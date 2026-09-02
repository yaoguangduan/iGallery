use image::imageops::FilterType;
use std::path::Path;
use std::process::Command;

const THUMB_SIZE: u32 = 300;

pub fn generate_thumbnail(src: &Path, dst: &Path) -> Result<(), String> {
    let img = image::open(src).map_err(|e| format!("open image: {e}"))?;
    let thumb = img.resize_to_fill(THUMB_SIZE, THUMB_SIZE, FilterType::Lanczos3);
    thumb.save(dst).map_err(|e| format!("save thumbnail: {e}"))
}

pub struct VideoMeta {
    pub duration: Option<f64>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub thumb_ok: bool,
    pub taken_at: Option<String>,   // QuickTime creation_time → 北京时间 RFC3339
}

pub fn process_video(src: &Path, thumb_dst: &Path) -> VideoMeta {
    let mut meta = probe_mp4_native(src)
        .unwrap_or(VideoMeta { duration: None, width: None, height: None, thumb_ok: false, taken_at: None });

    meta.thumb_ok = ffmpeg_thumbnail(src, thumb_dst);

    if meta.duration.is_none() || meta.width.is_none() || meta.taken_at.is_none() {
        if let Some(probe) = ffprobe_meta(src) {
            if meta.duration.is_none() { meta.duration = probe.duration; }
            if meta.width.is_none() { meta.width = probe.width; meta.height = probe.height; }
            if meta.taken_at.is_none() { meta.taken_at = probe.taken_at; }
        }
    }

    meta
}

fn ffmpeg_thumbnail(src: &Path, dst: &Path) -> bool {
    Command::new("ffmpeg")
        .args([
            "-i", &src.to_string_lossy(),
            "-ss", "00:00:01",
            "-vframes", "1",
            "-vf", &format!("scale={THUMB_SIZE}:{THUMB_SIZE}:force_original_aspect_ratio=increase,crop={THUMB_SIZE}:{THUMB_SIZE}"),
            "-q:v", "2",
            "-y",
            &dst.to_string_lossy(),
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn ffprobe_meta(src: &Path) -> Option<VideoMeta> {
    let output = Command::new("ffprobe")
        .args([
            "-v", "quiet",
            "-print_format", "json",
            "-show_format", "-show_streams",
            &src.to_string_lossy(),
        ])
        .output()
        .ok()?;

    let json: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;
    let duration = json["format"]["duration"].as_str().and_then(|s| s.parse().ok());
    let mut width = None;
    let mut height = None;
    if let Some(streams) = json["streams"].as_array() {
        for s in streams {
            if s["codec_type"].as_str() == Some("video") {
                width = s["width"].as_u64().map(|v| v as u32);
                height = s["height"].as_u64().map(|v| v as u32);
                break;
            }
        }
    }
    let taken_at = json["format"]["tags"]["creation_time"].as_str()
        .and_then(|s| crate::time::parse_flexible(s))
        .map(|dt| dt.with_timezone(&crate::time::beijing()).to_rfc3339());
    Some(VideoMeta { duration, width, height, thumb_ok: false, taken_at })
}

fn probe_mp4_native(src: &Path) -> Option<VideoMeta> {
    let file = std::fs::File::open(src).ok()?;
    let mut reader = std::io::BufReader::new(file);
    let ctx = mp4parse::read_mp4(&mut reader).ok()?;

    let mut duration = None;
    let mut width = None;
    let mut height = None;
    // mp4parse 0.17 未暴露 creation_time；视频时间由 ffprobe 兜底

    if let Some(ref ts) = ctx.timescale {
        for track in &ctx.tracks {
            if track.track_type == mp4parse::TrackType::Video {
                if let Some(d) = track.duration {
                    duration = Some(d.0 as f64 / ts.0 as f64);
                }
                break;
            }
        }
    }
    for track in &ctx.tracks {
        if track.track_type == mp4parse::TrackType::Video {
            if let Some(ref tkhd) = track.tkhd {
                let w = (tkhd.width >> 16) as u32;
                let h = (tkhd.height >> 16) as u32;
                if w > 0 && h > 0 { width = Some(w); height = Some(h); }
            }
            break;
        }
    }
    Some(VideoMeta { duration, width, height, thumb_ok: false, taken_at: None })
}
