/// Where the backend proxy lives.
///
/// Defaults to the hosted backend on Render. For local development against a
/// backend running on your machine, override at run time:
///   flutter run --dart-define=API_BASE_URL=http://localhost:3000
///   (Android emulator: use http://10.0.2.2:3000 instead)
class AppConfig {
  static const String _override = String.fromEnvironment('API_BASE_URL');

  /// The hosted backend (Render). Used unless overridden via --dart-define.
  static const String _production =
      'https://diet-planner-backend-qnux.onrender.com';

  /// The Google **Web** OAuth client ID, passed as `serverClientId` so the
  /// ID token is minted for an audience the backend can verify. Set with:
  ///   flutter run --dart-define=GOOGLE_SERVER_CLIENT_ID=xxxx.apps.googleusercontent.com
  static const String googleServerClientId =
      String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

  static String get apiBaseUrl {
    if (_override.isNotEmpty) return _override;
    return _production;
  }
}
