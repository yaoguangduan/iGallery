import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;

import 'api.dart';
import 'mime.dart';
import 'server_state.dart';
import 'time_fmt.dart';

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
  final String? checksum;
  final String? exifMake;
  final String? exifModel;
  final double? exifGpsLat;
  final double? exifGpsLng;
  final int favorite;
  final String tags;
  final String notes;
  final String? folderId;
  final int hasThumb;

  MediaItem({
    required this.id, required this.filename, required this.ext,
    required this.mime, required this.mediaType, required this.size,
    this.width, this.height, this.duration, this.orientation,
    this.takenAt, required this.createdAt, required this.updatedAt,
    this.deletedAt, this.checksum, this.exifMake, this.exifModel,
    this.exifGpsLat, this.exifGpsLng,
    this.favorite = 0, this.tags = '[]', this.notes = '',
    this.folderId, this.hasThumb = 1,
  });

  bool get isVideo => mediaType == 'video';
  bool get isImage => mediaType == 'image';
  bool get isFavorite => favorite == 1;
  String get displayDate => takenAt ?? createdAt;

  MediaItem copyWith({
    String? filename,
    int? favorite,
    String? tags,
    String? notes,
    String? folderId,
    bool clearFolderId = false,
  }) => MediaItem(
    id: id, filename: filename ?? this.filename, ext: ext,
    mime: mime, mediaType: mediaType, size: size,
    width: width, height: height, duration: duration, orientation: orientation,
    takenAt: takenAt, createdAt: createdAt, updatedAt: updatedAt,
    deletedAt: deletedAt, checksum: checksum,
    exifMake: exifMake, exifModel: exifModel,
    exifGpsLat: exifGpsLat, exifGpsLng: exifGpsLng,
    favorite: favorite ?? this.favorite,
    tags: tags ?? this.tags,
    notes: notes ?? this.notes,
    folderId: clearFolderId ? null : (folderId ?? this.folderId),
    hasThumb: hasThumb,
  );

  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
    id: j['id'] as String,
    filename: j['filename'] as String,
    ext: j['ext'] as String? ?? '',
    mime: j['mime'] as String,
    mediaType: j['media_type'] as String? ?? 'image',
    size: (j['size'] as num).toInt(),
    width: (j['width'] as num?)?.toInt(),
    height: (j['height'] as num?)?.toInt(),
    duration: (j['duration'] as num?)?.toDouble(),
    orientation: (j['orientation'] as num?)?.toInt(),
    takenAt: j['taken_at'] as String?,
    createdAt: j['created_at'] as String,
    updatedAt: j['updated_at'] as String? ?? '',
    deletedAt: j['deleted_at'] as String?,
    checksum: j['checksum'] as String?,
    exifMake: j['exif_make'] as String?,
    exifModel: j['exif_model'] as String?,
    exifGpsLat: (j['exif_gps_lat'] as num?)?.toDouble(),
    exifGpsLng: (j['exif_gps_lng'] as num?)?.toDouble(),
    favorite: (j['favorite'] as num?)?.toInt() ?? 0,
    tags: j['tags'] as String? ?? '[]',
    notes: j['notes'] as String? ?? '',
    folderId: j['folder_id'] as String?,
    hasThumb: (j['has_thumb'] as num?)?.toInt() ?? 1,
  );
}

class QueryResult {
  final List<MediaItem> items;
  final String? nextCursor;
  final int? total;
  QueryResult({required this.items, this.nextCursor, this.total});
}

class UploadResult {
  final MediaItem item;
  final bool dedup;
  UploadResult({required this.item, required this.dedup});
}

class FolderItem {
  final String id;
  final String name;
  final String? parentId;
  final String? coverId;
  final String? coverMediaType;
  final int itemCount;
  final String createdAt;
  final String updatedAt;

  FolderItem({
    required this.id, required this.name, this.parentId, this.coverId,
    this.coverMediaType,
    required this.itemCount, required this.createdAt, required this.updatedAt,
  });

  bool get coverIsVideo => coverMediaType == 'video';

  FolderItem copyWith({String? name}) => FolderItem(
    id: id, name: name ?? this.name, parentId: parentId,
    coverId: coverId, coverMediaType: coverMediaType,
    itemCount: itemCount, createdAt: createdAt, updatedAt: updatedAt,
  );

  factory FolderItem.fromJson(Map<String, dynamic> j) => FolderItem(
    id: j['id'] as String,
    name: j['name'] as String,
    parentId: j['parent_id'] as String?,
    coverId: j['cover_id'] as String?,
    coverMediaType: j['cover_media_type'] as String?,
    itemCount: (j['item_count'] as num?)?.toInt() ?? 0,
    createdAt: j['created_at'] as String,
    updatedAt: j['updated_at'] as String? ?? '',
  );
}

