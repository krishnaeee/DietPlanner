import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A glass card with an optional Nocturne micro-label header.
class SectionCard extends StatelessWidget {
  final String? title;
  final IconData? icon;
  final Widget child;
  final EdgeInsetsGeometry padding;

  const SectionCard({
    super.key,
    this.title,
    this.icon,
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.line),
      ),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 14, color: AppColors.brand),
                    const SizedBox(width: 7),
                  ],
                  Text(
                    title!.toUpperCase(),
                    style: text.labelSmall?.copyWith(
                      color: AppColors.inkFaint,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      fontSize: 8.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 13),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

/// A small label shown above an input field.
class FieldLabel extends StatelessWidget {
  final String text;
  const FieldLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: AppColors.inkMuted,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
