// 文件名 / 扩展名 sanitize
// - ext: 只允许 [a-z0-9]{1,10}
// - filename (zip 用): 去掉路径分隔符、控制字符，避免 Zip Slip
// - disposition: RFC 5987 UTF-8 编码

pub fn sanitize_ext(raw: &str) -> String {
    let cleaned: String = raw
        .to_lowercase()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(10)
        .collect();
    if cleaned.is_empty() { "bin".to_string() } else { cleaned }
}

pub fn sanitize_filename(raw: &str) -> String {
    // 去掉路径部分，只保留 basename
    let base = raw
        .rsplit(|c| c == '/' || c == '\\')
        .next()
        .unwrap_or("file");

    // 过滤控制字符和危险字符
    let cleaned: String = base
        .chars()
        .filter(|c| !c.is_control() && *c != '\0')
        .collect();

    let trimmed = cleaned.trim().trim_matches('.');
    if trimmed.is_empty() || trimmed == "." || trimmed == ".." {
        "unnamed".to_string()
    } else if trimmed.len() > 200 {
        // 文件名过长截断，保留扩展名
        let dot = trimmed.rfind('.');
        match dot {
            Some(i) if trimmed.len() - i <= 12 => {
                let stem_end = 200 - (trimmed.len() - i);
                format!("{}{}", &trimmed[..stem_end], &trimmed[i..])
            }
            _ => trimmed.chars().take(200).collect(),
        }
    } else {
        trimmed.to_string()
    }
}

/// Content-Disposition 的 filename* (RFC 5987) + ASCII fallback filename
pub fn content_disposition(name: &str) -> String {
    let ascii: String = name
        .chars()
        .map(|c| if c.is_ascii_graphic() && c != '"' && c != '\\' { c } else { '_' })
        .collect();
    let encoded = percent_encode(name);
    format!(
        "attachment; filename=\"{ascii}\"; filename*=UTF-8''{encoded}"
    )
}

fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        // RFC 5987 unreserved + `%` 逃逸
        let ok = b.is_ascii_alphanumeric()
            || matches!(b, b'-' | b'.' | b'_' | b'~');
        if ok {
            out.push(b as char);
        } else {
            out.push('%');
            out.push_str(&format!("{b:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ext_only_alnum() {
        assert_eq!(sanitize_ext("JPG"), "jpg");
        assert_eq!(sanitize_ext("../evil"), "evil");
        assert_eq!(sanitize_ext(""), "bin");
        assert_eq!(sanitize_ext("verylongextension"), "verylongex");
    }

    #[test]
    fn filename_strips_path() {
        assert_eq!(sanitize_filename("../../etc/passwd"), "passwd");
        assert_eq!(sanitize_filename("normal.jpg"), "normal.jpg");
        assert_eq!(sanitize_filename(""), "unnamed");
        assert_eq!(sanitize_filename(".."), "unnamed");
        assert_eq!(sanitize_filename("a\r\nb.jpg"), "ab.jpg");
    }
}
