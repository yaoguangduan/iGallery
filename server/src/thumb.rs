use image::imageops::FilterType;
use std::path::Path;

const THUMB_SIZE: u32 = 300;

pub fn generate_thumbnail(src: &Path, dst: &Path) -> Result<(), String> {
    let img = image::open(src).map_err(|e| format!("failed to open image: {e}"))?;
    let thumb = img.resize_to_fill(THUMB_SIZE, THUMB_SIZE, FilterType::Lanczos3);
    thumb
        .save(dst)
        .map_err(|e| format!("failed to save thumbnail: {e}"))
}
