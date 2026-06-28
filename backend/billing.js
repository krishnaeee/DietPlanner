// Billing catalog + payment-provider abstraction.
//
// Three ways to pay, all settling into one credit balance (a subscription
// instead grants unlimited generations for its period):
//   • single        — pay-per-generation, 1 credit, small price
//   • pack_10 / 30   — credit bundles (cheaper per credit)
//   • sub_monthly    — unlimited plans for 30 days
//
// Provider is chosen by BILLING_PROVIDER:
//   • mock   (default) — no keys needed; checkout fulfils instantly. For dev.
//   • stripe           — hosted Stripe Checkout + webhook fulfilment.

export const CURRENCY = (process.env.BILLING_CURRENCY || 'usd').toLowerCase();
export const BILLING_PROVIDER = (process.env.BILLING_PROVIDER || 'mock').toLowerCase();

// Free credits handed to a brand-new account so they can try the app once.
export const SIGNUP_FREE_CREDITS = Number(process.env.SIGNUP_FREE_CREDITS ?? 3);

export const SUBSCRIPTION_PERIOD_MS = 30 * 24 * 60 * 60 * 1000; // 30 days

// Amounts are in the currency's smallest unit (cents/paise). Override any price
// via env (BILLING_PRICE_<ID>) without touching code.
const priceOf = (id, fallback) => Number(process.env[`BILLING_PRICE_${id.toUpperCase()}`] ?? fallback);

/// The product catalog. `kind` drives fulfilment: credits → addCredits,
/// subscription → activateSubscription.
export const PRODUCTS = [
  {
    id: 'single',
    kind: 'credits',
    credits: 1,
    title: 'Single plan',
    description: 'Generate one diet plan',
    amountCents: priceOf('single', 99),
  },
  {
    id: 'pack_10',
    kind: 'credits',
    credits: 10,
    title: '10 plans',
    description: 'Best for a few people or restarts',
    amountCents: priceOf('pack_10', 699),
  },
  {
    id: 'pack_30',
    kind: 'credits',
    credits: 30,
    title: '30 plans',
    description: 'Lowest price per plan',
    amountCents: priceOf('pack_30', 1499),
    bestValue: true,
  },
  {
    id: 'sub_monthly',
    kind: 'subscription',
    periodMs: SUBSCRIPTION_PERIOD_MS,
    title: 'Unlimited (monthly)',
    description: 'As many plans as you want for 30 days',
    amountCents: priceOf('sub_monthly', 999),
    recurring: true,
  },
];

export const getProduct = (id) => PRODUCTS.find((p) => p.id === id) || null;

// ───────────────────────────────────────────────────────────── revenuecat ──
// Shared secret you set as the Authorization header in the RevenueCat dashboard
// webhook config — lets the backend trust incoming webhook calls.
export const RC_WEBHOOK_AUTH = process.env.REVENUECAT_WEBHOOK_AUTH || '';

// Optional map of store product identifiers → our catalog ids, in case the
// App Store / Play Console product ids differ from ours. Defaults to identity
// (configure store products with the same ids: single, pack_10, pack_30,
// sub_monthly) so no mapping is needed.
let RC_PRODUCT_MAP = {};
try {
  RC_PRODUCT_MAP = JSON.parse(process.env.REVENUECAT_PRODUCT_MAP || '{}');
} catch (_) {
  console.warn('[billing] REVENUECAT_PRODUCT_MAP is not valid JSON — ignoring.');
}

/// Resolves a store product identifier from a RevenueCat webhook to our catalog
/// product (applying REVENUECAT_PRODUCT_MAP first, then a direct id match).
export const productForStoreId = (storeId) =>
  getProduct(RC_PRODUCT_MAP[storeId] || storeId);

// Symbol-only formatter for the few currencies we expect; falls back to the
// uppercased code. Keeps the client free of any money-formatting logic.
const SYMBOLS = { usd: '$', inr: '₹', eur: '€', gbp: '£', aud: 'A$', cad: 'C$' };
export function formatPrice(amountCents, currency = CURRENCY) {
  const symbol = SYMBOLS[currency] || `${currency.toUpperCase()} `;
  const major = amountCents / 100;
  const text = Number.isInteger(major) ? major.toString() : major.toFixed(2);
  return `${symbol}${text}`;
}

/// Shapes a product for the client, with a ready-to-show price label and, for
/// credit packs, the per-plan unit price.
export function publicProduct(p) {
  const out = {
    id: p.id,
    kind: p.kind,
    title: p.title,
    description: p.description,
    amountCents: p.amountCents,
    currency: CURRENCY,
    priceLabel: formatPrice(p.amountCents),
    bestValue: !!p.bestValue,
    recurring: !!p.recurring,
  };
  if (p.kind === 'credits') {
    out.credits = p.credits;
    if (p.credits > 1) out.perCreditLabel = `${formatPrice(Math.round(p.amountCents / p.credits))}/plan`;
  }
  return out;
}

export const publicCatalog = () => ({
  provider: BILLING_PROVIDER,
  currency: CURRENCY,
  products: PRODUCTS.map(publicProduct),
});

// ─────────────────────────────────────────────────────────────── provider ──

let _stripe = null;
async function stripe() {
  if (_stripe) return _stripe;
  const key = process.env.STRIPE_SECRET_KEY;
  if (!key) throw httpError(500, 'Stripe is not configured (STRIPE_SECRET_KEY missing).');
  // Lazy + dynamic so the app runs in mock mode without the package installed.
  let Stripe;
  try {
    ({ default: Stripe } = await import('stripe'));
  } catch (_) {
    throw httpError(500, "Stripe mode requires the 'stripe' package — run: npm install stripe");
  }
  _stripe = new Stripe(key);
  return _stripe;
}

function httpError(status, message) {
  const e = new Error(message);
  e.status = status;
  return e;
}

/// Creates a Stripe Checkout Session for [product] and returns its URL + the
/// session id (used as provider_ref at fulfilment). Metadata carries the user
/// and product so the webhook knows what to grant.
export async function createStripeCheckout({ user, product, successUrl, cancelUrl }) {
  const s = await stripe();
  const session = await s.checkout.sessions.create({
    mode: product.kind === 'subscription' ? 'subscription' : 'payment',
    success_url: successUrl,
    cancel_url: cancelUrl,
    client_reference_id: String(user.id),
    customer_email: user.email,
    metadata: { userId: String(user.id), productId: product.id },
    line_items: [
      {
        quantity: 1,
        price_data: {
          currency: CURRENCY,
          unit_amount: product.amountCents,
          product_data: { name: product.title, description: product.description },
          ...(product.kind === 'subscription'
            ? { recurring: { interval: 'month' } }
            : {}),
        },
      },
    ],
  });
  return { url: session.url, ref: session.id };
}

/// Verifies and parses a Stripe webhook payload. Returns the Stripe event.
export async function parseStripeEvent(rawBody, signature) {
  const s = await stripe();
  const secret = process.env.STRIPE_WEBHOOK_SECRET;
  if (!secret) throw httpError(500, 'STRIPE_WEBHOOK_SECRET is not set.');
  return s.webhooks.constructEvent(rawBody, signature, secret);
}
