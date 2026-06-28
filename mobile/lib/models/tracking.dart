// Per-plan engagement data: weigh-ins, checked-off meals, and water intake.
// Persisted locally per account by TrackingStorage, keyed by the plan's id.

import 'diet_plan.dart';

/// A date as a stable, sortable `yyyy-mm-dd` string (local calendar day).
String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

double _toDouble(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse('$v') ?? 0;
}

int _toInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.round();
  return int.tryParse('$v') ?? 0;
}

/// A single body-weight measurement on a calendar day.
class WeighIn {
  final DateTime date; // date-only (local)
  final double kg;

  WeighIn({required this.date, required this.kg});

  Map<String, dynamic> toJson() => {'date': dateKey(date), 'kg': kg};

  static WeighIn fromJson(Map<String, dynamic> j) => WeighIn(
        date: DateTime.tryParse((j['date'] ?? '').toString()) ?? DateTime.now(),
        kg: _toDouble(j['kg']),
      );
}

/// All tracking state for one plan.
class PlanTracking {
  /// Weigh-ins, kept sorted oldest → newest.
  final List<WeighIn> weighIns;

  /// Completed meals, keyed `"<dayIndex>:<mealIndex>"` (both 0-based).
  final Set<String> mealsDone;

  /// Glasses of water drunk, keyed by [dateKey].
  final Map<String, int> waterByDate;

  /// Daily water goal in glasses.
  final int waterGoal;

  /// Whether daily hydration reminders are scheduled for this plan.
  final bool waterRemindersOn;

  PlanTracking({
    this.weighIns = const [],
    this.mealsDone = const {},
    this.waterByDate = const {},
    this.waterGoal = 8,
    this.waterRemindersOn = false,
  });

  PlanTracking copyWith({
    List<WeighIn>? weighIns,
    Set<String>? mealsDone,
    Map<String, int>? waterByDate,
    int? waterGoal,
    bool? waterRemindersOn,
  }) =>
      PlanTracking(
        weighIns: weighIns ?? this.weighIns,
        mealsDone: mealsDone ?? this.mealsDone,
        waterByDate: waterByDate ?? this.waterByDate,
        waterGoal: waterGoal ?? this.waterGoal,
        waterRemindersOn: waterRemindersOn ?? this.waterRemindersOn,
      );

  // ───────────────────────────────────────────────────────── reads ──

  bool isMealDone(int day, int meal) => mealsDone.contains('$day:$meal');

  int waterFor(DateTime d) => waterByDate[dateKey(d)] ?? 0;

  double? get firstWeight => weighIns.isEmpty ? null : weighIns.first.kg;
  double? get latestWeight => weighIns.isEmpty ? null : weighIns.last.kg;

  /// Number of meals checked off across plan-day indices `0..elapsedDays-1`.
  int doneMealsIn(int elapsedDays) {
    var n = 0;
    for (final k in mealsDone) {
      final day = int.tryParse(k.split(':').first);
      if (day != null && day < elapsedDays) n++;
    }
    return n;
  }

  // ──────────────────────────────────────────────────────── writes ──

  /// Toggles a meal's completion and returns the updated tracking.
  PlanTracking toggleMeal(int day, int meal) {
    final key = '$day:$meal';
    final next = Set<String>.from(mealsDone);
    if (!next.remove(key)) next.add(key);
    return copyWith(mealsDone: next);
  }

  /// Records (or replaces) the weigh-in for [date]'s calendar day.
  PlanTracking withWeighIn(DateTime date, double kg) {
    final k = dateKey(date);
    final list = weighIns.where((w) => dateKey(w.date) != k).toList()
      ..add(WeighIn(date: DateTime(date.year, date.month, date.day), kg: kg));
    list.sort((a, b) => a.date.compareTo(b.date));
    return copyWith(weighIns: list);
  }

  /// Sets the glass count for [date]'s calendar day (clamped at 0).
  PlanTracking withWater(DateTime date, int glasses) {
    final next = Map<String, int>.from(waterByDate);
    next[dateKey(date)] = glasses < 0 ? 0 : glasses;
    return copyWith(waterByDate: next);
  }

  // ─────────────────────────────────────────────────────── metrics ──

  /// Calendar days (as [dateKey]s) on which the user did *something*:
  /// logged weight, drank water, or checked off a meal. [startDate] maps a
  /// plan-day index back to its calendar date.
  Set<String> activeDays(DateTime startDate) {
    final days = <String>{};
    for (final w in weighIns) {
      days.add(dateKey(w.date));
    }
    waterByDate.forEach((k, v) {
      if (v > 0) days.add(k);
    });
    for (final k in mealsDone) {
      final day = int.tryParse(k.split(':').first);
      if (day == null) continue;
      final d = DateTime(startDate.year, startDate.month, startDate.day + day);
      days.add(dateKey(d));
    }
    return days;
  }

  /// Consecutive active days ending today (or yesterday). 0 if neither active.
  int currentStreak(DateTime today, DateTime startDate) {
    final active = activeDays(startDate);
    var cursor = DateTime(today.year, today.month, today.day);
    if (!active.contains(dateKey(cursor))) {
      cursor = cursor.subtract(const Duration(days: 1));
      if (!active.contains(dateKey(cursor))) return 0;
    }
    var streak = 0;
    while (active.contains(dateKey(cursor))) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  /// Meal adherence over the days that have already started.
  ({int done, int total, int elapsedDays}) adherence(
      DietPlan plan, DateTime startDate, DateTime today) {
    final t = DateTime(today.year, today.month, today.day);
    var elapsed = 0;
    var total = 0;
    for (var i = 0; i < plan.days.length; i++) {
      final d = DateTime(startDate.year, startDate.month, startDate.day + i);
      if (d.isAfter(t)) break;
      elapsed++;
      total += plan.days[i].meals.length;
    }
    return (done: doneMealsIn(elapsed), total: total, elapsedDays: elapsed);
  }

  // ──────────────────────────────────────────────────────── json ──

  Map<String, dynamic> toJson() => {
        'weighIns': weighIns.map((e) => e.toJson()).toList(),
        'mealsDone': mealsDone.toList(),
        'waterByDate': waterByDate,
        'waterGoal': waterGoal,
        'waterRemindersOn': waterRemindersOn,
      };

  static PlanTracking fromJson(Map<String, dynamic> m) {
    final weighIns = ((m['weighIns'] as List?) ?? [])
        .map((e) => WeighIn.fromJson((e as Map).cast<String, dynamic>()))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    final water = <String, int>{};
    final rawWater = m['waterByDate'];
    if (rawWater is Map) {
      rawWater.forEach((k, v) => water['$k'] = _toInt(v));
    }
    return PlanTracking(
      weighIns: weighIns,
      mealsDone: ((m['mealsDone'] as List?) ?? []).map((e) => '$e').toSet(),
      waterByDate: water,
      waterGoal: m['waterGoal'] == null ? 8 : _toInt(m['waterGoal']),
      waterRemindersOn: m['waterRemindersOn'] == true,
    );
  }
}
