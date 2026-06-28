import { buildPrompt, buildMealPrompt, MEAL_SCHEMA } from './planSchema.js';
import { getProvider } from './providers.js';

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

export async function generatePlan(input) {
  // Continuation support: generate days [startDay .. startDay+plannedDays-1] of
  // a longer journey. startDay defaults to 1 (a fresh first week).
  const startDay = Math.max(1, Math.round(input.startDay || 1));
  const remaining = Math.max(1, input.targetDays - (startDay - 1));
  const plannedDays = Math.min(remaining, MAX_PLAN_DAYS);
  const { system, user } = buildPrompt({ ...input, startDay }, plannedDays);
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
