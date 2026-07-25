import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import {
  generatePlan, generateMeal, generateRecipe, generateReview, generateActivity,
  MAX_PLAN_DAYS,
} from './planService.js';
import { describeProvider } from './providers.js';
import { authRouter, requireAuth } from './auth.js';
import { billingRouter, stripeWebhookHandler } from './billingRoutes.js';
import { plansRouter } from './plansRoutes.js';
import {
  getEntitlements, spendCredits, addCredits, applyRetarget,
  getRecipe, saveRecipe, pool,
} from './db.js';
import { decideRetarget } from './retarget.js';
import { BILLING_PROVIDER, CURRENCY } from './billing.js';

const app = express();
app.use(cors());

// Stripe webhook needs the raw body for signature verification, so it is
// mounted with a raw parser BEFORE the global JSON parser below.
app.post('/api/billing/webhook', express.raw({ type: 'application/json' }), stripeWebhookHandler);

app.use(express.json({ limit: '1mb' }));

const PORT = Number(process.env.PORT || 3000);

// Deployed-version marker. Render injects RENDER_GIT_COMMIT/BRANCH at runtime,
// so /health can report exactly what's live — turning the keep-warm cron into a
// deploy monitor (the commit flips when a push to main auto-deploys). startedAt
// shows when this instance booted (i.e. the deploy/restart time).
const VERSION = {
  commit: (process.env.RENDER_GIT_COMMIT || 'dev').slice(0, 7),
  branch: process.env.RENDER_GIT_BRANCH || null,
  startedAt: new Date().toISOString(),
};

// Auth: signup / login / me (token verification).
app.use('/api/auth', authRouter);
// Billing: balance/catalog, checkout, return page.
app.use('/api/billing', billingRouter);
// Plans + tracking sync (durable, multi-device).
app.use('/api/plans', plansRouter);

const SEXES = ['male', 'female', 'other'];
const ACTIVITY = ['sedentary', 'light', 'moderate', 'active', 'very_active'];
const GOALS = ['lose', 'gain', 'maintain']; // 'maintain' == "eat healthy"
const COOKING_STYLES = ['everyday', 'less_oil', 'steamed', 'mixed'];

