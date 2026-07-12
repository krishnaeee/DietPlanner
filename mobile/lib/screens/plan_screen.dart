import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/diet_plan.dart';
import '../models/tracking.dart';
import '../services/api_service.dart';
import '../services/billing_service.dart';
import '../services/notification_service.dart';
import '../services/plan_storage.dart';
import '../services/tracking_storage.dart';
import '../theme/app_theme.dart';
import '../widgets/fresh.dart';
import 'diet_settings_screen.dart';
import 'grocery_list_screen.dart';
import 'meal_detail_screen.dart';
import 'paywall_screen.dart';
import 'progress_screen.dart';

const _kWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

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

  /// When shown as a tab inside PlanHub, drop the redundant "Progress" header
  /// action (Progress is its own tab).
  final bool embedded;

  const PlanScreen({
    super.key,
    this.requestBody,
    this.location = '',
    this.planName = '',
    this.stored,
    this.initialDay,
    this.highlightMeal,
    this.embedded = false,
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
    final body = widget.requestBody!;
    double? metric(String k) {
      final v = body[k];
      return v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
    }

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
      startWeightKg: metric('weightKg'),
      targetWeightKg: metric('targetWeightKg'),
      request: Map<String, dynamic>.from(body), // kept so the plan can be extended
    );
    await PlanStorage.upsert(sp); // new plans are added, not overwritten
    _current = sp;
    return plan;
  }

  void _retry() {
    setState(() => _future = _load());
  }

  /// Opens the paywall; if the user buys (or has a balance on return), retries
  /// generation automatically.
  Future<void> _openPaywallThenRetry() async {
    final bought = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const PaywallScreen(
          reason: 'You need credits or an unlimited plan to generate this.',
        ),
      ),
    );
    if (!mounted) return;
    if (bought == true || BillingService.instance.entitlements.value.canGenerate) {
      _retry();
    }
  }

  static DateTime _defaultStart() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day); // today — so the Today tab = Day 1
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
                const FreshHeader(
                  title: 'Building your plan',
                  subtitle: 'Our nutrition AI is putting together your week.',
                  showBack: true,
                ),
                Expanded(child: _CookingLoader(location: widget.location)),
              ],
            );
          }
          if (snap.hasError) {
            // Out of credits → show a paywall prompt instead of a generic error.
            if (snap.error is PaymentRequiredException) {
              return Column(
                children: [
                  const FreshHeader(title: 'Your diet plan', showBack: true),
                  Expanded(
                    child: _PaywallPrompt(
                      message: (snap.error as PaymentRequiredException).message,
                      onOpen: _openPaywallThenRetry,
                    ),
                  ),
                ],
              );
            }
            return Column(
              children: [
                const FreshHeader(title: 'Your diet plan', showBack: true),
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
            embedded: widget.embedded,
            // Freshly generated (not opened from the saved list) → offer reminders.
            justGenerated: widget.requestBody != null,
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
                      shape: BoxShape.circle,
                      gradient: const RadialGradient(
                        center: Alignment(-0.35, -0.4),
                        colors: [Color(0xFFFFB46B), Color(0xFFFF5D6D)],
                      ),
                      boxShadow: coralGlow(opacity: 0.20, blur: 14, y: 5),
                    ),
                    child: const Icon(Icons.local_dining_rounded,
                        color: Colors.white, size: 34),
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
      colors: [Color(0x00FF7A59), Color(0xFFFF7A59), AppColors.brand],
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

// ──────────────────────────────────────────────────────── out-of-credits ──

class _PaywallPrompt extends StatelessWidget {
  final String message;
  final VoidCallback onOpen;
  const _PaywallPrompt({required this.message, required this.onOpen});

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
                color: AppColors.accent.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.lock_rounded, color: AppColors.accent, size: 40),
            ),
            const SizedBox(height: 20),
            Text(
              'Out of credits',
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
              onPressed: onOpen,
              icon: const Icon(Icons.workspace_premium_rounded),
              label: const Text('See plans & credits'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
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
  final bool justGenerated;
  final bool embedded;
  const _PlanView({
    required this.plan,
    required this.location,
    required this.stored,
    this.initialDay,
    this.highlightMeal,
    this.justGenerated = false,
    this.embedded = false,
  });

  @override
  State<_PlanView> createState() => _PlanViewState();
}

class _PlanViewState extends State<_PlanView> {
  int _selected = 0;

  late StoredPlan _sp;
  late DietPlan _plan; // grows as the user loads more weeks
  bool _extending = false; // a "load next week" generation is in flight
  int? _swapping; // meal index (on the selected day) currently being swapped
  PlanTracking _tracking = PlanTracking();

  final ScrollController _scroll = ScrollController();
  final GlobalKey _mealKey = GlobalKey();
  int? _highlight; // meal index to highlight (from a tapped notification)

  bool get _scheduled => _sp.remindersScheduled;
  DateTime get _start => _sp.startDate;

  /// Calendar date of a given day number (Day 1 == [_start]).
  DateTime _dateForDay(int dayNumber) {
    final s = DateTime(_start.year, _start.month, _start.day);
    return s.add(Duration(days: dayNumber - 1));
  }

  /// Index (0-based) of the day whose date is today, or null if today falls
  /// outside the plan's window.
  int? get _todayIndex {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final s = DateTime(_start.year, _start.month, _start.day);
    final diff = today.difference(s).inDays;
    if (diff < 0 || diff >= _plan.days.length) return null;
    return diff;
  }

  @override
  void initState() {
    super.initState();
    _sp = widget.stored;
    _plan = widget.plan;
    final n = _plan.days.length;
    if (n > 0) {
      if (widget.initialDay != null) {
        // Deep-linked from a tapped notification — honour that day.
        _selected = widget.initialDay!.clamp(0, n - 1);
      } else {
        // Opening the plan normally — land on today if it's within the plan.
        _selected = _todayIndex ?? 0;
      }
    }
    _highlight = widget.highlightMeal;
    if (_highlight != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealHighlighted());
    }
    _loadTracking();
    _maybeShowReminderPrompt();
  }

  Future<void> _loadTracking() async {
    final t = await TrackingStorage.load(_sp.id);
    if (mounted) setState(() => _tracking = t);
  }

  /// Right after a plan is generated, offer to set reminders via a centered
  /// dialog (only for freshly generated plans that don't already have them,
  /// and only when the app-level master switch is on).
  void _maybeShowReminderPrompt() {
    if (!widget.justGenerated || _scheduled) return;
    if (!NotificationService.instance.remindersEnabled.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final set = await showDialog<bool>(
        context: context,
        builder: (_) => const _ReminderPromptDialog(),
      );
      if (set == true && mounted) _enableAllReminders();
    });
  }

  /// One tap from the post-generation prompt: turns on meal + grocery reminders
  /// (with the repeat cycle) AND water reminders for this plan — no settings
  /// detour, no start-date question. Uses the plan's own start date (today for a
  /// fresh plan).
  Future<void> _enableAllReminders() async {
    final messenger = ScaffoldMessenger.of(context);
    final allowed = await NotificationService.instance.requestPermissions();
    if (!mounted) return;
    if (!allowed) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Allow notifications for this app to receive reminders.'),
      ));
      return;
    }
    // Meal/grocery reminders + repeat on the plan; water reminders in tracking.
    await PlanStorage.upsert(
        _sp.copyWith(remindersScheduled: true, repeatForever: true));
    final t = await TrackingStorage.load(_sp.id);
    final nextTracking = t.copyWith(waterRemindersOn: true);
    await TrackingStorage.save(_sp.id, nextTracking);

    final refreshed = await _rescheduleAndRefresh();
    if (!mounted) return;
    setState(() {
      _sp = refreshed;
      _tracking = nextTracking;
    });
    messenger.showSnackBar(const SnackBar(
      content: Text('All reminders on — meals, groceries, repeat & water.'),
    ));
  }

  Future<void> _toggleMeal(int dayIndex, int mealIndex) async {
    final next = _tracking.toggleMeal(dayIndex, mealIndex);
    setState(() => _tracking = next);
    await TrackingStorage.save(_sp.id, next);
  }

  /// Regenerates a single meal on the selected day (free on the backend), then
  /// replaces it in place and persists.
  Future<void> _swapMeal(int mealIndex) async {
    if (_swapping != null) return;
    final dayIndex = _selected;
    final day = _plan.days[dayIndex];
    if (mealIndex < 0 || mealIndex >= day.meals.length) return;
    final meal = day.meals[mealIndex];
    final messenger = ScaffoldMessenger.of(context);
    final req = _sp.request;
    final location =
        widget.location.trim().isNotEmpty ? widget.location.trim() : '${req?['location'] ?? ''}';

    final body = <String, dynamic>{
      'location': location,
      'mealName': meal.name,
      'time': meal.time,
      'targetCalories': meal.calories,
      'avoidDish': meal.dish,
      if (req?['dietaryPreference'] != null)
        'dietaryPreference': req!['dietaryPreference'],
    };

    setState(() => _swapping = mealIndex);
    try {
      final fresh = await ApiService.swapMeal(body);
      final merged = _plan.withReplacedMeal(dayIndex, mealIndex, fresh);
      await PlanStorage.upsert(_sp.copyWith(plan: merged));
      if (!mounted) return;
      setState(() {
        _plan = merged;
        _sp = _sp.copyWith(plan: merged);
        _swapping = null;
      });
      messenger.showSnackBar(SnackBar(
          content: Text(fresh.dish.isEmpty ? 'Meal swapped.' : 'Swapped to ${fresh.dish}.')));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _swapping = null);
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _swapping = null);
      messenger.showSnackBar(SnackBar(content: Text('Could not swap meal. $e')));
    }
  }

  void _openProgress() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ProgressScreen(stored: _sp)))
        .then((_) => _loadTracking()); // weight/water may have changed
  }

  void _openSettings() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => DietSettingsScreen(stored: _sp)))
        .then((_) => _reloadStored()); // reminder state may have changed
  }

  /// Opens the grocery list for the currently selected day (with a toggle there
  /// to expand to the whole upcoming week).
  void _openDayGrocery() {
    final days = _plan.days;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GroceryListScreen(
        plan: _plan,
        startIndex: _selected,
        windowDays: math.min(7, days.length - _selected),
        startInDayMode: true,
      ),
    ));
  }

  /// Re-reads this plan's stored record (e.g. after settings changed reminders)
  /// so later actions here don't clobber those changes with a stale copy.
  Future<void> _reloadStored() async {
    final all = await PlanStorage.loadAll();
    final fresh = all.firstWhere((e) => e.id == _sp.id, orElse: () => _sp);
    if (mounted) setState(() => _sp = fresh);
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

  /// Goal-ish subtitle: "Pollachi · vegetarian · 1,800 kcal/day".
  String get _subtitle {
    final parts = <String>[];
    if (widget.location.trim().isNotEmpty) parts.add(widget.location.trim());
    final pref = _sp.request?['dietaryPreference'];
    if (pref is String && pref.trim().isNotEmpty) parts.add(pref.trim());
    parts.add('${_plan.dailyCalorieTarget} kcal/day');
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final text = Theme.of(context).textTheme;
    final days = plan.days;
    final selected = days.isEmpty ? 0 : _selected.clamp(0, days.length - 1);

    // Journey: how far into the requested period today is.
    final elapsed = _todayIndex == null ? 0 : _todayIndex! + 1;
    final journeyPct = plan.requestedDays <= 0
        ? 0.0
        : (elapsed / plan.requestedDays).clamp(0.0, 1.0);

    return Stack(
      children: [
        Column(
          children: [
            FreshHeader(
              title: '${plan.requestedDays}-day plan',
              subtitle: _subtitle,
              showBack: true,
              actions: [
                if (!widget.embedded)
                  HeaderPill(
                    icon: Icons.insights_rounded,
                    label: 'Progress',
                    onTap: _openProgress,
                  ),
                HeaderCircleButton(
                  icon: Icons.tune_rounded,
                  tooltip: 'Diet settings',
                  onTap: _openSettings,
                ),
              ],
            ),
            // ── journey progress bar
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 0),
              child: Row(
                children: [
                  Text(elapsed == 0 ? 'STARTS SOON' : 'DAY $elapsed',
                      style: text.labelSmall?.copyWith(
                          color: AppColors.inkMuted,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                          fontSize: 9)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: SizedBox(
                        height: 4,
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: AppColors.surfaceHigh),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: journeyPct == 0 ? 0.001 : journeyPct,
                              heightFactor: 1, // fill the track's height
                              child: const DecoratedBox(
                                decoration:
                                    BoxDecoration(gradient: AppColors.ctaGradient),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('${(journeyPct * 100).round()}%',
                      style: text.labelSmall?.copyWith(
                          color: AppColors.inkMuted,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                          fontSize: 9)),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: _scroll,
                padding: EdgeInsets.fromLTRB(
                    18, 14, 18, widget.embedded ? 150 : 96),
                children: [
                  if (days.isNotEmpty) ...[
                    _DateStrip(
                      count: days.length,
                      selected: selected,
                      todayIndex: _todayIndex,
                      dateForDay: _dateForDay,
                      dayNumberAt: (i) => days[i].day,
                      onSelect: (i) => setState(() {
                        _selected = i;
                        _highlight = null; // switching days cancels the highlight
                      }),
                    ),
                    const SizedBox(height: 14),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 280),
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: SlideTransition(
                          position:
                              Tween(begin: const Offset(0, 0.03), end: Offset.zero)
                                  .animate(anim),
                          child: child,
                        ),
                      ),
                      child: Column(
                        key: ValueKey(selected),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _DayMacroChips(day: days[selected], plan: plan),
                          const SizedBox(height: 14),
                          ...List.generate(days[selected].meals.length, (m) {
                            final hi = m == _highlight;
                            return Padding(
                              key: hi ? _mealKey : null,
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _PlanMealRow(
                                meal: days[selected].meals[m],
                                highlight: hi,
                                done: _tracking.isMealDone(selected, m),
                                swapping: _swapping == m,
                                swapDisabled: _swapping != null,
                                onToggle: () => _toggleMeal(selected, m),
                                onSwap: () => _swapMeal(m),
                                onTap: () =>
                                    Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => MealDetailScreen(
                                      stored: _sp,
                                      dayIndex: selected,
                                      mealIndex: m),
                                )),
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    _extendSection(plan, text),
                    if (plan.summary.trim().isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _AboutPlan(summary: plan.summary.trim()),
                    ],
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
          ],
        ),
        // ── floating groceries pill (sits above the hub dock when embedded)
        if (days.isNotEmpty)
          Positioned(
            right: 16,
            bottom: widget.embedded ? 96 : 18,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: AppColors.ctaGradient,
                borderRadius: BorderRadius.circular(99),
                boxShadow: coralGlow(),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(99),
                  onTap: _openDayGrocery,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 15, vertical: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.shopping_cart_rounded,
                            color: Colors.white, size: 17),
                        SizedBox(width: 6),
                        Text('Groceries',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 12.5)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ──────────────────────────────────────────────── extend (load next week) ──

  /// Footer below the day list: a button to generate the next batch of days, or
  /// a "plan complete" note once the whole journey is built. Hidden for plans
  /// with no stored request (can't be extended) and for short plans that were
  /// never truncated.
  Widget _extendSection(DietPlan plan, TextTheme text) {
    final remaining = plan.requestedDays - plan.days.length;

    if (remaining <= 0) {
      // Nothing left to load. Show a done note only for multi-week journeys
      // (a short single-shot plan never needed extending).
      if (plan.requestedDays <= 7) return const SizedBox.shrink();
      final mint = MacroColors.protein;
      return Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: mint.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: mint.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(Icons.check_circle_rounded, color: mint, size: 19),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Your full ${plan.requestedDays}-day plan is ready.',
                style: text.bodyMedium
                    ?.copyWith(color: AppColors.ink, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );
    }

    if (_sp.request == null) return const SizedBox.shrink(); // can't extend

    final next = math.min(7, remaining);
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.field),
            onTap: _extending ? null : _loadNextWeek,
            child: Ink(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.field),
                border: Border.all(
                    color: AppColors.brand.withValues(alpha: 0.5), width: 1.5),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 13),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_extending)
                      const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                    else
                      const Icon(Icons.add_rounded,
                          color: AppColors.brand, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      _extending
                          ? 'Building next $next days…'
                          : 'Load next $next days',
                      style: text.titleSmall?.copyWith(
                          color: AppColors.brand, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${plan.days.length} of ${plan.requestedDays} days ready · 1 credit · free on Unlimited',
          style: text.bodySmall?.copyWith(color: AppColors.inkFaint, fontSize: 11),
        ),
      ],
    );
  }

  /// Generates the next batch of days, appends them, persists, and (if reminders
  /// are on) reschedules so the new days get alarms too. Out of credits → paywall.
  Future<void> _loadNextWeek() async {
    final req = _sp.request;
    if (req == null || _extending) return;
    final messenger = ScaffoldMessenger.of(context);

    final nextStart = _plan.days.isEmpty ? 1 : _plan.days.last.day + 1;
    // Dishes from the last detailed week, so the model doesn't repeat them.
    final recent = _plan.days
        .skip((_plan.days.length - 7).clamp(0, _plan.days.length))
        .expand((d) => d.meals.map((m) => m.dish.trim()))
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();

    // Adaptive re-target inputs: the backend re-paces the next week to the
    // user's latest weigh-in (only acts when there's a weigh-in and startDay>1).
    final latest = _tracking.latestWeight;
    final body = <String, dynamic>{
      ...req,
      'startDay': nextStart,
      'avoidDishes': recent,
      'planId': _sp.id,
      'currentWeightKg': ?latest,
      if (_tracking.weighIns.isNotEmpty)
        'weighIns': _tracking.weighIns.map((w) => w.toJson()).toList(),
    };

    setState(() => _extending = true);
    try {
      final batch = await ApiService.generatePlan(body);
      if (batch.days.isEmpty) {
        if (!mounted) return;
        setState(() => _extending = false);
        messenger.showSnackBar(const SnackBar(
            content: Text('No more days were returned. Try again.')));
        return;
      }
      // Adopt any re-targeted calorie/macro numbers the batch came back with.
      final merged = _plan.withAppendedDays(
        batch.days,
        dailyCalorieTarget: batch.dailyCalorieTarget,
        dailyProteinTarget: batch.dailyProteinTarget,
        dailyCarbsTarget: batch.dailyCarbsTarget,
        dailyFatTarget: batch.dailyFatTarget,
      );
      final added = merged.days.length - _plan.days.length;
      final retargeted = merged.dailyCalorieTarget != _plan.dailyCalorieTarget;
      await PlanStorage.upsert(_sp.copyWith(plan: merged));
      // Extend reminders over the new days when they're enabled.
      final refreshed =
          _scheduled ? await _rescheduleAndRefresh() : _sp.copyWith(plan: merged);
      if (!mounted) return;
      setState(() {
        _plan = merged;
        _sp = refreshed;
        _extending = false;
      });
      messenger.showSnackBar(SnackBar(
        content: Text(retargeted
            ? 'Added $added days · target now ${merged.dailyCalorieTarget} kcal/day'
            : 'Added $added days — '
                '${merged.days.length} of ${merged.requestedDays} ready.'),
      ));
    } on PaymentRequiredException catch (e) {
      if (!mounted) return;
      setState(() => _extending = false);
      await _openPaywallThenExtend(e.message);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _extending = false);
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _extending = false);
      messenger.showSnackBar(SnackBar(content: Text('Could not load more days. $e')));
    }
  }

  /// Opens the paywall; if the user gains credits, immediately retries the load.
  Future<void> _openPaywallThenExtend(String reason) async {
    final bought = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => PaywallScreen(reason: reason),
    ));
    if (!mounted) return;
    if (bought == true ||
        BillingService.instance.entitlements.value.canGenerate) {
      _loadNextWeek();
    }
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
}

// ──────────────────────────────────────────────────────── date strip ──

/// A horizontal calendar strip: weekday micro + day-of-month per plan day.
/// Selected = coral pill; today = coral outline; past days tick in mint.
class _DateStrip extends StatefulWidget {
  final int count;
  final int selected;
  final int? todayIndex;
  final DateTime Function(int dayNumber) dateForDay;
  final int Function(int index) dayNumberAt;
  final ValueChanged<int> onSelect;
  const _DateStrip({
    required this.count,
    required this.selected,
    required this.todayIndex,
    required this.dateForDay,
    required this.dayNumberAt,
    required this.onSelect,
  });

  @override
  State<_DateStrip> createState() => _DateStripState();
}

class _DateStripState extends State<_DateStrip> {
  final _ctrl = ScrollController();
  static const _w = 46.0; // item width incl. gap

  @override
  void initState() {
    super.initState();
    // Land with the selected date in view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_ctrl.hasClients) return;
      final target = (widget.selected * _w - 120)
          .clamp(0.0, _ctrl.position.maxScrollExtent);
      _ctrl.jumpTo(target);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mint = MacroColors.protein;
    return SizedBox(
      height: 56,
      child: ListView.separated(
        controller: _ctrl,
        scrollDirection: Axis.horizontal,
        itemCount: widget.count,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final date = widget.dateForDay(widget.dayNumberAt(i));
          final sel = i == widget.selected;
          final isToday = widget.todayIndex == i;
          final past = widget.todayIndex != null && i < widget.todayIndex!;
          return GestureDetector(
            onTap: () => widget.onSelect(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 40,
              decoration: BoxDecoration(
                color: sel ? AppColors.brand : Colors.transparent,
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                  color: sel
                      ? AppColors.brand
                      : (isToday ? AppColors.brand : Colors.transparent),
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _kWeekdays[date.weekday - 1].toUpperCase().substring(0, 3),
                    style: TextStyle(
                      fontSize: 7.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                      color: sel
                          ? Colors.white.withValues(alpha: 0.85)
                          : AppColors.inkFaint,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${date.day}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: sel
                          ? Colors.white
                          : (past ? mint : AppColors.inkMuted),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────── day macro summary ──

/// Four glass chips summarising the selected day: kcal · P · C · F.
class _DayMacroChips extends StatelessWidget {
  final DayPlan day;
  final DietPlan plan;
  const _DayMacroChips({required this.day, required this.plan});

  @override
  Widget build(BuildContext context) {
    Widget chip(String value, String label, Color? color) {
      final text = Theme.of(context).textTheme;
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: AppColors.line),
          ),
          child: Column(
            children: [
              Text(value,
                  style: text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: color ?? AppColors.ink,
                      height: 1)),
              const SizedBox(height: 3),
              Text(label,
                  style: text.labelSmall?.copyWith(
                      color: AppColors.inkMuted,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.7,
                      fontSize: 7.5)),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        chip('${day.totalCalories}', 'KCAL', null),
        const SizedBox(width: 7),
        chip('${day.totalProtein}g', 'PROTEIN', MacroColors.protein),
        const SizedBox(width: 7),
        chip('${day.totalCarbs}g', 'CARBS', MacroColors.carbs),
        const SizedBox(width: 7),
        chip('${day.totalFat}g', 'FAT', MacroColors.fat),
      ],
    );
  }
}

// ─────────────────────────────────────────────────── meal row ──

/// A compact glass meal row: icon, dish, time · kcal · macros, swap + check.
/// Tap opens the full recipe page.
class _PlanMealRow extends StatelessWidget {
  final Meal meal;
  final bool highlight;
  final bool done;
  final bool swapping;
  final bool swapDisabled;
  final VoidCallback onToggle;
  final VoidCallback onSwap;
  final VoidCallback onTap;
  const _PlanMealRow({
    required this.meal,
    required this.highlight,
    required this.done,
    required this.swapping,
    required this.swapDisabled,
    required this.onToggle,
    required this.onSwap,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = AppColors.forMeal(meal.name);
    final mint = MacroColors.protein;
    final dark = AppColors.brightness == Brightness.dark;

    final macros = (meal.protein > 0 || meal.carbs > 0 || meal.fat > 0)
        ? ' · P${meal.protein} C${meal.carbs} F${meal.fat}'
        : '';

    return Material(
      color: done ? mint.withValues(alpha: 0.05) : AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: highlight
                  ? color
                  : (done ? mint.withValues(alpha: 0.45) : AppColors.line),
              width: highlight ? 2 : 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(11),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(AppColors.iconForMeal(meal.name), color: color, size: 19),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(meal.dish.isEmpty ? meal.name : meal.dish,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800, height: 1.15)),
                      const SizedBox(height: 2),
                      Text(
                        '${meal.time.isEmpty ? meal.name : meal.time}'
                        '${meal.calories > 0 ? ' · ${meal.calories} kcal' : ''}'
                        '$macros',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall
                            ?.copyWith(color: AppColors.inkMuted, fontSize: 10.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                // swap
                Material(
                  color: AppColors.surfaceHigh,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: (swapping || swapDisabled) ? null : onSwap,
                    child: SizedBox(
                      width: 30,
                      height: 30,
                      child: swapping
                          ? const Padding(
                              padding: EdgeInsets.all(7),
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(Icons.autorenew_rounded,
                              size: 16,
                              color: swapDisabled
                                  ? AppColors.inkFaint
                                  : AppColors.brand),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // check
                GestureDetector(
                  onTap: onToggle,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: done ? mint : Colors.transparent,
                      shape: BoxShape.circle,
                      border:
                          Border.all(color: done ? mint : AppColors.line, width: 2),
                    ),
                    child: Icon(Icons.check_rounded,
                        size: 16,
                        color: done
                            ? (dark ? const Color(0xFF062B1A) : Colors.white)
                            : AppColors.inkFaint),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────── about card ──

/// The AI's plan overview, collapsed to two lines with a "more" toggle.
class _AboutPlan extends StatefulWidget {
  final String summary;
  const _AboutPlan({required this.summary});

  @override
  State<_AboutPlan> createState() => _AboutPlanState();
}

class _AboutPlanState extends State<_AboutPlan> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => _open = !_open),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.all(13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.auto_awesome_rounded,
                        color: AppColors.violet, size: 15),
                    const SizedBox(width: 7),
                    Text('ABOUT THIS PLAN',
                        style: text.labelSmall?.copyWith(
                            color: AppColors.inkFaint,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                            fontSize: 8.5)),
                    const Spacer(),
                    Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                        color: AppColors.inkFaint, size: 18),
                  ],
                ),
                const SizedBox(height: 7),
                Text(
                  widget.summary,
                  maxLines: _open ? null : 2,
                  overflow: _open ? null : TextOverflow.ellipsis,
                  style: text.bodySmall
                      ?.copyWith(color: AppColors.inkMuted, height: 1.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReminderPromptDialog extends StatelessWidget {
  const _ReminderPromptDialog();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Dialog(
      backgroundColor: AppColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: AppColors.brand.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.notifications_active_rounded,
                    color: AppColors.brand, size: 36),
              ),
            ),
            const SizedBox(height: 18),
            Center(
              child: Text('Turn on all reminders?',
                  textAlign: TextAlign.center,
                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 12),
            _bullet(context, Icons.restaurant_rounded,
                'A gentle alarm at each meal time so you never miss one.'),
            const SizedBox(height: 10),
            _bullet(context, Icons.shopping_cart_rounded,
                'A grocery alert the evening before each day, so you can shop ahead.'),
            const SizedBox(height: 10),
            _bullet(context, Icons.water_drop_rounded,
                'Hydration nudges through the day to hit your water goal.'),
            const SizedBox(height: 10),
            _bullet(context, Icons.autorenew_rounded,
                'Keeps going after the plan ends by cycling the menu.'),
            const SizedBox(height: 16),
            Text(
              'One tap turns it all on. Change or turn off anytime in the plan\'s Diet settings.',
              style: text.bodySmall?.copyWith(color: AppColors.inkMuted, height: 1.4),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.notifications_active_rounded, size: 18),
                label: const Text('Turn on reminders'),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Maybe later'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bullet(BuildContext context, IconData icon, String label) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: AppColors.brand),
        const SizedBox(width: 12),
        Expanded(
          child: Text(label,
              style: text.bodyMedium?.copyWith(color: AppColors.ink, height: 1.4)),
        ),
      ],
    );
  }
}

