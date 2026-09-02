use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use uuid::Uuid;

use crate::db::{self, FolderRow};
use crate::time::now_rfc3339;
use crate::AppState;

#[derive(serde::Serialize)]
pub struct FolderInfo {
    pub id: String,
    pub name: String,
    pub parent_id: Option<String>,
    pub cover_id: Option<String>,
    pub cover_media_type: Option<String>,
    pub item_count: i64,
    pub created_at: String,
    pub updated_at: String,
}

// ── POST /v1/folders ──

#[derive(serde::Deserialize)]
pub struct CreateFolder {
    pub name: String,
    pub parent_id: Option<String>,
}

pub async fn create_folder(
    State(state): State<AppState>,
    Json(body): Json<CreateFolder>,
) -> impl IntoResponse {
    let name = body.name.trim().to_string();
    if name.is_empty() {
        return (StatusCode::BAD_REQUEST, Json(serde_json::json!({"error": "name is required"}))).into_response();
    }

    if let Some(ref pid) = body.parent_id {
        match db::get_folder(&state.pool, pid).await {
            Ok(None) => return (StatusCode::NOT_FOUND, Json(serde_json::json!({"error": "parent folder not found"}))).into_response(),
            Err(e) => { tracing::error!("get_folder: {e}"); return StatusCode::INTERNAL_SERVER_ERROR.into_response(); }
            _ => {}
        }
    }

    let now = now_rfc3339();
    let row = FolderRow {
        id: Uuid::new_v4().to_string(),
        name,
        parent_id: body.parent_id,
        created_at: now.clone(),
        updated_at: now,
    };
    if let Err(e) = db::insert_folder(&state.pool, &row).await {
        tracing::error!("insert_folder: {e}");
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }

    let info = FolderInfo {
        id: row.id, name: row.name, parent_id: row.parent_id,
        cover_id: None, cover_media_type: None, item_count: 0,
        created_at: row.created_at, updated_at: row.updated_at,
    };
    (StatusCode::CREATED, Json(info)).into_response()
}

// ── GET /v1/folders?parent_id=x ──

#[derive(serde::Deserialize)]
pub struct ListQuery {
    pub parent_id: Option<String>,
}

/// P1: 一条 SQL 拿完，消灭 N+1
pub async fn list_folders(
    State(state): State<AppState>,
    Query(q): Query<ListQuery>,
) -> impl IntoResponse {
    let parent = q.parent_id.as_deref().filter(|s| !s.is_empty());
    match db::list_folders_with_meta(&state.pool, parent).await {
        Ok(rows) => {
            let out: Vec<FolderInfo> = rows.into_iter().map(|m| FolderInfo {
                id: m.row.id, name: m.row.name, parent_id: m.row.parent_id,
                cover_id: m.cover_id, cover_media_type: m.cover_media_type,
                item_count: m.item_count,
                created_at: m.row.created_at, updated_at: m.row.updated_at,
            }).collect();
            Json(out).into_response()
        }
        Err(e) => { tracing::error!("list_folders: {e}"); StatusCode::INTERNAL_SERVER_ERROR.into_response() }
    }
}

// ── GET /v1/folders/{id} ──

pub async fn get_folder(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    match db::get_folder(&state.pool, &id).await {
        Ok(Some(row)) => {
            // 也走一次 with_meta，取当前节点的 cover/count
            match db::list_folders_with_meta(&state.pool, row.parent_id.as_deref()).await {
                Ok(all) => {
                    let this = all.into_iter().find(|m| m.row.id == id);
                    if let Some(m) = this {
                        Json(FolderInfo {
                            id: m.row.id, name: m.row.name, parent_id: m.row.parent_id,
                            cover_id: m.cover_id, cover_media_type: m.cover_media_type,
                            item_count: m.item_count,
                            created_at: m.row.created_at, updated_at: m.row.updated_at,
                        }).into_response()
                    } else {
                        Json(FolderInfo {
                            id: row.id, name: row.name, parent_id: row.parent_id,
                            cover_id: None, cover_media_type: None, item_count: 0,
                            created_at: row.created_at, updated_at: row.updated_at,
                        }).into_response()
                    }
                }
                Err(e) => { tracing::error!("get_folder meta: {e}"); StatusCode::INTERNAL_SERVER_ERROR.into_response() }
            }
        }
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(e) => { tracing::error!("get_folder: {e}"); StatusCode::INTERNAL_SERVER_ERROR.into_response() }
    }
}

// ── PATCH /v1/folders/{id} ──

#[derive(serde::Deserialize)]
pub struct RenameBody { pub name: String }

pub async fn rename_folder(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<RenameBody>,
) -> impl IntoResponse {
    let name = body.name.trim();
    if name.is_empty() {
        return (StatusCode::BAD_REQUEST, Json(serde_json::json!({"error": "name is required"}))).into_response();
    }
    match db::rename_folder(&state.pool, &id, name).await {
        Ok(true) => StatusCode::NO_CONTENT.into_response(),
        Ok(false) => StatusCode::NOT_FOUND.into_response(),
        Err(e) => { tracing::error!("rename_folder: {e}"); StatusCode::INTERNAL_SERVER_ERROR.into_response() }
    }
}

// ── DELETE /v1/folders/{id} ──

pub async fn delete_folder(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    match db::get_folder(&state.pool, &id).await {
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(e) => { tracing::error!("get_folder: {e}"); return StatusCode::INTERNAL_SERVER_ERROR.into_response(); }
        _ => {}
    }
    let has_children = db::folder_has_children(&state.pool, &id).await.unwrap_or(true);
    let has_media = db::folder_has_media(&state.pool, &id).await.unwrap_or(true);
    if has_children || has_media {
        return (StatusCode::CONFLICT, Json(serde_json::json!({"error": "文件夹不为空"}))).into_response();
    }
    match db::delete_folder(&state.pool, &id).await {
        Ok(_) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => { tracing::error!("delete_folder: {e}"); StatusCode::INTERNAL_SERVER_ERROR.into_response() }
    }
}

// ── GET /v1/folders/{id}/ancestors ──

pub async fn get_ancestors(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let mut ancestors: Vec<serde_json::Value> = Vec::new();
    let mut current_id = Some(id);

    while let Some(ref cid) = current_id {
        match db::get_folder(&state.pool, cid).await {
            Ok(Some(row)) => {
                ancestors.push(serde_json::json!({"id": row.id, "name": row.name}));
                current_id = row.parent_id;
            }
            _ => break,
        }
    }
    ancestors.reverse();
    Json(ancestors).into_response()
}
