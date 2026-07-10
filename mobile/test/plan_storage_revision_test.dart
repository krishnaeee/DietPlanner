import 'package:diet_planner/models/diet_plan.dart';
import 'package:diet_planner/services/plan_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

DietPlan _plan() => DietPlan(
      summary: 's',
      dailyCalorieTarget: 1800,
      days: [DayPlan(day: 1, totalCalories: 0, meals: const [])],
      requestedDays: 7,
      plannedDays: 1,
      truncated: true,
      model: 'test',
    );

StoredPlan _stored(String id) => StoredPlan(
      id: id,
      name: id,
      slot: 0,
      plan: _plan(),
      location: 'Pollachi',
      startDate: DateTime.now(),
      remindersScheduled: false,
      scheduledCount: 0,
      savedAt: DateTime.now(),
    );

void main() {
  // The home list relies on PlanStorage.revision firing on every write so a plan
  // saved in the background (after its creating screen was popped) still shows.
  test('PlanStorage.revision notifies listeners on upsert and delete', () async {
    SharedPreferences.setMockInitialValues({});

    var notifications = 0;
    void listener() => notifications++;
    PlanStorage.revision.addListener(listener);

    final before = PlanStorage.revision.value;
    await PlanStorage.upsert(_stored('a'));
    expect(PlanStorage.revision.value, greaterThan(before),
        reason: 'upsert should bump the revision');
    expect(notifications, greaterThanOrEqualTo(1));

    final afterUpsert = PlanStorage.revision.value;
    await PlanStorage.delete('a');
    expect(PlanStorage.revision.value, greaterThan(afterUpsert),
        reason: 'delete should bump the revision');

    PlanStorage.revision.removeListener(listener);
  });
}
