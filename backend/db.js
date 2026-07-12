// User + billing store backed by Postgres (Neon in production).
//
// Set DATABASE_URL to your Neon connection string (the pooled one is fine).
// Every exported function is async — Postgres queries return promises, unlike
// the old node:sqlite layer this replaced.
import pg from 'pg';

const { Pool } = pg;

if (!process.env.DATABASE_URL) {
  throw new Error(
    'DATABASE_URL is not set. Add your Neon Postgres connection string to the ' +
      'environment (e.g. Render → Environment, or backend/.env for local dev).',
  );
}

// Neon requires TLS. rejectUnauthorized:false keeps the handshake working
// across hosts without shipping Neon's CA bundle — the connection is still
// encrypted, we just don't pin the certificate.
export const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: { rejectUnauthorized: false },
  max: Number(process.env.PGPOOL_MAX || 5),
});

// ─────────────────────────────────────────────────────────────── schema ──
// Runs once at import (top-level await) so the tables exist before any query.
await pool.query(`
  CREATE TABLE IF NOT EXISTS users (
    id             SERIAL PRIMARY KEY,
    email          TEXT UNIQUE NOT NULL,
    password_hash  TEXT NOT NULL,
    google_sub     TEXT,
    credits        INTEGER NOT NULL DEFAULT 0,
    sub_status     TEXT,                       -- null | 'active' | 'canceled'
    sub_expires_at TIMESTAMPTZ,                -- null when no sub
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
  );
`);

await pool.query(`
  CREATE TABLE IF NOT EXISTS transactions (
    id            BIGSERIAL PRIMARY KEY,
    user_id       INTEGER NOT NULL,
    kind          TEXT NOT NULL,               -- grant | purchase | spend | refund | subscription
    credits_delta INTEGER NOT NULL DEFAULT 0,
    amount_cents  INTEGER NOT NULL DEFAULT 0,
    currency      TEXT,
    product_id    TEXT,
    provider      TEXT,                        -- mock | stripe | revenuecat | signup | app
    provider_ref  TEXT,                        -- session/event id; deduped for idempotency
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
  );
`);

// A provider_ref may only be fulfilled once — the partial unique index makes a
// duplicate webhook delivery (or retried purchase) a no-op insert.
await pool.query(
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_tx_provider_ref ON transactions(provider_ref) WHERE provider_ref IS NOT NULL',
);

// ─────────────────────────────────────────────────── plans + tracking ──
// Server-side home for each user's plans and the tracked reality the adaptive
// re-targeting loop reads. `plan`/`request` (JSONB) are the artifact — enough
// for any device to re-render the menu — while the flat columns beside them are
// the queryable state the engine reasons over. current_calorie_target is the
// single column re-targeting rewrites (see applyRetarget below).
await pool.query(`
  CREATE TABLE IF NOT EXISTS plans (
    id                     TEXT PRIMARY KEY,                                     -- client-generated StoredPlan.id
    user_id                INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    slot                   INTEGER NOT NULL,                                     -- notification-id namespacing
    name                   TEXT NOT NULL,
    plan                   JSONB NOT NULL,                                       -- DietPlan.toResponseJson() (all days/meals/ingredients)
    request                JSONB,                                               -- original /api/plan body, for extend
    goal                   TEXT NOT NULL,                                       -- lose | gain | maintain
    height_cm              NUMERIC(5,1),
    age                    INTEGER,
    sex                    TEXT,
    activity_level         TEXT,
    start_weight_kg        NUMERIC(5,2),
    target_weight_kg       NUMERIC(5,2),
    target_days            INTEGER NOT NULL,
    planned_days           INTEGER NOT NULL DEFAULT 0,
    start_date             DATE,                                                -- calendar date of Day 1
    location               TEXT,
    dietary_preference     TEXT,
    current_calorie_target INTEGER,                                             -- owned by the re-target loop after creation
    current_macros         JSONB,
    reminders_scheduled    BOOLEAN NOT NULL DEFAULT false,
    repeat_forever         BOOLEAN NOT NULL DEFAULT false,
    water_goal             INTEGER NOT NULL DEFAULT 8,
    water_reminders_on     BOOLEAN NOT NULL DEFAULT false,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, slot)
  );
`);
await pool.query('CREATE INDEX IF NOT EXISTS idx_plans_user ON plans(user_id)');

