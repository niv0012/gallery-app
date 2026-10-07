import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'core/network/api_client.dart';
import 'core/routes/app_routes.dart';
import 'core/theme/app_theme.dart';
import 'l10n/app_localizations.dart';
import 'providers/auth_providers.dart';
import 'providers/album_provider.dart';
import 'providers/media_provider.dart';
import 'providers/settings_provider.dart';
import 'services/deep_link_service.dart';
import 'services/push_notification_service.dart';
import 'services/upload_foreground_service.dart';
import 'upload/upload_job_model.dart' show UploadJobStatus;
import 'upload/upload_queue_provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'firebase_options.dart';
import 'core/constants/supabase_constants.dart';

/// Lets DeepLinkService navigate / show SnackBars after a
/// picgallery://payment-success|payment-failed link arrives, without
/// needing a BuildContext from inside a widget.
final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UploadForegroundService.init();
  // Opens the on-device Hive boxes the Admin Dashboard and the local-only
  // media/albums/folders/onboarding/settings/upload-queue features persist
  // to, so the very first frame can already read saved state.
  await Hive.initFlutter();

  // The backend now has a permanent public URL baked into ApiClient's
  // default (https://api.picgallery.in), so no saved/manual host is
  // needed anymore.
  final apiClient = ApiClient();

  // Initialize Firebase with platform-specific options.
  // options: is required on web (no google-services.json on web);
  // it also works fine on Android/iOS so we always pass it.
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    await PushNotificationService.instance.init(apiClient, navigatorKey);
  } catch (e) {
    debugPrint('Firebase initialization failed: $e');
  }

  // Initialize DeepLinkService before runApp so initial cold-start deep links
  // are captured before the splash screen timer evaluates navigation.
  await DeepLinkService.instance.init(navigatorKey);

  // Initialize Supabase for the Super Admin flow
  await Supabase.initialize(
    url: SupabaseConstants.url,
    anonKey: SupabaseConstants.anonKey,
    authOptions: const FlutterAuthClientOptions(
      authFlowType: AuthFlowType.pkce,
    ),
  );

  runApp(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(apiClient)],
      child: const PicGallery(),
    ),
  );
}

class PicGallery extends ConsumerStatefulWidget {
  const PicGallery({super.key});

  @override
  ConsumerState<PicGallery> createState() => _PicGalleryState();
}

class _PicGalleryState extends ConsumerState<PicGallery>
    with WidgetsBindingObserver {
  DateTime? _backgroundedAt;
  bool _refreshingOnResume = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _backgroundedAt ??= DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed || _backgroundedAt == null) return;

    final elapsed = DateTime.now().difference(_backgroundedAt!);
    _backgroundedAt = null;
    if (elapsed < const Duration(seconds: 2) ||
        !ref.read(authStateProvider).isLoggedIn) {
      return;
    }

    // iOS suspends network requests when the app is backgrounded — Android
    // uses the foreground service to keep going. On iOS return-to-foreground,
    // re-queue any paused jobs so uploads resume automatically.
    if (!kIsWeb && Platform.isIOS) {
      final queueState = ref.read(uploadQueueProvider);
      final hasPaused = queueState.valueOrNull?.jobs.any((j) =>
          j.status == UploadJobStatus.paused) ?? false;
      if (hasPaused) {
        ref.read(uploadQueueProvider.notifier).resumeAll();
      }
    }

    if (_refreshingOnResume) return;
    _refreshingOnResume = true;
    Future.wait([
      ref.read(mediaProvider).load(),
      ref.read(albumProvider).refreshSilently(),
    ]).whenComplete(() {
      _refreshingOnResume = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);

    final themeMode = switch (settings.themeMode) {
      'Light' => ThemeMode.light,
      'Dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'picgallery',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      initialRoute: AppRoutes.splash,
      onGenerateRoute: AppRoutes.onGenerateRoute,
      navigatorObservers: [routeObserver],
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    );
  }
}
