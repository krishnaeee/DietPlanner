import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:http/http.dart' as http;
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../models/billing.dart';
import 'auth_service.dart';

class BillingException implements Exception {
  final String message;
  BillingException(this.message);
  @override
  String toString() => message;
}

/// Outcome of starting a checkout.
enum CheckoutStatus {
  /// Provider fulfilled (mock instantly; RevenueCat after the store purchase +
  /// webhook). [entitlements] hold the refreshed balance.
  completed,

  /// Stripe — the hosted checkout was opened in the browser. Refresh on return.
  redirected,

  /// The user dismissed the native purchase sheet. Nothing changed.
  cancelled,
}

class CheckoutResult {
  final CheckoutStatus status;
  final Entitlements? entitlements;
  CheckoutResult(this.status, {this.entitlements});
}

/// Talks to /api/billing and (on store builds) RevenueCat. Holds the latest
/// balance + catalog and notifies the UI (the credit chip, the paywall) when
/// they change.
class BillingService {
  BillingService._();
  static final BillingService instance = BillingService._();

  final ValueNotifier<Entitlements> entitlements =
      ValueNotifier<Entitlements>(const Entitlements());

  BillingInfo? _info;
  BillingInfo? get info => _info;

  // RevenueCat state (store builds only).
  bool _rcConfigured = false;
  final Map<String, Package> _rcPackages = {}; // catalog id → RC package

