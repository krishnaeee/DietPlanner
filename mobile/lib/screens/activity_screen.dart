import 'package:flutter/material.dart';

import '../models/activity.dart';
import '../models/tracking.dart';
import '../services/api_service.dart';
import '../services/plan_storage.dart';
import '../services/tracking_storage.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/fresh.dart';

/// "Move more" — detailed AI activity suggestions for a day or a whole week,
/// tailored to the plan's goal. Each session says what to do AND how to do it
/// (ordered steps, the one form cue, kit, why it helps); the plan carries a
/// shared warm-up, a progression rule, and safety guardrails. Its own tab
/// (advice only; it never changes the calorie target). Free, auth-only.
class ActivityScreen extends StatefulWidget {
  final StoredPlan stored;

  /// When shown as a bottom-nav tab (not pushed), leave room under the dock.
  final bool embedded;
  const ActivityScreen({super.key, required this.stored, this.embedded = false});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  PlanTracking _t = PlanTracking();
  // Cached per scope: key absent = not resolved yet, value null = resolved but
  // nothing stored (show the first-run state).
  final Map<String, ActivityPlan?> _cache = {};
  final Map<String, DateTime?> _updatedAt = {}; // when each scope was generated
  bool _busy = false; // generating a new plan
  bool _resolving = true; // loading the stored plan for the selected scope
  String _scope = 'day'; // day | week

  /// Suggestions auto-refresh once they're older than this.
  static const _maxAge = Duration(days: 7);

  StoredPlan get _sp => widget.stored;

  @override
  void initState() {
    super.initState();
    _loadTracking();
    _resolve('day'); // show whatever's already stored for today
    // Keep the latest weight fresh if it's logged on another tab.
    TrackingStorage.revision.addListener(_loadTracking);
  }

  @override
  void dispose() {
    TrackingStorage.revision.removeListener(_loadTracking);
    super.dispose();
  }

  Future<void> _loadTracking() async {
    final t = await TrackingStorage.load(_sp.id);
    if (!mounted) return;
    setState(() => _t = t);
  }

  /// Selects [scope] and loads its stored suggestions once, so re-opening the
  /// tab (or toggling back) shows the same plan instead of regenerating.
  Future<void> _resolve(String scope) async {
    if (_cache.containsKey(scope)) {
      setState(() {
        _scope = scope;
        _resolving = false;
      });
      return;
    }
    setState(() {
      _scope = scope;
      _resolving = true;
    });
    ({ActivityPlan? activity, DateTime? updatedAt})? stored;
    try {
      stored = await ApiService.getStoredActivity(_sp.id, scope);
    } catch (_) {
      stored = null; // offline / error → fall back to the first-run state
    }
    if (!mounted) return;
    final plan = stored?.activity;
    final ts = stored?.updatedAt;
    final fresh = ts != null && DateTime.now().difference(ts) < _maxAge;
    // Stored but stale (> 7 days) → regenerate automatically on open.
    if (plan != null && !fresh) {
      setState(() => _resolving = false);
      await _suggest(scope);
      return;
    }
    setState(() {
      _cache[scope] = plan;
      _updatedAt[scope] = ts;
      _resolving = false;
    });
  }

