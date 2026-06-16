import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/diet_plan.dart';
import 'auth_service.dart';

/// One saved, named plan plus its reminder state.
///
/// [slot] is a small, stable integer unique per plan. It namespaces this plan's
/// notification IDs (base = slot * 100000) so reminders for different people
/// (e.g. me / wife / son) never collide and can be turned on independently.
class StoredPlan {
  final String id;
  final String name;
  final int slot;
  final DietPlan plan;
  final String location;
  final DateTime startDate; // calendar date of Day 1
  final bool remindersScheduled;
  final int scheduledCount;
  final DateTime savedAt;

  StoredPlan({
    required this.id,
    required this.name,
    required this.slot,
    required this.plan,
    required this.location,
    required this.startDate,
    required this.remindersScheduled,
    required this.scheduledCount,
    required this.savedAt,
  });

  StoredPlan copyWith({
    String? name,
    DateTime? startDate,
    bool? remindersScheduled,
    int? scheduledCount,
  }) =>
      StoredPlan(
        id: id,
        name: name ?? this.name,
        slot: slot,
        plan: plan,
        location: location,
        startDate: startDate ?? this.startDate,
        remindersScheduled: remindersScheduled ?? this.remindersScheduled,
        scheduledCount: scheduledCount ?? this.scheduledCount,
        savedAt: savedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'slot': slot,
        'plan': plan.toResponseJson(),
        'location': location,
        'startDate': startDate.toIso8601String(),
        'remindersScheduled': remindersScheduled,
        'scheduledCount': scheduledCount,
        'savedAt': savedAt.toIso8601String(),
      };

  static StoredPlan fromJson(Map<String, dynamic> m) => StoredPlan(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? 'My plan').toString(),
        slot: m['slot'] is int ? m['slot'] as int : 0,
        plan: DietPlan.fromResponse(m['plan'] as Map<String, dynamic>),
        location: (m['location'] ?? '').toString(),
        startDate:
            DateTime.tryParse((m['startDate'] ?? '').toString()) ?? DateTime.now(),
        remindersScheduled: m['remindersScheduled'] == true,
        scheduledCount: m['scheduledCount'] is int ? m['scheduledCount'] as int : 0,
        savedAt: DateTime.tryParse((m['savedAt'] ?? '').toString()) ?? DateTime.now(),
      );
}

/// Persists a **per-account** list of named plans to device storage. Each
/// logged-in user gets their own key, so plans don't leak between users sharing
/// a device. Still local-only (not synced across devices).
class PlanStorage {
  PlanStorage._();
  static const _base = 'saved_plans_v2';
  static const _legacySingle = 'saved_plan_v1';

  // Per-user storage key (falls back to the shared base when logged out).
  static String get _key {
    final email = AuthService.instance.email;
    return (email == null || email.isEmpty) ? _base : '$_base::$email';
  }

  static Future<List<StoredPlan>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();

    final raw = prefs.getString(_key);
    if (raw != null) return _parse(raw);

    // First load for this account: adopt any pre-auth (device-wide) plans once,
    // so a plan created before logging in isn't lost. Only the first account to
    // log in inherits them; later accounts start empty.
    if (_key != _base) {
      final global = prefs.getString(_base);
      if (global != null) {
        await prefs.setString(_key, global);
        await prefs.remove(_base);
        return _parse(global);
      }
    }

    // Even older single-plan format → adopt into this account.
    final single = prefs.getString(_legacySingle);
    if (single != null) {
      try {
        final m = jsonDecode(single) as Map<String, dynamic>;
        final migrated = StoredPlan(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: 'My plan',
          slot: 0,
          plan: DietPlan.fromResponse(m['plan'] as Map<String, dynamic>),
          location: (m['location'] ?? '').toString(),
          startDate:
              DateTime.tryParse((m['startDate'] ?? '').toString()) ?? DateTime.now(),
          remindersScheduled: m['remindersScheduled'] == true,
          scheduledCount: m['scheduledCount'] is int ? m['scheduledCount'] as int : 0,
          savedAt: DateTime.now(),
        );
        await _saveList([migrated]);
        await prefs.remove(_legacySingle);
        return [migrated];
      } catch (_) {
        return [];
      }
    }
    return [];
  }

  static List<StoredPlan> _parse(String raw) {
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => StoredPlan.fromJson(e as Map<String, dynamic>))
          .toList();
      list.sort((a, b) => b.savedAt.compareTo(a.savedAt)); // newest first
      return list;
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveList(List<StoredPlan> plans) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(plans.map((e) => e.toJson()).toList()));
  }

  static Future<void> upsert(StoredPlan p) async {
    final all = await loadAll();
    final i = all.indexWhere((e) => e.id == p.id);
    if (i >= 0) {
      all[i] = p;
    } else {
      all.add(p);
    }
    await _saveList(all);
  }

  static Future<void> rename(String id, String name) async {
    final all = await loadAll();
    final i = all.indexWhere((e) => e.id == id);
    if (i >= 0) {
      all[i] = all[i].copyWith(name: name);
      await _saveList(all);
    }
  }

  static Future<void> delete(String id) async {
    final all = await loadAll();
    all.removeWhere((e) => e.id == id);
    await _saveList(all);
  }

  /// Smallest slot integer not used by [existing] — for notification namespacing.
  static int nextSlot(List<StoredPlan> existing) {
    final used = existing.map((e) => e.slot).toSet();
    var s = 0;
    while (used.contains(s)) {
      s++;
    }
    return s;
  }
}
