import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/billing_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'paywall_screen.dart';
import 'plan_screen.dart';

/// The plan-generation form. Reached from the home's "New plan" / add button.
/// On generate it replaces itself with the [PlanScreen], so backing out of the
/// plan returns to the home list.
class AddPlanScreen extends StatefulWidget {
  const AddPlanScreen({super.key});

  @override
  State<AddPlanScreen> createState() => _AddPlanScreenState();
}

class _AddPlanScreenState extends State<AddPlanScreen> {
  final _formKey = GlobalKey<FormState>();

  // Pre-filled defaults for quick testing. Clear these for production.
  final _weight = TextEditingController(text: '75');
  final _height = TextEditingController(text: '163');
  final _location = TextEditingController(text: 'pollachi');
  final _targetWeight = TextEditingController(text: '65');
  final _period = TextEditingController(text: '24');
  final _age = TextEditingController(text: '36');
  final _dietPref = TextEditingController();
  final _planName = TextEditingController();

  String _periodUnit = 'weeks'; // 'weeks' | 'days'
  String _sex = 'male'; // male | female | other
  String _activity = 'light'; // sedentary ... very_active

  @override
  void initState() {
    super.initState();
    // Refresh the live goal indicator as weights change.
    _weight.addListener(_refresh);
    _targetWeight.addListener(_refresh);
  }

  void _refresh() => setState(() {});

