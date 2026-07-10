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
  String _goal = 'lose'; // lose | gain | maintain ("eat healthy")

  bool get _maintain => _goal == 'maintain';

  @override
  void initState() {
    super.initState();
    // Refresh the live BMI / goal indicators as the body inputs change.
    _weight.addListener(_refresh);
    _targetWeight.addListener(_refresh);
    _height.addListener(_refresh);
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
      'targetDays': targetDays,
      'goal': _goal,
      // Target weight only matters for lose/gain; "eat healthy" plans maintain.
      if (!_maintain) 'targetWeightKg': double.parse(_targetWeight.text.trim()),
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

  /// Live BMI from the entered weight + height, with its category, a colour, and
  /// the healthy weight range (BMI 18.5–24.9) for the height. Null until both
  /// inputs are valid.
  ({double bmi, String category, Color color, double lo, double hi})? get _bmi {
    final w = double.tryParse(_weight.text.trim());
    final h = double.tryParse(_height.text.trim());
    // Guard against nonsense (e.g. height typed in metres) so the card doesn't
    // render an absurd BMI. Bounds match the field validators.
    if (w == null || h == null || w < 20 || w > 500 || h < 50 || h > 300) {
      return null;
    }
    final m = h / 100;
    final bmi = w / (m * m);
    String category;
    Color color;
    if (bmi < 18.5) {
      category = 'Underweight';
      color = AppColors.dinner;
    } else if (bmi < 25) {
      category = 'Normal';
      color = AppColors.brand;
    } else if (bmi < 30) {
      category = 'Overweight';
      color = AppColors.accent;
    } else {
      category = 'Obese';
      color = const Color(0xFFE0573E);
    }
    return (bmi: bmi, category: category, color: color, lo: 18.5 * m * m, hi: 24.9 * m * m);
  }

  /// A sensible "healthy" target weight (BMI 22) for the current height.
  double? get _healthyTarget {
    final h = double.tryParse(_height.text.trim());
    if (h == null || h < 50 || h > 300) return null;
    final m = h / 100;
    return 22 * m * m;
  }

  /// Only offer the "use healthy target" shortcut when the healthy weight is on
  /// the correct side of the current weight for the chosen goal — otherwise it
  /// would fill a target that contradicts the goal.
  bool get _healthyTargetSensible {
    if (_maintain) return false;
    final w = double.tryParse(_weight.text.trim());
    final t = _healthyTarget;
    if (w == null || t == null) return false;
    return _goal == 'lose' ? t < w : t > w;
  }

  void _useHealthyTarget() {
    final t = _healthyTarget;
    if (t == null) return;
    _targetWeight.text = t.round().toString();
  }

  /// Validates the target weight: a number in range AND on the correct side of
  /// the current weight for the goal (below for lose, above for gain).
  String? _validateTarget(String? v) {
    final base = _requiredNumber(v, min: 20, max: 500);
    if (base != null) return base;
    final t = double.parse(v!.trim());
    final w = double.tryParse(_weight.text.trim());
    if (w != null) {
      if (_goal == 'lose' && t >= w) return 'Set a weight below your current one';
      if (_goal == 'gain' && t <= w) return 'Set a weight above your current one';
    }
    return null;
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
                    title: 'What\'s your goal?',
                    icon: Icons.flag_outlined,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _PillToggle<String>(
                          selected: _goal,
                          onChanged: (v) => setState(() => _goal = v),
                          options: const [
                            (value: 'lose', label: 'Lose', icon: Icons.trending_down_rounded),
                            (value: 'gain', label: 'Gain', icon: Icons.trending_up_rounded),
                            (value: 'maintain', label: 'Healthy', icon: Icons.favorite_rounded),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _maintain
                              ? 'A balanced plan to maintain your weight and eat well — no target needed.'
                              : _goal == 'gain'
                                  ? 'A higher-calorie, protein-rich plan to reach your target weight.'
                                  : 'A safe-deficit plan to reach your target weight.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: AppColors.inkMuted,
                              ),
                        ),
                      ],
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
                                validator: (v) => _requiredNumber(v, min: 20, max: 500),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _LabeledField(
                                label: 'Height',
                                controller: _height,
                                suffix: 'cm',
                                icon: Icons.straighten_rounded,
                                number: true,
                                validator: (v) => _requiredNumber(v, min: 50, max: 300),
                              ),
                            ),
                          ],
                        ),
                        // Target weight only for lose/gain — "eat healthy" maintains.
                        if (!_maintain) ...[
                          const SizedBox(height: 14),
                          _LabeledField(
                            label: 'Target weight',
                            controller: _targetWeight,
                            suffix: 'kg',
                            icon: Icons.flag_rounded,
                            number: true,
                            autovalidate: true,
                            validator: _validateTarget,
                          ),
                        ],
                        if (_bmi != null) ...[
                          const SizedBox(height: 16),
                          _BmiCard(
                            bmi: _bmi!,
                            onUseHealthy:
                                _healthyTargetSensible ? _useHealthyTarget : null,
                            healthyTarget: _healthyTarget,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  SectionCard(
                    title: 'Location & duration',
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
  final bool autovalidate;
  final String? Function(String?)? validator;

  const _LabeledField({
    this.label,
    required this.controller,
    this.hint,
    this.suffix,
    this.icon,
    this.number = false,
    this.capitalize = false,
    this.autovalidate = false,
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
          autovalidateMode:
              autovalidate ? AutovalidateMode.onUserInteraction : null,
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

/// Live BMI readout: value, category, healthy weight range, and (for a weight
/// goal) a one-tap "use a healthy target" shortcut.
class _BmiCard extends StatelessWidget {
  final ({double bmi, String category, Color color, double lo, double hi}) bmi;
  final VoidCallback? onUseHealthy;
  final double? healthyTarget;
  const _BmiCard({required this.bmi, this.onUseHealthy, this.healthyTarget});

  String _kg(double v) {
    final s = v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bmi.color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.monitor_heart_rounded, color: bmi.color, size: 20),
              const SizedBox(width: 10),
              Text('BMI ${bmi.bmi.toStringAsFixed(1)}',
                  style: text.titleMedium?.copyWith(
                      color: AppColors.ink, fontWeight: FontWeight.w800)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: bmi.color,
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Text(bmi.category,
                    style: text.labelSmall?.copyWith(
                        color: Colors.white, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('Healthy range for your height: ${_kg(bmi.lo)}–${_kg(bmi.hi)} kg',
              style: text.bodySmall?.copyWith(color: AppColors.inkMuted)),
          if (onUseHealthy != null && healthyTarget != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onUseHealthy,
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                label: Text('Use healthy target (${_kg(healthyTarget!)} kg)'),
              ),
            ),
          ],
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
