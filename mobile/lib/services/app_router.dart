import 'dart:convert';

import 'package:flutter/material.dart';

import '../screens/plan_screen.dart';
import '../screens/progress_screen.dart';
import 'plan_storage.dart';

/// Global navigator key so notification taps can navigate without a BuildContext.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Opens the plan/day/meal encoded in a tapped notification's [payload].
///
/// Payload shape (set in [NotificationService]):
///   {"planId": "...", "day": <0-based day index>, "meal": <0-based meal index, -1 for grocery>}
Future<void> routeFromNotification(String payload) async {
  Map<String, dynamic> data;
  try {
    data = jsonDecode(payload) as Map<String, dynamic>;
  } catch (_) {
    return; // malformed payload — open the app normally
  }

  final planId = (data['planId'] ?? '').toString();
  if (planId.isEmpty) return;
  final type = (data['type'] ?? '').toString();
  final day = _asInt(data['day'], 0);
  final meal = _asInt(data['meal'], -1);

  final all = await PlanStorage.loadAll();
  StoredPlan? match;
  for (final p in all) {
    if (p.id == planId) {
      match = p;
      break;
    }
  }
  if (match == null) return; // plan was deleted — nothing to open
  final sp = match; // final + non-null → safe to capture in the builder closure

  final nav = appNavigatorKey.currentState;
  if (nav == null) return;
  // Hydration nudges open the progress dashboard; meal/grocery open the plan.
  if (type == 'water') {
    nav.push(MaterialPageRoute(builder: (_) => ProgressScreen(stored: sp)));
    return;
  }
  nav.push(MaterialPageRoute(
    builder: (_) => PlanScreen(
      stored: sp,
      location: sp.location,
      initialDay: day,
      highlightMeal: meal >= 0 ? meal : null,
    ),
  ));
}

int _asInt(dynamic v, int fallback) {
  if (v is int) return v;
  return int.tryParse('$v') ?? fallback;
}
