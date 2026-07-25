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

/// Something the user ate that the plan didn't include — a snack, a tea, a
/// coffee. Without this the app can only see adherence to the planned menu, so
/// a day of perfect check-offs plus four teas still looked "on target".
///
/// Calories are the user's own figure (a quick-pick preset or typed in), so
/// logging one costs nothing and works offline.
class ExtraItem {
  final String id; // stable, so it can be removed and synced
  final int dayIndex; // 0-based plan day it was eaten on
  final String name;
  final int calories;
  final int protein;
  final int carbs;
  final int fat;

  ExtraItem({
    required this.id,
    required this.dayIndex,
    required this.name,
    required this.calories,
    this.protein = 0,
    this.carbs = 0,
    this.fat = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'dayIndex': dayIndex,
        'name': name,
        'calories': calories,
        'protein': protein,
        'carbs': carbs,
        'fat': fat,
      };

  static ExtraItem fromJson(Map<String, dynamic> j) => ExtraItem(
        id: (j['id'] ?? '').toString(),
        dayIndex: _toInt(j['dayIndex']),
        name: (j['name'] ?? '').toString(),
        calories: _toInt(j['calories']),
        protein: _toInt(j['protein']),
        carbs: _toInt(j['carbs']),
        fat: _toInt(j['fat']),
      );
}

/// All tracking state for one plan.
class PlanTracking {
  /// Weigh-ins, kept sorted oldest → newest.
  final List<WeighIn> weighIns;

  /// Completed meals, keyed `"<dayIndex>:<mealIndex>"` (both 0-based).
  final Set<String> mealsDone;

  /// Meals the user explicitly marked as NOT eaten, keyed like [mealsDone].
  /// Mutually exclusive with [mealsDone]: a "resolved" meal is in one set or the
  /// other. Skipping counts as engagement (keeps a streak) but not as adherence.
  final Set<String> mealsSkipped;

  /// Glasses of water drunk, keyed by [dateKey].
  final Map<String, int> waterByDate;

  /// Daily water goal in glasses.
  final int waterGoal;

  /// Whether daily hydration reminders are scheduled for this plan.
  final bool waterRemindersOn;

  /// Off-plan items eaten, across all days (see [ExtraItem]).
  final List<ExtraItem> extras;

  PlanTracking({
    this.weighIns = const [],
    this.mealsDone = const {},
    this.mealsSkipped = const {},
    this.waterByDate = const {},
    this.waterGoal = 8,
    this.waterRemindersOn = false,
    this.extras = const [],
  });

  PlanTracking copyWith({
    List<WeighIn>? weighIns,
    Set<String>? mealsDone,
    Set<String>? mealsSkipped,
    Map<String, int>? waterByDate,
    int? waterGoal,
    bool? waterRemindersOn,
    List<ExtraItem>? extras,
  }) =>
      PlanTracking(
        weighIns: weighIns ?? this.weighIns,
        mealsDone: mealsDone ?? this.mealsDone,
        mealsSkipped: mealsSkipped ?? this.mealsSkipped,
        waterByDate: waterByDate ?? this.waterByDate,
        waterGoal: waterGoal ?? this.waterGoal,
        waterRemindersOn: waterRemindersOn ?? this.waterRemindersOn,
        extras: extras ?? this.extras,
      );

  // ───────────────────────────────────────────────────────── reads ──

  bool isMealDone(int day, int meal) => mealsDone.contains('$day:$meal');

  bool isMealSkipped(int day, int meal) => mealsSkipped.contains('$day:$meal');

  /// A meal is "resolved" once it's been either eaten or skipped — used so
  /// "Up next" moves on and the day can still reach "All done".
  bool isMealResolved(int day, int meal) =>
      isMealDone(day, meal) || isMealSkipped(day, meal);

  int waterFor(DateTime d) => waterByDate[dateKey(d)] ?? 0;

  /// Off-plan items logged on a plan day, in the order they were added.
  List<ExtraItem> extrasFor(int dayIndex) =>
      extras.where((e) => e.dayIndex == dayIndex).toList();

