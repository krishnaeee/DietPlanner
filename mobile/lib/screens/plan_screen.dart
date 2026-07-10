import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/diet_plan.dart';
import '../models/tracking.dart';
import '../services/api_service.dart';
import '../services/billing_service.dart';
import '../services/notification_service.dart';
import '../services/plan_storage.dart';
import '../services/tracking_storage.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'diet_settings_screen.dart';
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
  bool _extending = false; // a "load next week" generation is in flight
  int? _swapping; // meal index (on the selected day) currently being swapped
  bool _reminderPromptDismissed = false; // hides the "set reminders" nudge
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
    _loadPromptDismissed();
  }

  Future<void> _loadTracking() async {
    final t = await TrackingStorage.load(_sp.id);
    if (mounted) setState(() => _tracking = t);
  }

  static const _promptDismissKey = 'reminder_prompt_dismissed';

  /// Restores whether this plan's "set reminders" nudge was dismissed before.
  Future<void> _loadPromptDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_promptDismissKey) ?? const [];
    if (ids.contains(_sp.id) && mounted) {
      setState(() => _reminderPromptDismissed = true);
    }
  }

  /// Hides the nudge and remembers it per-plan so it doesn't return on reopen.
  Future<void> _dismissReminderPrompt() async {
    setState(() => _reminderPromptDismissed = true);
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_promptDismissKey) ?? <String>[];
    if (!ids.contains(_sp.id)) {
      ids.add(_sp.id);
      await prefs.setStringList(_promptDismissKey, ids);
    }
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
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _HeaderAction(
                icon: Icons.insights_rounded,
                label: 'Progress',
                onTap: _openProgress,
              ),
              const SizedBox(width: 8),
              _HeaderIconButton(
                icon: Icons.tune_rounded,
                tooltip: 'Diet settings',
                onTap: _openSettings,
              ),
            ],
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
                    plan: plan,
                    swappingIndex: _swapping,
                    isDone: (m) => _tracking.isMealDone(_selected, m),
                    onToggle: (m) => _toggleMeal(_selected, m),
                    onSwap: _swapMeal,
                    onGrocery: _openDayGrocery,
                  ),
                ),
                const SizedBox(height: 20),
                _extendSection(plan, text),
                if (!_scheduled && !_reminderPromptDismissed) ...[
                  const SizedBox(height: 16),
                  _ReminderPromptCard(
                    onSet: _openSettings,
                    onDismiss: _dismissReminderPrompt,
                  ),
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
            const SizedBox(height: 12),
            const Divider(),
            _Collapsible(
              initiallyExpanded: true,
              title: Text('About this plan',
                  style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
              child: Text(
                plan.summary,
                style: text.bodyMedium?.copyWith(height: 1.5, color: AppColors.ink),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A tappable header with a chevron that expands/collapses [child] with a
/// smooth size+fade animation. Used to fold the plan summary and each meal's
/// ingredient list so the plan view stays compact.
class _Collapsible extends StatefulWidget {
  final Widget title;
  final Widget child;
  final bool initiallyExpanded;
  const _Collapsible({
    required this.title,
    required this.child,
    this.initiallyExpanded = true,
  });

  @override
  State<_Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends State<_Collapsible> {
  late bool _open = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(child: widget.title),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Icons.keyboard_arrow_down_rounded,
                      color: AppColors.inkMuted),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: widget.child,
          ),
          secondChild: const SizedBox(width: double.infinity),
          crossFadeState:
              _open ? CrossFadeState.showFirst : CrossFadeState.showSecond,
          duration: const Duration(milliseconds: 220),
          sizeCurve: Curves.easeOut,
        ),
      ],
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
              Icon(Icons.chevron_right_rounded, color: AppColors.inkFaint),
            ],
          ),
        ),
      ),
    );
  }
}

/// Slim link inside a day's detail: opens that day's grocery list.
class _DayGroceryLink extends StatelessWidget {
  final VoidCallback onTap;
  const _DayGroceryLink({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: AppColors.brand.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.shopping_cart_rounded,
                  color: AppColors.brand, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Groceries for this day',
                    style: text.bodyMedium?.copyWith(
                        color: AppColors.brandDark, fontWeight: FontWeight.w700)),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.brand),
            ],
          ),
        ),
      ),
    );
  }
}

