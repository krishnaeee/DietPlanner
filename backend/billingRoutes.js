// Billing HTTP surface: balance/catalog, checkout, Stripe webhook, and the
// tiny return pages the hosted checkout redirects back to.
import express from 'express';
import { randomUUID } from 'node:crypto';

import { requireAuth } from './auth.js';
import { getEntitlements, addCredits, activateSubscription, findUserById } from './db.js';
import {
  BILLING_PROVIDER,
  CURRENCY,
  getProduct,
  publicCatalog,
  createStripeCheckout,
  parseStripeEvent,
  RC_WEBHOOK_AUTH,
  productForStoreId,
} from './billing.js';

// Where the app/server lives publicly — used to build Stripe return URLs.
const PUBLIC_BASE_URL = (process.env.PUBLIC_BASE_URL || '').replace(/\/$/, '');

/// Client-facing entitlements shape (what the Flutter app renders).
function entitlementsDto(userId) {
  const e = getEntitlements(userId);
  return {
    credits: e.credits,
    subscriptionActive: e.subscriptionActive,
    subscriptionExpiresAt: e.subscriptionActive ? e.subExpiresAt : null,
  };
}

/// Applies a paid product to an account. Idempotent on [providerRef]. Used by
/// both the mock checkout and the Stripe webhook so fulfilment lives in one place.
function fulfill({ userId, product, provider, providerRef }) {
  const meta = {
    provider,
    providerRef,
    productId: product.id,
    amountCents: product.amountCents,
    currency: CURRENCY,
  };
  if (product.kind === 'subscription') {
    return activateSubscription(userId, product.periodMs, meta);
  }
  return addCredits(userId, product.credits, { ...meta, kind: 'purchase' });
}

export const billingRouter = express.Router();

// Current balance + the catalog to render the paywall.
billingRouter.get('/me', requireAuth, (req, res) => {
  res.json({ entitlements: entitlementsDto(req.user.id), ...publicCatalog() });
});

// Start a purchase. In mock mode we fulfil immediately and return the new
// balance; in stripe mode we return a Checkout URL for the app to open.
billingRouter.post('/checkout', requireAuth, async (req, res) => {
  // RevenueCat purchases happen natively in the app via the SDK; the server is
  // told about them through the webhook, not this endpoint.
  if (BILLING_PROVIDER === 'revenuecat') {
    return res
      .status(400)
      .json({ error: 'Purchases are made in-app on this platform.', code: 'USE_NATIVE_PURCHASE' });
  }

  const product = getProduct(req.body?.productId);
  if (!product) return res.status(400).json({ error: 'Unknown product.' });

  if (BILLING_PROVIDER === 'mock') {
    const result = fulfill({
      userId: req.user.id,
      product,
      provider: 'mock',
      providerRef: `mock_${randomUUID()}`,
    });
    console.log(`[billing] mock purchase ${product.id} by ${req.user.email} → ${JSON.stringify(entitlementsDto(req.user.id))}`);
    return res.json({
      provider: 'mock',
      completed: true,
      applied: result.applied,
      entitlements: entitlementsDto(req.user.id),
    });
  }

  // Stripe: create a hosted Checkout session.
  try {
    const user = findUserById(req.user.id);
    const base = PUBLIC_BASE_URL || `${req.protocol}://${req.get('host')}`;
    const { url, ref } = await createStripeCheckout({
      user,
      product,
      successUrl: `${base}/api/billing/return?status=success`,
      cancelUrl: `${base}/api/billing/return?status=cancel`,
    });
    console.log(`[billing] stripe checkout ${product.id} for ${user.email} (session ${ref})`);
    return res.json({ provider: 'stripe', url });
  } catch (err) {
    const status = err.status || 500;
    console.error(`[billing] checkout failed: ${err.message}`);
    return res.status(status).json({ error: err.message || 'Could not start checkout.' });
  }
});

