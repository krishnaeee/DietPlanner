import 'package:flutter/material.dart';

import '../models/diet_plan.dart';
import '../models/recipe.dart';
import '../services/api_service.dart';
import '../services/plan_storage.dart';
import '../services/recipe_store.dart';
import '../theme/app_theme.dart';
import '../widgets/fresh.dart';
import 'paywall_screen.dart';

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

  Recipe? _recipe;
  bool _loadingRecipe = false;

  Meal get _meal => _plan.days[widget.dayIndex].meals[widget.mealIndex];

  @override
  void initState() {
    super.initState();
    _loadCachedRecipe();
  }

  /// Show a locally-cached recipe instantly (offline, no round-trip) if we have
  /// one for this dish.
  Future<void> _loadCachedRecipe() async {
    final dish = _meal.dish.trim();
    if (dish.isEmpty) return;
    final cached = await RecipeStore.get(dish);
    if (cached != null && mounted) setState(() => _recipe = cached);
  }

  /// Fetches preparation steps. Free on a cache hit (server or local); a miss
  /// costs one credit (or is free on a subscription). Opens the paywall on 402.
  Future<void> _getSteps() async {
    if (_loadingRecipe) return;
    final dish = _meal.dish.trim();
    if (dish.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final req = widget.stored.request;

    setState(() => _loadingRecipe = true);
    try {
      final recipe = await ApiService.getRecipe(<String, dynamic>{
        'dish': dish,
        'location': widget.stored.location.trim().isNotEmpty
            ? widget.stored.location.trim()
            : '${req?['location'] ?? ''}',
        if (req?['dietaryPreference'] != null)
          'dietaryPreference': req!['dietaryPreference'],
        if (req?['allergies'] is List) 'allergies': req!['allergies'],
      });
      await RecipeStore.put(dish, recipe);
      if (!mounted) return;
      setState(() {
        _recipe = recipe;
        _loadingRecipe = false;
      });
    } on PaymentRequiredException catch (e) {
      if (!mounted) return;
      setState(() => _loadingRecipe = false);
      final bought = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => PaywallScreen(reason: e.message),
      ));
      if (bought == true && mounted) _getSteps(); // retry after buying
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loadingRecipe = false);
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingRecipe = false);
      messenger.showSnackBar(const SnackBar(
          content: Text("Couldn't get preparation steps. Please try again.")));
    }
  }

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
        _recipe = null; // the dish changed — old steps no longer apply
      });
      _loadCachedRecipe(); // show cached steps if we already have them for the new dish
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
                            colors: AppColors.orbColors,
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
                // ── how to make it
                const SizedBox(height: 22),
                if (_recipe != null)
                  _RecipeView(recipe: _recipe!)
                else
                  _PrepStepsButton(
                    loading: _loadingRecipe,
                    onTap: _getSteps,
                  ),

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

/// The call-to-action to fetch preparation steps, with an honest note on cost.
class _PrepStepsButton extends StatelessWidget {
  final bool loading;
  final VoidCallback onTap;
  const _PrepStepsButton({required this.loading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (loading) {
      return Container(
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
                width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Text('Writing the steps…',
                style: text.titleSmall
                    ?.copyWith(color: AppColors.inkMuted, fontWeight: FontWeight.w800)),
          ],
        ),
      );
    }
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadius.field),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.field),
                border: Border.all(color: AppColors.brand),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.menu_book_rounded, size: 18, color: AppColors.brand),
                  const SizedBox(width: 9),
                  Text('How to make it',
                      style: text.titleSmall?.copyWith(
                          color: AppColors.brand, fontWeight: FontWeight.w800)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Generated once, then free forever — costs a credit only the first time '
          'anyone makes this dish.',
          textAlign: TextAlign.center,
          style: text.bodySmall?.copyWith(color: AppColors.inkFaint, height: 1.4),
        ),
      ],
    );
  }
}

/// Renders a fetched recipe: time/servings, numbered steps, and any tips.
class _RecipeView extends StatelessWidget {
  final Recipe recipe;
  const _RecipeView({required this.recipe});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.menu_book_rounded, size: 16, color: AppColors.brand),
              const SizedBox(width: 8),
              Text('HOW TO MAKE IT',
                  style: text.labelSmall?.copyWith(
                      color: AppColors.inkMuted,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.0,
                      fontSize: 9)),
              const Spacer(),
              if (recipe.prepMinutes > 0 || recipe.servings > 0)
                Text(
                  [
                    if (recipe.prepMinutes > 0) '${recipe.prepMinutes} min',
                    if (recipe.servings > 0) 'serves ${recipe.servings}',
                  ].join(' · '),
                  style: text.bodySmall?.copyWith(
                      color: AppColors.inkMuted, fontWeight: FontWeight.w700),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ...List.generate(recipe.steps.length, (i) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.brand.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Text('${i + 1}',
                        style: text.labelSmall?.copyWith(
                            color: AppColors.brand,
                            fontWeight: FontWeight.w800,
                            fontSize: 11)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(recipe.steps[i],
                        style: text.bodyMedium?.copyWith(height: 1.45)),
                  ),
                ],
              ),
            );
          }),
          if (recipe.tips.isNotEmpty) ...[
            const SizedBox(height: 2),
            ...recipe.tips.map((t) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lightbulb_outline_rounded,
                          size: 15, color: AppColors.accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(t,
                            style: text.bodySmall?.copyWith(
                                color: AppColors.inkMuted, height: 1.4)),
                      ),
                    ],
                  ),
                )),
          ],
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
