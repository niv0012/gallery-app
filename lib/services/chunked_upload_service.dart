import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/network/api_client.dart';
import '../models/media_model.dart';

class ChunkedUploadService {
  ChunkedUploadService({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;
  static const int _chunkSizeBytes = 10 * 1024 * 1024;
  static const int _maxConcurrentParts = 8;

  Future<MediaModel> uploadChunked({
    required String filePath,
    required String fileName,
    required String contentType,
    String? albumId,
    String? folderId,
    String? existingUploadId,
    String? existingMediaId,
    Map<String, String>? completedParts,
    CancelToken? cancelToken,
    void Function(int sentBytes, int totalBytes)? onSendProgress,
    void Function(String uploadId, String mediaId)? onUploadStarted,
    void Function(int partNumber, String etag)? onPartUploaded,
  }) async {
    final file = File(filePath);
    final fileSize = await file.length();
    const chunkSize = _chunkSizeBytes;
    final totalParts = (fileSize / chunkSize).ceil();

    String uploadId = '';
    String mediaId = '';
    List<String>? partUrls;
    final parts = <Map<String, dynamic>>[];
    int totalSent = 0;

    bool tryResume = existingUploadId != null && existingMediaId != null;
    final Set<int> uploadedPartNumbers = {};

    if (tryResume) {
      try {
        debugPrint(
            '[ChunkedUpload] Resuming upload $existingUploadId with ${completedParts?.length ?? 0} saved parts');
        final resumeRes = await _apiClient.post('/media/chunked/resume', body: {
          'upload_id': existingUploadId,
          'media_id': existingMediaId,
          'filename': fileName,
          'total_parts': totalParts,
        });
        uploadId = existingUploadId;
        mediaId = existingMediaId;
        partUrls = (resumeRes['part_urls'] as List<dynamic>?)?.cast<String>();

        final remoteUploadedParts =
            (resumeRes['uploaded_parts'] as List<dynamic>?)?.cast<int>() ?? [];
        debugPrint(
            '[ChunkedUpload] Server confirmed ${remoteUploadedParts.length} uploaded parts');

        if (completedParts != null) {
          for (final remotePartNum in remoteUploadedParts) {
            final etag = completedParts[remotePartNum.toString()];
            if (etag != null) {
              uploadedPartNumbers.add(remotePartNum);
              parts.add({'PartNumber': remotePartNum, 'ETag': etag});
            } else if (partUrls == null) {
              uploadedPartNumbers.add(remotePartNum);
            }
          }
        } else if (partUrls == null) {
          uploadedPartNumbers.addAll(remoteUploadedParts);
        }

        for (final partNum in uploadedPartNumbers) {
          final start = (partNum - 1) * chunkSize;
          final end =
              (start + chunkSize < fileSize) ? start + chunkSize : fileSize;
          totalSent += (end - start);
        }

        onSendProgress?.call(totalSent, fileSize);
      } catch (error) {
        debugPrint('[ChunkedUpload] Resume failed: $error');
        throw StateError(
          'The server could not resume this upload session. '
          'The saved upload was not restarted from zero. '
          'Retry the upload to start a new session.',
        );
      }
    }

    if (!tryResume) {
      final startRes = await _apiClient.post('/media/chunked/start', body: {
        'filename': fileName,
        'content_type': contentType,
        'total_size': fileSize,
        'total_parts': totalParts,
      });

      uploadId = startRes['upload_id'] as String;
      mediaId = startRes['media_id'] as String;
      partUrls = (startRes['part_urls'] as List<dynamic>?)?.cast<String>();
      onUploadStarted?.call(uploadId, mediaId);
    }

    // Reuse one client so direct multipart uploads can reuse connections.
    final directUploadDio = Dio();
    int currentPartIndex = 0;
    final Map<int, int> inFlightProgress = {};

    Future<void> uploadWorker() async {
      while (true) {
        if (cancelToken?.isCancelled == true) {
          throw DioException.requestCancelled(
              requestOptions: RequestOptions(path: ''),
              reason: 'Cancelled by user');
        }

        int i = currentPartIndex;
        if (i >= totalParts) break;
        currentPartIndex++;

        final partNumber = i + 1;
        if (uploadedPartNumbers.contains(partNumber)) {
          continue;
        }

        final start = i * chunkSize;
        final end =
            (start + chunkSize < fileSize) ? start + chunkSize : fileSize;
        final chunkLength = end - start;

        void reportProgress(int sent) {
          inFlightProgress[partNumber] = sent;
          final currentInFlightBytes =
              inFlightProgress.values.fold<int>(0, (a, b) => a + b);
          onSendProgress?.call(totalSent + currentInFlightBytes, fileSize);
        }

        if (partUrls != null && partUrls.isNotEmpty) {
          final partUrl = partUrls[i];
          final res = await directUploadDio.put(
            partUrl,
            data: file.openRead(start, end),
            options: Options(
              headers: {
                'Content-Type': contentType,
                'Content-Length': chunkLength,
              },
            ),
            cancelToken: cancelToken,
            onSendProgress: (sent, total) => reportProgress(sent),
          );
          final etag = res.headers.value('ETag') ?? res.headers.value('etag');
          parts.add({'PartNumber': partNumber, 'ETag': etag ?? ''});
          onPartUploaded?.call(partNumber, etag ?? '');
        } else {
          final chunkData = FormData.fromMap({
            'file': MultipartFile.fromStream(
              () => file.openRead(start, end),
              chunkLength,
              filename: 'part$partNumber',
              contentType: DioMediaType.parse('application/octet-stream'),
            ),
          });

          await _apiClient.patchMultipart(
            '/media/chunked/$uploadId/$partNumber',
            data: chunkData,
            cancelToken: cancelToken,
            onSendProgress: (sent, total) => reportProgress(sent),
          );
          onPartUploaded?.call(partNumber, '');
        }

        inFlightProgress.remove(partNumber);
        totalSent += chunkLength;
        onSendProgress?.call(
            totalSent + inFlightProgress.values.fold<int>(0, (a, b) => a + b),
            fileSize);
      }
    }

    final workers = List.generate(
        totalParts < _maxConcurrentParts ? totalParts : _maxConcurrentParts,
        (_) => uploadWorker());
    await Future.wait(workers);

    // AWS S3 requires parts to be sorted by PartNumber when completing
    parts.sort(
        (a, b) => (a['PartNumber'] as int).compareTo(b['PartNumber'] as int));

    // 3. Complete chunked upload
    final completeBody = {
      'upload_id': uploadId,
      'media_id': mediaId,
      'filename': fileName,
      'content_type': contentType,
      'total_size': fileSize,
      if (partUrls != null) 'parts': parts,
      if (albumId != null) 'album_id': albumId,
      if (folderId != null) 'folder_id': folderId,
    };

    dynamic completeRes;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        completeRes = await _apiClient.post(
          '/media/chunked/complete',
          body: completeBody,
        );
        break;
      } on ApiException catch (error) {
        final retryable = error.statusCode == 0 || error.statusCode >= 500;
        if (!retryable || attempt == 3) rethrow;
        debugPrint(
            '[ChunkedUpload] Finalization attempt $attempt failed; retrying: $error');
        await Future<void>.delayed(Duration(seconds: attempt * 5));
      }
    }

    return MediaModel.fromApiJson(completeRes as Map<String, dynamic>);
  }
}
