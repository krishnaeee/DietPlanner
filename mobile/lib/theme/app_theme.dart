import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Central design system: colors, radii, spacing, shadows, and the ThemeData
/// that ties them together. Every screen reads from here so the look stays
/// cohesive.
class AppColors {
  AppColors._();

  // Brand greens.
  static const brand = Color(0xFF1E9E64);
  static const brandDark = Color(0xFF12824E);
  static const brandDeep = Color(0xFF0C5E3A);

  // Energy accent (calories / highlights).
  static const accent = Color(0xFFF59E1B);

  // Neutrals.
  static const bg = Color(0xFFF2F6F2);
  static const surface = Colors.white;
  static const ink = Color(0xFF17241D);
  static const inkMuted = Color(0xFF6B7C72);
  static const inkFaint = Color(0xFF9AA9A0);
  static const line = Color(0xFFE4EDE6);
  static const fieldFill = Color(0xFFF6FAF6);

  // Meal-type accents.
  static const breakfast = Color(0xFFF59E1B);
  static const lunch = Color(0xFF1E9E64);
  static const dinner = Color(0xFF4C6EF5);
  static const snack = Color(0xFFB16BE8);

  static const brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF27B277), Color(0xFF0F7A49)],
  );

  /// Returns the accent color for a meal based on its name.
  static Color forMeal(String name) {
    final n = name.toLowerCase();
    if (n.contains('break')) return breakfast;
    if (n.contains('lunch')) return lunch;
    if (n.contains('dinner') || n.contains('supper')) return dinner;
    if (n.contains('snack')) return snack;
    return brand;
  }

  static IconData iconForMeal(String name) {
    final n = name.toLowerCase();
    if (n.contains('break')) return Icons.wb_twilight_rounded;
    if (n.contains('lunch')) return Icons.lunch_dining_rounded;
    if (n.contains('dinner') || n.contains('supper')) return Icons.nightlight_round;
    if (n.contains('snack')) return Icons.cookie_rounded;
    return Icons.restaurant_rounded;
  }
}

class AppRadius {
  AppRadius._();
  static const card = 22.0;
  static const field = 16.0;
  static const chip = 30.0;
  static const pill = 40.0;
}

/// A soft, low-contrast elevation used on cards.
List<BoxShadow> softShadow({double opacity = 0.06, double blur = 24, double y = 12}) => [
      BoxShadow(
        color: const Color(0xFF13351F).withValues(alpha: opacity),
        blurRadius: blur,
        offset: Offset(0, y),
      ),
    ];

class AppTheme {
  AppTheme._();

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.brand,
      brightness: Brightness.light,
    ).copyWith(
      primary: AppColors.brand,
      surface: AppColors.surface,
      onSurface: AppColors.ink,
    );

    final base = ThemeData(useMaterial3: true, colorScheme: scheme);

    final textTheme = GoogleFonts.plusJakartaSansTextTheme(base.textTheme).apply(
      bodyColor: AppColors.ink,
      displayColor: AppColors.ink,
    );

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.bg,
      textTheme: textTheme,
      splashFactory: InkSparkle.splashFactory,
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
      ),
      dividerTheme: const DividerThemeData(color: AppColors.line, thickness: 1, space: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.fieldFill,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        hintStyle: const TextStyle(color: AppColors.inkFaint, fontWeight: FontWeight.w500),
        prefixIconColor: AppColors.brand,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
          borderSide: const BorderSide(color: AppColors.brand, width: 1.8),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
          borderSide: const BorderSide(color: Color(0xFFE0573E)),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
          borderSide: const BorderSide(color: Color(0xFFE0573E), width: 1.8),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.brand,
          foregroundColor: Colors.white,
          textStyle: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.field)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.ink,
        contentTextStyle: const TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}
