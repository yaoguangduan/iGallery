// 统一北京时间 (UTC+8, 无夏令时)
use chrono::{DateTime, FixedOffset, TimeZone, Utc};

const CST_OFFSET_SECS: i32 = 8 * 3600;

pub fn beijing() -> FixedOffset {
    FixedOffset::east_opt(CST_OFFSET_SECS).unwrap()
}

pub fn now_rfc3339() -> String {
    Utc::now().with_timezone(&beijing()).to_rfc3339()
}

pub fn to_beijing_rfc3339(dt: DateTime<Utc>) -> String {
    dt.with_timezone(&beijing()).to_rfc3339()
}

pub fn parse_flexible(s: &str) -> Option<DateTime<FixedOffset>> {
    if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
        return Some(dt);
    }
    // 尝试 EXIF 风格 "2024-01-01T12:00:00"
    if let Ok(ndt) = chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S") {
        return Some(beijing().from_local_datetime(&ndt).single()?);
    }
    None
}