// The weight signal — one row per calendar day per plan (matches the client's
// replace-by-day withWeighIn). user_id is denormalized so "all of a user's
// weigh-ins" needs no join.
await pool.query(`
  CREATE TABLE IF NOT EXISTS weighins (
    id          BIGSERIAL PRIMARY KEY,
    plan_id     TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
    user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    measured_on DATE NOT NULL,
    weight_kg   NUMERIC(5,2) NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (plan_id, measured_on)
  );
`);
await pool.query('CREATE INDEX IF NOT EXISTS idx_weighins_plan ON weighins(plan_id, measured_on)');

// The adherence signal — today the client's mealsDone booleans. status +
// eaten_calories are the seam for real off-plan intake logging later.
await pool.query(`
  CREATE TABLE IF NOT EXISTS meal_log (
    id             BIGSERIAL PRIMARY KEY,
    plan_id        TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
    user_id        INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    day_index      INTEGER NOT NULL,                                            -- 0-based plan day
    meal_index     INTEGER NOT NULL,                                            -- 0-based meal
    status         TEXT NOT NULL DEFAULT 'eaten',                              -- eaten | skipped | swapped | offplan
    eaten_calories INTEGER,                                                     -- NULL = the plan's own number
    logged_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (plan_id, day_index, meal_index)
  );
`);
await pool.query('CREATE INDEX IF NOT EXISTS idx_meal_log_plan ON meal_log(plan_id)');

// Daily hydration — one row per day per plan (matches the client's waterByDate).
await pool.query(`
  CREATE TABLE IF NOT EXISTS water_log (
    plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    day     DATE NOT NULL,
    glasses INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (plan_id, day)
  );
`);

// Audit ledger of every adaptive re-target decision — same philosophy as
// `transactions`: makes the coach's course-corrections explainable.
await pool.query(`
  CREATE TABLE IF NOT EXISTS retarget_events (
    id                 BIGSERIAL PRIMARY KEY,
    plan_id            TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
    user_id            INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    at_day_index       INTEGER,
    observed_weight_kg NUMERIC(5,2),
    trend_kg_per_week  NUMERIC(4,2),
    old_target         INTEGER,
    new_target         INTEGER,
    reason             TEXT,                                                    -- plateau | too_fast | on_track | scheduled
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
  );
`);
await pool.query('CREATE INDEX IF NOT EXISTS idx_retarget_plan ON retarget_events(plan_id)');

// ─────────────────────────────────────────────────────────────── users ──

export async function createUser(email, passwordHash) {
  const { rows } = await pool.query(
    'INSERT INTO users (email, password_hash) VALUES ($1, $2) RETURNING id, email',
    [email, passwordHash],
  );
  return { id: rows[0].id, email: rows[0].email };
}

export async function findUserByEmail(email) {
  const { rows } = await pool.query('SELECT * FROM users WHERE email = $1', [email]);
  return rows[0]; // undefined when none
}

export async function findUserById(id) {
  const { rows } = await pool.query(
    'SELECT id, email, created_at FROM users WHERE id = $1',
    [id],
  );
  return rows[0];
}

export async function linkGoogle(id, sub) {
  await pool.query('UPDATE users SET google_sub = $1 WHERE id = $2', [sub, id]);
}

// ─────────────────────────────────────────────────────────────── billing ──

