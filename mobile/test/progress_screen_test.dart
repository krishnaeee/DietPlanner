import 'dart:convert';

import 'package:diet_planner/models/diet_plan.dart';
import 'package:diet_planner/models/tracking.dart';
import 'package:diet_planner/screens/progress_screen.dart';
import 'package:diet_planner/services/plan_storage.dart';
import 'package:diet_planner/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

DietPlan _plan() => DietPlan(
      summary: 'Test plan',
      dailyCalorieTarget: 1800,
      days: [
        DayPlan(day: 1, totalCalories: 1790, meals: [
          Meal(name: 'Breakfast', time: '08:00', dish: 'Idli', description: '', calories: 400, ingredients: []),
          Meal(name: 'Lunch', time: '13:00', dish: 'Rice', description: '', calories: 600, ingredients: []),
        ]),
        DayPlan(day: 2, totalCalories: 1800, meals: [
          Meal(name: 'Breakfast', time: '08:00', dish: 'Dosa', description: '', calories: 450, ingredients: []),
        ]),
      ],
      requestedDays: 7,
      plannedDays: 2,
      truncated: false,
      model: 'test',
    );

StoredPlan _stored() => StoredPlan(
      id: 'p1',
      name: 'Me',
      slot: 0,
      plan: _plan(),
      location: 'Pollachi',
      startDate: DateTime.now().subtract(const Duration(days: 1)),
      remindersScheduled: false,
      scheduledCount: 0,
      savedAt: DateTime.now().subtract(const Duration(days: 5)),
      startWeightKg: 80,
      targetWeightKg: 70,
    );

void main() {
  testWidgets('Progress screen renders the chart with weigh-ins without error',
      (tester) async {
    final t = PlanTracking(
      weighIns: [
        WeighIn(date: DateTime.now().subtract(const Duration(days: 3)), kg: 79),
        WeighIn(date: DateTime.now(), kg: 78),
      ],
      waterByDate: {dateKey(DateTime.now()): 3},
    );
    SharedPreferences.setMockInitialValues({
      'tracking_v1': jsonEncode({'p1': t.toJson()}),
    });

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(Brightness.dark),
      home: ProgressScreen(stored: _stored()),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('CURRENT WEIGHT'), findsOneWidget);
    expect(find.text("Log today's weight"), findsOneWidget);
  });

  testWidgets('Logging a weight rebuilds without error', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(Brightness.dark),
      home: ProgressScreen(stored: _stored()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text("Log today's weight"));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '77');
    await tester.tap(find.text('Save weight'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
