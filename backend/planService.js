import {
  buildPrompt,
  buildMealPrompt,
  buildRecipePrompt,
  buildReviewPrompt,
  buildActivityPrompt,
  MEAL_SCHEMA,
  RECIPE_SCHEMA,
  REVIEW_SCHEMA,
  ACTIVITY_SCHEMA,
} from './planSchema.js';
import { getProvider } from './providers.js';
import { computeTargets } from './tdee.js';

// EFFORT only applies to providers that support reasoning effort (Anthropic);
// others ignore it. MODEL overrides the active provider's default model.
const EFFORT = process.env.EFFORT || 'medium'; // low | medium | high | max
const MAX_TOKENS = Number(process.env.MAX_TOKENS || 32000);

// Cap how many days we ask the model to detail in one call, to keep the
// response within token limits AND generation time under the app's timeout.
// Longer goals still plan up to this many days; the summary notes the cap.
// (Lowered to 7 — a full 14-day Opus plan can run past the client timeout.)
export const MAX_PLAN_DAYS = Number(process.env.MAX_PLAN_DAYS || 7);

// Tolerant JSON extraction: prefer clean parse, otherwise strip markdown
// fences and grab the outermost {...}. Guards against the model wrapping JSON.
function parsePlanJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    const cleaned = text.replace(/```json\s*/gi, '').replace(/```/g, '').trim();
    const start = cleaned.indexOf('{');
    const end = cleaned.lastIndexOf('}');
    if (start !== -1 && end !== -1 && end > start) {
      return JSON.parse(cleaned.slice(start, end + 1));
    }
    throw new Error('Model response was not valid JSON.');
  }
}

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/// Safety net for allergies. buildPrompt states them as a hard constraint, but a
/// model can still slip, so we keyword-scan the returned dishes, descriptions and
/// ingredient names. These are FLAGS, not verdicts — a dairy allergy will also
/// match "coconut milk" — so the client should surface them as "check these",
/// letting the user (who knows their allergy) judge. For an allergy, a false
/// positive is a far better failure mode than a silent miss.
export function findAllergenFlags(plan, allergies) {
  if (!allergies?.length || !plan?.days?.length) return [];
  const terms = allergies.map((a) => ({
    allergen: a,
    re: new RegExp(`\\b${escapeRe(String(a).toLowerCase())}`, 'i'),
  }));
  const flags = [];
  for (const day of plan.days) {
    for (const meal of day.meals || []) {
      const fields = [
        meal.dish,
        meal.description,
        ...(meal.ingredients || []).map((i) => i?.name),
      ].filter(Boolean);
      for (const t of terms) {
        const matched = fields.find((f) => t.re.test(String(f)));
        if (matched) {
          flags.push({
            day: day.day,
            meal: meal.name,
            dish: meal.dish,
            allergen: t.allergen,
            matched: String(matched),
          });
        }
      }
    }
  }
  return flags;
}

