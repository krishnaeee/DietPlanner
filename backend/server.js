import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import { generatePlan, MAX_PLAN_DAYS } from './planService.js';
import { describeProvider } from './providers.js';
import { authRouter, requireAuth } from './auth.js';

const app = express();
app.use(cors());
app.use(express.json({ limit: '1mb' }));

const PORT = Number(process.env.PORT || 3000);

// Auth: signup / login / me (token verification).
app.use('/api/auth', authRouter);

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

  try {
    const result = await generatePlan(value);
    const secs = ((Date.now() - started) / 1000).toFixed(1);
    console.log(`[plan] → responded 200 in ${secs}s (${result.plan?.days?.length ?? 0} days)`);
    res.json(result);
  } catch (err) {
    const secs = ((Date.now() - started) / 1000).toFixed(1);
    console.error(`[plan] → responded ${err.status || 500} after ${secs}s: ${err?.message}`);
    if (err?.stack) console.error(err.stack);
    const status = err.status || 500;
    res.status(status).json({ error: err.message || 'Failed to generate plan.' });
  }
});

app.listen(PORT, () => {
  const p = describeProvider();
  console.log(`Diet planner backend listening on http://localhost:${PORT}`);
  console.log(
    `  provider=${p.name} · model=${p.model} · effort=${process.env.EFFORT || 'medium'} · maxPlanDays=${MAX_PLAN_DAYS} · ${p.keyEnv}=${p.keySet ? 'set' : 'MISSING'}`,
  );
});
