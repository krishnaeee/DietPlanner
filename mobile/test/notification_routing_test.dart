import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:diet_planner/models/diet_plan.dart';
import 'package:diet_planner/services/plan_storage.dart';
import 'package:diet_planner/services/app_router.dart';
import 'package:diet_planner/screens/grocery_list_screen.dart';
import 'package:diet_planner/screens/plan_screen.dart';
import 'package:diet_planner/screens/progress_screen.dart';

StoredPlan _plan() => StoredPlan(
      id: 'p1',
      name: 'Plan 1',
      slot: 0,
      location: 'Pollachi',
      startDate: DateTime(2026, 1, 1),
      remindersScheduled: true,
      scheduledCount: 0,
      savedAt: DateTime(2026, 1, 1),
      plan: DietPlan(
        summary: 's',
        dailyCalorieTarget: 1800,
        requestedDays: 3,
        plannedDays: 3,
        truncated: false,
        model: 'test',
        days: [
          for (var d = 1; d <= 3; d++)
            DayPlan(day: d, totalCalories: 600, meals: [
              Meal(
                name: 'Lunch',
                time: '13:00',
                dish: 'Rice bowl',
                description: '',
                calories: 600,
                ingredients: [Ingredient(name: 'Rice', quantity: '100 g')],
              ),
            ]),
        ],
      ),
    );

Future<void> _pumpHost(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    navigatorKey: appNavigatorKey,
    home: const Scaffold(body: Text('home')),
  ));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'saved_plans_v2': jsonEncode([_plan().toJson()]),
    });
  });

  testWidgets('grocery notification opens the grocery list, not the plan',
      (tester) async {
    await _pumpHost(tester);
    await routeFromNotification(
        jsonEncode({'planId': 'p1', 'day': 1, 'meal': -1, 'type': 'grocery'}));
    await tester.pumpAndSettle();

    expect(find.byType(GroceryListScreen), findsOneWidget);
    expect(find.byType(PlanScreen), findsNothing);
  });

  // (The meal path routes to PlanScreen — the unchanged fallback. We don't
  // mount PlanScreen here because it keeps an animation timer alive past
  // teardown; the grocery test's `PlanScreen findsNothing` already proves a
  // grocery tap no longer lands there.)

  testWidgets('water notification opens the progress screen', (tester) async {
    await _pumpHost(tester);
    await routeFromNotification(
        jsonEncode({'planId': 'p1', 'day': -1, 'meal': -1, 'type': 'water'}));
    await tester.pumpAndSettle();

    expect(find.byType(ProgressScreen), findsOneWidget);
  });
}
