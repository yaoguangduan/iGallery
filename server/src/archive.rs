use std::collections::HashMap;
use std::io::Write;
use std::path::Path;
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

pub fn create_zip(
    media_dir: &Path,
    files: &[(String, String)], // (uuid.ext, original_filename)
) -> Result<Vec<u8>, String> {
    let mut buf = Vec::new();
    {
        let mut writer = ZipWriter::new(std::io::Cursor::new(&mut buf));
        let options = SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);

        let mut name_count: HashMap<String, usize> = HashMap::new();

        for (stored_name, original_name) in files {
            let path = media_dir.join(stored_name);
            if !path.exists() {
                continue;
            }

            let zip_name = dedup_filename(original_name, &mut name_count);
            let data = std::fs::read(&path).map_err(|e| format!("read {stored_name}: {e}"))?;

            writer
                .start_file(&zip_name, options)
                .map_err(|e| format!("zip start: {e}"))?;
            writer
                .write_all(&data)
                .map_err(|e| format!("zip write: {e}"))?;
        }

        writer.finish().map_err(|e| format!("zip finish: {e}"))?;
    }
    Ok(buf)
}

fn dedup_filename(name: &str, counts: &mut HashMap<String, usize>) -> String {
    let entry = counts.entry(name.to_string()).or_insert(0);
    *entry += 1;
    if *entry == 1 {
        return name.to_string();
    }
    let dot = name.rfind('.');
    let n = *entry - 1;
    match dot {
        Some(i) => format!("{}({}){}", &name[..i], n, &name[i..]),
        None => format!("{} ({})", name, n),
    }
}
