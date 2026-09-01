import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:path_provider/path_provider.dart';

import 'server_state.dart';

class MediaItem {
  final String id;
  final String filename;
  final String ext;
  final String mime;
  final String mediaType;
  final int size;
  final int? width;
  final int? height;
  final double? duration;
  final int? orientation;
  final String? takenAt;
  final String createdAt;
  final String updatedAt;
  final String? deletedAt;
  final String? exifMake;
  final String? exifModel;
  final double? exifGpsLat;
  final double? exifGpsLng;
  final int favorite;
  final String tags;
  final String notes;

  MediaItem({
    required this.id, required this.filename, required this.ext,
    required this.mime, required this.mediaType, required this.size,
    this.width, this.height, this.duration, this.orientation,
    this.takenAt, required this.createdAt, required this.updatedAt,
    this.deletedAt, this.exifMake, this.exifModel,
    this.exifGpsLat, this.exifGpsLng,
    this.favorite = 0, this.tags = '[]', this.notes = '',
  });

  bool get isVideo => mediaType == 'video';
  bool get isImage => mediaType == 'image';
  bool get isFavorite => favorite == 1;
  String get displayDate => takenAt ?? createdAt;

  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
    id: j['id'] as String,
    filename: j['filename'] as String,
    ext: j['ext'] as String? ?? '',
    mime: j['mime'] as String,
    mediaType: j['media_type'] as String? ?? 'image',
    size: j['size'] as int,
    width: j['width'] as int?,
    height: j['height'] as int?,
    duration: (j['duration'] as num?)?.toDouble(),
    orientation: j['orientation'] as int?,
    takenAt: j['taken_at'] as String?,
    createdAt: j['created_at'] as String,
    updatedAt: j['updated_at'] as String? ?? '',
    deletedAt: j['deleted_at'] as String?,
    exifMake: j['exif_make'] as String?,
    exifModel: j['exif_model'] as String?,
    exifGpsLat: (j['exif_gps_lat'] as num?)?.toDouble(),
    exifGpsLng: (j['exif_gps_lng'] as num?)?.toDouble(),
    favorite: j['favorite'] as int? ?? 0,
    tags: j['tags'] as String? ?? '[]',
    notes: j['notes'] as String? ?? '',
  );
}

class PageResult {
  final List<MediaItem> items;
  final int total;
  final int page;
  final int size;
  PageResult({required this.items, required this.total, required this.page, required this.size});
}

class MediaService {
  final ServerState _state;
  MediaService(this._state);

  String get _base => _state.baseUrl;
  String thumbUrl(String id) => '$_base/v1/media/$id/thumb';
  String fullUrl(String id) => '$_base/v1/media/$id';

  /// PocketBase-style query
  Future<PageResult> query({
    int page = 1,
    int size = 50,
    Map<String, dynamic>? filter,
    List<Map<String, String>>? sort,
  }) async {
    final body = <String, dynamic>{
      'page': page,
      'size': size,
    };
    if (filter != null) body['filter'] = filter;
    if (sort != null) body['sort'] = sort;

    final resp = await http.post(
      Uri.parse('$_base/v1/media/query'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) throw Exception('query failed: ${resp.statusCode} ${resp.body}');

    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (json['items'] as List)
        .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
    return PageResult(
      items: items,
      total: json['total'] as int,
      page: json['page'] as int,
      size: json['size'] as int,
    );
  }

  Future<List<MediaItem>> upload(
    List<File> files, {
    void Function(int completed, int total)? onProgress,
  }) async {
    final uploaded = <MediaItem>[];
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final request = http.MultipartRequest('POST', Uri.parse('$_base/v1/media/upload'));
      final filename = file.path.split(Platform.pathSeparator).last;
      final mimeType = _guessMime(filename);
      request.files.add(await http.MultipartFile.fromPath('file', file.path, filename: filename, contentType: mimeType));
      try {
        final stat = await file.stat();
        request.fields['taken_at'] = stat.modified.toIso8601String();
      } catch (_) {}
      final response = await request.send();
      final body = await response.stream.bytesToString();
      if (response.statusCode == 200) {
        final list = jsonDecode(body) as List;
        for (final item in list) uploaded.add(MediaItem.fromJson(item as Map<String, dynamic>));
      }
      onProgress?.call(i + 1, files.length);
    }
    return uploaded;
  }

  Future<Uint8List> downloadBytes(String id) async {
    final resp = await http.get(Uri.parse('$_base/v1/media/$id'));
    if (resp.statusCode != 200) throw Exception('download failed: ${resp.statusCode}');
    return resp.bodyBytes;
  }

  Future<MediaItem?> uploadBytes({
    required Uint8List bytes,
    required String filename,
    String? takenAt,
  }) async {
    final request = http.MultipartRequest('POST', Uri.parse('$_base/v1/media/upload'));
    final ext = filename.split('.').last.toLowerCase();
    final mime = _guessMime(filename);
    request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename, contentType: mime));
    if (takenAt != null) request.fields['taken_at'] = takenAt;
    final response = await request.send();
    final body = await response.stream.bytesToString();
    if (response.statusCode == 200) {
      final list = jsonDecode(body) as List;
      if (list.isNotEmpty) return MediaItem.fromJson(list[0] as Map<String, dynamic>);
    }
    return null;
  }

  Future<void> delete(String id) async {
    await http.delete(Uri.parse('$_base/v1/media/$id'));
  }

  Future<void> batchDelete(List<String> ids) async {
    await http.post(Uri.parse('$_base/v1/media/batch-delete'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode({'ids': ids}));
  }

  Future<void> restore(String id) async {
    await http.post(Uri.parse('$_base/v1/media/$id/restore'));
  }

  Future<void> updateFields(String id, Map<String, dynamic> fields) async {
    await http.patch(Uri.parse('$_base/v1/media/$id'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode(fields));
  }

  Future<File> downloadBatch(List<String> ids) async {
    final resp = await http.post(Uri.parse('$_base/v1/media/download'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode({'ids': ids}));
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/igallery.zip');
    await file.writeAsBytes(resp.bodyBytes);
    return file;
  }

  Future<ServerStats> fetchInfo() async {
    final resp = await http.get(Uri.parse('$_base/v1/info'));
    if (resp.statusCode != 200) throw Exception('info failed: ${resp.statusCode}');
    return ServerStats.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  MediaType? _guessMime(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => MediaType('image', 'jpeg'),
      'png' => MediaType('image', 'png'),
      'gif' => MediaType('image', 'gif'),
      'webp' => MediaType('image', 'webp'),
      'heic' || 'heif' => MediaType('image', 'heic'),
      'mp4' => MediaType('video', 'mp4'),
      'mov' => MediaType('video', 'quicktime'),
      'avi' => MediaType('video', 'x-msvideo'),
      _ => null,
    };
  }
}
