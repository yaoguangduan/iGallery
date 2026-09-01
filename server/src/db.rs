use serde::{Deserialize, Serialize};
use sqlx::{sqlite::SqlitePoolOptions, SqlitePool};
use std::path::Path;

// ── schema ──

pub async fn init_pool(data_dir: &Path) -> SqlitePool {
    let db_path = data_dir.join("gallery.db");
    let url = format!("sqlite:{}?mode=rwc", db_path.display());

    let pool = SqlitePoolOptions::new()
        .max_connections(4)
        .connect(&url)
        .await
        .expect("failed to connect to SQLite");

    sqlx::query(SCHEMA).execute(&pool).await.expect("failed to create table");

    for idx in INDEXES {
        sqlx::query(idx).execute(&pool).await.ok();
    }

    pool
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS media (
    id            TEXT PRIMARY KEY,
    filename      TEXT NOT NULL,
    ext           TEXT NOT NULL DEFAULT '',
    mime          TEXT NOT NULL,
    media_type    TEXT NOT NULL DEFAULT 'image',  -- image / video / audio / other
    size          INTEGER NOT NULL DEFAULT 0,
    width         INTEGER,
    height        INTEGER,
    duration      REAL,                           -- seconds (video/audio)
    orientation   INTEGER,                        -- EXIF 1-8

    taken_at      TEXT,                           -- capture time (EXIF > client mtime > upload)
    created_at    TEXT NOT NULL,                  -- upload time
    updated_at    TEXT NOT NULL,
    deleted_at    TEXT,                           -- soft delete: NULL = active

    checksum      TEXT,                           -- SHA256

    -- EXIF camera info
    exif_make     TEXT,
    exif_model    TEXT,
    exif_lens     TEXT,
    exif_focal_length REAL,                       -- mm
    exif_aperture REAL,                           -- f-number
    exif_iso      INTEGER,
    exif_exposure TEXT,                            -- e.g. '1/125'

    -- GPS
    exif_gps_lat  REAL,
    exif_gps_lng  REAL,

    -- user data
    favorite      INTEGER NOT NULL DEFAULT 0,     -- 0/1
    tags          TEXT NOT NULL DEFAULT '[]',      -- JSON array
    notes         TEXT NOT NULL DEFAULT '',
    has_thumb     INTEGER NOT NULL DEFAULT 0
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
];

// ── row ──

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaRow {
    pub id: String,
    pub filename: String,
    pub ext: String,
    pub mime: String,
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
}

impl sqlx::FromRow<'_, sqlx::sqlite::SqliteRow> for MediaRow {
    fn from_row(row: &sqlx::sqlite::SqliteRow) -> Result<Self, sqlx::Error> {
        use sqlx::Row;
        Ok(Self {
            id: row.try_get("id")?,
            filename: row.try_get("filename")?,
            ext: row.try_get::<String, _>("ext").unwrap_or_default(),
            mime: row.try_get("mime")?,
            media_type: row.try_get::<String, _>("media_type").unwrap_or_else(|_| "image".into()),
            size: row.try_get("size")?,
            width: row.try_get("width")?,
            height: row.try_get("height")?,
            duration: row.try_get("duration").ok(),
            orientation: row.try_get("orientation").ok(),
            taken_at: row.try_get("taken_at")?,
            created_at: row.try_get("created_at")?,
            updated_at: row.try_get::<String, _>("updated_at").unwrap_or_default(),
            deleted_at: row.try_get("deleted_at").ok().flatten(),
            checksum: row.try_get("checksum")?,
            exif_make: row.try_get("exif_make").ok().flatten(),
            exif_model: row.try_get("exif_model").ok().flatten(),
            exif_lens: row.try_get("exif_lens").ok().flatten(),
            exif_focal_length: row.try_get("exif_focal_length").ok().flatten(),
            exif_aperture: row.try_get("exif_aperture").ok().flatten(),
            exif_iso: row.try_get("exif_iso").ok().flatten(),
            exif_exposure: row.try_get("exif_exposure").ok().flatten(),
            exif_gps_lat: row.try_get("exif_gps_lat").ok().flatten(),
            exif_gps_lng: row.try_get("exif_gps_lng").ok().flatten(),
            favorite: row.try_get::<i32, _>("favorite").unwrap_or(0),
            tags: row.try_get::<String, _>("tags").unwrap_or_else(|_| "[]".into()),
            notes: row.try_get::<String, _>("notes").unwrap_or_default(),
            has_thumb: row.try_get::<i32, _>("has_thumb").unwrap_or(0),
        })
    }
}

// ── CRUD ──

const ALL_COLS: &str = "id,filename,ext,mime,media_type,size,width,height,duration,orientation,\
taken_at,created_at,updated_at,deleted_at,checksum,\
exif_make,exif_model,exif_lens,exif_focal_length,exif_aperture,exif_iso,exif_exposure,\
exif_gps_lat,exif_gps_lng,favorite,tags,notes,has_thumb";

