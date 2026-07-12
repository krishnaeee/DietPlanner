import 'package:flutter_test/flutter_test.dart';
import 'package:diet_planner/models/diet_plan.dart';
import 'package:diet_planner/services/plan_storage.dart';
import 'package:diet_planner/services/sync_service.dart';

DietPlan _plan() => DietPlan(
      summary: 's',
      dailyCalorieTarget: 1581,
      dailyProteinTarget: 135,
      dailyCarbsTarget: 150,
      dailyFatTarget: 49,
      days: [DayPlan(day: 1, totalCalories: 1581, meals: const [])],
      requestedDays: 168,
      plannedDays: 7,
      truncated: true,
      model: 'test',
    );

StoredPlan _stored() => StoredPlan(
      id: 'plan_1',
      name: 'Plan 1',
      slot: 0,
      plan: _plan(),
      location: 'pollachi',
      startDate: DateTime(2026, 7, 12),
      remindersScheduled: true,
      scheduledCount: 3,
      savedAt: DateTime(2026, 7, 12),
      startWeightKg: 75,
      targetWeightKg: 65,
      repeatForever: true,
      request: {
        'goal': 'lose', 'weightKg': 75, 'targetWeightKg': 65, 'heightCm': 175,
        'age': 30, 'sex': 'male', 'activityLevel': 'sedentary',
        'targetDays': 168, 'location': 'pollachi', 'dietaryPreference': 'veg',
      },
    );

void main() {
  final sync = SyncService.instance;

  test('planBody carries the required fields + state the server needs', () {
    final b = sync.planBody(_stored());
    // Server-required.
    expect(b['name'], 'Plan 1');
    expect(b['slot'], 0);
    expect(b['goal'], 'lose');
    expect(b['targetDays'], 168);
    expect(b['plan'], isA<Map>());
    // Stats pulled from the saved request.
    expect(b['heightCm'], 175);
    expect(b['age'], 30);
    expect(b['sex'], 'male');
    expect(b['activityLevel'], 'sedentary');
    expect(b['startWeightKg'], 75);
    expect(b['targetWeightKg'], 65);
    // Targets come from the plan so current_calorie_target seeds right.
    expect(b['currentCalorieTarget'], 1581);
    expect((b['currentMacros'] as Map)['protein'], 135);
    expect(b['startDate'], '2026-07-12');
    expect(b['remindersScheduled'], true);
    expect(b['repeatForever'], true);
  });

  test('storedFromServer reconstructs a StoredPlan from a server row', () {
    // Shape the backend's mapPlanRow returns (JSON-decoded).
    final serverRow = {
      'id': 'plan_1',
      'name': 'Renamed',
      'slot': 2,
      'plan': _plan().toResponseJson(),
      'request': {'goal': 'lose'},
      'location': 'pollachi',
      'startDate': '2026-07-12T00:00:00.000Z',
      'startWeightKg': 75.0,
      'targetWeightKg': 65.0,
      'remindersScheduled': true,
      'repeatForever': true,
    };
    final sp = sync.storedFromServer(serverRow);
    expect(sp, isNotNull);
    expect(sp!.id, 'plan_1');
    expect(sp.name, 'Renamed');
    expect(sp.slot, 2);
    expect(sp.plan.dailyCalorieTarget, 1581);
    expect(sp.location, 'pollachi');
    expect(sp.startDate.year, 2026);
    expect(sp.startWeightKg, 75);
    expect(sp.targetWeightKg, 65);
    expect(sp.remindersScheduled, true);
    expect(sp.repeatForever, true);
  });

  test('storedFromServer returns null on a malformed row (no blob)', () {
    expect(sync.storedFromServer({'id': 'x', 'name': 'x'}), isNull);
  });
}