class MediaService {
  final ServerState _state;
  MediaService(this._state);

  String get _base => _state.baseUrl;
  String thumbUrl(String id) => '$_base/v1/media/$id/thumb';
  String fullUrl(String id) => '$_base/v1/media/$id';
  Map<String, String> get authHeaders {
    final t = apiConfig.token;
    return (t != null && t.isNotEmpty) ? {'Authorization': 'Bearer $t'} : {};
  }

  /// cursor 分页优先；不传 cursor 视为首页
  Future<QueryResult> query({
    int size = 50,
    Map<String, dynamic>? filter,
    List<Map<String, String>>? sort,
    String? cursor,
    bool withTotal = false,
  }) async {
    final body = <String, dynamic>{'size': size, 'with_total': withTotal};
    if (filter != null) body['filter'] = filter;
    if (sort != null) body['sort'] = sort;
    if (cursor != null) body['cursor'] = cursor;

    final json = await Api.instance.postJson('/v1/media/query', body: body) as Map<String, dynamic>;
    final items = (json['items'] as List)
        .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
    return QueryResult(
      items: items,
      nextCursor: json['next_cursor'] as String?,
      total: (json['total'] as num?)?.toInt(),
    );
  }

  /// 秒传探测：命中则返回已存在的 MediaItem
  Future<MediaItem?> probe(String checksum) async {
    final json = await Api.instance.postJson('/v1/media/probe',
        body: {'checksum': checksum}) as Map<String, dynamic>;
    if (json['exists'] == true) {
      return MediaItem.fromJson(json['item'] as Map<String, dynamic>);
    }
    return null;
  }

  /// 计算文件 SHA256（isolate 里跑）
  static Future<String> sha256File(File f) async {
    // 用 stream 避免大文件一次读入内存
    final digest = await sha256.bind(f.openRead()).first;
    return digest.toString();
  }

