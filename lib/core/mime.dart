import 'package:http_parser/http_parser.dart';

/// 双端一致的 mime 猜测 (C6)
MediaType? guessMime(String filename) {
  final ext = filename.split('.').last.toLowerCase();
  return switch (ext) {
    'jpg' || 'jpeg' => MediaType('image', 'jpeg'),
    'png'  => MediaType('image', 'png'),
    'gif'  => MediaType('image', 'gif'),
    'webp' => MediaType('image', 'webp'),
    'heic' || 'heif' => MediaType('image', 'heic'),
    'bmp'  => MediaType('image', 'bmp'),
    'tiff' || 'tif' => MediaType('image', 'tiff'),
    'mp4'  => MediaType('video', 'mp4'),
    'mov'  => MediaType('video', 'quicktime'),
    'avi'  => MediaType('video', 'x-msvideo'),
    'mkv'  => MediaType('video', 'x-matroska'),
    'webm' => MediaType('video', 'webm'),
    'm4a'  => MediaType('audio', 'mp4'),
    'mp3'  => MediaType('audio', 'mpeg'),
    'flac' => MediaType('audio', 'flac'),
    _ => null,
  };
}

bool isImageExt(String ext) {
  const s = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', 'tiff', 'tif'};
  return s.contains(ext.toLowerCase());
}

bool isVideoExt(String ext) {
  const s = {'mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v'};
  return s.contains(ext.toLowerCase());
}
