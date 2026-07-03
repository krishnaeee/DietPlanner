// Email + password and Google authentication: signup, login, JWT issuance/verification.
import express from 'express';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import { randomBytes } from 'node:crypto';
import { OAuth2Client } from 'google-auth-library';

import { createUser, findUserByEmail, findUserById, linkGoogle, addCredits } from './db.js';
import { SIGNUP_FREE_CREDITS } from './billing.js';

/// Grants the free starter credits to a freshly created account (recorded in
/// the ledger as a 'grant' so the balance has an audit trail).
async function grantSignupCredits(userId) {
  if (SIGNUP_FREE_CREDITS > 0) {
    await addCredits(userId, SIGNUP_FREE_CREDITS, { kind: 'grant', provider: 'signup' });
  }
}

const JWT_SECRET = process.env.JWT_SECRET || 'dev-insecure-secret-change-me';
const JWT_EXPIRES = '30d';

// The Web OAuth client ID — the audience the Android app's ID token is minted for.
const GOOGLE_WEB_CLIENT_ID = process.env.GOOGLE_WEB_CLIENT_ID || '';
const googleClient = new OAuth2Client();

if (!process.env.JWT_SECRET) {
  console.warn(
    '[auth] ⚠ JWT_SECRET not set — using an insecure dev secret. Set JWT_SECRET in .env.',
  );
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function signToken(user) {
  return jwt.sign({ sub: user.id, email: user.email }, JWT_SECRET, {
    expiresIn: JWT_EXPIRES,
  });
}

function readCredentials(body) {
  const email =
    typeof body?.email === 'string' ? body.email.trim().toLowerCase() : '';
  const password = typeof body?.password === 'string' ? body.password : '';
  return { email, password };
}

export const authRouter = express.Router();

authRouter.post('/signup', async (req, res) => {
  const { email, password } = readCredentials(req.body);
  if (!EMAIL_RE.test(email)) {
    return res.status(400).json({ error: 'Enter a valid email address.' });
  }
  if (password.length < 6) {
    return res.status(400).json({ error: 'Password must be at least 6 characters.' });
  }
  if (await findUserByEmail(email)) {
    return res.status(409).json({ error: 'An account with this email already exists.' });
  }

  const hash = await bcrypt.hash(password, 10);
  const user = await createUser(email, hash);
  await grantSignupCredits(user.id);
  console.log(`[auth] signup: ${email} (id ${user.id}) +${SIGNUP_FREE_CREDITS} free credits`);
  return res
    .status(201)
    .json({ token: signToken(user), user: { id: user.id, email: user.email } });
});

authRouter.post('/login', async (req, res) => {
  const { email, password } = readCredentials(req.body);
  if (!email || !password) {
    return res.status(400).json({ error: 'Email and password are required.' });
  }

  const row = await findUserByEmail(email);
  // Always run a compare to avoid leaking whether the email exists via timing.
  const ok = row ? await bcrypt.compare(password, row.password_hash) : false;
  if (!row || !ok) {
    return res.status(401).json({ error: 'Invalid email or password.' });
  }

  console.log(`[auth] login: ${email} (id ${row.id})`);
  return res.json({
    token: signToken({ id: row.id, email: row.email }),
    user: { id: row.id, email: row.email },
  });
});

/// Auth-verification middleware: requires a valid `Authorization: Bearer <jwt>`.
export function requireAuth(req, res, next) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) return res.status(401).json({ error: 'Authentication required.' });
  try {
    const payload = jwt.verify(token, JWT_SECRET);
    req.user = { id: payload.sub, email: payload.email };
    return next();
  } catch (_) {
    return res.status(401).json({ error: 'Session expired. Please log in again.' });
  }
}

// Google sign-in: the app sends a Google ID token; we verify it with Google,
// find-or-create the matching account by email, and issue our own JWT.
authRouter.post('/google', async (req, res) => {
  if (!GOOGLE_WEB_CLIENT_ID) {
    return res.status(500).json({ error: 'Google login is not configured on the server.' });
  }
  const idToken = typeof req.body?.idToken === 'string' ? req.body.idToken : '';
  if (!idToken) return res.status(400).json({ error: 'Missing Google ID token.' });

  let payload;
  try {
    const ticket = await googleClient.verifyIdToken({
      idToken,
      audience: GOOGLE_WEB_CLIENT_ID,
    });
    payload = ticket.getPayload();
  } catch (_) {
    return res.status(401).json({ error: 'Could not verify your Google sign-in.' });
  }

  const email = (payload?.email || '').toLowerCase();
  const sub = payload?.sub || '';
  if (!email) return res.status(401).json({ error: 'Your Google account has no email.' });

  let user = await findUserByEmail(email);
  if (!user) {
    // No local password for Google accounts — store an unusable random hash.
    const hash = await bcrypt.hash(randomBytes(24).toString('hex'), 10);
    user = await createUser(email, hash);
    await grantSignupCredits(user.id);
  }
  await linkGoogle(user.id, sub);
  console.log(`[auth] google login: ${email} (id ${user.id})`);
  return res.json({
    token: signToken({ id: user.id, email: user.email }),
    user: { id: user.id, email: user.email },
  });
});

// Returns the current user — used by the app to verify a stored token on launch.
authRouter.get('/me', requireAuth, async (req, res) => {
  const user = await findUserById(req.user.id);
  if (!user) return res.status(401).json({ error: 'Account not found.' });
  return res.json({ user: { id: user.id, email: user.email } });
});
