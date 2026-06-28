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
  /// ID token is minted for an audience the backend can verify. Baked in by
  /// default (it's a public value); override per build if needed with:
  ///   flutter run --dart-define=GOOGLE_SERVER_CLIENT_ID=xxxx.apps.googleusercontent.com
  static const String _googleClientIdOverride =
      String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

  /// Default Web client ID — must match the backend's GOOGLE_WEB_CLIENT_ID.
  static const String _googleClientIdDefault =
      '26666014882-n4mudqgpjmr0tokve8lc1u4ulpiecfao.apps.googleusercontent.com';

  static String get googleServerClientId =>
      _googleClientIdOverride.isNotEmpty
          ? _googleClientIdOverride
          : _googleClientIdDefault;

  static String get apiBaseUrl {
    if (_override.isNotEmpty) return _override;
    return _production;
  }

  /// RevenueCat public SDK keys (one per store). Pass at build time:
  ///   flutter build ios --dart-define=REVENUECAT_IOS_API_KEY=appl_xxx
  ///   flutter build appbundle --dart-define=REVENUECAT_ANDROID_API_KEY=goog_xxx
  /// Left blank by default — the app falls back to the server's mock/Stripe
  /// billing until these are set and BILLING_PROVIDER=revenuecat on the backend.
  static const String revenueCatIosKey =
      String.fromEnvironment('REVENUECAT_IOS_API_KEY');
  static const String revenueCatAndroidKey =
      String.fromEnvironment('REVENUECAT_ANDROID_API_KEY');
}
