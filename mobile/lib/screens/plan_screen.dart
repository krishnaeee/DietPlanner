import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/diet_plan.dart';
import '../services/api_service.dart';
import '../services/notification_service.dart';
import '../services/plan_storage.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

class PlanScreen extends StatefulWidget {
  /// Generate a new plan from [requestBody] (named [planName]), or open a saved
  /// one by passing [stored] (no API call).
  final Map<String, dynamic>? requestBody;
  final String location;
  final String planName;
  final StoredPlan? stored;

  /// Deep-link target (from a tapped notification): open at this day index and
  /// briefly highlight this meal index.
  final int? initialDay;
  final int? highlightMeal;

  const PlanScreen({
    super.key,
    this.requestBody,
    this.location = '',
    this.planName = '',
    this.stored,
    this.initialDay,
    this.highlightMeal,
  });

  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends State<PlanScreen> {
  late Future<DietPlan> _future;
  StoredPlan? _current; // the saved record for the displayed plan

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<DietPlan> _load() async {
    if (widget.stored != null) {
      _current = widget.stored;
      return widget.stored!.plan;
    }
    final plan = await ApiService.generatePlan(widget.requestBody!);
    final all = await PlanStorage.loadAll();
    final sp = StoredPlan(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: widget.planName.trim().isEmpty
          ? 'Plan ${all.length + 1}'
          : widget.planName.trim(),
      slot: PlanStorage.nextSlot(all),
      plan: plan,
      location: widget.location,
      startDate: _defaultStart(),
      remindersScheduled: false,
      scheduledCount: 0,
      savedAt: DateTime.now(),
    );
    await PlanStorage.upsert(sp); // new plans are added, not overwritten
    _current = sp;
    return plan;
  }

  void _retry() {
    setState(() => _future = _load());
  }

  static DateTime _defaultStart() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day + 1); // tomorrow
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<DietPlan>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return Column(
              children: [
                const GradientHeader(
                  title: 'Building your plan',
                  subtitle: 'Our nutrition AI is putting together your week.',
                  showBack: true,
                ),
                Expanded(child: _CookingLoader(location: widget.location)),
              ],
            );
          }
          if (snap.hasError) {
            return Column(
              children: [
                const GradientHeader(title: 'Your diet plan', showBack: true),
                Expanded(
                  child: _ErrorView(message: snap.error.toString(), onRetry: _retry),
                ),
              ],
            );
          }
          return _PlanView(
            plan: snap.data!,
            location: widget.location,
            stored: _current!,
            initialDay: widget.initialDay,
            highlightMeal: widget.highlightMeal,
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────── loading state ──

class _CookingLoader extends StatefulWidget {
  final String location;
  const _CookingLoader({required this.location});

  @override
  State<_CookingLoader> createState() => _CookingLoaderState();
}

class _CookingLoaderState extends State<_CookingLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotate =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1300))
        ..repeat();
  Timer? _timer;
  int _tip = 0;

  late final List<String> _tips = [
    'Calculating your daily calories…',
    widget.location.trim().isEmpty
        ? 'Finding dishes local to you…'
        : 'Finding local dishes in ${widget.location.trim()}…',
    'Balancing protein, carbs & fat…',
    'Building your day-by-day menu…',
    'Listing ingredients for each meal…',
  ];

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 2400), (_) {
      if (mounted) setState(() => _tip = (_tip + 1) % _tips.length);
    });
  }

  @override
  void dispose() {
    _rotate.dispose();
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 132,
              height: 132,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  RotationTransition(
                    turns: _rotate,
                    child: CustomPaint(
                      size: const Size(132, 132),
                      painter: _RingPainter(),
                    ),
                  ),
                  Container(
                    width: 78,
                    height: 78,
                    decoration: BoxDecoration(
                      color: AppColors.brand.withValues(alpha: 0.10),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.local_dining_rounded,
                        color: AppColors.brand, size: 36),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            Text(
              'Cooking up your plan',
              style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              child: Text(
                _tips[_tip],
                key: ValueKey(_tip),
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'This usually takes 20–40 seconds.',
              style: text.bodySmall?.copyWith(color: AppColors.inkFaint),
            ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final center = Offset(r, r);
    final rect = Rect.fromCircle(center: center, radius: r - 6);

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..color = AppColors.line;
    canvas.drawCircle(center, r - 6, track);

    final shader = const SweepGradient(
      colors: [Color(0x0027B277), AppColors.brand, AppColors.brandDark],
      stops: [0.0, 0.65, 1.0],
    ).createShader(rect);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..shader = shader;
    canvas.drawArc(rect, -math.pi / 2, math.pi * 1.5, false, arc);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ───────────────────────────────────────────────────────────── error state ──

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: const Color(0xFFE0573E).withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.cloud_off_rounded,
                  color: Color(0xFFE0573E), size: 40),
            ),
            const SizedBox(height: 20),
            Text(
              'Couldn\'t build your plan',
              style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: AppColors.inkMuted, height: 1.4),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────── plan view ──

class _PlanView extends StatefulWidget {
  final DietPlan plan;
  final String location;
  final StoredPlan stored;
  final int? initialDay;
  final int? highlightMeal;
  const _PlanView({
    required this.plan,
    required this.location,
    required this.stored,
    this.initialDay,
    this.highlightMeal,
  });

  @override
  State<_PlanView> createState() => _PlanViewState();
}

class _PlanViewState extends State<_PlanView> {
  int _selected = 0;

  late StoredPlan _sp;
  bool _busy = false;

  final ScrollController _scroll = ScrollController();
  final GlobalKey _mealKey = GlobalKey();
  int? _highlight; // meal index to highlight (from a tapped notification)

  bool get _scheduled => _sp.remindersScheduled;
  int get _count => _sp.scheduledCount;
  DateTime get _start => _sp.startDate;

  @override
  void initState() {
    super.initState();
    _sp = widget.stored;
    final n = widget.plan.days.length;
    if (n > 0 && widget.initialDay != null) {
      _selected = widget.initialDay!.clamp(0, n - 1);
    }
    _highlight = widget.highlightMeal;
    if (_highlight != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealHighlighted());
    }
  }

  /// Scrolls the tapped meal into view, holds the highlight briefly, then clears.
  Future<void> _revealHighlighted() async {
    final ctx = _mealKey.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOut,
        alignment: 0.12,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 2600));
    if (mounted) setState(() => _highlight = null);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final text = Theme.of(context).textTheme;
    final days = plan.days;
    final sub = widget.location.trim().isEmpty
        ? '${plan.plannedDays}-day plan'
        : '${plan.plannedDays}-day plan · ${widget.location.trim()}';

    return Column(
      children: [
        GradientHeader(title: 'Your diet plan', subtitle: sub, showBack: true),
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
            children: [
              _SummaryCard(plan: plan),
              if (plan.truncated) ...[
                const SizedBox(height: 12),
                _InfoBanner(
                  text: 'Showing the first ${plan.plannedDays} of '
                      '${plan.requestedDays} days. Longer plans arrive in a later update.',
                ),
              ],
              if (days.isNotEmpty) ...[
                const SizedBox(height: 22),
                _DaySelector(
                  count: days.length,
                  selected: _selected,
                  onSelect: (i) => setState(() {
                    _selected = i;
                    _highlight = null; // switching days cancels the deep-link highlight
                  }),
                ),
                const SizedBox(height: 18),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween(begin: const Offset(0, 0.03), end: Offset.zero)
                          .animate(anim),
                      child: child,
                    ),
                  ),
                  child: _DayDetail(
                    key: ValueKey(_selected),
                    day: days[_selected.clamp(0, days.length - 1)],
                    highlightIndex: _highlight,
                    mealKey: _mealKey,
                  ),
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: Text(
                    'No daily meals were returned.',
                    textAlign: TextAlign.center,
                    style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
                  ),
                ),
            ],
          ),
        ),
        if (days.isNotEmpty) _reminderBar(),
      ],
    );
  }

  // ─────────────────────────────────────────────────────── reminder bar UI ──

  Widget _reminderBar() {
    final text = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF13351F).withValues(alpha: 0.06),
            blurRadius: 18,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: _busy
            ? const SizedBox(
                height: 52,
                child: Center(child: CircularProgressIndicator()),
              )
            : _scheduled
                ? Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: AppColors.brand.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.notifications_active_rounded,
                            color: AppColors.brand),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Reminders on',
                                style:
                                    text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                            Text('$_count set · Day 1 ${_fmtDate(_start)}',
                                style: text.bodySmall
                                    ?.copyWith(color: AppColors.inkMuted)),
                          ],
                        ),
                      ),
                      TextButton(onPressed: _turnOff, child: const Text('Turn off')),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _setupReminders,
                          icon: const Icon(Icons.notifications_active_rounded),
                          label: const Text('Set daily reminders'),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Grocery alert at 7 PM the day before + meal-time alarms',
                        textAlign: TextAlign.center,
                        style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                      ),
                    ],
                  ),
      ),
    );
  }

  Future<void> _setupReminders() async {
    final messenger = ScaffoldMessenger.of(context);
    final start = await _pickStart();
    if (start == null) return;

    setState(() => _busy = true);
    final allowed = await NotificationService.instance.requestPermissions();
    if (!allowed) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(const SnackBar(
        content: Text('Allow notifications for this app to receive reminders.'),
      ));
      return;
    }

    // Mark this plan active with the chosen start, then rebuild all reminders
    // (so other people's plans keep their reminders too).
    await PlanStorage.upsert(_sp.copyWith(remindersScheduled: true, startDate: start));
    var refreshed = await _rescheduleAndRefresh();
    if (refreshed.scheduledCount == 0) {
      // Nothing was in the future — flip it back off.
      refreshed = refreshed.copyWith(remindersScheduled: false);
      await PlanStorage.upsert(refreshed);
    }
    if (!mounted) return;
    setState(() {
      _sp = refreshed;
      _busy = false;
    });
    messenger.showSnackBar(SnackBar(
      content: Text(refreshed.scheduledCount > 0
          ? 'Reminders set — ${refreshed.scheduledCount} notifications. Day 1: ${_fmtDate(start)}.'
          : 'No upcoming times left to schedule — try starting tomorrow.'),
    ));
  }

  Future<void> _turnOff() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    await PlanStorage.upsert(_sp.copyWith(remindersScheduled: false));
    final refreshed = await _rescheduleAndRefresh();
    if (!mounted) return;
    setState(() {
      _sp = refreshed;
      _busy = false;
    });
    messenger.showSnackBar(const SnackBar(content: Text('Reminders turned off.')));
  }

  /// Reschedules notifications for every active plan and re-reads this plan's
  /// updated record (with its fresh scheduled count).
  Future<StoredPlan> _rescheduleAndRefresh() async {
    final all = await PlanStorage.loadAll();
    final counts = await NotificationService.instance.rescheduleAll(all);
    for (final p in all) {
      final c = counts[p.id] ?? 0;
      if (p.scheduledCount != c) {
        await PlanStorage.upsert(p.copyWith(scheduledCount: c));
      }
    }
    final fresh = await PlanStorage.loadAll();
    return fresh.firstWhere((e) => e.id == _sp.id, orElse: () => _sp);
  }

  Future<DateTime?> _pickStart() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    return showModalBottomSheet<DateTime>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('When does Day 1 start?',
                    style: Theme.of(ctx)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.event_rounded, color: AppColors.brand),
              title: const Text('Tomorrow'),
              subtitle: const Text('Grocery alert tonight at 7 PM, meals from tomorrow'),
              onTap: () => Navigator.pop(ctx, tomorrow),
            ),
            ListTile(
              leading: const Icon(Icons.today_rounded, color: AppColors.brand),
              title: const Text('Today'),
              subtitle: const Text("Meals from today (times already passed are skipped)"),
              onTap: () => Navigator.pop(ctx, today),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _fmtDate(DateTime d) {
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mo = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${wd[d.weekday - 1]}, ${d.day} ${mo[d.month - 1]}';
  }
}

