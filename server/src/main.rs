mod archive;
mod auth;
mod db;
mod exif_util;
mod folder;
mod mdns;
mod media;
mod sanitize;
mod thumb;
mod time;

use axum::{extract::DefaultBodyLimit, middleware, routing, Router};
use clap::Parser;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::AsyncReadExt;
use tower_http::cors::CorsLayer;
use tower_http::timeout::TimeoutLayer;
use xxhash_rust::xxh3::Xxh3;

#[derive(Parser)]
#[command(name = "igallery-server", about = "iGallery 局域网相册服务")]
struct Cli {
    /// 数据存储路径（包含 media/thumbs/db）
    #[arg(short, long, env = "DATA_DIR", default_value = "./data")]
    data: PathBuf,

    /// 监听端口
    #[arg(short, long, env = "PORT", default_value_t = 9600)]
    port: u16,

    /// 设备名称（局域网发现时显示）
    #[arg(short, long, env = "DEVICE_NAME")]
    name: Option<String>,

    /// 媒体文件存储路径
    #[arg(short, long, env = "MEDIA_DIR")]
    media_dir: Option<PathBuf>,

    /// 缩略图存储路径
    #[arg(short, long, env = "THUMBS_DIR")]
    thumbs_dir: Option<PathBuf>,

    /// 鉴权 token（未指定则关闭鉴权）
    #[arg(long, env = "IGALLERY_TOKEN")]
    token: Option<String>,
}

#[derive(Clone)]
pub struct AppState {
    pub pool: sqlx::SqlitePool,
    pub data_dir: PathBuf,
    pub media_dir: PathBuf,
    pub thumbs_dir: PathBuf,
    pub device_name: String,
    pub token: Option<String>,
    /// M7: 持有 mDNS daemon，避免进程期间被 drop。
    /// None = mDNS 初始化失败，仅失去局域网自动发现，服务本身照常。
    pub _mdns: Option<Arc<mdns_sd::ServiceDaemon>>,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let cli = Cli::parse();

    let port = cli.port;
    let data_dir = cli.data;

    let device_name = cli.name.unwrap_or_else(|| {
        gethostname::gethostname().to_string_lossy().to_string()
    });

    let media_dir = cli.media_dir.unwrap_or_else(|| data_dir.join("media"));
    let thumbs_dir = cli.thumbs_dir.unwrap_or_else(|| data_dir.join("thumbs"));

    tokio::fs::create_dir_all(&data_dir).await.expect("create data dir");
    tokio::fs::create_dir_all(&media_dir).await.expect("create media dir");
    tokio::fs::create_dir_all(&thumbs_dir).await.expect("create thumbs dir");

    let pool = db::init_pool(&data_dir).await.expect("open sqlite");

    // mDNS：失败不致命 (R1)，只警告，降级为"无自动发现"继续服务。
    // 旧实现在二次失败时 process::exit(0) —— 在不支持组播的容器里
    // 整个服务会一声不吭地退出，与"非致命"的意图完全相反。
    let mdns_daemon = match mdns_sd::ServiceDaemon::new() {
        Ok(d) => Some(Arc::new(d)),
        Err(e) => {
            tracing::warn!("mDNS daemon init failed: {e} — 重试一次");
            match mdns_sd::ServiceDaemon::new() {
                Ok(d) => Some(Arc::new(d)),
                Err(e2) => {
                    tracing::warn!("mDNS 不可用: {e2} —— 局域网自动发现将不可用，服务继续启动");
                    None
                }
            }
        }
    };
    if let Some(daemon) = &mdns_daemon {
        mdns::register(daemon, port, &device_name);
    }

    let token = cli.token.clone();

    let pool_for_purge = pool.clone();
    let state = AppState {
        pool,
        data_dir: data_dir.clone(),
        media_dir: media_dir.clone(),
        thumbs_dir: thumbs_dir.clone(),
        device_name: device_name.clone(),
        token: token.clone(),
        _mdns: mdns_daemon,
    };