  /// Generates a fresh plan for [scope]. The server stores it, so it persists
  /// across re-opens until the user regenerates. Free.
  Future<void> _suggest(String scope) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    final req = _sp.request;
    final goal = (req?['goal'] ?? '').toString();
    final body = <String, dynamic>{
      'planId': _sp.id,
      'scope': scope,
      'goal': goal.isNotEmpty ? goal : 'maintain',
      'sex': req?['sex'],
      'age': req?['age'],
      'activityLevel': req?['activityLevel'],
      'weightKg': _t.latestWeight ?? _sp.startWeightKg,
    };
    setState(() {
      _scope = scope;
      _busy = true;
    });
    try {
      final plan = await ApiService.getActivity(body);
      if (!mounted) return;
      setState(() {
        _cache[scope] = plan;
        _updatedAt[scope] = DateTime.now(); // just generated + stored
        _busy = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(const SnackBar(
          content: Text("Couldn't get activity suggestions. Please try again.")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final name = _sp.name.trim();
    return Scaffold(
      body: Column(
        children: [
          FreshHeader(
            title: 'Activity',
            subtitle: name.isEmpty ? null : name,
            showBack: true,
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(16, 8, 16, widget.embedded ? 110 : 28),
              children: [
                // Persistent control row — pick a scope to (re)fetch.
                Row(
                  children: [
                    Icon(Icons.directions_run_rounded,
                        size: 16, color: AppColors.brand),
                    const SizedBox(width: 8),
                    Text('MOVE MORE',
                        style: text.labelSmall?.copyWith(
                            color: AppColors.inkFaint,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.0,
                            fontSize: 9)),
                    const Spacer(),
                    _ScopeToggle(
                      scope: _scope,
                      enabled: !_busy,
                      onPick: _resolve,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_busy)
                  const _ActivityLoading()
                else if (_resolving)
                  const _ActivityResolving()
                else if (_cache[_scope] == null)
                  _ActivityEmpty(scope: _scope, onPick: _suggest)
                else
                  _ActivityResult(
                    plan: _cache[_scope]!,
                    scope: _scope,
                    updatedAt: _updatedAt[_scope],
                    onRegenerate: () => _suggest(_scope),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Intensity → colour + label. light=slate, moderate=mint, vigorous=coral.
({Color color, String label}) _intensityStyle(String intensity) {
  switch (intensity) {
    case 'vigorous':
      return (color: AppColors.brand, label: 'Vigorous');
    case 'light':
      return (color: AppColors.inkMuted, label: 'Light');
    default:
      return (color: MacroColors.protein, label: 'Moderate');
  }
}

/// First-run state: explain the feature and point at the toggle above.
class _ActivityEmpty extends StatelessWidget {
  final String scope;
  final void Function(String scope) onPick;
  const _ActivityEmpty({required this.scope, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 6),
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.brand.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.directions_run_rounded,
                size: 28, color: AppColors.brand),
          ),
          const SizedBox(height: 14),
          Text('Move to reach your goal faster',
              textAlign: TextAlign.center,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(
            'Get a detailed, do-it-now workout tailored to your goal — what to do, how to do it, and why. Pick a single day or a whole week. Free, anytime.',
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(color: AppColors.inkMuted, height: 1.5),
          ),
          const SizedBox(height: 18),
          GradientButton(
            label: scope == 'week' ? 'Suggest this week' : "Suggest today's workout",
            icon: Icons.auto_awesome_rounded,
            onPressed: () => onPick(scope),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// Busy state while the model thinks.
class _ActivityLoading extends StatelessWidget {
  const _ActivityLoading();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SectionCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 22),
        child: Column(
          children: [
            const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(height: 14),
            Text('Building your workout…',
                style: text.bodyMedium?.copyWith(color: AppColors.inkMuted)),
          ],
        ),
      ),
    );
  }
}

/// The suggestions once they arrive: the shared warm-up, per-session cards
/// (expandable in week view), and a closing notes card.
class _ActivityResult extends StatefulWidget {
  final ActivityPlan plan;
  final String scope; // day | week
  final DateTime? updatedAt;
  final VoidCallback onRegenerate;
  const _ActivityResult(
      {required this.plan,
      required this.scope,
      required this.updatedAt,
      required this.onRegenerate});

  @override
  State<_ActivityResult> createState() => _ActivityResultState();
}

class _ActivityResultState extends State<_ActivityResult> {
  // In week view, one card open at a time (starts on the first).
  int? _open = 0;
  bool get _accordion => widget.scope == 'week';

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = widget.plan;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (p.headline.isNotEmpty) ...[
          Text(p.headline,
              style: text.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800, height: 1.3)),
          const SizedBox(height: 14),
        ],
        if (p.warmup.isNotEmpty) ...[
          _WarmupCard(text: p.warmup),
          const SizedBox(height: 12),
        ],
        for (var i = 0; i < p.activities.length; i++) ...[
          _ActivityCard(
            a: p.activities[i],
            weekScope: _accordion,
            expanded: _accordion ? _open == i : true,
            onToggle: _accordion
                ? () => setState(() => _open = _open == i ? null : i)
                : null,
          ),
          const SizedBox(height: 10),
        ],
        if (p.progression.isNotEmpty || p.safety.isNotEmpty || p.tip.isNotEmpty) ...[
          const SizedBox(height: 4),
          _NotesCard(
              progression: p.progression, safety: p.safety, tip: p.tip),
        ],
        const SizedBox(height: 12),
        Center(
          child: TextButton.icon(
            onPressed: widget.onRegenerate,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: Text(widget.scope == 'week'
                ? 'Regenerate this week'
                : "Regenerate today's workout"),
          ),
        ),
        if (widget.updatedAt != null)
          Center(
            child: Text(
              'Generated ${relativeSince(widget.updatedAt!)} · auto-refreshes weekly',
              style: text.bodySmall
                  ?.copyWith(color: AppColors.inkFaint, fontSize: 11),
            ),
          ),
      ],
    );
  }
}

/// Brief spinner while the stored plan for the selected scope loads.
class _ActivityResolving extends StatelessWidget {
  const _ActivityResolving();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4)),
      ),
    );
  }
}

/// The one shared warm-up + cool-down, pinned above the sessions.
class _WarmupCard extends StatelessWidget {
  final String text;
  const _WarmupCard({required this.text});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.self_improvement_rounded,
                  size: 15, color: MacroColors.protein),
              const SizedBox(width: 8),
              Text('WARM UP & COOL DOWN',
                  style: t.labelSmall?.copyWith(
                      color: AppColors.inkFaint,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.0,
                      fontSize: 9)),
            ],
          ),
          const SizedBox(height: 8),
          Text(text,
              style: t.bodySmall?.copyWith(color: AppColors.inkMuted, height: 1.5)),
        ],
      ),
    );
  }
}

