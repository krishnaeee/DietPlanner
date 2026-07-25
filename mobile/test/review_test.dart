import 'package:flutter_test/flutter_test.dart';
import 'package:diet_planner/models/review.dart';

void main() {
  test('Review.fromJson parses a detailed review: metrics, action plan, outlook', () {
    final r = Review.fromJson({
      'headline': 'Strong start!',
      'status': 'on_track',
      'summary': 'Down 2 kg with 82% adherence.',
      'metrics': [
        {'label': 'Pace', 'value': '0.6 kg/week', 'read': 'inside the safe zone', 'trend': 'good'},
        {'label': 'Extras', 'value': 'Not enough data yet', 'read': '', 'trend': 'watch'},
        {'label': '', 'value': '', 'read': '', 'trend': 'good'}, // dropped (blank)
      ],
      'doingWell': ['Consistent weigh-ins', '', '  Good adherence  '],
      'improve': ['Protein missed on 3 days'],
      'actionPlan': ['Add a boiled egg at breakfast', '  '],
      'outlook': 'If pace holds you\'d near 68 kg by day 40 — an estimate.',
    });
    expect(r.headline, 'Strong start!');
    expect(r.status, 'on_track');
    expect(r.doingWell, ['Consistent weigh-ins', 'Good adherence']);
    expect(r.improve, ['Protein missed on 3 days']);
    expect(r.actionPlan, ['Add a boiled egg at breakfast']); // blank dropped
    expect(r.outlook, contains('estimate'));

    expect(r.metrics, hasLength(2)); // blank metric dropped
    expect(r.metrics.first.label, 'Pace');
    expect(r.metrics.first.trend, 'good');
    expect(r.metrics.first.isThin, isFalse);
    expect(r.metrics[1].isThin, isTrue); // "Not enough data yet"
  });

  test('missing fields degrade gracefully', () {
    final r = Review.fromJson({'headline': 'Hi'});
    expect(r.status, 'on_track', reason: 'defaults to a neutral status');
    expect(r.summary, '');
    expect(r.metrics, isEmpty);
    expect(r.doingWell, isEmpty);
    expect(r.improve, isEmpty);
    expect(r.actionPlan, isEmpty);
    expect(r.outlook, '');
  });
}
