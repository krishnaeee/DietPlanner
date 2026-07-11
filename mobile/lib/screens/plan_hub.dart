import 'package:flutter/material.dart';

import '../services/plan_storage.dart';
import '../theme/app_theme.dart';
import 'plan_screen.dart';
import 'progress_screen.dart';
import 'today_screen.dart';

/// A single plan opened from the Plans list: its own floating dock for Today,
/// the day-by-day Plan, and Progress. Back (in any tab's header) returns to
/// the Plans list.
class PlanHub extends StatefulWidget {
  final StoredPlan stored;
  const PlanHub({super.key, required this.stored});

  @override
  State<PlanHub> createState() => _PlanHubState();
}

class _PlanHubState extends State<PlanHub> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final sp = widget.stored;
    return Scaffold(
      backgroundColor: AppColors.bg,
      extendBody: true, // content scrolls behind the floating dock
      body: IndexedStack(
        index: _index,
        children: [
          TodayScreen(plan: sp),
          PlanScreen(stored: sp, location: sp.location, embedded: true),
          ProgressScreen(stored: sp),
        ],
      ),
      bottomNavigationBar: _Dock(
        index: _index,
        onTap: (i) => setState(() => _index = i),
      ),
    );
  }
}

/// Nocturne's floating pill dock.
class _Dock extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;
  const _Dock({required this.index, required this.onTap});

  static const _items = [
    (icon: Icons.today_rounded, label: 'Today'),
    (icon: Icons.restaurant_menu_rounded, label: 'Plan'),
    (icon: Icons.insights_rounded, label: 'Progress'),
  ];

  @override
  Widget build(BuildContext context) {
    final dark = AppColors.brightness == Brightness.dark;
    return SafeArea(
      minimum: const EdgeInsets.only(bottom: 10),
      child: Center(
        heightFactor: 1,
        child: Container(
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: dark
                ? const Color(0xFF14171F).withValues(alpha: 0.94)
                : Colors.white.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: AppColors.line),
            boxShadow: [
              BoxShadow(
                color: (dark ? Colors.black : const Color(0xFF171A26))
                    .withValues(alpha: dark ? 0.28 : 0.09),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < _items.length; i++)
                _DockItem(
                  icon: _items[i].icon,
                  label: _items[i].label,
                  selected: i == index,
                  onTap: () => onTap(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DockItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _DockItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.ink : AppColors.inkFaint;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(99),
      child: SizedBox(
        width: 74,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 2),
              Text(label,
                  style: TextStyle(
                      color: color,
                      fontSize: 9,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600)),
              const SizedBox(height: 2),
              // Coral dot marks the active tab.
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: selected ? 4 : 0,
                height: 4,
                decoration: const BoxDecoration(
                    color: AppColors.brand, shape: BoxShape.circle),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
