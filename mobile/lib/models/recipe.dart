/// Step-by-step preparation for one dish, as returned by /api/recipe and cached
/// locally so re-opening it is instant and offline.
class Recipe {
  final String dish;
  final int servings;
  final int prepMinutes;
  final List<String> steps;
  final List<String> tips;

  Recipe({
    required this.dish,
    required this.servings,
    required this.prepMinutes,
    required this.steps,
    required this.tips,
  });

  static int _toInt(dynamic v) =>
      v is int ? v : (v is num ? v.round() : int.tryParse('${v ?? ''}') ?? 0);

  static List<String> _toStrings(dynamic v) => ((v as List?) ?? [])
      .map((e) => '$e'.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  factory Recipe.fromJson(Map<String, dynamic> j) => Recipe(
        dish: (j['dish'] ?? '').toString(),
        servings: _toInt(j['servings']),
        prepMinutes: _toInt(j['prepMinutes']),
        steps: _toStrings(j['steps']),
        tips: _toStrings(j['tips']),
      );

  Map<String, dynamic> toJson() => {
        'dish': dish,
        'servings': servings,
        'prepMinutes': prepMinutes,
        'steps': steps,
        'tips': tips,
      };
}