/// A dismissible nudge shown at the bottom of a plan when reminders aren't set.
class _ReminderPromptCard extends StatelessWidget {
  final VoidCallback onSet;
  final VoidCallback onDismiss;
  const _ReminderPromptCard({required this.onSet, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.brand.withValues(alpha: 0.4)),
        boxShadow: softShadow(opacity: 0.05, blur: 14, y: 6),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Get daily reminders?',
                        style: text.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(
                      'A grocery alert the evening before + meal-time alarms.',
                      style:
                          text.bodySmall?.copyWith(color: AppColors.inkMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onSet,
                  icon: const Icon(Icons.notifications_active_rounded, size: 18),
                  label: const Text('Set reminders'),
                ),
              ),
              const SizedBox(width: 10),
              TextButton(onPressed: onDismiss, child: const Text('Not now')),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'You can turn this off anytime in Diet settings.',
            style: text.bodySmall?.copyWith(color: AppColors.inkFaint),
          ),
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
  final DietPlan plan;
  final int? swappingIndex;
  final bool Function(int meal) isDone;
  final void Function(int meal) onToggle;
  final void Function(int meal) onSwap;
  final VoidCallback onGrocery;
  const _DayDetail({
    super.key,
    required this.day,
    required this.date,
    required this.isToday,
    this.highlightIndex,
    this.mealKey,
    required this.plan,
    this.swappingIndex,
    required this.isDone,
    required this.onToggle,
    required this.onSwap,
    required this.onGrocery,
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
        const SizedBox(height: 12),
        _DayGroceryLink(onTap: onGrocery),
        if (plan.hasMacros) ...[
          const SizedBox(height: 14),
          _MacroBars(day: day, plan: plan),
        ],
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
              swapping: swappingIndex == m,
              swapDisabled: swappingIndex != null,
              onToggle: () => onToggle(m),
              onSwap: () => onSwap(m),
            ),
          );
        }),
      ],
    );
  }
}

/// Three slim bars showing the day's protein / carbs / fat against the plan's
/// daily targets.
class _MacroBars extends StatelessWidget {
  final DayPlan day;
  final DietPlan plan;
  const _MacroBars({required this.day, required this.plan});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _MacroBar(
            label: 'Protein',
            grams: day.totalProtein,
            target: plan.dailyProteinTarget,
            color: AppColors.brand,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _MacroBar(
            label: 'Carbs',
            grams: day.totalCarbs,
            target: plan.dailyCarbsTarget,
            color: AppColors.accent,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _MacroBar(
            label: 'Fat',
            grams: day.totalFat,
            target: plan.dailyFatTarget,
            color: AppColors.dinner,
          ),
        ),
      ],
    );
  }
}

class _MacroBar extends StatelessWidget {
  final String label;
  final int grams;
  final int target;
  final Color color;
  const _MacroBar({
    required this.label,
    required this.grams,
    required this.target,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final pct = target <= 0 ? 0.0 : (grams / target).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: text.labelSmall?.copyWith(
                    color: AppColors.inkMuted, fontWeight: FontWeight.w700)),
            Text(target > 0 ? '$grams/${target}g' : '${grams}g',
                style: text.labelSmall?.copyWith(
                    color: AppColors.ink, fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 6,
            backgroundColor: AppColors.line,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    );
  }
}

class _MealCard extends StatelessWidget {
  final Meal meal;
  final bool highlight;
  final bool done;
  final bool swapping; // this meal is being regenerated
  final bool swapDisabled; // another meal on the day is being swapped
  final VoidCallback? onToggle;
  final VoidCallback? onSwap;
  const _MealCard({
    required this.meal,
    this.highlight = false,
    this.done = false,
    this.swapping = false,
    this.swapDisabled = false,
    this.onToggle,
    this.onSwap,
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
                if (onSwap != null) ...[
                  const SizedBox(width: 6),
                  _swapButton(context, color),
                ],
                if (onToggle != null) ...[
                  const SizedBox(width: 6),
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
            if (meal.protein > 0 || meal.carbs > 0 || meal.fat > 0) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  _macroChip(context, 'P', meal.protein, AppColors.brand),
                  const SizedBox(width: 8),
                  _macroChip(context, 'C', meal.carbs, AppColors.accent),
                  const SizedBox(width: 8),
                  _macroChip(context, 'F', meal.fat, AppColors.dinner),
                ],
              ),
            ],
            if (meal.ingredients.isNotEmpty) ...[
              const SizedBox(height: 6),
              _Collapsible(
                initiallyExpanded: false,
                title: Text(
                  'INGREDIENTS (${meal.ingredients.length})',
                  style: text.labelSmall?.copyWith(
                    color: AppColors.inkFaint,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: meal.ingredients.map((ing) {
                    final label = ing.quantity.isEmpty
                        ? ing.name
                        : '${ing.name} · ${ing.quantity}';
                    return Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
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
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _macroChip(BuildContext context, String letter, int grams, Color color) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$letter ${grams}g',
        style: text.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w800),
      ),
    );
  }

  Widget _swapButton(BuildContext context, Color color) {
    final enabled = !swapping && !swapDisabled;
    return Semantics(
      button: true,
      label: 'Swap this meal for a different dish',
      child: Material(
        color: AppColors.fieldFill,
        shape: CircleBorder(side: BorderSide(color: AppColors.line, width: 1.5)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onSwap : null,
          child: SizedBox(
            width: 36,
            height: 36,
            child: swapping
                ? const Padding(
                    padding: EdgeInsets.all(9),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.autorenew_rounded,
                    size: 20, color: enabled ? color : AppColors.inkFaint),
          ),
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
/// A compact icon-only pill in the gradient header (e.g. the settings gear).
class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _HeaderIconButton(
      {required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.18),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, color: Colors.white, size: 20),
          ),
        ),
      ),
    );
  }
}

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
