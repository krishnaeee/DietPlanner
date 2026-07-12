import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/diet_plan.dart';
import '../models/tracking.dart';
import 'auth_service.dart';
import 'plan_storage.dart';
import 'tracking_storage.dart';

/// Syncs the phone's locally-stored plans + tracking with the backend so a
/// reinstall or a new device restores the whole journey — SharedPreferences is
/// wiped on uninstall while the server row survives — and so the adaptive
/// re-target audit trail has real plan rows to write against.
///
/// Model: **push-on-write** (best-effort, fire-and-forget from the storage
/// layer) + **pull-on-login** (restore only plans that are missing locally, so
/// the active device's state is never clobbered). Every network failure is
/// swallowed — sync must never block or break the UI; a dropped write is
/// re-sent on the next local change or the next launch.
class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  static const _timeout = Duration(seconds: 15);

  /// True while [pullAll] writes restored data locally, so the storage hooks
  /// don't immediately re-push what we just pulled.
  bool restoring = false;

  bool get _authed => (AuthService.instance.token ?? '').isNotEmpty;
  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${AuthService.instance.token}',
      };
  Uri _uri(String path) => Uri.parse('${AppConfig.apiBaseUrl}$path');

  // ──────────────────────────────────────────────────────────────── push ──

  /// Upserts a plan on the server. Fire-and-forget; safe on every save.
  void pushPlan(StoredPlan p) {
    if (restoring || !_authed) return;
    _fire(() => http.put(_uri('/api/plans/${p.id}'),
        headers: _headers, body: jsonEncode(planBody(p))));
  }

  void deletePlanRemote(String id) {
    if (restoring || !_authed) return;
    _fire(() => http.delete(_uri('/api/plans/$id'), headers: _headers));
  }

  /// Pushes a plan's full tracking snapshot (weigh-ins + done-meals + water).
  void pushTracking(String planId, PlanTracking t) {
    if (restoring || !_authed) return;
    _fire(() => http.put(_uri('/api/plans/$planId/tracking'),
        headers: _headers, body: jsonEncode(t.toJson())));
  }

  void _fire(Future<http.Response> Function() req) {
    () async {
      try {
        await req().timeout(_timeout);
      } catch (_) {
        // Best-effort: retried on the next write / next launch.
      }
    }();
  }

  // ──────────────────────────────────────────────────────────────── pull ──

  /// Restores any server-side plans not present locally (the reinstall /
  /// new-device case) plus their tracking. Existing local plans are left
  /// untouched, so the active device is never overwritten. Returns how many
  /// were restored. Safe to fire-and-forget.
  Future<int> pullAll() async {
    if (!_authed) return 0;
    List<dynamic> serverPlans;
    try {
      final resp =
          await http.get(_uri('/api/plans'), headers: _headers).timeout(_timeout);
      if (resp.statusCode != 200) return 0;
      serverPlans = (jsonDecode(resp.body)['plans'] as List?) ?? const [];
    } catch (_) {
      return 0;
    }
    final localIds = (await PlanStorage.loadAll()).map((e) => e.id).toSet();
    var restored = 0;
    restoring = true;
    try {
      for (final raw in serverPlans) {
        if (raw is! Map) continue;
        final m = raw.cast<String, dynamic>();
        final id = '${m['id'] ?? ''}';
        if (id.isEmpty || localIds.contains(id)) continue;
        final sp = storedFromServer(m);
        if (sp == null) continue;
        await PlanStorage.upsert(sp);
        await _restoreTracking(id);
        restored++;
      }
    } finally {
      restoring = false;
    }
    return restored;
  }

  Future<void> _restoreTracking(String id) async {
    try {
      final resp = await http
          .get(_uri('/api/plans/$id/tracking'), headers: _headers)
          .timeout(_timeout);
      if (resp.statusCode != 200) return;
      final t = (jsonDecode(resp.body)['tracking'] as Map?)?.cast<String, dynamic>();
      if (t != null) await TrackingStorage.save(id, PlanTracking.fromJson(t));
    } catch (_) {
      // best-effort
    }
  }

  // ───────────────────────────────────────────────────────────── mapping ──

  static double? _optD(dynamic v) =>
      v == null ? null : (v is num ? v.toDouble() : double.tryParse('$v'));

  /// StoredPlan → PUT body. Goal/body stats come from the plan's saved request
  /// (the original /api/plan body); the calorie/macro targets come from the plan
  /// so the server's current_calorie_target seeds correctly.
  @visibleForTesting
  Map<String, dynamic> planBody(StoredPlan p) {
    final req = p.request ?? const <String, dynamic>{};
    num? n(String k) {
      final v = req[k];
      return v is num ? v : num.tryParse('${v ?? ''}');
    }

    final goal = (req['goal'] ??
            ((p.targetWeightKg != null && p.startWeightKg != null)
                ? (p.targetWeightKg! < p.startWeightKg!
                    ? 'lose'
                    : p.targetWeightKg! > p.startWeightKg!
                        ? 'gain'
                        : 'maintain')
                : 'maintain'))
        .toString();

    final d = p.startDate;
    final startDate = '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';

    return {
      'name': p.name,
      'slot': p.slot,
      'goal': goal,
      'targetDays': (n('targetDays') ?? p.plan.requestedDays).toInt(),
      'plan': p.plan.toResponseJson(),
      'request': p.request,
      'heightCm': n('heightCm'),
      'age': n('age')?.toInt(),
      'sex': req['sex'],
      'activityLevel': req['activityLevel'],
      'startWeightKg': p.startWeightKg ?? n('weightKg'),
      'targetWeightKg': p.targetWeightKg ?? n('targetWeightKg'),
      'plannedDays': p.plan.plannedDays,
      'startDate': startDate,
      'location': p.location,
      'dietaryPreference': req['dietaryPreference'],
      'currentCalorieTarget': p.plan.dailyCalorieTarget,
      'currentMacros': {
        'protein': p.plan.dailyProteinTarget,
        'carbs': p.plan.dailyCarbsTarget,
        'fat': p.plan.dailyFatTarget,
      },
      'remindersScheduled': p.remindersScheduled,
      'repeatForever': p.repeatForever,
    };
  }

  @visibleForTesting
  StoredPlan? storedFromServer(Map<String, dynamic> m) {
    final blob = m['plan'];
    if (blob is! Map) return null;
    try {
      return StoredPlan(
        id: '${m['id']}',
        name: (m['name'] ?? 'My plan').toString(),
        slot: m['slot'] is int ? m['slot'] as int : int.tryParse('${m['slot']}') ?? 0,
        plan: DietPlan.fromResponse(blob.cast<String, dynamic>()),
        location: (m['location'] ?? '').toString(),
        startDate: DateTime.tryParse('${m['startDate'] ?? ''}') ?? DateTime.now(),
        remindersScheduled: m['remindersScheduled'] == true,
        repeatForever: m['repeatForever'] == true,
        scheduledCount: 0,
        savedAt: DateTime.now(),
        startWeightKg: _optD(m['startWeightKg']),
        targetWeightKg: _optD(m['targetWeightKg']),
        request:
            m['request'] is Map ? Map<String, dynamic>.from(m['request'] as Map) : null,
      );
    } catch (_) {
      return null;
    }
  }
}
