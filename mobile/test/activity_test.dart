import 'package:flutter_test/flutter_test.dart';
import 'package:diet_planner/models/activity.dart';

void main() {
  test('ActivityPlan.fromJson parses a detailed day plan and drops nameless rows', () {
    final p = ActivityPlan.fromJson({
      'headline': 'A light day to start.',
      'warmup': 'Before: 5 min march + arm circles. After: 2 min easy walk.',
      'activities': [
        {
          'day': '',
          'name': 'Brisk walk',
          'focus': 'Zone-2 cardio — burns fat without stressing joints',
          'minutes': 30,
          'intensity': 'moderate',
          'calories': 150,
          'equipment': 'Treadmill or any flat route',
          'howTo': ['Walk 25 min at a brisk pace', 'Cool down 5 min slow'],
          'formCue': 'Keep a pace where talking is a little hard',
        },
        {'day': '', 'name': '', 'minutes': 10, 'intensity': 'light', 'calories': 0}, // dropped
      ],
      'progression': 'Add 5 min when it feels easy twice running.',
      'safety': 'Stop on chest pain or dizziness; hydrate.',
      'tip': 'Walk right after dinner so it never slips.',
    });
    expect(p.headline, 'A light day to start.');
    expect(p.warmup, contains('Before'));
    expect(p.progression, contains('Add 5 min'));
    expect(p.safety, contains('chest pain'));
    expect(p.activities.length, 1);
    final a = p.activities.single;
    expect(a.name, 'Brisk walk');
    expect(a.focus, contains('Zone-2'));
    expect(a.minutes, 30);
    expect(a.intensity, 'moderate');
    expect(a.calories, 150);
    expect(a.equipment, 'Treadmill or any flat route');
    expect(a.howTo, hasLength(2));
    expect(a.howTo.first, 'Walk 25 min at a brisk pace');
    expect(a.formCue, contains('talking'));
    expect(a.day, isEmpty);
    expect(p.tip, 'Walk right after dinner so it never slips.');
  });

  test('week plan keeps day labels and flags rest days', () {
    final p = ActivityPlan.fromJson({
      'headline': 'Your week',
      'warmup': 'Standard warm-up.',
      'activities': [
        {'day': 'Mon', 'name': 'Walk', 'minutes': 30, 'intensity': 'moderate', 'calories': 150, 'howTo': ['Walk 30 min']},
        {'day': 'Tue', 'name': 'Active recovery', 'minutes': 15, 'intensity': 'light', 'calories': 40, 'howTo': ['Gentle stretch'], 'formCue': ''},
      ],
      'tip': 'Consistency beats intensity.',
    });
    expect(p.activities.map((a) => a.day), ['Mon', 'Tue']);
    expect(p.activities[1].name, 'Active recovery');
    expect(p.activities[0].isRest, isFalse);
    expect(p.activities[1].isRest, isTrue);
  });

  test('legacy note falls back into focus; missing/garbage fields degrade gracefully', () {
    // Old payloads used a single "note" string — it should still populate focus.
    final legacy = ActivitySuggestion.fromJson(
        {'name': 'Jog', 'minutes': '20', 'note': 'Easy pace.'});
    expect(legacy.minutes, 20); // string coerced
    expect(legacy.intensity, 'moderate'); // default
    expect(legacy.focus, 'Easy pace.'); // note -> focus fallback
    expect(legacy.howTo, isEmpty);
    expect(legacy.formCue, isEmpty);

    final p = ActivityPlan.fromJson({'headline': 'Hi'});
    expect(p.activities, isEmpty);
    expect(p.tip, '');
    expect(p.warmup, '');
  });
}
