use axum::{
    body::Body,
    extract::{DefaultBodyLimit, Multipart, Path, State},
    http::{header, StatusCode},
    response::IntoResponse,
    Json,
};
use sha2::{Digest, Sha256};
use tokio::fs;
use tokio::io::AsyncWriteExt;
use uuid::Uuid;

use crate::db::{self, MediaRow, QueryRequest};
use crate::exif_util;
use crate::thumb;
use crate::AppState;

// ── POST /v1/media/query — PocketBase-style flexible query ──

pub async fn query_media(
    State(state): State<AppState>,
    Json(req): Json<QueryRequest>,
) -> impl IntoResponse {
    match db::query_media(&state.pool, &req).await {
        Ok((items, total)) => Json(serde_json::json!({
            "items": items,
            "total": total,
            "page": req.page,
            "size": req.size,
        })).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, Json(serde_json::json!({"error": e}))).into_response(),
    }
}

// ── GET /v1/media/{id} — serve original file ──

pub async fn get_media(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let row = match db::get_media(&state.pool, &id).await {
        Some(r) => r,
        None => return StatusCode::NOT_FOUND.into_response(),
    };
    let path = state.media_dir.join(format!("{}.{}", id, row.ext));
    match fs::read(&path).await {
        Ok(data) => ([(header::CONTENT_TYPE, row.mime)], Body::from(data)).into_response(),
        Err(_) => StatusCode::NOT_FOUND.into_response(),
    }
}

// ── GET /v1/media/{id}/thumb ──

pub async fn get_thumb(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let path = state.thumbs_dir.join(format!("{id}.jpg"));
    match fs::read(&path).await {
        Ok(data) => ([(header::CONTENT_TYPE, "image/jpeg".to_string())], Body::from(data)).into_response(),
        Err(_) => StatusCode::NOT_FOUND.into_response(),
    }
}

// ── POST /v1/media/upload — single file ──

pub async fn upload(
    State(state): State<AppState>,
    mut multipart: Multipart,
) -> impl IntoResponse {
    let mut taken_at_override: Option<String> = None;
    let mut uploaded: Vec<MediaRow> = Vec::new();

    while let Ok(Some(field)) = multipart.next_field().await {
        let name = field.name().unwrap_or("").to_string();

        if name == "taken_at" {
            if let Ok(text) = field.text().await { taken_at_override = Some(text); }
            continue;
        }
        if name != "file" { continue; }

        let filename = field.file_name().unwrap_or("unknown").to_string();
        let content_type = field.content_type().unwrap_or("application/octet-stream").to_string();

        if let Some(row) = stream_upload(&state, field, &filename, &content_type, taken_at_override.as_deref()).await {
            uploaded.push(row);
        }
    }
    Json(uploaded)
}

pub async fn upload_batch(
    State(state): State<AppState>,
    mut multipart: Multipart,
) -> impl IntoResponse {
    let mut uploaded: Vec<MediaRow> = Vec::new();
    while let Ok(Some(field)) = multipart.next_field().await {
        let name = field.name().unwrap_or("").to_string();
        if name != "file" { continue; }
        let filename = field.file_name().unwrap_or("unknown").to_string();
        let content_type = field.content_type().unwrap_or("application/octet-stream").to_string();
        if let Some(row) = stream_upload(&state, field, &filename, &content_type, None).await {
            uploaded.push(row);
        }
    }
    Json(uploaded)
}

