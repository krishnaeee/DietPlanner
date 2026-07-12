import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/notification_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';
import 'login_screen.dart';

/// Decides the first screen: a brief splash while the saved session is checked,
/// then the home screen (logged in) or the login screen. Rebuilds reactively
/// when the user logs in or out.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await AuthService.instance.loadSession();
    await AuthService.instance.verify(); // clears the session on a definitive 401
    // Re-arm reminders for this account's plans: slides repeating plans' rolling
    // windows forward and restores anything lost to a reboot. Fire-and-forget so
    // it never blocks the first screen.
    NotificationService.instance.refreshAll();
    // Restore any plans/tracking that live on the server but not on this device
    // (fresh install / new phone). Fire-and-forget — restored plans surface via
    // PlanStorage.revision once they land; never blocks the first screen.
    SyncService.instance.pullAll();
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return Container(
        decoration: BoxDecoration(gradient: AppColors.brandGradient),
        alignment: Alignment.center,
        child: const Icon(Icons.eco_rounded, color: Colors.white, size: 56),
      );
    }
    return ValueListenableBuilder<bool>(
      valueListenable: AuthService.instance.authState,
      builder: (_, loggedIn, _) =>
          loggedIn ? const HomeScreen() : const LoginScreen(),
    );
  }
}