// Runs a unit of work on a single pooled connection inside a transaction,
// rolling back on throw. The callback receives that client so its queries share
// the transaction.
async function inTx(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

/// Current credits + subscription for a user. `subscriptionActive` is the only
/// flag callers should gate on (it accounts for expiry). Pass [exec] (a tx
/// client) to read inside an open transaction; defaults to the pool.
export async function getEntitlements(userId, exec = pool) {
  const { rows } = await exec.query(
    'SELECT credits, sub_status, sub_expires_at FROM users WHERE id = $1',
    [userId],
  );
  const row = rows[0];
  if (!row) return { credits: 0, subStatus: null, subExpiresAt: null, subscriptionActive: false };
  const expiresMs = row.sub_expires_at ? new Date(row.sub_expires_at).getTime() : 0;
  const active = row.sub_status === 'active' && expiresMs > Date.now();
  return {
    credits: row.credits ?? 0,
    subStatus: row.sub_status ?? null,
    subExpiresAt: row.sub_expires_at ?? null,
    subscriptionActive: active,
  };
}

// Records a ledger row on [client]. Returns false if provider_ref was already
// used (ON CONFLICT DO NOTHING skips the insert) — the caller treats that as
// "already fulfilled". Using ON CONFLICT (not a caught exception) keeps the
// surrounding transaction alive, which Postgres would otherwise abort.
async function ledger(client, tx) {
  const res = await client.query(
    `INSERT INTO transactions
       (user_id, kind, credits_delta, amount_cents, currency, product_id, provider, provider_ref)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
     ON CONFLICT (provider_ref) WHERE provider_ref IS NOT NULL DO NOTHING`,
    [
      tx.userId,
      tx.kind,
      tx.creditsDelta ?? 0,
      tx.amountCents ?? 0,
      tx.currency ?? null,
      tx.productId ?? null,
      tx.provider ?? null,
      tx.providerRef ?? null,
    ],
  );
  return res.rowCount > 0;
}

/// Adds [n] credits and writes a ledger row, atomically. When [providerRef] was
/// already recorded, this is a no-op and returns the unchanged balance
/// (idempotent fulfilment for webhooks / retried purchases).
export async function addCredits(userId, n, meta = {}) {
  return inTx(async (client) => {
    const recorded = await ledger(client, {
      userId,
      kind: meta.kind || 'purchase',
      creditsDelta: n,
      ...meta,
    });
    if (!recorded) return { applied: false, ...(await getEntitlements(userId, client)) };
    await client.query('UPDATE users SET credits = credits + $1 WHERE id = $2', [n, userId]);
    return { applied: true, ...(await getEntitlements(userId, client)) };
  });
}

/// Atomically spends [n] credits if the balance allows. Returns { ok, credits }.
/// ok=false means insufficient balance (nothing changed). The row is locked
/// FOR UPDATE so concurrent spends can't double-spend.
export async function spendCredits(userId, n = 1, meta = {}) {
  return inTx(async (client) => {
    const { rows } = await client.query(
      'SELECT credits FROM users WHERE id = $1 FOR UPDATE',
      [userId],
    );
    const credits = rows[0]?.credits ?? 0;
    if (!rows[0] || credits < n) return { ok: false, credits };
    await client.query('UPDATE users SET credits = credits - $1 WHERE id = $2', [n, userId]);
    await ledger(client, { userId, kind: 'spend', creditsDelta: -n, ...meta });
    return { ok: true, credits: credits - n };
  });
}

/// Activates/extends a subscription by [periodMs]. Idempotent on [providerRef].
/// If already active, the new period stacks on the remaining time so renewals
/// don't lose days.
export async function activateSubscription(userId, periodMs, meta = {}) {
  return inTx(async (client) => {
    const recorded = await ledger(client, { userId, kind: 'subscription', ...meta });
    if (!recorded) return { applied: false, ...(await getEntitlements(userId, client)) };
    const ent = await getEntitlements(userId, client);
    const base = ent.subscriptionActive ? new Date(ent.subExpiresAt).getTime() : Date.now();
    const expires = new Date(base + periodMs).toISOString();
    await client.query('UPDATE users SET sub_status = $1, sub_expires_at = $2 WHERE id = $3', [
      'active',
      expires,
      userId,
    ]);
    return { applied: true, ...(await getEntitlements(userId, client)) };
  });
}

// ─────────────────────────────────────────────────── plans + tracking ──

// snake_case DB row → the camelCase plan shape the client/engine expects.
function mapPlanRow(r) {
  if (!r) return undefined;
  const num = (v) => (v == null ? null : Number(v));
  return {
    id: r.id,
    slot: r.slot,
    name: r.name,
    plan: r.plan,
    request: r.request,
    goal: r.goal,
    heightCm: num(r.height_cm),
    age: r.age,
    sex: r.sex,
    activityLevel: r.activity_level,
    startWeightKg: num(r.start_weight_kg),
    targetWeightKg: num(r.target_weight_kg),
    targetDays: r.target_days,
    plannedDays: r.planned_days,
    startDate: r.start_date,
    location: r.location,
    dietaryPreference: r.dietary_preference,
    currentCalorieTarget: r.current_calorie_target,
    currentMacros: r.current_macros,
    remindersScheduled: r.reminders_scheduled,
    repeatForever: r.repeat_forever,
    waterGoal: r.water_goal,
    waterRemindersOn: r.water_reminders_on,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
  };
}

/// Insert or update a plan, idempotent on the client-supplied id. The whole menu
/// rides in `plan` (JSONB); the flat columns are the queryable state. On UPDATE
/// the loop-owned columns (current_calorie_target/current_macros) are NOT
/// overwritten — the client seeds them on first insert, applyRetarget owns them
/// thereafter — and the WHERE guards that the row belongs to this user.
export async function upsertPlan(userId, p) {
  const planJson = JSON.stringify(p.plan ?? {});
  const requestJson = p.request != null ? JSON.stringify(p.request) : null;
  const macrosJson = p.currentMacros != null ? JSON.stringify(p.currentMacros) : null;
  const { rows } = await pool.query(
    `INSERT INTO plans (
        id, user_id, slot, name, plan, request, goal, height_cm, age, sex,
        activity_level, start_weight_kg, target_weight_kg, target_days,
        planned_days, start_date, location, dietary_preference,
        current_calorie_target, current_macros, reminders_scheduled,
        repeat_forever, water_goal, water_reminders_on)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24)
      ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name,
        plan = EXCLUDED.plan,
        request = EXCLUDED.request,
        goal = EXCLUDED.goal,
        height_cm = EXCLUDED.height_cm,
        age = EXCLUDED.age,
        sex = EXCLUDED.sex,
        activity_level = EXCLUDED.activity_level,
        start_weight_kg = EXCLUDED.start_weight_kg,
        target_weight_kg = EXCLUDED.target_weight_kg,
        target_days = EXCLUDED.target_days,
        planned_days = EXCLUDED.planned_days,
        start_date = EXCLUDED.start_date,
        location = EXCLUDED.location,
        dietary_preference = EXCLUDED.dietary_preference,
        reminders_scheduled = EXCLUDED.reminders_scheduled,
        repeat_forever = EXCLUDED.repeat_forever,
        water_goal = EXCLUDED.water_goal,
        water_reminders_on = EXCLUDED.water_reminders_on,
        updated_at = now()
      WHERE plans.user_id = $2
      RETURNING *`,
    [
      p.id, userId, p.slot, p.name, planJson, requestJson, p.goal,
      p.heightCm ?? null, p.age ?? null, p.sex ?? null, p.activityLevel ?? null,
      p.startWeightKg ?? null, p.targetWeightKg ?? null, p.targetDays,
      p.plannedDays ?? 0, p.startDate ?? null, p.location ?? null,
      p.dietaryPreference ?? null, p.currentCalorieTarget ?? null, macrosJson,
      p.remindersScheduled ?? false, p.repeatForever ?? false,
      p.waterGoal ?? 8, p.waterRemindersOn ?? false,
    ],
  );
  return mapPlanRow(rows[0]);
}

/// All of a user's plans, ordered by slot.
export async function listPlans(userId) {
  const { rows } = await pool.query(
    'SELECT * FROM plans WHERE user_id = $1 ORDER BY slot',
    [userId],
  );
  return rows.map(mapPlanRow);
}

/// One plan, scoped to its owner (undefined when not found / not theirs).
export async function getPlan(userId, planId) {
  const { rows } = await pool.query(
    'SELECT * FROM plans WHERE id = $1 AND user_id = $2',
    [planId, userId],
  );
  return mapPlanRow(rows[0]);
}

/// Deletes a plan (children cascade). Scoped so one user can't delete another's.
export async function deletePlan(userId, planId) {
  const res = await pool.query(
    'DELETE FROM plans WHERE id = $1 AND user_id = $2',
    [planId, userId],
  );
  return res.rowCount > 0;
}

/// Upserts the weigh-in for a calendar day (one per day per plan). The INSERT …
/// SELECT WHERE EXISTS makes it a no-op unless planId belongs to userId, so a
/// caller can't write into someone else's plan. [measuredOn] is a yyyy-mm-dd
/// string. Returns true when a row was written.
export async function recordWeighIn(userId, planId, measuredOn, weightKg) {
  const { rows } = await pool.query(
    `INSERT INTO weighins (plan_id, user_id, measured_on, weight_kg)
       SELECT $1, $2, $3, $4
        WHERE EXISTS (SELECT 1 FROM plans WHERE id = $1 AND user_id = $2)
     ON CONFLICT (plan_id, measured_on)
       DO UPDATE SET weight_kg = EXCLUDED.weight_kg, created_at = now()
     RETURNING id`,
    [planId, userId, measuredOn, weightKg],
  );
  return rows.length > 0;
}

/// A plan's weigh-in series, oldest → newest, in the client's {date, kg} shape.
export async function listWeighIns(userId, planId) {
  const { rows } = await pool.query(
    `SELECT measured_on, weight_kg FROM weighins
       WHERE plan_id = $1 AND user_id = $2 ORDER BY measured_on`,
    [planId, userId],
  );
  return rows.map((r) => ({ date: r.measured_on, kg: Number(r.weight_kg) }));
}

/// Replaces a plan's meal-adherence set with [meals] (each {dayIndex, mealIndex,
/// status?, eatenCalories?}), mirroring the client's mealsDone set. Delete-then-
/// insert inside one transaction so a partial sync can't leave a torn state; the
/// ownership check makes the whole thing a no-op for a foreign plan.
export async function syncMealLog(userId, planId, meals) {
  return inTx(async (client) => {
    const owned = await client.query(
      'SELECT 1 FROM plans WHERE id = $1 AND user_id = $2',
      [planId, userId],
    );
    if (!owned.rowCount) return false;
    await client.query('DELETE FROM meal_log WHERE plan_id = $1', [planId]);
    for (const m of meals) {
      await client.query(
        `INSERT INTO meal_log (plan_id, user_id, day_index, meal_index, status, eaten_calories)
           VALUES ($1, $2, $3, $4, $5, $6)
           ON CONFLICT (plan_id, day_index, meal_index) DO NOTHING`,
        [planId, userId, m.dayIndex, m.mealIndex, m.status ?? 'eaten', m.eatenCalories ?? null],
      );
    }
    return true;
  });
}

/// Sets the glass count for a calendar day (clamped at 0). Ownership-guarded like
/// recordWeighIn. [day] is a yyyy-mm-dd string.
export async function setWater(userId, planId, day, glasses) {
  const { rows } = await pool.query(
    `INSERT INTO water_log (plan_id, user_id, day, glasses)
       SELECT $1, $2, $3, $4
        WHERE EXISTS (SELECT 1 FROM plans WHERE id = $1 AND user_id = $2)
     ON CONFLICT (plan_id, day) DO UPDATE SET glasses = EXCLUDED.glasses
     RETURNING plan_id`,
    [planId, userId, day, glasses < 0 ? 0 : glasses],
  );
  return rows.length > 0;
}

/// The coach's write: atomically move a plan's live calorie/macro target and
/// record why in retarget_events. Like spend/ledger, the target change and its
/// audit row commit together or not at all. The row is locked FOR UPDATE so a
/// concurrent re-target can't race. Returns { ok, oldTarget, newTarget }.
export async function applyRetarget(userId, planId, ev) {
  return inTx(async (client) => {
    const { rows } = await client.query(
      'SELECT current_calorie_target FROM plans WHERE id = $1 AND user_id = $2 FOR UPDATE',
      [planId, userId],
    );
    if (!rows[0]) return { ok: false };
    const oldTarget = rows[0].current_calorie_target;
    await client.query(
      `UPDATE plans
          SET current_calorie_target = $1,
              current_macros = COALESCE($2, current_macros),
              updated_at = now()
        WHERE id = $3`,
      [ev.newTarget, ev.macros != null ? JSON.stringify(ev.macros) : null, planId],
    );
    await client.query(
      `INSERT INTO retarget_events
         (plan_id, user_id, at_day_index, observed_weight_kg, trend_kg_per_week, old_target, new_target, reason)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
      [
        planId, userId, ev.atDayIndex ?? null, ev.observedWeightKg ?? null,
        ev.trendKgPerWeek ?? null, oldTarget, ev.newTarget, ev.reason ?? null,
      ],
    );
    return { ok: true, oldTarget, newTarget: ev.newTarget };
  });
}

/// Everything the weekly re-target engine needs for one plan, in a single call:
/// the state slice, the weigh-in series (oldest → newest), and how many planned
/// meals have been marked eaten. Read-only.
export async function getAdaptiveInputs(userId, planId) {
  const plan = await getPlan(userId, planId);
  if (!plan) return undefined;
  const weighIns = await listWeighIns(userId, planId);
  const { rows } = await pool.query(
    "SELECT count(*)::int AS eaten FROM meal_log WHERE plan_id = $1 AND status = 'eaten'",
    [planId],
  );
  return { plan, weighIns, mealsEaten: rows[0].eaten };
}

/// A plan's full tracking in the client's PlanTracking shape, for restoring on a
/// new device: weigh-ins ({date,kg}), the done-meal set ("day:meal"), water by
/// day, and the plan-level water settings. Dates come back as yyyy-mm-dd strings
/// (to_char, so no timezone drift). undefined when the plan isn't the user's.
export async function getTracking(userId, planId) {
  const { rows: prow } = await pool.query(
    'SELECT water_goal, water_reminders_on FROM plans WHERE id = $1 AND user_id = $2',
    [planId, userId],
  );
  if (!prow[0]) return undefined;
  const { rows: w } = await pool.query(
    "SELECT to_char(measured_on,'YYYY-MM-DD') AS d, weight_kg FROM weighins WHERE plan_id = $1 ORDER BY measured_on",
    [planId],
  );
  const { rows: m } = await pool.query(
    "SELECT day_index, meal_index FROM meal_log WHERE plan_id = $1 AND status = 'eaten' ORDER BY day_index, meal_index",
    [planId],
  );
  const { rows: wa } = await pool.query(
    "SELECT to_char(day,'YYYY-MM-DD') AS d, glasses FROM water_log WHERE plan_id = $1",
    [planId],
  );
  const waterByDate = {};
  for (const r of wa) waterByDate[r.d] = r.glasses;
  return {
    weighIns: w.map((r) => ({ date: r.d, kg: Number(r.weight_kg) })),
    mealsDone: m.map((r) => `${r.day_index}:${r.meal_index}`),
    waterByDate,
    waterGoal: prow[0].water_goal,
    waterRemindersOn: prow[0].water_reminders_on,
  };
}

export default pool;
