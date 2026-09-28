// Minimal platform-agnostic Google / Apple social auth service used by providers/screens.
// Implements the small surface the app expects from SocialAuthService in
// lib/providers/auth_providers.dart (signInWithGoogle, signOutGoogle, signInWithApple)
// and the SocialAuthResult/SocialAuthCancelled types used by callers.

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:google_sign_in/google_sign_in.dart' as gsign;
import 'package:firebase_auth/firebase_auth.dart' as fauth;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';



/// Result returned by SocialAuthService.signInWithGoogle / signInWithApple
/// — callers expect `.provider`, `.idToken` and `.fullName`.
class SocialAuthResult {
  final String provider;
  final String idToken;
  final String? fullName;

  SocialAuthResult(
      {required this.provider, required this.idToken, this.fullName});
}

/// Thrown when the user cancels a social sign-in flow.
class SocialAuthCancelled implements Exception {}

/// Thrown when Google reports [16] Account reauth failed.
/// The caller should clear any cached Google session and retry
/// [signInWithGoogle] — this forces a fresh Credential Manager flow.
class SocialAuthReauthNeeded implements Exception {
  final String message;
  SocialAuthReauthNeeded(this.message);
  @override
  String toString() => 'SocialAuthReauthNeeded: $message';
}

/// Very small Google / Apple Sign-In helper used by UI code. Uses
/// dynamic calls for GoogleSignIn so it works with both the older
/// and the newer credential-manager-based google_sign_in implementations
/// without causing analyzer errors about missing constructors/methods.
class SocialAuthService {
  SocialAuthService._private();
  factory SocialAuthService() => SocialAuthService._private();

  // IMPORTANT: the server client ID below must match the Web OAuth client
  // ID created in the Google Cloud Console / Firebase project. This exact
  // string is required by the backend to validate ID tokens minted for
  // the web client. Do NOT change unless you know the backend is expecting
  // a different OAuth client.
  static const _webClientId =
      '608395495309-b4kfrmpr1pc7sea8grjnnkbn7j2gc7gj.apps.googleusercontent.com';

  // Guard: GoogleSignIn.instance.initialize() must only be called once.
  // Calling it a second time throws "Bad state: init() has already been called".
  // Only used on mobile — web uses Firebase Auth directly.
  static bool _gsInitialized = false;

  static Future<void> _ensureInitialized() async {
    if (_gsInitialized) return;
    await gsign.GoogleSignIn.instance.initialize(
      serverClientId: _webClientId,
    );
    _gsInitialized = true;
  }

  /// Signs in with Google.
  /// On web, this uses signInWithPopup. On mobile, it uses the Credential Manager.
  Future<SocialAuthResult> signInWithGoogle() async {
    if (kIsWeb) {
      try {
        final fauth.GoogleAuthProvider googleProvider =
            fauth.GoogleAuthProvider()
              ..addScope('email')
              ..addScope('profile');
        final fauth.UserCredential result =
            await fauth.FirebaseAuth.instance.signInWithPopup(googleProvider);
        
        final fauth.OAuthCredential? oauthCred =
            result.credential as fauth.OAuthCredential?;
        final String? idToken = oauthCred?.idToken;
        if (idToken == null || idToken.isEmpty) {
          throw Exception('Google Sign-In returned no ID token');
        }

        return SocialAuthResult(
          provider: 'google',
          idToken: idToken,
          fullName: result.user?.displayName,
        );
      } catch (e) {
        if (e.toString().toLowerCase().contains('popup-closed-by-user')) {
          throw SocialAuthCancelled();
        }
        rethrow;
      }
    }
    // ── Mobile (Android / iOS): use google_sign_in Credential Manager ──────
    final gsign.GoogleSignIn gsInstance = gsign.GoogleSignIn.instance;
    await _ensureInitialized();

    gsign.GoogleSignInAccount account;
    try {
      account = await gsInstance.authenticate(
        scopeHint: <String>['email', 'profile'],
      );
    } catch (e) {
      debugPrint(
          '[SocialAuth] signInWithGoogle authenticate() threw: ${e.runtimeType} — $e');
      if (e is gsign.GoogleSignInException) {
        debugPrint('[SocialAuth] GoogleSignInException code: ${e.code}');

        // ── [16] Account reauth failed ───────────────────────────────────
        final String errStr = e.description ?? e.toString();
        if (errStr.contains('reauth') || errStr.contains('[16]')) {
          debugPrint(
              '[SocialAuth] Detected reauth error — clearing stale tokens...');
          try {
            await gsInstance.disconnect();
          } catch (_) {
            try {
              await gsInstance.signOut();
            } catch (_) {}
          }
          throw SocialAuthReauthNeeded(errStr);
        }

        if (e.code == gsign.GoogleSignInExceptionCode.canceled ||
            e.code == gsign.GoogleSignInExceptionCode.interrupted) {
          throw SocialAuthCancelled();
        }
      }
      if (e.toString().toLowerCase().contains('cancel') ||
          e.toString().toLowerCase().contains('user cancelled')) {
        throw SocialAuthCancelled();
      }
      rethrow;
    }

    final String? fullName = account.displayName;
    final gsign.GoogleSignInAuthentication auth = account.authentication;
    final String? idToken = auth.idToken;

    if (idToken == null || idToken.isEmpty) {
      throw Exception('Google Sign-In returned no ID token');
    }

    return SocialAuthResult(
        provider: 'google', idToken: idToken, fullName: fullName);
  }