// Validates and normalises the request body. Returns { value } or { error }.
function validate(body) {
  const errors = [];
  const num = (v) => (typeof v === 'number' && isFinite(v) ? v : Number(v));

  const weightKg = num(body.weightKg);
  const heightCm = num(body.heightCm);
  const targetWeightKg = num(body.targetWeightKg);
  const targetDays = Math.round(num(body.targetDays));
  const location = typeof body.location === 'string' ? body.location.trim() : '';

  if (!(weightKg > 0 && weightKg < 500)) errors.push('weightKg must be between 0 and 500');
  // Lower bound of 50 cm rejects a height mistakenly entered in metres (e.g. 1.7).
  if (!(heightCm > 50 && heightCm < 300)) errors.push('heightCm must be between 50 and 300');
  if (!(targetDays >= 1 && targetDays <= 365)) errors.push('targetDays must be between 1 and 365');
  if (!location) errors.push('location is required');

  // Goal: lose | gain | maintain ("eat healthy"). An explicit goal is validated
  // like sex/activity (unknown → error). Older clients that omit it fall back to
  // inferring from the weights.
  let goal;
  if (body.goal != null && body.goal !== '') {
    if (!GOALS.includes(body.goal)) {
      errors.push(`goal must be one of ${GOALS.join(', ')}`);
      goal = 'maintain'; // placeholder — the request already errored
    } else {
      goal = body.goal;
    }
  } else {
    goal =
      targetWeightKg > 0 && targetWeightKg < weightKg
        ? 'lose'
        : targetWeightKg > weightKg
          ? 'gain'
          : 'maintain';
  }

  // Target weight is required for lose/gain (and must be on the correct side of
  // the current weight); for "eat healthy" (maintain) it is optional and
  // defaults to the current weight (a balanced, weight-stable plan).
  let effectiveTarget = targetWeightKg;
  if (goal === 'maintain') {
    if (!(targetWeightKg > 0 && targetWeightKg < 500)) effectiveTarget = weightKg;
  } else if (!(targetWeightKg > 0 && targetWeightKg < 500)) {
    errors.push('targetWeightKg must be between 0 and 500');
  } else if (goal === 'lose' && targetWeightKg >= weightKg) {
    errors.push('target weight must be below current weight for a lose goal');
  } else if (goal === 'gain' && targetWeightKg <= weightKg) {
    errors.push('target weight must be above current weight for a gain goal');
  }

  const value = {
    weightKg,
    heightCm,
    targetWeightKg: effectiveTarget,
    targetDays,
    location,
    goal,
  };

  if (body.age != null && body.age !== '') {
    const age = Math.round(num(body.age));
    if (!(age > 0 && age < 120)) errors.push('age must be between 0 and 120');
    else value.age = age;
  }
  if (body.sex) {
    if (!SEXES.includes(body.sex)) errors.push(`sex must be one of ${SEXES.join(', ')}`);
    else value.sex = body.sex;
  }
  if (body.activityLevel) {
    if (!ACTIVITY.includes(body.activityLevel))
      errors.push(`activityLevel must be one of ${ACTIVITY.join(', ')}`);
    else value.activityLevel = body.activityLevel;
  }
  // Cooking style — how meals are prepared. Optional; unknown is rejected like
  // the other enums, and 'everyday' carries no special instruction.
  if (body.cookingStyle) {
    if (!COOKING_STYLES.includes(body.cookingStyle))
      errors.push(`cookingStyle must be one of ${COOKING_STYLES.join(', ')}`);
    else if (body.cookingStyle !== 'everyday') value.cookingStyle = body.cookingStyle;
  }
  if (typeof body.dietaryPreference === 'string' && body.dietaryPreference.trim()) {
    value.dietaryPreference = body.dietaryPreference.trim();
  }

  // Allergies — a medical constraint carried into every prompt (plan + swap).
  // Accepts an array or a comma-separated string; deduped case-insensitively.
  const rawAllergies = Array.isArray(body.allergies)
    ? body.allergies
    : typeof body.allergies === 'string'
      ? body.allergies.split(',')
      : [];
  const seenAllergy = new Set();
  const allergies = [];
  for (const a of rawAllergies) {
    const s = String(a ?? '').trim().slice(0, 40);
    if (!s) continue;
    const k = s.toLowerCase();
    if (seenAllergy.has(k)) continue;
    seenAllergy.add(k);
    allergies.push(s);
    if (allergies.length >= 20) break; // keep the prompt bounded
  }
  if (allergies.length) value.allergies = allergies;

  // Continuation: which day of the journey this batch starts at, and dishes
  // from earlier weeks to avoid repeating.
  if (body.startDay != null && body.startDay !== '') {
    const startDay = Math.round(num(body.startDay));
    if (!(startDay >= 1 && startDay <= targetDays))
      errors.push('startDay must be between 1 and targetDays');
    else value.startDay = startDay;
  }
  if (Array.isArray(body.avoidDishes)) {
    value.avoidDishes = body.avoidDishes
      .filter((d) => typeof d === 'string' && d.trim())
      .map((d) => d.trim())
      .slice(0, 40); // cap so the prompt stays bounded
  }

  // Adaptive re-target inputs (only meaningful on a continuation week). The
  // client sends its latest weigh-in + trend so the next week can be re-paced to
  // real progress; planId lets the decision be persisted to the audit trail.
  if (body.currentWeightKg != null && body.currentWeightKg !== '') {
    const cw = num(body.currentWeightKg);
    if (cw > 0 && cw < 500) value.currentWeightKg = cw;
  }
  if (typeof body.planId === 'string' && body.planId.trim()) {
    value.planId = body.planId.trim();
  }
  if (Array.isArray(body.weighIns)) {
    value.weighIns = body.weighIns
      .filter((w) => w && w.date && isFinite(num(w.kg)))
      .map((w) => ({ date: String(w.date), kg: num(w.kg) }))
      .slice(0, 60);
  }

  return errors.length ? { error: errors } : { value };
}