  /// Calories from off-plan items on a plan day — added on top of the planned
  /// meals so a day's total reflects what was actually eaten.
  int extraCaloriesFor(int dayIndex) =>
      extrasFor(dayIndex).fold(0, (s, e) => s + e.calories);

  /// Distinct off-plan items logged recently, most-recent first (deduped by
  /// name, case-insensitively) — so a habitual coffee is one tap to re-log.
  List<ExtraItem> recentExtras({int limit = 6}) {
    final seen = <String>{};
    final out = <ExtraItem>[];
    for (final e in extras.reversed) {
      final k = e.name.trim().toLowerCase();
      if (k.isEmpty || seen.contains(k)) continue;
      seen.add(k);
      out.add(e);
      if (out.length >= limit) break;
    }
    return out;
  }

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

  /// Toggles a meal's completion. Marking it eaten clears any "skipped" flag —
  /// the two states are mutually exclusive.
  PlanTracking toggleMeal(int day, int meal) {
    final key = '$day:$meal';
    final done = Set<String>.from(mealsDone);
    final skipped = Set<String>.from(mealsSkipped);
    if (done.remove(key)) {
      return copyWith(mealsDone: done);
    }
    done.add(key);
    skipped.remove(key);
    return copyWith(mealsDone: done, mealsSkipped: skipped);
  }

  /// Toggles a meal's "didn't eat" flag. Marking it skipped clears "eaten".
  PlanTracking toggleSkip(int day, int meal) {
    final key = '$day:$meal';
    final done = Set<String>.from(mealsDone);
    final skipped = Set<String>.from(mealsSkipped);
    if (skipped.remove(key)) {
      return copyWith(mealsSkipped: skipped);
    }
    skipped.add(key);
    done.remove(key);
    return copyWith(mealsDone: done, mealsSkipped: skipped);
  }

  /// Records (or replaces) the weigh-in for [date]'s calendar day.
  PlanTracking withWeighIn(DateTime date, double kg) {
    final k = dateKey(date);
    final list = weighIns.where((w) => dateKey(w.date) != k).toList()
      ..add(WeighIn(date: DateTime(date.year, date.month, date.day), kg: kg));
    list.sort((a, b) => a.date.compareTo(b.date));
    return copyWith(weighIns: list);
  }

  /// Adds an off-plan item.
  PlanTracking withExtra(ExtraItem e) => copyWith(extras: [...extras, e]);

  /// Removes an off-plan item by id.
  PlanTracking withoutExtra(String id) =>
      copyWith(extras: extras.where((e) => e.id != id).toList());

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
    for (final k in mealsDone.followedBy(mealsSkipped)) {
      final day = int.tryParse(k.split(':').first);
      if (day == null) continue;
      final d = DateTime(startDate.year, startDate.month, startDate.day + day);
      days.add(dateKey(d));
    }
    // Logging an off-plan item is engagement too — it keeps a streak alive.
    for (final e in extras) {
      final d =
          DateTime(startDate.year, startDate.month, startDate.day + e.dayIndex);
      days.add(dateKey(d));
    }
    return days;
  }

  /// The longest run of consecutive active days ever recorded for this plan.
  int bestStreak(DateTime startDate) {
    final active = activeDays(startDate);
    if (active.isEmpty) return 0;
    final dates = active.map(DateTime.parse).toList()..sort();
    var best = 1, run = 1;
    for (var i = 1; i < dates.length; i++) {
      if (dates[i].difference(dates[i - 1]).inDays == 1) {
        run++;
        if (run > best) best = run;
      } else {
        run = 1;
      }
    }
    return best;
  }