  Map<String, String> get _headers {
    final token = AuthService.instance.token;
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  /// Fetches balance + catalog. On RevenueCat builds it also loads store
  /// offerings and overlays the real, localized store prices. Tolerant of
  /// network errors (keeps the last value).
  Future<BillingInfo?> refresh() async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl}/api/billing/me');
    try {
      final resp =
          await http.get(uri, headers: _headers).timeout(const Duration(seconds: 20));
      if (resp.statusCode == 200) {
        var info = BillingInfo.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
        if (info.provider == 'revenuecat') {
          await _ensureRevenueCat();
          info = _withStorePrices(info);
        }
        _info = info;
        entitlements.value = info.entitlements;
        return info;
      }
    } catch (_) {
      // Offline / server down — leave the cached values in place.
    }
    return _info;
  }

  /// Lets callers push a fresher balance returned by another endpoint (e.g. the
  /// `account` block on a successful /api/plan response).
  void applyEntitlements(Entitlements e) => entitlements.value = e;

  /// Starts a purchase. mock → fulfilled instantly. stripe → opens the hosted
  /// checkout in the browser. revenuecat → native store purchase sheet.
  Future<CheckoutResult> checkout(String productId) async {
    if (_info?.provider == 'revenuecat') {
      return _purchaseViaRevenueCat(productId);
    }
    return _checkoutViaServer(productId);
  }

  // ──────────────────────────────────────────────────── server (mock/stripe) ──

  Future<CheckoutResult> _checkoutViaServer(String productId) async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl}/api/billing/checkout');
    http.Response resp;
    try {
      resp = await http
          .post(uri, headers: _headers, body: jsonEncode({'productId': productId}))
          .timeout(const Duration(seconds: 25));
    } catch (e) {
      throw BillingException('Could not reach the server. Is the backend running? ($e)');
    }

    if (resp.statusCode != 200) throw BillingException(_errorOf(resp));

    final body = jsonDecode(resp.body) as Map<String, dynamic>;

    if (body['completed'] == true) {
      final ent = Entitlements.fromJson(
          (body['entitlements'] ?? {}) as Map<String, dynamic>);
      entitlements.value = ent;
      return CheckoutResult(CheckoutStatus.completed, entitlements: ent);
    }

    final url = body['url']?.toString();
    if (url == null || url.isEmpty) {
      throw BillingException('Checkout could not be started.');
    }
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok) throw BillingException('Could not open the checkout page.');
    return CheckoutResult(CheckoutStatus.redirected);
  }

  // ───────────────────────────────────────────────────────────── revenuecat ──

  /// Configures the RevenueCat SDK once and identifies the user (so the purchase
  /// webhook can attribute the payment), then loads the store packages. Safe to
  /// call repeatedly; a no-op on web or when no store key is configured.
  Future<void> _ensureRevenueCat() async {
    if (kIsWeb) return;
    final key = defaultTargetPlatform == TargetPlatform.iOS
        ? AppConfig.revenueCatIosKey
        : defaultTargetPlatform == TargetPlatform.android
            ? AppConfig.revenueCatAndroidKey
            : '';
    if (key.isEmpty) return; // store keys not set in this build

    final uid = AuthService.instance.userId;
    try {
      if (!_rcConfigured) {
        final cfg = PurchasesConfiguration(key);
        if (uid != null) cfg.appUserID = uid;
        await Purchases.configure(cfg);
        _rcConfigured = true;
      } else if (uid != null) {
        await Purchases.logIn(uid); // re-identify after an account switch
      }
      await _loadRcPackages();
    } catch (e) {
      debugPrint('[billing] RevenueCat init failed: $e');
    }
  }

  /// Maps the current offering's packages by their store product identifier,
  /// which we keep equal to our catalog ids (single, pack_10, pack_30, sub_monthly).
  Future<void> _loadRcPackages() async {
    final offerings = await Purchases.getOfferings();
    final packages = offerings.current?.availablePackages ?? const <Package>[];
    _rcPackages.clear();
    for (final p in packages) {
      _rcPackages[p.storeProduct.identifier] = p;
    }
  }

  /// Overlays RevenueCat's localized store price strings onto the backend
  /// catalog (falls back to the server price when a package isn't found).
  BillingInfo _withStorePrices(BillingInfo info) {
    if (_rcPackages.isEmpty) return info;
    final products = info.products.map((p) {
      final pkg = _rcPackages[p.id];
      return pkg == null ? p : p.withStorePrice(pkg.storeProduct.priceString);
    }).toList();
    return BillingInfo(
      entitlements: info.entitlements,
      provider: info.provider,
      currency: info.currency,
      products: products,
    );
  }

  Future<CheckoutResult> _purchaseViaRevenueCat(String productId) async {
    if (kIsWeb) {
      throw BillingException('In-app purchases are only available in the mobile app.');
    }
    await _ensureRevenueCat();
    final pkg = _rcPackages[productId];
    if (pkg == null) {
      throw BillingException("This item isn't available from the store yet.");
    }

    try {
      await Purchases.purchasePackage(pkg);
    } on PlatformException catch (e) {
      if (PurchasesErrorHelper.getErrorCode(e) ==
          PurchasesErrorCode.purchaseCancelledError) {
        return CheckoutResult(CheckoutStatus.cancelled);
      }
      throw BillingException(e.message ?? 'The purchase could not be completed.');
    }

    // The store receipt is validated by RevenueCat, which then calls our webhook
    // to grant credits / activate the subscription. That's asynchronous, so poll
    // our backend a few times until the new balance shows up.
    final ent = await _refreshUntilGranted();
    return CheckoutResult(CheckoutStatus.completed, entitlements: ent);
  }

  /// Re-fetches the balance a few times to let the purchase webhook land.
  Future<Entitlements> _refreshUntilGranted() async {
    final before = entitlements.value;
    for (var attempt = 0; attempt < 5; attempt++) {
      await Future<void>.delayed(Duration(milliseconds: attempt == 0 ? 800 : 1500));
      final info = await refresh();
      final now = info?.entitlements ?? entitlements.value;
      final changed = now.credits != before.credits ||
          now.subscriptionActive != before.subscriptionActive;
      if (changed) return now;
    }
    return entitlements.value;
  }

  String _errorOf(http.Response resp) {
    try {
      final e = (jsonDecode(resp.body) as Map)['error'];
      if (e is List) return e.join('\n');
      if (e is String) return e;
    } catch (_) {}
    return 'Request failed (HTTP ${resp.statusCode}).';
  }
}
