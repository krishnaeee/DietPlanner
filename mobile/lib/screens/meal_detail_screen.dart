import 'package:flutter/material.dart';

import '../models/diet_plan.dart';
import '../services/api_service.dart';
import '../services/plan_storage.dart';
import '../theme/app_theme.dart';
import '../widgets/fresh.dart';

/// A full recipe page for one meal: dish, macros, ingredients, and a one-tap
/// swap for a different dish. Swapping persists to storage (so Today and the
/// plan update via the revision notifier).
class MealDetailScreen extends StatefulWidget {
  final StoredPlan stored;
  final int dayIndex;
  final int mealIndex;
  const MealDetailScreen({
    super.key,
    required this.stored,
    required this.dayIndex,
    required this.mealIndex,
  });

  @override
  State<MealDetailScreen> createState() => _MealDetailScreenState();
}

class _MealDetailScreenState extends State<MealDetailScreen> {
  late DietPlan _plan = widget.stored.plan;
  bool _swapping = false;

  Meal get _meal => _plan.days[widget.dayIndex].meals[widget.mealIndex];

  Future<void> _swap() async {
    if (_swapping) return;
    final messenger = ScaffoldMessenger.of(context);
    final req = widget.stored.request;
    final loc = (widget.stored.location.trim().isNotEmpty
            ? widget.stored.location.trim()
            : '${req?['location'] ?? ''}')
        .trim();
    if (loc.isEmpty) {
      messenger.showSnackBar(const SnackBar(
          content: Text("This plan has no location, so meals can't be swapped.")));
      return;
    }
    final body = <String, dynamic>{
      'location': loc,
      'mealName': _meal.name,
      'time': _meal.time,
      'targetCalories': _meal.calories,
      'avoidDish': _meal.dish,
      if (req?['dietaryPreference'] != null)
        'dietaryPreference': req!['dietaryPreference'],
    };
    setState(() => _swapping = true);
    try {
      final fresh = await ApiService.swapMeal(body);

      // Re-read the CURRENT stored record so we don't clobber reminders, start
      // date or days appended since this screen opened — and don't resurrect a
      // plan deleted in the meantime.
      final all = await PlanStorage.loadAll();
      StoredPlan? current;
      for (final p in all) {
        if (p.id == widget.stored.id) {
          current = p;
          break;
        }
      }
      if (!mounted) return;
      if (current == null) {
        setState(() => _swapping = false);
        messenger.showSnackBar(const SnackBar(content: Text('This plan was deleted.')));
        return;
      }
      if (widget.dayIndex >= current.plan.days.length ||
          widget.mealIndex >= current.plan.days[widget.dayIndex].meals.length) {
        setState(() => _swapping = false);
        messenger.showSnackBar(
            const SnackBar(content: Text('This meal is no longer available.')));
        return;
      }

      final merged =
          current.plan.withReplacedMeal(widget.dayIndex, widget.mealIndex, fresh);
      await PlanStorage.upsert(current.copyWith(plan: merged));
      if (!mounted) return;
      setState(() {
        _plan = merged;
        _swapping = false;
      });
      messenger.showSnackBar(SnackBar(
          content: Text(fresh.dish.isEmpty ? 'Meal swapped.' : 'Swapped to ${fresh.dish}.')));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _swapping = false);
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _swapping = false);
      messenger.showSnackBar(const SnackBar(
          content: Text("Couldn't swap the meal. Please try again.")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final meal = _meal;
    final color = AppColors.forMeal(meal.name);
    return Scaffold(
      body: Column(
        children: [
          FreshHeader(
            title: meal.name.isEmpty ? 'Meal' : meal.name,
            subtitle: meal.time.isEmpty ? null : meal.time,
            showBack: true,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
              children: [
                // The dish floats as a lit orb over a violet haze.
                SizedBox(
                  height: 168,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            gradient: RadialGradient(
                              center: const Alignment(0.2, -0.4),
                              radius: 1.1,
                              colors: [
                                AppColors.violet.withValues(
                                    alpha: AppColors.brightness == Brightness.dark
                                        ? 0.22
                                        : 0.14),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                      Container(
                        width: 108,
                        height: 108,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const RadialGradient(
                            center: Alignment(-0.35, -0.4),
                            colors: [Color(0xFFFFB46B), Color(0xFFFF5D6D)],
                          ),
                          boxShadow: coralGlow(opacity: 0.20, blur: 16, y: 5),
                        ),
                        child: Icon(AppColors.iconForMeal(meal.name),
                            color: Colors.white, size: 48),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Text(meal.dish.isEmpty ? meal.name : meal.dish,
                    style: text.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.4,
                        height: 1.15)),
                if (meal.calories > 0) ...[
                  const SizedBox(height: 3),
                  Text('${meal.calories} kcal',
                      style: text.bodySmall?.copyWith(
                          color: color, fontWeight: FontWeight.w800)),
                ],

                if (meal.protein > 0 || meal.carbs > 0 || meal.fat > 0) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(child: _MacroChip('Protein', meal.protein, MacroColors.protein)),
                      const SizedBox(width: 10),
                      Expanded(child: _MacroChip('Carbs', meal.carbs, MacroColors.carbs)),
                      const SizedBox(width: 10),
                      Expanded(child: _MacroChip('Fat', meal.fat, MacroColors.fat)),
                    ],
                  ),
                ],

                if (meal.description.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text(meal.description,
                      style: text.bodyMedium?.copyWith(color: AppColors.ink, height: 1.5)),
                ],

                if (meal.ingredients.isNotEmpty) ...[
                  const SizedBox(height: 22),
                  Text('INGREDIENTS',
                      style: text.labelSmall?.copyWith(
                          color: AppColors.inkFaint,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8)),
                  const SizedBox(height: 10),
                  ...meal.ingredients.map((ing) => Container(
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        decoration: BoxDecoration(
                          border: Border(
                              bottom: BorderSide(color: AppColors.line)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                  color: AppColors.brand, shape: BoxShape.circle),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(ing.name,
                                  style: text.bodyMedium
                                      ?.copyWith(fontWeight: FontWeight.w700)),
                            ),
                            if (ing.quantity.isNotEmpty)
                              Text(ing.quantity,
                                  style: text.bodySmall?.copyWith(
                                      color: AppColors.inkMuted,
                                      fontWeight: FontWeight.w700)),
                          ],
                        ),
                      )),
                ],
                const SizedBox(height: 22),
                _swapping
                    ? Container(
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(AppRadius.field),
                          border: Border.all(color: AppColors.line),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const SizedBox(
                                width: 17,
                                height: 17,
                                child: CircularProgressIndicator(strokeWidth: 2)),
                            const SizedBox(width: 10),
                            Text('Finding a new dish…',
                                style: text.titleSmall?.copyWith(
                                    color: AppColors.inkMuted,
                                    fontWeight: FontWeight.w800)),
                          ],
                        ),
                      )
                    : GradientButton(
                        label: 'Swap this meal',
                        icon: Icons.autorenew_rounded,
                        onPressed: _swap,
                      ),
                const SizedBox(height: 6),
                Text('Swapping is free and keeps a similar calorie budget.',
                    textAlign: TextAlign.center,
                    style: text.bodySmall?.copyWith(color: AppColors.inkFaint)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MacroChip extends StatelessWidget {
  final String label;
  final int grams;
  final Color color;
  const _MacroChip(this.label, this.grams, this.color);
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Text('${grams}g',
              style: text.titleMedium
                  ?.copyWith(color: color, fontWeight: FontWeight.w900, height: 1)),
          const SizedBox(height: 3),
          Text(label.toUpperCase(),
              style: text.labelSmall?.copyWith(
                  color: AppColors.inkMuted,
                  fontWeight: FontWeight.w700,
                  fontSize: 9.5,
                  letterSpacing: 0.4)),
        ],
      ),
    );
  }
}
