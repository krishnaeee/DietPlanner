import 'package:flutter/material.dart';

import '../services/notification_service.dart';
import '../services/plan_storage.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/fresh.dart';
import 'settings_screen.dart';

const _kWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _kMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

String _fullDate(DateTime d) =>
    '${_kWeekdays[d.weekday - 1]}, ${d.day} ${_kMonths[d.month - 1]}';

/// Per-plan settings, opened from the plan screen's gear button. Currently owns
/// reminder setup (grocery + meal alarms), the "repeat after plan ends" toggle,
/// and a read-only plan summary. Changes persist to storage; the plan screen
/// re-reads the record when this screen is popped.
class DietSettingsScreen extends StatefulWidget {
  final StoredPlan stored;
  const DietSettingsScreen({super.key, required this.stored});

  @override
  State<DietSettingsScreen> createState() => _DietSettingsScreenState();
}

class _DietSettingsScreenState extends State<DietSettingsScreen> {
  late StoredPlan _sp;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _sp = widget.stored;
    _reload(); // pick up any changes made since the plan screen loaded
  }

  Future<void> _reload() async {
    final all = await PlanStorage.loadAll();
    final fresh = all.firstWhere((e) => e.id == _sp.id, orElse: () => _sp);
    if (mounted) setState(() => _sp = fresh);
  }

  bool get _scheduled => _sp.remindersScheduled;
  bool get _repeat => _sp.repeatForever;
  int get _count => _sp.scheduledCount;
  DateTime get _start => _sp.startDate;

  @override
  Widget build(BuildContext context) {
    final name = _sp.name.trim();
    return Scaffold(
      body: Column(
        children: [
          FreshHeader(
            title: 'Diet settings',
            subtitle: name.isEmpty ? null : name,
            showBack: true,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
              children: [
                _remindersCard(),
                const SizedBox(height: 16),
                _planCard(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────────────────────────────────────── reminders card ──

  void _openAppSettings() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
  }

  Widget _remindersCard() {
    final text = Theme.of(context).textTheme;
    return ValueListenableBuilder<bool>(
      valueListenable: NotificationService.instance.remindersEnabled,
      builder: (context, masterOn, _) => SectionCard(
        title: 'Reminders',
        icon: Icons.notifications_active_rounded,
        child: !masterOn
            ? _masterOffNotice(text)
            : _busy
                ? const SizedBox(
                    height: 52,
                    child: Center(child: CircularProgressIndicator()))
                : _scheduled
                    ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Reminders on',
                                  style: text.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w800)),
                              Text('$_count set · Day 1 ${_fullDate(_start)}',
                                  style: text.bodySmall
                                      ?.copyWith(color: AppColors.inkMuted)),
                            ],
                          ),
                        ),
                        TextButton(
                            onPressed: _turnOff, child: const Text('Turn off')),
                      ],
                    ),
                    const Divider(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: _repeat,
                      onChanged: _toggleRepeat,
                      activeThumbColor: AppColors.brand,
                      title: Text('Repeat after plan ends',
                          style: text.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      subtitle: Text(
                        'Keep daily reminders going by cycling the menu',
                        style:
                            text.bodySmall?.copyWith(color: AppColors.inkMuted),
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton.icon(
                      onPressed: _setupReminders,
                      icon: const Icon(Icons.notifications_active_rounded),
                      label: const Text('Set daily reminders'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Grocery alert at 7 PM the day before + meal-time alarms',
                      textAlign: TextAlign.center,
                      style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                    ),
                  ],
                ),
      ),
    );
  }

  Widget _masterOffNotice(TextTheme text) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.notifications_off_rounded,
                color: AppColors.inkMuted, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Meal & grocery reminders are turned off for all plans.',
                style: text.bodyMedium?.copyWith(color: AppColors.ink),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _openAppSettings,
            icon: const Icon(Icons.settings_rounded, size: 18),
            label: const Text('Open Settings'),
          ),
        ),
      ],
    );
  }

  // ────────────────────────────────────────────────────── plan summary card ──

  Widget _planCard() {
    final plan = _sp.plan;
    return SectionCard(
      title: 'Plan',
      icon: Icons.restaurant_menu_rounded,
      child: Column(
        children: [
          if (_sp.location.trim().isNotEmpty)
            _row(Icons.place_rounded, 'Location', _sp.location.trim()),
          _row(Icons.event_rounded, 'Day 1', _fullDate(_start)),
          _row(Icons.calendar_month_rounded, 'Journey',
              '${plan.days.length} of ${plan.requestedDays} days ready'),
        ],
      ),
    );
  }

  Widget _row(IconData icon, String label, String value) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.inkMuted),
          const SizedBox(width: 10),
          Text(label, style: text.bodyMedium?.copyWith(color: AppColors.inkMuted)),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: text.bodyMedium?.copyWith(
                  color: AppColors.ink, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────── actions ──

  Future<void> _setupReminders() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!NotificationService.instance.remindersEnabled.value) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Turn on meal & grocery reminders in Settings first.'),
      ));
      return;
    }
    final start = await _pickStart();
    if (start == null) return;

    setState(() => _busy = true);
    final allowed = await NotificationService.instance.requestPermissions();
    if (!allowed) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(const SnackBar(
        content: Text('Allow notifications for this app to receive reminders.'),
      ));
      return;
    }

    // Mark this plan active with the chosen start, then rebuild all reminders
    // (so other people's plans keep their reminders too).
    await PlanStorage.upsert(_sp.copyWith(remindersScheduled: true, startDate: start));
    var refreshed = await _rescheduleAndRefresh();
    if (refreshed.scheduledCount == 0) {
      // Nothing was in the future — flip it back off.
      refreshed = refreshed.copyWith(remindersScheduled: false);
      await PlanStorage.upsert(refreshed);
    }
    if (!mounted) return;
    setState(() {
      _sp = refreshed;
      _busy = false;
    });
    messenger.showSnackBar(SnackBar(
      content: Text(refreshed.scheduledCount > 0
          ? 'Reminders set — ${refreshed.scheduledCount} notifications. Day 1: ${_fullDate(start)}.'
          : 'No upcoming times left to schedule — try starting tomorrow.'),
    ));
  }

  Future<void> _turnOff() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    await PlanStorage.upsert(_sp.copyWith(remindersScheduled: false));
    final refreshed = await _rescheduleAndRefresh();
    if (!mounted) return;
    setState(() {
      _sp = refreshed;
      _busy = false;
    });
    messenger.showSnackBar(const SnackBar(content: Text('Reminders turned off.')));
  }

  /// Toggles whether reminders keep cycling the menu after the plan's last day,
  /// then reschedules so the change takes effect immediately.
  Future<void> _toggleRepeat(bool on) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    await PlanStorage.upsert(_sp.copyWith(repeatForever: on));
    final refreshed = await _rescheduleAndRefresh();
    if (!mounted) return;
    setState(() {
      _sp = refreshed;
      _busy = false;
    });
    messenger.showSnackBar(SnackBar(
      content: Text(on
          ? 'Reminders will keep repeating after the plan ends.'
          : 'Reminders will stop after the last plan day.'),
    ));
  }

  /// Reschedules notifications for every active plan and re-reads this plan's
  /// updated record (with its fresh scheduled count).
  Future<StoredPlan> _rescheduleAndRefresh() async {
    final all = await PlanStorage.loadAll();
    final counts = await NotificationService.instance.rescheduleAll(all);
    for (final p in all) {
      final c = counts[p.id] ?? 0;
      if (p.scheduledCount != c) {
        await PlanStorage.upsert(p.copyWith(scheduledCount: c));
      }
    }
    final fresh = await PlanStorage.loadAll();
    return fresh.firstWhere((e) => e.id == _sp.id, orElse: () => _sp);
  }

  Future<DateTime?> _pickStart() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    return showModalBottomSheet<DateTime>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('When does Day 1 start?',
                    style: Theme.of(ctx)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.event_rounded, color: AppColors.brand),
              title: const Text('Tomorrow'),
              subtitle: const Text('Grocery alert tonight at 7 PM, meals from tomorrow'),
              onTap: () => Navigator.pop(ctx, tomorrow),
            ),
            ListTile(
              leading: const Icon(Icons.today_rounded, color: AppColors.brand),
              title: const Text('Today'),
              subtitle: const Text("Meals from today (times already passed are skipped)"),
              onTap: () => Navigator.pop(ctx, today),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
