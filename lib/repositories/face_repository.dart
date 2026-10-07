import 'package:image_picker/image_picker.dart';

import '../models/face_search_result_model.dart';
import '../services/face_recognition_service.dart';

/// Talks to the backend's real face-recognition pipeline (InsightFace +
/// pgvector) via [FaceSearchApiService]. Replaces the old
/// [HiveFaceRepository] that indexed fake, on-device "embeddings" into
/// Hive — there is nothing left to index or store locally: every
/// search call detects AND matches faces server-side in one round
/// trip, so this repository is a thin passthrough.
abstract class FaceRepository {
  /// Searches the current studio's own library.
  Future<FaceSearchApiResponse> searchMyLibrary({
    required XFile selfie,
    String? albumId,
    String? folderId,
    int? faceIndex,
  });

  /// "Find my photos" within one publicly shared album — no login.
  Future<FaceSearchApiResponse> searchSharedGallery({
    required String token,
    required XFile selfie,
    String? password,
    int? faceIndex,
  });

  /// "Find my photos" across all active shared albums for the logged-in client.
  Future<FaceSearchApiResponse> searchClientGallery({
    required XFile selfie,
    int? faceIndex,
  });

  /// Check indexing status.
  Future<Map<String, dynamic>> getFaceIndexStatus({
    String? albumId,
    List<String>? albumIds,
  });
}

class ApiFaceRepository implements FaceRepository {
  ApiFaceRepository({required FaceSearchApiService service})
      : _service = service;

  final FaceSearchApiService _service;

  @override
  Future<FaceSearchApiResponse> searchMyLibrary({
    required XFile selfie,
    String? albumId,
    String? folderId,
    int? faceIndex,
  }) {
    return _service.searchMyLibrary(
      selfie: selfie,
      albumId: albumId,
      folderId: folderId,
      faceIndex: faceIndex,
    );
  }

  @override
  Future<FaceSearchApiResponse> searchSharedGallery({
    required String token,
    required XFile selfie,
    String? password,
    int? faceIndex,
  }) {
    return _service.searchSharedGallery(
      token: token,
      selfie: selfie,
      password: password,
      faceIndex: faceIndex,
    );
  }

  @override
  Future<FaceSearchApiResponse> searchClientGallery({
    required XFile selfie,
    int? faceIndex,
  }) {
    return _service.searchClientGallery(
      selfie: selfie,
      faceIndex: faceIndex,
    );
  }

  @override
  Future<Map<String, dynamic>> getFaceIndexStatus({
    String? albumId,
    List<String>? albumIds,
  }) {
    return _service.getFaceIndexStatus(
      albumId: albumId,
      albumIds: albumIds,
    );
  }
}