class _SummaryCard extends StatelessWidget {
  final DietPlan plan;
  const _SummaryCard({required this.plan});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.local_fire_department_rounded,
                    color: AppColors.accent, size: 30),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Daily calorie target',
                        style: text.bodySmall?.copyWith(color: AppColors.inkMuted)),
                    const SizedBox(height: 2),
                    RichText(
                      text: TextSpan(
                        style: text.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: AppColors.ink,
                        ),
                        children: [
                          TextSpan(text: '${plan.dailyCalorieTarget}'),
                          TextSpan(
                            text: '  kcal',
                            style: text.titleSmall?.copyWith(
                              color: AppColors.inkMuted,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (plan.summary.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 16),
            Text(
              plan.summary,
              style: text.bodyMedium?.copyWith(height: 1.5, color: AppColors.ink),
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  final String text;
  const _InfoBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, color: AppColors.accent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.ink,
                    height: 1.4,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DaySelector extends StatelessWidget {
  final int count;
  final int selected;
  final ValueChanged<int> onSelect;
  const _DaySelector({
    required this.count,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: count,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final sel = i == selected;
          return GestureDetector(
            onTap: () => onSelect(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration: BoxDecoration(
                color: sel ? AppColors.brand : AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: sel ? AppColors.brand : AppColors.line),
                boxShadow: sel ? softShadow(opacity: 0.10, blur: 12, y: 6) : null,
              ),
              child: Text(
                'Day ${i + 1}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: sel ? Colors.white : AppColors.inkMuted,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DayDetail extends StatelessWidget {
  final DayPlan day;
  final int? highlightIndex;
  final Key? mealKey;
  const _DayDetail({super.key, required this.day, this.highlightIndex, this.mealKey});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Day ${day.day}',
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(30),
              ),
              child: Row(
                children: [
                  const Icon(Icons.local_fire_department_rounded,
                      color: AppColors.accent, size: 16),
                  const SizedBox(width: 4),
                  Text(
                    '${day.totalCalories} kcal',
                    style: text.labelLarge?.copyWith(
                      color: AppColors.accent,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        ...List.generate(day.meals.length, (m) {
          final hi = m == highlightIndex;
          return Padding(
            key: hi ? mealKey : null,
            padding: const EdgeInsets.only(bottom: 12),
            child: _MealCard(meal: day.meals[m], highlight: hi),
          );
        }),
      ],
    );
  }
}

class _MealCard extends StatelessWidget {
  final Meal meal;
  final bool highlight;
  const _MealCard({required this.meal, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = AppColors.forMeal(meal.name);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: highlight ? color.withValues(alpha: 0.06) : AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(
          color: highlight ? color : Colors.transparent,
          width: 2,
        ),
        boxShadow: softShadow(
          opacity: highlight ? 0.16 : 0.05,
          blur: highlight ? 26 : 18,
          y: 8,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(AppColors.iconForMeal(meal.name), color: color, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        meal.name.isEmpty ? 'Meal' : meal.name,
                        style: text.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: color,
                        ),
                      ),
                      if (meal.time.isNotEmpty)
                        Text(meal.time,
                            style: text.bodySmall?.copyWith(color: AppColors.inkMuted)),
                    ],
                  ),
                ),
                if (meal.calories > 0)
                  Text(
                    '${meal.calories} kcal',
                    style: text.labelLarge?.copyWith(
                      color: AppColors.inkMuted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              meal.dish,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (meal.description.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                meal.description,
                style: text.bodySmall?.copyWith(color: AppColors.inkMuted, height: 1.4),
              ),
            ],
            if (meal.ingredients.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                'INGREDIENTS',
                style: text.labelSmall?.copyWith(
                  color: AppColors.inkFaint,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: meal.ingredients.map((ing) {
                  final label = ing.quantity.isEmpty
                      ? ing.name
                      : '${ing.name} · ${ing.quantity}';
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: AppColors.fieldFill,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.line),
                    ),
                    child: Text(
                      label,
                      style: text.bodySmall?.copyWith(
                        color: AppColors.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
