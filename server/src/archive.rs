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
        let entry = ZipEntryBuilder::new(zip_name.clone().into(), Compression::Stored).build();
        let mut entry_writer = match zip.write_entry_stream(entry).await {
            Ok(w) => w,
            Err(e) => { tracing::warn!("zip start {stored_name}: {e}"); continue; }
        };

        let mut buf = vec![0u8; 64 * 1024];
        let mut truncated = false;
        loop {
            let n = match file.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => n,
                Err(e) => {
                    tracing::warn!("zip read {stored_name}: {e}");
                    truncated = true;
                    break;
                }
            };
            if let Err(e) = futures::AsyncWriteExt::write_all(&mut entry_writer, &buf[..n]).await {
                tracing::warn!("zip write {stored_name}: {e}");
                truncated = true;
                break;
            }
        }
        if let Err(e) = entry_writer.close().await {
            tracing::warn!("zip close entry {stored_name}: {e}");
            truncated = true;
        }
        // 读到一半失败的条目会变成一个看似正常的坏文件。
        // 补一条 <名字>.INCOMPLETE.txt 说明，用户解压时一眼看到，
        // 而不是拿回一张打不开的图去猜。
        if truncated {
            let note_name = format!("{zip_name}.INCOMPLETE.txt");
            let note = format!(
                "文件 {zip_name} 在打包过程中读取失败，压缩包内的这份数据不完整，请重新下载。\n"
            );
            let entry = ZipEntryBuilder::new(note_name.into(), Compression::Stored).build();
            if let Ok(mut w) = zip.write_entry_stream(entry).await {
                let _ = futures::AsyncWriteExt::write_all(&mut w, note.as_bytes()).await;
                let _ = w.close().await;
            }
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
