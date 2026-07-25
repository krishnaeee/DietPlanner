import 'package:flutter_test/flutter_test.dart';
import 'package:diet_planner/models/tracking.dart';

ExtraItem _item(String id, int day, String name, int kcal, {int p = 0}) =>
    ExtraItem(id: id, dayIndex: day, name: name, calories: kcal, protein: p);

void main() {
  test('extrasFor filters to one plan day, extraCaloriesFor sums it', () {
    final t = PlanTracking(extras: [
      _item('a', 0, 'Tea with milk', 60),
      _item('b', 0, 'Biscuits (2)', 100),
      _item('c', 1, 'Samosa', 260),
    ]);
    expect(t.extrasFor(0).map((e) => e.name), ['Tea with milk', 'Biscuits (2)']);
    expect(t.extraCaloriesFor(0), 160);
    expect(t.extraCaloriesFor(1), 260);
    expect(t.extraCaloriesFor(2), 0, reason: 'a day with nothing logged');
  });

  test('withExtra adds and withoutExtra removes by id', () {
    var t = PlanTracking();
    t = t.withExtra(_item('a', 0, 'Coffee with milk', 90));
    t = t.withExtra(_item('b', 0, 'Banana', 105));
    expect(t.extras.length, 2);
    expect(t.extraCaloriesFor(0), 195);

    t = t.withoutExtra('a');
    expect(t.extras.single.name, 'Banana');
    // Removing an unknown id is a no-op, not a crash.
    expect(t.withoutExtra('nope').extras.length, 1);
  });

  test('extras survive the json round-trip', () {
    final t = PlanTracking(extras: [_item('a', 3, 'Handful of nuts', 170, p: 6)]);
    final back = PlanTracking.fromJson(t.toJson());
    expect(back.extras.length, 1);
    final e = back.extras.single;
    expect(e.id, 'a');
    expect(e.dayIndex, 3);
    expect(e.name, 'Handful of nuts');
    expect(e.calories, 170);
    expect(e.protein, 6);
  });

  test('older saved tracking with no extras still loads', () {
    final legacy = {'weighIns': [], 'mealsDone': [], 'waterByDate': {}};
    expect(PlanTracking.fromJson(legacy).extras, isEmpty);
  });

  test('logging an extra counts as an active day', () {
    final start = DateTime(2026, 7, 12);
    // Day index 2 => 14 July.
    final t = PlanTracking(extras: [_item('a', 2, 'Tea with milk', 60)]);
    expect(t.activeDays(start), contains('2026-07-14'));
  });
}
