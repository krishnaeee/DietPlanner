import 'package:flutter_test/flutter_test.dart';
import 'package:diet_planner/screens/add_plan_screen.dart';

void main() {
  test('merges chip picks with free text', () {
    expect(mergeAllergies({'Peanuts', 'Milk'}, 'prawns, cashew'),
        ['Peanuts', 'Milk', 'prawns', 'cashew']);
  });

  test('trims, drops blanks, and ignores stray commas', () {
    expect(mergeAllergies(const [], '  prawns ,, , cashew  '), ['prawns', 'cashew']);
    expect(mergeAllergies(const [], ''), isEmpty);
    expect(mergeAllergies(const [], '   '), isEmpty);
  });

  test('de-dupes case-insensitively, keeping the first spelling', () {
    // Tapping the Milk chip and then also typing "milk" must send it once.
    expect(mergeAllergies({'Milk'}, 'milk, MILK, eggs'), ['Milk', 'eggs']);
  });

  test('chips alone and text alone both work', () {
    expect(mergeAllergies({'Sesame'}, ''), ['Sesame']);
    expect(mergeAllergies(const [], 'Sesame'), ['Sesame']);
  });
}
