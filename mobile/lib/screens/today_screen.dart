import 'package:flutter/material.dart';

import '../models/diet_plan.dart';
import '../models/tracking.dart';
import '../services/auth_service.dart';
import '../services/plan_storage.dart';
import '../services/tracking_storage.dart';
import '../theme/app_theme.dart';
import '../widgets/add_extra_sheet.dart';
import '../widgets/fresh.dart';
import 'add_plan_screen.dart';
import 'diet_settings_screen.dart';
import 'grocery_list_screen.dart';
import 'meal_detail_screen.dart';

const _kMonthsUp = [
  'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
  'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'
];
const _kWeekdaysUp = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];

/// The Today tab for one plan (inside PlanHub) — Nocturne's daily ritual:
/// the glowing calorie ring fed by check-offs, glass macro tiles, the streak,
/// an "Up next" meal promoted with a gradient border, and the day's meals.
class TodayScreen extends StatefulWidget {
  final StoredPlan plan;
  const TodayScreen({super.key, required this.plan});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  late StoredPlan _plan = widget.plan;
  PlanTracking _tracking = PlanTracking();

  /// Whether the "yesterday's unlogged meals" recovery list is expanded.
  bool _recoverOpen = false;

  /// Days since the last weigh-in, or null if none logged yet.
  int? get _daysSinceWeighIn {
    if (_tracking.weighIns.isEmpty) return null;
    final last = _tracking.weighIns.last.date;
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day)
        .difference(DateTime(last.year, last.month, last.day))
        .inDays;
  }

  @override
  void initState() {
    super.initState();
    _loadTracking();
    TrackingStorage.revision.addListener(_loadTracking);
    PlanStorage.revision.addListener(_reloadPlan);
  }

  @override
  void dispose() {
    TrackingStorage.revision.removeListener(_loadTracking);
    PlanStorage.revision.removeListener(_reloadPlan);
    super.dispose();
  }

  Future<void> _loadTracking() async {
    final t = await TrackingStorage.load(_plan.id);
    if (mounted) setState(() => _tracking = t);
  }

  /// The plan may change while this tab is alive (extended/swapped elsewhere).
  Future<void> _reloadPlan() async {
    final all = await PlanStorage.loadAll();
    for (final p in all) {
      if (p.id == _plan.id) {
        if (mounted) setState(() => _plan = p);
        break;
      }
    }
  }

  ({int index, bool upcoming, bool finished}) _dayState() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start =
        DateTime(_plan.startDate.year, _plan.startDate.month, _plan.startDate.day);
    final since = today.difference(start).inDays;
    final last = _plan.plan.days.length - 1;
    if (since < 0) return (index: 0, upcoming: true, finished: false);
    if (since > last) return (index: last, upcoming: false, finished: true);
    return (index: since, upcoming: false, finished: false);
  }

  Future<void> _toggle(int dayIndex, int mealIndex) async {
    final next = _tracking.toggleMeal(dayIndex, mealIndex);
    setState(() => _tracking = next);
    await TrackingStorage.save(_plan.id, next);
  }

  /// Marks a meal as "didn't eat" (or clears it) — distinct from eaten, so a
  /// skipped meal stops blocking "Up next" and the day can still reach "All done".
  Future<void> _skip(int dayIndex, int mealIndex) async {
    final next = _tracking.toggleSkip(dayIndex, mealIndex);
    setState(() => _tracking = next);
    await TrackingStorage.save(_plan.id, next);
  }

  /// Quick weigh-in from the daily loop (the trend that drives the whole plan
  /// otherwise lives only behind a pill in Progress).
  Future<void> _logWeight() async {
    final ctrl = TextEditingController(
      text: (_tracking.latestWeight != null && _tracking.latestWeight! > 0)
          ? _tracking.latestWeight!.toStringAsFixed(1).replaceAll('.0', '')
          : '',
    );
    final kg = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Today's weight"),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(suffixText: 'kg'),
          onSubmitted: (_) =>
              Navigator.pop(ctx, double.tryParse(ctrl.text.trim())),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, double.tryParse(ctrl.text.trim())),
              child: const Text('Save')),
        ],
      ),
    );
    ctrl.dispose();
    if (kg == null || kg <= 0 || kg >= 500 || !mounted) return;
    final next = _tracking.withWeighIn(DateTime.now(), kg);
    setState(() => _tracking = next);
    await TrackingStorage.save(_plan.id, next);
  }

  /// Logs an off-plan item (snack, tea, coffee) against [dayIndex].
  Future<void> _addExtra(int dayIndex) async {
    final recent = _tracking
        .recentExtras()
        .map((e) => ExtraPreset(e.name, e.calories, e.protein, e.carbs, e.fat))
        .toList();
    final item = await showAddExtraSheet(context, dayIndex, recent: recent);
    if (item == null || !mounted) return;
    final next = _tracking.withExtra(item);
    setState(() => _tracking = next);
    await TrackingStorage.save(_plan.id, next);
  }

  Future<void> _removeExtra(String id) async {
    final next = _tracking.withoutExtra(id);
    setState(() => _tracking = next);
    await TrackingStorage.save(_plan.id, next);
  }

  void _openDietSettings() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => DietSettingsScreen(stored: _plan)));

  void _openMeal(int dayIndex, int mealIndex) =>
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => MealDetailScreen(
            stored: _plan, dayIndex: dayIndex, mealIndex: mealIndex),
      ));

  /// Seeds a re-plan from the finished plan's original request, updated to the
  /// user's current weight (and switched to maintain when asked).
  Map<String, dynamic> _replanSeed({required bool maintain}) {
    final seed = Map<String, dynamic>.from(_plan.request ?? const {});
    final current = _tracking.latestWeight ?? _plan.startWeightKg;
    if (current != null) seed['weightKg'] = current;
    if (maintain) {
      seed['goal'] = 'maintain';
      seed.remove('targetWeightKg');
    }
    return seed;
  }

  /// Opens the create wizard pre-filled with [_replanSeed], so finishing a plan
  /// flows straight into the next one instead of a dead-end.
  void _openReplan({required bool maintain}) =>
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AddPlanScreen(seed: _replanSeed(maintain: maintain)),
      ));

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final sp = _plan;

    if (sp.plan.days.isEmpty) {
      return Scaffold(
        body: Column(
          children: [
            FreshHeader(
                title: sp.name.trim().isEmpty ? 'Today' : sp.name.trim(),
                showBack: true),
            const Expanded(
                child: Center(child: Text('This plan has no days yet.'))),
          ],
        ),
      );
    }

    final ds = _dayState();
    final day = sp.plan.days[ds.index];
    final plan = sp.plan;
    final streak = _tracking.currentStreak(DateTime.now(), sp.startDate);

    var kcal = 0, p = 0, c = 0, f = 0, doneCount = 0;
    for (var m = 0; m < day.meals.length; m++) {
      if (_tracking.isMealDone(ds.index, m)) {
        kcal += day.meals[m].calories;
        p += day.meals[m].protein;
        c += day.meals[m].carbs;
        f += day.meals[m].fat;
        doneCount++;
      }
    }
    // Off-plan items count toward the day too — that's the whole point of
    // logging them, otherwise the ring keeps flattering you.
    final extras = _tracking.extrasFor(ds.index);
    for (final e in extras) {
      kcal += e.calories;
      p += e.protein;
      c += e.carbs;
      f += e.fat;
    }
    // The next unresolved meal (neither eaten nor skipped) — promoted as
    // "Up next". Skipping a meal advances this so the day isn't stuck all day.
    var next = -1;
    for (var m = 0; m < day.meals.length; m++) {
      if (!_tracking.isMealResolved(ds.index, m)) {
        next = m;
        break;
      }
    }

    // Forgot-to-log recovery: yesterday's still-unresolved meals, surfaced in
    // context so a missed check-off can be fixed without hunting the Plan tab.
    final yIndex = ds.index - 1;
    final hasYesterday = !ds.upcoming && yIndex >= 0 && yIndex < plan.days.length;
    final yUnlogged = hasYesterday
        ? [
            for (var m = 0; m < plan.days[yIndex].meals.length; m++)
              if (!_tracking.isMealResolved(yIndex, m)) m,
          ]
        : const <int>[];

    // True completion = lived past the last day AND the whole journey is
    // generated (vs. just needing the next week loaded in the Plan tab).
    final journeyComplete =
        ds.finished && plan.days.length >= plan.requestedDays;
    final goalStr = (_plan.request?['goal'] ?? '').toString();
    final target = _plan.targetWeightKg;
    final startW = _plan.startWeightKg;
    final currentW = _tracking.latestWeight ?? startW;
    bool reached;
    if (goalStr == 'maintain' || target == null || currentW == null) {
      reached = true; // completing a maintain plan is itself the win
    } else if (goalStr == 'gain') {
      reached = currentW >= target - 0.3;
    } else {
      reached = currentW <= target + 0.3; // lose
    }

    final now = DateTime.now();
    var micro =
        '${_kWeekdaysUp[now.weekday - 1]} · ${_kMonthsUp[now.month - 1]} ${now.day}';
    if (ds.upcoming) {
      micro += ' · STARTS SOON';
    } else if (journeyComplete) {
      micro += ' · PLAN COMPLETE';
    } else if (ds.finished) {
      micro += ' · NEXT DAYS READY TO LOAD';
    }
    if (streak > 0) micro += ' · 🔥 $streak-DAY STREAK';

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _reloadPlan,
          color: AppColors.brand,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 96),
            children: [
              // ── header
              Row(
                children: [
                  HeaderCircleButton(
                    icon: Icons.arrow_back_rounded,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(micro,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelSmall?.copyWith(
                                color: AppColors.inkMuted,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.1,
                                fontSize: 9)),
                        const SizedBox(height: 2),
                        Text(_greeting(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleLarge?.copyWith(
                                fontSize: 21,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.5)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  HeaderCircleButton(
                      icon: Icons.tune_rounded,
                      tooltip: 'Diet settings',
                      onTap: _openDietSettings),
                ],
              ),
              const SizedBox(height: 18),

              // ── plan complete: celebrate the result + point at what's next
              if (journeyComplete) ...[
                _PlanCompleteCard(
                  reached: reached,
                  startWeightKg: startW,
                  currentWeightKg: currentW,
                  targetWeightKg: target,
                  adherence:
                      _tracking.adherence(plan, _plan.startDate, DateTime.now()),
                  streak: streak,
                  onContinue: () => _openReplan(maintain: false),
                  onMaintain: () => _openReplan(maintain: true),
                ),
                const SizedBox(height: 18),
              ],

              // ── weigh-in strip: the trend that drives the plan, in the loop
              if (!ds.upcoming && !journeyComplete) ...[
                _WeighInStrip(
                  currentKg: _tracking.latestWeight,
                  targetKg: _plan.targetWeightKg,
                  daysSinceWeighIn: _daysSinceWeighIn,
                  onLog: _logWeight,
                ),
                const SizedBox(height: 16),
              ],

              // ── the ring, straight on the canvas
              Center(child: CalorieRing(consumed: kcal, target: plan.dailyCalorieTarget)),
              const SizedBox(height: 18),
              if (plan.hasMacros)
                MacroTilesRow(
                  protein: p,
                  carbs: c,
                  fat: f,
                  proteinTarget: plan.dailyProteinTarget,
                  carbsTarget: plan.dailyCarbsTarget,
                  fatTarget: plan.dailyFatTarget,
                ),
              const SizedBox(height: 20),

              // ── up next
              if (next >= 0) ...[
                _Micro('UP NEXT · DAY ${day.day}'),
                const SizedBox(height: 8),
                _UpNextCard(
                  meal: day.meals[next],
                  onEat: () => _toggle(ds.index, next),
                  onSkip: () => _skip(ds.index, next),
                  onTap: () => _openMeal(ds.index, next),
                ),
                const SizedBox(height: 16),
              ] else ...[
                _AllDoneCard(eaten: doneCount, total: day.meals.length),
                const SizedBox(height: 16),
              ],

              // ── forgot-to-log recovery (yesterday's unlogged meals)
              if (yUnlogged.isNotEmpty) ...[
                _RecoveryCard(
                  dayLabel: '${plan.days[yIndex].day}',
                  count: yUnlogged.length,
                  open: _recoverOpen,
                  onTap: () => setState(() => _recoverOpen = !_recoverOpen),
                ),
                if (_recoverOpen) ...[
                  const SizedBox(height: 10),
                  ...List.generate(
                    plan.days[yIndex].meals.length,
                    (m) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: FreshMealTile(
                        meal: plan.days[yIndex].meals[m],
                        done: _tracking.isMealDone(yIndex, m),
                        skipped: _tracking.isMealSkipped(yIndex, m),
                        onToggle: () => _toggle(yIndex, m),
                        onSkip: () => _skip(yIndex, m),
                        onTap: () => _openMeal(yIndex, m),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
              ],

              // ── the day's meals
              _Micro('TODAY · $doneCount OF ${day.meals.length} EATEN'),
              const SizedBox(height: 8),
              ...List.generate(day.meals.length, (m) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: FreshMealTile(
                    meal: day.meals[m],
                    done: _tracking.isMealDone(ds.index, m),
                    skipped: _tracking.isMealSkipped(ds.index, m),
                    onToggle: () => _toggle(ds.index, m),
                    onSkip: () => _skip(ds.index, m),
                    onTap: () => _openMeal(ds.index, m),
                  ),
                );
              }),

              // ── anything off-plan eaten today
              const SizedBox(height: 6),
              if (extras.isNotEmpty) ...[
                _Micro('ALSO EATEN · ${_tracking.extraCaloriesFor(ds.index)} KCAL'),
                const SizedBox(height: 8),
                ...extras.map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: ExtraRow(
                        item: e,
                        onRemove: () => _removeExtra(e.id),
                      ),
                    )),
              ],
              AddExtraButton(onTap: () => _addExtra(ds.index)),

              const SizedBox(height: 4),
              _GroceryShortcut(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => GroceryListScreen(
                    plan: plan,
                    startIndex: ds.index,
                    windowDays: (plan.days.length - ds.index).clamp(1, 7),
                    startInDayMode: true,
                  ),
                )),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _greeting() {
    final h = DateTime.now().hour;
    final part =
        h < 12 ? 'Morning' : (h < 17 ? 'Afternoon' : 'Evening');
    final email = AuthService.instance.email ?? '';
    var name = email.contains('@') ? email.split('@').first : '';
    if (_plan.name.trim().isNotEmpty) name = _plan.name.trim();
    return name.isEmpty ? part : '$part, $name';
  }
}

/// A wide-tracked micro section label.
class _Micro extends StatelessWidget {
  final String label;
  const _Micro(this.label);
  @override
  Widget build(BuildContext context) {
    return Text(label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: AppColors.inkMuted,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.4,
            fontSize: 9));
  }
}

