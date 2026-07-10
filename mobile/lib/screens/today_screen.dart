import 'package:flutter/material.dart';

import '../models/tracking.dart';
import '../services/active_plan.dart';
import '../services/auth_service.dart';
import '../services/plan_storage.dart';
import '../services/tracking_storage.dart';
import '../theme/app_theme.dart';
import '../widgets/fresh.dart';
import 'add_plan_screen.dart';
import 'grocery_list_screen.dart';
import 'meal_detail_screen.dart';
import 'settings_screen.dart';

/// The Today dashboard — the app's new home. Shows the active plan's meals for
/// today, a calorie ring that fills as they're checked off, macros, and the
/// current streak. Checking a meal is the core daily interaction.
class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  List<StoredPlan> _plans = [];
  StoredPlan? _plan;
  PlanTracking _tracking = PlanTracking();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    PlanStorage.revision.addListener(_load);
    ActivePlan.id.addListener(_load);
    TrackingStorage.revision.addListener(_reloadTracking);
  }

  @override
  void dispose() {
    PlanStorage.revision.removeListener(_load);
    ActivePlan.id.removeListener(_load);
    TrackingStorage.revision.removeListener(_reloadTracking);
    super.dispose();
  }

  Future<void> _load() async {
    final all = await PlanStorage.loadAll();
    final active = ActivePlan.resolve(all);
    final tracking =
        active == null ? PlanTracking() : await TrackingStorage.load(active.id);
    if (!mounted) return;
    setState(() {
      _plans = all;
      _plan = active;
      _tracking = tracking;
      _loading = false;
    });
  }

  /// Reloads only tracking (e.g. after weight/water logged on the Progress tab).
  Future<void> _reloadTracking() async {
    final p = _plan;
    if (p == null) return;
    final t = await TrackingStorage.load(p.id);
    if (mounted) setState(() => _tracking = t);
  }

  Future<void> _openSwitcher() async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('Switch plan',
                  style: Theme.of(ctx)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800)),
            ),
            for (final p in _plans)
              ListTile(
                leading: Icon(Icons.restaurant_menu_rounded,
                    color: p.id == _plan?.id ? AppColors.brand : AppColors.inkMuted),
                title: Text(p.name.trim().isEmpty ? 'Plan' : p.name.trim(),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                trailing: p.id == _plan?.id
                    ? const Icon(Icons.check_rounded, color: AppColors.brand)
                    : null,
                onTap: () => Navigator.pop(ctx, p.id),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen != null) await ActivePlan.set(chosen);
  }

  /// Which plan day to show today: the elapsed day if the plan is running, else
  /// day 1 (upcoming) or the last day (finished).
  ({int index, bool upcoming, bool finished}) _dayState(StoredPlan sp) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start =
        DateTime(sp.startDate.year, sp.startDate.month, sp.startDate.day);
    final since = today.difference(start).inDays;
    final last = sp.plan.days.length - 1;
    if (since < 0) return (index: 0, upcoming: true, finished: false);
    if (since > last) return (index: last, upcoming: false, finished: true);
    return (index: since, upcoming: false, finished: false);
  }

  Future<void> _toggle(int dayIndex, int mealIndex) async {
    final next = _tracking.toggleMeal(dayIndex, mealIndex);
    setState(() => _tracking = next);
    await TrackingStorage.save(_plan!.id, next);
  }

  void _openSettings() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const SettingsScreen()));

  void _createPlan() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const AddPlanScreen()));

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    // No plan, or a plan that came back with no days — both show the empty state
    // rather than crashing on an out-of-range day index.
    if (_plan == null || _plan!.plan.days.isEmpty) {
      return _EmptyToday(onCreate: _createPlan);
    }
    return _dashboard(_plan!);
  }

  Widget _dashboard(StoredPlan sp) {
    final text = Theme.of(context).textTheme;
    final ds = _dayState(sp);
    final day = sp.plan.days[ds.index];
    final plan = sp.plan;

    // Consumed = sum of checked-off meals for the shown day.
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
    final streak = _tracking.currentStreak(DateTime.now(), sp.startDate);

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            // ── header
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_greeting(),
                          style: text.bodyMedium?.copyWith(color: AppColors.inkMuted)),
                      const SizedBox(height: 1),
                      // Tapping the plan name switches plans (family devices).
                      InkWell(
                        onTap: _plans.length > 1 ? _openSwitcher : null,
                        borderRadius: BorderRadius.circular(8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                sp.name.trim().isEmpty ? 'Your plan' : sp.name.trim(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.headlineSmall?.copyWith(
                                    fontWeight: FontWeight.w900, letterSpacing: -0.4),
                              ),
                            ),
                            if (_plans.length > 1)
                              Icon(Icons.expand_more_rounded,
                                  color: AppColors.inkMuted, size: 22),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (streak > 0) ...[StreakBadge(days: streak), const SizedBox(width: 8)],
                _CircleBtn(icon: Icons.settings_rounded, onTap: _openSettings),
              ],
            ),
            const SizedBox(height: 16),

            // ── calorie + macro hero
            Container(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppColors.brand.withValues(alpha: 0.10),
                    AppColors.surface,
                  ],
                ),
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(color: AppColors.line),
              ),
              child: Column(
                children: [
                  CalorieRing(consumed: kcal, target: plan.dailyCalorieTarget),
                  if (plan.hasMacros) ...[
                    const SizedBox(height: 16),
                    MacroTilesRow(
                      protein: p,
                      carbs: c,
                      fat: f,
                      proteinTarget: plan.dailyProteinTarget,
                      carbsTarget: plan.dailyCarbsTarget,
                      fatTarget: plan.dailyFatTarget,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 22),

            // ── day heading
            Row(
              children: [
                Text('Today', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
                const SizedBox(width: 8),
                _DayPill(
                  label: ds.upcoming
                      ? 'Starts soon · Day ${day.day}'
                      : ds.finished
                          ? 'Plan complete · Day ${day.day}'
                          : 'Day ${day.day}',
                ),
                const Spacer(),
                Text('$doneCount/${day.meals.length}',
                    style: text.labelLarge?.copyWith(
                        color: AppColors.brand, fontWeight: FontWeight.w900)),
              ],
            ),
            const SizedBox(height: 12),

            ...List.generate(day.meals.length, (m) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: FreshMealTile(
                  meal: day.meals[m],
                  done: _tracking.isMealDone(ds.index, m),
                  onToggle: () => _toggle(ds.index, m),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => MealDetailScreen(
                        stored: sp, dayIndex: ds.index, mealIndex: m),
                  )),
                ),
              );
            }),

            const SizedBox(height: 6),
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
    );
  }

  String _greeting() {
    final h = DateTime.now().hour;
    final part = h < 12 ? 'Good morning' : (h < 17 ? 'Good afternoon' : 'Good evening');
    final email = AuthService.instance.email ?? '';
    final name = email.contains('@') ? email.split('@').first : '';
    return name.isEmpty ? part : '$part, $name';
  }
}

