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
import 'plan_screen.dart';

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
      builder: (_) => PlanScreen(stored: p, location: p.location),
    ));
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
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE0573E)),
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
            title: 'Your plans',
            subtitle: _plans.isEmpty
                ? null
                : '${_plans.length} plan${_plans.length == 1 ? '' : 's'}',
            actions: [_CreditChip(onTap: _openPaywall)],
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _plans.isEmpty
                    ? _EmptyState(onAdd: _addPlan)
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                        children: [
                          ..._plans.map((p) => Padding(
                                padding: const EdgeInsets.only(bottom: 10),
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
          : FloatingActionButton.extended(
              onPressed: _addPlan,
              icon: const Icon(Icons.add_rounded),
              label: const Text('New plan'),
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

/// The app-icon badge in the header. Doubles as the Settings entry point.
/// A tappable balance pill in the header: "3" credits or "∞" when unlimited.
/// Light Fresh styling (brand-tinted) to sit on the page ground.
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
          color: AppColors.brand.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.pill),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    unlimited ? Icons.all_inclusive_rounded : Icons.stars_rounded,
                    color: AppColors.brandDark,
                    size: 18,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    unlimited ? 'Unlimited' : '${ent.credits}',
                    style: const TextStyle(
                      color: AppColors.brandDark,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A saved-plan row: tap to open, ⋮ menu to rename/delete.
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

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final loc = plan.location.trim();
    final sub = loc.isEmpty
        ? '${plan.plan.plannedDays}-day plan'
        : '${plan.plan.plannedDays}-day plan · $loc';
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onOpen,
        child: Ink(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.line),
            boxShadow: softShadow(),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.brand.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.restaurant_menu_rounded, color: AppColors.brand),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(plan.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text(sub, style: text.bodySmall?.copyWith(color: AppColors.inkMuted)),
                      // Only advertise "Reminders on" when BOTH the plan's flag
                      // and the app-level master switch are on.
                      if (plan.remindersScheduled)
                        ValueListenableBuilder<bool>(
                          valueListenable:
                              NotificationService.instance.remindersEnabled,
                          builder: (context, masterOn, _) => masterOn
                              ? Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.notifications_active_rounded,
                                          size: 14, color: AppColors.brand),
                                      const SizedBox(width: 4),
                                      Text('Reminders on',
                                          style: text.labelSmall?.copyWith(
                                              color: AppColors.brand,
                                              fontWeight: FontWeight.w700)),
                                    ],
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert_rounded, color: AppColors.inkMuted),
                  onSelected: (v) {
                    if (v == 'open') onOpen();
                    if (v == 'rename') onRename();
                    if (v == 'delete') onDelete();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'open', child: Text('Open')),
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
