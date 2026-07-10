import 'package:flutter/material.dart';

import '../services/active_plan.dart';
import '../services/plan_storage.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';
import 'progress_screen.dart';
import 'settings_screen.dart';
import 'today_screen.dart';

/// The app shell: a persistent bottom tab bar hosting Today, Plans, Progress and
/// Profile. Replaces the old push-into-a-list navigation.
class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _index = 0;
  StoredPlan? _active; // newest plan, for the Progress tab

  @override
  void initState() {
    super.initState();
    _loadActive();
    PlanStorage.revision.addListener(_loadActive);
    ActivePlan.id.addListener(_loadActive);
  }

  @override
  void dispose() {
    PlanStorage.revision.removeListener(_loadActive);
    ActivePlan.id.removeListener(_loadActive);
    super.dispose();
  }

  Future<void> _loadActive() async {
    final all = await PlanStorage.loadAll();
    if (!mounted) return;
    setState(() => _active = ActivePlan.resolve(all));
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      const TodayScreen(),
      const HomeScreen(), // "Plans" list
      _active == null
          ? const _NeedsPlan(label: 'Create a plan to track your progress.')
          : ProgressScreen(
              key: ValueKey('progress-${_active!.id}'),
              stored: _active!,
              embedded: true,
            ),
      const SettingsScreen(embedded: true),
    ];

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: IndexedStack(index: _index, children: tabs),
      bottomNavigationBar: _TabBar(
        index: _index,
        onTap: (i) => setState(() => _index = i),
      ),
    );
  }
}

class _NeedsPlan extends StatelessWidget {
  final String label;
  const _NeedsPlan({required this.label});
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.insights_rounded,
                  size: 48, color: AppColors.brand.withValues(alpha: 0.6)),
              const SizedBox(height: 14),
              Text(label,
                  textAlign: TextAlign.center,
                  style: text.bodyLarge?.copyWith(color: AppColors.inkMuted)),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;
  const _TabBar({required this.index, required this.onTap});

  static const _items = [
    (icon: Icons.today_rounded, label: 'Today'),
    (icon: Icons.restaurant_menu_rounded, label: 'Plans'),
    (icon: Icons.insights_rounded, label: 'Progress'),
    (icon: Icons.person_rounded, label: 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.line)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF13351F).withValues(alpha: 0.05),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Row(
            children: [
              for (var i = 0; i < _items.length; i++)
                Expanded(
                  child: _TabItem(
                    icon: _items[i].icon,
                    label: _items[i].label,
                    selected: i == index,
                    onTap: () => onTap(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TabItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.brand : AppColors.inkFaint;
    return InkResponse(
      onTap: onTap,
      radius: 40,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.brand.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(icon, color: color, size: 23),
          ),
          const SizedBox(height: 3),
          Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: 10.5,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600)),
        ],
      ),
    );
  }
}