    // 路由分两组：
    // - fast：查询/增删改等轻请求，套 60s 超时，防止卡住的连接永远占着；
    // - slow：上传/下载/原图/缩略图，大文件本来就要传很久，不设超时
    //   （客户端可随时掐断连接，服务端检测到写入失败会清理，见 stream_upload）。
    let fast = Router::new()
        .route("/v1/media/query",       routing::post(media::query_media))
        .route("/v1/media/probe",       routing::post(media::probe))
        .route("/v1/media/batch-delete", routing::post(media::batch_delete))
        .route("/v1/media/batch-move",  routing::post(media::batch_move))
        .route("/v1/media/batch-favorite", routing::post(media::batch_favorite))
        .route("/v1/media/checksums",     routing::get(media::list_checksums).post(media::check_hashes))
        .route("/v1/media/{id}",        routing::delete(media::delete_media).patch(media::update_media))
        .route("/v1/media/{id}/restore", routing::post(media::restore_media))
        .route("/v1/folders",           routing::get(folder::list_folders).post(folder::create_folder))
        .route("/v1/folders/{id}",      routing::get(folder::get_folder).patch(folder::patch_folder).delete(folder::delete_folder))
        .route("/v1/folders/{id}/ancestors", routing::get(folder::get_ancestors))
        .route("/v1/auth",              routing::get(auth::auth_probe))
        .route("/v1/info",              routing::get(media::server_info))
        .route("/v1/logs",              routing::post(receive_client_logs))
        .layer(TimeoutLayer::with_status_code(
            axum::http::StatusCode::REQUEST_TIMEOUT,
            Duration::from_secs(60),
        ));

    let slow = Router::new()
        .route("/v1/media/upload",      routing::post(media::upload))
        .route("/v1/media/upload-batch", routing::post(media::upload_batch))
        .route("/v1/media/download",    routing::post(media::download_batch))
        .route("/v1/media/{id}",        routing::get(media::get_media))
        .route("/v1/media/{id}/thumb",  routing::get(media::get_thumb))
        .route("/v1/media/{id}/download", routing::get(media::download_single));

    let app = Router::new()
        .merge(fast)
        .merge(slow)
        .layer(middleware::from_fn_with_state(state.clone(), auth::require_token))
        .layer(DefaultBodyLimit::max(4 * 1024 * 1024 * 1024)) // 4 GB
        .layer(CorsLayer::permissive())
        .with_state(state);

    let addr = format!("0.0.0.0:{port}");
    tracing::info!("iGallery server preparing {addr}");
    tracing::info!("  data:   {}", data_dir.display());
    tracing::info!("  media:  {}", media_dir.display());
    tracing::info!("  thumbs: {}", thumbs_dir.display());
    if token.is_some() {
        tracing::info!("  auth:   token required (Authorization: Bearer <token>)");
    } else {
        tracing::warn!("  auth:   DISABLED — 局域网内任何设备可访问");
    }
    thumb::probe_toolchain();

    // 监听前完成一次旧 SHA/空 checksum 迁移，避免混合算法期间秒传漏判并产生重复文件。
    if !migrate_legacy_checksums(&pool_for_purge, &media_dir).await {
        tracing::error!("checksum migration failed; server will not accept requests");
        return;
    }

    // 后台定期清理"删除超过 30 天"的条目（回收站语义：期内可 restore）。
    tokio::spawn(purge_loop(pool_for_purge, media_dir.clone(), thumbs_dir.clone()));

    let listener = tokio::net::TcpListener::bind(&addr).await.expect("bind");
    tracing::info!("iGallery server listening on {addr}");
    axum::serve(listener, app).await.expect("serve");
}

/// 软删除 30 天后物理清理：删 DB 行 + 媒体文件 + 缩略图。
/// 失败只告警，下个周期再来，绝不影响主服务。
async fn purge_loop(pool: sqlx::SqlitePool, media_dir: PathBuf, thumbs_dir: PathBuf) {
    let mut interval = tokio::time::interval(Duration::from_secs(6 * 3600));
    interval.tick().await; // 首次立即触发，跳过
    loop {
        interval.tick().await;
        let cutoff = crate::time::to_beijing_rfc3339(chrono::Utc::now() - chrono::Duration::days(30));
        let rows = match db::select_purgeable(&pool, &cutoff, 1000).await {
            Ok(r) => r,
            Err(e) => { tracing::warn!("purge select: {e}"); continue; }
        };
        if rows.is_empty() { continue; }

        match db::purge_ids(&pool, &rows).await {
            Ok(n) if n > 0 => {
                for (id, ext) in &rows {
                    // 文件删不掉只告警：行已经没了，客户端不会再引用到
                    let _ = tokio::fs::remove_file(media_dir.join(format!("{id}.{ext}"))).await;
                    let _ = tokio::fs::remove_file(thumbs_dir.join(format!("{id}.jpg"))).await;
                }
                tracing::info!("purge: 物理清理了 {n} 条删除超过 30 天的记录");
            }
            Ok(_) => {}
            Err(e) => tracing::warn!("purge delete: {e}"),
        }
    }
}

