use axum::{
    body::Body,
    extract::{Multipart, Path, Request, State},
    http::{header, StatusCode},
    response::IntoResponse,
    Json,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::fs;
use tokio::io::AsyncWriteExt;
use tower_http::services::ServeFile;
use tower::ServiceExt;
use uuid::Uuid;

use crate::db::{self, MediaRow, QueryRequest, UpdateFields};
use crate::exif_util;
use crate::sanitize::{content_disposition, sanitize_ext, sanitize_filename};
use crate::thumb;
use crate::time::now_rfc3339;
use crate::AppState;

// 缩略图/原图 immutable，缓存 30 天 (P2)
const IMMUTABLE_CACHE: &str = "public, max-age=2592000, immutable";

// ── POST /v1/media/query — flexible + cursor 分页 ──

pub async fn query_media(
    State(state): State<AppState>,
    Json(req): Json<QueryRequest>,
) -> impl IntoResponse {
    match db::query_media(&state.pool, &req).await {
        Ok(r) => Json(r).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, Json(serde_json::json!({"error": e}))).into_response(),
    }
}

// ── GET /v1/media/{id} — serve original file, immutable cache ──

pub async fn get_media(
    State(state): State<AppState>,
    Path(id): Path<String>,
    request: Request,
) -> impl IntoResponse {
    let row = match db::get_media(&state.pool, &id).await {
        Ok(Some(r)) => r,
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(e) => { tracing::error!("get_media db: {e}"); return StatusCode::INTERNAL_SERVER_ERROR.into_response(); }
    };
    let path = state.media_dir.join(format!("{}.{}", id, row.ext));
    if !path.exists() {
        return StatusCode::NOT_FOUND.into_response();
    }
    match ServeFile::new(&path).oneshot(request).await {
        Ok(resp) => {
            let (mut parts, body) = resp.into_parts();
            parts.headers.insert(header::CACHE_CONTROL, IMMUTABLE_CACHE.parse().unwrap());
            if let Some(taken_at) = &row.taken_at {
                if let Ok(val) = taken_at.parse() {
                    parts.headers.insert("x-taken-at", val);
                }
            }
            axum::http::Response::from_parts(parts, body).into_response()
        }
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

// ── GET /v1/media/{id}/thumb ──

pub async fn get_thumb(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let path = state.thumbs_dir.join(format!("{id}.jpg"));
    match fs::read(&path).await {
        Ok(data) => (
            [
                (header::CONTENT_TYPE, "image/jpeg".to_string()),
                (header::CACHE_CONTROL, IMMUTABLE_CACHE.to_string()),
            ],
            Body::from(data),
        ).into_response(),
        Err(_) => StatusCode::NOT_FOUND.into_response(),
    }
}

// ── POST /v1/media/probe — 秒传探测 (客户端上传前先算 SHA256) ──

#[derive(Deserialize)]
pub struct ProbeReq { pub checksum: String }

pub async fn probe(
    State(state): State<AppState>,
    Json(body): Json<ProbeReq>,
) -> impl IntoResponse {
    match db::find_by_checksum(&state.pool, &body.checksum).await {
        Ok(Some(row)) => Json(serde_json::json!({"exists": true, "item": row})).into_response(),
        Ok(None) => Json(serde_json::json!({"exists": false})).into_response(),
        Err(e) => { tracing::error!("probe db: {e}"); StatusCode::INTERNAL_SERVER_ERROR.into_response() }
    }
}

// ── POST /v1/media/upload ──

/// 上传响应带 dedup 标志（true = 命中已有文件）
#[derive(Serialize)]
struct UploadItem {
    #[serde(flatten)]
    row: MediaRow,
    dedup: bool,
}

pub async fn upload(
    State(state): State<AppState>,
    mut multipart: Multipart,
) -> impl IntoResponse {
    let mut taken_at_override: Option<String> = None;
    let mut folder_id_override: Option<String> = None;
    let mut uploaded: Vec<UploadItem> = Vec::new();

    while let Ok(Some(field)) = multipart.next_field().await {
        let name = field.name().unwrap_or("").to_string();

        if name == "taken_at" {
            if let Ok(text) = field.text().await { taken_at_override = Some(text); }
            continue;
        }
        if name == "folder_id" {
            if let Ok(text) = field.text().await { folder_id_override = Some(text); }
            continue;
        }
        if name != "file" { continue; }

        let filename = field.file_name().unwrap_or("unknown").to_string();
        let content_type = field.content_type().unwrap_or("application/octet-stream").to_string();

        match stream_upload(&state, field, &filename, &content_type, taken_at_override.as_deref(), folder_id_override.clone()).await {
            Ok(Some(item)) => uploaded.push(item),
            Ok(None) => {}
            Err(e) => tracing::warn!("upload failed for {filename}: {e}"),
        }
    }
    Json(uploaded).into_response()
}

pub async fn upload_batch(
    State(state): State<AppState>,
    mut multipart: Multipart,
) -> impl IntoResponse {
    let mut uploaded: Vec<UploadItem> = Vec::new();
    while let Ok(Some(field)) = multipart.next_field().await {
        let name = field.name().unwrap_or("").to_string();
        if name != "file" { continue; }
        let filename = field.file_name().unwrap_or("unknown").to_string();
        let content_type = field.content_type().unwrap_or("application/octet-stream").to_string();
        if let Ok(Some(item)) = stream_upload(&state, field, &filename, &content_type, None, None).await {
            uploaded.push(item);
        }
    }
    Json(uploaded).into_response()
}

/// R2: 上传中断 → 清理临时文件；只有完整成功才写库。
async fn stream_upload(
    state: &AppState,
    mut field: axum::extract::multipart::Field<'_>,
    filename: &str,
    content_type: &str,
    taken_at_override: Option<&str>,
    folder_id: Option<String>,
) -> Result<Option<UploadItem>, String> {
    let id = Uuid::new_v4().to_string();
    let safe_filename = sanitize_filename(filename);
    let raw_ext = safe_filename.rsplit('.').next().unwrap_or("bin");
    let ext = sanitize_ext(raw_ext);
    let media_path = state.media_dir.join(format!("{id}.{ext}"));

    let mut file = fs::File::create(&media_path).await
        .map_err(|e| format!("create: {e}"))?;
    let mut hasher = Sha256::new();
    let mut total_size: u64 = 0;
    let mut interrupted = false;
    let mut interrupt_reason = String::new();

    loop {
        match field.chunk().await {
            Ok(Some(chunk)) => {
                hasher.update(&chunk);
                total_size += chunk.len() as u64;
                if let Err(e) = file.write_all(&chunk).await {
                    interrupted = true;
                    interrupt_reason = format!("write: {e}");
                    break;
                }
            }
            Ok(None) => break,      // 完整结束
            Err(e) => {
                interrupted = true;
                interrupt_reason = format!("read: {e}");
                break;
            }
        }
    }
    file.flush().await.ok();
    drop(file);

    if interrupted {
        let _ = fs::remove_file(&media_path).await;
        return Err(interrupt_reason);
    }

    let checksum = format!("{:x}", hasher.finalize());

    // 去重
    if let Ok(Some(existing)) = db::find_by_checksum(&state.pool, &checksum).await {
        let _ = fs::remove_file(&media_path).await;
        return Ok(Some(UploadItem { row: existing, dedup: true }));
    }

    let media_type = if content_type.starts_with("image/") { "image" }
        else if content_type.starts_with("video/") { "video" }
        else if content_type.starts_with("audio/") { "audio" }
        else { "other" };

    let exif = exif_util::extract(&media_path);
    let mut taken_at = exif.taken_at.clone().or_else(|| taken_at_override.map(String::from));

    let mut w: Option<i32> = None;
    let mut h: Option<i32> = None;
    let mut duration: Option<f64> = None;
    let thumb_path = state.thumbs_dir.join(format!("{id}.jpg"));
    let mut has_thumb = false;

    if media_type == "image" {
        let ew = exif.width.map(|v| v as i32);
        let eh = exif.height.map(|v| v as i32);
        if ew.is_some() && eh.is_some() {
            w = ew; h = eh;
        } else if let Ok((iw, ih)) = image::image_dimensions(&media_path) {
            w = Some(iw as i32); h = Some(ih as i32);
        }
        let src = media_path.clone();
        let dst = thumb_path.clone();
        has_thumb = tokio::task::spawn_blocking(move || thumb::generate_thumbnail(&src, &dst))
            .await.ok().and_then(|r| r.ok()).is_some();
    } else if media_type == "video" {
        let src = media_path.clone();
        let dst = thumb_path.clone();
        let meta = tokio::task::spawn_blocking(move || thumb::process_video(&src, &dst))
            .await.unwrap_or(thumb::VideoMeta { duration: None, width: None, height: None, thumb_ok: false, taken_at: None });
        duration = meta.duration;
        w = meta.width.map(|v| v as i32);
        h = meta.height.map(|v| v as i32);
        has_thumb = meta.thumb_ok;
        // 视频 QuickTime creation_time (备用时间源)
        if taken_at.is_none() { taken_at = meta.taken_at; }
    }

    finalize_row(state, id, safe_filename, ext, content_type, media_type,
        total_size, w, h, duration, exif.orientation.map(|v| v as i32),
        taken_at, checksum, exif, has_thumb, folder_id).await
}

#[allow(clippy::too_many_arguments)]
async fn finalize_row(
    state: &AppState,
    id: String,
    filename: String,
    ext: String,
    content_type: &str,
    media_type: &str,
    size: u64,
    w: Option<i32>, h: Option<i32>,
    duration: Option<f64>,
    orientation: Option<i32>,
    taken_at: Option<String>,
    checksum: String,
    exif: exif_util::ExifData,
    has_thumb: bool,
    folder_id: Option<String>,
) -> Result<Option<UploadItem>, String> {
    let now = now_rfc3339();
    let row = MediaRow {
        id, filename, ext, mime: content_type.to_string(),
        media_type: media_type.to_string(),
        size: size as i64, width: w, height: h,
        duration, orientation,
        taken_at, created_at: now.clone(), updated_at: now, deleted_at: None,
        checksum: Some(checksum),
        exif_make: exif.make, exif_model: exif.model, exif_lens: exif.lens,
        exif_focal_length: exif.focal_length, exif_aperture: exif.aperture,
        exif_iso: exif.iso.map(|v| v as i32), exif_exposure: exif.exposure,
        exif_gps_lat: exif.gps_lat, exif_gps_lng: exif.gps_lng,
        favorite: 0, tags: "[]".to_string(), notes: String::new(),
        has_thumb: if has_thumb { 1 } else { 0 },
        folder_id,
    };

    db::insert_media(&state.pool, &row).await.map_err(|e| format!("insert: {e}"))?;
    Ok(Some(UploadItem { row, dedup: false }))
}

// ── DELETE /v1/media/{id} ──

pub async fn delete_media(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    match db::soft_delete(&state.pool, &id).await {
        Ok(true) => StatusCode::NO_CONTENT.into_response(),
        Ok(false) => StatusCode::NOT_FOUND.into_response(),
        Err(e) => { tracing::error!("soft_delete: {e}"); StatusCode::INTERNAL_SERVER_ERROR.into_response() }
    }
}

#[derive(Deserialize)]
pub struct BatchIds { pub ids: Vec<String> }

/// R3: 单条 UPDATE 完成 batch delete
pub async fn batch_delete(
    State(state): State<AppState>,
    Json(body): Json<BatchIds>,
) -> impl IntoResponse {
    match db::soft_delete_many(&state.pool, &body.ids).await {
        Ok(n) => Json(serde_json::json!({"deleted": n})).into_response(),
        Err(e) => { tracing::error!("batch_delete: {e}"); StatusCode::INTERNAL_SERVER_ERROR.into_response() }
    }
}

#[derive(Deserialize)]
pub struct BatchMove {
    pub ids: Vec<String>,
    pub folder_id: Option<String>,
}

pub async fn batch_move(
    State(state): State<AppState>,
    Json(body): Json<BatchMove>,
) -> impl IntoResponse {
    if let Some(ref fid) = body.folder_id {
        match db::get_folder(&state.pool, fid).await {
            Ok(None) => return (StatusCode::NOT_FOUND, Json(serde_json::json!({"error": "folder not found"}))).into_response(),
            Err(e) => { tracing::error!("get_folder: {e}"); return StatusCode::INTERNAL_SERVER_ERROR.into_response(); }
            _ => {}
        }
    }
    match db::move_many(&state.pool, &body.ids, body.folder_id.as_deref()).await {
        Ok(n) => Json(serde_json::json!({"moved": n})).into_response(),
        Err(e) => { tracing::error!("batch_move: {e}"); StatusCode::INTERNAL_SERVER_ERROR.into_response() }
    }
}

// ── POST /v1/media/batch-favorite ──

#[derive(Deserialize)]
pub struct BatchFavorite {
    pub ids: Vec<String>,
    pub favorite: bool,
}

pub async fn batch_favorite(
    State(state): State<AppState>,
    Json(body): Json<BatchFavorite>,
) -> impl IntoResponse {
    match db::set_favorite_many(&state.pool, &body.ids, body.favorite).await {
        Ok(n) => Json(serde_json::json!({"updated": n})).into_response(),
        Err(e) => { tracing::error!("batch_favorite: {e}"); StatusCode::INTERNAL_SERVER_ERROR.into_response() }
    }
}

pub async fn restore_media(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    match db::restore(&state.pool, &id).await {
        Ok(true) => StatusCode::NO_CONTENT.into_response(),
        Ok(false) => StatusCode::NOT_FOUND.into_response(),
        Err(e) => { tracing::error!("restore: {e}"); StatusCode::INTERNAL_SERVER_ERROR.into_response() }
    }
}

/// M4: 强类型 PATCH，返回更新后的完整 row 方便客户端 copyWith 直接刷新
pub async fn update_media(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<UpdateFields>,
) -> impl IntoResponse {
    match db::update_fields(&state.pool, &id, &body).await {
        Ok(true) => {
            match db::get_media(&state.pool, &id).await {
                Ok(Some(row)) => Json(row).into_response(),
                Ok(None) => StatusCode::NOT_FOUND.into_response(),
                Err(e) => { tracing::error!("update_media get: {e}"); StatusCode::INTERNAL_SERVER_ERROR.into_response() }
            }
        }
        Ok(false) => StatusCode::NOT_FOUND.into_response(),
        Err(e) => { tracing::error!("update_media: {e}"); StatusCode::INTERNAL_SERVER_ERROR.into_response() }
    }
}

// ── POST /v1/media/download — 流式 zip ──

pub async fn download_batch(
    State(state): State<AppState>,
    Json(body): Json<BatchIds>,
) -> impl IntoResponse {
    let mut files = Vec::new();
    for id in &body.ids {
        match db::get_media(&state.pool, id).await {
            Ok(Some(row)) => files.push((format!("{id}.{}", row.ext), row.filename)),
            _ => {}
        }
    }
    if files.is_empty() {
        return StatusCode::NOT_FOUND.into_response();
    }

    let stream = crate::archive::create_zip_stream(&state.media_dir, &files);
    ([
        (header::CONTENT_TYPE, "application/zip".to_string()),
        (header::CONTENT_DISPOSITION, "attachment; filename=\"igallery.zip\"".to_string()),
    ], Body::from_stream(stream)).into_response()
}

// ── GET /v1/media/{id}/download ──

pub async fn download_single(
    State(state): State<AppState>,
    Path(id): Path<String>,
    request: Request,
) -> impl IntoResponse {
    let row = match db::get_media(&state.pool, &id).await {
        Ok(Some(r)) => r,
        _ => return StatusCode::NOT_FOUND.into_response(),
    };
    let path = state.media_dir.join(format!("{}.{}", id, row.ext));
    if !path.exists() {
        return StatusCode::NOT_FOUND.into_response();
    }
    // RFC 5987 编码，支持中文和特殊字符 (S2)
    let disposition = content_disposition(&row.filename);
    match ServeFile::new(&path).oneshot(request).await {
        Ok(resp) => {
            let (mut parts, body) = resp.into_parts();
            parts.headers.insert(header::CONTENT_DISPOSITION, disposition.parse().unwrap());
            if let Some(taken_at) = &row.taken_at {
                if let Ok(val) = taken_at.parse() {
                    parts.headers.insert("x-taken-at", val);
                }
            }
            axum::http::Response::from_parts(parts, body).into_response()
        }
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

// ── GET /v1/info ──

#[derive(Serialize)]
pub struct ServerInfo {
    pub name: String,
    pub version: String,
    pub file_count: i64,
    pub total_size: i64,
}

pub async fn server_info(State(state): State<AppState>) -> Json<ServerInfo> {
    Json(ServerInfo {
        name: state.device_name.clone(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        file_count: db::count_active(&state.pool).await,
        total_size: db::total_size(&state.pool).await,
    })
}
