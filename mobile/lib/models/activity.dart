/// One suggested activity within an [ActivityPlan]. Detailed enough to actually
/// do: ordered [howTo] steps, the kit needed, one key form cue, and why it helps.
class ActivitySuggestion {
  final String day; // weekday label for a week plan; empty for a single day
  final String name;
  final String focus; // what it trains + why it serves the goal
  final int minutes;
  final String intensity; // light | moderate | vigorous
  final int calories;
  final String equipment; // "None — bodyweight only" when there's none
  final List<String> howTo; // ordered execution steps — the "how to do it"
  final String formCue; // the single most important technique cue (may be empty)

  ActivitySuggestion({
    required this.day,
    required this.name,
    required this.focus,
    required this.minutes,
    required this.intensity,
    required this.calories,
    required this.equipment,
    required this.howTo,
    required this.formCue,
  });

  static int _toInt(dynamic v) =>
      v is int ? v : (v is num ? v.round() : int.tryParse('${v ?? ''}') ?? 0);

  static List<String> _strings(dynamic v) => ((v as List?) ?? [])
      .map((e) => '$e'.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  /// A rest / active-recovery day reads differently in the UI (slimmer, calmer).
  bool get isRest {
    final n = name.toLowerCase();
    return n.contains('rest') || n.contains('recovery') || n.contains('off day');
  }

  factory ActivitySuggestion.fromJson(Map<String, dynamic> j) => ActivitySuggestion(
        day: (j['day'] ?? '').toString().trim(),
        name: (j['name'] ?? '').toString(),
        // Fall back to the old single 'note' field for any cached/legacy payload.
        focus: (j['focus'] ?? j['note'] ?? '').toString(),
        minutes: _toInt(j['minutes']),
        intensity: (j['intensity'] ?? 'moderate').toString(),
        calories: _toInt(j['calories']),
        equipment: (j['equipment'] ?? '').toString(),
        howTo: _strings(j['howTo']),
        formCue: (j['formCue'] ?? '').toString(),
      );
}

/// AI activity suggestions for a day or a week, from /api/activity. Carries a
/// shared warm-up/cool-down plus plan-wide progression, safety, and a tip.
class ActivityPlan {
  final String headline;
  final String warmup; // shared warm-up + cool-down, stated once
  final List<ActivitySuggestion> activities;
  final String progression; // how/when to make it harder
  final String safety; // stop-signs + recovery rule
  final String tip; // scheduling / adherence nudge

  ActivityPlan({
    required this.headline,
    required this.warmup,
    required this.activities,
    required this.progression,
    required this.safety,
    required this.tip,
  });

  factory ActivityPlan.fromJson(Map<String, dynamic> j) => ActivityPlan(
        headline: (j['headline'] ?? '').toString(),
        warmup: (j['warmup'] ?? '').toString(),
        activities: ((j['activities'] as List?) ?? [])
            .map((e) => ActivitySuggestion.fromJson((e as Map).cast<String, dynamic>()))
            .where((a) => a.name.isNotEmpty)
            .toList(),
        progression: (j['progression'] ?? '').toString(),
        safety: (j['safety'] ?? '').toString(),
        tip: (j['tip'] ?? '').toString(),
      );
}
