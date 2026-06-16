import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/auth_gate.dart';
import 'services/app_router.dart';
import 'services/notification_service.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
  ));
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
    return MaterialApp(
      title: 'AI Diet Planner',
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      theme: AppTheme.light(),
      home: const AuthGate(),
    );
  }
}
