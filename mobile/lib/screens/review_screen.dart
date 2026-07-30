import 'package:flutter/material.dart';

import '../models/review.dart';
import '../models/tracking.dart';
import '../services/api_service.dart';
import '../services/plan_storage.dart';
import '../theme/app_theme.dart';
import '../widgets/fresh.dart';

/// Full-page AI progress review, opened from the Progress tab (like the
/// Groceries page opens from the plan). Fetches on open — free, auth-only — and
/// can be re-run.
class ReviewScreen extends StatefulWidget {
  final StoredPlan stored;
  final PlanTracking tracking;
  const ReviewScreen({super.key, required this.stored, required this.tracking});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  Review? _review;
  DateTime? _updatedAt; // when the shown review was generated
  bool _loading = true;
  String? _error;

  /// Reviews auto-refresh once they're older than this.
  static const _maxAge = Duration(days: 7);

  StoredPlan get _sp => widget.stored;
  PlanTracking get _t => widget.tracking;

  @override
  void initState() {
    super.initState();
    _init();
  }

  /// Show the stored review if it's fresh (< 7 days old); regenerate if it's
  /// stale or missing. "Review again" is the explicit manual refresh.
  Future<void> _init() async {
    try {
      final stored = await ApiService.getStoredReview(_sp.id);
      if (!mounted) return;
      final r = stored.review;
      final ts = stored.updatedAt;
      final fresh = ts != null && DateTime.now().difference(ts) < _maxAge;
      if (r != null && fresh) {
        setState(() {
          _review = r;
          _updatedAt = ts;
          _loading = false;
        });
        return;
      }
    } catch (_) {
      // Stored-read failed (offline / server issue) — fall through and generate.
    }
    await _fetch();
  }

  /// Days since the plan started, 1-based and clamped to the plan length.
  int get _daysElapsed {
    final now = DateTime.now();
    final start = DateTime(_sp.startDate.year, _sp.startDate.month, _sp.startDate.day);
    final d = DateTime(now.year, now.month, now.day).difference(start).inDays + 1;
    return d.clamp(1, _sp.plan.days.isEmpty ? 1 : _sp.plan.days.length);
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final a = _t.adherence(_sp.plan, _sp.startDate, DateTime.now());
    final goal = (_sp.request?['goal'] ?? '').toString();
    final body = <String, dynamic>{
      'planId': _sp.id,
      'goal': goal.isNotEmpty ? goal : 'maintain',
      'startWeightKg': _sp.startWeightKg ?? _t.firstWeight,
      'targetWeightKg': _sp.targetWeightKg,
      'currentWeightKg': _t.latestWeight,
      'targetDays': _sp.plan.requestedDays,
      'daysElapsed': _daysElapsed,
      'calorieTarget': _sp.plan.dailyCalorieTarget,
      'weighIns': _t.weighIns.map((w) => w.toJson()).toList(),
      'mealsDone': a.done,
      'mealsTotal': a.total,
      'extrasCount': _t.extras.length,
      'extrasCalories': _t.extras.fold<int>(0, (s, e) => s + e.calories),
    };
    try {
      final review = await ApiService.getReview(body);
      if (!mounted) return;
      setState(() {
        _review = review;
        _updatedAt = DateTime.now(); // just generated + stored server-side
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = "Couldn't review your progress. Please try again.";
        _loading = false;
      });
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
            title: 'Progress review',
            subtitle: name.isEmpty ? null : name,
            showBack: true,
          ),
          Expanded(
            child: _loading
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                            width: 26,
                            height: 26,
                            child: CircularProgressIndicator(strokeWidth: 2.5)),
                        const SizedBox(height: 16),
                        Text('Reviewing your progress…',
                            style: text.bodyMedium
                                ?.copyWith(color: AppColors.inkMuted)),
                      ],
                    ),
                  )
                : _error != null
                    ? _ReviewError(message: _error!, onRetry: _fetch)
                    : _review == null
                        ? const SizedBox.shrink()
                        : ListView(
                            padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
                            children: [
                              _ReviewBody(review: _review!),
                              const SizedBox(height: 22),
                              GradientButton(
                                label: 'Review again',
                                icon: Icons.refresh_rounded,
                                onPressed: _fetch,
                              ),
                              if (_updatedAt != null) ...[
                                const SizedBox(height: 10),
                                Center(
                                  child: Text(
                                    'Last reviewed ${relativeSince(_updatedAt!)} · auto-refreshes weekly',
                                    style: text.bodySmall?.copyWith(
                                        color: AppColors.inkFaint, fontSize: 11),
                                  ),
                                ),
                              ],
                            ],
                          ),
          ),
        ],
      ),
    );
  }
}

/// The review content laid out for a full page: status, headline, summary, and
/// the doing-well / focus-on lists.
class _ReviewBody extends StatelessWidget {
  final Review review;
  const _ReviewBody({required this.review});

