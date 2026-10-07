/// Model representing a server-side ZIP job (Phase 4 – 7.3).
///
/// Maps to `ZipJobRead` in `app/api/routes/zip_jobs.py`.
class ZipJobModel {
  final String id;
  final String kind; // 'zip_folder' | 'zip_album'
  final ZipJobStatus status;
  final int progress; // 0–100
  final String? resultUrl;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? expiresAt;

  const ZipJobModel({
    required this.id,
    required this.kind,
    required this.status,
    required this.progress,
    this.resultUrl,
    this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
    this.expiresAt,
  });

  bool get isActive =>
      status == ZipJobStatus.pending || status == ZipJobStatus.processing;

  bool get isFinished =>
      status == ZipJobStatus.completed ||
      status == ZipJobStatus.failed ||
      status == ZipJobStatus.canceled;

  bool get isExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now().toUtc());

  factory ZipJobModel.fromJson(Map<String, dynamic> json) {
    return ZipJobModel(
      id: json['id'] as String,
      kind: json['kind'] as String,
      status: ZipJobStatus.fromApi(json['status'] as String),
      progress: json['progress'] as int? ?? 0,
      resultUrl: json['result_url'] as String?,
      errorMessage: json['error_message'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      expiresAt: json['expires_at'] != null
          ? DateTime.parse(json['expires_at'] as String)
          : null,
    );
  }
}

enum ZipJobStatus {
  pending,
  processing,
  completed,
  failed,
  canceled;

  static ZipJobStatus fromApi(String value) => switch (value) {
        'pending' => ZipJobStatus.pending,
        'processing' => ZipJobStatus.processing,
        'completed' => ZipJobStatus.completed,
        'failed' => ZipJobStatus.failed,
        'canceled' => ZipJobStatus.canceled,
        _ => ZipJobStatus.failed,
      };

  String get label => switch (this) {
        ZipJobStatus.pending => 'Queued',
        ZipJobStatus.processing => 'Building ZIP…',
        ZipJobStatus.completed => 'Ready',
        ZipJobStatus.failed => 'Failed',
        ZipJobStatus.canceled => 'Canceled',
      };
}
