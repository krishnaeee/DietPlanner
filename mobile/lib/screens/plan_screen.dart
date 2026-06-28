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
import '../widgets/common.dart';
import 'grocery_list_screen.dart';
import 'paywall_screen.dart';
import 'progress_screen.dart';

const _kWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _kMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

/// "5 Jun" — compact form for day-selector pills.
String _shortDate(DateTime d) => '${d.day} ${_kMonths[d.month - 1]}';

/// "Mon, 5 Jun" — full form for headers and reminder text.
String _fullDate(DateTime d) =>
    '${_kWeekdays[d.weekday - 1]}, ${d.day} ${_kMonths[d.month - 1]}';

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
            // Out of credits → show a paywall prompt instead of a generic error.
            if (snap.error is PaymentRequiredException) {
              return Column(
                children: [
                  const GradientHeader(title: 'Your diet plan', showBack: true),
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
  late DietPlan _plan; // grows as the user loads more weeks
  bool _busy = false;
  bool _extending = false; // a "load next week" generation is in flight
  PlanTracking _tracking = PlanTracking();

  final ScrollController _scroll = ScrollController();
  final GlobalKey _mealKey = GlobalKey();
  int? _highlight; // meal index to highlight (from a tapped notification)

  bool get _scheduled => _sp.remindersScheduled;
  bool get _repeat => _sp.repeatForever;
  int get _count => _sp.scheduledCount;
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
  }

  Future<void> _loadTracking() async {
    final t = await TrackingStorage.load(_sp.id);
    if (mounted) setState(() => _tracking = t);
  }

  Future<void> _toggleMeal(int dayIndex, int mealIndex) async {
    final next = _tracking.toggleMeal(dayIndex, mealIndex);
    setState(() => _tracking = next);
    await TrackingStorage.save(_sp.id, next);
  }

  void _openProgress() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ProgressScreen(stored: _sp)))
        .then((_) => _loadTracking()); // weight/water may have changed
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
    final plan = _plan;
    final text = Theme.of(context).textTheme;
    final days = plan.days;
    final sub = widget.location.trim().isEmpty
        ? '${plan.plannedDays}-day plan'
        : '${plan.plannedDays}-day plan · ${widget.location.trim()}';

    return Column(
      children: [
        GradientHeader(
          title: 'Your diet plan',
          subtitle: sub,
          showBack: true,
          trailing: _HeaderAction(
            icon: Icons.insights_rounded,
            label: 'Progress',
            onTap: _openProgress,
          ),
        ),
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
            children: [
              _SummaryCard(plan: plan),
              if (days.isNotEmpty) ...[
                const SizedBox(height: 12),
                _GroceryListButton(
                  windowDays: math.min(7, days.length - _selected),
                  onTap: () {
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => GroceryListScreen(
                        plan: plan,
                        startIndex: _selected,
                        windowDays: 7,
                      ),
                    ));
                  },
                ),
              ],
              if (plan.truncated) ...[
                const SizedBox(height: 12),
                _InfoBanner(
                  text: '${plan.days.length} of ${plan.requestedDays} days ready. '
                      'Load the next week at the bottom to extend your plan.',
                ),
              ],
              if (days.isNotEmpty) ...[
                const SizedBox(height: 22),
                _DaySelector(
                  count: days.length,
                  selected: _selected,
                  todayIndex: _todayIndex,
                  dateForDay: _dateForDay,
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
                    date: _dateForDay(days[_selected.clamp(0, days.length - 1)].day),
                    isToday: _todayIndex == _selected,
                    highlightIndex: _highlight,
                    mealKey: _mealKey,
                    isDone: (m) => _tracking.isMealDone(_selected, m),
                    onToggle: (m) => _toggleMeal(_selected, m),
                  ),
                ),
                const SizedBox(height: 20),
                _extendSection(plan, text),
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
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.brand.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle_rounded, color: AppColors.brand, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Your full ${plan.requestedDays}-day plan is ready.',
                style: text.bodyMedium
                    ?.copyWith(color: AppColors.ink, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
    }

    if (_sp.request == null) return const SizedBox.shrink(); // can't extend

    final next = math.min(7, remaining);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.line),
        boxShadow: softShadow(opacity: 0.05, blur: 14, y: 6),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.event_repeat_rounded,
                    color: AppColors.accent, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${plan.days.length} of ${plan.requestedDays} days ready',
                        style:
                            text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text('$remaining days left to plan',
                        style:
                            text.bodySmall?.copyWith(color: AppColors.inkMuted)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _extending ? null : _loadNextWeek,
              icon: _extending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.add_rounded),
              label: Text(_extending
                  ? 'Building next $next days…'
                  : 'Load next $next days'),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Uses 1 credit · free on Unlimited',
            style: text.bodySmall?.copyWith(color: AppColors.inkFaint),
          ),
        ],
      ),
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

    final body = <String, dynamic>{
      ...req,
      'startDay': nextStart,
      'avoidDishes': recent,
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
      final merged = _plan.withAppendedDays(batch.days);
      final added = merged.days.length - _plan.days.length;
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
        content: Text('Added $added days — '
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
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
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
                                    style: text.titleSmall
                                        ?.copyWith(fontWeight: FontWeight.w800)),
                                Text('$_count set · Day 1 ${_fmtDate(_start)}',
                                    style: text.bodySmall
                                        ?.copyWith(color: AppColors.inkMuted)),
                              ],
                            ),
                          ),
                          TextButton(
                              onPressed: _turnOff, child: const Text('Turn off')),
                        ],
                      ),
                      const Divider(height: 8),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: _repeat,
                        onChanged: _toggleRepeat,
                        activeThumbColor: AppColors.brand,
                        title: Text('Repeat after plan ends',
                            style:
                                text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                        subtitle: Text(
                          'Keep daily reminders going by cycling the menu',
                          style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                        ),
                      ),
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

  /// Toggles whether reminders keep cycling the menu after the plan's last day,
  /// then reschedules so the change takes effect immediately.
  Future<void> _toggleRepeat(bool on) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    await PlanStorage.upsert(_sp.copyWith(repeatForever: on));
    final refreshed = await _rescheduleAndRefresh();
    if (!mounted) return;
    setState(() {
      _sp = refreshed;
      _busy = false;
    });
    messenger.showSnackBar(SnackBar(
      content: Text(on
          ? 'Reminders will keep repeating after the plan ends.'
          : 'Reminders will stop after the last plan day.'),
    ));
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

  String _fmtDate(DateTime d) => _fullDate(d);
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