  ({Color color, String label}) get _status {
    switch (review.status) {
      case 'ahead':
        return (color: MacroColors.protein, label: 'AHEAD');
      case 'on_track':
        return (color: MacroColors.protein, label: 'ON TRACK');
      case 'behind':
        return (color: AppColors.accent, label: 'BEHIND');
      case 'too_fast':
        return (color: AppColors.accent, label: 'TOO FAST');
      default:
        return (color: AppColors.inkMuted, label: 'EARLY DAYS');
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final st = _status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            color: st.color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(st.label,
              style: text.labelSmall?.copyWith(
                  color: st.color,
                  fontWeight: FontWeight.w800,
                  fontSize: 9.5,
                  letterSpacing: 0.8)),
        ),
        const SizedBox(height: 14),
        Text(review.headline,
            style: text.headlineSmall?.copyWith(
                fontWeight: FontWeight.w900, height: 1.2, letterSpacing: -0.4)),
        if (review.summary.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(review.summary,
              style: text.bodyLarge?.copyWith(color: AppColors.ink, height: 1.55)),
        ],
        if (review.metrics.isNotEmpty) ...[
          const SizedBox(height: 22),
          _MetricsBlock(metrics: review.metrics),
        ],
        if (review.doingWell.isNotEmpty) ...[
          const SizedBox(height: 18),
          _ReviewList(
              label: 'DOING WELL',
              icon: Icons.check_circle_rounded,
              color: MacroColors.protein,
              items: review.doingWell),
        ],
        if (review.improve.isNotEmpty) ...[
          const SizedBox(height: 14),
          _ReviewList(
              label: 'FOCUS ON',
              icon: Icons.trending_up_rounded,
              color: AppColors.brand,
              items: review.improve),
        ],
        if (review.actionPlan.isNotEmpty) ...[
          const SizedBox(height: 14),
          _ActionPlanCard(items: review.actionPlan),
        ],
        if (review.outlook.isNotEmpty) ...[
          const SizedBox(height: 14),
          _OutlookCard(text: review.outlook),
        ],
      ],
    );
  }
}

/// Direction → colour for a metric row. good=mint, watch=amber, off=coral.
Color _trendColor(String trend) {
  switch (trend) {
    case 'watch':
      return AppColors.accent;
    case 'off':
      return AppColors.brand;
    default:
      return MacroColors.protein;
  }
}

/// "By the numbers" — the data read-out, always visible. One stat row per
/// metric: label, bold value, a one-line interpretation, dot coloured by trend.
class _MetricsBlock extends StatelessWidget {
  final List<ReviewMetric> metrics;
  const _MetricsBlock({required this.metrics});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 14, 15, 4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('BY THE NUMBERS',
              style: text.labelSmall?.copyWith(
                  color: AppColors.inkFaint,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                  fontSize: 9)),
          const SizedBox(height: 14),
          ...metrics.map((m) => _row(context, m)),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, ReviewMetric m) {
    final text = Theme.of(context).textTheme;
    final dim = m.isThin;
    final c = dim ? AppColors.inkFaint : _trendColor(m.trend);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(m.label.toUpperCase(),
                    style: text.labelSmall?.copyWith(
                        color: AppColors.inkMuted,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                        fontSize: 9)),
                const SizedBox(height: 3),
                Text(m.value,
                    style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: dim ? AppColors.inkMuted : AppColors.ink)),
                if (m.read.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(m.read,
                      style: text.bodySmall
                          ?.copyWith(color: AppColors.inkFaint, height: 1.35)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Next steps" — the prescription, as a coral-numbered checklist.
class _ActionPlanCard extends StatelessWidget {
  final List<String> items;
  const _ActionPlanCard({required this.items});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 14, 15, 6),
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
              Icon(Icons.flag_rounded, size: 15, color: AppColors.brand),
              const SizedBox(width: 8),
              Text('NEXT STEPS',
                  style: text.labelSmall?.copyWith(
                      color: AppColors.brand,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      fontSize: 9)),
            ],
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < items.length; i++)
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
                    child: Text(items[i],
                        style: text.bodyMedium?.copyWith(
                            height: 1.4, fontWeight: FontWeight.w500)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// "Outlook" — the hedged forward projection, visually quieted with an
/// ESTIMATE tag so it never reads as a promise.
class _OutlookCard extends StatelessWidget {
  final String text;
  const _OutlookCard({required this.text});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 12, 15, 14),
      decoration: BoxDecoration(
        color: AppColors.fieldFill,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.timeline_rounded, size: 15, color: AppColors.inkMuted),
              const SizedBox(width: 8),
              Text('OUTLOOK',
                  style: t.labelSmall?.copyWith(
                      color: AppColors.inkFaint,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      fontSize: 9)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.inkFaint.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('ESTIMATE',
                    style: t.labelSmall?.copyWith(
                        color: AppColors.inkMuted,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                        fontSize: 8)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(text,
              style: t.bodyMedium?.copyWith(
                  color: AppColors.inkMuted,
                  height: 1.5,
                  fontStyle: FontStyle.italic)),
        ],
      ),
    );
  }
}

class _ReviewList extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final List<String> items;
  const _ReviewList(
      {required this.label,
      required this.icon,
      required this.color,
      required this.items});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 14, 15, 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: text.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                  fontSize: 9)),
          const SizedBox(height: 10),
          ...items.map((s) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 16, color: color),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(s,
                          style: text.bodyMedium
                              ?.copyWith(height: 1.45, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}

class _ReviewError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ReviewError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, size: 40, color: AppColors.inkMuted),
            const SizedBox(height: 14),
            Text(message,
                textAlign: TextAlign.center,
                style: text.bodyMedium
                    ?.copyWith(color: AppColors.inkMuted, height: 1.4)),
            const SizedBox(height: 20),
            GradientButton(
                label: 'Try again', icon: Icons.refresh_rounded, onPressed: onRetry),
          ],
        ),
      ),
    );
  }
}
