import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Central design system: colors, radii, spacing, shadows, and the ThemeData
/// that ties them together. Every screen reads from here so the look stays
/// cohesive.
///
/// Visual language: dark, minimal, "UNIX"-style — near-black charcoal canvas,
/// slightly lighter cards with large radii, thin type, big light-weight
/// numbers, restrained accents, subtle hairline borders instead of shadows.
class AppColors {
  AppColors._();

  /// The active brightness. Set by the root before the theme is built; the
  /// neutral getters below resolve against it so a light/dark toggle restyles
  /// every screen at once. Accents stay fixed across both modes.
  static Brightness brightness = Brightness.dark;
  static bool get _dark => brightness == Brightness.dark;

  // Accents — same in both modes; chosen to read on white and near-black.
  static const brand = Color(0xFF20B26E); // health green
  static const brandDark = Color(0xFF1B8F58);
  static const brandDeep = Color(0xFF14603F);

  // Energy accent (calories / highlights).
  static const accent = Color(0xFFEF9B23);

  // Meal-type accents.
  static const breakfast = Color(0xFFEF9B23);
  static const lunch = Color(0xFF20B26E);
  static const dinner = Color(0xFF5B7CFF);
  static const snack = Color(0xFFB57BEA);

  // Neutrals — flip with [brightness].
  static Color get bg => _dark ? const Color(0xFF0E1116) : const Color(0xFFF2F6F2);
  static Color get surface => _dark ? const Color(0xFF171C23) : Colors.white;
  static Color get surfaceHigh =>
      _dark ? const Color(0xFF1F2630) : const Color(0xFFEEF3EE);
  static Color get ink => _dark ? const Color(0xFFECEEF2) : const Color(0xFF17241D);
  static Color get inkMuted =>
      _dark ? const Color(0xFF8B95A1) : const Color(0xFF6B7C72);
  static Color get inkFaint =>
      _dark ? const Color(0xFF5A626E) : const Color(0xFF9AA9A0);
  static Color get line => _dark ? const Color(0xFF272E38) : const Color(0xFFE4EDE6);
  static Color get fieldFill =>
      _dark ? const Color(0xFF1C222B) : const Color(0xFFF6FAF6);

  // Header/canvas gradient — quiet charcoal in dark, brand green in light.
  static LinearGradient get brandGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: _dark
            ? const [Color(0xFF20262F), Color(0xFF0E1116)]
            : const [Color(0xFF27B277), Color(0xFF0F7A49)],
      );

  // Primary-action (CTA) gradient — the green, for buttons only.
  static const ctaGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF2FC183), Color(0xFF1B8F58)],
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
  static const card = 28.0; // large, UNIX-style
  static const field = 16.0;
  static const chip = 30.0;
  static const pill = 40.0;
}

/// A soft, low-contrast elevation. Tinted and faint in light mode; on dark it
/// barely registers (dark cards lean on hairline borders instead), so a heavy
/// black drop shadow never leaks through when the theme flips.
List<BoxShadow> softShadow({double opacity = 0.06, double blur = 24, double y = 12}) {
  final dark = AppColors.brightness == Brightness.dark;
  final color = dark ? Colors.black : const Color(0xFF13351F);
  final a = dark ? (opacity * 0.5).clamp(0.0, 0.25) : opacity;
  return [
    BoxShadow(color: color.withValues(alpha: a), blurRadius: blur, offset: Offset(0, y)),
  ];
}

class AppTheme {
  AppTheme._();

  /// Builds the theme for [brightness]. The caller must set
  /// [AppColors.brightness] to the same value first, so custom widgets that read
  /// AppColors stay in sync with Material components.
  static ThemeData build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.brand,
      brightness: brightness,
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
      dividerTheme: DividerThemeData(color: AppColors.line, thickness: 1, space: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.fieldFill,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        hintStyle: TextStyle(color: AppColors.inkFaint, fontWeight: FontWeight.w500),
        prefixIconColor: AppColors.brand,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
          borderSide: BorderSide(color: AppColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
          borderSide: BorderSide(color: AppColors.line),
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
          textStyle: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.field)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: AppColors.brand),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        dragHandleColor: AppColors.line,
      ),
      dialogTheme: DialogThemeData(backgroundColor: AppColors.surface),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.surfaceHigh,
        contentTextStyle: TextStyle(color: AppColors.ink),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}