/// Tappable card that opens the consolidated grocery list for the upcoming days.
class _GroceryListButton extends StatelessWidget {
  final int windowDays;
  final VoidCallback onTap;
  const _GroceryListButton({required this.windowDays, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final label = windowDays <= 1
        ? "This day's grocery list"
        : 'Next $windowDays-day grocery list';
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.card),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.line),
            boxShadow: softShadow(opacity: 0.05, blur: 14, y: 6),
          ),
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: AppColors.brand.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.shopping_cart_rounded,
                    color: AppColors.brand, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: text.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(
                      'One deduped shopping list with combined quantities',
                      style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.inkFaint),
            ],
          ),
        ),
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

class _DaySelector extends StatefulWidget {
  final int count;
  final int selected;
  final int? todayIndex;
  final DateTime Function(int dayNumber) dateForDay;
  final ValueChanged<int> onSelect;
  const _DaySelector({
    required this.count,
    required this.selected,
    required this.todayIndex,
    required this.dateForDay,
    required this.onSelect,
  });

  @override
  State<_DaySelector> createState() => _DaySelectorState();
}

class _DaySelectorState extends State<_DaySelector> {
  static const double _pillWidth = 78;
  static const double _gap = 8;

  final ScrollController _ctrl = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelected());
  }

  @override
  void didUpdateWidget(covariant _DaySelector old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelected());
    }
  }

  /// Centres the selected pill in the viewport (clamped to scroll bounds).
  void _scrollToSelected() {
    if (!_ctrl.hasClients) return;
    const itemExtent = _pillWidth + _gap;
    final viewport = _ctrl.position.viewportDimension;
    final target = widget.selected * itemExtent - (viewport - itemExtent) / 2;
    _ctrl.animateTo(
      target.clamp(0.0, _ctrl.position.maxScrollExtent),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 60,
      child: ListView.separated(
        controller: _ctrl,
        scrollDirection: Axis.horizontal,
        itemCount: widget.count,
        separatorBuilder: (_, _) => const SizedBox(width: _gap),
        itemBuilder: (context, i) {
          final sel = i == widget.selected;
          final isToday = i == widget.todayIndex;
          final dateColor = sel
              ? Colors.white.withValues(alpha: 0.85)
              : (isToday ? AppColors.accent : AppColors.inkMuted);
          return GestureDetector(
            onTap: () => widget.onSelect(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: _pillWidth,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: sel ? AppColors.brand : AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: sel
                      ? AppColors.brand
                      : (isToday ? AppColors.accent : AppColors.line),
                  width: isToday && !sel ? 1.6 : 1,
                ),
                boxShadow: sel ? softShadow(opacity: 0.10, blur: 12, y: 6) : null,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    isToday ? 'Today' : 'Day ${i + 1}',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13.5,
                      color: sel
                          ? Colors.white
                          : (isToday ? AppColors.accent : AppColors.inkMuted),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _shortDate(widget.dateForDay(i + 1)),
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 11.5,
                      color: dateColor,
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

class _DayDetail extends StatelessWidget {
  final DayPlan day;
  final DateTime date;
  final bool isToday;
  final int? highlightIndex;
  final Key? mealKey;
  final bool Function(int meal) isDone;
  final void Function(int meal) onToggle;
  const _DayDetail({
    super.key,
    required this.day,
    required this.date,
    required this.isToday,
    this.highlightIndex,
    this.mealKey,
    required this.isDone,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final doneCount =
        List.generate(day.meals.length, (m) => isDone(m)).where((d) => d).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('Day ${day.day}',
                          style: text.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800)),
                      if (isToday) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.accent,
                            borderRadius: BorderRadius.circular(30),
                          ),
                          child: Text(
                            'TODAY',
                            style: text.labelSmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _fullDate(date),
                    style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (day.meals.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: AppColors.brand.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.task_alt_rounded,
                        color: AppColors.brand, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      '$doneCount/${day.meals.length}',
                      style: text.labelLarge?.copyWith(
                        color: AppColors.brand,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
            ],
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
            child: _MealCard(
              meal: day.meals[m],
              highlight: hi,
              done: isDone(m),
              onToggle: () => onToggle(m),
            ),
          );
        }),
      ],
    );
  }
}

class _MealCard extends StatelessWidget {
  final Meal meal;
  final bool highlight;
  final bool done;
  final VoidCallback? onToggle;
  const _MealCard({
    required this.meal,
    this.highlight = false,
    this.done = false,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = AppColors.forMeal(meal.name);
    final bg = highlight
        ? color.withValues(alpha: 0.06)
        : (done ? AppColors.brand.withValues(alpha: 0.05) : AppColors.surface);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(
          color: highlight
              ? color
              : (done ? AppColors.brand.withValues(alpha: 0.5) : Colors.transparent),
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
                if (onToggle != null) ...[
                  const SizedBox(width: 10),
                  _MealCheck(done: done, onTap: onToggle!),
                ],
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

/// A round check toggle shown on each meal card to mark it eaten.
class _MealCheck extends StatelessWidget {
  final bool done;
  final VoidCallback onTap;
  const _MealCheck({required this.done, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      checked: done,
      label: done ? 'Meal eaten' : 'Mark meal eaten',
      child: Material(
        color: done ? AppColors.brand : AppColors.fieldFill,
        shape: CircleBorder(
          side: BorderSide(color: done ? AppColors.brand : AppColors.line, width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(
              Icons.check_rounded,
              size: 20,
              color: done ? Colors.white : AppColors.inkFaint,
            ),
          ),
        ),
      ),
    );
  }
}

/// A pill button in the gradient header (e.g. "Progress").
class _HeaderAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _HeaderAction(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(AppRadius.pill),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
