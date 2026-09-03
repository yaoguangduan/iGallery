use image::imageops::FilterType;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const THUMB_SIZE: u32 = 300;

/// 外部工具最长执行时间。损坏/畸形的视频能让 ffmpeg 卡到天荒地老，
/// 而它跑在上传请求的链路上 —— 不设上限就是"上传永远不返回"。
const TOOL_TIMEOUT: Duration = Duration::from_secs(60);
/// 启动探测只是问一下版本号，给短一点
const PROBE_TIMEOUT: Duration = Duration::from_secs(5);

/// 等子进程结束，超时就杀掉。返回 None 表示超时被杀。
///
/// 用轮询而不是 wait_timeout crate：只多一个依赖不值当，
/// 100ms 的粒度对分钟级超时完全够用。
fn wait_with_timeout(mut child: Child, timeout: Duration, what: &str) -> Option<std::process::ExitStatus> {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Some(status),
            Ok(None) => {
                if Instant::now() >= deadline {
                    tracing::warn!("{what} 超过 {}s 未结束，已终止", timeout.as_secs());
                    let _ = child.kill();
                    let _ = child.wait();  // 回收僵尸进程
                    return None;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(e) => {
                tracing::warn!("{what} wait 失败: {e}");
                let _ = child.kill();
                return None;
            }
        }
    }
}

/// 启动时探一次 ffmpeg / ffprobe 在不在 PATH 上。
///
/// 二者都只靠 `Command::new("ffmpeg")` 走 PATH 解析（Windows 上 std 会自动补
/// `.exe`），所以装好 + 加进 PATH + 重启服务就够了，不需要改任何配置。
/// 缺了不会致命：视频照样能传能播，只是没有缩略图，
/// 时长/分辨率退回 mp4parse（只认 mp4/mov），creation_time 也拿不到。
/// 这条日志的意义是让没法在本机验证的人看一眼启动输出就知道装没装上。
pub fn probe_toolchain() {
    for tool in ["ffmpeg", "ffprobe"] {
        let ok = Command::new(tool)
            .arg("-version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .ok()
            .and_then(|c| wait_with_timeout(c, PROBE_TIMEOUT, tool))
            .map(|s| s.success())
            .unwrap_or(false);
        if ok {
            tracing::info!("  {tool}: OK");
        } else {
            tracing::warn!("  {tool}: 不在 PATH 上 —— 视频缩略图会缺失");
        }
    }
}

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
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .ok()
        .and_then(|c| wait_with_timeout(c, TOOL_TIMEOUT, "ffmpeg 抽帧"))
        .map(|s| s.success())
        .unwrap_or(false)
}

fn ffprobe_meta(src: &Path) -> Option<VideoMeta> {
    // 不能用 Command::output()：它内部会一直读到 EOF，等于绕过了超时。
    // 这里自己接管 stdout，超时先杀进程，再读已经写出来的部分。
    let mut child = Command::new("ffprobe")
        .args([
            "-v", "quiet",
            "-print_format", "json",
            "-show_format", "-show_streams",
            &src.to_string_lossy(),
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;

    let mut stdout = child.stdout.take()?;
    // 元数据 JSON 很小，先把管道读空避免写满阻塞子进程，再等退出
    let mut buf = Vec::new();
    let read_handle = std::thread::spawn(move || {
        use std::io::Read;
        let _ = stdout.read_to_end(&mut buf);
        buf
    });
    let status = wait_with_timeout(child, TOOL_TIMEOUT, "ffprobe 探测")?;
    if !status.success() { return None; }
    let out = read_handle.join().ok()?;

    let json: serde_json::Value = serde_json::from_slice(&out).ok()?;
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
