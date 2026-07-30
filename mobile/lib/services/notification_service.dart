import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb, ValueNotifier;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/diet_plan.dart';
import '../models/tracking.dart';
import 'plan_storage.dart';
import 'tracking_storage.dart';

/// Schedules local notifications for a diet plan:
///  - a grocery reminder at 7 PM the evening before each day, and
///  - a meal alarm at each meal's time.
/// All times are device-local. Notifications fire even when the app is closed.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// App-level master switch for meal/grocery reminders across ALL plans. When
  /// off, no plan schedules meal/grocery alarms regardless of its own setting.
  /// (Water/hydration reminders are independent of this.) Persisted; the
  /// settings screen listens to it.
  final ValueNotifier<bool> remindersEnabled = ValueNotifier<bool>(true);
  static const _enabledKey = 'reminders_enabled_v1';

  /// Set before runApp. Invoked when a notification is tapped while the app is
  /// running (foreground, or background but still alive). Cold-start taps are
  /// delivered separately via [initialLaunchPayload].
  void Function(String payload)? onTap;

  static const _channelId = 'diet_reminders';
  static const _channelName = 'Diet reminders';
  static const _channelDesc = 'Grocery and meal reminders for your diet plan';

  static const _waterChannelId = 'water_reminders';
  static const _waterChannelName = 'Water reminders';
  static const _waterChannelDesc = 'Daily hydration reminders';

  // Times of day (24h) at which hydration nudges fire when water reminders
  // are on. Kept short so a missed glass is reinforced through the day.
  static const _waterHours = [10, 13, 16, 19];

  // How many days ahead a [StoredPlan.repeatForever] plan schedules in one pass.
  // The window slides forward each time [refreshAll] runs (app launch), so the
  // reminders effectively never stop. Kept modest to respect the OS cap on the
  // number of pending notifications.
  static const _repeatHorizonDays = 14;

  Future<void> init() async {
    if (_ready || kIsWeb) {
      _ready = true;
      return;
    }
    // Restore the master reminders switch (default on).
    try {
      final prefs = await SharedPreferences.getInstance();
      remindersEnabled.value = prefs.getBool(_enabledKey) ?? true;
    } catch (_) {
      // Prefs unavailable — leave the default (on).
    }
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // Detection failed — leave tz.local as UTC; times may be off by the offset.
    }

    // The DEFAULT small icon is the always-present launcher (so init can never
    // throw on a missing resource); our own reminders override it with the
    // monochrome @drawable/ic_stat_notify in _scheduleAt.
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    // A notification-setup failure must NEVER blank the app at startup — guard
    // the whole platform init and degrade gracefully (no reminders).
    try {
      await _plugin.initialize(
        settings:
            const InitializationSettings(android: android, iOS: darwin, macOS: darwin),
        onDidReceiveNotificationResponse: _onResponse,
      );

      final androidPlugin = _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.createNotificationChannel(const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDesc,
        importance: Importance.high,
      ));
      await androidPlugin?.createNotificationChannel(const AndroidNotificationChannel(
        _waterChannelId,
        _waterChannelName,
        description: _waterChannelDesc,
        importance: Importance.high,
      ));
    } catch (e) {
      debugPrint('NotificationService.init failed (reminders disabled): $e');
    }
    _ready = true;
  }

  /// Requests notification + exact-alarm permissions.
  /// Returns true if notifications are allowed (reminders can be shown).
  Future<bool> requestPermissions() async {
    await init();
    if (kIsWeb) return false;

    final android = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final granted = await android.requestNotificationsPermission() ?? false;
      // Best-effort; if denied we fall back to inexact alarms when scheduling.
      await android.requestExactAlarmsPermission();
      return granted;
    }

    final ios = _plugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      return await ios.requestPermissions(alert: true, badge: true, sound: true) ?? false;
    }
    return true;
  }

  /// Routes notification taps that arrive while the app is alive.
  void _onResponse(NotificationResponse response) {
    final p = response.payload;
    if (p != null && p.isNotEmpty) onTap?.call(p);
  }

  /// If a notification tap cold-started the app, returns its payload; else null.
  Future<String?> initialLaunchPayload() async {
    if (kIsWeb) return null;
    await init();
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp == true) {
      return details!.notificationResponse?.payload;
    }
    return null;
  }

  /// Cancels ALL reminders, then re-schedules grocery + meal notifications for
  /// every plan that has reminders enabled. Each plan's notification IDs are
  /// namespaced by its [StoredPlan.slot], so several people's reminders coexist.
  /// Returns a map of plan id → number of notifications scheduled.
  Future<Map<String, int>> rescheduleAll(List<StoredPlan> plans) async {
    await init();
    if (kIsWeb) return <String, int>{}; // scheduled notifications unsupported on web
    await cancelAll();
    final now = tz.TZDateTime.now(tz.local);
    final counts = <String, int>{};
    for (final sp in plans) {
      var count = 0;
      // Meal/grocery reminders require BOTH the plan's own flag and the global
      // master switch to be on.
      final tracking = await TrackingStorage.load(sp.id);
      if (sp.remindersScheduled && remindersEnabled.value) {
        count += await _scheduleOne(sp, now);
        // Re-engagement nudges ride the same opt-in as meal/grocery reminders.
        count += await _scheduleEngagement(sp, tracking, now);
      }
      // Hydration reminders are independent of the meal/grocery master switch.
      if (tracking.waterRemindersOn) count += await _scheduleWater(sp, now);
      if (count > 0) counts[sp.id] = count;
    }
    return counts;
  }

  /// Flips the app-level master switch for meal/grocery reminders and reschedules
  /// every plan under the new setting (turning it off cancels them all; turning
  /// it on re-arms each plan that has its own reminders enabled).
  Future<void> setRemindersEnabled(bool on) async {
    if (remindersEnabled.value == on) return;
    remindersEnabled.value = on;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, on);
    } catch (_) {
      // Best-effort persistence.
    }
    await refreshAll();
  }

  /// Reschedules reminders for every saved plan and writes back each plan's
  /// fresh scheduled count. Call on app launch so repeating plans slide their
  /// rolling window forward (and recover reminders lost to a reboot).
  Future<void> refreshAll() async {
    if (kIsWeb) return;
    final all = await PlanStorage.loadAll();
    final counts = await rescheduleAll(all);
    for (final p in all) {
      final c = counts[p.id] ?? 0;
      if (p.scheduledCount != c) {
        await PlanStorage.upsert(p.copyWith(scheduledCount: c));
      }
    }
  }

  /// Schedules the day's remaining (then daily-repeating) hydration nudges.
  Future<int> _scheduleWater(StoredPlan sp, tz.TZDateTime now) async {
    final base = sp.slot * 100000;
    final tag = sp.name.trim().isEmpty ? '' : ' · ${sp.name.trim()}';
    var count = 0;
    for (var k = 0; k < _waterHours.length; k++) {
      var when = tz.TZDateTime(tz.local, now.year, now.month, now.day, _waterHours[k], 0);
      if (!when.isAfter(now)) when = when.add(const Duration(days: 1));
      await _scheduleAt(
        id: base + 80000 + k, // water ID band, below the 90000 grocery band
        title: '💧 Time to hydrate$tag',
        body: 'Drink a glass of water and tick it off in your plan.',
        when: when,
        channelId: _waterChannelId,
        match: DateTimeComponents.time, // repeat daily at this time
        payload: jsonEncode({'planId': sp.id, 'day': -1, 'meal': -1, 'type': 'water'}),
      );
      count++;
    }
    return count;
  }

  /// Retention nudges (ID band 70000, below water's 80000): a weekly weigh-in
  /// reminder and a "comeback" nudge that only fires if the user goes quiet —
  /// it re-anchors to their latest activity on every reschedule, so it slides
  /// forward as long as they keep logging.
  Future<int> _scheduleEngagement(
      StoredPlan sp, PlanTracking tracking, tz.TZDateTime now) async {
    final base = sp.slot * 100000;
    final tag = sp.name.trim().isEmpty ? '' : ' · ${sp.name.trim()}';
    final start = sp.startDate;
    var count = 0;

    // Weekly weigh-in — one reminder that repeats weekly on the start weekday.
    var weigh =
        tz.TZDateTime(tz.local, start.year, start.month, start.day, 9, 0);
    while (!weigh.isAfter(now)) {
      weigh = weigh.add(const Duration(days: 7));
    }
    await _scheduleAt(
      id: base + 70000,
      title: '⚖️ Weekly weigh-in$tag',
      body: 'Log your weight to keep your trend — and your plan — on track.',
      when: weigh,
      match: DateTimeComponents.dayOfWeekAndTime, // weekly
      payload: jsonEncode({'planId': sp.id, 'day': -1, 'meal': -1, 'type': 'weighin'}),
    );
    count++;

    // Comeback — 2 days after the most recent active day, at 6 PM.
    final active = tracking.activeDays(start);
    final lastActive = active.isEmpty
        ? DateTime(start.year, start.month, start.day)
        : active.map(DateTime.parse).reduce((a, b) => a.isAfter(b) ? a : b);
    final comeback = tz.TZDateTime(
            tz.local, lastActive.year, lastActive.month, lastActive.day, 18, 0)
        .add(const Duration(days: 2));
    if (comeback.isAfter(now)) {
      await _scheduleAt(
        id: base + 70010,
        title: '👋 We miss you$tag',
        body: 'Your plan is waiting — log a meal or a weigh-in to keep your streak alive.',
        when: comeback,
        payload:
            jsonEncode({'planId': sp.id, 'day': -1, 'meal': -1, 'type': 'comeback'}),
      );
      count++;
    }
    return count;
  }

  Future<int> _scheduleOne(StoredPlan sp, tz.TZDateTime now) async {
    final plan = sp.plan;
    if (plan.days.isEmpty) return 0;
    final startDate = sp.startDate;
    final base = sp.slot * 100000; // per-plan notification ID namespace
    final tag = sp.name.trim().isEmpty ? '' : ' · ${sp.name.trim()}';
    var count = 0;

    // The calendar dates to fill, each mapped to a plan-day index. Normally one
    // pass over the plan's days from the start date; when [repeatForever] is on,
    // a rolling window from today that cycles the menu so it never runs out.
    // `offset` namespaces notification IDs within this reschedule pass.
    final slots = <({int offset, DateTime date, int dayIndex})>[];
    if (sp.repeatForever) {
      final today = DateTime(now.year, now.month, now.day);
      final startDay = DateTime(startDate.year, startDate.month, startDate.day);
      final from = startDay.isAfter(today) ? startDay : today;
      final fromSince = from.difference(startDay).inDays; // ≥ 0
      for (var o = 0; o < _repeatHorizonDays; o++) {
        final date = DateTime(from.year, from.month, from.day + o);
        slots.add((
          offset: o,
          date: date,
          dayIndex: (fromSince + o) % plan.days.length,
        ));
      }
    } else {
      for (var i = 0; i < plan.days.length; i++) {
        // Date-component arithmetic (DST-safe) for Day i's calendar date.
        final date = DateTime(startDate.year, startDate.month, startDate.day + i);
        slots.add((offset: i, date: date, dayIndex: i));
      }
    }

    for (final s in slots) {
      final d = plan.days[s.dayIndex];
      final dayDate = s.date;

      // Grocery reminder at 7 PM the evening before.
      final g = DateTime(dayDate.year, dayDate.month, dayDate.day - 1);
      final groceryAt = tz.TZDateTime(tz.local, g.year, g.month, g.day, 19, 0);
      if (groceryAt.isAfter(now)) {
        final items = _ingredientsFor(d);
        if (items.isNotEmpty) {
          await _scheduleAt(
            id: base + 90000 + s.offset,
            title: '🛒 Groceries for Day ${d.day}$tag (tomorrow)',
            body: items,
            when: groceryAt,
            bigText: items,
            payload: jsonEncode(
                {'planId': sp.id, 'day': s.dayIndex, 'meal': -1, 'type': 'grocery'}),
          );
          count++;
        }
      }

      // Meal alarms at each meal time.
      for (var m = 0; m < d.meals.length; m++) {
        final meal = d.meals[m];
        final hm = _parseTime(meal.time);
        if (hm == null) continue;
        final mealAt = tz.TZDateTime(
            tz.local, dayDate.year, dayDate.month, dayDate.day, hm.$1, hm.$2);
        if (mealAt.isAfter(now)) {
          final name = meal.name.isEmpty ? 'Meal' : meal.name;
          await _scheduleAt(
            id: base + s.offset * 10 + m,
            title: meal.dish.isEmpty ? '$name time$tag' : '$name$tag — ${meal.dish}',
            body: meal.description.isEmpty
                ? 'Time for your ${name.toLowerCase()}.'
                : meal.description,
            when: mealAt,
            payload: jsonEncode(
                {'planId': sp.id, 'day': s.dayIndex, 'meal': m, 'type': 'meal'}),
          );
          count++;
        }
      }
    }
    return count;
  }

  Future<void> cancelAll() async {
    await init();
    if (kIsWeb) return; // no local-notification plugin on web
    await _plugin.cancelAll();
  }

  // ───────────────────────────────────────────────────────────── internals ──

  Future<void> _scheduleAt({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime when,
    String channelId = _channelId,
    String? bigText,
    String? payload,
    DateTimeComponents? match,
  }) async {
    final water = channelId == _waterChannelId;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        water ? _waterChannelName : _channelName,
        channelDescription: water ? _waterChannelDesc : _channelDesc,
        importance: Importance.high,
        priority: Priority.high,
        // White monochrome silhouette in the status bar; the full-colour logo
        // shows as the large icon; coral accent tint in the expanded view.
        icon: '@drawable/ic_stat_notify',
        color: const Color(0xFFFF5D6D),
        largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
        styleInformation: bigText != null ? BigTextStyleInformation(bigText) : null,
      ),
      iOS: const DarwinNotificationDetails(),
      macOS: const DarwinNotificationDetails(),
    );

    try {
      await _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: when,
        notificationDetails: details,
        payload: payload,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        matchDateTimeComponents: match,
      );
    } catch (_) {
      // Exact-alarm permission not granted → still schedule, just inexact. Guard
      // this retry too so a scheduling failure (e.g. a bad icon) can never
      // propagate out of a reschedule and crash startup.
      try {
        await _plugin.zonedSchedule(
          id: id,
          title: title,
          body: body,
          scheduledDate: when,
          notificationDetails: details,
          payload: payload,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          matchDateTimeComponents: match,
        );
      } catch (e) {
        debugPrint('NotificationService: could not schedule id=$id: $e');
      }
    }
  }

  // "HH:mm" / "H:mm" → (hour, minute); null if unparseable.
  (int, int)? _parseTime(String t) {
    final match = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(t.trim());
    if (match == null) return null;
    final h = int.tryParse(match.group(1)!);
    final m = int.tryParse(match.group(2)!);
    if (h == null || m == null || h > 23 || m > 59) return null;
    return (h, m);
  }

  // Deduped, human-readable shopping list for a day.
  String _ingredientsFor(DayPlan day) {
    final seen = <String>{};
    final items = <String>[];
    for (final meal in day.meals) {
      for (final ing in meal.ingredients) {
        final key = ing.name.toLowerCase().trim();
        if (key.isEmpty || seen.contains(key)) continue;
        seen.add(key);
        items.add(ing.quantity.isEmpty ? ing.name : '${ing.name} (${ing.quantity})');
      }
    }
    return items.join(', ');
  }
}
