import 'package:flutter/material.dart';

import '../models/diet_plan.dart';
import '../models/tracking.dart';
import '../services/auth_service.dart';
import '../services/plan_storage.dart';
import '../services/tracking_storage.dart';
import '../theme/app_theme.dart';
import '../widgets/add_extra_sheet.dart';
import '../widgets/fresh.dart';
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

  /// Logs an off-plan item (snack, tea, coffee) against [dayIndex].
  Future<void> _addExtra(int dayIndex) async {
    final item = await showAddExtraSheet(context, dayIndex);
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

    final now = DateTime.now();
    var micro =
        '${_kWeekdaysUp[now.weekday - 1]} · ${_kMonthsUp[now.month - 1]} ${now.day}';
    if (ds.upcoming) {
      micro += ' · STARTS SOON';
    } else if (ds.finished) {
      micro += ' · PLAN COMPLETE';
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