// Stripe webhook — MUST be mounted with a raw body parser (see server.js).
// Fulfils the purchase recorded in the session metadata.
export async function stripeWebhookHandler(req, res) {
  let event;
  try {
    event = await parseStripeEvent(req.body, req.headers['stripe-signature']);
  } catch (err) {
    console.error(`[billing] webhook signature check failed: ${err.message}`);
    return res.status(400).send(`Webhook Error: ${err.message}`);
  }

  if (event.type === 'checkout.session.completed' || event.type === 'invoice.paid') {
    const session = event.data.object;
    const userId = Number(session.metadata?.userId || session.client_reference_id);
    const product = getProduct(session.metadata?.productId);
    if (userId && product) {
      fulfill({ userId, product, provider: 'stripe', providerRef: session.id });
      console.log(`[billing] fulfilled ${product.id} for user ${userId} (stripe ${session.id})`);
    } else {
      console.warn('[billing] webhook missing userId/product metadata — ignored');
    }
  }
  res.json({ received: true });
}

// RevenueCat webhook (JSON). Authenticated by the shared secret you set as the
// Authorization header in the RevenueCat dashboard. RevenueCat validates the
// App Store / Play receipt, then calls this so we grant credits / activate the
// subscription. Idempotent on the event id.
billingRouter.post('/revenuecat/webhook', (req, res) => {
  if (!RC_WEBHOOK_AUTH || req.headers.authorization !== RC_WEBHOOK_AUTH) {
    return res.status(401).json({ error: 'Unauthorized webhook.' });
  }
  const event = req.body?.event;
  if (!event) return res.status(400).json({ error: 'Missing event.' });

  // Event types that represent a payment we should fulfil. Consumables (credit
  // packs / single) arrive as NON_RENEWING_PURCHASE; subscriptions as
  // INITIAL_PURCHASE / RENEWAL (and re-grants on UNCANCELLATION).
  const FULFIL = new Set([
    'INITIAL_PURCHASE',
    'RENEWAL',
    'NON_RENEWING_PURCHASE',
    'UNCANCELLATION',
  ]);
  if (!FULFIL.has(event.type)) {
    return res.json({ ignored: event.type });
  }

  const userId = Number(event.app_user_id);
  const product = productForStoreId(event.product_id);
  if (!userId || !product) {
    console.warn(`[billing] RC webhook unmapped: user=${event.app_user_id} product=${event.product_id}`);
    return res.json({ ignored: 'no-mapping' });
  }

  const result = fulfill({
    userId,
    product,
    provider: 'revenuecat',
    providerRef: String(event.id || event.transaction_id || ''),
  });
  console.log(
    `[billing] RC ${event.type} ${product.id} for user ${userId} (applied=${result.applied !== false})`,
  );
  return res.json({ received: true });
});

// Minimal browser landing page after hosted checkout (mobile opens it in a tab).
billingRouter.get('/return', (req, res) => {
  const ok = req.query.status === 'success';
  res.set('Content-Type', 'text/html').send(`<!doctype html>
<html><head><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${ok ? 'Payment complete' : 'Checkout canceled'}</title>
<style>body{font-family:system-ui,sans-serif;background:#f3faf5;color:#13351f;
display:grid;place-items:center;height:100vh;margin:0;text-align:center}
.card{background:#fff;padding:32px 28px;border-radius:20px;box-shadow:0 10px 40px rgba(19,53,31,.08);max-width:340px}
h1{font-size:20px;margin:12px 0 6px}p{color:#5b6b60;line-height:1.5}
.dot{font-size:44px}</style></head>
<body><div class="card"><div class="dot">${ok ? '✅' : '↩️'}</div>
<h1>${ok ? 'Payment complete' : 'Checkout canceled'}</h1>
<p>${ok ? 'Your credits have been added. You can close this tab and return to the app.' : 'No charge was made. Return to the app to try again.'}</p>
</div></body></html>`);
});
