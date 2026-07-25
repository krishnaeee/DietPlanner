// Plan + tracking sync API. Lets the app push its locally-stored plans and
// tracking to the server and pull them back — so a reinstall or a new device
// restores the whole journey (today it lives only in the phone's
// SharedPreferences), and the adaptive re-target audit trail has real plan rows
// to write against.
//
// Thin auth'd wrappers over the already-tested db.js functions. All routes are
// scoped to req.user.id, so one account can never touch another's data.

import express from 'express';
import { requireAuth } from './auth.js';
import {
  listPlans,
  getPlan,
  upsertPlan,
  deletePlan,
  recordWeighIn,
  setWater,
  syncMealLog,
  syncExtras,
  getTracking,
} from './db.js';

export const plansRouter = express.Router();
plansRouter.use(requireAuth);

// GET /api/plans — every plan the user owns (blob + queryable state).
plansRouter.get('/', async (req, res) => {
  res.json({ plans: await listPlans(req.user.id) });
});

// GET /api/plans/:id — one plan.
plansRouter.get('/:id', async (req, res) => {
  const plan = await getPlan(req.user.id, req.params.id);
  if (!plan) return res.status(404).json({ error: 'Plan not found.' });
  res.json({ plan });
});

// PUT /api/plans/:id — upsert a plan (idempotent on the client-supplied id).
plansRouter.put('/:id', async (req, res) => {
  const b = req.body || {};
  if (!b.name || !b.goal || b.slot == null || b.targetDays == null || b.plan == null) {
    return res
      .status(400)
      .json({ error: 'name, slot, goal, targetDays and plan are required.' });
  }
  const plan = await upsertPlan(req.user.id, { ...b, id: req.params.id });
  // upsertPlan returns undefined when the id exists under a different account.
  if (!plan) return res.status(409).json({ error: 'That plan id belongs to another account.' });
  res.json({ plan });
});

// DELETE /api/plans/:id — remove a plan (its tracking cascades).
plansRouter.delete('/:id', async (req, res) => {
  res.json({ deleted: await deletePlan(req.user.id, req.params.id) });
});

// POST /api/plans/:id/weighin — record/replace one calendar day's weigh-in.
plansRouter.post('/:id/weighin', async (req, res) => {
  const { date, kg } = req.body || {};
  if (!date || !(Number(kg) > 0)) {
    return res.status(400).json({ error: 'date (yyyy-mm-dd) and a positive kg are required.' });
  }
  const ok = await recordWeighIn(req.user.id, req.params.id, String(date), Number(kg));
  if (!ok) return res.status(404).json({ error: 'Plan not found.' });
  res.json({ ok: true });
});

// PUT /api/plans/:id/tracking — push the whole tracking snapshot for a plan
// (weigh-ins, done-meals set, water-by-day). Idempotent; safe to call on any
// local change.
plansRouter.put('/:id/tracking', async (req, res) => {
  const id = req.params.id;
  const b = req.body || {};
  if (!(await getPlan(req.user.id, id))) {
    return res.status(404).json({ error: 'Plan not found.' });
  }
  if (Array.isArray(b.weighIns)) {
    for (const w of b.weighIns) {
      if (w && w.date && Number(w.kg) > 0) {
        await recordWeighIn(req.user.id, id, String(w.date), Number(w.kg));
      }
    }
  }
  // Eaten and explicitly-skipped meals sync together as one snapshot, so the
  // server holds the full resolved set (delete-then-insert inside syncMealLog).
  if (Array.isArray(b.mealsDone) || Array.isArray(b.mealsSkipped)) {
    const toMeals = (arr, status) =>
      (Array.isArray(arr) ? arr : [])
        .map((k) => String(k).split(':'))
        .filter((p) => p.length === 2)
        .map((p) => ({ dayIndex: Number(p[0]), mealIndex: Number(p[1]), status }))
        .filter((m) => Number.isInteger(m.dayIndex) && Number.isInteger(m.mealIndex));
    const meals = [
      ...toMeals(b.mealsDone, 'eaten'),
      ...toMeals(b.mealsSkipped, 'skipped'),
    ];
    await syncMealLog(req.user.id, id, meals);
  }
  if (b.waterByDate && typeof b.waterByDate === 'object') {
    for (const [day, glasses] of Object.entries(b.waterByDate)) {
      await setWater(req.user.id, id, String(day), Number(glasses) || 0);
    }
  }
  if (Array.isArray(b.extras)) {
    await syncExtras(req.user.id, id, b.extras);
  }
  res.json({ ok: true });
});

// GET /api/plans/:id/tracking — pull a plan's tracking to restore on a device.
plansRouter.get('/:id/tracking', async (req, res) => {
  const tracking = await getTracking(req.user.id, req.params.id);
  if (!tracking) return res.status(404).json({ error: 'Plan not found.' });
  res.json({ tracking });
});
