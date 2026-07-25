/// One data read-out inside a [Review] — a figure the user can trust because it
/// is derived only from their own logged numbers.
class ReviewMetric {
  final String label; // e.g. "Pace", "Goal progress"
  final String value; // e.g. "0.6 kg/week" or "Not enough data yet"
  final String read; // one-line interpretation that adds meaning
  final String trend; // good | watch | off — colors the row

  ReviewMetric({
    required this.label,
    required this.value,
    required this.read,
    required this.trend,
  });

  /// The model emits this literal when a metric can't be computed yet.
  bool get isThin => value.trim().toLowerCase() == 'not enough data yet';

  factory ReviewMetric.fromJson(Map<String, dynamic> j) => ReviewMetric(
        label: (j['label'] ?? '').toString(),
        value: (j['value'] ?? '').toString(),
        read: (j['read'] ?? '').toString(),
        trend: (j['trend'] ?? 'good').toString(),
      );
}

/// An AI-written progress review, from /api/review. Detailed: a status, a
/// narrative summary, concrete metric read-outs, what's going well, what to fix,
/// a concrete action plan, and a hedged outlook.
class Review {
  final String headline;
  final String status; // early | on_track | ahead | behind | too_fast
  final String summary;
  final List<ReviewMetric> metrics;
  final List<String> doingWell;
  final List<String> improve; // diagnosis — what's off
  final List<String> actionPlan; // prescription — concrete next steps
  final String outlook; // hedged forward trajectory

  Review({
    required this.headline,
    required this.status,
    required this.summary,
    required this.metrics,
    required this.doingWell,
    required this.improve,
    required this.actionPlan,
    required this.outlook,
  });

  static List<String> _strings(dynamic v) => ((v as List?) ?? [])
      .map((e) => '$e'.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  static List<ReviewMetric> _metrics(dynamic v) => ((v as List?) ?? [])
      .whereType<Map>()
      .map((e) => ReviewMetric.fromJson(e.cast<String, dynamic>()))
      .where((m) => m.label.isNotEmpty || m.value.isNotEmpty)
      .toList();

  factory Review.fromJson(Map<String, dynamic> j) => Review(
        headline: (j['headline'] ?? '').toString(),
        status: (j['status'] ?? 'on_track').toString(),
        summary: (j['summary'] ?? '').toString(),
        metrics: _metrics(j['metrics']),
        doingWell: _strings(j['doingWell']),
        improve: _strings(j['improve']),
        actionPlan: _strings(j['actionPlan']),
        outlook: (j['outlook'] ?? '').toString(),
      );
}