/// The next unchecked meal, promoted with the aurora gradient border.
class _UpNextCard extends StatelessWidget {
  final Meal meal;
  final VoidCallback onEat;
  final VoidCallback onSkip;
  final VoidCallback onTap;
  const _UpNextCard(
      {required this.meal,
      required this.onEat,
      required this.onSkip,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = AppColors.forMeal(meal.name);
    return Container(
      decoration: BoxDecoration(
        gradient: AppColors.auroraGradient,
        borderRadius: BorderRadius.circular(19),
      ),
      padding: const EdgeInsets.all(1.5),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(17.5),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(AppColors.iconForMeal(meal.name), color: color, size: 21),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(meal.dish.isEmpty ? meal.name : meal.dish,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w800, height: 1.15)),
                      const SizedBox(height: 2),
                      Text(
                        '${meal.name}${meal.time.isEmpty ? '' : ' · ${meal.time}'}'
                        '${meal.calories > 0 ? ' · ${meal.calories} kcal' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall
                            ?.copyWith(color: AppColors.inkMuted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                // Secondary "didn't eat" — a ghost icon so it doesn't compete
                // with the primary "Mark eaten" action.
                Semantics(
                  button: true,
                  label: "Didn't eat",
                  child: Tooltip(
                    message: "Didn't eat",
                    child: InkResponse(
                      onTap: onSkip,
                      radius: 24,
                      child: SizedBox(
                        width: 40,
                        height: 44,
                        child: Icon(Icons.do_not_disturb_on_outlined,
                            color: AppColors.inkFaint, size: 22),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Material(
                  color: AppColors.ink,
                  borderRadius: BorderRadius.circular(30),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: onEat,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        child: Center(
                          widthFactor: 1,
                          child: Text('Mark eaten',
                              style: TextStyle(
                                  color: AppColors.bg,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 10.5)),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when every meal of the day is resolved (eaten or skipped).
class _AllDoneCard extends StatelessWidget {
  final int eaten;
  final int total;
  const _AllDoneCard({required this.eaten, required this.total});
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final mint = MacroColors.protein;
    final skipped = total - eaten;
    final message = skipped == 0
        ? 'All $total meals done — great day! 🎉'
        : 'Day logged — $eaten eaten, $skipped skipped. Honest tracking beats a perfect-looking day. 👍';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: mint.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: mint.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(skipped == 0 ? Icons.celebration_rounded : Icons.check_circle_rounded,
              color: mint, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: text.bodyMedium
                    ?.copyWith(color: AppColors.ink, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }
}

/// The weigh-in strip in the daily loop: nudges a weigh-in when due, otherwise
/// shows the current weight and distance to target. Tapping it logs a weight.
class _WeighInStrip extends StatelessWidget {
  final double? currentKg;
  final double? targetKg;
  final int? daysSinceWeighIn; // null = never logged
  final VoidCallback onLog;
  const _WeighInStrip({
    required this.currentKg,
    required this.targetKg,
    required this.daysSinceWeighIn,
    required this.onLog,
  });

  static String _kg(double v) {
    final s = v.abs().toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final amber = AppColors.accent;
    final due = daysSinceWeighIn == null || daysSinceWeighIn! >= 7;

    String? toGo;
    if (currentKg != null && targetKg != null) {
      final d = (currentKg! - targetKg!).abs();
      toGo = d < 0.3 ? 'at your target 🎯' : '${_kg(d)} kg to go';
    }

    final title = due
        ? (daysSinceWeighIn == null ? 'Log your starting weight' : 'Time to weigh in')
        : '${currentKg != null ? '${_kg(currentKg!)} kg' : 'Weight'}'
            '${toGo != null ? ' · $toGo' : ''}';
    final sub = due
        ? 'Your weight trend is what keeps the plan on track.'
        : (daysSinceWeighIn == 0
            ? 'Logged today'
            : 'Logged ${daysSinceWeighIn}d ago · tap to update');

    return DecoratedBox(
      decoration: BoxDecoration(
        color: due ? amber.withValues(alpha: 0.10) : AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: due ? Colors.transparent : AppColors.line),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onLog,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.monitor_weight_rounded,
                    size: 18, color: due ? amber : AppColors.inkMuted),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: text.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w800, height: 1.2)),
                      const SizedBox(height: 2),
                      Text(sub,
                          style: text.bodySmall?.copyWith(
                              color: AppColors.inkMuted, fontSize: 11)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (due)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                        color: amber, borderRadius: BorderRadius.circular(30)),
                    child: Text('Log',
                        style: text.labelSmall?.copyWith(
                            color: AppColors.bg,
                            fontWeight: FontWeight.w800,
                            fontSize: 11)),
                  )
                else
                  Icon(Icons.edit_rounded, size: 15, color: AppColors.inkFaint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when the whole journey is complete: a celebratory recap of the result
/// and a goal-aware invitation to keep going (never a dead-end).
class _PlanCompleteCard extends StatelessWidget {
  final bool reached;
  final double? startWeightKg;
  final double? currentWeightKg;
  final double? targetWeightKg;
  final ({int done, int total, int elapsedDays}) adherence;
  final int streak;
  final VoidCallback onContinue;
  final VoidCallback onMaintain;
  const _PlanCompleteCard({
    required this.reached,
    required this.startWeightKg,
    required this.currentWeightKg,
    required this.targetWeightKg,
    required this.adherence,
    required this.streak,
    required this.onContinue,
    required this.onMaintain,
  });

  static String _kg(double v) {
    final s = v.abs().toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final mint = MacroColors.protein;
    final delta = (startWeightKg != null && currentWeightKg != null)
        ? currentWeightKg! - startWeightKg!
        : null;
    final pct =
        adherence.total == 0 ? 0 : (100 * adherence.done ~/ adherence.total);

    final recap = delta != null
        ? 'You went ${_kg(startWeightKg!)} → ${_kg(currentWeightKg!)} kg '
            '(${delta < 0 ? '−' : '+'}${_kg(delta)} kg) over ${adherence.elapsedDays} days.'
        : 'Nice work sticking with it over ${adherence.elapsedDays} days.';

    Widget stat(String value, String label, Color color) => Expanded(
          child: Column(
            children: [
              Text(value,
                  style: text.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w900, color: color)),
              const SizedBox(height: 2),
              Text(label,
                  style: text.labelSmall?.copyWith(
                      color: AppColors.inkMuted,
                      fontWeight: FontWeight.w700,
                      fontSize: 9,
                      letterSpacing: 0.5)),
            ],
          ),
        );

    return Container(
      decoration: BoxDecoration(
        gradient: AppColors.auroraGradient,
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.all(1.5),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18.5),
        ),
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(reached ? '🎉' : '💪', style: const TextStyle(fontSize: 22)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(reached ? 'Goal reached!' : 'Plan complete',
                      style: text.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900, letterSpacing: -0.4)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(recap,
                style: text.bodyMedium
                    ?.copyWith(color: AppColors.inkMuted, height: 1.4)),
            const SizedBox(height: 16),
            Row(
              children: [
                if (delta != null)
                  stat('${delta < 0 ? '−' : '+'}${_kg(delta)} kg', 'CHANGE',
                      delta < 0 ? mint : AppColors.ink),
                stat('$pct%', 'ADHERENCE', mint),
                stat('🔥 $streak', streak == 1 ? 'DAY' : 'DAYS', AppColors.ink),
              ],
            ),
            const SizedBox(height: 18),
            GradientButton(
              label: reached
                  ? 'Maintain this weight'
                  : (targetWeightKg != null
                      ? 'Keep going toward ${_kg(targetWeightKg!)} kg'
                      : 'Keep going'),
              icon: reached
                  ? Icons.self_improvement_rounded
                  : Icons.trending_flat_rounded,
              onPressed: reached ? onMaintain : onContinue,
            ),
            const SizedBox(height: 4),
            Center(
              child: TextButton(
                onPressed: reached ? onContinue : onMaintain,
                child: Text(reached ? 'Set a new goal' : 'Switch to maintain'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Gentle nudge to log yesterday's meals you forgot to check off. Tapping it
/// expands an in-place list so you never have to hunt for the right day.
class _RecoveryCard extends StatelessWidget {
  final String dayLabel;
  final int count;
  final bool open;
  final VoidCallback onTap;
  const _RecoveryCard({
    required this.dayLabel,
    required this.count,
    required this.open,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final amber = AppColors.accent;
    return Material(
      color: amber.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.history_rounded, color: amber, size: 19),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Yesterday (Day $dayLabel): $count meal${count == 1 ? '' : 's'} '
                  'unlogged — count them?',
                  style: text.bodySmall?.copyWith(
                      color: AppColors.ink,
                      fontWeight: FontWeight.w700,
                      height: 1.3),
                ),
              ),
              const SizedBox(width: 8),
              AnimatedRotation(
                turns: open ? 0.5 : 0,
                duration: motion(context, 180),
                child: Icon(Icons.expand_more_rounded,
                    color: AppColors.inkMuted, size: 22),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroceryShortcut extends StatelessWidget {
  final VoidCallback onTap;
  const _GroceryShortcut({required this.onTap});
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const Icon(Icons.shopping_cart_rounded,
                    color: AppColors.brand, size: 19),
                const SizedBox(width: 10),
                Expanded(
                  child: Text("Today's groceries",
                      style: text.bodyMedium?.copyWith(
                          color: AppColors.ink, fontWeight: FontWeight.w800)),
                ),
                Icon(Icons.chevron_right_rounded, color: AppColors.inkFaint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
