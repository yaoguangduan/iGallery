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
use tower_http::cors::CorsLayer;

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
    /// M7: 持有 mDNS daemon，避免进程期间被 drop
    pub _mdns: Arc<mdns_sd::ServiceDaemon>,
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

    // mDNS：失败不致命 (R1)，只警告
    let mdns_daemon = match mdns_sd::ServiceDaemon::new() {
        Ok(d) => Arc::new(d),
        Err(e) => {
            tracing::warn!("mDNS daemon init failed: {e} — 局域网自动发现将不可用");
            Arc::new(mdns_sd::ServiceDaemon::new().unwrap_or_else(|_| {
                // 二次失败，做个空 daemon 占位
                std::process::exit(0)  // 不会走到这里，除非彻底不能创建
            }))
        }
    };
    mdns::register(&mdns_daemon, port, &device_name);

    let token = cli.token.clone();

    let state = AppState {
        pool,
        data_dir: data_dir.clone(),
        media_dir: media_dir.clone(),
        thumbs_dir: thumbs_dir.clone(),
        device_name: device_name.clone(),
        token: token.clone(),
        _mdns: mdns_daemon,
    };

    let app = Router::new()
        .route("/v1/media/query",       routing::post(media::query_media))
        .route("/v1/media/probe",       routing::post(media::probe))
        .route("/v1/media/upload",      routing::post(media::upload))
        .route("/v1/media/upload-batch", routing::post(media::upload_batch))
        .route("/v1/media/batch-delete", routing::post(media::batch_delete))
        .route("/v1/media/batch-move",  routing::post(media::batch_move))
        .route("/v1/media/batch-favorite", routing::post(media::batch_favorite))
        .route("/v1/media/download",    routing::post(media::download_batch))
        .route("/v1/folders",           routing::get(folder::list_folders).post(folder::create_folder))
        .route("/v1/folders/{id}",      routing::get(folder::get_folder).patch(folder::rename_folder).delete(folder::delete_folder))
        .route("/v1/folders/{id}/ancestors", routing::get(folder::get_ancestors))
        .route("/v1/media/{id}",        routing::get(media::get_media).delete(media::delete_media).patch(media::update_media))
        .route("/v1/media/{id}/thumb",  routing::get(media::get_thumb))
        .route("/v1/media/{id}/download", routing::get(media::download_single))
        .route("/v1/media/{id}/restore", routing::post(media::restore_media))
        .route("/v1/auth",              routing::get(auth::auth_probe))
        .route("/v1/info",              routing::get(media::server_info))
        .layer(middleware::from_fn_with_state(state.clone(), auth::require_token))
        .layer(DefaultBodyLimit::max(4 * 1024 * 1024 * 1024)) // 4 GB
        .layer(CorsLayer::permissive())
        .with_state(state);

    let addr = format!("0.0.0.0:{port}");
    tracing::info!("iGallery server listening on {addr}");
    tracing::info!("  data:   {}", data_dir.display());
    tracing::info!("  media:  {}", media_dir.display());
    tracing::info!("  thumbs: {}", thumbs_dir.display());
    if token.is_some() {
        tracing::info!("  auth:   token required (Authorization: Bearer <token>)");
    } else {
        tracing::warn!("  auth:   DISABLED — 局域网内任何设备可访问");
    }

    let listener = tokio::net::TcpListener::bind(&addr).await.expect("bind");
    axum::serve(listener, app).await.expect("serve");
}