  /// Tries to silently recover the Google account the user already selected
  /// in a previous [signInWithGoogle] call — **no account picker UI shown**.
  ///
  /// Used on the Credential Manager false-cancel retry path
  /// (flutter/flutter#171761): after `authenticate()` fires a spurious
  /// "canceled" exception, the account is already cached; calling
  /// `authenticate()` again would show the picker a second time, which is
  /// confusing. This method uses [attemptLightweightAuthentication] — the
  /// v7 replacement for the removed `signInSilently()` — to fetch the
  /// cached account with zero UI.
  ///
  /// Returns `null` if no account is available silently (genuine cancel —
  /// caller should treat that as [SocialAuthCancelled]).
  // ── Debug: last error from signInWithGoogleSilent (cleared on each call) ──
  // Read this in the UI to surface the real exception without USB/adb.
  String? lastSilentError;

  Future<SocialAuthResult?> signInWithGoogleSilent() async {
    lastSilentError = null; // reset each attempt
    // Silent sign-in is not meaningful on web (no cached credential flow).
    if (kIsWeb) return null;
    try {
      final gsign.GoogleSignIn gsInstance = gsign.GoogleSignIn.instance;
      await _ensureInitialized();

      // attemptLightweightAuthentication() is the v7 no-UI equivalent of
      // the removed signInSilently(). It returns null if there is no
      // previously authenticated account to restore.
      final gsign.GoogleSignInAccount? account =
          await gsInstance.attemptLightweightAuthentication();
      debugPrint(
          '[SocialAuth] signInWithGoogleSilent result: ${account?.email ?? "null (no cached account)"}');

      if (account == null) return null;

      final gsign.GoogleSignInAuthentication auth = account.authentication;
      final String? idToken = auth.idToken;

      if (idToken == null || idToken.isEmpty) {
        debugPrint(
            '[SocialAuth] signInWithGoogleSilent: silent account found but no idToken');
        return null;
      }

      return SocialAuthResult(
        provider: 'google',
        idToken: idToken,
        fullName: account.displayName,
      );
    } catch (e, stack) {
      // ── DEBUG: surface the REAL error in the UI (remove after diagnosis) ──
      final errMsg = '[${e.runtimeType}] $e';
      lastSilentError = errMsg;
      debugPrint(
          '[SocialAuth] signInWithGoogleSilent THREW:\n  type : ${e.runtimeType}\n  error: $e\n  stack: $stack');
      return null; // treat any error as "not available silently"
    }
  }

  /// Signs in with Apple and returns an ID token + optional full name.

  /// Throws [SocialAuthCancelled] when the user cancels the flow.
  Future<SocialAuthResult> signInWithApple() async {
    if (kIsWeb) {
      try {
        final fauth.OAuthProvider appleProvider = fauth.OAuthProvider('apple.com')
          ..addScope('email')
          ..addScope('name');
          
        final fauth.UserCredential result =
            await fauth.FirebaseAuth.instance.signInWithPopup(appleProvider);
        
        final fauth.OAuthCredential? oauthCred =
            result.credential as fauth.OAuthCredential?;
        final String? idToken = oauthCred?.idToken;
        if (idToken == null || idToken.isEmpty) {
          throw Exception('Apple Sign-In returned no ID token');
        }

        return SocialAuthResult(
          provider: 'apple',
          idToken: idToken,
          fullName: result.user?.displayName,
        );
      } catch (e) {
        if (e.toString().toLowerCase().contains('popup-closed-by-user') ||
            e.toString().toLowerCase().contains('cancel')) {
          throw SocialAuthCancelled();
        }
        rethrow;
      }
    }

    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );

      final idToken = credential.identityToken;
      if (idToken == null || idToken.isEmpty) throw SocialAuthCancelled();

      final given = credential.givenName ?? '';
      final family = credential.familyName ?? '';
      final fullName = '$given $family'.trim();
      return SocialAuthResult(
          provider: 'apple',
          idToken: idToken,
          fullName: fullName.isEmpty ? null : fullName);
    } catch (e) {
      // The sign_in_with_apple package throws its own exceptions for
      // cancellation; map them to SocialAuthCancelled for callers.
      if (e.toString().toLowerCase().contains('cancel')) {
        throw SocialAuthCancelled();
      }
      rethrow;
    }
  }

  /// Best-effort sign out/cleanup for Google sign-in.
  Future<void> signOutGoogle() async {
    try {
      final gsign.GoogleSignIn gsInstance = gsign.GoogleSignIn.instance;
      try {
        await gsInstance.disconnect();
      } catch (_) {
        try {
          await gsInstance.signOut();
        } catch (_) {}
      }
    } catch (_) {
      // Silent fail — best effort only
    }
  }
}