// Health check + keep-warm. The `SELECT 1` pokes Neon so the free-tier DB
// (which auto-suspends after ~5 min idle) stays awake between cron-job.org
// pings, not just the Render web service. Returns 503 if the DB is
// unreachable so the pinger's failure alert doubles as DB monitoring.
app.get('/health', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ ok: true, db: 'up', maxPlanDays: MAX_PLAN_DAYS, version: VERSION });
  } catch (err) {
    console.error('[health] DB check failed:', err.message);
    res.status(503).json({ ok: false, db: 'down', maxPlanDays: MAX_PLAN_DAYS, version: VERSION });
  }
});

app.post('/api/plan', requireAuth, async (req, res) => {
  const started = Date.now();
  console.log(`\n[plan] ← request from ${req.user?.email ?? req.ip}`);
  const { value, error } = validate(req.body || {});
  if (error) {
    console.warn('[plan] ✗ validation failed:', error);
    return res.status(400).json({ error });
  }
  console.log(
    `[plan] input ok: ${value.weightKg}kg → ${value.targetWeightKg}kg over ${value.targetDays}d in ${value.location}`,
  );

  // ── Entitlement gate: an active subscription generates free; otherwise we
  // spend one credit up front (refunded below if generation fails). No
  // entitlement → 402 so the app can show the paywall.
  const ent = await getEntitlements(req.user.id);
  let creditSpent = false;
  if (!ent.subscriptionActive) {
    const spend = await spendCredits(req.user.id, 1, { provider: 'app', productId: 'plan' });
    if (!spend.ok) {
      console.log(`[plan] ✗ payment required for ${req.user.email} (credits=${spend.credits})`);
      return res.status(402).json({
        error: "You're out of credits. Buy a plan, a credit pack, or go unlimited to continue.",
        code: 'PAYMENT_REQUIRED',
        entitlements: { credits: spend.credits, subscriptionActive: false },
      });
    }
    creditSpent = true;
  }

  // ── Adaptive re-target: on a continuation week, recompute the calorie target
  // from the user's latest weigh-in and re-pace to the deadline, so the new week
  // adapts to real progress (metabolic slowdown, plateau, or ahead of schedule).
  // No re-target inputs (or a first-week request) → generation is unchanged.
  let retarget = null;
  if (value.startDay > 1 && value.currentWeightKg) {
    retarget = decideRetarget({
      startWeightKg: value.weightKg,
      currentWeightKg: value.currentWeightKg,
      heightCm: value.heightCm,
      age: value.age,
      sex: value.sex,
      activityLevel: value.activityLevel,
      goal: value.goal,
      targetWeightKg: value.targetWeightKg,
      targetDays: value.targetDays,
      startDay: value.startDay,
      weighIns: value.weighIns,
    });
    value.calorieOverride = retarget.newTarget; // generatePlan builds around this
    console.log(
      `[plan] re-target: ${value.currentWeightKg}kg → ${retarget.newTarget} kcal/day ` +
        `(${retarget.reason}, trend ${retarget.trendKgPerWeek ?? 'n/a'} kg/wk)`,
    );
    // Best-effort audit — only when the plan is already synced server-side and
    // the move is meaningful. A missing plan row (sync not built yet) is a no-op.
    if (value.planId && retarget.changed) {
      try {
        await applyRetarget(req.user.id, value.planId, {
          atDayIndex: value.startDay - 1,
          observedWeightKg: retarget.observedWeightKg,
          trendKgPerWeek: retarget.trendKgPerWeek,
          newTarget: retarget.newTarget,
          macros: retarget.macros,
          reason: retarget.reason,
        });
      } catch (e) {
        console.warn('[plan] re-target audit write skipped:', e.message);
      }
    }
  }

  try {
    const result = await generatePlan(value);
    if (retarget) result.meta.retarget = retarget; // let the client explain the change
    const secs = ((Date.now() - started) / 1000).toFixed(1);
    const after = await getEntitlements(req.user.id);
    console.log(`[plan] → responded 200 in ${secs}s (${result.plan?.days?.length ?? 0} days) · credits=${after.credits}`);
    res.json({
      ...result,
      account: {
        credits: after.credits,
        subscriptionActive: after.subscriptionActive,
        subscriptionExpiresAt: after.subscriptionActive ? after.subExpiresAt : null,
      },
    });
  } catch (err) {
    // Generation failed after we charged — give the credit back so the user
    // isn't billed for nothing.
    if (creditSpent) {
      await addCredits(req.user.id, 1, { kind: 'refund', provider: 'app', productId: 'plan', amountCents: 0, currency: CURRENCY });
      console.log(`[plan] refunded 1 credit to ${req.user.email} after failure`);
    }
    const secs = ((Date.now() - started) / 1000).toFixed(1);
    console.error(`[plan] → responded ${err.status || 500} after ${secs}s: ${err?.message}`);
    if (err?.stack) console.error(err.stack);
    const status = err.status || 500;
    res.status(status).json({ error: err.message || 'Failed to generate plan.' });
  }
});

