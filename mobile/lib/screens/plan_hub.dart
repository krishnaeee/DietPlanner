import 'package:flutter/material.dart';

import '../services/plan_storage.dart';
import '../theme/app_theme.dart';
import 'plan_screen.dart';
import 'progress_screen.dart';
import 'today_screen.dart';

/// A single plan opened from the Plans list: its own bottom tabs for Today, the
/// day-by-day Plan, and Progress. Back (in any tab's header) returns to Plans.
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
      body: IndexedStack(
        index: _index,
        children: [
          TodayScreen(plan: sp),
          PlanScreen(stored: sp, location: sp.location, embedded: true),
          ProgressScreen(stored: sp),
        ],
      ),
      bottomNavigationBar: _HubNav(
        index: _index,
        onTap: (i) => setState(() => _index = i),
      ),
    );
  }
}

class _HubNav extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;
  const _HubNav({required this.index, required this.onTap});

  static const _items = [
    (icon: Icons.today_rounded, label: 'Today'),
    (icon: Icons.restaurant_menu_rounded, label: 'Plan'),
    (icon: Icons.insights_rounded, label: 'Progress'),
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
                  child: _HubTab(
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

class _HubTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _HubTab({
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
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 4),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.brand.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(icon, color: color, size: 20),
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
