import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/diet_plan.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// A consolidated shopping list for a window of days (default: the next 7 from
/// the day the user was viewing). Ingredients are deduped by name and their
/// quantities summed per unit where they can be parsed (e.g. "2 cups" + "1 cup"
/// → "3 cups"); unparseable amounts like "to taste" are kept verbatim.
///
/// Check-off state lives only while the screen is open — it's a shopping aid,
/// not persisted progress (that's what the meal checks on the plan screen are).
class GroceryListScreen extends StatefulWidget {
  final DietPlan plan;

  /// Index into [plan.days] to start the window at (the day being viewed).
  final int startIndex;

  /// How many days the list covers.
  final int windowDays;

  const GroceryListScreen({
    super.key,
    required this.plan,
    this.startIndex = 0,
    this.windowDays = 7,
  });

  @override
  State<GroceryListScreen> createState() => _GroceryListScreenState();
}

class _GroceryListScreenState extends State<GroceryListScreen> {
  late final List<DayPlan> _window;
  late final List<_Item> _items;
  final Set<String> _checked = {};

  @override
  void initState() {
    super.initState();
    final days = widget.plan.days;
    final start = widget.startIndex.clamp(0, days.isEmpty ? 0 : days.length - 1);
    final end = (start + widget.windowDays).clamp(0, days.length);
    _window = days.sublist(start, end);
    _items = _aggregate(_window);
  }

  int get _firstDay => _window.isEmpty ? 0 : _window.first.day;
  int get _lastDay => _window.isEmpty ? 0 : _window.last.day;
  int get _doneCount => _items.where((i) => _checked.contains(i.key)).length;

  void _toggle(String key) {
    setState(() {
      if (!_checked.add(key)) _checked.remove(key);
    });
  }

