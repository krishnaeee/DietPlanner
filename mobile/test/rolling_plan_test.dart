import 'package:diet_planner/models/diet_plan.dart';
import 'package:flutter_test/flutter_test.dart';

DayPlan _day(int day) => DayPlan(
      day: day,
      totalCalories: 1800,
      meals: [
        Meal(
          name: 'Lunch',
          time: '13:00',
          dish: 'Dish $day',
          description: '',
          calories: 600,
          ingredients: [],
        ),
      ],
    );

DietPlan _base({int requestedDays = 180}) => DietPlan(
      summary: 's',
      dailyCalorieTarget: 1800,
      days: [for (var d = 1; d <= 7; d++) _day(d)],
      requestedDays: requestedDays,
      plannedDays: 7,
      truncated: true,
      model: 'test',
    );

void main() {
  group('DietPlan.withAppendedDays', () {
    test('renumbers appended days contiguously from the last day', () {
      final merged = _base().withAppendedDays([for (var d = 1; d <= 7; d++) _day(d)]);
      // Even though the batch is numbered 1..7, it must become 8..14.
      expect(merged.days.map((d) => d.day).toList(),
          [for (var d = 1; d <= 14; d++) d]);
      expect(merged.plannedDays, 14);
      expect(merged.truncated, isTrue);
    });

    test('next-start cursor always advances (no infinite re-request)', () {
      var plan = _base();
      // Simulate the model always renumbering from 1; the cursor must still climb.
      final starts = <int>[];
      for (var i = 0; i < 3; i++) {
        starts.add(plan.days.last.day + 1); // what _loadNextWeek would send
        plan = plan.withAppendedDays([for (var d = 1; d <= 7; d++) _day(d)]);
      }
      expect(starts, [8, 15, 22]); // strictly increasing — never stuck at 8
    });

    test('caps appended days at requestedDays (no overshoot)', () {
      // 7 already + a 7-day batch into a 10-day goal → only 3 added.
      final merged = _base(requestedDays: 10)
          .withAppendedDays([for (var d = 1; d <= 7; d++) _day(d)]);
      expect(merged.days.length, 10);
      expect(merged.days.last.day, 10);
      expect(merged.truncated, isFalse);
    });

    test('appends nothing once the journey is complete', () {
      final full = _base(requestedDays: 7); // already 7 of 7
      final merged = full.withAppendedDays([_day(1)]);
      expect(merged.days.length, 7);
      expect(merged.truncated, isFalse);
    });
  });

  group('DietPlan.withReplacedMeal', () {
    Meal meal(int cals) => Meal(
          name: 'Lunch',
          time: '13:00',
          dish: 'New dish',
          description: '',
          calories: cals,
          protein: 30,
          carbs: 40,
          fat: 10,
          ingredients: [],
        );

    DietPlan plan() => DietPlan(
          summary: 's',
          dailyCalorieTarget: 1800,
          dailyProteinTarget: 120,
          dailyCarbsTarget: 180,
          dailyFatTarget: 50,
          days: [
            DayPlan(day: 1, totalCalories: 1000, meals: [_day(1).meals.first, meal(600)]),
          ],
          requestedDays: 7,
          plannedDays: 1,
          truncated: true,
          model: 'test',
        );

    test('replaces the meal and recomputes the day total', () {
      final p = plan();
      final firstCals = p.days[0].meals[0].calories;
      final merged = p.withReplacedMeal(0, 1, meal(750));
      expect(merged.days[0].meals[1].dish, 'New dish');
      expect(merged.days[0].totalCalories, firstCals + 750);
      // Macro targets are preserved across a swap.
      expect(merged.dailyProteinTarget, 120);
    });

    test('out-of-range indices are a no-op', () {
      final p = plan();
      expect(p.withReplacedMeal(5, 0, meal(700)).days[0].totalCalories,
          p.days[0].totalCalories);
      expect(p.withReplacedMeal(0, 9, meal(700)).days[0].totalCalories,
          p.days[0].totalCalories);
    });
  });
}
