import 'package:flutter_test/flutter_test.dart';
import 'package:diet_planner/models/tracking.dart';

ExtraItem _e(String id, String name, int kcal) =>
    ExtraItem(id: id, dayIndex: 0, name: name, calories: kcal);

void main() {
  test('recentExtras: most-recent first, deduped by name, capped', () {
    var t = PlanTracking();
    // Logged in this order (oldest → newest).
    for (final e in [
      _e('1', 'Coffee', 90),
      _e('2', 'Biscuit', 100),
      _e('3', 'Coffee', 95), // a later coffee (different calories)
      _e('4', 'Tea', 60),
    ]) {
      t = t.withExtra(e);
    }

    final recent = t.recentExtras();
    // Newest-first, one entry per name (the latest Coffee wins).
    expect(recent.map((e) => e.name).toList(), ['Tea', 'Coffee', 'Biscuit']);
    expect(recent.firstWhere((e) => e.name == 'Coffee').calories, 95);
  });

  test('recentExtras respects the limit', () {
    var t = PlanTracking();
    for (var i = 0; i < 10; i++) {
      t = t.withExtra(_e('$i', 'Item$i', 50));
    }
    expect(t.recentExtras(limit: 4).length, 4);
    expect(t.recentExtras(limit: 4).first.name, 'Item9'); // newest first
  });

  test('recentExtras ignores blank names and is empty with no history', () {
    expect(PlanTracking().recentExtras(), isEmpty);
    final t = PlanTracking().withExtra(_e('1', '   ', 10));
    expect(t.recentExtras(), isEmpty);
  });
}
