/// An AI-written progress review, from /api/review.
class Review {
  final String headline;
  final String status; // early | on_track | ahead | behind | too_fast
  final String summary;
  final List<String> doingWell;
  final List<String> improve;

  Review({
    required this.headline,
    required this.status,
    required this.summary,
    required this.doingWell,
    required this.improve,
  });

  static List<String> _strings(dynamic v) => ((v as List?) ?? [])
      .map((e) => '$e'.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  factory Review.fromJson(Map<String, dynamic> j) => Review(
        headline: (j['headline'] ?? '').toString(),
        status: (j['status'] ?? 'on_track').toString(),
        summary: (j['summary'] ?? '').toString(),
        doingWell: _strings(j['doingWell']),
        improve: _strings(j['improve']),
      );
}
