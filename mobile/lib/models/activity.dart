/// One suggested activity within an [ActivityPlan].
class ActivitySuggestion {
  final String day; // weekday label for a week plan; empty for a single day
  final String name;
  final int minutes;
  final String intensity; // light | moderate | vigorous
  final int calories;
  final String note;

  ActivitySuggestion({
    required this.day,
    required this.name,
    required this.minutes,
    required this.intensity,
    required this.calories,
    required this.note,
  });

  static int _toInt(dynamic v) =>
      v is int ? v : (v is num ? v.round() : int.tryParse('${v ?? ''}') ?? 0);

  factory ActivitySuggestion.fromJson(Map<String, dynamic> j) => ActivitySuggestion(
        day: (j['day'] ?? '').toString().trim(),
        name: (j['name'] ?? '').toString(),
        minutes: _toInt(j['minutes']),
        intensity: (j['intensity'] ?? 'moderate').toString(),
        calories: _toInt(j['calories']),
        note: (j['note'] ?? '').toString(),
      );
}

/// AI activity suggestions for a day or a week, from /api/activity.
class ActivityPlan {
  final String headline;
  final List<ActivitySuggestion> activities;
  final String tip;

  ActivityPlan({required this.headline, required this.activities, required this.tip});

  factory ActivityPlan.fromJson(Map<String, dynamic> j) => ActivityPlan(
        headline: (j['headline'] ?? '').toString(),
        activities: ((j['activities'] as List?) ?? [])
            .map((e) => ActivitySuggestion.fromJson((e as Map).cast<String, dynamic>()))
            .where((a) => a.name.isNotEmpty)
            .toList(),
        tip: (j['tip'] ?? '').toString(),
      );
}