async fn migrate_legacy_checksums(
    pool: &sqlx::SqlitePool,
    media_dir: &std::path::Path,
) -> bool {
    const BUFFER_SIZE: usize = 1024 * 1024;
    let mut after_id = String::new();
    let mut migrated = 0usize;
    let mut read_failed = 0usize;
    let mut db_failed = 0usize;

    loop {
        let batch = match db::list_legacy_checksums_after(pool, &after_id, 50).await {
            Ok(batch) => batch,
            Err(e) => {
                tracing::warn!("checksum migration query: {e}");
                return false;
            }
        };
        if batch.is_empty() {
            break;
        }

        for (id, ext) in batch {
            after_id = id.clone();
            let path = media_dir.join(format!("{id}.{ext}"));
            let result = async {
                let mut file = tokio::fs::File::open(&path).await?;
                let mut buffer = vec![0u8; BUFFER_SIZE];
                let mut hasher = Xxh3::new();
                loop {
                    let read = file.read(&mut buffer).await?;
                    if read == 0 {
                        break;
                    }
                    hasher.update(&buffer[..read]);
                }
                Ok::<String, std::io::Error>(format!("{:032x}", hasher.digest128()))
            }.await;

            match result {
                Ok(checksum) => match db::set_checksum(pool, &id, &checksum).await {
                    Ok(()) => migrated += 1,
                    Err(e) => {
                        db_failed += 1;
                        tracing::warn!("checksum migration set {id}: {e}");
                    }
                },
                Err(e) => {
                    read_failed += 1;
                    tracing::warn!("checksum migration read {}: {e}", path.display());
                }
            }
        }
    }

    if migrated > 0 || read_failed > 0 || db_failed > 0 {
        tracing::info!(
            "checksum migration: XXH3-128 migrated={migrated}, read_failed={read_failed}, db_failed={db_failed}"
        );
    }
    read_failed == 0 && db_failed == 0
}

#[derive(serde::Deserialize)]
struct ClientLogEntry {
    level: String,
    message: String,
    detail: Option<String>,
    created_at: Option<i64>,
}

#[derive(serde::Deserialize)]
struct ClientLogsBody {
    logs: Vec<ClientLogEntry>,
}

async fn receive_client_logs(
    axum::Json(body): axum::Json<ClientLogsBody>,
) -> impl axum::response::IntoResponse {
    for entry in &body.logs {
        let detail = entry.detail.as_deref().unwrap_or("");
        match entry.level.as_str() {
            "error" => tracing::error!(target: "client", "{} {}", entry.message, detail),
            "warn"  => tracing::warn!(target: "client", "{} {}", entry.message, detail),
            _       => tracing::info!(target: "client", "{} {}", entry.message, detail),
        }
    }
    axum::Json(serde_json::json!({"received": body.logs.len()}))
}

#[cfg(test)]
mod tests {
    use xxhash_rust::xxh3::{xxh3_128, Xxh3};

    #[test]
    fn xxh3_128_matches_canonical_vectors() {
        let vectors = [
            (b"".as_slice(), "99aa06d3014798d86001c324468d497f"),
            (b"abc".as_slice(), "06b05ab6733a618578af5f94892f3950"),
            (b"Hello, World!".as_slice(), "531df2844447dd5077db03842cd75395"),
            (
                b"The quick brown fox jumps over the lazy dog".as_slice(),
                "ddd650205ca3e7fa24a1cc2e3a8a7651",
            ),
        ];

        for (input, expected) in vectors {
            assert_eq!(format!("{:032x}", xxh3_128(input)), expected);
            let mut streamed = Xxh3::new();
            for chunk in input.chunks(3) {
                streamed.update(chunk);
            }
            assert_eq!(format!("{:032x}", streamed.digest128()), expected);
        }
    }
}
