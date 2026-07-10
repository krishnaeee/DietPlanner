import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/diet_plan.dart';
import '../theme/app_theme.dart';

/// Shared "Fresh" (Lifesum-inspired) building blocks: a calorie ring, macro
/// tiles, a streak badge, and a meal tile with a satisfying check-off that
/// feeds the ring. Kept in one place so every screen reads as one system.

/// A light header in the Fresh style: dark title + muted subtitle on the page
/// ground (no heavy gradient), an optional soft back button, and trailing
/// actions. Replaces the old GradientHeader across the redesigned screens.
class FreshHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool showBack;
  final List<Widget> actions;
  const FreshHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.showBack = false,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      bottom: false,
      // Gap between the OS status bar and the app's top bar.
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Container(
          decoration: BoxDecoration(
            gradient: AppColors.ctaGradient, // the brand theme colour
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: AppColors.brand.withValues(alpha: 0.28),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          padding: EdgeInsets.fromLTRB(showBack ? 10 : 18, 10, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (showBack) ...[
                HeaderCircleButton(
                  icon: Icons.arrow_back_rounded,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleLarge?.copyWith(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2)),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 12)),
                    ],
                  ],
                ),
              ),
              for (final a in actions) ...[const SizedBox(width: 8), a],
            ],
          ),
        ),
      ),
    );
  }
}

/// A translucent-white circular button for the coloured Fresh header.
class HeaderCircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  const HeaderCircleButton(
      {super.key, required this.icon, required this.onTap, this.tooltip});
  @override
  Widget build(BuildContext context) {
    final btn = Material(
      color: Colors.white.withValues(alpha: 0.2),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
            width: 36, height: 36, child: Icon(icon, size: 18, color: Colors.white)),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

/// A translucent-white pill (icon + label) for the coloured Fresh header.
class HeaderPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const HeaderPill(
      {super.key, required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.2),
      borderRadius: BorderRadius.circular(AppRadius.pill),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 17),
              const SizedBox(width: 5),
              Text(label,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Macro accent colours (consistent across the app).
class MacroColors {
  MacroColors._();
  static const protein = AppColors.brand; // green
  static const carbs = AppColors.accent; // amber
  static const fat = AppColors.dinner; // blue
}

/// A big calorie progress ring: the arc fills as meals are checked off.
class CalorieRing extends StatelessWidget {
  final int consumed;
  final int target;
  final double size;
  const CalorieRing({
    super.key,
    required this.consumed,
    required this.target,
    this.size = 132,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final pct = target <= 0 ? 0.0 : (consumed / target).clamp(0.0, 1.0);
    final left = (target - consumed);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(pct),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$consumed',
                style: text.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1,
                  color: AppColors.ink,
                  height: 1,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                left >= 0 ? 'of $target kcal' : '$target kcal · +${-left}',
                style: text.bodySmall?.copyWith(
                  color: AppColors.inkMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double pct;
  _RingPainter(this.pct);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 7;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..color = AppColors.brand.withValues(alpha: 0.12);
    canvas.drawCircle(c, r, track);

    if (pct > 0) {
      final rect = Rect.fromCircle(center: c, radius: r);
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12
        ..strokeCap = StrokeCap.round
        ..shader = const SweepGradient(
          startAngle: -math.pi / 2,
          endAngle: math.pi * 1.5,
          colors: [Color(0xFF2FD08A), AppColors.brand, AppColors.brandDark],
        ).createShader(rect);
      canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * pct, false, arc);
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.pct != pct;
}

/// A row of three macro tiles (protein / carbs / fat) with a mini progress bar.
class MacroTilesRow extends StatelessWidget {
  final int protein, carbs, fat;
  final int proteinTarget, carbsTarget, fatTarget;
  const MacroTilesRow({
    super.key,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.proteinTarget,
    required this.carbsTarget,
    required this.fatTarget,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _MacroTile('Protein', protein, proteinTarget, MacroColors.protein)),
        const SizedBox(width: 10),
        Expanded(child: _MacroTile('Carbs', carbs, carbsTarget, MacroColors.carbs)),
        const SizedBox(width: 10),
        Expanded(child: _MacroTile('Fat', fat, fatTarget, MacroColors.fat)),
      ],
    );
  }
}

class _MacroTile extends StatelessWidget {
  final String label;
  final int value, target;
  final Color color;
  const _MacroTile(this.label, this.value, this.target, this.color);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final pct = target <= 0 ? 0.0 : (value / target).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${value}g',
              style: text.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w900, color: color, height: 1)),
          const SizedBox(height: 2),
          Text(label.toUpperCase(),
              style: text.labelSmall?.copyWith(
                  color: AppColors.inkMuted,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                  fontSize: 9.5)),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 5,
              backgroundColor: color.withValues(alpha: 0.16),
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ],
      ),
    );
  }
}

/// A "🔥 N days" streak pill.
class StreakBadge extends StatelessWidget {
  final int days;
  final bool light; // white-on-transparent for gradient headers
  const StreakBadge({super.key, required this.days, this.light = false});

  @override
  Widget build(BuildContext context) {
    final fg = light ? Colors.white : AppColors.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: light
            ? Colors.white.withValues(alpha: 0.18)
            : AppColors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.local_fire_department_rounded, color: fg, size: 16),
          const SizedBox(width: 4),
          Text('$days',
              style: TextStyle(color: fg, fontWeight: FontWeight.w900, fontSize: 14)),
          const SizedBox(width: 3),
          Text(days == 1 ? 'day' : 'days',
              style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                  height: 1)),
        ],
      ),
    );
  }
}

/// A meal row with a round check-off that feeds the ring/streak.
class FreshMealTile extends StatelessWidget {
  final Meal meal;
  final bool done;
  final VoidCallback onToggle;
  final VoidCallback? onTap;
  const FreshMealTile({
    super.key,
    required this.meal,
    required this.done,
    required this.onToggle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = AppColors.forMeal(meal.name);
    return Material(
      color: done ? AppColors.brand.withValues(alpha: 0.06) : AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
                color: done
                    ? AppColors.brand.withValues(alpha: 0.35)
                    : AppColors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.all(13),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(AppColors.iconForMeal(meal.name), color: color, size: 19),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(meal.dish.isEmpty ? meal.name : meal.dish,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800, height: 1.15)),
                      const SizedBox(height: 2),
                      Text(
                        '${meal.name}${meal.time.isEmpty ? '' : ' · ${meal.time}'}'
                        '${meal.calories > 0 ? ' · ${meal.calories} kcal' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _Check(done: done, onTap: onToggle),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Check extends StatelessWidget {
  final bool done;
  final VoidCallback onTap;
  const _Check({required this.done, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      checked: done,
      label: done ? 'Eaten' : 'Mark eaten',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: done ? AppColors.brand : Colors.transparent,
            shape: BoxShape.circle,
            border: Border.all(
                color: done ? AppColors.brand : AppColors.line, width: 2),
          ),
          child: Icon(Icons.check_rounded,
              size: 18, color: done ? Colors.white : AppColors.inkFaint),
        ),
      ),
    );
  }
}
