import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/tracking.dart';
import 'auth_service.dart';
import 'sync_service.dart';

/// Persists per-plan [PlanTracking] in a single per-account blob, mirroring the
/// key scheme of [PlanStorage]: each signed-in user gets their own key so
/// tracking data never leaks between accounts sharing a device. Local-only.
class TrackingStorage {
  TrackingStorage._();
  static const _base = 'tracking_v1';

  /// Bumped on every write so screens sharing a plan's tracking (Today ↔
  /// Progress) reload instead of showing — or clobbering — a stale copy.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static String get _key {
    final email = AuthService.instance.email;
    return (email == null || email.isEmpty) ? _base : '$_base::$email';
  }

  static Future<Map<String, dynamic>> _loadMap() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  /// Tracking for [planId] — an empty [PlanTracking] if none saved yet.
  static Future<PlanTracking> load(String planId) async {
    final map = await _loadMap();
    final m = map[planId];
    if (m is Map) return PlanTracking.fromJson(m.cast<String, dynamic>());
    return PlanTracking();
  }

  static Future<void> save(String planId, PlanTracking t) async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _loadMap();
    map[planId] = t.toJson();
    await prefs.setString(_key, jsonEncode(map));
    revision.value++;
    SyncService.instance.pushTracking(planId, t); // best-effort server sync
  }

  /// Drops a plan's tracking (call when the plan itself is deleted).
  static Future<void> remove(String planId) async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _loadMap();
    if (map.remove(planId) != null) {
      await prefs.setString(_key, jsonEncode(map));
    }
  }
}
