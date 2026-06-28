import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/diet_plan.dart';
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
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // Detection failed — leave tz.local as UTC; times may be off by the offset.
    }

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(android: android, iOS: darwin, macOS: darwin),
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
      if (sp.remindersScheduled) count += await _scheduleOne(sp, now);
      // Hydration reminders are independent of meal/grocery reminders.
      final tracking = await TrackingStorage.load(sp.id);
      if (tracking.waterRemindersOn) count += await _scheduleWater(sp, now);
      if (count > 0) counts[sp.id] = count;
    }
    return counts;
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
      // Exact-alarm permission not granted → still schedule, just inexact.
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
