import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/notification_service.dart';
import '../services/theme_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// App-level settings, opened from the home header's app icon: appearance
/// (light/dark), account, and about. (Per-plan reminder settings live in
/// DietSettingsScreen, opened from a plan.)
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final email = AuthService.instance.email ?? '';

    return Scaffold(
      body: Column(
        children: [
          const GradientHeader(
            title: 'Settings',
            subtitle: 'Appearance & account',
            showBack: true,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
              children: [
                SectionCard(
                  title: 'Appearance',
                  icon: Icons.palette_outlined,
                  child: AnimatedBuilder(
                    animation: ThemeController.instance,
                    builder: (context, _) {
                      final dark = ThemeController.instance.isDark;
                      return SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: dark,
                        onChanged: (v) => ThemeController.instance.setDark(v),
                        activeThumbColor: AppColors.brand,
                        secondary: Icon(
                          dark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                          color: AppColors.brand,
                        ),
                        title: Text('Dark mode',
                            style: text.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        subtitle: Text(
                          dark ? 'Dark theme is on' : 'Light theme is on',
                          style:
                              text.bodySmall?.copyWith(color: AppColors.inkMuted),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
                SectionCard(
                  title: 'Reminders',
                  icon: Icons.notifications_active_outlined,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: NotificationService.instance.remindersEnabled,
                    builder: (context, on, _) => SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: on,
                      onChanged: (v) =>
                          NotificationService.instance.setRemindersEnabled(v),
                      activeThumbColor: AppColors.brand,
                      secondary: Icon(
                        on
                            ? Icons.notifications_active_rounded
                            : Icons.notifications_off_rounded,
                        color: AppColors.brand,
                      ),
                      title: Text('Meal & grocery reminders',
                          style:
                              text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                      subtitle: Text(
                        on
                            ? 'On for all plans (each plan can still set its own)'
                            : 'Off — no plan will send meal or grocery alarms',
                        style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SectionCard(
                  title: 'Account',
                  icon: Icons.person_outline_rounded,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (email.isNotEmpty) ...[
                        Row(
                          children: [
                            Icon(Icons.email_outlined,
                                size: 18, color: AppColors.inkMuted),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(email,
                                  style: text.bodyMedium?.copyWith(
                                      color: AppColors.ink,
                                      fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                      ],
                      OutlinedButton.icon(
                        onPressed: () => _logout(context),
                        icon: const Icon(Icons.logout_rounded, size: 18),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFE0573E),
                          side: const BorderSide(color: Color(0xFFE0573E)),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(AppRadius.field)),
                        ),
                        label: const Text('Log out'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SectionCard(
                  title: 'About',
                  icon: Icons.info_outline_rounded,
                  child: Text(
                    'AI Diet Planner — location-aware, AI-generated meal plans '
                    'with macros, grocery lists, and reminders.',
                    style: text.bodySmall
                        ?.copyWith(color: AppColors.inkMuted, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _logout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('You can sign back in anytime.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Log out')),
        ],
      ),
    );
    if (ok != true) return;
    await NotificationService.instance.cancelAll();
    await AuthService.instance.logout();
    if (context.mounted) {
      // Pop back to the auth gate, which now shows the login screen.
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }
}
