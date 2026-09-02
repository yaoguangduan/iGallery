use std::collections::HashMap;
use std::path::Path;

use async_zip::base::write::ZipFileWriter;
use async_zip::{Compression, ZipEntryBuilder};
use futures::stream::Stream;
use tokio::io::AsyncReadExt;
use tokio_util::io::ReaderStream;

use crate::sanitize::sanitize_filename;

/// 真正的流式 zip：blocking + async 混合，用 async_zip 通过 duplex pipe 一边写一边流出 (P3)
pub fn create_zip_stream(
    media_dir: &Path,
    files: &[(String, String)],
) -> impl Stream<Item = Result<bytes::Bytes, std::io::Error>> + Send {
    let media_dir = media_dir.to_path_buf();
    let files: Vec<(String, String)> = files.to_vec();

    let (read_half, write_half) = tokio::io::duplex(64 * 1024);

    tokio::spawn(async move {
        if let Err(e) = build_zip_streaming(&media_dir, &files, write_half).await {
            tracing::warn!("zip stream error: {e}");
        }
    });

    ReaderStream::new(read_half)
}

async fn build_zip_streaming(
    media_dir: &Path,
    files: &[(String, String)],
    writer: tokio::io::DuplexStream,
) -> std::io::Result<()> {
    let mut zip = ZipFileWriter::with_tokio(writer);
    let mut name_count: HashMap<String, usize> = HashMap::new();

    for (stored_name, original_name) in files {
        let path = media_dir.join(stored_name);
        if !path.exists() { continue; }

        let safe = sanitize_filename(original_name);
        let zip_name = dedup_filename(&safe, &mut name_count);

        let mut file = match tokio::fs::File::open(&path).await {
            Ok(f) => f,
            Err(e) => { tracing::warn!("zip open {stored_name}: {e}"); continue; }
        };

        // 图片/视频通常已压缩，用 Stored 更快
        let entry = ZipEntryBuilder::new(zip_name.into(), Compression::Stored).build();
        let mut entry_writer = match zip.write_entry_stream(entry).await {
            Ok(w) => w,
            Err(e) => { tracing::warn!("zip start {stored_name}: {e}"); continue; }
        };

        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let n = match file.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => n,
                Err(e) => { tracing::warn!("zip read {stored_name}: {e}"); break; }
            };
            if let Err(e) = futures::AsyncWriteExt::write_all(&mut entry_writer, &buf[..n]).await {
                tracing::warn!("zip write {stored_name}: {e}");
                break;
            }
        }
        if let Err(e) = entry_writer.close().await {
            tracing::warn!("zip close entry {stored_name}: {e}");
        }
    }

    zip.close().await.map_err(std::io::Error::other)?;
    Ok(())
}

fn dedup_filename(name: &str, counts: &mut HashMap<String, usize>) -> String {
    let entry = counts.entry(name.to_string()).or_insert(0);
    *entry += 1;
    if *entry == 1 { return name.to_string(); }
    let dot = name.rfind('.');
    let n = *entry - 1;
    match dot {
        Some(i) => format!("{}({}){}", &name[..i], n, &name[i..]),
        None => format!("{} ({})", name, n),
    }
}
