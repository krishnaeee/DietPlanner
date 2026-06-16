// Data models mirroring the backend's structured plan response.
// fromJson parses the API/stored shape; toJson serializes back for local storage.

int _toInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.round();
  return int.tryParse('$v') ?? 0;
}

class Ingredient {
  final String name;
  final String quantity;

  Ingredient({required this.name, required this.quantity});

  factory Ingredient.fromJson(Map<String, dynamic> j) => Ingredient(
        name: (j['name'] ?? '').toString(),
        quantity: (j['quantity'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {'name': name, 'quantity': quantity};
}

class Meal {
  final String name;
  final String time;
  final String dish;
  final String description;
  final int calories;
  final List<Ingredient> ingredients;

  Meal({
    required this.name,
    required this.time,
    required this.dish,
    required this.description,
    required this.calories,
    required this.ingredients,
  });

  factory Meal.fromJson(Map<String, dynamic> j) => Meal(
        name: (j['name'] ?? '').toString(),
        time: (j['time'] ?? '').toString(),
        dish: (j['dish'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
        calories: _toInt(j['calories']),
        ingredients: ((j['ingredients'] as List?) ?? [])
            .map((e) => Ingredient.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'time': time,
        'dish': dish,
        'description': description,
        'calories': calories,
        'ingredients': ingredients.map((e) => e.toJson()).toList(),
      };
}

class DayPlan {
  final int day;
  final int totalCalories;
  final List<Meal> meals;

  DayPlan({required this.day, required this.totalCalories, required this.meals});

  factory DayPlan.fromJson(Map<String, dynamic> j) => DayPlan(
        day: _toInt(j['day']),
        totalCalories: _toInt(j['totalCalories']),
        meals: ((j['meals'] as List?) ?? [])
            .map((e) => Meal.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'day': day,
        'totalCalories': totalCalories,
        'meals': meals.map((e) => e.toJson()).toList(),
      };
}

class DietPlan {
  final String summary;
  final int dailyCalorieTarget;
  final List<DayPlan> days;

  // From the response `meta` block.
  final int requestedDays;
  final int plannedDays;
  final bool truncated;
  final String model;

  DietPlan({
    required this.summary,
    required this.dailyCalorieTarget,
    required this.days,
    required this.requestedDays,
    required this.plannedDays,
    required this.truncated,
    required this.model,
  });

  factory DietPlan.fromResponse(Map<String, dynamic> body) {
    final plan = (body['plan'] ?? {}) as Map<String, dynamic>;
    final meta = (body['meta'] ?? {}) as Map<String, dynamic>;
    return DietPlan(
      summary: (plan['summary'] ?? '').toString(),
      dailyCalorieTarget: _toInt(plan['dailyCalorieTarget']),
      days: ((plan['days'] as List?) ?? [])
          .map((e) => DayPlan.fromJson(e as Map<String, dynamic>))
          .toList(),
      requestedDays: _toInt(meta['requestedDays']),
      plannedDays: _toInt(meta['plannedDays']),
      truncated: meta['truncated'] == true,
      model: (meta['model'] ?? '').toString(),
    );
  }

  /// Serializes back to the same `{plan, meta}` shape `fromResponse` parses,
  /// so it can be stored locally and re-loaded losslessly.
  Map<String, dynamic> toResponseJson() => {
        'plan': {
          'summary': summary,
          'dailyCalorieTarget': dailyCalorieTarget,
          'days': days.map((e) => e.toJson()).toList(),
        },
        'meta': {
          'requestedDays': requestedDays,
          'plannedDays': plannedDays,
          'truncated': truncated,
          'model': model,
        },
      };
}
