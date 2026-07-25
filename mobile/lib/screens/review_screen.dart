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
  bool _loading = true;
  String? _error;

  StoredPlan get _sp => widget.stored;
  PlanTracking get _t => widget.tracking;

  @override
  void initState() {
    super.initState();
    _fetch();
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
        if (review.doingWell.isNotEmpty) ...[
          const SizedBox(height: 24),
          _ReviewList(
              label: 'DOING WELL',
              icon: Icons.check_circle_rounded,
              color: MacroColors.protein,
              items: review.doingWell),
        ],
        if (review.improve.isNotEmpty) ...[
          const SizedBox(height: 18),
          _ReviewList(
              label: 'FOCUS ON',
              icon: Icons.trending_up_rounded,
              color: AppColors.brand,
              items: review.improve),
        ],
      ],
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
