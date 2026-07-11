import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/tracking.dart';
import '../services/notification_service.dart';
import '../services/plan_storage.dart';
import '../services/tracking_storage.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/fresh.dart';

/// Tracking & engagement dashboard for one plan: weight progress, daily streak,
/// meal adherence, and water intake (with optional hydration reminders).
class ProgressScreen extends StatefulWidget {
  final StoredPlan stored;

  /// When shown as a bottom-nav tab (not pushed), hide the back button.
  final bool embedded;
  const ProgressScreen({super.key, required this.stored, this.embedded = false});

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  PlanTracking _t = PlanTracking();
  bool _loading = true;
  bool _busy = false;

  StoredPlan get _sp => widget.stored;

  @override
  void initState() {
    super.initState();
    _loadTracking();
    // Reload if the tracking is changed elsewhere (e.g. meal check-off on the
    // Today tab) so this tab never shows — or writes back — a stale copy.
    TrackingStorage.revision.addListener(_loadTracking);
  }

  @override
  void dispose() {
    TrackingStorage.revision.removeListener(_loadTracking);
    super.dispose();
  }

  Future<void> _loadTracking() async {
    final t = await TrackingStorage.load(_sp.id);
    if (!mounted) return;
    setState(() {
      _t = t;
      _loading = false;
    });
  }

  Future<void> _persist(PlanTracking next) async {
    setState(() => _t = next);
    await TrackingStorage.save(_sp.id, next);
  }

  // ─────────────────────────────────────────────────────────── weight ──

