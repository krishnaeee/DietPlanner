import 'package:flutter_test/flutter_test.dart';
import 'package:diet_planner/models/recipe.dart';
import 'package:diet_planner/services/recipe_store.dart';

void main() {
  test('Recipe.fromJson parses and coerces', () {
    final r = Recipe.fromJson({
      'dish': 'Idli',
      'servings': 4,
      'prepMinutes': '30', // string → int
      'steps': ['Soak', '', 'Grind', '  Steam  '], // blanks dropped, trimmed
      'tips': ['Ferment overnight'],
    });
    expect(r.dish, 'Idli');
    expect(r.servings, 4);
    expect(r.prepMinutes, 30);
    expect(r.steps, ['Soak', 'Grind', 'Steam']);
    expect(r.tips, ['Ferment overnight']);
  });

  test('Recipe survives the json round-trip', () {
    final r = Recipe(
        dish: 'Dosa', servings: 2, prepMinutes: 20, steps: ['Batter', 'Cook'], tips: []);
    final back = Recipe.fromJson(r.toJson());
    expect(back.dish, 'Dosa');
    expect(back.steps, ['Batter', 'Cook']);
    expect(back.tips, isEmpty);
  });

  test('RecipeStore.keyFor matches the backend normalisation', () {
    // Must mirror db.js recipeKey: lowercase, collapse whitespace, trim.
    expect(RecipeStore.keyFor('Idli'), 'idli');
    expect(RecipeStore.keyFor('  Masala   Dosa  '), 'masala dosa');
    expect(RecipeStore.keyFor('IDLI'), RecipeStore.keyFor('idli'));
  });
}
