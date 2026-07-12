import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/auth_gate.dart';
import 'services/app_router.dart';
import 'services/notification_service.dart';
import 'services/theme_controller.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
  ));
  // Restore the saved light/dark preference before the first frame.
  await ThemeController.instance.load();
  // Initialize the notification plugin + timezones (no permission prompt yet —
  // that happens when the user opts into reminders).
  await NotificationService.instance.init();
  // Route notification taps that arrive while the app is running.
  NotificationService.instance.onTap = routeFromNotification;

  runApp(const DietPlannerApp());

  // If a notification tap cold-started the app, jump straight to that meal
  // once the first frame (and the navigator) is ready.
  final launchPayload = await NotificationService.instance.initialLaunchPayload();
  if (launchPayload != null && launchPayload.isNotEmpty) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      routeFromNotification(launchPayload);
    });
  }
}

class DietPlannerApp extends StatelessWidget {
  const DietPlannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Rebuild the whole app when the light/dark preference changes, keeping
    // AppColors.brightness in lockstep with the ThemeData.
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) {
        AppColors.brightness = ThemeController.instance.brightness;
        // Status-bar icons follow the mode (light icons on the dark canvas).
        final dark = AppColors.brightness == Brightness.dark;
        SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        ));
        return MaterialApp(
          title: 'DietME',
          debugShowCheckedModeBanner: false,
          navigatorKey: appNavigatorKey,
          theme: AppTheme.build(AppColors.brightness),
          home: const AuthGate(),
        );
      },
    );
  }
}