  Future<void> _logWeight() async {
    final value = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) =>
          _LogWeightSheet(initialKg: _t.latestWeight ?? _sp.startWeightKg),
    );
    if (value == null) return;
    await _persist(_t.withWeighIn(DateTime.now(), value));
  }

  // ──────────────────────────────────────────────────────────── water ──

  Future<void> _setWater(int glasses) =>
      _persist(_t.withWater(DateTime.now(), glasses));

  Future<void> _toggleWaterReminders(bool on) async {
    final messenger = ScaffoldMessenger.of(context);
    if (on) {
      final allowed = await NotificationService.instance.requestPermissions();
      if (!allowed) {
        messenger.showSnackBar(const SnackBar(
          content: Text('Allow notifications to get water reminders.'),
        ));
        return;
      }
    }
    setState(() => _busy = true);
    final next = _t.copyWith(waterRemindersOn: on);
    await _persist(next);
    await _rescheduleAll();
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(
      content: Text(on
          ? 'Water reminders on — nudges at 10am, 1pm, 4pm & 7pm.'
          : 'Water reminders off.'),
    ));
  }

  /// Reschedules notifications for every plan (single source of truth), then
  /// writes back each plan's fresh scheduled count.
  Future<void> _rescheduleAll() async {
    final all = await PlanStorage.loadAll();
    final counts = await NotificationService.instance.rescheduleAll(all);
    for (final p in all) {
      final c = counts[p.id] ?? 0;
      if (p.scheduledCount != c) {
        await PlanStorage.upsert(p.copyWith(scheduledCount: c));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = _sp.name.trim();
    return Scaffold(
      body: Column(
        children: [
          FreshHeader(
            title: 'Your progress',
            subtitle: name.isEmpty ? null : name,
            showBack: !widget.embedded,
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                    children: [
                      _WeightCard(
                        stored: _sp,
                        tracking: _t,
                        onLog: _logWeight,
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(child: _StreakCard(stored: _sp, tracking: _t)),
                          const SizedBox(width: 14),
                          Expanded(child: _AdherenceCard(stored: _sp, tracking: _t)),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _WaterCard(
                        tracking: _t,
                        busy: _busy,
                        onSet: _setWater,
                        onToggleReminders: _toggleWaterReminders,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

String _fmtKg(double kg) {
  final s = kg.toStringAsFixed(1);
  return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s} kg';
}

/// Bottom-sheet body for entering today's weight. Owns its own controller so
/// it is disposed with the sheet (after the close animation), not before.
class _LogWeightSheet extends StatefulWidget {
  final double? initialKg;
  const _LogWeightSheet({this.initialKg});

  @override
  State<_LogWeightSheet> createState() => _LogWeightSheetState();
}

class _LogWeightSheetState extends State<_LogWeightSheet> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    final v = widget.initialKg;
    _ctrl = TextEditingController(
      text: (v == null || v <= 0) ? '' : _fmtKg(v).replaceAll(' kg', ''),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _save() {
    final v = double.tryParse(_ctrl.text.trim());
    Navigator.pop(context, (v != null && v > 0 && v < 500) ? v : null);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 4,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Today's weight",
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          TextField(
            controller: _ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.ink),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.monitor_weight_rounded, size: 20),
              suffixText: 'kg',
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: _save, child: const Text('Save weight')),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────── weight card ──

class _WeightCard extends StatelessWidget {
  final StoredPlan stored;
  final PlanTracking tracking;
  final VoidCallback onLog;
  const _WeightCard(
      {required this.stored, required this.tracking, required this.onLog});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final start = stored.startWeightKg ?? tracking.firstWeight;
    final current = tracking.latestWeight ?? start;
    final target = stored.targetWeightKg;

    // Chart points: an anchor at the start weight, then each weigh-in.
    final points = <({DateTime date, double kg})>[];
    if (stored.startWeightKg != null) {
      points.add((date: stored.savedAt, kg: stored.startWeightKg!));
    }
    for (final w in tracking.weighIns) {
      points.removeWhere((p) => dateKey(p.date) == dateKey(w.date));
      points.add((date: w.date, kg: w.kg));
    }
    points.sort((a, b) => a.date.compareTo(b.date));

    String goalLine;
    Color goalColor = AppColors.brand;
    if (current == null || target == null) {
      goalLine = 'Log your weight to track progress.';
    } else {
      final toGo = (current - target).abs();
      if (toGo < 0.3) {
        goalLine = '🎉 You reached your target!';
      } else {
        final moved = start == null ? 0.0 : (start - current).abs();
        goalColor = AppColors.brand;
        goalLine = '${_fmtKg(toGo)} to target'
            '${moved >= 0.1 ? ' · ${_fmtKg(moved)} so far' : ''}';
      }
    }

    return SectionCard(
      title: 'Weight progress',
      icon: Icons.monitor_weight_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _stat(context, 'Start', start),
              _divider(),
              _stat(context, 'Current', current, emphasize: true),
              _divider(),
              _stat(context, 'Target', target),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: goalColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              goalLine,
              style: text.bodySmall
                  ?.copyWith(color: goalColor, fontWeight: FontWeight.w700),
            ),
          ),
          if (points.length >= 2) ...[
            const SizedBox(height: 18),
            SizedBox(
              height: 140,
              width: double.infinity,
              child: CustomPaint(
                painter: _WeightChartPainter(points: points, target: target),
              ),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onLog,
              icon: const Icon(Icons.add_rounded),
              label: const Text("Log today's weight"),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(BuildContext context, String label, double? kg,
      {bool emphasize = false}) {
    final text = Theme.of(context).textTheme;
    return Expanded(
      child: Column(
        children: [
          Text(label, style: text.bodySmall?.copyWith(color: AppColors.inkMuted)),
          const SizedBox(height: 4),
          Text(
            kg == null ? '—' : _fmtKg(kg),
            style: (emphasize ? text.titleLarge : text.titleMedium)?.copyWith(
              fontWeight: FontWeight.w800,
              color: emphasize ? AppColors.brand : AppColors.ink,
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() =>
      Container(width: 1, height: 34, color: AppColors.line);
}

class _WeightChartPainter extends CustomPainter {
  final List<({DateTime date, double kg})> points;
  final double? target;
  _WeightChartPainter({required this.points, this.target});

  @override
  void paint(Canvas canvas, Size size) {
    final values = points.map((p) => p.kg).toList();
    var lo = values.reduce(math.min);
    var hi = values.reduce(math.max);
    if (target != null) {
      lo = math.min(lo, target!);
      hi = math.max(hi, target!);
    }
    if (hi - lo < 1) {
      lo -= 1;
      hi += 1;
    }
    final pad = (hi - lo) * 0.15;
    lo -= pad;
    hi += pad;

    double x(int i) => points.length == 1
        ? size.width / 2
        : size.width * i / (points.length - 1);
    double y(double kg) => size.height * (1 - (kg - lo) / (hi - lo));

    // Target line (dashed).
    if (target != null) {
      final ty = y(target!);
      final tp = Paint()
        ..color = AppColors.violet.withValues(alpha: 0.7) // dashed target
        ..strokeWidth = 1.5;
      for (double dx = 0; dx < size.width; dx += 10) {
        canvas.drawLine(Offset(dx, ty), Offset(dx + 5, ty), tp);
      }
    }

    // Area fill under the line.
    final path = Path()..moveTo(x(0), y(points.first.kg));
    for (var i = 1; i < points.length; i++) {
      path.lineTo(x(i), y(points[i].kg));
    }
    final fill = Path.from(path)
      ..lineTo(x(points.length - 1), size.height)
      ..lineTo(x(0), size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.brand.withValues(alpha: 0.22),
            AppColors.brand.withValues(alpha: 0.02),
          ],
        ).createShader(Offset.zero & size),
    );

    // The line itself.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = AppColors.brand,
    );

    // Dots.
    final dot = Paint()..color = AppColors.brand;
    final ring = Paint()..color = AppColors.surface;
    for (var i = 0; i < points.length; i++) {
      final c = Offset(x(i), y(points[i].kg));
      canvas.drawCircle(c, 5, ring);
      canvas.drawCircle(c, 3.5, dot);
    }
  }

  @override
  bool shouldRepaint(covariant _WeightChartPainter old) =>
      old.points != points || old.target != target;
}

// ──────────────────────────────────────────────────────────── streak card ──

class _StreakCard extends StatelessWidget {
  final StoredPlan stored;
  final PlanTracking tracking;
  const _StreakCard({required this.stored, required this.tracking});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final streak = tracking.currentStreak(DateTime.now(), stored.startDate);
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.local_fire_department_rounded,
                  color: AppColors.accent, size: 20),
              const SizedBox(width: 6),
              Text('Streak',
                  style: text.bodySmall?.copyWith(color: AppColors.inkMuted)),
            ],
          ),
          const SizedBox(height: 10),
          RichText(
            text: TextSpan(
              style: text.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w800, color: AppColors.ink),
              children: [
                TextSpan(text: '$streak'),
                TextSpan(
                  text: streak == 1 ? '  day' : '  days',
                  style: text.bodySmall?.copyWith(
                    color: AppColors.inkMuted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            streak == 0 ? 'Log today to start' : 'Keep it going!',
            style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────── adherence card ──

class _AdherenceCard extends StatelessWidget {
  final StoredPlan stored;
  final PlanTracking tracking;
  const _AdherenceCard({required this.stored, required this.tracking});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final a = tracking.adherence(stored.plan, stored.startDate, DateTime.now());
    final pct = a.total == 0 ? 0.0 : a.done / a.total;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.task_alt_rounded, color: AppColors.brand, size: 20),
              const SizedBox(width: 6),
              Text('Adherence',
                  style: text.bodySmall?.copyWith(color: AppColors.inkMuted)),
            ],
          ),
          const SizedBox(height: 10),
          Text('${(pct * 100).round()}%',
              style: text.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w800, color: AppColors.ink)),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 8,
              backgroundColor: AppColors.line,
              valueColor: const AlwaysStoppedAnimation(AppColors.brand),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            a.total == 0
                ? 'Starts on Day 1'
                : '${a.done} of ${a.total} meals',
            style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────── water card ──

class _WaterCard extends StatelessWidget {
  final PlanTracking tracking;
  final bool busy;
  final ValueChanged<int> onSet;
  final ValueChanged<bool> onToggleReminders;
  const _WaterCard({
    required this.tracking,
    required this.busy,
    required this.onSet,
    required this.onToggleReminders,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final glasses = tracking.waterFor(DateTime.now());
    final goal = tracking.waterGoal;
    const blue = Color(0xFF3AA0E3);

    return SectionCard(
      title: 'Water intake',
      icon: Icons.water_drop_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: text.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w800, color: AppColors.ink),
                    children: [
                      TextSpan(text: '$glasses'),
                      TextSpan(
                        text: ' / $goal glasses',
                        style: text.bodyMedium?.copyWith(
                          color: AppColors.inkMuted,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _roundBtn(Icons.remove_rounded,
                  glasses > 0 ? () => onSet(glasses - 1) : null),
              const SizedBox(width: 10),
              _roundBtn(Icons.add_rounded, () => onSet(glasses + 1), filled: true),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(math.max(goal, glasses), (i) {
              final filled = i < glasses;
              return Icon(
                filled ? Icons.local_drink_rounded : Icons.local_drink_outlined,
                color: filled ? blue : AppColors.line,
                size: 26,
              );
            }),
          ),
          const SizedBox(height: 6),
          const Divider(),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: tracking.waterRemindersOn,
            onChanged: busy ? null : onToggleReminders,
            activeThumbColor: AppColors.brand,
            title: Text('Water reminders',
                style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            subtitle: Text('Daily nudges at 10am, 1pm, 4pm & 7pm',
                style: text.bodySmall?.copyWith(color: AppColors.inkMuted)),
          ),
        ],
      ),
    );
  }

  Widget _roundBtn(IconData icon, VoidCallback? onTap, {bool filled = false}) {
    final enabled = onTap != null;
    return Material(
      color: filled
          ? AppColors.brand
          : (enabled ? AppColors.fieldFill : AppColors.fieldFill.withValues(alpha: 0.5)),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 42,
          height: 42,
          child: Icon(
            icon,
            color: filled
                ? Colors.white
                : (enabled ? AppColors.ink : AppColors.inkFaint),
            size: 22,
          ),
        ),
      ),
    );
  }
}
