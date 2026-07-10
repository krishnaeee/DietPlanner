import 'dart:convert';

import 'package:diet_planner/models/diet_plan.dart';
import 'package:diet_planner/screens/today_screen.dart';
import 'package:diet_planner/services/plan_storage.dart';
import 'package:diet_planner/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // A plan that came back with zero days must not crash the Today dashboard
  // (it used to index days[-1]/days[0] on an empty list → RangeError).
  testWidgets('Today shows the empty state for a zero-day plan (no crash)',
      (tester) async {
    final sp = StoredPlan(
      id: 'z1',
      name: 'Zero',
      slot: 0,
      plan: DietPlan(
        summary: '',
        dailyCalorieTarget: 1800,
        days: const [],
        requestedDays: 7,
        plannedDays: 0,
        truncated: true,
        model: 'test',
      ),
      location: 'Chennai',
      startDate: DateTime.now(),
      remindersScheduled: false,
      scheduledCount: 0,
      savedAt: DateTime.now(),
    );
    SharedPreferences.setMockInitialValues({
      'saved_plans_v2': jsonEncode([sp.toJson()]),
    });

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(Brightness.light),
      home: const Scaffold(body: TodayScreen()),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Start your journey'), findsOneWidget);
  });
}
