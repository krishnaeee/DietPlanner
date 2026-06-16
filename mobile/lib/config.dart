import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;

/// Where the backend proxy lives.
///
/// Override at run time (e.g. for a physical device on your LAN) with:
///   flutter run --dart-define=API_BASE_URL=http://192.168.1.50:3000
class AppConfig {
  static const String _override = String.fromEnvironment('API_BASE_URL');

  /// The Google **Web** OAuth client ID, passed as `serverClientId` so the
  /// ID token is minted for an audience the backend can verify. Set with:
  ///   flutter run --dart-define=GOOGLE_SERVER_CLIENT_ID=xxxx.apps.googleusercontent.com
  static const String googleServerClientId =
      String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

  static String get apiBaseUrl {
    if (_override.isNotEmpty) return _override;
    // The Android emulator reaches the host machine via 10.0.2.2, not localhost.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:3000';
    }
    // iOS simulator, web, desktop all reach the host as localhost.
    return 'http://localhost:3000';
  }
}
