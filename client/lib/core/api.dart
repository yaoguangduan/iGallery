import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 统一 HTTP 层 (R4):
/// - 单例 http.Client，socket 复用
/// - 分档超时：connect 10s，普通读写 60s，上传/下载不限（依赖底层活性）
/// - request seq 防竞态：调用方持有 seq，回调时校验
/// - 401/超时/网络错等统一抛 ApiException，UI 层可 showToast

class ApiConfig {
  String? baseUrl;
  String? token;
  ApiConfig();
}

final ApiConfig apiConfig = ApiConfig();

const Duration kReadTimeout = Duration(seconds: 60);
const Duration kProbeTimeout = Duration(seconds: 3);
// 上传/下载不设 timeout — 传大视频可能几十分钟

enum ApiErrorKind { network, timeout, unauthorized, notFound, server, badRequest, unknown }

class ApiException implements Exception {
  final ApiErrorKind kind;
  final String message;
  final int? statusCode;
  ApiException(this.kind, this.message, {this.statusCode});

  @override
  String toString() => 'ApiException($kind, $statusCode): $message';

  /// 面向用户的短提示
  String get userMessage => switch (kind) {
    ApiErrorKind.network       => '网络异常',
    ApiErrorKind.timeout       => '请求超时',
    ApiErrorKind.unauthorized  => '未授权',
    ApiErrorKind.notFound      => '资源不存在',
    ApiErrorKind.server        => '服务器错误',
    ApiErrorKind.badRequest    => '请求参数错误',
    ApiErrorKind.unknown       => '未知错误',
  };
}

class Api {
  static final Api instance = Api._();
  Api._();

  final http.Client _client = http.Client();
  http.Client get client => _client;

  Map<String, String> _headers({Map<String, String>? extra, bool json = false}) {
    final h = <String, String>{};
    if (json) h['Content-Type'] = 'application/json';
    if (apiConfig.token != null && apiConfig.token!.isNotEmpty) {
      h['Authorization'] = 'Bearer ${apiConfig.token}';
    }
    if (extra != null) h.addAll(extra);
    return h;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = apiConfig.baseUrl;
    if (base == null || base.isEmpty) {
      throw ApiException(ApiErrorKind.network, '未连接服务器');
    }
    return Uri.parse('$base$path').replace(
      queryParameters: (query?.isEmpty ?? true) ? null : query,
    );
  }

  Future<T> _wrap<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException(ApiErrorKind.timeout, '请求超时');
    } on SocketException catch (e) {
      throw ApiException(ApiErrorKind.network, e.message);
    } on http.ClientException catch (e) {
      throw ApiException(ApiErrorKind.network, e.message);
    } catch (e, st) {
      if (kDebugMode) debugPrint('api unknown: $e\n$st');
      throw ApiException(ApiErrorKind.unknown, e.toString());
    }
  }

  ApiException _fromStatus(int code, String body) {
    final kind = switch (code) {
      401 || 403 => ApiErrorKind.unauthorized,
      404 => ApiErrorKind.notFound,
      >= 500 => ApiErrorKind.server,
      >= 400 => ApiErrorKind.badRequest,
      _ => ApiErrorKind.unknown,
    };
    String msg = '$code';
    try {
      final json = jsonDecode(body);
      if (json is Map && json['error'] != null) msg = json['error'].toString();
    } catch (_) {}
    return ApiException(kind, msg, statusCode: code);
  }

  Future<dynamic> getJson(String path, {Map<String, String>? query, Duration? timeout}) {
    return _wrap(() async {
      final resp = await _client
          .get(_uri(path, query), headers: _headers())
          .timeout(timeout ?? kReadTimeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw _fromStatus(resp.statusCode, resp.body);
      }
      if (resp.body.isEmpty) return null;
      return jsonDecode(resp.body);
    });
  }

  Future<dynamic> postJson(String path, {Object? body, Duration? timeout}) {
    return _wrap(() async {
      final resp = await _client
          .post(_uri(path),
              headers: _headers(json: true),
              body: body == null ? null : jsonEncode(body))
          .timeout(timeout ?? kReadTimeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw _fromStatus(resp.statusCode, resp.body);
      }
      if (resp.body.isEmpty) return null;
      return jsonDecode(resp.body);
    });
  }

  Future<dynamic> patchJson(String path, {Object? body, Duration? timeout}) {
    return _wrap(() async {
      final resp = await _client
          .patch(_uri(path),
              headers: _headers(json: true),
              body: body == null ? null : jsonEncode(body))
          .timeout(timeout ?? kReadTimeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw _fromStatus(resp.statusCode, resp.body);
      }
      if (resp.body.isEmpty) return null;
      return jsonDecode(resp.body);
    });
  }

  Future<void> delete(String path, {Duration? timeout}) {
    return _wrap(() async {
      final resp = await _client
          .delete(_uri(path), headers: _headers())
          .timeout(timeout ?? kReadTimeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw _fromStatus(resp.statusCode, resp.body);
      }
    });
  }

  /// 探活：短超时，不抛异常
  Future<Map<String, dynamic>?> probe(String baseUrl, {String? token}) async {
    try {
      final headers = <String, String>{};
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
      final resp = await _client
          .get(Uri.parse('$baseUrl/v1/info'), headers: headers)
          .timeout(kProbeTimeout);
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// /v1/auth 探测：不带 token 就能调用
  Future<Map<String, dynamic>?> authProbe(String baseUrl, {String? token}) async {
    try {
      final headers = <String, String>{};
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
      final resp = await _client
          .get(Uri.parse('$baseUrl/v1/auth'), headers: headers)
          .timeout(kProbeTimeout);
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }
}

/// request seq 防竞态：调用方在开始异步前 bump()，回调时 valid(seq) 判断
class Seq {
  int _v = 0;
  int bump() => ++_v;
  bool valid(int s) => s == _v;
}
