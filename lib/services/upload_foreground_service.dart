import 'dart:async';
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
/// Android 15 constraint: `dataSync` foreground services are killed after 6
/// hours by the OS. We work around this by stopping and restarting the service
/// every [_restartInterval] (5.5 hours) so the 6-hour timer resets. The
/// restart is invisible to the user — the notification reappears within a
/// second of the stop.
///
/// iOS: This class is a no-op. Uploads use the app's regular request flow;
/// background URLSession uploads are not implemented, so iOS suspends uploads
/// after the app moves to the background. main.dart's lifecycle observer
/// calls resumeAll() when the app returns to foreground.
class UploadForegroundService {
  UploadForegroundService._();

  static const String _channelId = 'picgallery_upload_channel';
  static const String _channelName = 'Uploads';

  /// Android 15 enforces a 6-hour cap on dataSync foreground services.
  /// Restart every 5.5 hours to stay safely below the limit.
  static const Duration _restartInterval = Duration(hours: 5, minutes: 30);

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  /// Timer that fires just before Android 15's 6-hour dataSync limit.
  static Timer? _restartTimer;

  /// Snapshot of the last notification content used to restore the
  /// notification text across a service restart.
  static ({int activeCount, int percentDone}) _lastTaskData =
      (activeCount: 0, percentDone: 0);

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
      // The plugin initialization below is guarded to Android above.
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

    _lastTaskData = (activeCount: activeCount, percentDone: percentDone);
    final taskData = _buildTaskData(
        activeCount: activeCount, percentDone: percentDone);

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

    // Schedule an Android-15-safe restart before the 6-hour kill.
    _scheduleRestart();
  }

  /// Updates the notification text.  Call from the upload ticker with the
  /// current aggregated progress (bytes done / total bytes across all jobs).
  static Future<void> update({
    required int activeCount,
    required int percentDone,
  }) async {
    if (!_supported) return;
    _lastTaskData = (activeCount: activeCount, percentDone: percentDone);

    if (!await FlutterForegroundTask.isRunningService) {
      await start(activeCount: activeCount, percentDone: percentDone);
      return;
    }

    final taskData = _buildTaskData(
        activeCount: activeCount, percentDone: percentDone);
    await FlutterForegroundTask.updateService(
      notificationTitle: taskData.title,
      notificationText: taskData.body,
    );
  }

  /// Stops the foreground service.  Call when the queue has no more active or
  /// queued jobs (i.e., everything is done, failed, or canceled).
  static Future<void> stop() async {
    _restartTimer?.cancel();
    _restartTimer = null;
    if (!_supported) return;
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.stopService();
  }

  // ---------------------------------------------------------------------------
  // Android 15 restart guard
  // ---------------------------------------------------------------------------

  /// Schedules a service stop→start just before Android 15's 6-hour kill.
  /// Cancels any previously pending restart first, so calling [start] multiple
  /// times doesn't stack timers.
  static void _scheduleRestart() {
    _restartTimer?.cancel();
    if (!_supported) return;
    _restartTimer = Timer(_restartInterval, _doRestart);
  }

  /// Silently restarts the foreground service to reset the Android 15
  /// 6-hour `dataSync` timer.
  static Future<void> _doRestart() async {
    if (!_supported) return;
    if (!await FlutterForegroundTask.isRunningService) return;

    // Stop, then immediately re-start with the last known notification content.
    await FlutterForegroundTask.stopService();
    final snap = _lastTaskData;
    await start(activeCount: snap.activeCount, percentDone: snap.percentDone);
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
