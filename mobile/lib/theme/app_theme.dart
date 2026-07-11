import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Central design system — the "Nocturne" language: OLED-black glass surfaces
/// in dark (the identity), a cool near-white twin in light, one coral→violet
/// gradient accent system, heavy geometric type, hairline borders.
///
/// Every screen reads from here so the look stays cohesive across modes.
class AppColors {
  AppColors._();

  /// The active brightness. Set by the root before the theme is built; the
  /// neutral getters below resolve against it so the theme toggle restyles
  /// every screen at once. Accents stay fixed across both modes.
  static Brightness brightness = Brightness.dark;
  static bool get _dark => brightness == Brightness.dark;

  // ── Accents (same in both modes; chosen to read on white and black) ──
  /// Coral — the primary accent ("brand" name kept so call sites don't churn).
  static const brand = Color(0xFFFF5D6D);
  static const brandDark = Color(0xFFE0485F);
  static const brandDeep = Color(0xFFB23A4E);

  /// Energy accent (calories / highlights) — warm amber.
  static const accent = Color(0xFFF2A93B);

  /// Secondary accent — violet (targets, fat macro).
  static const violet = Color(0xFF8B7CFF);

  // Meal-type accents (medium strength: legible on both grounds).
  static const breakfast = Color(0xFFF2A040);
  static const lunch = Color(0xFF2BB673);
  static const dinner = Color(0xFF8B7CFF);
  static const snack = Color(0xFFFF5E8A);

  // ── Macro accents — flip with brightness for contrast ──
  static Color get proteinAccent =>
      _dark ? const Color(0xFF4ADE9C) : const Color(0xFF18B876);
  static Color get carbsAccent =>
      _dark ? const Color(0xFFFFB46B) : const Color(0xFFD98A1F);
  static Color get fatAccent =>
      _dark ? const Color(0xFFB3A9FF) : const Color(0xFF6E5DE6);

  // ── Neutrals — flip with [brightness] ──
  static Color get bg => _dark ? const Color(0xFF0B0D12) : const Color(0xFFF5F6FA);
  static Color get surface => _dark ? const Color(0xFF14171F) : Colors.white;
  static Color get surfaceHigh =>
      _dark ? const Color(0xFF1C2029) : const Color(0xFFF0F1F6);
  static Color get ink => _dark ? const Color(0xFFECEEF2) : const Color(0xFF15171D);
  static Color get inkMuted =>
      _dark ? const Color(0xFF8B93A1) : const Color(0xFF6A7079);
  static Color get inkFaint =>
      _dark ? const Color(0xFF5D6572) : const Color(0xFFA3A9B6);
  static Color get line => _dark ? const Color(0xFF232833) : const Color(0xFFE6E8EF);
  static Color get fieldFill =>
      _dark ? const Color(0xFF1A1E27) : const Color(0xFFF0F1F6);

  /// The signature coral gradient — CTAs, progress fills, the auth header.
  static const ctaGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFFFF7A59), Color(0xFFFF4D6D)],
  );

  /// Full accent sweep (ring arcs, selection borders): coral → violet.
  static const auroraGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFF7A59), Color(0xFFFF4D6D), Color(0xFF8B7CFF)],
  );

  /// Kept for the auth screens' branded header — same coral in both modes.
  static LinearGradient get brandGradient => ctaGradient;

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
  static const card = 20.0; // glass cards
  static const field = 16.0;
  static const chip = 30.0;
  static const pill = 40.0;
}

/// A soft, low-contrast elevation. On dark it barely registers (glass cards
/// lean on hairline borders); on light it's a cool, faint drop.
List<BoxShadow> softShadow({double opacity = 0.06, double blur = 24, double y = 12}) {
  final dark = AppColors.brightness == Brightness.dark;
  final color = dark ? Colors.black : const Color(0xFF171A26);
  final a = dark ? (opacity * 0.5).clamp(0.0, 0.25) : opacity;
  return [
    BoxShadow(color: color.withValues(alpha: a), blurRadius: blur, offset: Offset(0, y)),
  ];
}

/// The coral glow used under gradient CTAs and the ring.
List<BoxShadow> coralGlow({double opacity = 0.35, double blur = 24, double y = 8}) {
  return [
    BoxShadow(
      color: const Color(0xFFFF4D6D).withValues(alpha: opacity),
      blurRadius: blur,
      offset: Offset(0, y),
    ),
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

    // Manrope — the heavy geometric voice of Nocturne.
    final textTheme = GoogleFonts.manropeTextTheme(base.textTheme).apply(
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
