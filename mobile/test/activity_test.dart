import 'package:flutter_test/flutter_test.dart';
import 'package:diet_planner/models/activity.dart';

void main() {
  test('ActivityPlan.fromJson parses a day plan and drops nameless rows', () {
    final p = ActivityPlan.fromJson({
      'headline': 'A light day to start.',
      'activities': [
        {'day': '', 'name': 'Brisk walk', 'minutes': 30, 'intensity': 'moderate', 'calories': 150, 'note': 'Keep a steady pace.'},
        {'day': '', 'name': '', 'minutes': 10, 'intensity': 'light', 'calories': 0, 'note': ''}, // dropped
      ],
      'tip': 'Warm up first.',
    });
    expect(p.headline, 'A light day to start.');
    expect(p.activities.length, 1);
    final a = p.activities.single;
    expect(a.name, 'Brisk walk');
    expect(a.minutes, 30);
    expect(a.intensity, 'moderate');
    expect(a.calories, 150);
    expect(a.day, isEmpty);
    expect(p.tip, 'Warm up first.');
  });

  test('week plan keeps day labels', () {
    final p = ActivityPlan.fromJson({
      'headline': 'Your week',
      'activities': [
        {'day': 'Mon', 'name': 'Walk', 'minutes': 30, 'intensity': 'moderate', 'calories': 150, 'note': ''},
        {'day': 'Tue', 'name': 'Rest', 'minutes': 0, 'intensity': 'light', 'calories': 0, 'note': 'Active recovery.'},
      ],
      'tip': 'Consistency beats intensity.',
    });
    expect(p.activities.map((a) => a.day), ['Mon', 'Tue']);
    expect(p.activities[1].name, 'Rest');
  });

  test('missing/garbage fields degrade gracefully', () {
    final p = ActivityPlan.fromJson({'headline': 'Hi'});
    expect(p.activities, isEmpty);
    expect(p.tip, '');
    final a = ActivitySuggestion.fromJson({'name': 'Jog', 'minutes': '20'});
    expect(a.minutes, 20); // string coerced
    expect(a.intensity, 'moderate'); // default
  });
}
