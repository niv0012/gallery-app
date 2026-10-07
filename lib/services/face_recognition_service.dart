import 'dart:convert';
import 'package:image_picker/image_picker.dart';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' as http_parser;

import '../core/network/api_client.dart';
import '../models/face_search_result_model.dart';

/// Thrown whenever the backend responds with a non-2xx status code.
/// Mirrors [ApiException] but kept separate since this service talks
/// to the backend directly over `http.MultipartRequest` rather than
/// through [ApiClient] (which only speaks JSON bodies).
class FaceSearchException implements Exception {
  final int statusCode;
  final String message;

  const FaceSearchException(this.statusCode, this.message);

  @override
  String toString() => 'FaceSearchException($statusCode): $message';
}

/// Real face detection + search, talking to the backend's InsightFace +
/// pgvector pipeline (`POST /faces/search`,
/// `POST /public/share-links/{token}/face-search`).
///
/// This replaces the old fake service that used to live in this file —
/// it hashed image bytes into a pseudo "128-D embedding" and compared
/// those locally. No embeddings are computed or stored on-device
/// anymore: the backend does detection AND matching in one round trip,
/// and only ever returns similarity scores + matched media back to the
/// client.
class FaceSearchApiService {
  FaceSearchApiService({required ApiClient apiClient, http.Client? httpClient})
      : _apiClient = apiClient,
        _httpClient = httpClient ?? http.Client();

  final ApiClient _apiClient;
  final http.Client _httpClient;

  /// Face detection + a cosine search across a real photo library can
  /// take noticeably longer than a typical JSON call — especially on
  /// the very first request after the backend starts, since that's
  /// when the ~350MB InsightFace model actually loads into memory.
  /// Same reasoning as [MediaUploadService]'s longer-than-[ApiClient]
  /// timeout.
  static const Duration _timeout = Duration(seconds: 60);

  /// Searches the studio's OWN library — `POST /faces/search` (needs
  /// the photographer's bearer token, attached automatically from
  /// [ApiClient.authToken]). [albumId]/[folderId] scope the search to
  /// one album/folder; [faceIndex] re-runs the search using a specific
  /// face from a previous response's `detectedFaces` instead of the
  /// backend's auto-picked largest one. [threshold] overrides the
  /// backend's default `FACE_MATCH_THRESHOLD` for this one call.
  Future<FaceSearchApiResponse> searchMyLibrary({
    required XFile selfie,
    String? albumId,
    String? folderId,
    int? faceIndex,
    double? threshold,
  }) {
    final query = <String, String>{
      if (albumId != null) 'album_id': albumId,
      if (folderId != null) 'folder_id': folderId,
      if (faceIndex != null) 'face_index': faceIndex.toString(),
      if (threshold != null) 'threshold': threshold.toString(),
    };
    final path =
        '/faces/search${query.isEmpty ? '' : '?${Uri(queryParameters: query).query}'}';
    return _post(path, selfie, withAuth: true);
  }

  Future<Map<String, dynamic>> getFaceIndexStatus({String? albumId, List<String>? albumIds}) async {
    final query = <String, dynamic>{};
    if (albumId != null) query['album_id'] = albumId;
    if (albumIds != null && albumIds.isNotEmpty) query['album_ids'] = albumIds;
    final path = '/faces/status${query.isEmpty ? '' : '?${Uri(queryParameters: query).query}'}';
    final response = await _apiClient.get(path, withAuth: true);
    return response.data as Map<String, dynamic>;
  }

  /// "Find my photos" for a guest viewing a shared gallery — `POST
  /// /public/share-links/{token}/face-search`. No login required, same
  /// as viewing the shared gallery itself; [password] is only needed
  /// if the studio protected the link with one.
  Future<FaceSearchApiResponse> searchSharedGallery({
    required String token,
    required XFile selfie,
    String? password,
    int? faceIndex,
  }) {
    final query = <String, String>{
      if (password != null) 'password': password,
      if (faceIndex != null) 'face_index': faceIndex.toString(),
    };
    final path =
        '/public/share-links/$token/face-search${query.isEmpty ? '' : '?${Uri(queryParameters: query).query}'}';
    return _post(path, selfie, withAuth: false);
  }

  /// "Find my photos" for a client searching across all their active shared albums.
  Future<FaceSearchApiResponse> searchClientGallery({
    required XFile selfie,
    int? faceIndex,
    double? threshold,
  }) {
    final query = <String, String>{
      if (faceIndex != null) 'face_index': faceIndex.toString(),
      if (threshold != null) 'threshold': threshold.toString(),
    };
    final path =
        '/client/faces/search${query.isEmpty ? '' : '?${Uri(queryParameters: query).query}'}';
    return _post(path, selfie, withAuth: true);
  }

  Future<FaceSearchApiResponse> _post(String path, XFile selfie,
      {required bool withAuth}) async {
    final uri = Uri.parse('${_apiClient.baseUrl}$path');
    final request = http.MultipartRequest('POST', uri);

    if (withAuth) {
      final token = _apiClient.authToken;
      if (token != null) {
        request.headers['Authorization'] = 'Bearer $token';
      }
    }

    final bytes = await selfie.readAsBytes();
    final fileName = selfie.name.isNotEmpty
        ? selfie.name
        : 'selfie.jpg';
    request.files.add(
      http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: fileName,
        contentType: http_parser.MediaType('image', _guessSubtype(fileName)),
      ),
    );

    final http.StreamedResponse streamedResponse;
    try {
      streamedResponse = await _httpClient
          .send(request)
          .timeout(_timeout, onTimeout: _throwTimeout);
    } on FaceSearchException {
      rethrow;
    } catch (_) {
      // Connection refused, DNS failure, TLS error, stream erroring
      // mid-flight, etc. — same "one exception type" reasoning
      // [ApiClient]/[MediaUploadService] use for their own guarded sends.
      throw const FaceSearchException(
        0,
        "Couldn't reach the server. Check your connection and that the backend is running, then try again.",
      );
    }

    final response = await http.Response.fromStream(streamedResponse);
    return _decode(response);
  }

  String _guessSubtype(String fileName) {
    final ext =
        fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
    switch (ext) {
      case 'png':
        return 'png';
      case 'webp':
        return 'webp';
      case 'heic':
        return 'heic';
      case 'heif':
        return 'heif';
      default:
        return 'jpeg';
    }
  }

  FaceSearchApiResponse _decode(http.Response response) {
    dynamic decoded;
    if (response.body.isNotEmpty) {
      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }
    }

    if (response.statusCode >= 200 &&
        response.statusCode < 300 &&
        decoded is Map<String, dynamic>) {
      return FaceSearchApiResponse.fromJson(decoded);
    }

    throw FaceSearchException(
        response.statusCode, _extractMessage(decoded, response.body));
  }

  /// Same FastAPI `HTTPException`/validation-error unwrapping
  /// [ApiClient] uses, duplicated here since this service can't share
  /// [ApiClient]'s private helper.
  String _extractMessage(dynamic decoded, String rawBody) {
    if (decoded is Map<String, dynamic> && decoded.containsKey('detail')) {
      final detail = decoded['detail'];
      if (detail is String) return detail;
      if (detail is List) {
        return detail
            .map((e) => e is Map && e['msg'] != null
                ? e['msg'].toString()
                : e.toString())
            .join(', ');
      }
      return detail.toString();
    }
    return rawBody.isNotEmpty ? rawBody : 'Unknown error';
  }

  Never _throwTimeout() {
    throw const FaceSearchException(
      0,
      "Couldn't reach the server. Check your connection and that the backend is running, then try again.",
    );
  }

  void dispose() => _httpClient.close();
}
