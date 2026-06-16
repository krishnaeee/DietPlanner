import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/diet_plan.dart';
import 'plan_storage.dart';

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

    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDesc,
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
      if (!sp.remindersScheduled) continue;
      counts[sp.id] = await _scheduleOne(sp, now);
    }
    return counts;
  }

  Future<int> _scheduleOne(StoredPlan sp, tz.TZDateTime now) async {
    final plan = sp.plan;
    final startDate = sp.startDate;
    final base = sp.slot * 100000; // per-plan notification ID namespace
    final tag = sp.name.trim().isEmpty ? '' : ' · ${sp.name.trim()}';
    var count = 0;

    for (var i = 0; i < plan.days.length; i++) {
      final d = plan.days[i];
      // Date-component arithmetic (DST-safe) for Day i's calendar date.
      final dayDate = DateTime(startDate.year, startDate.month, startDate.day + i);

      // Grocery reminder at 7 PM the evening before.
      final g = DateTime(dayDate.year, dayDate.month, dayDate.day - 1);
      final groceryAt = tz.TZDateTime(tz.local, g.year, g.month, g.day, 19, 0);
      if (groceryAt.isAfter(now)) {
        final items = _ingredientsFor(d);
        if (items.isNotEmpty) {
          await _scheduleAt(
            id: base + 90000 + i,
            title: '🛒 Groceries for Day ${d.day}$tag (tomorrow)',
            body: items,
            when: groceryAt,
            bigText: items,
            payload: jsonEncode({'planId': sp.id, 'day': i, 'meal': -1, 'type': 'grocery'}),
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
            id: base + i * 10 + m,
            title: meal.dish.isEmpty ? '$name time$tag' : '$name$tag — ${meal.dish}',
            body: meal.description.isEmpty
                ? 'Time for your ${name.toLowerCase()}.'
                : meal.description,
            when: mealAt,
            payload: jsonEncode({'planId': sp.id, 'day': i, 'meal': m, 'type': 'meal'}),
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
    String? bigText,
    String? payload,
  }) async {
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
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