pub async fn insert_media(pool: &SqlitePool, r: &MediaRow) {
    sqlx::query(&format!(
        "INSERT OR REPLACE INTO media ({ALL_COLS}) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
    ))
    .bind(&r.id).bind(&r.filename).bind(&r.ext).bind(&r.mime).bind(&r.media_type)
    .bind(r.size).bind(r.width).bind(r.height).bind(r.duration).bind(r.orientation)
    .bind(&r.taken_at).bind(&r.created_at).bind(&r.updated_at).bind(&r.deleted_at).bind(&r.checksum)
    .bind(&r.exif_make).bind(&r.exif_model).bind(&r.exif_lens).bind(r.exif_focal_length).bind(r.exif_aperture)
    .bind(r.exif_iso).bind(&r.exif_exposure)
    .bind(r.exif_gps_lat).bind(r.exif_gps_lng)
    .bind(r.favorite).bind(&r.tags).bind(&r.notes).bind(r.has_thumb)
    .execute(pool).await.expect("insert failed");
}

pub async fn get_media(pool: &SqlitePool, id: &str) -> Option<MediaRow> {
    sqlx::query_as::<_, MediaRow>(&format!("SELECT {ALL_COLS} FROM media WHERE id = ?"))
        .bind(id).fetch_optional(pool).await.ok().flatten()
}

pub async fn soft_delete(pool: &SqlitePool, id: &str) -> bool {
    let now = chrono::Utc::now().to_rfc3339();
    let r = sqlx::query("UPDATE media SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL")
        .bind(&now).bind(&now).bind(id).execute(pool).await;
    matches!(r, Ok(r) if r.rows_affected() > 0)
}

pub async fn hard_delete(pool: &SqlitePool, id: &str) -> bool {
    let r = sqlx::query("DELETE FROM media WHERE id = ?")
        .bind(id).execute(pool).await;
    matches!(r, Ok(r) if r.rows_affected() > 0)
}

pub async fn restore(pool: &SqlitePool, id: &str) -> bool {
    let now = chrono::Utc::now().to_rfc3339();
    let r = sqlx::query("UPDATE media SET deleted_at = NULL, updated_at = ? WHERE id = ? AND deleted_at IS NOT NULL")
        .bind(&now).bind(id).execute(pool).await;
    matches!(r, Ok(r) if r.rows_affected() > 0)
}

pub async fn update_fields(pool: &SqlitePool, id: &str, sets: &[(String, String)]) -> bool {
    if sets.is_empty() { return false; }
    let assigns: Vec<String> = sets.iter().map(|(k, _)| format!("{k} = ?")).collect();
    let now = chrono::Utc::now().to_rfc3339();
    let sql = format!("UPDATE media SET {}, updated_at = ? WHERE id = ?", assigns.join(", "));
    let mut q = sqlx::query(&sql);
    for (_, v) in sets { q = q.bind(v); }
    q = q.bind(&now).bind(id);
    let r = q.execute(pool).await;
    matches!(r, Ok(r) if r.rows_affected() > 0)
}

pub async fn find_by_checksum(pool: &SqlitePool, checksum: &str) -> Option<MediaRow> {
    sqlx::query_as::<_, MediaRow>(&format!(
        "SELECT {ALL_COLS} FROM media WHERE checksum = ? AND deleted_at IS NULL"
    )).bind(checksum).fetch_optional(pool).await.ok().flatten()
}

pub async fn count_active(pool: &SqlitePool) -> i64 {
    sqlx::query_as::<_, (i64,)>("SELECT COUNT(*) FROM media WHERE deleted_at IS NULL")
        .fetch_one(pool).await.map(|r| r.0).unwrap_or(0)
}

pub async fn total_size(pool: &SqlitePool) -> i64 {
    sqlx::query_as::<_, (i64,)>("SELECT COALESCE(SUM(size),0) FROM media WHERE deleted_at IS NULL")
        .fetch_one(pool).await.map(|r| r.0).unwrap_or(0)
}

// ── flexible query ──

const ALLOWED_FIELDS: &[&str] = &[
    "id","filename","ext","mime","media_type","size","width","height","duration",
    "orientation","taken_at","created_at","updated_at","deleted_at","checksum",
    "exif_make","exif_model","exif_lens","exif_focal_length","exif_aperture",
    "exif_iso","exif_exposure","exif_gps_lat","exif_gps_lng",
    "favorite","tags","notes","has_thumb",
];

fn is_allowed_field(f: &str) -> bool {
    ALLOWED_FIELDS.contains(&f)
}

#[derive(Debug, Deserialize)]
pub struct QueryRequest {
    #[serde(default)]
    pub filter: Option<FilterNode>,
    #[serde(default)]
    pub sort: Option<Vec<SortItem>>,
    #[serde(default = "default_page")]
    pub page: i64,
    #[serde(default = "default_size")]
    pub size: i64,
}
fn default_page() -> i64 { 1 }
fn default_size() -> i64 { 50 }

#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub enum FilterNode {
    Group { #[serde(alias = "AND", alias = "and")] and: Option<Vec<FilterNode>>,
            #[serde(alias = "OR", alias = "or")]   or: Option<Vec<FilterNode>> },
    Cond  { field: String, op: String, value: Option<serde_json::Value> },
}