  /// A few plain-language insights from the user's own tracking — no LLM.
  /// Empty until there's enough data to say something honest.
  List<String> insights(DietPlan plan, DateTime startDate, DateTime today) {
    final t = DateTime(today.year, today.month, today.day);
    final out = <String>[];
    final skips = <String, int>{};
    final totals = <String, int>{};
    var wdDone = 0, wdTot = 0, weDone = 0, weTot = 0;

    for (var i = 0; i < plan.days.length; i++) {
      final d = DateTime(startDate.year, startDate.month, startDate.day + i);
      if (d.isAfter(t)) break;
      final weekend =
          d.weekday == DateTime.saturday || d.weekday == DateTime.sunday;
      for (var m = 0; m < plan.days[i].meals.length; m++) {
        final slot = plan.days[i].meals[m].name.trim();
        if (slot.isNotEmpty) {
          totals[slot] = (totals[slot] ?? 0) + 1;
          if (isMealSkipped(i, m)) skips[slot] = (skips[slot] ?? 0) + 1;
        }
        final done = isMealDone(i, m);
        if (weekend) {
          weTot++;
          if (done) weDone++;
        } else {
          wdTot++;
          if (done) wdDone++;
        }
      }
    }

    // 1. Most-skipped meal slot.
    String? topSlot;
    var topSkips = 0, topTot = 0;
    skips.forEach((slot, n) {
      if (n > topSkips) {
        topSkips = n;
        topSlot = slot;
        topTot = totals[slot] ?? 0;
      }
    });
    if (topSlot != null && topSkips >= 2) {
      out.add(
          '$topSlot is your most-skipped meal — $topSkips of $topTot days. It gets lighter and more appealing when you extend the plan.');
    }

    // 2. Weekday vs weekend adherence gap.
    if (wdTot >= 4 && weTot >= 2) {
      final wd = (100 * wdDone / wdTot).round();
      final we = (100 * weDone / weTot).round();
      if ((wd - we).abs() >= 15) {
        out.add(we < wd
            ? 'Weekends are tougher — $we% adherence vs $wd% on weekdays. A little weekend prep goes a long way.'
            : 'You do better on weekends — $we% vs $wd% on weekdays.');
      }
    }

    // 3. Best streak, if it beats the current one.
    final best = bestStreak(startDate);
    final cur = currentStreak(today, startDate);
    if (best >= 3 && best > cur) {
      out.add('Your best streak so far: $best days. Think you can beat it? 🔥');
    }

    return out;
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

  /// Meal-slot names the user skips often (≥40% of started days, with at least
  /// 3 data points) — a soft adaptation signal for the next week's generation.
  List<String> frequentlySkippedSlots(
      DietPlan plan, DateTime startDate, DateTime today) {
    final t = DateTime(today.year, today.month, today.day);
    final skips = <String, int>{};
    final totals = <String, int>{};
    for (var i = 0; i < plan.days.length; i++) {
      final d = DateTime(startDate.year, startDate.month, startDate.day + i);
      if (d.isAfter(t)) break;
      for (var m = 0; m < plan.days[i].meals.length; m++) {
        final slot = plan.days[i].meals[m].name.trim();
        if (slot.isEmpty) continue;
        totals[slot] = (totals[slot] ?? 0) + 1;
        if (isMealSkipped(i, m)) skips[slot] = (skips[slot] ?? 0) + 1;
      }
    }
    final out = <String>[];
    totals.forEach((slot, total) {
      final skipped = skips[slot] ?? 0;
      if (total >= 3 && skipped / total >= 0.4) out.add(slot);
    });
    return out;
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
        'mealsSkipped': mealsSkipped.toList(),
        'waterByDate': waterByDate,
        'waterGoal': waterGoal,
        'waterRemindersOn': waterRemindersOn,
        'extras': extras.map((e) => e.toJson()).toList(),
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
      mealsSkipped: ((m['mealsSkipped'] as List?) ?? []).map((e) => '$e').toSet(),
      waterByDate: water,
      waterGoal: m['waterGoal'] == null ? 8 : _toInt(m['waterGoal']),
      waterRemindersOn: m['waterRemindersOn'] == true,
      extras: ((m['extras'] as List?) ?? [])
          .map((e) => ExtraItem.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
    );
  }
}
