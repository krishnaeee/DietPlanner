import 'package:flutter_test/flutter_test.dart';
import 'package:diet_planner/models/diet_plan.dart';

DietPlan _plan({required int calorieTarget}) => DietPlan(
      summary: 's',
      dailyCalorieTarget: calorieTarget,
      dailyProteinTarget: 130,
      dailyCarbsTarget: 150,
      dailyFatTarget: 50,
      days: [DayPlan(day: 1, totalCalories: calorieTarget, meals: const [])],
      requestedDays: 168,
      plannedDays: 1,
      truncated: true,
      model: 'test',
    );

List<DayPlan> _week() =>
    [for (var i = 0; i < 7; i++) DayPlan(day: 1 + i, totalCalories: 1600, meals: const [])];

void main() {
  test('withAppendedDays adopts a re-targeted calorie/macro number', () {
    final base = _plan(calorieTarget: 1581);
    final merged = base.withAppendedDays(
      _week(),
      dailyCalorieTarget: 1618,
      dailyProteinTarget: 130,
      dailyCarbsTarget: 162,
      dailyFatTarget: 50,
    );
    expect(merged.dailyCalorieTarget, 1618, reason: 'new target adopted');
    expect(merged.dailyCarbsTarget, 162);
    expect(merged.days.length, 8, reason: 'week appended');
  });

  test('a normal extend (same/absent target) keeps the current target', () {
    final base = _plan(calorieTarget: 1581);
    // Omitted overrides → unchanged.
    expect(base.withAppendedDays(_week()).dailyCalorieTarget, 1581);
    // A zero/garbage target must not clobber the real one.
    expect(
      base.withAppendedDays(_week(), dailyCalorieTarget: 0).dailyCalorieTarget,
      1581,
    );
  });
}