class _DayPill extends StatelessWidget {
  final String label;
  const _DayPill({required this.label});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.brand.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Text(label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: AppColors.brandDark, fontWeight: FontWeight.w800)),
    );
  }
}

class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleBtn({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      shape: CircleBorder(side: BorderSide(color: AppColors.line)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
            width: 40, height: 40, child: Icon(icon, size: 20, color: AppColors.inkMuted)),
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
      color: AppColors.brand.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Icon(Icons.shopping_cart_rounded, color: AppColors.brand, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text("Today's groceries",
                    style: text.bodyMedium?.copyWith(
                        color: AppColors.brandDark, fontWeight: FontWeight.w800)),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.brand),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyToday extends StatelessWidget {
  final VoidCallback onCreate;
  const _EmptyToday({required this.onCreate});
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                    color: AppColors.brand.withValues(alpha: 0.10),
                    shape: BoxShape.circle),
                child: const Icon(Icons.eco_rounded, color: AppColors.brand, size: 44),
              ),
              const SizedBox(height: 22),
              Text('Start your journey',
                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
              const SizedBox(height: 10),
              Text(
                'Create an AI diet plan and your daily meals, macros and streak show up right here.',
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: AppColors.inkMuted, height: 1.4),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: PrimaryButton(
                  label: 'Create your first plan',
                  icon: Icons.auto_awesome_rounded,
                  onPressed: onCreate,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