#[derive(Debug, Deserialize)]
pub struct SortItem {
    pub field: String,
    #[serde(default = "default_dir")]
    pub dir: String,
}
fn default_dir() -> String { "desc".into() }

pub struct BuiltQuery {
    pub sql: String,
    pub binds: Vec<String>,
}

pub fn build_filter(node: &FilterNode) -> Result<BuiltQuery, String> {
    match node {
        FilterNode::Group { and, or } => {
            if let Some(items) = and {
                let parts: Result<Vec<BuiltQuery>, String> = items.iter().map(build_filter).collect();
                let parts = parts?;
                let sqls: Vec<String> = parts.iter().map(|p| p.sql.clone()).collect();
                let binds: Vec<String> = parts.into_iter().flat_map(|p| p.binds).collect();
                Ok(BuiltQuery { sql: format!("({})", sqls.join(" AND ")), binds })
            } else if let Some(items) = or {
                let parts: Result<Vec<BuiltQuery>, String> = items.iter().map(build_filter).collect();
                let parts = parts?;
                let sqls: Vec<String> = parts.iter().map(|p| p.sql.clone()).collect();
                let binds: Vec<String> = parts.into_iter().flat_map(|p| p.binds).collect();
                Ok(BuiltQuery { sql: format!("({})", sqls.join(" OR ")), binds })
            } else {
                Ok(BuiltQuery { sql: "1=1".into(), binds: vec![] })
            }
        }
        FilterNode::Cond { field, op, value } => {
            if !is_allowed_field(field) {
                return Err(format!("unknown field: {field}"));
            }
            let op_lower = op.to_lowercase();
            match op_lower.as_str() {
                "=" | "!=" | ">" | "<" | ">=" | "<=" => {
                    let v = value.as_ref().map(json_to_string).unwrap_or_default();
                    Ok(BuiltQuery { sql: format!("{field} {op_lower} ?"), binds: vec![v] })
                }
                "like" => {
                    let v = value.as_ref().map(json_to_string).unwrap_or_default();
                    Ok(BuiltQuery { sql: format!("{field} LIKE ?"), binds: vec![v] })
                }
                "in" => {
                    if let Some(serde_json::Value::Array(arr)) = value {
                        let placeholders: Vec<&str> = arr.iter().map(|_| "?").collect();
                        let binds: Vec<String> = arr.iter().map(json_to_string).collect();
                        Ok(BuiltQuery { sql: format!("{field} IN ({})", placeholders.join(",")), binds })
                    } else {
                        Err("'in' requires array value".into())
                    }
                }
                "between" => {
                    if let Some(serde_json::Value::Array(arr)) = value {
                        if arr.len() == 2 {
                            let binds = vec![json_to_string(&arr[0]), json_to_string(&arr[1])];
                            Ok(BuiltQuery { sql: format!("{field} BETWEEN ? AND ?"), binds })
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

fn json_to_string(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Number(n) => n.to_string(),
        serde_json::Value::Bool(b) => if *b { "1".into() } else { "0".into() },
        serde_json::Value::Null => String::new(),
        other => other.to_string(),
    }
}

pub async fn query_media(pool: &SqlitePool, req: &QueryRequest) -> Result<(Vec<MediaRow>, i64), String> {
    let page = req.page.max(1);
    let size = req.size.clamp(1, 500);
    let offset = (page - 1) * size;

    let where_sql = if let Some(ref filter) = req.filter {
        let built = build_filter(filter)?;
        (built.sql, built.binds)
    } else {
        ("1=1".into(), vec![])
    };

    let order_sql = if let Some(ref sorts) = req.sort {
        let parts: Vec<String> = sorts.iter().filter_map(|s| {
            if !is_allowed_field(&s.field) { return None; }
            let dir = if s.dir.to_lowercase() == "asc" { "ASC" } else { "DESC" };
            Some(format!("{} {} NULLS LAST", s.field, dir))
        }).collect();
        if parts.is_empty() { "COALESCE(taken_at, created_at) DESC".into() }
        else { parts.join(", ") }
    } else {
        "COALESCE(taken_at, created_at) DESC".into()
    };

    let count_sql = format!("SELECT COUNT(*) FROM media WHERE {}", where_sql.0);
    let data_sql = format!(
        "SELECT {ALL_COLS} FROM media WHERE {} ORDER BY {} LIMIT ? OFFSET ?",
        where_sql.0, order_sql
    );

    let mut cq = sqlx::query_as::<_, (i64,)>(&count_sql);
    for v in &where_sql.1 { cq = cq.bind(v); }
    let total = cq.fetch_one(pool).await.map(|r| r.0).unwrap_or(0);

    let mut dq = sqlx::query_as::<_, MediaRow>(&data_sql);
    for v in &where_sql.1 { dq = dq.bind(v); }
    dq = dq.bind(size).bind(offset);
    let rows = dq.fetch_all(pool).await.unwrap_or_default();

    Ok((rows, total))
}
