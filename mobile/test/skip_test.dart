import 'package:flutter_test/flutter_test.dart';
import 'package:diet_planner/models/tracking.dart';

void main() {
  test('eaten and skipped are mutually exclusive', () {
    var t = PlanTracking();

    // Skip a meal.
    t = t.toggleSkip(0, 1);
    expect(t.isMealSkipped(0, 1), isTrue);
    expect(t.isMealDone(0, 1), isFalse);
    expect(t.isMealResolved(0, 1), isTrue);

    // Marking it eaten clears the skip.
    t = t.toggleMeal(0, 1);
    expect(t.isMealDone(0, 1), isTrue);
    expect(t.isMealSkipped(0, 1), isFalse);

    // Skipping again clears the eaten flag.
    t = t.toggleSkip(0, 1);
    expect(t.isMealSkipped(0, 1), isTrue);
    expect(t.isMealDone(0, 1), isFalse);

    // Toggling skip off returns to unresolved.
    t = t.toggleSkip(0, 1);
    expect(t.isMealResolved(0, 1), isFalse);
  });

  test('skipping counts as an active day (keeps the streak) but not adherence', () {
    final start = DateTime(2026, 7, 20);
    var t = PlanTracking();
    // Skip a meal on plan day 0 (== start date).
    t = t.toggleSkip(0, 0);
    expect(t.activeDays(start).contains(dateKey(start)), isTrue,
        reason: 'a skip is engagement');
    // doneMealsIn only counts eaten, so a skip does not inflate adherence.
    expect(t.doneMealsIn(1), 0);
  });

  test('skipped meals survive the json round-trip', () {
    var t = PlanTracking();
    t = t.toggleMeal(0, 0); // eaten
    t = t.toggleSkip(1, 2); // skipped
    final back = PlanTracking.fromJson(t.toJson());
    expect(back.isMealDone(0, 0), isTrue);
    expect(back.isMealSkipped(1, 2), isTrue);
    expect(back.mealsSkipped, {'1:2'});
  });

  test('older saved tracking with no mealsSkipped still loads', () {
    final back = PlanTracking.fromJson({
      'mealsDone': ['0:0'],
      // no 'mealsSkipped' key (legacy payload)
    });
    expect(back.isMealDone(0, 0), isTrue);
    expect(back.mealsSkipped, isEmpty);
  });
}
