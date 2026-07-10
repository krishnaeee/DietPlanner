import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plan_storage.dart';

/// Which saved plan the Today and Progress tabs follow. On a shared/family
/// device this lets each person pick their own plan instead of always getting
/// whichever was created last. Persisted; defaults to the newest plan.
class ActivePlan {
  ActivePlan._();

  static final ValueNotifier<String?> id = ValueNotifier<String?>(null);
  static const _key = 'active_plan_id';

  /// Restores the saved selection. Call once before runApp.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    id.value = prefs.getString(_key);
  }

  static Future<void> set(String planId) async {
    id.value = planId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, planId);
  }

  /// The selected plan within [plans], or the newest if none/invalid.
  static StoredPlan? resolve(List<StoredPlan> plans) {
    if (plans.isEmpty) return null;
    final sel = id.value;
    if (sel != null) {
      for (final p in plans) {
        if (p.id == sel) return p;
      }
    }
    return plans.first; // newest
  }
}
