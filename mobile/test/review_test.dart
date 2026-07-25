import 'package:flutter_test/flutter_test.dart';
import 'package:diet_planner/models/review.dart';

void main() {
  test('Review.fromJson parses lists and drops blanks', () {
    final r = Review.fromJson({
      'headline': 'Strong start!',
      'status': 'on_track',
      'summary': 'Down 2 kg with 71% adherence.',
      'doingWell': ['Consistent weigh-ins', '', '  Good adherence  '],
      'improve': ['Log your snacks'],
    });
    expect(r.headline, 'Strong start!');
    expect(r.status, 'on_track');
    expect(r.doingWell, ['Consistent weigh-ins', 'Good adherence']);
    expect(r.improve, ['Log your snacks']);
  });

  test('missing fields degrade gracefully', () {
    final r = Review.fromJson({'headline': 'Hi'});
    expect(r.status, 'on_track', reason: 'defaults to a neutral status');
    expect(r.summary, '');
    expect(r.doingWell, isEmpty);
    expect(r.improve, isEmpty);
  });
}
