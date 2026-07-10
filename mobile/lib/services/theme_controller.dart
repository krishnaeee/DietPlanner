import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds the app's light/dark preference and persists it. The root listens to
/// this and rebuilds the whole app (and [AppColors.brightness]) when it changes.
class ThemeController extends ChangeNotifier {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  static const _key = 'theme_dark_v1';
  bool _dark = true; // the app ships dark by default

  bool get isDark => _dark;
  Brightness get brightness => _dark ? Brightness.dark : Brightness.light;

  /// Loads the saved preference. Call once before runApp.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _dark = prefs.getBool(_key) ?? true;
  }

  Future<void> setDark(bool dark) async {
    if (_dark == dark) return;
    _dark = dark;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, dark);
  }

  Future<void> toggle() => setDark(!_dark);
}
