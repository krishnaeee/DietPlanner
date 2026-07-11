import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/diet_plan.dart';
import '../theme/app_theme.dart';

/// Nocturne building blocks: an on-canvas header with glass buttons, the
/// glowing gradient calorie ring, glass macro tiles, a streak badge, a meal
/// tile with a mint check-off, and the coral gradient CTA. One place, one look.

/// On-canvas header: heavy title + micro subtitle, glass circle back button,
/// trailing actions. No coloured band — Nocturne screens sit on the canvas.
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
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
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
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.4)),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 1),
                    Text(subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall
                            ?.copyWith(color: AppColors.inkMuted, fontSize: 11.5)),
                  ],
                ],
              ),
            ),
            for (final a in actions) ...[const SizedBox(width: 8), a],
          ],
        ),
      ),
    );
  }
}

/// A glass circular icon button (header back, gear, …). Mode-aware.
class HeaderCircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  const HeaderCircleButton(
      {super.key, required this.icon, required this.onTap, this.tooltip});
  @override
  Widget build(BuildContext context) {
    final btn = Material(
      color: AppColors.surface,
      shape: CircleBorder(side: BorderSide(color: AppColors.line)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
            width: 38, height: 38, child: Icon(icon, size: 18, color: AppColors.ink)),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

/// A glass pill (icon + label) for header actions.
class HeaderPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const HeaderPill(
      {super.key, required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: AppColors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: AppColors.brand, size: 16),
                const SizedBox(width: 5),
                Text(label,
                    style: TextStyle(
                        color: AppColors.ink,
                        fontWeight: FontWeight.w800,
                        fontSize: 12.5)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Macro accent colours — resolve per mode via the design system.
class MacroColors {
  MacroColors._();
  static Color get protein => AppColors.proteinAccent;
  static Color get carbs => AppColors.carbsAccent;
  static Color get fat => AppColors.fatAccent;
}

/// The glowing coral→violet calorie ring. Fills as meals are checked off.
class CalorieRing extends StatelessWidget {
  final int consumed;
  final int target;
  final double size;
  const CalorieRing({
    super.key,
    required this.consumed,
    required this.target,
    this.size = 150,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final pct = target <= 0 ? 0.0 : (consumed / target).clamp(0.0, 1.0);
    final left = target - consumed;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(pct, AppColors.surfaceHigh),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _fmt(consumed),
                style: text.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1.5,
                  color: AppColors.ink,
                  height: 1,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                left >= 0 ? 'OF ${_fmt(target)} KCAL' : '+${_fmt(-left)} OVER',
                style: text.labelSmall?.copyWith(
                  color: AppColors.inkMuted,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                  fontSize: 9,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(int n) {
    final s = n.toString();
    if (s.length <= 3) return s;
    return '${s.substring(0, s.length - 3)},${s.substring(s.length - 3)}';
  }
}

class _RingPainter extends CustomPainter {
  final double pct;
  final Color track;
  _RingPainter(this.pct, this.track);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 8;
    final rect = Rect.fromCircle(center: c, radius: r);

    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 11
        ..color = track,
    );

    if (pct <= 0) return;
    final sweep = math.pi * 2 * pct;
    final shader = const SweepGradient(
      startAngle: -math.pi / 2,
      endAngle: math.pi * 1.5,
      colors: [Color(0xFFFF7A59), Color(0xFFFF4D6D), Color(0xFF8B7CFF)],
    ).createShader(rect);

    // Soft glow under the arc, then the crisp arc on top.
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 11
        ..strokeCap = StrokeCap.round
        ..shader = shader
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 4),
    );
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 11
        ..strokeCap = StrokeCap.round
        ..shader = shader,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.pct != pct || old.track != track;
}

/// Three glass macro tiles (protein / carbs / fat) with a thin progress line.
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
        Expanded(child: _MacroTile('PROTEIN', protein, proteinTarget, MacroColors.protein)),
        const SizedBox(width: 9),
        Expanded(child: _MacroTile('CARBS', carbs, carbsTarget, MacroColors.carbs)),
        const SizedBox(width: 9),
        Expanded(child: _MacroTile('FAT', fat, fatTarget, MacroColors.fat)),
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
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: text.labelSmall?.copyWith(
                  color: AppColors.inkMuted,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.9,
                  fontSize: 8.5)),
          const SizedBox(height: 3),
          Text('${value}g',
              style: text.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w900, color: AppColors.ink, height: 1)),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 4,
              backgroundColor: AppColors.surfaceHigh,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ],
      ),
    );
  }
}

/// A "🔥 N days" streak pill (coral-tinted; [light] keeps working on gradients).
class StreakBadge extends StatelessWidget {
  final int days;
  final bool light;
  const StreakBadge({super.key, required this.days, this.light = false});

  @override
  Widget build(BuildContext context) {
    final fg = light ? Colors.white : AppColors.brandDark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: light
            ? Colors.white.withValues(alpha: 0.18)
            : AppColors.brand.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.local_fire_department_rounded, color: fg, size: 15),
          const SizedBox(width: 4),
          Text('$days',
              style: TextStyle(color: fg, fontWeight: FontWeight.w900, fontSize: 13)),
          const SizedBox(width: 3),
          Text(days == 1 ? 'day' : 'days',
              style: TextStyle(
                  color: fg, fontWeight: FontWeight.w700, fontSize: 10.5, height: 1)),
        ],
      ),
    );
  }
}

/// A glass meal row with a mint check-off that feeds the ring/streak.
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
    final mint = MacroColors.protein;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
                color: done ? mint.withValues(alpha: 0.45) : AppColors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(AppColors.iconForMeal(meal.name), color: color, size: 19),
                ),
                const SizedBox(width: 12),
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
                        style: text.bodySmall
                            ?.copyWith(color: AppColors.inkMuted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _Check(done: done, onTap: onToggle, mint: mint),
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
  final Color mint;
  const _Check({required this.done, required this.onTap, required this.mint});

  @override
  Widget build(BuildContext context) {
    final dark = AppColors.brightness == Brightness.dark;
    return Semantics(
      button: true,
      checked: done,
      label: done ? 'Eaten' : 'Mark eaten',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: done ? mint : Colors.transparent,
            shape: BoxShape.circle,
            border: Border.all(color: done ? mint : AppColors.line, width: 2),
          ),
          child: Icon(Icons.check_rounded,
              size: 16,
              color: done
                  ? (dark ? const Color(0xFF062B1A) : Colors.white)
                  : AppColors.inkFaint),
        ),
      ),
    );
  }
}

/// The coral gradient CTA — Nocturne's primary button.
class GradientButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onPressed;
  const GradientButton(
      {super.key, required this.label, this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: AppColors.ctaGradient,
        borderRadius: BorderRadius.circular(AppRadius.field),
        boxShadow: coralGlow(),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.field),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 15),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, color: Colors.white, size: 19),
                  const SizedBox(width: 9),
                ],
                Text(label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 15)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
