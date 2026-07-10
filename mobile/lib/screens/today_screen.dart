import 'package:flutter/material.dart';

import '../models/tracking.dart';
import '../services/auth_service.dart';
import '../services/plan_storage.dart';
import '../services/tracking_storage.dart';
import '../theme/app_theme.dart';
import '../widgets/fresh.dart';
import 'diet_settings_screen.dart';
import 'grocery_list_screen.dart';
import 'meal_detail_screen.dart';

/// The Today tab for one plan (inside [PlanHub]). A calorie ring fed by meal
/// check-offs, macro tiles, the streak, and today's meals.
class TodayScreen extends StatefulWidget {
  final StoredPlan plan;
  const TodayScreen({super.key, required this.plan});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  late StoredPlan _plan = widget.plan;
  PlanTracking _tracking = PlanTracking();

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

  /// The plan may change while this tab is alive (extended/swapped on the Plan
  /// tab) — re-read it by id.
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

  void _openDietSettings() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => DietSettingsScreen(stored: _plan)));

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
                subtitle: _greeting(),
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

    return Scaffold(
      body: Column(
        children: [
          FreshHeader(
            title: sp.name.trim().isEmpty ? 'Today' : sp.name.trim(),
            subtitle: _greeting(),
            showBack: true,
            actions: [
              if (streak > 0) StreakBadge(days: streak, light: true),
              HeaderCircleButton(
                  icon: Icons.tune_rounded,
                  tooltip: 'Diet settings',
                  onTap: _openDietSettings),
            ],
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reloadPlan,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                children: [
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
                  Row(
                    children: [
                      Text('Today',
                          style:
                              text.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
                      const SizedBox(width: 8),
                      _DayPill(
                        label: ds.upcoming
                            ? 'Starts soon · Day ${day.day}'
                            : ds.finished
                                ? 'Complete · Day ${day.day}'
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
                      padding: const EdgeInsets.only(bottom: 12),
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
          ),
        ],
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
