import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import { generatePlan, generateMeal, MAX_PLAN_DAYS } from './planService.js';
import { describeProvider } from './providers.js';
import { authRouter, requireAuth } from './auth.js';
import { billingRouter, stripeWebhookHandler } from './billingRoutes.js';
import { getEntitlements, spendCredits, addCredits } from './db.js';
import { BILLING_PROVIDER, CURRENCY } from './billing.js';

const app = express();
app.use(cors());

// Stripe webhook needs the raw body for signature verification, so it is
// mounted with a raw parser BEFORE the global JSON parser below.
app.post('/api/billing/webhook', express.raw({ type: 'application/json' }), stripeWebhookHandler);

app.use(express.json({ limit: '1mb' }));

const PORT = Number(process.env.PORT || 3000);

// Auth: signup / login / me (token verification).
app.use('/api/auth', authRouter);
// Billing: balance/catalog, checkout, return page.
app.use('/api/billing', billingRouter);

const SEXES = ['male', 'female', 'other'];
const ACTIVITY = ['sedentary', 'light', 'moderate', 'active', 'very_active'];

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
  if (!(heightCm > 0 && heightCm < 300)) errors.push('heightCm must be between 0 and 300');
  if (!(targetWeightKg > 0 && targetWeightKg < 500))
    errors.push('targetWeightKg must be between 0 and 500');
  if (!(targetDays >= 1 && targetDays <= 365)) errors.push('targetDays must be between 1 and 365');
  if (!location) errors.push('location is required');

  // Optional fields — only validate if provided.
  const value = { weightKg, heightCm, targetWeightKg, targetDays, location };

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
  if (typeof body.dietaryPreference === 'string' && body.dietaryPreference.trim()) {
    value.dietaryPreference = body.dietaryPreference.trim();
  }

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

  return errors.length ? { error: errors } : { value };
}

app.get('/health', (_req, res) => {
  res.json({ ok: true, maxPlanDays: MAX_PLAN_DAYS });
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
  const ent = getEntitlements(req.user.id);
  let creditSpent = false;
  if (!ent.subscriptionActive) {
    const spend = spendCredits(req.user.id, 1, { provider: 'app', productId: 'plan' });
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

  try {
    const result = await generatePlan(value);
    const secs = ((Date.now() - started) / 1000).toFixed(1);
    const after = getEntitlements(req.user.id);
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
      addCredits(req.user.id, 1, { kind: 'refund', provider: 'app', productId: 'plan', amountCents: 0, currency: CURRENCY });
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

app.listen(PORT, () => {
  const p = describeProvider();
  console.log(`Diet planner backend listening on http://localhost:${PORT}`);
  console.log(
    `  provider=${p.name} · model=${p.model} · effort=${process.env.EFFORT || 'medium'} · maxPlanDays=${MAX_PLAN_DAYS} · ${p.keyEnv}=${p.keySet ? 'set' : 'MISSING'}`,
  );
});
