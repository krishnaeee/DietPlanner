import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/tracking.dart';
import '../theme/app_theme.dart';
import 'fresh.dart';

/// A common off-plan item with typical values. Presets mean logging a tea is one
/// tap — no LLM call, no credit, works offline. Anything unusual can still be
/// typed in with your own calorie figure.
class ExtraPreset {
  final String name;
  final int calories;
  final int protein;
  final int carbs;
  final int fat;
  const ExtraPreset(this.name, this.calories, this.protein, this.carbs, this.fat);
}

/// Rough, everyday values — deliberately approximate. The point is that the
/// day's total stops pretending the tea didn't happen, not gram-accuracy.
const kExtraPresets = <ExtraPreset>[
  ExtraPreset('Tea with milk', 60, 2, 9, 2),
  ExtraPreset('Black / green tea', 2, 0, 0, 0),
  ExtraPreset('Coffee with milk', 90, 3, 12, 3),
  ExtraPreset('Black coffee', 5, 0, 1, 0),
  ExtraPreset('Biscuits (2)', 100, 1, 14, 4),
  ExtraPreset('Banana', 105, 1, 27, 0),
  ExtraPreset('Handful of nuts', 170, 6, 6, 15),
  ExtraPreset('Buttermilk', 40, 3, 5, 1),
  ExtraPreset('Samosa', 260, 4, 30, 14),
  ExtraPreset('Soft drink', 140, 0, 35, 0),
  ExtraPreset('Chocolate (30g)', 170, 2, 13, 12),
];

/// Bottom sheet for logging an off-plan item on [dayIndex]. Returns the new
/// item, or null if dismissed.
Future<ExtraItem?> showAddExtraSheet(BuildContext context, int dayIndex) {
  return showModalBottomSheet<ExtraItem>(
    context: context,
    isScrollControlled: true, // so the keyboard doesn't cover the fields
    useSafeArea: true, // keep content clear of the status bar / home indicator
    backgroundColor: Colors.transparent,
    builder: (_) => _AddExtraSheet(dayIndex: dayIndex),
  );
}

class _AddExtraSheet extends StatefulWidget {
  final int dayIndex;
  const _AddExtraSheet({required this.dayIndex});

  @override
  State<_AddExtraSheet> createState() => _AddExtraSheetState();
}

class _AddExtraSheetState extends State<_AddExtraSheet> {
  final _name = TextEditingController();
  final _kcal = TextEditingController();
  ExtraPreset? _picked;

  @override
  void dispose() {
    _name.dispose();
    _kcal.dispose();
    super.dispose();
  }

  void _choose(ExtraPreset p) {
    setState(() {
      // Tapping the selected chip again clears it.
      if (_picked?.name == p.name) {
        _picked = null;
        _name.clear();
        _kcal.clear();
        return;
      }
      _picked = p;
      _name.text = p.name;
      _kcal.text = '${p.calories}';
    });
  }

  bool get _valid =>
      _name.text.trim().isNotEmpty && (int.tryParse(_kcal.text.trim()) ?? -1) >= 0;

  void _save() {
    final name = _name.text.trim();
    final kcal = int.tryParse(_kcal.text.trim()) ?? 0;
    // Macros only come from a preset the user didn't edit the calories of —
    // guessing macros for a typed-in item would be fiction.
    final usePresetMacros = _picked != null &&
        _picked!.name == name &&
        _picked!.calories == kcal;
    Navigator.of(context).pop(ExtraItem(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      dayIndex: widget.dayIndex,
      name: name,
      calories: kcal,
      protein: usePresetMacros ? _picked!.protein : 0,
      carbs: usePresetMacros ? _picked!.carbs : 0,
      fat: usePresetMacros ? _picked!.fat : 0,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      // Lift above the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: AppColors.line),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.line,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text('Add something extra',
                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text(
                'Anything you ate that the plan didn\'t include — it counts toward the day.',
                style: text.bodySmall
                    ?.copyWith(color: AppColors.inkMuted, height: 1.4),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: kExtraPresets
                    .map((p) => _PresetChip(
                          label: p.name,
                          kcal: p.calories,
                          selected: _picked?.name == p.name,
                          onTap: () => _choose(p),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _name,
                onChanged: (_) => setState(() {}),
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'What did you have?',
                  hintText: 'e.g. two idlis at the canteen',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _kcal,
                onChanged: (_) => setState(() {}),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Calories (kcal)',
                  hintText: 'your best estimate is fine',
                ),
              ),
              const SizedBox(height: 20),
              IgnorePointer(
                ignoring: !_valid,
                child: Opacity(
                  opacity: _valid ? 1 : 0.45,
                  child: GradientButton(
                    label: 'Add to this day',
                    icon: Icons.add_rounded,
                    onPressed: _save,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  final String label;
  final int kcal;
  final bool selected;
  final VoidCallback onTap;
  const _PresetChip({
    required this.label,
    required this.kcal,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: motion(context, 140),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.brand : AppColors.fieldFill,
          borderRadius: BorderRadius.circular(AppRadius.chip),
          border: Border.all(color: selected ? AppColors.brand : AppColors.line),
        ),
        child: Text(
          '$label · $kcal',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : AppColors.inkMuted,
          ),
        ),
      ),
    );
  }
}

/// One logged off-plan item, with a quiet remove action.
class ExtraRow extends StatelessWidget {
  final ExtraItem item;
  final VoidCallback onRemove;
  const ExtraRow({super.key, required this.item, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 11, 6, 11),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: [
          Icon(Icons.local_cafe_rounded, size: 17, color: AppColors.inkFaint),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          Text('${item.calories} kcal',
              style: text.bodySmall?.copyWith(
                  color: AppColors.inkMuted, fontWeight: FontWeight.w700)),
          IconButton(
            icon: Icon(Icons.close_rounded, size: 17, color: AppColors.inkFaint),
            tooltip: 'Remove',
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// Ghost button that opens the "add something extra" sheet.
class AddExtraButton extends StatelessWidget {
  final VoidCallback onTap;
  const AddExtraButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.line),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_rounded, size: 17, color: AppColors.brand),
              const SizedBox(width: 8),
              Text('Add something extra',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.brand, fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      ),
    );
  }
}
