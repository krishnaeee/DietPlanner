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

export default pool;
