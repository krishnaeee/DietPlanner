import 'package:flutter/material.dart';

import '../models/billing.dart';
import '../services/billing_service.dart';
import '../theme/app_theme.dart';
import '../widgets/fresh.dart';

/// The paywall: shows the current balance and the three ways to pay —
/// pay-per-generation (a single plan), credit packs, and an unlimited
/// subscription. Works with the mock provider (instant) and Stripe (browser).
class PaywallScreen extends StatefulWidget {
  /// Optional line explaining why the paywall appeared (e.g. after a 402).
  final String? reason;
  const PaywallScreen({super.key, this.reason});

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  late Future<BillingInfo?> _future;
  String? _busyProductId; // product currently being purchased

  @override
  void initState() {
    super.initState();
    _future = BillingService.instance.refresh();
  }

  Future<void> _buy(Product product) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busyProductId = product.id);
    try {
      final result = await BillingService.instance.checkout(product.id);
      if (!mounted) return;
      if (result.status == CheckoutStatus.cancelled) {
        return; // user dismissed the purchase sheet — no message, no change
      }
      if (result.status == CheckoutStatus.completed) {
        messenger.showSnackBar(SnackBar(
          content: Text(product.isSubscription
              ? "You're now unlimited 🎉"
              : '${product.credits} credit${product.credits == 1 ? '' : 's'} added 🎉'),
        ));
        Navigator.of(context).pop(true); // tell the opener a purchase happened
      } else {
        // Stripe opened in the browser — refresh balance when they come back.
        await _future;
        if (!mounted) return;
        setState(() => _future = BillingService.instance.refresh());
        messenger.showSnackBar(const SnackBar(
          content: Text('Finish the payment in your browser, then come back.'),
        ));
      }
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _busyProductId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const FreshHeader(
            title: 'Plans & credits',
            subtitle: 'Pay only when you generate, save with a pack, or go unlimited.',
            showBack: true,
          ),
          Expanded(
            child: FutureBuilder<BillingInfo?>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final info = snap.data;
                if (info == null) {
                  return _Retry(onRetry: () {
                    setState(() => _future = BillingService.instance.refresh());
                  });
                }
                return _Catalog(
                  info: info,
                  reason: widget.reason,
                  busyProductId: _busyProductId,
                  onBuy: _buy,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Catalog extends StatelessWidget {
  final BillingInfo info;
  final String? reason;
  final String? busyProductId;
  final void Function(Product) onBuy;
  const _Catalog({
    required this.info,
    required this.reason,
    required this.busyProductId,
    required this.onBuy,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final sub = info.subscription;
    final single = info.creditProducts.where((p) => p.credits == 1).firstOrNull;
    final packs = info.creditProducts.where((p) => p.credits > 1).toList();
    final busy = busyProductId != null;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
      children: [
        if (reason != null) ...[
          _ReasonBanner(text: reason!),
          const SizedBox(height: 14),
        ],
        _BalanceCard(entitlements: info.entitlements),
        const SizedBox(height: 22),

        if (sub != null) ...[
          _SectionLabel('Go unlimited'),
          const SizedBox(height: 10),
          _SubscriptionCard(
            product: sub,
            active: info.entitlements.subscriptionActive,
            busy: busyProductId == sub.id,
            disabled: busy && busyProductId != sub.id,
            onBuy: () => onBuy(sub),
          ),
          const SizedBox(height: 22),
        ],

        if (single != null) ...[
          _SectionLabel('Pay as you go'),
          const SizedBox(height: 10),
          _ProductCard(
            product: single,
            icon: Icons.bolt_rounded,
            busy: busyProductId == single.id,
            disabled: busy && busyProductId != single.id,
            onBuy: () => onBuy(single),
          ),
          const SizedBox(height: 22),
        ],

        if (packs.isNotEmpty) ...[
          _SectionLabel('Save with a pack'),
          const SizedBox(height: 10),
          for (final p in packs) ...[
            _ProductCard(
              product: p,
              icon: Icons.local_grocery_store_rounded,
              busy: busyProductId == p.id,
              disabled: busy && busyProductId != p.id,
              onBuy: () => onBuy(p),
            ),
            const SizedBox(height: 12),
          ],
        ],

        const SizedBox(height: 8),
        Text(
          info.provider == 'mock'
              ? 'Test mode — purchases are simulated, no real charge.'
              : 'Payments are processed securely. Cancel anytime.',
          textAlign: TextAlign.center,
          style: text.bodySmall?.copyWith(color: AppColors.inkFaint),
        ),
      ],
    );
  }
}

class _BalanceCard extends StatelessWidget {
  final Entitlements entitlements;
  const _BalanceCard({required this.entitlements});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final unlimited = entitlements.subscriptionActive;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: AppColors.brandGradient,
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: softShadow(opacity: 0.18, blur: 24, y: 10),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              unlimited ? Icons.all_inclusive_rounded : Icons.stars_rounded,
              color: Colors.white,
              size: 30,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your balance',
                    style: text.bodySmall
                        ?.copyWith(color: Colors.white.withValues(alpha: 0.85))),
                const SizedBox(height: 2),
                Text(
                  unlimited
                      ? 'Unlimited'
                      : '${entitlements.credits} credit${entitlements.credits == 1 ? '' : 's'}',
                  style: text.headlineSmall
                      ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                ),
                if (unlimited && entitlements.subscriptionExpiresAt != null)
                  Text(
                    'Renews ${_fmtDate(entitlements.subscriptionExpiresAt!)}',
                    style: text.bodySmall
                        ?.copyWith(color: Colors.white.withValues(alpha: 0.85)),
                  )
                else
                  Text('1 credit = 1 diet plan',
                      style: text.bodySmall
                          ?.copyWith(color: Colors.white.withValues(alpha: 0.85))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SubscriptionCard extends StatelessWidget {
  final Product product;
  final bool active;
  final bool busy;
  final bool disabled;
  final VoidCallback onBuy;
  const _SubscriptionCard({
    required this.product,
    required this.active,
    required this.busy,
    required this.disabled,
    required this.onBuy,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.brand, width: 2),
        boxShadow: softShadow(),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.all_inclusive_rounded, color: AppColors.brand),
              const SizedBox(width: 10),
              Expanded(
                child: Text(product.title,
                    style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              ),
              Text(product.priceLabel,
                  style: text.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800, color: AppColors.brandDark)),
              Text('/mo', style: text.bodySmall?.copyWith(color: AppColors.inkMuted)),
            ],
          ),
          const SizedBox(height: 6),
          Text(product.description,
              style: text.bodyMedium?.copyWith(color: AppColors.inkMuted)),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: (active || disabled) ? null : onBuy,
              child: busy
                  ? const _BtnSpinner()
                  : Text(active ? 'Active' : 'Go unlimited'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProductCard extends StatelessWidget {
  final Product product;
  final IconData icon;
  final bool busy;
  final bool disabled;
  final VoidCallback onBuy;
  const _ProductCard({
    required this.product,
    required this.icon,
    required this.busy,
    required this.disabled,
    required this.onBuy,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Opacity(
      opacity: disabled ? 0.5 : 1,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(
            color: product.bestValue ? AppColors.accent : AppColors.line,
            width: product.bestValue ? 2 : 1,
          ),
          boxShadow: softShadow(opacity: 0.05, blur: 16, y: 6),
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.brand.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: AppColors.brand),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(product.title,
                            style:
                                text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                      ),
                      if (product.bestValue) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.accent.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text('BEST VALUE',
                              style: text.labelSmall?.copyWith(
                                  color: AppColors.accent,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.4)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    product.perCreditLabel == null
                        ? product.description
                        : '${product.description} · ${product.perCreditLabel}',
                    style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              height: 40,
              child: FilledButton(
                onPressed: disabled ? null : onBuy,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                child: busy
                    ? const _BtnSpinner()
                    : Text(product.priceLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BtnSpinner extends StatelessWidget {
  const _BtnSpinner();
  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      );
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .titleMedium
            ?.copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _ReasonBanner extends StatelessWidget {
  final String text;
  const _ReasonBanner({required this.text});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, color: AppColors.accent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.ink, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

class _Retry extends StatelessWidget {
  final VoidCallback onRetry;
  const _Retry({required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_rounded, color: AppColors.inkFaint, size: 40),
          const SizedBox(height: 12),
          const Text("Couldn't load plans"),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

String _fmtDate(DateTime d) {
  const mo = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${d.day} ${mo[d.month - 1]}';
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
