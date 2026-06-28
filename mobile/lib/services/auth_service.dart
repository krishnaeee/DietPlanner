import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

/// Email + password auth against the backend. Persists the JWT on the device
/// and exposes a [authState] notifier the UI listens to (logged in vs out).
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  static const _tokenKey = 'auth_token';
  static const _emailKey = 'auth_email';
  static const _userIdKey = 'auth_user_id';

  String? _token;
  String? _email;
  String? _userId;

  /// true = logged in. The auth gate rebuilds when this flips.
  final ValueNotifier<bool> authState = ValueNotifier<bool>(false);

  String? get token => _token;
  String? get email => _email;

  /// The backend user id (as a string). Used as the RevenueCat app user id so
  /// the purchase webhook can attribute the payment to this account.
  String? get userId => _userId;
  bool get isLoggedIn => _token != null;

  /// Loads a saved session into memory. Call once at startup.
  Future<void> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_tokenKey);
    _email = prefs.getString(_emailKey);
    _userId = prefs.getString(_userIdKey);
    authState.value = _token != null;
  }

  Future<void> signup(String email, String password) =>
      _authPost('/api/auth/signup', email, password);

  Future<void> login(String email, String password) =>
      _authPost('/api/auth/login', email, password);

  bool _googleInited = false;

  /// Google sign-in: get a Google ID token, exchange it with the backend for an
  /// app JWT. Returns false if the user cancelled; throws [AuthException] on error.
  Future<bool> googleLogin() async {
    final serverClientId = AppConfig.googleServerClientId;
    if (serverClientId.isEmpty) {
      throw AuthException(
        "Google login isn't configured yet — pass --dart-define=GOOGLE_SERVER_CLIENT_ID=...",
      );
    }

    final google = GoogleSignIn.instance;
    if (!_googleInited) {
      await google.initialize(serverClientId: serverClientId);
      _googleInited = true;
    }
    if (!google.supportsAuthenticate()) {
      throw AuthException("Google sign-in isn't supported on this platform build.");
    }

    GoogleSignInAccount account;
    try {
      account = await google.authenticate();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return false;
      final detail = [e.description, e.details?.toString()]
          .where((s) => s != null && s.isNotEmpty)
          .join(' · ');
      throw AuthException(
        'Google sign-in failed (${e.code.name})'
        '${detail.isEmpty ? '' : ':\n$detail'}',
      );
    }

    final idToken = account.authentication.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw AuthException('Google did not return an ID token. Check the server client ID.');
    }

    final uri = Uri.parse('${AppConfig.apiBaseUrl}/api/auth/google');
    http.Response resp;
    try {
      resp = await http
          .post(uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'idToken': idToken}))
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw AuthException(
        'Could not reach the server at ${AppConfig.apiBaseUrl}. Is the backend running? ($e)',
      );
    }

    final body = _decode(resp.body);
    if (resp.statusCode == 200 || resp.statusCode == 201) {
      final token = body['token'] as String?;
      if (token == null || token.isEmpty) {
        throw AuthException('Unexpected response from the server.');
      }
      final user = body['user'];
      final em = (user is Map ? user['email'] : null)?.toString() ?? account.email;
      final uid = (user is Map ? user['id'] : null)?.toString();
      await _persist(token, em, uid);
      return true;
    }
    throw AuthException(_errorOf(body, resp.statusCode));
  }

  Future<void> _authPost(String path, String email, String password) async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl}$path');
    http.Response resp;
    try {
      resp = await http
          .post(uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'email': email, 'password': password}))
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw AuthException(
        'Could not reach the server at ${AppConfig.apiBaseUrl}.\n'
        'Is the backend running? ($e)',
      );
    }

    final body = _decode(resp.body);
    if (resp.statusCode == 200 || resp.statusCode == 201) {
      final token = body['token'] as String?;
      if (token == null || token.isEmpty) {
        throw AuthException('Unexpected response from the server.');
      }
      final user = body['user'];
      final em = (user is Map ? user['email'] : null)?.toString() ?? email;
      final uid = (user is Map ? user['id'] : null)?.toString();
      await _persist(token, em, uid);
      return;
    }
    throw AuthException(_errorOf(body, resp.statusCode));
  }

  /// Verifies the stored token with the backend. A definitive 401 clears the
  /// session; network errors are tolerated (keeps you in for offline use).
  Future<bool> verify() async {
    if (_token == null) return false;
    final uri = Uri.parse('${AppConfig.apiBaseUrl}/api/auth/me');
    try {
      final resp = await http
          .get(uri, headers: {'Authorization': 'Bearer $_token'})
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 401) {
        await logout();
        return false;
      }
      return true;
    } catch (_) {
      return true; // offline — don't punish the user
    }
  }

  Future<void> logout() async {
    _token = null;
    _email = null;
    _userId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_emailKey);
    await prefs.remove(_userIdKey);
    authState.value = false;
  }

  Future<void> _persist(String token, String email, String? userId) async {
    _token = token;
    _email = email;
    _userId = userId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    await prefs.setString(_emailKey, email);
    if (userId != null) {
      await prefs.setString(_userIdKey, userId);
    } else {
      await prefs.remove(_userIdKey);
    }
    authState.value = true;
  }

  Map<String, dynamic> _decode(String body) {
    try {
      final d = jsonDecode(body);
      return d is Map<String, dynamic> ? d : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  String _errorOf(Map<String, dynamic> body, int status) {
    final e = body['error'];
    if (e is List) return e.join('\n');
    if (e is String) return e;
    return 'Request failed (HTTP $status).';
  }
}