// Swap a single meal. Free (auth only) — it refines a plan the user already
// paid to generate, and is a much smaller call than a full plan.
app.post('/api/plan/meal', requireAuth, async (req, res) => {
  const body = req.body || {};
  const num = (v) => (typeof v === 'number' && isFinite(v) ? v : Number(v));
  const location = typeof body.location === 'string' ? body.location.trim() : '';
  if (!location) return res.status(400).json({ error: 'location is required' });

  const input = {
    location,
    mealName: typeof body.mealName === 'string' ? body.mealName.trim() : '',
    time: typeof body.time === 'string' ? body.time.trim() : '',
    avoidDish: typeof body.avoidDish === 'string' ? body.avoidDish.trim() : '',
    dietaryPreference:
      typeof body.dietaryPreference === 'string' ? body.dietaryPreference.trim() : '',
    // A swap must honour allergies just as strictly as the original plan.
    allergies: (Array.isArray(body.allergies) ? body.allergies : [])
      .map((a) => String(a ?? '').trim().slice(0, 40))
      .filter(Boolean)
      .slice(0, 20),
  };
  const tc = Math.round(num(body.targetCalories));
  if (tc > 0 && tc < 5000) input.targetCalories = tc;

  try {
    const { meal } = await generateMeal(input);
    console.log(`[meal] → swapped to "${meal?.dish ?? '?'}" for ${req.user?.email}`);
    res.json({ meal });
  } catch (err) {
    const status = err.status || 500;
    console.error(`[meal] → ${status}: ${err?.message}`);
    res.status(status).json({ error: err.message || 'Failed to swap meal.' });
  }
});

// Step-by-step preparation for one dish. A GLOBAL cache means a dish is only
// ever generated once for the whole app: a cache HIT is free; a MISS spends one
// credit (free on an active subscription; refunded if generation fails), then
// caches the result so it's free for everyone forever after.
app.post('/api/recipe', requireAuth, async (req, res) => {
  const body = req.body || {};
  const dish = typeof body.dish === 'string' ? body.dish.trim() : '';
  if (!dish) return res.status(400).json({ error: 'dish is required' });

  // Cache hit → free, no credit, no LLM.
  const cached = await getRecipe(dish);
  if (cached) {
    console.log(`[recipe] cache hit for "${dish}" (${req.user?.email})`);
    return res.json({ recipe: cached, cached: true, charged: false });
  }

  // Cache miss → same gate as /api/plan: sub generates free, else spend 1 credit.
  const ent = await getEntitlements(req.user.id);
  let creditSpent = false;
  if (!ent.subscriptionActive) {
    const spend = await spendCredits(req.user.id, 1, { provider: 'app', productId: 'recipe' });
    if (!spend.ok) {
      return res.status(402).json({
        error: "You're out of credits. Buy a credit pack or go unlimited to get preparation steps.",
        code: 'PAYMENT_REQUIRED',
        entitlements: { credits: spend.credits, subscriptionActive: false },
      });
    }
    creditSpent = true;
  }

  try {
    const recipe = await generateRecipe({
      dish,
      location: typeof body.location === 'string' ? body.location.trim() : '',
      dietaryPreference:
        typeof body.dietaryPreference === 'string' ? body.dietaryPreference.trim() : '',
      allergies: (Array.isArray(body.allergies) ? body.allergies : [])
        .map((a) => String(a ?? '').trim())
        .filter(Boolean)
        .slice(0, 20),
    });
    await saveRecipe(dish, recipe, req.user.id);
    const after = await getEntitlements(req.user.id);
    console.log(`[recipe] generated + cached "${dish}" · charged=${creditSpent} · credits=${after.credits}`);
    res.json({
      recipe,
      cached: false,
      charged: creditSpent,
      account: {
        credits: after.credits,
        subscriptionActive: after.subscriptionActive,
        subscriptionExpiresAt: after.subscriptionActive ? after.subExpiresAt : null,
      },
    });
  } catch (err) {
    if (creditSpent) {
      await addCredits(req.user.id, 1, {
        kind: 'refund', provider: 'app', productId: 'recipe', amountCents: 0, currency: CURRENCY,
      });
      console.log(`[recipe] refunded 1 credit to ${req.user.email} after failure`);
    }
    const status = err.status || 500;
    console.error(`[recipe] → ${status}: ${err?.message}`);
    res.status(status).json({ error: err.message || 'Failed to get preparation steps.' });
  }
});

