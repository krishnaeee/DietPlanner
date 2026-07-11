import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:diet_planner/models/diet_plan.dart';
import 'package:diet_planner/screens/grocery_list_screen.dart';

/// Builds a one-day plan whose only ingredient, "Onion", aggregates to a long
/// combined quantity ("2 pcs medium + 1 pcs large + 3 cups chopped").
DietPlan _planWithLongQuantity() {
  final onionParts = [
    Ingredient(name: 'Onion', quantity: '2 pcs medium'),
    Ingredient(name: 'Onion', quantity: '1 pcs large'),
    Ingredient(name: 'Onion', quantity: '3 cups chopped'),
  ];
  return DietPlan(
    summary: 's',
    dailyCalorieTarget: 2000,
    days: [
      DayPlan(
        day: 1,
        totalCalories: 500,
        meals: [
          Meal(
            name: 'Lunch',
            time: '13:00',
            dish: 'Salad',
            description: '',
            calories: 500,
            ingredients: onionParts,
          ),
        ],
      ),
    ],
    requestedDays: 1,
    plannedDays: 1,
    truncated: false,
    model: 'test',
  );
}

void main() {
  testWidgets(
      'long quantity wraps in its pill and does not stack the ingredient name',
      (tester) async {
    // A phone-width surface so the long quantity genuinely competes for space.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(home: GroceryListScreen(plan: _planWithLongQuantity())),
    );
    await tester.pumpAndSettle();

    // The combined quantity is present…
    expect(find.text('2 pcs medium + 1 pcs large + 3 cups chopped'), findsOneWidget);

    // …and the ingredient name is not collapsed into a vertical stack of
    // single characters. "Onion" must fit within two lines; one character per
    // line would be five lines and far taller.
    final nameSize = tester.getSize(find.text('Onion'));
    expect(nameSize.height, lessThan(60),
        reason: 'name should be at most ~2 lines, not one char per line');
    expect(nameSize.width, greaterThan(40),
        reason: 'name should have real horizontal width, not ~1 glyph wide');

    // No RenderFlex overflow was thrown building the row.
    expect(tester.takeException(), isNull);
  });
}
