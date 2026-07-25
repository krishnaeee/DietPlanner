import 'package:diet_planner/models/diet_plan.dart';
import 'package:diet_planner/services/plan_storage.dart';
import 'package:diet_planner/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:diet_planner/screens/today_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Meal _meal(String name) => Meal(
      name: name,
      time: '',
      dish: '$name dish',
      description: '',
      calories: 400,
      ingredients: const [],
    );

DayPlan _day(int n) =>
    DayPlan(day: n, totalCalories: 800, meals: [_meal('Breakfast'), _meal('Lunch')]);

StoredPlan _finishedPlan({required String goal, required double target}) => StoredPlan(
      id: 'done1',
      name: 'Cut',
      slot: 0,
      plan: DietPlan(
        summary: '',
        dailyCalorieTarget: 1600,
        days: [_day(1), _day(2)],
        requestedDays: 2, // fully generated → journey complete
        plannedDays: 2,
        truncated: false,
        model: 'test',
      ),
      location: 'Chennai',
      // 10 days ago → today is well past day 2, so the plan reads as finished.
      startDate: DateTime.now().subtract(const Duration(days: 10)),
      remindersScheduled: false,
      scheduledCount: 0,
      savedAt: DateTime.now(),
      startWeightKg: 75,
      targetWeightKg: target,
      request: {'goal': goal, 'weightKg': 75, 'targetWeightKg': target},
    );

void main() {
  testWidgets('completed plan (goal not reached) shows the completion card + continue CTA',
      (tester) async {
    SharedPreferences.setMockInitialValues({}); // no weigh-ins → current == start (75)
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(Brightness.light),
      home: TodayScreen(plan: _finishedPlan(goal: 'lose', target: 70)),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Plan complete'), findsOneWidget);
    // Still at 75 vs a 70 target → not reached → the "keep going" CTA.
    expect(find.text('Keep going toward 70 kg'), findsOneWidget);
    expect(find.textContaining('PLAN COMPLETE'), findsOneWidget); // header label
  });

  testWidgets('completed maintain plan reads as goal reached', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(Brightness.light),
      home: TodayScreen(plan: _finishedPlan(goal: 'maintain', target: 75)),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Goal reached!'), findsOneWidget);
    expect(find.text('Maintain this weight'), findsOneWidget);
  });
}