  /// 单文件上传：返回 UploadResult（含 dedup）
  Future<UploadResult?> uploadFile(
    File file, {
    String? folderId,
    String? takenAtIso,
  }) async {
    final filename = file.path.split(Platform.pathSeparator).last;
    final size = await file.length();

    // 秒传探测（<= 5GB 才算 sha，超大文件跳过秒传直传）
    if (size < 5 * 1024 * 1024 * 1024) {
      try {
        final sum = await sha256File(file);
        final existing = await probe(sum);
        if (existing != null) {
          return UploadResult(item: existing, dedup: true);
        }
      } catch (_) {
        // probe 失败不阻塞上传
      }
    }

    final request = http.MultipartRequest('POST', Uri.parse('$_base/v1/media/upload'));
    request.headers.addAll(authHeaders);
    request.files.add(await http.MultipartFile.fromPath(
      'file', file.path, filename: filename, contentType: guessMime(filename),
    ));
    if (takenAtIso != null) {
      request.fields['taken_at'] = takenAtIso;
    } else {
      try {
        final stat = await file.stat();
        request.fields['taken_at'] = toServerRfc3339(stat.modified);
      } catch (_) {}
    }
    if (folderId != null) request.fields['folder_id'] = folderId;

    final response = await request.send();
    final body = await response.stream.bytesToString();
    if (response.statusCode != 200) {
      throw ApiException(
        response.statusCode == 401 ? ApiErrorKind.unauthorized : ApiErrorKind.server,
        'upload ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final list = jsonDecode(body) as List;
    if (list.isEmpty) return null;
    final j = list.first as Map<String, dynamic>;
    return UploadResult(
      item: MediaItem.fromJson(j),
      dedup: j['dedup'] == true,
    );
  }

  Future<UploadResult?> uploadBytes({
    required Uint8List bytes,
    required String filename,
    String? takenAt,
    String? folderId,
  }) async {
    final request = http.MultipartRequest('POST', Uri.parse('$_base/v1/media/upload'));
    request.headers.addAll(authHeaders);
    request.files.add(http.MultipartFile.fromBytes('file', bytes,
        filename: filename, contentType: guessMime(filename)));
    if (takenAt != null) request.fields['taken_at'] = takenAt;
    if (folderId != null) request.fields['folder_id'] = folderId;
    final response = await request.send();
    final body = await response.stream.bytesToString();
    if (response.statusCode != 200) {
      throw ApiException(ApiErrorKind.server, 'upload ${response.statusCode}',
          statusCode: response.statusCode);
    }
    final list = jsonDecode(body) as List;
    if (list.isEmpty) return null;
    final j = list.first as Map<String, dynamic>;
    return UploadResult(item: MediaItem.fromJson(j), dedup: j['dedup'] == true);
  }

  Future<Uint8List> downloadBytes(String id) async {
    // 先查缓存
    // 注：cachedMediaSync 在 DiskCache 里，避免耦合，这里直接走 http
    final resp = await Api.instance.client
        .get(Uri.parse('$_base/v1/media/$id'), headers: authHeaders);
    if (resp.statusCode != 200) {
      throw ApiException(ApiErrorKind.server, 'download ${resp.statusCode}');
    }
    return resp.bodyBytes;
  }

  Future<void> delete(String id) => Api.instance.delete('/v1/media/$id');

  Future<void> batchDelete(List<String> ids) =>
      Api.instance.postJson('/v1/media/batch-delete', body: {'ids': ids});

  Future<void> restore(String id) =>
      Api.instance.postJson('/v1/media/$id/restore');

  /// PATCH 返回更新后的完整 MediaItem
  Future<MediaItem?> updateFields(String id, Map<String, dynamic> fields) async {
    final json = await Api.instance.patchJson('/v1/media/$id', body: fields);
    if (json == null) return null;
    return MediaItem.fromJson(json as Map<String, dynamic>);
  }

  /// 单个文件下载的原始响应（供 DownloadService 决定落盘路径）
  Future<http.Response> downloadRaw(String id) async {
    final resp = await Api.instance.client
        .get(Uri.parse('$_base/v1/media/$id/download'), headers: authHeaders)
        .timeout(const Duration(minutes: 30));
    if (resp.statusCode != 200) {
      throw ApiException(ApiErrorKind.server, 'download ${resp.statusCode}',
          statusCode: resp.statusCode);
    }
    return resp;
  }

  Future<File> downloadBatch(List<String> ids, {required String savePath}) async {
    final request = http.Request('POST', Uri.parse('$_base/v1/media/download'));
    request.headers['Content-Type'] = 'application/json';
    request.headers.addAll(authHeaders);
    request.body = jsonEncode({'ids': ids});

    final response = await Api.instance.client.send(request);
    if (response.statusCode != 200) {
      throw ApiException(ApiErrorKind.server, 'zip ${response.statusCode}');
    }
    final file = File(savePath);
    final sink = file.openWrite();
    await response.stream.pipe(sink);
    await sink.close();
    return file;
  }

  Future<void> downloadIndividual(
    List<String> ids, {
    required String saveDir,
    void Function(int completed, int total)? onProgress,
  }) async {
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      try {
        final resp = await downloadRaw(id);
        String filename = id;
        final disposition = resp.headers['content-disposition'];
        if (disposition != null) {
          final utf8 = RegExp(r"filename\*=UTF-8''([^;]+)", caseSensitive: false).firstMatch(disposition);
          if (utf8 != null) {
            filename = Uri.decodeComponent(utf8.group(1)!);
          } else {
            final m = RegExp(r'filename="?([^";]+)"?').firstMatch(disposition);
            if (m != null) filename = m.group(1)!;
          }
        }
        final file = File('$saveDir/$filename');
        await file.writeAsBytes(resp.bodyBytes);
        final takenAt = resp.headers['x-taken-at'];
        if (takenAt != null) {
          final dt = DateTime.tryParse(takenAt);
          if (dt != null) {
            try { await file.setLastModified(dt); } catch (_) {}
          }
        }
      } catch (_) {
        // 单个失败不中断整批
      }
      onProgress?.call(i + 1, ids.length);
    }
  }

  Future<ServerStats> fetchInfo() async {
    final json = await Api.instance.getJson('/v1/info') as Map<String, dynamic>;
    return ServerStats.fromJson(json);
  }

  // ── Folders ──

  Future<List<FolderItem>> listFolders({String? parentId}) async {
    final list = await Api.instance.getJson('/v1/folders',
        query: parentId != null ? {'parent_id': parentId} : null) as List;
    return list.map((e) => FolderItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<FolderItem> createFolder({required String name, String? parentId}) async {
    final json = await Api.instance.postJson('/v1/folders',
        body: {'name': name, if (parentId != null) 'parent_id': parentId}) as Map<String, dynamic>;
    return FolderItem.fromJson(json);
  }

  Future<void> renameFolder(String id, String name) =>
      Api.instance.patchJson('/v1/folders/$id', body: {'name': name});

  Future<void> deleteFolder(String id) => Api.instance.delete('/v1/folders/$id');

  Future<int> batchMove(List<String> ids, {String? folderId}) async {
    final json = await Api.instance.postJson('/v1/media/batch-move',
        body: {'ids': ids, 'folder_id': folderId}) as Map<String, dynamic>;
    return (json['moved'] as num?)?.toInt() ?? 0;
  }

  Future<int> batchFavorite(List<String> ids, {required bool favorite}) async {
    final json = await Api.instance.postJson('/v1/media/batch-favorite',
        body: {'ids': ids, 'favorite': favorite}) as Map<String, dynamic>;
    return (json['updated'] as num?)?.toInt() ?? 0;
  }
}