async fn stream_upload(
    state: &AppState,
    mut field: axum::extract::multipart::Field<'_>,
    filename: &str,
    content_type: &str,
    taken_at_override: Option<&str>,
) -> Option<MediaRow> {
    let id = Uuid::new_v4().to_string();
    let ext = filename.rsplit('.').next().unwrap_or("bin").to_lowercase();
    let media_path = state.media_dir.join(format!("{id}.{ext}"));

    // 流式写入磁盘 + 边写边算 SHA256
    let mut file = match fs::File::create(&media_path).await {
        Ok(f) => f,
        Err(_) => return None,
    };
    let mut hasher = Sha256::new();
    let mut total_size: u64 = 0;

    while let Ok(Some(chunk)) = field.chunk().await {
        hasher.update(&chunk);
        total_size += chunk.len() as u64;
        if file.write_all(&chunk).await.is_err() {
            let _ = fs::remove_file(&media_path).await;
            return None;
        }
    }
    file.flush().await.ok();
    drop(file);

    let checksum = format!("{:x}", hasher.finalize());

    // 去重：已存在则删除刚写入的文件
    if let Some(existing) = db::find_by_checksum(&state.pool, &checksum).await {
        let _ = fs::remove_file(&media_path).await;
        return Some(existing);
    }

    let media_type = if content_type.starts_with("image/") { "image" }
        else if content_type.starts_with("video/") { "video" }
        else if content_type.starts_with("audio/") { "audio" }
        else { "other" };

    let exif = exif_util::extract(&media_path);
    let taken_at = exif.taken_at.or_else(|| taken_at_override.map(String::from));

    let (w, h) = if media_type == "image" {
        let ew = exif.width.map(|v| v as i32);
        let eh = exif.height.map(|v| v as i32);
        if ew.is_some() && eh.is_some() { (ew, eh) }
        else {
            image::image_dimensions(&media_path).ok()
                .map(|(w, h)| (Some(w as i32), Some(h as i32)))
                .unwrap_or((None, None))
        }
    } else { (None, None) };

    let has_thumb = if media_type == "image" {
        let thumb_path = state.thumbs_dir.join(format!("{id}.jpg"));
        let src = media_path.clone();
        tokio::task::spawn_blocking(move || thumb::generate_thumbnail(&src, &thumb_path))
            .await.ok().and_then(|r| r.ok()).is_some()
    } else { false };

    let now = chrono::Utc::now().to_rfc3339();
    let row = MediaRow {
        id, filename: filename.to_string(), ext, mime: content_type.to_string(),
        media_type: media_type.to_string(),
        size: total_size as i64, width: w, height: h,
        duration: None, orientation: exif.orientation.map(|v| v as i32),
        taken_at, created_at: now.clone(), updated_at: now, deleted_at: None,
        checksum: Some(checksum),
        exif_make: exif.make, exif_model: exif.model, exif_lens: exif.lens,
        exif_focal_length: exif.focal_length, exif_aperture: exif.aperture,
        exif_iso: exif.iso.map(|v| v as i32), exif_exposure: exif.exposure,
        exif_gps_lat: exif.gps_lat, exif_gps_lng: exif.gps_lng,
        favorite: 0, tags: "[]".to_string(), notes: String::new(),
        has_thumb: if has_thumb { 1 } else { 0 },
    };

    db::insert_media(&state.pool, &row).await;
    Some(row)
}

// ── DELETE /v1/media/{id} — soft delete ──

pub async fn delete_media(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    if db::soft_delete(&state.pool, &id).await {
        StatusCode::NO_CONTENT
    } else {
        StatusCode::NOT_FOUND
    }
}

// ── POST /v1/media/batch-delete — soft delete multiple ──

#[derive(serde::Deserialize)]
pub struct BatchIds { pub ids: Vec<String> }

pub async fn batch_delete(
    State(state): State<AppState>,
    Json(body): Json<BatchIds>,
) -> impl IntoResponse {
    let mut deleted = 0usize;
    for id in &body.ids {
        if db::soft_delete(&state.pool, id).await { deleted += 1; }
    }
    Json(serde_json::json!({ "deleted": deleted }))
}

// ── POST /v1/media/{id}/restore ──

pub async fn restore_media(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    if db::restore(&state.pool, &id).await { StatusCode::NO_CONTENT }
    else { StatusCode::NOT_FOUND }
}

// ── PATCH /v1/media/{id} — update fields ──

pub async fn update_media(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<serde_json::Map<String, serde_json::Value>>,
) -> impl IntoResponse {
    let allowed = ["favorite", "tags", "notes", "filename"];
    let sets: Vec<(String, String)> = body.iter()
        .filter(|(k, _)| allowed.contains(&k.as_str()))
        .map(|(k, v)| (k.clone(), match v {
            serde_json::Value::String(s) => s.clone(),
            other => other.to_string(),
        }))
        .collect();
    if db::update_fields(&state.pool, &id, &sets).await {
        StatusCode::NO_CONTENT
    } else {
        StatusCode::NOT_FOUND
    }
}

// ── POST /v1/media/download — zip batch ──

pub async fn download_batch(
    State(state): State<AppState>,
    Json(body): Json<BatchIds>,
) -> impl IntoResponse {
    let mut files = Vec::new();
    for id in &body.ids {
        if let Some(row) = db::get_media(&state.pool, id).await {
            files.push((format!("{id}.{}", row.ext), row.filename));
        }
    }
    match crate::archive::create_zip(&state.media_dir, &files) {
        Ok(data) => ([
            (header::CONTENT_TYPE, "application/zip".to_string()),
            (header::CONTENT_DISPOSITION, "attachment; filename=\"igallery.zip\"".to_string()),
        ], Body::from(data)).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e).into_response(),
    }
}

// ── GET /v1/info ──

#[derive(serde::Serialize)]
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
