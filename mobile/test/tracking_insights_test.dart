import 'package:flutter_test/flutter_test.dart';
import 'package:diet_planner/models/diet_plan.dart';
import 'package:diet_planner/models/tracking.dart';

Meal _m(String name) => Meal(
    name: name, time: '', dish: '$name dish', description: '', calories: 300, ingredients: const []);

DayPlan _day(int n) =>
    DayPlan(day: n, totalCalories: 900, meals: [_m('Breakfast'), _m('Lunch'), _m('Dinner')]);

void main() {
  final start = DateTime.now().subtract(const Duration(days: 9)); // days 0..6 all elapsed
  final plan = DietPlan(
    summary: '',
    dailyCalorieTarget: 1800,
    days: [for (var i = 1; i <= 7; i++) _day(i)],
    requestedDays: 7,
    plannedDays: 7,
    truncated: false,
    model: 'test',
  );

  test('frequentlySkippedSlots flags a slot skipped >= 40% of started days', () {
    var t = PlanTracking();
    // Skip Breakfast (meal 0) on days 0..3 → 4 of 7 days.
    for (final d in [0, 1, 2, 3]) {
      t = t.toggleSkip(d, 0);
    }
    final slots = t.frequentlySkippedSlots(plan, start, DateTime.now());
    expect(slots, contains('Breakfast'));
    expect(slots, isNot(contains('Lunch')));
  });

  test('insights surfaces the most-skipped meal and best streak', () {
    var t = PlanTracking();
    for (final d in [0, 1, 2, 3]) {
      t = t.toggleSkip(d, 0); // Breakfast skipped 4 days running (also active days)
    }
    final ins = t.insights(plan, start, DateTime.now());
    expect(ins.any((s) => s.contains('Breakfast') && s.contains('most-skipped')), isTrue);

    // Days 0..3 are consecutive active days → best streak 4.
    expect(t.bestStreak(start), 4);
    expect(ins.any((s) => s.contains('best streak')), isTrue);
  });

  test('no insights when there is nothing notable', () {
    // A clean plan with a couple of eaten meals and no skips → no strong signal.
    var t = PlanTracking().toggleMeal(0, 0).toggleMeal(0, 1);
    expect(t.frequentlySkippedSlots(plan, start, DateTime.now()), isEmpty);
  });
}
