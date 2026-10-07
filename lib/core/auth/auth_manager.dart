import 'package:flutter/foundation.dart';
import '../storage/secure_storage.dart';

/// Centralized manager for handling Studio JWT session lifecycle,
/// token storage state, and global forced-logout triggers.
class AuthManager extends ChangeNotifier {
  final SecureStorage _secureStorage;

  String? _accessToken;
  String? _refreshToken;
  bool _isSessionExpired = false;
  bool _disposed = false;

  String? get accessToken => _accessToken;
  String? get refreshToken => _refreshToken;
  bool get isLoggedIn => _accessToken != null && _accessToken!.isNotEmpty;
  bool get isSessionExpired => _isSessionExpired;

  AuthManager({SecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? SecureStorage();

  /// Called on app startup or after auth operations to restore state.
  Future<void> initSession() async {
    _accessToken = await _secureStorage.getAccessToken();
    _refreshToken = await _secureStorage.getRefreshToken();
    _isSessionExpired = false;
    if (!_disposed) notifyListeners();
  }

  void setTokens({required String accessToken, required String? refreshToken}) {
    _accessToken = accessToken;
    if (refreshToken != null) {
      _refreshToken = refreshToken;
    }
    _isSessionExpired = false;
    if (!_disposed) notifyListeners();
  }

  Future<void> handleSessionExpired() async {
    _accessToken = null;
    _refreshToken = null;
    _isSessionExpired = true;
    await _secureStorage.clearTokens();
    await _secureStorage.clearRememberMe();
    if (!_disposed) notifyListeners();
  }

  Future<void> logout() async {
    _accessToken = null;
    _refreshToken = null;
    _isSessionExpired = false;
    await _secureStorage.clearTokens();
    await _secureStorage.clearRememberMe();
    if (!_disposed) notifyListeners();
  }
  
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
