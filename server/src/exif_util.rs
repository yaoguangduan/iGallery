use std::path::Path;

pub struct ExifData {
    pub taken_at: Option<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub orientation: Option<u32>,
    pub make: Option<String>,
    pub model: Option<String>,
    pub lens: Option<String>,
    pub focal_length: Option<f64>,
    pub aperture: Option<f64>,
    pub iso: Option<u32>,
    pub exposure: Option<String>,
    pub gps_lat: Option<f64>,
    pub gps_lng: Option<f64>,
}

pub fn extract(path: &Path) -> ExifData {
    let mut data = ExifData {
        taken_at: None, width: None, height: None, orientation: None,
        make: None, model: None, lens: None, focal_length: None,
        aperture: None, iso: None, exposure: None,
        gps_lat: None, gps_lng: None,
    };

    let file = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(_) => return data,
    };
    let mut buf = std::io::BufReader::new(file);
    let exif = match exif::Reader::new().read_from_container(&mut buf) {
        Ok(e) => e,
        Err(_) => return data,
    };

    data.taken_at = get_str(&exif, exif::Tag::DateTimeOriginal)
        .and_then(|s| parse_exif_datetime(&s));

    data.width = get_u32(&exif, exif::Tag::PixelXDimension)
        .or_else(|| get_u32(&exif, exif::Tag::ImageWidth));
    data.height = get_u32(&exif, exif::Tag::PixelYDimension)
        .or_else(|| get_u32(&exif, exif::Tag::ImageLength));
    data.orientation = get_u32(&exif, exif::Tag::Orientation);

    data.make = get_str(&exif, exif::Tag::Make);
    data.model = get_str(&exif, exif::Tag::Model);
    data.lens = get_str(&exif, exif::Tag::LensModel);

    if let Some(f) = exif.get_field(exif::Tag::FocalLength, exif::In::PRIMARY) {
        if let Some(r) = as_rational(&f.value) { data.focal_length = Some(r); }
    }
    if let Some(f) = exif.get_field(exif::Tag::FNumber, exif::In::PRIMARY) {
        if let Some(r) = as_rational(&f.value) { data.aperture = Some(r); }
    }
    data.iso = get_u32(&exif, exif::Tag::PhotographicSensitivity);
    if let Some(f) = exif.get_field(exif::Tag::ExposureTime, exif::In::PRIMARY) {
        data.exposure = Some(f.display_value().to_string().trim_matches('"').to_string());
    }

    data.gps_lat = extract_gps_coord(&exif, exif::Tag::GPSLatitude, exif::Tag::GPSLatitudeRef);
    data.gps_lng = extract_gps_coord(&exif, exif::Tag::GPSLongitude, exif::Tag::GPSLongitudeRef);

    data
}

fn get_str(exif: &exif::Exif, tag: exif::Tag) -> Option<String> {
    let f = exif.get_field(tag, exif::In::PRIMARY)?;
    let s = f.display_value().to_string();
    let s = s.trim().trim_matches('"').to_string();
    if s.is_empty() { None } else { Some(s) }
}

fn get_u32(exif: &exif::Exif, tag: exif::Tag) -> Option<u32> {
    let f = exif.get_field(tag, exif::In::PRIMARY)?;
    match &f.value {
        exif::Value::Long(v) => v.first().copied(),
        exif::Value::Short(v) => v.first().map(|x| *x as u32),
        _ => None,
    }
}

fn as_rational(v: &exif::Value) -> Option<f64> {
    match v {
        exif::Value::Rational(rs) => rs.first().map(|r| r.num as f64 / r.denom.max(1) as f64),
        _ => None,
    }
}

fn extract_gps_coord(exif: &exif::Exif, tag: exif::Tag, ref_tag: exif::Tag) -> Option<f64> {
    let f = exif.get_field(tag, exif::In::PRIMARY)?;
    let rs = match &f.value {
        exif::Value::Rational(rs) if rs.len() >= 3 => rs,
        _ => return None,
    };
    let deg = rs[0].num as f64 / rs[0].denom.max(1) as f64;
    let min = rs[1].num as f64 / rs[1].denom.max(1) as f64;
    let sec = rs[2].num as f64 / rs[2].denom.max(1) as f64;
    let mut coord = deg + min / 60.0 + sec / 3600.0;

    if let Some(rf) = exif.get_field(ref_tag, exif::In::PRIMARY) {
        let r = rf.display_value().to_string();
        if r.contains('S') || r.contains('W') { coord = -coord; }
    }
    Some(coord)
}

fn parse_exif_datetime(s: &str) -> Option<String> {
    let s = s.trim().trim_matches('"');
    if s.len() < 19 { return None; }
    let date_part = &s[..10];
    let time_part = &s[11..19];
    Some(format!("{}T{}", date_part.replace(':', "-"), time_part))
}