  Future<void> _copyToClipboard() async {
    final messenger = ScaffoldMessenger.of(context);
    final buffer = StringBuffer()
      ..writeln('Grocery list · Day $_firstDay–$_lastDay');
    for (final item in _items) {
      buffer.writeln(
          '• ${item.name}${item.quantity.isEmpty ? '' : ' — ${item.quantity}'}');
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString().trimRight()));
    messenger.showSnackBar(
      const SnackBar(content: Text('Grocery list copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final dayLabel = _window.length == 1
        ? 'Day $_firstDay'
        : 'Day $_firstDay–$_lastDay';
    final sub = _items.isEmpty
        ? dayLabel
        : '$dayLabel · ${_items.length} items';

    return Scaffold(
      body: Column(
        children: [
          GradientHeader(
            title: 'Grocery list',
            subtitle: sub,
            showBack: true,
            trailing: _items.isEmpty
                ? null
                : _HeaderAction(
                    icon: Icons.copy_rounded,
                    label: 'Copy',
                    onTap: _copyToClipboard,
                  ),
          ),
          Expanded(
            child: _items.isEmpty
                ? _EmptyState(text: text)
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
                    children: [
                      _ProgressCard(done: _doneCount, total: _items.length),
                      const SizedBox(height: 16),
                      SectionCard(
                        title: 'Everything you need',
                        icon: Icons.shopping_cart_rounded,
                        padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
                        child: Column(
                          children: [
                            for (var i = 0; i < _items.length; i++) ...[
                              if (i > 0)
                                const Divider(height: 1, indent: 12, endIndent: 12),
                              _GroceryRow(
                                item: _items[i],
                                checked: _checked.contains(_items[i].key),
                                onTap: () => _toggle(_items[i].key),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Quantities are summed across the ${_window.length} '
                        'day${_window.length == 1 ? '' : 's'} shown. '
                        'Tap an item to tick it off while you shop.',
                        textAlign: TextAlign.center,
                        style: text.bodySmall?.copyWith(color: AppColors.inkFaint),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────── aggregation logic ──

class _Item {
  final String key; // lowercased name, used for dedupe + check state
  final String name; // first-seen display casing
  final String quantity; // combined, human-readable
  _Item({required this.key, required this.name, required this.quantity});
}

/// Dedupe ingredients by name across [days] and combine their quantities.
List<_Item> _aggregate(List<DayPlan> days) {
  // Preserve first-seen casing and accumulate quantities per ingredient.
  final order = <String>[];
  final display = <String, String>{};
  final unitSums = <String, Map<String, double>>{}; // name → unit → total
  final freeform = <String, List<String>>{}; // name → unparseable amounts

  for (final day in days) {
    for (final meal in day.meals) {
      for (final ing in meal.ingredients) {
        final key = ing.name.toLowerCase().trim();
        if (key.isEmpty) continue;
        if (!display.containsKey(key)) {
          order.add(key);
          display[key] = ing.name.trim();
          unitSums[key] = {};
          freeform[key] = [];
        }
        final qty = ing.quantity.trim();
        if (qty.isEmpty) continue;
        final parsed = _parseQty(qty);
        if (parsed == null) {
          if (!freeform[key]!.contains(qty)) freeform[key]!.add(qty);
        } else {
          unitSums[key]![parsed.$2] =
              (unitSums[key]![parsed.$2] ?? 0) + parsed.$1;
        }
      }
    }
  }

  final items = order.map((key) {
    final parts = <String>[];
    unitSums[key]!.forEach((unit, total) {
      parts.add(unit.isEmpty ? _fmtNum(total) : '${_fmtNum(total)} $unit');
    });
    parts.addAll(freeform[key]!);
    return _Item(key: key, name: display[key]!, quantity: parts.join(' + '));
  }).toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return items;
}

/// Splits a quantity like "2 cups" / "1/2 tsp" / "200g" into (amount, unit).
/// Returns null when there's no leading number (e.g. "to taste", "a pinch").
(double, String)? _parseQty(String raw) {
  final m = RegExp(r'^([0-9][0-9.\s/]*?)\s*([^\d].*)?$').firstMatch(raw.trim());
  if (m == null) return null;
  final amount = _parseNumber((m.group(1) ?? '').trim());
  if (amount == null) return null;
  return (amount, (m.group(2) ?? '').trim().toLowerCase());
}

/// Parses plain decimals, fractions ("1/2"), and mixed numbers ("1 1/2").
double? _parseNumber(String t) {
  if (t.isEmpty) return null;
  if (!t.contains('/')) return double.tryParse(t);
  var total = 0.0;
  var any = false;
  for (final token in t.split(RegExp(r'\s+'))) {
    if (token.isEmpty) continue;
    if (token.contains('/')) {
      final f = token.split('/');
      if (f.length != 2) return null;
      final a = double.tryParse(f[0]);
      final b = double.tryParse(f[1]);
      if (a == null || b == null || b == 0) return null;
      total += a / b;
    } else {
      final v = double.tryParse(token);
      if (v == null) return null;
      total += v;
    }
    any = true;
  }
  return any ? total : null;
}

/// Trims trailing zeros: 3.0 → "3", 1.5 → "1.5", 0.33 → "0.33".
String _fmtNum(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

// ─────────────────────────────────────────────────────────────────── widgets ──

class _GroceryRow extends StatelessWidget {
  final _Item item;
  final bool checked;
  final VoidCallback onTap;
  const _GroceryRow({required this.item, required this.checked, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            _CheckBox(checked: checked),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                item.name,
                style: text.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: checked ? AppColors.inkFaint : AppColors.ink,
                  decoration: checked ? TextDecoration.lineThrough : null,
                  decorationColor: AppColors.inkFaint,
                ),
              ),
            ),
            if (item.quantity.isNotEmpty) ...[
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: checked
                      ? AppColors.fieldFill
                      : AppColors.brand.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  item.quantity,
                  style: text.bodySmall?.copyWith(
                    color: checked ? AppColors.inkFaint : AppColors.brandDark,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CheckBox extends StatelessWidget {
  final bool checked;
  const _CheckBox({required this.checked});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: checked ? AppColors.brand : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: checked ? AppColors.brand : AppColors.line,
          width: 2,
        ),
      ),
      child: checked
          ? const Icon(Icons.check_rounded, size: 18, color: Colors.white)
          : null,
    );
  }
}

class _ProgressCard extends StatelessWidget {
  final int done;
  final int total;
  const _ProgressCard({required this.done, required this.total});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final pct = total == 0 ? 0.0 : done / total;
    return SectionCard(
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.brand.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.shopping_basket_rounded,
                color: AppColors.brand, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$done of $total in the basket',
                    style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: pct,
                    minHeight: 8,
                    backgroundColor: AppColors.line,
                    valueColor: const AlwaysStoppedAnimation(AppColors.brand),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final TextTheme text;
  const _EmptyState({required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: AppColors.brand.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.remove_shopping_cart_rounded,
                  color: AppColors.brand, size: 40),
            ),
            const SizedBox(height: 20),
            Text('No ingredients to list',
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Text(
              'The days in this window have no ingredients yet.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pill button used in the gradient header (mirrors the plan screen's action).
class _HeaderAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _HeaderAction(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(AppRadius.pill),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
