// The adaptive re-target decision — the brain of the weekly loop.
//
// Runs when a user generates the next week of a longer plan. It recomputes the
// calorie target from the user's CURRENT weight (not the start weight) and
// re-paces to reach the original target by the original deadline. That single
// recompute naturally handles the three things a static target can't:
//   • metabolic slowdown — a lighter body has a lower TDEE, so the target drifts
//     down as weight falls, keeping the deficit real instead of shrinking to zero;
//   • falling behind — less time left to the deadline ⇒ a steeper (lower) target;
//   • getting ahead — near the target already ⇒ a gentler target toward maintenance.
//
// Pure and deterministic. The observed weigh-in trend is used only to LABEL the
// decision (plateau / too_fast / on_track) for the audit log and UX — the number
// itself comes from the recompute.

import { computeTargets } from './tdee.js';

// A meaningful move; smaller deltas aren't worth a new audit row.
const MIN_DELTA_KCAL = 25;

export function decideRetarget(input) {
  const {
    startWeightKg,
    currentWeightKg,
    heightCm,
    age,
    sex,
    activityLevel,
    goal,
    targetWeightKg,
    targetDays,
    startDay = 1,
    weighIns = [],
    currentTarget,
  } = input;

  // Days already lived through (days 1..startDay-1 are done); re-pace over what
  // remains, floored at a week so the final stretch never demands an unsafe rate.
  const elapsedDays = Math.max(0, Math.round(startDay) - 1);
  const remainingDays = Math.max(7, targetDays - elapsedDays);

  const t = computeTargets({
    weightKg: currentWeightKg,
    heightCm,
    age,
    sex,
    activityLevel,
    goal,
    targetWeightKg,
    targetDays: remainingDays,
  });

  const trendKgPerWeek = weeklyTrend(weighIns);
  const reason = classify(goal, trendKgPerWeek);
  const changed =
    currentTarget == null || Math.abs(t.calorieTarget - currentTarget) >= MIN_DELTA_KCAL;

  return {
    newTarget: t.calorieTarget,
    macros: t.macros,
    tdee: t.tdee,
    reason,
    observedWeightKg: currentWeightKg,
    trendKgPerWeek,
    remainingDays,
    warnings: t.warnings,
    changed,
  };
}

// Signed kg/week from the earliest and latest dated weigh-ins. Sorts by date
// first, so an out-of-order series can't mislabel the trend. Returns null when
// there aren't two usable, dated points to measure a rate from.
export function weeklyTrend(weighIns) {
  const pts = (weighIns || [])
    .filter((w) => w && w.date != null && isFinite(Number(w.kg)))
    .slice()
    .sort((x, y) => new Date(x.date).getTime() - new Date(y.date).getTime());
  if (pts.length < 2) return null;
  const a = pts[0];
  const b = pts[pts.length - 1];
  const weeks = (new Date(b.date).getTime() - new Date(a.date).getTime()) / (7 * 86400000);
  if (!(weeks > 0)) return null;
  return Number(((Number(b.kg) - Number(a.kg)) / weeks).toFixed(2));
}

// Labels the decision from the observed trend vs. what the goal expects. Only a
// label for the audit/UX — never changes the computed number.
function classify(goal, trend) {
  if (goal === 'maintain' || trend == null) return 'scheduled';
  if (goal === 'lose') {
    if (trend >= -0.1) return 'plateau'; // not actually losing
    if (trend <= -1.0) return 'too_fast'; // faster than the safe ceiling
    return 'on_track';
  }
  if (goal === 'gain') {
    if (trend <= 0.1) return 'plateau';
    if (trend >= 1.0) return 'too_fast';
    return 'on_track';
  }
  return 'scheduled';
}
