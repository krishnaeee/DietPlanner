import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/recipe.dart';

/// A tiny on-device cache of generated recipes, keyed by the same normalised
/// dish name the server uses. It's a UX layer, not the source of truth: the
/// server's global cache already makes a re-fetch free, so this just avoids the
/// round-trip and works offline. Device-wide (recipes aren't user-private).
class RecipeStore {
  RecipeStore._();

  /// The exact normalisation the backend's `recipeKey` uses, so a locally-cached
  /// recipe and a server lookup agree on identity.
  static String keyFor(String dish) =>
      dish.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _prefKey(String dish) => 'recipe_v1::${keyFor(dish)}';

  static Future<Recipe?> get(String dish) async {
    if (keyFor(dish).isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey(dish));
    if (raw == null) return null;
    try {
      return Recipe.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> put(String dish, Recipe recipe) async {
    if (keyFor(dish).isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey(dish), jsonEncode(recipe.toJson()));
  }
}