/// One session. Collapsed: name, focus, the minute/intensity/calorie chips, and
/// the kit. Expanded: the numbered how-to steps and the key form cue.
class _ActivityCard extends StatelessWidget {
  final ActivitySuggestion a;
  final bool weekScope;
  final bool expanded;
  final VoidCallback? onToggle;
  const _ActivityCard({
    required this.a,
    required this.weekScope,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ist = _intensityStyle(a.intensity);
    final rest = a.isRest;

    final summary = Padding(
      padding: const EdgeInsets.fromLTRB(15, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (weekScope && a.day.isNotEmpty) ...[
                Container(
                  width: 40,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: (rest ? AppColors.inkMuted : AppColors.brand)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(a.day.toUpperCase(),
                      style: text.labelSmall?.copyWith(
                          color: rest ? AppColors.inkMuted : AppColors.brand,
                          fontWeight: FontWeight.w800,
                          fontSize: 9.5)),
                ),
                const SizedBox(width: 12),
              ] else ...[
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(top: 6),
                  decoration: BoxDecoration(
                      color: rest ? AppColors.inkMuted : AppColors.brand,
                      shape: BoxShape.circle),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.name,
                        style: text.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: rest ? AppColors.inkMuted : AppColors.ink)),
                    if (a.focus.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(a.focus,
                          style: text.bodySmall?.copyWith(
                              color: AppColors.inkMuted, height: 1.35)),
                    ],
                  ],
                ),
              ),
              if (onToggle != null)
                Padding(
                  padding: const EdgeInsets.only(left: 6, top: 2),
                  child: AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: motion(context, 180),
                    child: Icon(Icons.expand_more_rounded,
                        color: AppColors.inkMuted, size: 22),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // Minute / intensity / calorie chips.
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              _MetaChip(icon: Icons.schedule_rounded, label: '${a.minutes} min'),
              _IntensityChip(color: ist.color, label: ist.label),
              if (a.calories > 0)
                _MetaChip(
                    icon: Icons.local_fire_department_rounded,
                    label: '${a.calories} kcal'),
            ],
          ),
          if (a.equipment.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.fitness_center_rounded,
                    size: 13, color: AppColors.inkFaint),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(a.equipment,
                      style: text.bodySmall?.copyWith(
                          color: AppColors.inkFaint, height: 1.35)),
                ),
              ],
            ),
          ],
        ],
      ),
    );

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        children: [
          if (onToggle != null)
            Material(
              color: Colors.transparent,
              child: InkWell(onTap: onToggle, child: summary),
            )
          else
            summary,
          // Steps + form cue, revealed when expanded.
          AnimatedCrossFade(
            duration: motion(context, 180),
            crossFadeState:
                expanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            firstChild: _ActivityDetail(a: a),
            secondChild: const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// The expanded body: numbered how-to steps and the single form cue.
class _ActivityDetail extends StatelessWidget {
  final ActivitySuggestion a;
  const _ActivityDetail({required this.a});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 0, 15, 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: AppColors.line, height: 1),
          const SizedBox(height: 14),
          if (a.howTo.isNotEmpty) ...[
            Text('HOW TO',
                style: text.labelSmall?.copyWith(
                    color: AppColors.inkFaint,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.0,
                    fontSize: 9)),
            const SizedBox(height: 10),
            for (var i = 0; i < a.howTo.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 20,
                      child: Text('${i + 1}',
                          style: text.bodyMedium?.copyWith(
                              color: AppColors.brand,
                              fontWeight: FontWeight.w900,
                              height: 1.35)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(a.howTo[i],
                          style: text.bodyMedium?.copyWith(
                              height: 1.4, fontWeight: FontWeight.w500)),
                    ),
                  ],
                ),
              ),
          ],
          if (a.formCue.isNotEmpty) ...[
            const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 16, color: AppColors.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('FORM',
                            style: text.labelSmall?.copyWith(
                                color: AppColors.accent,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                                fontSize: 8.5)),
                        const SizedBox(height: 3),
                        Text(a.formCue,
                            style: text.bodySmall
                                ?.copyWith(color: AppColors.ink, height: 1.4)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _MetaChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppColors.inkMuted),
        const SizedBox(width: 5),
        Text(label,
            style: text.bodySmall?.copyWith(
                color: AppColors.inkMuted, fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _IntensityChip extends StatelessWidget {
  final Color color;
  final String label;
  const _IntensityChip({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: text.bodySmall
                ?.copyWith(color: color, fontWeight: FontWeight.w700)),
      ],
    );
  }
}

/// Plan-wide notes footer: how to progress, safety guardrails, a scheduling tip.
class _NotesCard extends StatelessWidget {
  final String progression;
  final String safety;
  final String tip;
  const _NotesCard(
      {required this.progression, required this.safety, required this.tip});

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[
      if (progression.isNotEmpty)
        _noteRow(context, Icons.trending_up_rounded, 'PROGRESSION', progression,
            AppColors.brand),
      if (safety.isNotEmpty)
        _noteRow(context, Icons.shield_rounded, 'SAFETY', safety,
            AppColors.accent),
      if (tip.isNotEmpty)
        _noteRow(context, Icons.lightbulb_outline_rounded, 'TIP', tip,
            MacroColors.protein),
    ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 16),
            rows[i],
          ],
        ],
      ),
    );
  }

  Widget _noteRow(BuildContext context, IconData icon, String label,
      String body, Color color) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: text.labelSmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      fontSize: 9)),
              const SizedBox(height: 4),
              Text(body,
                  style: text.bodySmall
                      ?.copyWith(color: AppColors.inkMuted, height: 1.45)),
            ],
          ),
        ),
      ],
    );
  }
}

class _ScopeToggle extends StatelessWidget {
  final String scope;
  final bool enabled;
  final void Function(String scope) onPick;
  const _ScopeToggle(
      {required this.scope, required this.enabled, required this.onPick});

  @override
  Widget build(BuildContext context) {
    Widget seg(String value, String label) {
      final sel = scope == value;
      return GestureDetector(
        // opaque + vertical padding expands the tap area to ~44dp while the
        // visible pill stays compact (the hitSlop pattern for a small control).
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => onPick(value) : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: sel ? AppColors.brand : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(label,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: sel ? Colors.white : AppColors.inkMuted,
                  )),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.fieldFill,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg('day', 'Today'),
        seg('week', 'This week'),
      ]),
    );
  }
}
