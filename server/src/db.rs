use serde::{Deserialize, Serialize};
use sqlx::{sqlite::SqlitePoolOptions, Row, SqlitePool};
use std::path::Path;

use crate::time::now_rfc3339;

// ── schema ──

pub async fn init_pool(data_dir: &Path) -> Result<SqlitePool, sqlx::Error> {
    let db_path = data_dir.join("gallery.db");
    let url = format!("sqlite:{}?mode=rwc", db_path.display());

    let pool = SqlitePoolOptions::new()
        .max_connections(16)
        .connect(&url)
        .await?;

    // SQLite 优化：WAL + NORMAL + 5s busy timeout
    sqlx::query("PRAGMA journal_mode=WAL").execute(&pool).await.ok();
    sqlx::query("PRAGMA synchronous=NORMAL").execute(&pool).await.ok();
    sqlx::query("PRAGMA busy_timeout=5000").execute(&pool).await.ok();
    sqlx::query("PRAGMA foreign_keys=ON").execute(&pool).await.ok();

    sqlx::query(SCHEMA).execute(&pool).await?;
    sqlx::query(FOLDERS_SCHEMA).execute(&pool).await?;

    // 一次性迁移：把历史 taken_at=NULL 的行补上 created_at。
    // 排序 NULLS LAST 会让 NULL 行永远沉底,用户看不见。幂等,再次启动是空扫。
    sqlx::query(
        "UPDATE media SET taken_at = created_at \
         WHERE taken_at IS NULL AND deleted_at IS NULL"
    ).execute(&pool).await.ok();

    for idx in INDEXES {
        sqlx::query(idx).execute(&pool).await.ok();
    }
    for idx in FOLDER_INDEXES {
        sqlx::query(idx).execute(&pool).await.ok();
    }

    Ok(pool)
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS media (
    id            TEXT PRIMARY KEY,
    filename      TEXT NOT NULL,
    ext           TEXT NOT NULL DEFAULT '',
    mime          TEXT NOT NULL,
    media_type    TEXT NOT NULL DEFAULT 'image',
    size          INTEGER NOT NULL DEFAULT 0,
    width         INTEGER,
    height        INTEGER,
    duration      REAL,
    orientation   INTEGER,

    taken_at      TEXT,
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL,
    deleted_at    TEXT,

    checksum      TEXT,

    exif_make     TEXT,
    exif_model    TEXT,
    exif_lens     TEXT,
    exif_focal_length REAL,
    exif_aperture REAL,
    exif_iso      INTEGER,
    exif_exposure TEXT,

    exif_gps_lat  REAL,
    exif_gps_lng  REAL,

    favorite      INTEGER NOT NULL DEFAULT 0,
    tags          TEXT NOT NULL DEFAULT '[]',
    notes         TEXT NOT NULL DEFAULT '',
    has_thumb     INTEGER NOT NULL DEFAULT 0,
    folder_id     TEXT
)";

const FOLDERS_SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS folders (
    id         TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    parent_id  TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
)";

const INDEXES: &[&str] = &[
    "CREATE INDEX IF NOT EXISTS idx_media_taken_at    ON media(taken_at)",
    "CREATE INDEX IF NOT EXISTS idx_media_created_at  ON media(created_at)",
    "CREATE INDEX IF NOT EXISTS idx_media_updated_at  ON media(updated_at)",
    "CREATE INDEX IF NOT EXISTS idx_media_deleted_at  ON media(deleted_at)",
    "CREATE INDEX IF NOT EXISTS idx_media_media_type  ON media(media_type)",
    "CREATE INDEX IF NOT EXISTS idx_media_mime        ON media(mime)",
    "CREATE INDEX IF NOT EXISTS idx_media_size        ON media(size)",
    "CREATE INDEX IF NOT EXISTS idx_media_ext         ON media(ext)",
    "CREATE INDEX IF NOT EXISTS idx_media_favorite    ON media(favorite)",
    "CREATE INDEX IF NOT EXISTS idx_media_checksum    ON media(checksum)",
    "CREATE INDEX IF NOT EXISTS idx_media_gps         ON media(exif_gps_lat, exif_gps_lng)",
    "CREATE INDEX IF NOT EXISTS idx_media_folder_id   ON media(folder_id)",
];

const FOLDER_INDEXES: &[&str] = &[
    "CREATE INDEX IF NOT EXISTS idx_folders_parent_id ON folders(parent_id)",
];

// ── row ──

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct MediaRow {
    pub id: String,
    pub filename: String,
    #[serde(default)]
    pub ext: String,
    pub mime: String,
    #[serde(default = "default_media_type")]
    pub media_type: String,
    pub size: i64,
    pub width: Option<i32>,
    pub height: Option<i32>,
    pub duration: Option<f64>,
    pub orientation: Option<i32>,
    pub taken_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub deleted_at: Option<String>,
    pub checksum: Option<String>,
    pub exif_make: Option<String>,
    pub exif_model: Option<String>,
    pub exif_lens: Option<String>,
    pub exif_focal_length: Option<f64>,
    pub exif_aperture: Option<f64>,
    pub exif_iso: Option<i32>,
    pub exif_exposure: Option<String>,
    pub exif_gps_lat: Option<f64>,
    pub exif_gps_lng: Option<f64>,
    pub favorite: i32,
    pub tags: String,
    pub notes: String,
    pub has_thumb: i32,
    pub folder_id: Option<String>,
}

fn default_media_type() -> String { "image".into() }

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct FolderRow {
    pub id: String,
    pub name: String,
    pub parent_id: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

// ── CRUD ──

pub const ALL_COLS: &str = "id,filename,ext,mime,media_type,size,width,height,duration,orientation,\
taken_at,created_at,updated_at,deleted_at,checksum,\
exif_make,exif_model,exif_lens,exif_focal_length,exif_aperture,exif_iso,exif_exposure,\
exif_gps_lat,exif_gps_lng,favorite,tags,notes,has_thumb,folder_id";

pub async fn insert_media(pool: &SqlitePool, r: &MediaRow) -> Result<(), sqlx::Error> {
    sqlx::query(&format!(
        "INSERT OR REPLACE INTO media ({ALL_COLS}) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
    ))
    .bind(&r.id).bind(&r.filename).bind(&r.ext).bind(&r.mime).bind(&r.media_type)
    .bind(r.size).bind(r.width).bind(r.height).bind(r.duration).bind(r.orientation)
    .bind(&r.taken_at).bind(&r.created_at).bind(&r.updated_at).bind(&r.deleted_at).bind(&r.checksum)
    .bind(&r.exif_make).bind(&r.exif_model).bind(&r.exif_lens).bind(r.exif_focal_length).bind(r.exif_aperture)
    .bind(r.exif_iso).bind(&r.exif_exposure)
    .bind(r.exif_gps_lat).bind(r.exif_gps_lng)
    .bind(r.favorite).bind(&r.tags).bind(&r.notes).bind(r.has_thumb).bind(&r.folder_id)
    .execute(pool).await?;
    Ok(())
}

pub async fn get_media(pool: &SqlitePool, id: &str) -> Result<Option<MediaRow>, sqlx::Error> {
    sqlx::query_as::<_, MediaRow>(&format!("SELECT {ALL_COLS} FROM media WHERE id = ?"))
        .bind(id)
        .fetch_optional(pool)
        .await
}

pub async fn soft_delete(pool: &SqlitePool, id: &str) -> Result<bool, sqlx::Error> {
    let now = now_rfc3339();
    let r = sqlx::query("UPDATE media SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL")
        .bind(&now).bind(&now).bind(id).execute(pool).await?;
    Ok(r.rows_affected() > 0)
}

pub async fn soft_delete_many(pool: &SqlitePool, ids: &[String]) -> Result<u64, sqlx::Error> {
    if ids.is_empty() { return Ok(0); }
    let mut total = 0u64;
    // SQLite 参数上限 999，分批
    for chunk in ids.chunks(500) {
        let placeholders = std::iter::repeat("?").take(chunk.len()).collect::<Vec<_>>().join(",");
        let now = now_rfc3339();
        let sql = format!(
            "UPDATE media SET deleted_at = ?, updated_at = ? WHERE deleted_at IS NULL AND id IN ({placeholders})"
        );
        let mut q = sqlx::query(&sql).bind(&now).bind(&now);
        for id in chunk { q = q.bind(id); }
        total += q.execute(pool).await?.rows_affected();
    }
    Ok(total)
}

pub async fn restore(pool: &SqlitePool, id: &str) -> Result<bool, sqlx::Error> {
    let now = now_rfc3339();
    let r = sqlx::query("UPDATE media SET deleted_at = NULL, updated_at = ? WHERE id = ? AND deleted_at IS NOT NULL")
        .bind(&now).bind(id).execute(pool).await?;
    Ok(r.rows_affected() > 0)
}

/// 强类型字段更新（防止 M4 的类型混乱）
#[derive(Debug, Default, Deserialize)]
#[serde(default)]
pub struct UpdateFields {
    pub filename: Option<String>,
    pub favorite: Option<bool>,
    pub tags: Option<serde_json::Value>,   // JSON 数组
    pub notes: Option<String>,
    /// null = 移到根；缺省 = 不改
    #[serde(skip_serializing_if = "Option::is_none")]
    pub folder_id: Option<Option<String>>,
}

impl UpdateFields {
    pub fn is_empty(&self) -> bool {
        self.filename.is_none()
            && self.favorite.is_none()
            && self.tags.is_none()
            && self.notes.is_none()
            && self.folder_id.is_none()
    }
}

pub async fn update_fields(pool: &SqlitePool, id: &str, f: &UpdateFields) -> Result<bool, sqlx::Error> {
    if f.is_empty() { return Ok(false); }

    let mut sets: Vec<&str> = Vec::new();
    if f.filename.is_some()  { sets.push("filename = ?"); }
    if f.favorite.is_some()  { sets.push("favorite = ?"); }
    if f.tags.is_some()      { sets.push("tags = ?"); }
    if f.notes.is_some()     { sets.push("notes = ?"); }
    if f.folder_id.is_some() { sets.push("folder_id = ?"); }
    sets.push("updated_at = ?");

    let sql = format!("UPDATE media SET {} WHERE id = ?", sets.join(", "));
    let mut q = sqlx::query(&sql);
    if let Some(v) = &f.filename { q = q.bind(v); }
    if let Some(v) = f.favorite  { q = q.bind(if v { 1i32 } else { 0i32 }); }
    if let Some(v) = &f.tags     { q = q.bind(v.to_string()); }
    if let Some(v) = &f.notes    { q = q.bind(v); }
    if let Some(v) = &f.folder_id { q = q.bind(v.as_deref()); }
    q = q.bind(now_rfc3339()).bind(id);
    let r = q.execute(pool).await?;
    Ok(r.rows_affected() > 0)
}

pub async fn find_by_checksum(pool: &SqlitePool, checksum: &str) -> Result<Option<MediaRow>, sqlx::Error> {
    sqlx::query_as::<_, MediaRow>(&format!(
        "SELECT {ALL_COLS} FROM media WHERE checksum = ? AND deleted_at IS NULL"
    )).bind(checksum).fetch_optional(pool).await
}

pub async fn list_all_checksums(pool: &SqlitePool) -> Result<Vec<String>, sqlx::Error> {
    let rows: Vec<(String,)> = sqlx::query_as(
        "SELECT checksum FROM media \
         WHERE checksum IS NOT NULL AND deleted_at IS NULL \
           AND length(checksum) = 32 AND checksum NOT GLOB '*[^0-9a-f]*'"
    ).fetch_all(pool).await?;
    Ok(rows.into_iter().map(|r| r.0).collect())
}

pub async fn list_legacy_checksums_after(
    pool: &SqlitePool,
    after_id: &str,
    limit: i64,
) -> Result<Vec<(String, String)>, sqlx::Error> {
    let rows: Vec<(String, String)> = sqlx::query_as(
        "SELECT id, ext FROM media \
         WHERE id > ? AND (checksum IS NULL OR length(checksum) != 32 \
           OR checksum GLOB '*[^0-9a-f]*') \
         ORDER BY id ASC LIMIT ?"
    ).bind(after_id).bind(limit).fetch_all(pool).await?;
    Ok(rows)
}

pub async fn set_checksum(pool: &SqlitePool, id: &str, checksum: &str) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE media SET checksum = ? WHERE id = ?")
        .bind(checksum).bind(id).execute(pool).await?;
    Ok(())
}

pub async fn count_active(pool: &SqlitePool) -> i64 {
    sqlx::query_as::<_, (i64,)>("SELECT COUNT(*) FROM media WHERE deleted_at IS NULL")
        .fetch_one(pool).await.map(|r| r.0).unwrap_or(0)
}

pub async fn total_size(pool: &SqlitePool) -> i64 {
    sqlx::query_as::<_, (i64,)>("SELECT COALESCE(SUM(size),0) FROM media WHERE deleted_at IS NULL")
        .fetch_one(pool).await.map(|r| r.0).unwrap_or(0)
}

// ── folder CRUD ──

pub async fn insert_folder(pool: &SqlitePool, r: &FolderRow) -> Result<(), sqlx::Error> {
    sqlx::query("INSERT INTO folders (id, name, parent_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)")
        .bind(&r.id).bind(&r.name).bind(&r.parent_id).bind(&r.created_at).bind(&r.updated_at)
        .execute(pool).await?;
    Ok(())
}

pub async fn get_folder(pool: &SqlitePool, id: &str) -> Result<Option<FolderRow>, sqlx::Error> {
    sqlx::query_as::<_, FolderRow>("SELECT id, name, parent_id, created_at, updated_at FROM folders WHERE id = ?")
        .bind(id).fetch_optional(pool).await
}

/// 一条 SQL 拿到 folder + cover + count，消灭 N+1 (P1)
#[derive(Debug, Clone, Serialize)]
pub struct FolderWithMeta {
    pub row: FolderRow,
    pub cover_id: Option<String>,
    pub cover_media_type: Option<String>,
    pub item_count: i64,
}

pub async fn list_folders_with_meta(
    pool: &SqlitePool,
    parent_id: Option<&str>,
) -> Result<Vec<FolderWithMeta>, sqlx::Error> {
    let sql = "
        SELECT
            f.id, f.name, f.parent_id, f.created_at, f.updated_at,
            (SELECT m.id FROM media m
                WHERE m.folder_id = f.id AND m.deleted_at IS NULL AND m.has_thumb = 1
                ORDER BY COALESCE(m.taken_at, m.created_at) DESC LIMIT 1) AS cover_id,
            (SELECT m.media_type FROM media m
                WHERE m.folder_id = f.id AND m.deleted_at IS NULL AND m.has_thumb = 1
                ORDER BY COALESCE(m.taken_at, m.created_at) DESC LIMIT 1) AS cover_media_type,
            (SELECT COUNT(*) FROM media m
                WHERE m.folder_id = f.id AND m.deleted_at IS NULL) AS item_count
        FROM folders f
        WHERE ";
    let where_clause = if parent_id.is_some() { "f.parent_id = ?" } else { "f.parent_id IS NULL" };
    let order = " ORDER BY f.name ASC";
    let full_sql = format!("{sql}{where_clause}{order}");

    let mut q = sqlx::query(&full_sql);
    if let Some(pid) = parent_id { q = q.bind(pid); }

    let rows = q.fetch_all(pool).await?;
    Ok(rows.into_iter().map(|row| FolderWithMeta {
        row: FolderRow {
            id: row.get("id"),
            name: row.get("name"),
            parent_id: row.get("parent_id"),
            created_at: row.get("created_at"),
            updated_at: row.get("updated_at"),
        },
        cover_id: row.get("cover_id"),
        cover_media_type: row.get("cover_media_type"),
        item_count: row.get("item_count"),
    }).collect())
}

pub async fn rename_folder(pool: &SqlitePool, id: &str, name: &str) -> Result<bool, sqlx::Error> {
    let now = now_rfc3339();
    let r = sqlx::query("UPDATE folders SET name = ?, updated_at = ? WHERE id = ?")
        .bind(name).bind(&now).bind(id).execute(pool).await?;
    Ok(r.rows_affected() > 0)
}

pub async fn move_folder(pool: &SqlitePool, id: &str, parent_id: Option<&str>) -> Result<bool, sqlx::Error> {
    let now = now_rfc3339();
    let r = sqlx::query("UPDATE folders SET parent_id = ?, updated_at = ? WHERE id = ?")
        .bind(parent_id).bind(&now).bind(id).execute(pool).await?;
    Ok(r.rows_affected() > 0)
}

pub async fn is_descendant_of(pool: &SqlitePool, folder_id: &str, ancestor_id: &str) -> Result<bool, sqlx::Error> {
    let mut current = Some(folder_id.to_string());
    let mut depth = 0;
    while let Some(ref cid) = current {
        if cid == ancestor_id { return Ok(true); }
        depth += 1;
        if depth > 256 { break; }
        match get_folder(pool, cid).await? {
            Some(row) => current = row.parent_id,
            None => break,
        }
    }
    Ok(false)
}

pub async fn delete_folder(pool: &SqlitePool, id: &str) -> Result<bool, sqlx::Error> {
    let r = sqlx::query("DELETE FROM folders WHERE id = ?")
        .bind(id).execute(pool).await?;
    Ok(r.rows_affected() > 0)
}

pub async fn folder_has_children(pool: &SqlitePool, id: &str) -> Result<bool, sqlx::Error> {
    let n: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM folders WHERE parent_id = ?")
        .bind(id).fetch_one(pool).await?;
    Ok(n.0 > 0)
}

pub async fn folder_has_media(pool: &SqlitePool, id: &str) -> Result<bool, sqlx::Error> {
    let n: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM media WHERE folder_id = ? AND deleted_at IS NULL")
        .bind(id).fetch_one(pool).await?;
    Ok(n.0 > 0)
}

/// batch move (R3)
pub async fn move_many(pool: &SqlitePool, ids: &[String], folder_id: Option<&str>) -> Result<u64, sqlx::Error> {
    if ids.is_empty() { return Ok(0); }
    let mut total = 0u64;
    for chunk in ids.chunks(500) {
        let placeholders = std::iter::repeat("?").take(chunk.len()).collect::<Vec<_>>().join(",");
        let now = now_rfc3339();
        let sql = format!(
            "UPDATE media SET folder_id = ?, updated_at = ? WHERE id IN ({placeholders})"
        );
        let mut q = sqlx::query(&sql).bind(folder_id).bind(&now);
        for id in chunk { q = q.bind(id); }
        total += q.execute(pool).await?.rows_affected();
    }
    Ok(total)
}

/// 批量设置收藏（R: favorite 0/1）
pub async fn set_favorite_many(pool: &SqlitePool, ids: &[String], favorite: bool) -> Result<u64, sqlx::Error> {
    if ids.is_empty() { return Ok(0); }
    let mut total = 0u64;
    let fav: i32 = if favorite { 1 } else { 0 };
    for chunk in ids.chunks(500) {
        let placeholders = std::iter::repeat("?").take(chunk.len()).collect::<Vec<_>>().join(",");
        let now = now_rfc3339();
        let sql = format!(
            "UPDATE media SET favorite = ?, updated_at = ? WHERE id IN ({placeholders})"
        );
        let mut q = sqlx::query(&sql).bind(fav).bind(&now);
        for id in chunk { q = q.bind(id); }
        total += q.execute(pool).await?.rows_affected();
    }
    Ok(total)
}

// ── 软删除物理清理（回收站到期）──

/// 找出删除时间早于 `before` 的条目 (id, ext)，供 purge_loop 删文件用
pub async fn select_purgeable(
    pool: &SqlitePool,
    before: &str,
    limit: i64,
) -> Result<Vec<(String, String)>, sqlx::Error> {
    sqlx::query_as::<_, (String, String)>(
        "SELECT id, ext FROM media WHERE deleted_at IS NOT NULL AND deleted_at < ? ORDER BY deleted_at ASC LIMIT ?",
    )
    .bind(before)
    .bind(limit)
    .fetch_all(pool)
    .await
}

/// 物理删除到期条目（只删仍处于已删除状态的，避免误删刚 restore 的）
pub async fn purge_ids(pool: &SqlitePool, rows: &[(String, String)]) -> Result<u64, sqlx::Error> {
    if rows.is_empty() { return Ok(0); }
    let mut total = 0u64;
    for chunk in rows.chunks(500) {
        let placeholders = std::iter::repeat("?").take(chunk.len()).collect::<Vec<_>>().join(",");
        let sql = format!("DELETE FROM media WHERE deleted_at IS NOT NULL AND id IN ({placeholders})");
        let mut q = sqlx::query(&sql);
        for (id, _) in chunk { q = q.bind(id); }
        total += q.execute(pool).await?.rows_affected();
    }
    Ok(total)
}

// ── flexible query with cursor pagination (R5) ──

const ALLOWED_FIELDS: &[&str] = &[
    "id","filename","ext","mime","media_type","size","width","height","duration",
    "orientation","taken_at","created_at","updated_at","deleted_at","checksum",
    "exif_make","exif_model","exif_lens","exif_focal_length","exif_aperture",
    "exif_iso","exif_exposure","exif_gps_lat","exif_gps_lng",
    "favorite","tags","notes","has_thumb","folder_id",
];

fn is_allowed_field(f: &str) -> bool { ALLOWED_FIELDS.contains(&f) }

#[derive(Debug, Deserialize)]
pub struct QueryRequest {
    #[serde(default)] pub filter: Option<FilterNode>,
    #[serde(default)] pub sort: Option<Vec<SortItem>>,
    /// page 分页 (兼容)
    #[serde(default)] pub page: Option<i64>,
    #[serde(default)] pub size: Option<i64>,
    /// cursor 分页 (推荐): base64(json({"v":<sort_value_or_null>,"id":"<id>"}))
    #[serde(default)] pub cursor: Option<String>,
    /// 是否需要 total（cursor 分页默认 false，减少一次 count 查询）
    #[serde(default)] pub with_total: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub enum FilterNode {
    Cond  { field: String, op: String, value: Option<serde_json::Value> },
    Group { #[serde(alias = "AND", alias = "and")] and: Option<Vec<FilterNode>>,
            #[serde(alias = "OR", alias = "or")]   or:  Option<Vec<FilterNode>> },
}

#[derive(Debug, Deserialize, Clone)]
pub struct SortItem {
    pub field: String,
    #[serde(default = "default_dir")] pub dir: String,
}
fn default_dir() -> String { "desc".into() }

pub struct BuiltQuery {
    pub sql: String,
    pub binds: Vec<serde_json::Value>,
}

pub fn build_filter(node: &FilterNode) -> Result<BuiltQuery, String> {
    match node {
        FilterNode::Group { and, or } => {
            let (items, joiner) = if let Some(items) = and { (items, " AND ") }
                else if let Some(items) = or { (items, " OR ") }
                else { return Ok(BuiltQuery { sql: "1=1".into(), binds: vec![] }); };

            let parts: Result<Vec<_>, _> = items.iter().map(build_filter).collect();
            let parts = parts?;
            let sqls: Vec<String> = parts.iter().map(|p| p.sql.clone()).collect();
            let binds: Vec<_> = parts.into_iter().flat_map(|p| p.binds).collect();
            Ok(BuiltQuery { sql: format!("({})", sqls.join(joiner)), binds })
        }
        FilterNode::Cond { field, op, value } => {
            if !is_allowed_field(field) {
                return Err(format!("unknown field: {field}"));
            }
            let op_lower = op.to_lowercase();
            match op_lower.as_str() {
                "=" | "!=" | ">" | "<" | ">=" | "<=" => {
                    let v = value.clone().unwrap_or(serde_json::Value::Null);
                    Ok(BuiltQuery { sql: format!("{field} {op_lower} ?"), binds: vec![v] })
                }
                "like" => {
                    let v = value.clone().unwrap_or(serde_json::Value::Null);
                    Ok(BuiltQuery { sql: format!("{field} LIKE ?"), binds: vec![v] })
                }
                "in" => {
                    if let Some(serde_json::Value::Array(arr)) = value {
                        let placeholders: Vec<&str> = arr.iter().map(|_| "?").collect();
                        Ok(BuiltQuery {
                            sql: format!("{field} IN ({})", placeholders.join(",")),
                            binds: arr.clone(),
                        })
                    } else { Err("'in' requires array value".into()) }
                }
                "between" => {
                    if let Some(serde_json::Value::Array(arr)) = value {
                        if arr.len() == 2 {
                            Ok(BuiltQuery { sql: format!("{field} BETWEEN ? AND ?"), binds: vec![arr[0].clone(), arr[1].clone()] })
                        } else { Err("'between' requires [low, high]".into()) }
                    } else { Err("'between' requires array".into()) }
                }
                "is_null" => Ok(BuiltQuery { sql: format!("{field} IS NULL"), binds: vec![] }),
                "is_not_null" => Ok(BuiltQuery { sql: format!("{field} IS NOT NULL"), binds: vec![] }),
                _ => Err(format!("unknown op: {op}")),
            }
        }
    }
}

fn bind_json<'a>(
    q: sqlx::query::QueryAs<'a, sqlx::Sqlite, MediaRow, sqlx::sqlite::SqliteArguments<'a>>,
    v: &'a serde_json::Value,
) -> sqlx::query::QueryAs<'a, sqlx::Sqlite, MediaRow, sqlx::sqlite::SqliteArguments<'a>> {
    match v {
        serde_json::Value::String(s) => q.bind(s.clone()),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() { q.bind(i) }
            else if let Some(f) = n.as_f64() { q.bind(f) }
            else { q.bind(n.to_string()) }
        }
        serde_json::Value::Bool(b) => q.bind(if *b { 1i32 } else { 0i32 }),
        serde_json::Value::Null => q.bind(Option::<String>::None),
        other => q.bind(other.to_string()),
    }
}

