import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Wraps [flutter_foreground_task] to start/update/stop an Android foreground
/// service notification while uploads are in progress.
///
/// The service is a "dataSync" foreground service type — it's displayed as a
/// persistent notification with the upload count and percentage, and tells the
/// OS not to kill the app process while active.
///
/// iOS: No foreground service is needed. iOS allows background URLSession
/// uploads natively; this class is a no-op on iOS/web/desktop.
class UploadForegroundService {
  UploadForegroundService._();

  static const String _channelId = 'picgallery_upload_channel';
  static const String _channelName = 'Uploads';

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  /// Call once at app startup (before any upload can start) to register the
  /// notification channel and initialize the plugin.
  static Future<void> init() async {
    if (!_supported) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _channelId,
        channelName: _channelName,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      // iOS uses BGURLSession natively, so this is a no-op.
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // Do not run a separate Dart isolate — we only need the notification.
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWifiLock: true,
      ),
    );
  }

  /// Starts the foreground service with an initial notification.
  ///
  /// Safe to call even if the service is already running — it becomes an
  /// [update] call in that case. Pass [activeCount] (queued + uploading jobs).
  static Future<void> start({
    required int activeCount,
    int percentDone = 0,
  }) async {
    if (!_supported) return;

    final taskData = _buildTaskData(activeCount: activeCount, percentDone: percentDone);

    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(
        notificationTitle: taskData.title,
        notificationText: taskData.body,
      );
    } else {
      await FlutterForegroundTask.startService(
        notificationTitle: taskData.title,
        notificationText: taskData.body,
        callback: _taskCallback,
      );
    }
  }

  /// Updates the notification text.  Call from the upload ticker with the
  /// current aggregated progress (bytes done / total bytes across all jobs).
  static Future<void> update({
    required int activeCount,
    required int percentDone,
  }) async {
    if (!_supported) return;
    if (!await FlutterForegroundTask.isRunningService) {
      await start(activeCount: activeCount, percentDone: percentDone);
      return;
    }

    final taskData = _buildTaskData(activeCount: activeCount, percentDone: percentDone);
    await FlutterForegroundTask.updateService(
      notificationTitle: taskData.title,
      notificationText: taskData.body,
    );
  }

  /// Stops the foreground service.  Call when the queue has no more active or
  /// queued jobs (i.e., everything is done, failed, or canceled).
  static Future<void> stop() async {
    if (!_supported) return;
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.stopService();
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  static ({String title, String body}) _buildTaskData({
    required int activeCount,
    required int percentDone,
  }) {
    final title = 'Uploading $activeCount file${activeCount == 1 ? '' : 's'}';
    final body = percentDone > 0 ? '$percentDone% complete' : 'Starting upload…';
    return (title: title, body: body);
  }
}

/// Top-level callback required by [flutter_foreground_task] when starting the
/// service.  We don't use the task loop, so this is intentionally empty.
@pragma('vm:entry-point')
void _taskCallback() {
  // No-op: we drive the notification content directly from the main isolate.
}
