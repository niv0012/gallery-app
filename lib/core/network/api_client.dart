import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform, debugPrint;
import 'package:http/http.dart' as http;

import '../auth/auth_manager.dart';
import '../storage/secure_storage.dart';
import 'auth_interceptor.dart';
import 'web_upload_helper.dart';

/// Thrown whenever the backend responds with a non-2xx status code.
class ApiException implements Exception {
  final int statusCode;
  final String message;

  const ApiException(this.statusCode, this.message);

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Central API Client powered by [Dio] and [AuthInterceptor] for talking to the
/// PicGallery FastAPI backend. Automatically attaches JWT tokens, handles base URLs,
/// performs automatic 401 token refresh retries, and converts errors into [ApiException].
class ApiClient {
  String baseUrl;
  final Dio _dio;
  final AuthManager? _authManager;
  final SecureStorage? _secureStorage;

  String? _inMemoryToken;

  String? get authToken => _authManager?.accessToken ?? _inMemoryToken;
  set authToken(String? token) {
    _inMemoryToken = token;
    if (_authManager != null && token != null) {
      _authManager.setTokens(
          accessToken: token, refreshToken: _authManager.refreshToken);
    }
  }

  ApiClient({
    String? baseUrl,
    http.Client? client,
    String? authToken,
    AuthManager? authManager,
    SecureStorage? secureStorage,
  })  : baseUrl = baseUrl ?? _defaultBaseUrl(),
        _authManager = authManager,
        _secureStorage = secureStorage,
        _inMemoryToken = authToken,
        _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(minutes: 10),
          sendTimeout: const Duration(minutes: 10),
        )) {
    if (authToken != null && authManager != null) {
      authManager.setTokens(accessToken: authToken, refreshToken: null);
    }

    final mgr = _authManager ?? AuthManager(secureStorage: _secureStorage);
    final storage = _secureStorage ?? SecureStorage();

    _dio.interceptors.add(
      AuthInterceptor(
        authManager: mgr,
        secureStorage: storage,
        getBaseUrl: () => this.baseUrl,
      ),
    );
  }

  static String baseUrlForHost(String host) {
    final trimmed = host.trim();
    if (trimmed.contains('://')) {
      final withoutTrailingSlash = trimmed.endsWith('/')
          ? trimmed.substring(0, trimmed.length - 1)
          : trimmed;
      return withoutTrailingSlash.endsWith('/api/v1')
          ? withoutTrailingSlash
          : '$withoutTrailingSlash/api/v1';
    }
    return 'http://$trimmed:8000/api/v1';
  }

  void updateBaseUrl(String newBaseUrl) => baseUrl = newBaseUrl;

  static String _defaultBaseUrl() {
    // Check --dart-define=API_HOST first, for all platforms including web.
    // This is how CI/CD (Codemagic) injects the production URL.
    const envHost = String.fromEnvironment('API_HOST');
    if (envHost.isNotEmpty) return baseUrlForHost(envHost);

    // On desktop/web without a dart-define, fall back to localhost for
    // local development only. Mobile (Android/iOS) without a dart-define
    // defaults to the production URL.
    if (kIsWeb) {
      // Web uses the production API directly (no local backend needed).
      return baseUrlForHost('https://api.picgallery.in');
    }
    if (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux) {
      return baseUrlForHost('localhost');
    }

    return baseUrlForHost('https://api.picgallery.in');
  }

  String _url(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    final cleanPath = path.startsWith('/') ? path : '/$path';
    return '$baseUrl$cleanPath';
  }

  Future<dynamic> get(String path, {bool withAuth = true, Duration? receiveTimeout}) async {
    return _guarded(() => _dio.get(
          _url(path),
          options: Options(
            extra: {'withAuth': withAuth},
            receiveTimeout: receiveTimeout,
          ),
        ));
  }

  Future<List<int>> getBytes(String path, {bool withAuth = true}) async {
    final response = await _guardedRaw(() => _dio.get<List<int>>(
          _url(path),
          options: Options(
            extra: {'withAuth': withAuth},
            responseType: ResponseType.bytes,
          ),
        ));
    return response.data as List<int>;
  }

  Future<void> downloadFile(String path, String savePath, {bool withAuth = true, void Function(int, int)? onReceiveProgress}) async {
    await _guardedRaw(() => _dio.download(
      _url(path),
      savePath,
      onReceiveProgress: onReceiveProgress,
      options: Options(extra: {'withAuth': withAuth}),
    ));
  }

  Future<dynamic> post(String path,
      {Object? body, bool withAuth = true}) async {
    debugPrint('[ApiClient] POST ${_url(path)} | body: $body');
    return _guarded(() => _dio.post(
          _url(path),
          data: body,
          options: Options(
            extra: {'withAuth': withAuth},
            headers: {'Content-Type': 'application/json'},
          ),
        ));
  }

  Future<dynamic> put(String path, {Object? body, bool withAuth = true}) async {
    return _guarded(() => _dio.put(
          _url(path),
          data: body,
          options: Options(
            extra: {'withAuth': withAuth},
            headers: {'Content-Type': 'application/json'},
          ),
        ));
  }

  Future<dynamic> patch(String path,
      {Object? body, bool withAuth = true}) async {
    return _guarded(() => _dio.patch(
          _url(path),
          data: body,
          options: Options(
            extra: {'withAuth': withAuth},
            headers: {'Content-Type': 'application/json'},
          ),
        ));
  }

  Future<dynamic> delete(String path,
      {Object? body, bool withAuth = true}) async {
    return _guarded(() => _dio.delete(
          _url(path),
          data: body,
          options: Options(
            extra: {'withAuth': withAuth},
            headers: {'Content-Type': 'application/json'},
          ),
        ));
  }

  Future<dynamic> postMultipart(String path,
      {required FormData data,
      bool withAuth = true,
      void Function(int, int)? onSendProgress}) async {
    debugPrint('[ApiClient] POST MULTIPART ${_url(path)}');
    return _guarded(() => _dio.post(
          _url(path),
          data: data,
          onSendProgress: onSendProgress,
          options: Options(
            extra: {'withAuth': withAuth},
            sendTimeout: const Duration(hours: 12),
            receiveTimeout: const Duration(hours: 12),
          ),
        ));
  }

  Future<dynamic> putMultipart(String path,
      {required FormData data,
      bool withAuth = true,
      void Function(int, int)? onSendProgress}) async {
    debugPrint('[ApiClient] PUT MULTIPART ${_url(path)}');
    return _guarded(() => _dio.put(
          _url(path),
          data: data,
          onSendProgress: onSendProgress,
          options: Options(
            extra: {'withAuth': withAuth},
            sendTimeout: const Duration(hours: 12),
            receiveTimeout: const Duration(hours: 12),
          ),
        ));
  }

  Future<dynamic> patchMultipart(String path,
      {required FormData data,
      bool withAuth = true,
      CancelToken? cancelToken,
      void Function(int, int)? onSendProgress}) async {
    debugPrint('[ApiClient] PATCH MULTIPART ${_url(path)}');
    return _guarded(() => _dio.patch(
          _url(path),
          data: data,
          cancelToken: cancelToken,
          onSendProgress: onSendProgress,
          options: Options(
            extra: {'withAuth': withAuth},
            sendTimeout: const Duration(minutes: 10),
            receiveTimeout: const Duration(minutes: 10),
          ),
        ));
  }

  /// Bypass Dio for large web files using native XMLHttpRequest.
  Future<dynamic> uploadLargeFileWeb(
    String path, {
    required String blobUrl,
    required String fileName,
    required String contentType,
    bool withAuth = true,
    void Function(int, int)? onSendProgress,
  }) async {
    debugPrint('[ApiClient] NATIVE WEB UPLOAD ${_url(path)}');
    final headers = <String, String>{};
    if (withAuth) {
      final token = authToken;
      if (token != null) {
        headers['Authorization'] = 'Bearer $token';
      }
    }

    // Attempt the upload via XHR bypass
    try {
      final responseBody = await uploadFileWeb(
        blobUrl: blobUrl,
        uploadUrl: _url(path),
        fileName: fileName,
        contentType: contentType,
        headers: headers,
        onSendProgress: onSendProgress,
      );
      debugPrint('[ApiClient] ✅ NATIVE WEB UPLOAD SUCCESS');

      // We expect the server to return JSON
      if (responseBody is String) {
        if (responseBody.isEmpty) return {};
        return jsonDecode(responseBody);
      }
      return responseBody;
    } catch (e) {
      debugPrint('[ApiClient] ❌ NATIVE WEB UPLOAD FAILED: $e');
      throw ApiException(0, 'Upload failed: $e');
    }
  }

  Future<Response> _guardedRaw(Future<Response> Function() send) async {
    try {
      final response = await send();
      debugPrint(
          '[ApiClient] ✅ HTTP ${response.statusCode} (Raw)');
      if (response.statusCode != null && response.statusCode! >= 200 && response.statusCode! < 300) {
        return response;
      }
      return _handleResponse(response);
    } on DioException catch (e) {
      if (e.response != null) {
        return _handleResponse(e.response!);
      }
      throw const ApiException(0, "Network error");
    } catch (e) {
      throw ApiException(0, e.toString());
    }
  }

  Future<dynamic> _guarded(Future<Response> Function() send) async {
    try {
      final response = await send();
      debugPrint(
          '[ApiClient] ✅ HTTP ${response.statusCode} | body: ${response.data}');
      return _handleResponse(response);
    } on DioException catch (e) {
      debugPrint(
          '[ApiClient] ❌ DioException type: ${e.type} | message: ${e.message}');
      if (e.response != null) {
        debugPrint(
            '[ApiClient] ❌ DioException has response: status=${e.response!.statusCode} body=${e.response!.data}');
        return _handleResponse(e.response!);
      }
      debugPrint('[ApiClient] ❌ No response — network/timeout failure');
      throw const ApiException(
        0,
        "Couldn't reach the server. Check your connection and that the backend is running, then try again.",
      );
    } on ApiException {
      rethrow;
    } catch (e, stack) {
      debugPrint('[ApiClient] ❌ Unexpected error in _guarded: $e\n$stack');
      throw ApiException(
        0,
        e.toString(),
      );
    }
  }

  dynamic _handleResponse(Response response) {
    final statusCode = response.statusCode ?? 0;
    final data = response.data;

    if (statusCode >= 200 && statusCode < 300) {
      return data;
    }

    final extracted = _extractMessage(data, response.statusMessage ?? '');
    debugPrint(
        '[ApiClient] ❌ _handleResponse: status=$statusCode | extracted="$extracted" | raw=$data');
    throw ApiException(statusCode, extracted);
  }

  String _extractMessage(dynamic decoded, String rawBody) {
    debugPrint(
        '[ApiClient] _extractMessage: decoded=$decoded | rawBody=$rawBody');
    if (decoded is Map<String, dynamic>) {
      if (decoded.containsKey('detail')) {
        final detail = decoded['detail'];
        debugPrint(
            '[ApiClient] _extractMessage: found detail=$detail (type: ${detail.runtimeType})');
        if (detail is String) return detail;
        if (detail is Map && detail.containsKey('message')) {
          return detail['message'].toString();
        }
        if (detail is List) {
          return detail
              .map((e) => e is Map && e['msg'] != null
                  ? e['msg'].toString()
                  : e.toString())
              .join(', ');
        }
        return detail.toString();
      }
      if (decoded.containsKey('message')) {
        debugPrint('[ApiClient] _extractMessage: found message key');
        return decoded['message'].toString();
      }
    }
    debugPrint(
        '[ApiClient] _extractMessage: no recognized key — falling back to rawBody');
    return rawBody.isNotEmpty ? rawBody : 'Unknown error';
  }

  void dispose() => _dio.close();
}
