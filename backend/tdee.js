// Deterministic energy + macro targets.
//
// Replaces the LLM's guessed daily calorie number with real math: Mifflin-St
// Jeor BMR × an activity factor gives Total Daily Energy Expenditure (TDEE),
// then the goal turns that into a safety-clamped daily target. Pure functions —
// same inputs give the same output, and the target is *recomputable* each week
// as the user's weight changes, which is what makes the adaptive loop possible.

const KCAL_PER_KG = 7700; // approx energy stored in 1 kg of body mass
const MAX_RATE_KG_WK = 1.0; // safe upper bound on weight change per week

const ACTIVITY = {
  sedentary: 1.2,
  light: 1.375,
  moderate: 1.55,
  active: 1.725,
  very_active: 1.9,
};

// Fallbacks for the optional onboarding fields.
const DEFAULT_AGE = 30;
const DEFAULT_ACTIVITY = 'sedentary';

export function activityFactor(level) {
  return ACTIVITY[String(level || '').toLowerCase()] ?? ACTIVITY[DEFAULT_ACTIVITY];
}

// Mifflin-St Jeor BMR. The `sex` term is the only sex-dependent part of the
// whole pipeline: +5 male, −161 female, −78 (their midpoint) when unspecified.
export function mifflinBmr({ weightKg, heightCm, age = DEFAULT_AGE, sex }) {
  const s = sex === 'male' ? 5 : sex === 'female' ? -161 : -78;
  return 10 * weightKg + 6.25 * heightCm - 5 * age + s;
}

// The lowest daily intake we'll prescribe without medical supervision.
function floorFor(sex) {
  return sex === 'female' ? 1200 : sex === 'male' ? 1500 : 1400;
}

// Goal-aware macro split: protein scaled to bodyweight (higher when changing
// weight, to spare/build muscle), fat ~28% of calories, carbs fill the rest.
export function macrosFor(calorieTarget, weightKg, goal) {
  const proteinPerKg = goal === 'maintain' ? 1.6 : 1.8;
  let protein = Math.round(proteinPerKg * weightKg);
  const maxProtein = Math.round((0.4 * calorieTarget) / 4); // ≤ ~40% of calories
  if (protein > maxProtein) protein = maxProtein;
  const fat = Math.round((0.28 * calorieTarget) / 9);
  const carbs = Math.max(0, Math.round((calorieTarget - protein * 4 - fat * 9) / 4));
  return { protein, carbs, fat };
}

/// The full computation. Returns resting/total burn, the goal-adjusted daily
/// calorie target (safety-clamped), a macro split, the implied weekly rate, and
/// any safety warnings. Pass `calorieOverride` to skip the goal math with a
/// caller-supplied target — that's the hook the weekly re-target loop uses to
/// feed back the adapted number instead of re-deriving from the start weight.
export function computeTargets(input) {
  const {
    weightKg,
    heightCm,
    age = DEFAULT_AGE,
    sex,
    activityLevel = DEFAULT_ACTIVITY,
    goal,
    targetWeightKg,
    targetDays,
    calorieOverride,
  } = input;

  const bmr = Math.round(mifflinBmr({ weightKg, heightCm, age, sex }));
  const tdee = Math.round(bmr * activityFactor(activityLevel));

  const resolvedGoal =
    goal ||
    (targetWeightKg < weightKg ? 'lose' : targetWeightKg > weightKg ? 'gain' : 'maintain');

  const warnings = [];
  let calorieTarget;
  let rateKgPerWeek = 0;

  if (calorieOverride != null) {
    calorieTarget = Math.round(calorieOverride);
  } else if (resolvedGoal === 'maintain') {
    calorieTarget = tdee;
  } else {
    const dir = resolvedGoal === 'gain' ? 1 : -1;
    const totalDeltaKg = Math.abs((targetWeightKg ?? weightKg) - weightKg);
    const weeks = Math.max(1, targetDays / 7);
    let rate = totalDeltaKg / weeks; // kg/week magnitude

    // Safe ceiling: the lesser of 1 kg/week and ~1% of bodyweight, so a small
    // user isn't paced faster than is safe for their size (1 kg/wk is ~1.8%/wk
    // for a 55 kg person — above the recommended ceiling).
    const maxRate = Math.min(MAX_RATE_KG_WK, 0.01 * weightKg);
    if (rate > maxRate) {
      warnings.push(
        `Requested ${rate.toFixed(2)} kg/week exceeds the safe ${maxRate.toFixed(2)} kg/week; ` +
          `planning for the safe maximum (~${(maxRate * weeks).toFixed(1)} kg over ${targetDays} days).`,
      );
      rate = maxRate;
    }
    const dailyDelta = (rate * KCAL_PER_KG) / 7; // kcal/day
    calorieTarget = Math.round(tdee + dir * dailyDelta);
    rateKgPerWeek = dir * rate;
  }

  // Never prescribe below the safe floor.
  const floor = floorFor(sex);
  let floorApplied = false;
  if (calorieTarget < floor) {
    calorieTarget = floor;
    floorApplied = true;
    if (resolvedGoal === 'lose') {
      const achievableDeficit = Math.max(0, tdee - calorieTarget);
      rateKgPerWeek = -((achievableDeficit * 7) / KCAL_PER_KG);
      warnings.push(
        `Target raised to the ${floor} kcal/day safe floor — loss will be slower than requested.`,
      );
    }
  }

  const defaultsUsed = [];
  if (input.age == null) defaultsUsed.push('age');
  if (!input.sex) defaultsUsed.push('sex');
  if (!input.activityLevel) defaultsUsed.push('activity');

  return {
    bmr,
    tdee,
    goal: resolvedGoal,
    calorieTarget,
    macros: macrosFor(calorieTarget, weightKg, resolvedGoal),
    rateKgPerWeek: Number(rateKgPerWeek.toFixed(2)),
    floorApplied,
    assumptions: { age, sex: sex || 'unspecified', activityLevel },
    defaultsUsed,
    warnings,
  };
}
