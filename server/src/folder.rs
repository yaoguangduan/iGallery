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
    pub has_password: bool,
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
        password_hash: None,
    };
    if let Err(e) = db::insert_folder(&state.pool, &row).await {
        tracing::error!("insert_folder: {e}");
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }

    let info = FolderInfo {
        id: row.id, name: row.name, parent_id: row.parent_id,
        cover_id: None, cover_media_type: None, item_count: 0,
        has_password: false,
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
                item_count: m.item_count, has_password: m.has_password,
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
                            item_count: m.item_count, has_password: m.has_password,
                            created_at: m.row.created_at, updated_at: m.row.updated_at,
                        }).into_response()
                    } else {
                        let has_pw = row.password_hash.is_some();
                        Json(FolderInfo {
                            id: row.id, name: row.name, parent_id: row.parent_id,
                            cover_id: None, cover_media_type: None, item_count: 0,
                            has_password: has_pw,
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
pub struct PatchBody {
    pub name: Option<String>,
    pub parent_id: Option<String>,
    pub password: Option<String>,
}

pub async fn patch_folder(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<PatchBody>,
) -> impl IntoResponse {
    if let Some(ref name) = body.name {
        let name = name.trim();
        if name.is_empty() {
            return (StatusCode::BAD_REQUEST, Json(serde_json::json!({"error": "name is required"}))).into_response();
        }
        match db::rename_folder(&state.pool, &id, name).await {
            Ok(true) => {}
            Ok(false) => return StatusCode::NOT_FOUND.into_response(),
            Err(e) => { tracing::error!("rename_folder: {e}"); return StatusCode::INTERNAL_SERVER_ERROR.into_response(); }
        }
    }
    if body.parent_id.is_some() {
        // "" means root (null parent_id), non-empty means a target folder
        let target = body.parent_id.as_deref().filter(|s| !s.is_empty());
        if let Some(pid) = target {
            if pid == id {
                return (StatusCode::BAD_REQUEST, Json(serde_json::json!({"error": "不能移动到自身"}))).into_response();
            }
            match db::get_folder(&state.pool, pid).await {
                Ok(None) => return (StatusCode::NOT_FOUND, Json(serde_json::json!({"error": "目标文件夹不存在"}))).into_response(),
                Err(e) => { tracing::error!("get_folder: {e}"); return StatusCode::INTERNAL_SERVER_ERROR.into_response(); }
                _ => {}
            }
            match db::is_descendant_of(&state.pool, pid, &id).await {
                Ok(true) => return (StatusCode::BAD_REQUEST, Json(serde_json::json!({"error": "不能移动到自己的子文件夹"}))).into_response(),
                Err(e) => { tracing::error!("is_descendant_of: {e}"); return StatusCode::INTERNAL_SERVER_ERROR.into_response(); }
                _ => {}
            }
        }
        match db::move_folder(&state.pool, &id, target).await {
            Ok(true) => {}
            Ok(false) => return StatusCode::NOT_FOUND.into_response(),
            Err(e) => { tracing::error!("move_folder: {e}"); return StatusCode::INTERNAL_SERVER_ERROR.into_response(); }
        }
    }
    if let Some(ref pw) = body.password {
        if pw.is_empty() {
            if let Err(e) = db::set_folder_password(&state.pool, &id, None).await {
                tracing::error!("clear_password: {e}");
                return StatusCode::INTERNAL_SERVER_ERROR.into_response();
            }
        } else {
            let pw_clone = pw.clone();
            let hash = match tokio::task::spawn_blocking(move || {
                bcrypt::hash(&pw_clone, bcrypt::DEFAULT_COST)
            }).await {
                Ok(Ok(h)) => h,
                _ => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
            };
            if let Err(e) = db::set_folder_password(&state.pool, &id, Some(&hash)).await {
                tracing::error!("set_password: {e}");
                return StatusCode::INTERNAL_SERVER_ERROR.into_response();
            }
        }
    }
    StatusCode::NO_CONTENT.into_response()
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
    // 非空也直接删：子树内的媒体逻辑删除、子文件夹一并移除（客户端弹确认）
    match db::delete_folder_tree(&state.pool, &id).await {
        Ok(_) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => { tracing::error!("delete_folder: {e}"); StatusCode::INTERNAL_SERVER_ERROR.into_response() }
    }
}

// ── POST /v1/folders/{id}/unlock ──

#[derive(serde::Deserialize)]
pub struct UnlockBody {
    pub password: String,
}

pub async fn unlock_folder(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<UnlockBody>,
) -> impl IntoResponse {
    let hash = match db::get_folder_password_hash(&state.pool, &id).await {
        Ok(Some(h)) => h,
        Ok(None) => return (StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "文件夹没有密码"}))).into_response(),
        Err(e) => { tracing::error!("unlock: {e}"); return StatusCode::INTERNAL_SERVER_ERROR.into_response(); }
    };
    let pw = body.password.clone();
    let valid = tokio::task::spawn_blocking(move || bcrypt::verify(&pw, &hash))
        .await.unwrap_or(Ok(false)).unwrap_or(false);
    // 密码错用 200 {unlocked:false} 表达，绝不用 401 —— 401/403 是客户端全局鉴权钩子
    // 判定"服务器 token 失效"的信号，会清空 token 并断连；文件夹密码错若也回 401，
    // 会把整个服务器鉴权一起搞挂（之后输对的 PIN 也因无 token 被中间件 401 而永远失败）。
    Json(serde_json::json!({"unlocked": valid})).into_response()
}

// ── GET /v1/folders/{id}/ancestors ──

pub async fn get_ancestors(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let mut ancestors: Vec<serde_json::Value> = Vec::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut current_id = Some(id);

    // seen 防环：脏数据造成 parent 互指时，没有这层保护会死循环把连接挂死。
    // 深度也封顶，正常目录层级远到不了 256。
    while let Some(ref cid) = current_id {
        if !seen.insert(cid.clone()) {
            tracing::warn!("folder ancestors: 检测到环，在 {cid} 处截断");
            break;
        }
        if ancestors.len() >= 256 {
            tracing::warn!("folder ancestors: 层级超过 256，截断");
            break;
        }
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