  void _openPaywall() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PaywallScreen()),
    );
  }

  @override
  void dispose() {
    _weight.dispose();
    _height.dispose();
    _location.dispose();
    _targetWeight.dispose();
    _period.dispose();
    _age.dispose();
    _dietPref.dispose();
    _planName.dispose();
    super.dispose();
  }

  String? _requiredNumber(String? v, {double min = 0, double max = 1000}) {
    if (v == null || v.trim().isEmpty) return 'Required';
    final n = double.tryParse(v.trim());
    if (n == null) return 'Enter a number';
    if (n <= min || n >= max) return 'Out of range';
    return null;
  }

  void _submit() {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fix the highlighted fields.')),
      );
      return;
    }

    // If we already know there's no balance, show the paywall up front rather
    // than navigating in and bouncing off the backend's 402. (The backend is
    // still the source of truth — this is just a faster path.)
    if (!BillingService.instance.entitlements.value.canGenerate) {
      _openPaywall();
      return;
    }

    final periodValue = int.parse(_period.text.trim());
    final targetDays = _periodUnit == 'weeks' ? periodValue * 7 : periodValue;

    final body = <String, dynamic>{
      'weightKg': double.parse(_weight.text.trim()),
      'heightCm': double.parse(_height.text.trim()),
      'location': _location.text.trim(),
      'targetWeightKg': double.parse(_targetWeight.text.trim()),
      'targetDays': targetDays,
      if (_age.text.trim().isNotEmpty) 'age': int.tryParse(_age.text.trim()),
      'sex': _sex,
      'activityLevel': _activity,
      if (_dietPref.text.trim().isNotEmpty) 'dietaryPreference': _dietPref.text.trim(),
    };

    // Replace this form with the plan so backing out of the plan lands on home.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => PlanScreen(
          requestBody: body,
          location: _location.text.trim(),
          planName: _planName.text.trim(),
        ),
      ),
    );
  }

  ({String label, Color color, IconData icon})? get _goal {
    final w = double.tryParse(_weight.text.trim());
    final t = double.tryParse(_targetWeight.text.trim());
    if (w == null || t == null || w <= 0 || t <= 0) return null;
    final diff = w - t;
    String fmt(double d) {
      final s = d.toStringAsFixed(1);
      return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
    }

    if (diff > 0.5) {
      return (label: 'Lose ${fmt(diff)} kg', color: AppColors.brand, icon: Icons.trending_down_rounded);
    }
    if (diff < -0.5) {
      return (label: 'Gain ${fmt(-diff)} kg', color: AppColors.accent, icon: Icons.trending_up_rounded);
    }
    return (label: 'Maintain weight', color: AppColors.dinner, icon: Icons.trending_flat_rounded);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const GradientHeader(
            title: 'New plan',
            subtitle: 'Tell us a little about you and we\'ll build a day-by-day plan with food local to you.',
            showBack: true,
          ),
          Expanded(
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
                children: [
                  SectionCard(
                    title: 'Who is this for?',
                    icon: Icons.badge_outlined,
                    child: _LabeledField(
                      label: 'Plan name',
                      controller: _planName,
                      hint: 'e.g. Me, Wife, Son',
                      icon: Icons.person_outline_rounded,
                      capitalize: true,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SectionCard(
                    title: 'Your body',
                    icon: Icons.monitor_weight_outlined,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _LabeledField(
                                label: 'Current weight',
                                controller: _weight,
                                suffix: 'kg',
                                icon: Icons.monitor_weight_rounded,
                                number: true,
                                validator: (v) => _requiredNumber(v, max: 500),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _LabeledField(
                                label: 'Target weight',
                                controller: _targetWeight,
                                suffix: 'kg',
                                icon: Icons.flag_rounded,
                                number: true,
                                validator: (v) => _requiredNumber(v, max: 500),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        _LabeledField(
                          label: 'Height',
                          controller: _height,
                          suffix: 'cm',
                          icon: Icons.straighten_rounded,
                          number: true,
                          validator: (v) => _requiredNumber(v, max: 300),
                        ),
                        if (_goal != null) ...[
                          const SizedBox(height: 16),
                          _GoalBanner(goal: _goal!),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  SectionCard(
                    title: 'Your goal',
                    icon: Icons.route_rounded,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _LabeledField(
                          label: 'Location (city, country)',
                          controller: _location,
                          hint: 'e.g. Chennai, India',
                          icon: Icons.place_rounded,
                          capitalize: true,
                          validator: (v) =>
                              (v == null || v.trim().isEmpty) ? 'Required' : null,
                        ),
                        const SizedBox(height: 14),
                        const FieldLabel('Target period'),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 96,
                              child: _LabeledField(
                                controller: _period,
                                icon: Icons.schedule_rounded,
                                number: true,
                                validator: (v) {
                                  if (v == null || v.trim().isEmpty) return '!';
                                  final n = int.tryParse(v.trim());
                                  if (n == null || n <= 0) return '!';
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _PillToggle<String>(
                                selected: _periodUnit,
                                onChanged: (v) => setState(() => _periodUnit = v),
                                options: const [
                                  (value: 'weeks', label: 'Weeks', icon: null),
                                  (value: 'days', label: 'Days', icon: null),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  SectionCard(
                    title: 'About you',
                    icon: Icons.person_outline_rounded,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Optional — these sharpen the plan.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: AppColors.inkMuted,
                              ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 110,
                              child: _LabeledField(
                                label: 'Age',
                                controller: _age,
                                icon: Icons.cake_rounded,
                                number: true,
                                validator: (v) {
                                  if (v == null || v.trim().isEmpty) return null;
                                  final n = int.tryParse(v.trim());
                                  if (n == null || n <= 0 || n >= 120) {
                                    return 'Invalid';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const FieldLabel('Sex'),
                                  _PillToggle<String>(
                                    selected: _sex,
                                    onChanged: (v) => setState(() => _sex = v),
                                    options: const [
                                      (value: 'male', label: 'Male', icon: Icons.male_rounded),
                                      (value: 'female', label: 'Female', icon: Icons.female_rounded),
                                      (value: 'other', label: 'Other', icon: Icons.person_rounded),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        const FieldLabel('Activity level'),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: const [
                            (value: 'sedentary', label: 'Sedentary'),
                            (value: 'light', label: 'Light'),
                            (value: 'moderate', label: 'Moderate'),
                            (value: 'active', label: 'Active'),
                            (value: 'very_active', label: 'Very active'),
                          ]
                              .map((o) => _ChoicePill(
                                    label: o.label,
                                    selected: _activity == o.value,
                                    onTap: () => setState(() => _activity = o.value),
                                  ))
                              .toList(),
                        ),
                        const SizedBox(height: 16),
                        _LabeledField(
                          label: 'Dietary preference',
                          controller: _dietPref,
                          hint: 'e.g. vegetarian, no pork',
                          icon: Icons.restaurant_menu_rounded,
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: const [
                            'Vegetarian',
                            'Vegan',
                            'Eggetarian',
                            'Non-veg',
                            'Jain',
                            'Keto',
                          ]
                              .map((d) => _ChoicePill(
                                    label: d,
                                    dense: true,
                                    selected: _dietPref.text.toLowerCase() == d.toLowerCase(),
                                    onTap: () => setState(() {
                                      _dietPref.text =
                                          _dietPref.text.toLowerCase() == d.toLowerCase()
                                              ? ''
                                              : d;
                                    }),
                                  ))
                              .toList(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: AppColors.bg,
          border: Border(top: BorderSide(color: AppColors.line)),
        ),
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: PrimaryButton(
            label: 'Generate my diet plan',
            icon: Icons.auto_awesome_rounded,
            onPressed: _submit,
          ),
        ),
      ),
    );
  }
}

/// A label-above-field input with consistent styling.
class _LabeledField extends StatelessWidget {
  final String? label;
  final TextEditingController controller;
  final String? hint;
  final String? suffix;
  final IconData? icon;
  final bool number;
  final bool capitalize;
  final String? Function(String?)? validator;

  const _LabeledField({
    this.label,
    required this.controller,
    this.hint,
    this.suffix,
    this.icon,
    this.number = false,
    this.capitalize = false,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) FieldLabel(label!),
        TextFormField(
          controller: controller,
          keyboardType:
              number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
          inputFormatters: number
              ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]
              : null,
          textCapitalization:
              capitalize ? TextCapitalization.words : TextCapitalization.none,
          style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink),
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: icon != null ? Icon(icon, size: 20) : null,
            suffixText: suffix,
            suffixStyle: TextStyle(
              color: AppColors.inkMuted,
              fontWeight: FontWeight.w700,
            ),
          ),
          validator: validator,
        ),
      ],
    );
  }
}

/// A segmented pill control (e.g. weeks/days, sex).
class _PillToggle<T> extends StatelessWidget {
  final List<({T value, String label, IconData? icon})> options;
  final T selected;
  final ValueChanged<T> onChanged;

  const _PillToggle({
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.fieldFill,
        borderRadius: BorderRadius.circular(AppRadius.field),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: options.map((o) {
          final sel = o.value == selected;
          return Expanded(
            child: GestureDetector(
              onTap: () => onChanged(o.value),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  color: sel ? AppColors.surfaceHigh : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  border: sel ? Border.all(color: AppColors.line) : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (o.icon != null) ...[
                      Icon(o.icon,
                          size: 16,
                          color: sel ? AppColors.brand : AppColors.inkMuted),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        o.label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: sel ? AppColors.ink : AppColors.inkMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// A tappable choice pill (activity level, diet quick-picks).
class _ChoicePill extends StatelessWidget {
  final String label;
  final bool selected;
  final bool dense;
  final VoidCallback onTap;

  const _ChoicePill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: EdgeInsets.symmetric(horizontal: dense ? 14 : 16, vertical: dense ? 8 : 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.brand : AppColors.fieldFill,
          borderRadius: BorderRadius.circular(AppRadius.chip),
          border: Border.all(
            color: selected ? AppColors.brand : AppColors.line,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            color: selected ? Colors.white : AppColors.inkMuted,
          ),
        ),
      ),
    );
  }
}

class _GoalBanner extends StatelessWidget {
  final ({String label, Color color, IconData icon}) goal;
  const _GoalBanner({required this.goal});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: goal.color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(goal.icon, color: goal.color, size: 20),
          const SizedBox(width: 10),
          Text(
            'Goal: ',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.inkMuted,
                ),
          ),
          Text(
            goal.label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: goal.color,
                  fontWeight: FontWeight.w800,
                ),
          ),
        ],
      ),
    );
  }
}

/// The gradient primary button used as the sticky CTA (also reused on home).
class PrimaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  const PrimaryButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: AppColors.ctaGradient,
        borderRadius: BorderRadius.circular(AppRadius.field),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.field),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
