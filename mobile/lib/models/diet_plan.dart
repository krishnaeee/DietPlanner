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
  final int protein; // grams
  final int carbs; // grams
  final int fat; // grams
  final List<Ingredient> ingredients;

  Meal({
    required this.name,
    required this.time,
    required this.dish,
    required this.description,
    required this.calories,
    this.protein = 0,
    this.carbs = 0,
    this.fat = 0,
    required this.ingredients,
  });

  factory Meal.fromJson(Map<String, dynamic> j) => Meal(
        name: (j['name'] ?? '').toString(),
        time: (j['time'] ?? '').toString(),
        dish: (j['dish'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
        calories: _toInt(j['calories']),
        protein: _toInt(j['protein']),
        carbs: _toInt(j['carbs']),
        fat: _toInt(j['fat']),
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
        'protein': protein,
        'carbs': carbs,
        'fat': fat,
        'ingredients': ingredients.map((e) => e.toJson()).toList(),
      };
}

class DayPlan {
  final int day;
  final int totalCalories;
  final List<Meal> meals;

  DayPlan({required this.day, required this.totalCalories, required this.meals});

  int get totalProtein => meals.fold(0, (s, m) => s + m.protein);
  int get totalCarbs => meals.fold(0, (s, m) => s + m.carbs);
  int get totalFat => meals.fold(0, (s, m) => s + m.fat);

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
  final int dailyProteinTarget; // grams
  final int dailyCarbsTarget; // grams
  final int dailyFatTarget; // grams
  final List<DayPlan> days;

  // From the response `meta` block.
  final int requestedDays;
  final int plannedDays;
  final bool truncated;
  final String model;

  DietPlan({
    required this.summary,
    required this.dailyCalorieTarget,
    this.dailyProteinTarget = 0,
    this.dailyCarbsTarget = 0,
    this.dailyFatTarget = 0,
    required this.days,
    required this.requestedDays,
    required this.plannedDays,
    required this.truncated,
    required this.model,
  });

  /// True when the plan carries macro targets (plans generated before macros
  /// existed don't — the UI hides macro chrome for those).
  bool get hasMacros => dailyProteinTarget > 0 || dailyCarbsTarget > 0 || dailyFatTarget > 0;

  factory DietPlan.fromResponse(Map<String, dynamic> body) {
    final plan = (body['plan'] ?? {}) as Map<String, dynamic>;
    final meta = (body['meta'] ?? {}) as Map<String, dynamic>;
    return DietPlan(
      summary: (plan['summary'] ?? '').toString(),
      dailyCalorieTarget: _toInt(plan['dailyCalorieTarget']),
      dailyProteinTarget: _toInt(plan['dailyProteinTarget']),
      dailyCarbsTarget: _toInt(plan['dailyCarbsTarget']),
      dailyFatTarget: _toInt(plan['dailyFatTarget']),
      days: ((plan['days'] as List?) ?? [])
          .map((e) => DayPlan.fromJson(e as Map<String, dynamic>))
          .toList(),
      requestedDays: _toInt(meta['requestedDays']),
      plannedDays: _toInt(meta['plannedDays']),
      truncated: meta['truncated'] == true,
      model: (meta['model'] ?? '').toString(),
    );
  }

  /// Returns a copy with [more] days appended (a freshly generated next week),
  /// recomputing how much of the requested journey is now covered.
  ///
  /// The appended days are **renumbered contiguously** from the current last day
  /// and capped at [requestedDays]. The model often ignores the "number days N
  /// to M" instruction and renumbers from 1; trusting its numbers would create
  /// duplicate day numbers and stall the "next start" cursor (re-requesting the
  /// same week forever). Renumbering here makes the merge robust regardless.
  ///
  /// The optional daily-target overrides let the plan **adopt a re-targeted**
  /// calorie/macro number from the new batch (the adaptive re-target loop moves
  /// it as the user's weight changes). When omitted or non-positive, the current
  /// targets are kept — so a normal extend, which returns the same numbers, is a
  /// no-op on the targets.
  DietPlan withAppendedDays(
    List<DayPlan> more, {
    int? dailyCalorieTarget,
    int? dailyProteinTarget,
    int? dailyCarbsTarget,
    int? dailyFatTarget,
  }) {
    final room = requestedDays - days.length;
    final take = room > 0 ? more.take(room) : const <DayPlan>[];
    var nextDay = days.isEmpty ? 1 : days.last.day + 1;
    final renumbered = take
        .map((d) => DayPlan(
              day: nextDay++,
              totalCalories: d.totalCalories,
              meals: d.meals,
            ))
        .toList();
    final all = [...days, ...renumbered];
    int keep(int? next, int current) => (next != null && next > 0) ? next : current;
    return DietPlan(
      summary: summary,
      dailyCalorieTarget: keep(dailyCalorieTarget, this.dailyCalorieTarget),
      dailyProteinTarget: keep(dailyProteinTarget, this.dailyProteinTarget),
      dailyCarbsTarget: keep(dailyCarbsTarget, this.dailyCarbsTarget),
      dailyFatTarget: keep(dailyFatTarget, this.dailyFatTarget),
      days: all,
      requestedDays: requestedDays,
      plannedDays: all.length,
      truncated: all.length < requestedDays,
      model: model,
    );
  }

  /// Returns a copy with one meal replaced (a "swap"), recomputing that day's
  /// total calories from the new meal set.
  DietPlan withReplacedMeal(int dayIndex, int mealIndex, Meal meal) {
    if (dayIndex < 0 || dayIndex >= days.length) return this;
    final day = days[dayIndex];
    if (mealIndex < 0 || mealIndex >= day.meals.length) return this;
    final meals = [...day.meals];
    meals[mealIndex] = meal;
    final newDays = [...days];
    newDays[dayIndex] = DayPlan(
      day: day.day,
      totalCalories: meals.fold(0, (s, m) => s + m.calories),
      meals: meals,
    );
    return DietPlan(
      summary: summary,
      dailyCalorieTarget: dailyCalorieTarget,
      dailyProteinTarget: dailyProteinTarget,
      dailyCarbsTarget: dailyCarbsTarget,
      dailyFatTarget: dailyFatTarget,
      days: newDays,
      requestedDays: requestedDays,
      plannedDays: plannedDays,
      truncated: truncated,
      model: model,
    );
  }

  /// Serializes back to the same `{plan, meta}` shape `fromResponse` parses,
  /// so it can be stored locally and re-loaded losslessly.
  Map<String, dynamic> toResponseJson() => {
        'plan': {
          'summary': summary,
          'dailyCalorieTarget': dailyCalorieTarget,
          'dailyProteinTarget': dailyProteinTarget,
          'dailyCarbsTarget': dailyCarbsTarget,
          'dailyFatTarget': dailyFatTarget,
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
