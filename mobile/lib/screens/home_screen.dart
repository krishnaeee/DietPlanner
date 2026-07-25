import 'package:flutter/material.dart';

import '../models/billing.dart';
import '../services/billing_service.dart';
import '../services/notification_service.dart';
import '../services/plan_storage.dart';
import '../services/tracking_storage.dart';
import '../theme/app_theme.dart';
import '../widgets/fresh.dart';
import 'add_plan_screen.dart';
import 'paywall_screen.dart';
import 'plan_hub.dart';
import 'settings_screen.dart';

/// The home: a list of the account's saved plans plus an "add" button that opens
/// the plan-generation flow. Plan generation itself lives in [AddPlanScreen].
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<StoredPlan> _plans = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _initForUser();
    // Reload whenever storage changes — including a plan saved in the background
    // after its creating screen was popped. Reactive, so it can't miss a write.
    PlanStorage.revision.addListener(_onStorageChanged);
  }

  @override
  void dispose() {
    PlanStorage.revision.removeListener(_onStorageChanged);
    super.dispose();
  }

  void _onStorageChanged() {
    if (mounted) _reload();
  }

  /// On (re)entering the home for a logged-in account: load that account's plans
  /// and re-sync reminders to them (clearing any previous user's).
  Future<void> _initForUser() async {
    final list = await PlanStorage.loadAll();
    if (!mounted) return;
    setState(() {
      _plans = list;
      _loading = false;
    });
    await NotificationService.instance.rescheduleAll(list);
    BillingService.instance.refresh(); // load credit balance for the header chip
  }

  Future<void> _reload() async {
    final list = await PlanStorage.loadAll();
    if (mounted) setState(() => _plans = list);
  }

  void _openPaywall() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PaywallScreen()),
    );
  }

  /// Opens the plan-generation form. The list refreshes via [didPopNext] when
  /// the user returns — the form uses pushReplacement to the plan, so a
  /// `.then()` here would fire too early (before the plan is saved).
  void _addPlan() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const AddPlanScreen()));
  }

  void _openPlan(StoredPlan p) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlanHub(stored: p),
    ));
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  Future<void> _renamePlan(StoredPlan p) async {
    final ctrl = TextEditingController(text: p.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename plan'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'e.g. Wife'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name != null && name.isNotEmpty) {
      await PlanStorage.rename(p.id, name);
      _reload();
    }
  }

  Future<void> _deletePlan(StoredPlan p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete plan?'),
        content: Text('Delete "${p.name}" and its reminders? This can\'t be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await PlanStorage.delete(p.id);
    await TrackingStorage.remove(p.id); // drop this plan's tracking data too
    // Rebuild reminders for the remaining plans (drops the deleted one's).
    final all = await PlanStorage.loadAll();
    final counts = await NotificationService.instance.rescheduleAll(all);
    for (final q in all) {
      final c = counts[q.id] ?? 0;
      if (q.scheduledCount != c) await PlanStorage.upsert(q.copyWith(scheduledCount: c));
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          FreshHeader(
            title: 'Plans',
            subtitle: _plans.isEmpty
                ? null
                : '${_plans.length} plan${_plans.length == 1 ? '' : 's'} on track',
            actions: [
              _CreditChip(onTap: _openPaywall),
              HeaderCircleButton(
                  icon: Icons.person_rounded,
                  tooltip: 'Profile & settings',
                  onTap: _openSettings),
            ],
          ),
          Expanded(
            child: _loading
                ? Center(
                    child: reduceMotion(context)
                        ? Text('Loading…',
                            style: TextStyle(color: AppColors.inkMuted))
                        : const CircularProgressIndicator())
                : _plans.isEmpty
                    ? _EmptyState(onAdd: _addPlan)
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                        children: [
                          ..._plans.map((p) => Padding(
                                padding: const EdgeInsets.only(bottom: 13),
                                child: _PlanCard(
                                  plan: p,
                                  onOpen: () => _openPlan(p),
                                  onRename: () => _renamePlan(p),
                                  onDelete: () => _deletePlan(p),
                                ),
                              )),
                        ],
                      ),
          ),
        ],
      ),
      floatingActionButton: _plans.isEmpty
          ? null // the empty state has its own prominent CTA
          : DecoratedBox(
              decoration: BoxDecoration(
                gradient: AppColors.ctaGradient,
                borderRadius: BorderRadius.circular(99),
                boxShadow: coralGlow(),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(99),
                  onTap: _addPlan,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add_rounded, color: Colors.white, size: 20),
                        SizedBox(width: 6),
                        Text('New plan',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 14)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// Shown when the account has no plans yet.
class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: AppColors.brand.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.restaurant_menu_rounded,
                  color: AppColors.brand, size: 44),
            ),
            const SizedBox(height: 22),
            Text('No plans yet',
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Text(
              'Create your first AI diet plan — a day-by-day menu built from food '
              'local to you.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: AppColors.inkMuted, height: 1.4),
            ),
            const SizedBox(height: 26),
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: 'Create your first plan',
                icon: Icons.auto_awesome_rounded,
                onPressed: onAdd,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A glass balance pill in the header: "✦ 3" credits or "∞" when unlimited.
class _CreditChip extends StatelessWidget {
  final VoidCallback onTap;
  const _CreditChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Entitlements>(
      valueListenable: BillingService.instance.entitlements,
      builder: (context, ent, _) {
        final unlimited = ent.subscriptionActive;
        return Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Ink(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(color: AppColors.line),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      unlimited ? Icons.all_inclusive_rounded : Icons.stars_rounded,
                      color: AppColors.brand,
                      size: 16,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      unlimited ? 'Unlimited' : '${ent.credits}',
                      style: TextStyle(
                        color: AppColors.ink,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A Nocturne plan cover card: glass with a coloured aurora orb, the goal tag,
/// journey progress, and the plan's meta. Tap to open, ⋮ to rename/delete.
class _PlanCard extends StatelessWidget {
  final StoredPlan plan;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  const _PlanCard({
    required this.plan,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
  });

  static const _orbs = AppColors.orbPalette;

  ({String label, Color color}) _goal() {
    final g = plan.request?['goal'];
    final orb = _orbs[plan.slot % _orbs.length];
    if (g == 'lose') {
      final s = plan.startWeightKg, t = plan.targetWeightKg;
      final d = (s != null && t != null) ? ' −${(s - t).round()} KG' : '';
      return (label: 'LOSE$d', color: orb);
    }
    if (g == 'gain') return (label: 'GAIN', color: orb);
    if (g == 'maintain') return (label: 'EAT HEALTHY', color: orb);
    // Older plans: infer from the stored weights.
    final s = plan.startWeightKg, t = plan.targetWeightKg;
    if (s != null && t != null && t < s) {
      return (label: 'LOSE −${(s - t).round()} KG', color: orb);
    }
    if (s != null && t != null && t > s) return (label: 'GAIN', color: orb);
    return (label: 'PLAN', color: orb);
  }

  /// A Nocturne menu row: small icon + weighty label.
  PopupMenuItem<String> _menuItem(String value, IconData icon, String label,
      {Color? color}) {
    return PopupMenuItem<String>(
      value: value,
      height: 48,
      child: Row(
        children: [
          Icon(icon, size: 17, color: color ?? AppColors.inkMuted),
          const SizedBox(width: 10),
          Text(label,
              style: TextStyle(
                  color: color ?? AppColors.ink,
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5)),
        ],
      ),
    );
  }

  /// 1-based journey day, clamped to the plan window; 0 while upcoming.
  int _elapsedDay() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final s = DateTime(
        plan.startDate.year, plan.startDate.month, plan.startDate.day);
    final since = today.difference(s).inDays;
    if (since < 0) return 0;
    return (since + 1).clamp(1, plan.plan.days.length);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final goal = _goal();
    final total = plan.plan.days.length;
    final day = _elapsedDay();
    final pct = total <= 0 ? 0.0 : (day / total).clamp(0.0, 1.0);
    final loc = plan.location.trim();

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AppColors.line),
          ),
          child: Stack(
            children: [
              // The aurora orb, softly glowing from the top-right corner.
              Positioned(
                right: -34,
                top: -46,
                child: Container(
                  width: 130,
                  height: 130,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: goal.color.withValues(
                        alpha: AppColors.brightness == Brightness.dark ? 0.14 : 0.09),
                    boxShadow: [
                      BoxShadow(
                        color: goal.color.withValues(
                            alpha: AppColors.brightness == Brightness.dark
                                ? 0.22
                                : 0.14),
                        blurRadius: 36,
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 15),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(plan.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w900)),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: goal.color.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(30),
                          ),
                          child: Text(goal.label,
                              style: text.labelSmall?.copyWith(
                                  color: goal.color,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.6,
                                  fontSize: 8.5)),
                        ),
                        PopupMenuButton<String>(
                          padding: EdgeInsets.zero,
                          icon: Icon(Icons.more_vert_rounded,
                              size: 19, color: AppColors.inkFaint),
                          onSelected: (v) {
                            if (v == 'open') onOpen();
                            if (v == 'rename') onRename();
                            if (v == 'delete') onDelete();
                          },
                          itemBuilder: (_) => [
                            _menuItem('open', Icons.north_east_rounded, 'Open'),
                            _menuItem('rename', Icons.edit_rounded, 'Rename'),
                            _menuItem('delete', Icons.delete_outline_rounded,
                                'Delete',
                                color: AppColors.brandDark),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    RichText(
                      text: TextSpan(
                        style: text.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.8,
                            color: AppColors.ink),
                        children: [
                          TextSpan(text: day == 0 ? 'Starts soon' : 'Day $day'),
                          if (day > 0)
                            TextSpan(
                              text: '  of $total',
                              style: text.bodySmall?.copyWith(
                                  color: AppColors.inkMuted,
                                  fontWeight: FontWeight.w700),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 9),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: pct,
                          minHeight: 4,
                          backgroundColor: AppColors.surfaceHigh,
                          valueColor: AlwaysStoppedAnimation(goal.color),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        if (loc.isNotEmpty) ...[
                          Icon(Icons.place_rounded,
                              size: 12, color: AppColors.inkMuted),
                          const SizedBox(width: 3),
                        ],
                        Expanded(
                          child: Text(
                            loc.isEmpty ? '$total-day plan' : loc,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(
                                color: AppColors.inkMuted, fontSize: 11),
                          ),
                        ),
                        if (plan.remindersScheduled)
                          ValueListenableBuilder<bool>(
                            valueListenable:
                                NotificationService.instance.remindersEnabled,
                            builder: (context, masterOn, _) => masterOn
                                ? Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: Icon(Icons.notifications_active_rounded,
                                        size: 13, color: AppColors.brand),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            '${plan.plan.dailyCalorieTarget} kcal/day',
                            style: text.bodySmall?.copyWith(
                                color: AppColors.inkMuted,
                                fontWeight: FontWeight.w700,
                                fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