// Progress review — the model interprets the user's own recorded figures
// (weigh-ins, adherence, days elapsed) into a written assessment. FREE (auth
// only), like a meal swap: it refines engagement with an already-paid plan and
// we want people using it often. The client sends already-computed numbers.
app.post('/api/review', requireAuth, async (req, res) => {
  const b = req.body || {};
  const num = (v) => (typeof v === 'number' && isFinite(v) ? v : Number(v) || 0);
  const input = {
    goal: ['lose', 'gain', 'maintain'].includes(b.goal) ? b.goal : 'maintain',
    startWeightKg: num(b.startWeightKg),
    targetWeightKg: num(b.targetWeightKg),
    currentWeightKg: num(b.currentWeightKg),
    targetDays: Math.max(1, Math.round(num(b.targetDays)) || 1),
    daysElapsed: Math.max(0, Math.round(num(b.daysElapsed))),
    calorieTarget: Math.round(num(b.calorieTarget)),
    weighIns: (Array.isArray(b.weighIns) ? b.weighIns : [])
      .filter((w) => w && w.date && isFinite(num(w.kg)))
      .map((w) => ({ date: String(w.date), kg: num(w.kg) }))
      .slice(0, 60),
    mealsDone: Math.max(0, Math.round(num(b.mealsDone))),
    mealsTotal: Math.max(0, Math.round(num(b.mealsTotal))),
    extrasCount: Math.max(0, Math.round(num(b.extrasCount))),
    extrasCalories: Math.max(0, Math.round(num(b.extrasCalories))),
  };
  try {
    const review = await generateReview(input);
    res.json({ review });
  } catch (err) {
    const status = err.status || 500;
    console.error(`[review] → ${status}: ${err?.message}`);
    res.status(status).json({ error: err.message || 'Failed to review your progress.' });
  }
});

// Activity suggestions for a day or a week. FREE (auth only), like the review —
// advice that supports an already-paid plan. NOT fed into the calorie math.
app.post('/api/activity', requireAuth, async (req, res) => {
  const b = req.body || {};
  const num = (v) => (typeof v === 'number' && isFinite(v) ? v : Number(v) || 0);
  const input = {
    scope: b.scope === 'week' ? 'week' : 'day',
    goal: ['lose', 'gain', 'maintain'].includes(b.goal) ? b.goal : 'maintain',
    sex: SEXES.includes(b.sex) ? b.sex : undefined,
    age: b.age != null && num(b.age) > 0 ? Math.round(num(b.age)) : undefined,
    activityLevel: ACTIVITY.includes(b.activityLevel) ? b.activityLevel : undefined,
    weightKg: num(b.weightKg) > 0 ? num(b.weightKg) : undefined,
  };
  try {
    const activity = await generateActivity(input);
    res.json({ activity });
  } catch (err) {
    const status = err.status || 500;
    console.error(`[activity] → ${status}: ${err?.message}`);
    res.status(status).json({ error: err.message || 'Failed to suggest activities.' });
  }
});

app.listen(PORT, () => {
  const p = describeProvider();
  console.log(`Diet planner backend listening on http://localhost:${PORT}`);
  console.log(
    `  provider=${p.name} · model=${p.model} · effort=${process.env.EFFORT || 'medium'} · maxPlanDays=${MAX_PLAN_DAYS} · ${p.keyEnv}=${p.keySet ? 'set' : 'MISSING'}`,
  );
});