export async function generatePlan(input) {
  // Continuation support: generate days [startDay .. startDay+plannedDays-1] of
  // a longer journey. startDay defaults to 1 (a fresh first week).
  const startDay = Math.max(1, Math.round(input.startDay || 1));
  const remaining = Math.max(1, input.targetDays - (startDay - 1));
  const plannedDays = Math.min(remaining, MAX_PLAN_DAYS);

  // Deterministic energy/macro target — the authoritative number the plan is
  // built around. `input.calorieOverride` (set by the weekly re-target loop)
  // wins over the goal math when present.
  const targets = computeTargets(input);
  console.log(
    `[gen] targets: BMR ${targets.bmr} · TDEE ${targets.tdee} · ${targets.calorieTarget} kcal/day ` +
      `(${targets.goal}, ${targets.rateKgPerWeek} kg/wk)${targets.warnings.length ? ' ⚠ ' + targets.warnings.join(' ') : ''}`,
  );

  const { system, user } = buildPrompt({ ...input, startDay, targets }, plannedDays);
  const provider = getProvider();

  console.log(
    `[gen] calling ${provider.name}:${provider.model} (effort=${EFFORT}, maxTokens=${MAX_TOKENS}) for ${plannedDays} day(s) from day ${startDay}…`,
  );
  const t0 = Date.now();
  // Heartbeat so you can see it's still working (vs. hung) in the console.
  const heartbeat = setInterval(() => {
    console.log(`[gen]   …still generating (${((Date.now() - t0) / 1000).toFixed(0)}s)`);
  }, 10000);

  let result;
  try {
    result = await provider.generate({ system, user, maxTokens: MAX_TOKENS, effort: EFFORT });
  } catch (err) {
    clearInterval(heartbeat);
    console.error(`[gen] ✗ ${provider.name} call failed after ${((Date.now() - t0) / 1000).toFixed(1)}s:`, err?.message);
    throw err;
  }
  clearInterval(heartbeat);

  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  console.log(
    `[gen] model responded in ${secs}s — out_tokens=${result.outTokens ?? '?'}`,
  );

  let plan;
  try {
    plan = parsePlanJson(result.text);
  } catch (e) {
    console.error('[gen] JSON parse failed. First 300 chars of output:\n', result.text.slice(0, 300));
    throw e;
  }
  console.log(`[gen] parsed ${plan?.days?.length ?? 0} day(s) OK`);

  // Overwrite the model's guessed daily targets with the deterministic ones, so
  // the stored/displayed numbers are correct and reproducible regardless of what
  // the LLM returned. The model only owns the meals; the engine owns the target.
  plan.dailyCalorieTarget = targets.calorieTarget;
  plan.dailyProteinTarget = targets.macros.protein;
  plan.dailyCarbsTarget = targets.macros.carbs;
  plan.dailyFatTarget = targets.macros.fat;

  // Allergy safety net — keyword flags on what the model actually returned.
  const allergyFlags = findAllergenFlags(plan, input.allergies);
  if (allergyFlags.length) {
    console.warn(
      `[gen] ⚠ allergen keyword hits: ` +
        allergyFlags.map((f) => `${f.allergen} in "${f.dish}" (day ${f.day})`).join('; '),
    );
  }

  return {
    plan,
    meta: {
      requestedDays: input.targetDays,
      startDay,
      plannedDays,
      // More days remain after this batch (the client can request the next one).
      truncated: startDay - 1 + plannedDays < input.targetDays,
      provider: provider.name,
      model: provider.model,
      // The engine's computed anchor — the client seeds current_calorie_target
      // from this and can show BMR/TDEE and any safety note.
      bmr: targets.bmr,
      tdee: targets.tdee,
      calorieTarget: targets.calorieTarget,
      rateKgPerWeek: targets.rateKgPerWeek,
      targetWarnings: targets.warnings,
      // Possible allergen mentions to surface as "check these" (not verdicts).
      allergyFlags,
    },
  };
}

// Regenerates a single meal (a "swap") — same slot/budget/locale, different
// dish. A small, fast call compared to a full plan.
export async function generateMeal(input) {
  const { system, user } = buildMealPrompt(input);
  const provider = getProvider();
  console.log(`[meal] swapping ${input.mealName || 'meal'} in ${input.location}…`);
  const result = await provider.generate({
    system,
    user,
    maxTokens: 2000,
    effort: 'low',
    schema: MEAL_SCHEMA,
  });
  const meal = parsePlanJson(result.text);
  return { meal, meta: { provider: provider.name, model: provider.model } };
}

// Generates step-by-step preparation instructions for one dish. Small, fast
// call; the caller caches the result so a dish is only ever generated once.
export async function generateRecipe(input) {
  const { system, user } = buildRecipePrompt(input);
  const provider = getProvider();
  console.log(`[recipe] generating steps for "${input.dish}"…`);
  const result = await provider.generate({
    system,
    user,
    maxTokens: 2000,
    effort: 'low',
    schema: RECIPE_SCHEMA,
  });
  return parsePlanJson(result.text);
}

// Writes a progress review from already-computed figures (weigh-ins, adherence,
// days elapsed). Small, fast call. The caller decides whether it's free.
export async function generateReview(input) {
  const { system, user } = buildReviewPrompt(input);
  const provider = getProvider();
  console.log(`[review] reviewing progress (day ${input.daysElapsed}/${input.targetDays})…`);
  const result = await provider.generate({
    system,
    user,
    maxTokens: 1500,
    effort: 'low',
    schema: REVIEW_SCHEMA,
  });
  return parsePlanJson(result.text);
}

// Suggests activities for a day or a week, tailored to goal/stats. Small call.
export async function generateActivity(input) {
  const { system, user } = buildActivityPrompt(input);
  const provider = getProvider();
  console.log(`[activity] suggesting ${input.scope === 'week' ? 'a week' : 'a day'} of activity…`);
  const result = await provider.generate({
    system,
    user,
    maxTokens: 2000,
    effort: 'low',
    schema: ACTIVITY_SCHEMA,
  });
  return parsePlanJson(result.text);
}
