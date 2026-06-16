// Smoke test: with no saved session, the app shows the login screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:diet_planner/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // No saved auth token / plans → app should land on the login screen.
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Shows login screen when logged out', (WidgetTester tester) async {
    await tester.pumpWidget(const DietPlannerApp());
    await tester.pumpAndSettle();

    expect(find.text('Welcome back'), findsOneWidget); // login header
    expect(find.text('Email'), findsOneWidget); // email field label
    expect(find.widgetWithText(FilledButton, 'Log in'), findsOneWidget);
  });
}
