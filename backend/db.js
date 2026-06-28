// User store backed by Node's built-in SQLite (node:sqlite — no native build).
import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

const DB_PATH = process.env.DB_PATH || './data/app.db';
mkdirSync(dirname(DB_PATH), { recursive: true });

const db = new DatabaseSync(DB_PATH);
db.exec(`
  CREATE TABLE IF NOT EXISTS users (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    email         TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at    TEXT NOT NULL
  );
`);

// Migration: add columns to pre-existing tables (each guarded so it's safe to
// re-run). Billing state lives on the user row; history lives in `transactions`.
const columns = db.prepare('PRAGMA table_info(users)').all().map((c) => c.name);
const addColumn = (name, ddl) => {
  if (!columns.includes(name)) db.exec(`ALTER TABLE users ADD COLUMN ${ddl}`);
};
addColumn('google_sub', 'google_sub TEXT');
addColumn('credits', 'credits INTEGER NOT NULL DEFAULT 0');
addColumn('sub_status', 'sub_status TEXT'); // null | 'active' | 'canceled'
addColumn('sub_expires_at', 'sub_expires_at TEXT'); // ISO; null when no sub

// Append-only ledger of every credit/subscription movement (audit + idempotency).
db.exec(`
  CREATE TABLE IF NOT EXISTS transactions (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id       INTEGER NOT NULL,
    kind          TEXT NOT NULL,        -- grant | purchase | spend | refund | subscription
    credits_delta INTEGER NOT NULL DEFAULT 0,
    amount_cents  INTEGER NOT NULL DEFAULT 0,
    currency      TEXT,
    product_id    TEXT,
    provider      TEXT,                 -- mock | stripe
    provider_ref  TEXT,                 -- session/event id; deduped for idempotency
    created_at    TEXT NOT NULL
  );
`);
// A provider_ref may only be fulfilled once — the unique index makes double
// webhook deliveries (or a retried mock purchase) a no-op insert.
db.exec(
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_tx_provider_ref ON transactions(provider_ref) WHERE provider_ref IS NOT NULL',
);

export function createUser(email, passwordHash) {
  const info = db
    .prepare('INSERT INTO users (email, password_hash, created_at) VALUES (?, ?, ?)')
    .run(email, passwordHash, new Date().toISOString());
  return { id: Number(info.lastInsertRowid), email };
}

export function findUserByEmail(email) {
  return db.prepare('SELECT * FROM users WHERE email = ?').get(email);
}

export function findUserById(id) {
  return db
    .prepare('SELECT id, email, created_at FROM users WHERE id = ?')
    .get(id);
}

export function linkGoogle(id, sub) {
  db.prepare('UPDATE users SET google_sub = ? WHERE id = ?').run(sub, id);
}

// ──────────────────────────────────────────────────────────────── billing ──

const now = () => new Date().toISOString();

// node:sqlite's DatabaseSync has no .transaction() helper (unlike better-sqlite3),
// so wrap a unit of work in an explicit BEGIN/COMMIT, rolling back on throw.
function inTx(fn) {
  db.exec('BEGIN');
  try {
    const result = fn();
    db.exec('COMMIT');
    return result;
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }
}

/// Current credits + subscription for a user. `subscriptionActive` is the only
/// flag callers should gate on (it accounts for expiry).
export function getEntitlements(userId) {
  const row = db
    .prepare('SELECT credits, sub_status, sub_expires_at FROM users WHERE id = ?')
    .get(userId);
  if (!row) return { credits: 0, subStatus: null, subExpiresAt: null, subscriptionActive: false };
  const active =
    row.sub_status === 'active' &&
    !!row.sub_expires_at &&
    new Date(row.sub_expires_at).getTime() > Date.now();
  return {
    credits: row.credits ?? 0,
    subStatus: row.sub_status ?? null,
    subExpiresAt: row.sub_expires_at ?? null,
    subscriptionActive: active,
  };
}

// Records a ledger row. Returns false if provider_ref was already used (the
// unique index rejects the duplicate) — the caller treats that as "already done".
function ledger(tx) {
  try {
    db.prepare(
      `INSERT INTO transactions
         (user_id, kind, credits_delta, amount_cents, currency, product_id, provider, provider_ref, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run(
      tx.userId,
      tx.kind,
      tx.creditsDelta ?? 0,
      tx.amountCents ?? 0,
      tx.currency ?? null,
      tx.productId ?? null,
      tx.provider ?? null,
      tx.providerRef ?? null,
      now(),
    );
    return true;
  } catch (err) {
    if (String(err?.message || '').includes('UNIQUE')) return false; // already fulfilled
    throw err;
  }
}

/// Adds [n] credits and writes a ledger row, atomically. When [providerRef] is
/// supplied and was already recorded, this is a no-op and returns the unchanged
/// balance (idempotent fulfilment for webhooks / retried purchases).
export function addCredits(userId, n, meta = {}) {
  return inTx(() => {
    const recorded = ledger({ userId, kind: meta.kind || 'purchase', creditsDelta: n, ...meta });
    if (!recorded) return { applied: false, ...getEntitlements(userId) };
    db.prepare('UPDATE users SET credits = credits + ? WHERE id = ?').run(n, userId);
    return { applied: true, ...getEntitlements(userId) };
  });
}

/// Atomically spends [n] credits if the balance allows. Returns
/// { ok, credits }. ok=false means insufficient balance (nothing changed).
export function spendCredits(userId, n = 1, meta = {}) {
  return inTx(() => {
    const row = db.prepare('SELECT credits FROM users WHERE id = ?').get(userId);
    if (!row || (row.credits ?? 0) < n) return { ok: false, credits: row?.credits ?? 0 };
    db.prepare('UPDATE users SET credits = credits - ? WHERE id = ?').run(n, userId);
    ledger({ userId, kind: 'spend', creditsDelta: -n, ...meta });
    return { ok: true, credits: (row.credits ?? 0) - n };
  });
}

/// Activates/extends a subscription until [expiresAt] (ISO string). Idempotent
/// on [providerRef]. If already active and not expired, the new period is added
/// on top of the remaining time so renewals don't lose days.
export function activateSubscription(userId, periodMs, meta = {}) {
  return inTx(() => {
    const recorded = ledger({ userId, kind: 'subscription', ...meta });
    if (!recorded) return { applied: false, ...getEntitlements(userId) };
    const ent = getEntitlements(userId);
    const base = ent.subscriptionActive
      ? new Date(ent.subExpiresAt).getTime()
      : Date.now();
    const expires = new Date(base + periodMs).toISOString();
    db.prepare('UPDATE users SET sub_status = ?, sub_expires_at = ? WHERE id = ?').run(
      'active',
      expires,
      userId,
    );
    return { applied: true, ...getEntitlements(userId) };
  });
}

export default db;