fn bind_json_count<'a>(
    q: sqlx::query::QueryAs<'a, sqlx::Sqlite, (i64,), sqlx::sqlite::SqliteArguments<'a>>,
    v: &'a serde_json::Value,
) -> sqlx::query::QueryAs<'a, sqlx::Sqlite, (i64,), sqlx::sqlite::SqliteArguments<'a>> {
    match v {
        serde_json::Value::String(s) => q.bind(s.clone()),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() { q.bind(i) }
            else if let Some(f) = n.as_f64() { q.bind(f) }
            else { q.bind(n.to_string()) }
        }
        serde_json::Value::Bool(b) => q.bind(if *b { 1i32 } else { 0i32 }),
        serde_json::Value::Null => q.bind(Option::<String>::None),
        other => q.bind(other.to_string()),
    }
}

#[derive(Debug, Serialize)]
pub struct QueryResult {
    pub items: Vec<MediaRow>,
    pub next_cursor: Option<String>,
    pub total: Option<i64>,
}

#[derive(Debug, Serialize, Deserialize)]
struct CursorPayload {
    /// primary sort field value (as JSON) — null 表示排序值为 NULL
    v: serde_json::Value,
    /// tie-breaker id
    id: String,
}

pub async fn query_media(pool: &SqlitePool, req: &QueryRequest) -> Result<QueryResult, String> {
    let size = req.size.unwrap_or(50).clamp(1, 500);

    // 排序：取首个合法字段作 primary；缺省用 COALESCE(taken_at, created_at) DESC
    let sorts: Vec<SortItem> = req.sort
        .clone()
        .unwrap_or_else(|| vec![SortItem { field: "taken_at".into(), dir: "desc".into() }])
        .into_iter()
        .filter(|s| is_allowed_field(&s.field))
        .collect();

    let (primary_field, primary_dir) = sorts.first()
        .map(|s| (s.field.clone(), if s.dir.to_lowercase() == "asc" { "ASC" } else { "DESC" }))
        .unwrap_or(("taken_at".to_string(), "DESC"));

    // where
    let (mut where_sql, where_binds) = match &req.filter {
        Some(f) => {
            let built = build_filter(f).map_err(|e| e)?;
            (built.sql, built.binds)
        }
        None => ("1=1".into(), vec![]),
    };

    // cursor: (primary_field, id) 之后
    let mut cursor_binds: Vec<serde_json::Value> = Vec::new();
    if let Some(cursor_str) = &req.cursor {
        // 坏游标直接报错，不要静默从第一页重来 —— 那样"加载更多"会出现重复内容，
        // 用户看不出问题在哪。客户端收到 400 后重置游标重新拉。
        let payload = decode_cursor(cursor_str)
            .ok_or_else(|| "invalid cursor".to_string())?;
        // 复合游标：(v, id) 大于/小于 (payload.v, payload.id)
        // 处理 NULL LAST：DESC 时 NULL 排最后 → 游标推进时需要 (v IS NOT NULL AND (v < ? OR (v = ? AND id < ?))) OR (v IS NULL AND primary IS NULL AND id < ?)
        // 简化：绝大多数场景 v 非 null；给 NULL 单独一分支
        let cmp = if primary_dir == "ASC" { ">" } else { "<" };
        let is_null_cursor = matches!(payload.v, serde_json::Value::Null);
        if is_null_cursor {
            // 已经在 NULL 段：只需 id 继续
            where_sql = format!("({where_sql}) AND ({primary_field} IS NULL AND id {cmp} ?)");
            cursor_binds.push(serde_json::Value::String(payload.id));
        } else {
            where_sql = format!(
                "({where_sql}) AND ((({primary_field} {cmp} ?) OR ({primary_field} = ? AND id {cmp} ?)) OR {primary_field} IS NULL)"
            );
            cursor_binds.push(payload.v.clone());
            cursor_binds.push(payload.v);
            cursor_binds.push(serde_json::Value::String(payload.id));
        }
    } else if let (Some(page), true) = (req.page, req.cursor.is_none()) {
        // page 分页兼容路径
        let page = page.max(1);
        let offset = (page - 1) * size;
        let order_parts: Vec<String> = sorts.iter().map(|s| {
            let dir = if s.dir.to_lowercase() == "asc" { "ASC" } else { "DESC" };
            format!("{} {} NULLS LAST", s.field, dir)
        }).collect();
        let order_sql = if order_parts.is_empty() {
            "COALESCE(taken_at, created_at) DESC".to_string()
        } else {
            format!("{}, id DESC", order_parts.join(", "))
        };

        let count_sql = format!("SELECT COUNT(*) FROM media WHERE {where_sql}");
        let data_sql = format!("SELECT {ALL_COLS} FROM media WHERE {where_sql} ORDER BY {order_sql} LIMIT ? OFFSET ?");

        let mut cq = sqlx::query_as::<_, (i64,)>(&count_sql);
        for v in &where_binds { cq = bind_json_count(cq, v); }
        let total = cq.fetch_one(pool).await.map_err(|e| e.to_string())?.0;

        let mut dq = sqlx::query_as::<_, MediaRow>(&data_sql);
        for v in &where_binds { dq = bind_json(dq, v); }
        dq = dq.bind(size).bind(offset);
        let items = dq.fetch_all(pool).await.map_err(|e| e.to_string())?;

        return Ok(QueryResult { items, next_cursor: None, total: Some(total) });
    }

    // cursor 分页
    // ORDER BY 用 (primary NULLS LAST, id DESC) 保证稳定顺序
    let order_sql = format!("{primary_field} {primary_dir} NULLS LAST, id DESC");

    let data_sql = format!(
        "SELECT {ALL_COLS} FROM media WHERE {where_sql} ORDER BY {order_sql} LIMIT ?"
    );

    let mut dq = sqlx::query_as::<_, MediaRow>(&data_sql);
    for v in &where_binds { dq = bind_json(dq, v); }
    for v in &cursor_binds { dq = bind_json(dq, v); }
    dq = dq.bind(size + 1); // 多取 1 判断 has_more

    let mut items = dq.fetch_all(pool).await.map_err(|e| e.to_string())?;

    let next_cursor = if items.len() > size as usize {
        items.pop();
        items.last().map(|last| encode_cursor(&CursorPayload {
            v: extract_field_value(last, &primary_field),
            id: last.id.clone(),
        }))
    } else {
        None
    };

    let total = if req.with_total.unwrap_or(false) {
        // where_sql 里可能已经拼进了 cursor 占位符，两组 bind 都要给，
        // 否则 SQLite 报参数数量不匹配（cursor + with_total 组合直接 400）
        let count_sql = format!("SELECT COUNT(*) FROM media WHERE {where_sql}");
        let mut cq = sqlx::query_as::<_, (i64,)>(&count_sql);
        for v in &where_binds { cq = bind_json_count(cq, v); }
        for v in &cursor_binds { cq = bind_json_count(cq, v); }
        Some(cq.fetch_one(pool).await.map_err(|e| e.to_string())?.0)
    } else {
        None
    };

    Ok(QueryResult { items, next_cursor, total })
}

fn encode_cursor(p: &CursorPayload) -> String {
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
    let json = serde_json::to_string(p).unwrap_or_default();
    URL_SAFE_NO_PAD.encode(json.as_bytes())
}

fn decode_cursor(s: &str) -> Option<CursorPayload> {
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
    let bytes = URL_SAFE_NO_PAD.decode(s).ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn extract_field_value(row: &MediaRow, field: &str) -> serde_json::Value {
    // 通过 serde 转 JSON 再取字段
    let v = serde_json::to_value(row).unwrap_or(serde_json::Value::Null);
    v.get(field).cloned().unwrap_or(serde_json::Value::Null)
}
