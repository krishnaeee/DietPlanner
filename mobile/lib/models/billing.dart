// Billing models mirroring the backend's /api/billing/me shape.

int _toInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.round();
  return int.tryParse('$v') ?? 0;
}

/// A user's current spending power.
class Entitlements {
  final int credits;
  final bool subscriptionActive;
  final DateTime? subscriptionExpiresAt;

  const Entitlements({
    this.credits = 0,
    this.subscriptionActive = false,
    this.subscriptionExpiresAt,
  });

  /// Can the user generate a plan right now without paying?
  bool get canGenerate => subscriptionActive || credits > 0;

  factory Entitlements.fromJson(Map<String, dynamic> j) => Entitlements(
        credits: _toInt(j['credits']),
        subscriptionActive: j['subscriptionActive'] == true,
        subscriptionExpiresAt: j['subscriptionExpiresAt'] != null
            ? DateTime.tryParse(j['subscriptionExpiresAt'].toString())
            : null,
      );
}

/// A purchasable item: a single plan, a credit pack, or the subscription.
class Product {
  final String id;
  final String kind; // 'credits' | 'subscription'
  final String title;
  final String description;
  final String priceLabel; // e.g. "$6.99" / "₹14.99"
  final int amountCents;
  final String currency;
  final int credits; // 0 for subscriptions
  final String? perCreditLabel; // e.g. "$0.50/plan" (packs only)
  final bool bestValue;
  final bool recurring;

  const Product({
    required this.id,
    required this.kind,
    required this.title,
    required this.description,
    required this.priceLabel,
    required this.amountCents,
    required this.currency,
    this.credits = 0,
    this.perCreditLabel,
    this.bestValue = false,
    this.recurring = false,
  });

  bool get isSubscription => kind == 'subscription';

  /// Returns a copy with the store-localized price label (and clears the
  /// per-credit hint, which we can't recompute from the localized string).
  Product withStorePrice(String label) => Product(
        id: id,
        kind: kind,
        title: title,
        description: description,
        priceLabel: label,
        amountCents: amountCents,
        currency: currency,
        credits: credits,
        perCreditLabel: null,
        bestValue: bestValue,
        recurring: recurring,
      );

  factory Product.fromJson(Map<String, dynamic> j) => Product(
        id: (j['id'] ?? '').toString(),
        kind: (j['kind'] ?? 'credits').toString(),
        title: (j['title'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
        priceLabel: (j['priceLabel'] ?? '').toString(),
        amountCents: _toInt(j['amountCents']),
        currency: (j['currency'] ?? '').toString(),
        credits: _toInt(j['credits']),
        perCreditLabel: j['perCreditLabel']?.toString(),
        bestValue: j['bestValue'] == true,
        recurring: j['recurring'] == true,
      );
}

/// The full paywall payload: balance + catalog + which provider is active.
class BillingInfo {
  final Entitlements entitlements;
  final String provider; // 'mock' | 'stripe'
  final String currency;
  final List<Product> products;

  const BillingInfo({
    required this.entitlements,
    required this.provider,
    required this.currency,
    required this.products,
  });

  List<Product> get creditProducts =>
      products.where((p) => p.kind == 'credits').toList();
  Product? get subscription =>
      products.where((p) => p.isSubscription).firstOrNull;

  factory BillingInfo.fromJson(Map<String, dynamic> j) => BillingInfo(
        entitlements:
            Entitlements.fromJson((j['entitlements'] ?? {}) as Map<String, dynamic>),
        provider: (j['provider'] ?? 'mock').toString(),
        currency: (j['currency'] ?? '').toString(),
        products: ((j['products'] as List?) ?? [])
            .map((e) => Product.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
