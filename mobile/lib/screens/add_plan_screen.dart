import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/billing_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'paywall_screen.dart';
import 'plan_screen.dart';

/// The plan-creation flow — a step-by-step wizard (Goal → Body → Where → About).
/// On the last step it generates and replaces itself with the [PlanScreen], so
/// backing out of the plan returns to where the wizard was opened from.
/// Merges the allergy chip picks with the free-text field: trimmed, blanks
/// dropped, de-duped case-insensitively (so "Milk" typed after tapping the Milk
/// chip doesn't send it twice). Top-level and testable because it assembles a
/// safety constraint — the backend refuses to include anything in this list.
@visibleForTesting
List<String> mergeAllergies(Iterable<String> picks, String freeText) {
  final out = <String>[];
  final seen = <String>{};
  void add(String s) {
    final t = s.trim();
    if (t.isEmpty) return;
    if (seen.add(t.toLowerCase())) out.add(t);
  }

  for (final a in picks) {
    add(a);
  }
  for (final a in freeText.split(',')) {
    add(a);
  }
  return out;
}

class AddPlanScreen extends StatefulWidget {
  const AddPlanScreen({super.key});

  @override
  State<AddPlanScreen> createState() => _AddPlanScreenState();
}

class _AddPlanScreenState extends State<AddPlanScreen> {
  final _pageCtrl = PageController();
  int _step = 0;
  static const _stepCount = 4;
  final _bodyKey = GlobalKey<FormState>(); // step 1 (body)
  final _whereKey = GlobalKey<FormState>(); // step 2 (location & duration)
  final _aboutKey = GlobalKey<FormState>(); // step 3 (about you)

  final _weight = TextEditingController(text: '75');
  final _height = TextEditingController(text: '163');
  final _location = TextEditingController(text: 'pollachi');
  final _targetWeight = TextEditingController(text: '65');
  final _period = TextEditingController(text: '24');
  final _age = TextEditingController(text: '36');
  final _dietPref = TextEditingController();
  final _allergies = TextEditingController();
  final _planName = TextEditingController();

  /// Allergies picked from the common-allergen chips (multi-select — unlike the
  /// single-choice diet preference, people are often allergic to several things).
  final _allergyPicks = <String>{};

  String _periodUnit = 'weeks'; // 'weeks' | 'days'
  String _sex = 'male'; // male | female | other
  String _activity = 'light'; // sedentary ... very_active
  String _cookingStyle = 'everyday'; // everyday | less_oil | steamed | mixed
  String _goal = 'lose'; // lose | gain | maintain ("eat healthy")

  bool get _maintain => _goal == 'maintain';

  @override
  void initState() {
    super.initState();
    _weight.addListener(_refresh);
    _targetWeight.addListener(_refresh);
    _height.addListener(_refresh);
    _dietPref.addListener(_refresh); // keep the quick-pick chips in sync
  }

  void _refresh() => setState(() {});

  void _openPaywall() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PaywallScreen()),
    );
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _weight.dispose();
    _height.dispose();
    _location.dispose();
    _targetWeight.dispose();
    _period.dispose();
    _age.dispose();
    _dietPref.dispose();
    _allergies.dispose();
    _planName.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────── navigation ──

  void _next() {
    FocusScope.of(context).unfocus();
    // Validate the CURRENT step's form (it is mounted; later pages may not be).
    if (_step == 1 && !(_bodyKey.currentState?.validate() ?? true)) return;
    if (_step == 2 && !(_whereKey.currentState?.validate() ?? true)) return;
    if (_step == 3 && !(_aboutKey.currentState?.validate() ?? true)) return;
    if (_step >= _stepCount - 1) {
      _submit();
      return;
    }
    _pageCtrl.nextPage(
        duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
  }

  void _back() {
    if (_step == 0) {
      Navigator.of(context).maybePop();
      return;
    }
    FocusScope.of(context).unfocus();
    _pageCtrl.previousPage(
        duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
  }

  // ─────────────────────────────────────────────────── validation/math ──

  String? _requiredNumber(String? v, {double min = 0, double max = 1000}) {
    if (v == null || v.trim().isEmpty) return 'Required';
    final n = double.tryParse(v.trim());
    if (n == null) return 'Enter a number';
    if (n <= min || n >= max) return 'Out of range';
    return null;
  }

  ({double bmi, String category, Color color, double lo, double hi})? get _bmi {
    final w = double.tryParse(_weight.text.trim());
    final h = double.tryParse(_height.text.trim());
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
      color = AppColors.danger;
    }
    return (bmi: bmi, category: category, color: color, lo: 18.5 * m * m, hi: 24.9 * m * m);
  }

  double? get _healthyTarget {
    final h = double.tryParse(_height.text.trim());
    if (h == null || h < 50 || h > 300) return null;
    final m = h / 100;
    return 22 * m * m;
  }

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

  /// Chip picks + the free-text field, trimmed and de-duped case-insensitively.
  List<String> get _allergyList => mergeAllergies(_allergyPicks, _allergies.text);

  void _submit() {
    FocusScope.of(context).unfocus();
    // Each step was validated as the user advanced (its form was mounted then),
    // so we don't re-validate now — the earlier pages may be unmounted and their
    // form state null, which would silently pass. Gating on _next is the guard.
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
      if (!_maintain) 'targetWeightKg': double.parse(_targetWeight.text.trim()),
      if (_age.text.trim().isNotEmpty) 'age': int.tryParse(_age.text.trim()),
      'sex': _sex,
      'activityLevel': _activity,
      'cookingStyle': _cookingStyle,
      if (_dietPref.text.trim().isNotEmpty) 'dietaryPreference': _dietPref.text.trim(),
      if (_allergyList.isNotEmpty) 'allergies': _allergyList,
    };

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

  // ─────────────────────────────────────────────────────────── build ──

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(
                children: [
                  _CircleBack(onTap: _back),
                  const SizedBox(width: 14),
                  Expanded(child: _StepProgress(step: _step, total: _stepCount)),
                  const SizedBox(width: 14),
                  Text('${_step + 1} of $_stepCount',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: AppColors.inkMuted, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
          Expanded(
            child: PageView(
              controller: _pageCtrl,
              physics: const NeverScrollableScrollPhysics(),
              onPageChanged: (i) => setState(() => _step = i),
              children: [_goalStep(), _bodyStep(), _whereStep(), _aboutStep()],
            ),
          ),
        ],
      ),
      bottomNavigationBar: _bottomBar(),
    );
  }

  Widget _stepScaffold({
    required String title,
    required String subtitle,
    required List<Widget> children,
  }) {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      children: [
        Text(title,
            style: text.headlineMedium
                ?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.5)),
        const SizedBox(height: 6),
        Text(subtitle,
            style: text.bodyMedium?.copyWith(color: AppColors.inkMuted, height: 1.35)),
        const SizedBox(height: 24),
        ...children,
      ],
    );
  }

  Widget _goalStep() {
    return _stepScaffold(
      title: "What's\nthe goal?",
      subtitle: "We'll shape the calories, macros and meals around this.",
      children: [
        _GoalOption(
          icon: Icons.trending_down_rounded,
          title: 'Lose weight',
          sub: 'A safe deficit, built from local food',
          selected: _goal == 'lose',
          onTap: () => setState(() => _goal = 'lose'),
        ),
        const SizedBox(height: 11),
        _GoalOption(
          icon: Icons.trending_up_rounded,
          title: 'Gain weight',
          sub: 'Higher calories, protein-forward',
          selected: _goal == 'gain',
          onTap: () => setState(() => _goal = 'gain'),
        ),
        const SizedBox(height: 11),
        _GoalOption(
          icon: Icons.favorite_rounded,
          title: 'Just eat healthier',
          sub: 'Balanced maintenance, no target',
          selected: _goal == 'maintain',
          onTap: () => setState(() => _goal = 'maintain'),
        ),
        const SizedBox(height: 24),
        const FieldLabel('Plan name (optional)'),
        _LabeledField(
          controller: _planName,
          hint: 'e.g. Me, Wife, Son',
          icon: Icons.person_outline_rounded,
          capitalize: true,
        ),
      ],
    );
  }

  Widget _bodyStep() {
    return Form(
      key: _bodyKey,
      child: _stepScaffold(
        title: 'Your body',
        subtitle: 'So the calories and macros fit you accurately.',
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
              onUseHealthy: _healthyTargetSensible ? _useHealthyTarget : null,
              healthyTarget: _healthyTarget,
            ),
          ],
        ],
      ),
    );
  }

  Widget _whereStep() {
    return Form(
      key: _whereKey,
      child: _stepScaffold(
        title: 'Where & how long',
        subtitle: 'We build the menu from dishes local to you.',
        children: [
          _LabeledField(
            label: 'Location (city, country)',
            controller: _location,
            hint: 'e.g. Chennai, India',
            icon: Icons.place_rounded,
            capitalize: true,
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
          ),
          const SizedBox(height: 16),
          const FieldLabel('Plan length'),
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
    );
  }

  Widget _aboutStep() {
    return Form(
      key: _aboutKey,
      child: _stepScaffold(
        title: 'A little about you',
        subtitle: 'Optional — these sharpen the plan. Skip anything you like.',
        children: [
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
                  if (n == null || n <= 0 || n >= 120) return 'Invalid';
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
        const SizedBox(height: 18),
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
        const SizedBox(height: 18),
        const FieldLabel('Cooking style'),
        const SizedBox(height: 2),
        Text(
          'How your meals are cooked — the plan is built around this.',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.inkMuted, height: 1.4),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: const [
            (value: 'everyday', label: 'Everyday home food'),
            (value: 'less_oil', label: 'Light · less oil'),
            (value: 'steamed', label: 'Steamed / boiled'),
            (value: 'mixed', label: 'A healthy mix'),
          ]
              .map((o) => _ChoicePill(
                    label: o.label,
                    selected: _cookingStyle == o.value,
                    onTap: () => setState(() => _cookingStyle = o.value),
                  ))
              .toList(),
        ),
        const SizedBox(height: 18),
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
          children: const ['Vegetarian', 'Vegan', 'Eggetarian', 'Non-veg', 'Jain', 'Keto']
              .map((d) => _ChoicePill(
                    label: d,
                    dense: true,
                    selected: _dietPref.text.toLowerCase() == d.toLowerCase(),
                    onTap: () => setState(() {
                      _dietPref.text =
                          _dietPref.text.toLowerCase() == d.toLowerCase() ? '' : d;
                    }),
                  ))
              .toList(),
        ),
        const SizedBox(height: 20),
        _LabeledField(
          label: 'Food allergies',
          controller: _allergies,
          hint: 'e.g. prawns, cashew — separate with commas',
          icon: Icons.warning_amber_rounded,
        ),
        const SizedBox(height: 8),
        Text(
          'Anything you list here is never included in your plan, or in a meal you swap.',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.inkMuted, height: 1.4),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: const [
            'Peanuts', 'Tree nuts', 'Milk', 'Eggs', 'Fish',
            'Shellfish', 'Soy', 'Wheat / gluten', 'Sesame',
          ]
              .map((a) => _ChoicePill(
                    label: a,
                    dense: true,
                    selected: _allergyPicks.contains(a),
                    // Multi-select: remove() returns false when it wasn't there.
                    onTap: () => setState(() {
                      if (!_allergyPicks.remove(a)) _allergyPicks.add(a);
                    }),
                  ))
              .toList(),
        ),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    final last = _step == _stepCount - 1;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.bg,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Row(
          children: [
            if (_step > 0) ...[
              SizedBox(
                height: 54,
                child: OutlinedButton(
                  onPressed: _back,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.inkMuted,
                    side: BorderSide(color: AppColors.line),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.field)),
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                  ),
                  child: const Text('Back'),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: PrimaryButton(
                label: last ? 'Generate my plan' : 'Continue',
                icon: last ? Icons.auto_awesome_rounded : Icons.arrow_forward_rounded,
                onPressed: _next,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A goal option card: glass, wrapped in the aurora gradient when selected.
class _GoalOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;
  final bool selected;
  final VoidCallback onTap;
  const _GoalOption({
    required this.icon,
    required this.title,
    required this.sub,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final card = Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(selected ? 16.5 : 18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(selected ? 16.5 : 18),
            border: selected ? null : Border.all(color: AppColors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.all(13),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(icon,
                      color: selected ? AppColors.brand : AppColors.inkMuted,
                      size: 21),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: text.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 1),
                      Text(sub,
                          style: text.bodySmall?.copyWith(
                              color: AppColors.inkMuted, fontSize: 11)),
                    ],
                  ),
                ),
                if (selected)
                  Container(
                    width: 24,
                    height: 24,
                    decoration: const BoxDecoration(
                      gradient: AppColors.ctaGradient,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check_rounded,
                        size: 14, color: Colors.white),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!selected) return card;
    // Selection = the aurora gradient ring.
    return Container(
      decoration: BoxDecoration(
        gradient: AppColors.auroraGradient,
        borderRadius: BorderRadius.circular(18),
      ),
      padding: const EdgeInsets.all(1.5),
      child: card,
    );
  }
}

/// A soft circular back button for the wizard header.
class _CircleBack extends StatelessWidget {
  final VoidCallback onTap;
  const _CircleBack({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      shape: CircleBorder(side: BorderSide(color: AppColors.line)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(Icons.arrow_back_rounded, size: 20, color: AppColors.ink),
        ),
      ),
    );
  }
}

/// A segmented progress bar for the wizard steps.
class _StepProgress extends StatelessWidget {
  final int step, total;
  const _StepProgress({required this.step, required this.total});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < total; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: AnimatedContainer(
              duration: motion(context, 220),
              height: 6,
              decoration: BoxDecoration(
                color: i <= step ? AppColors.brand : AppColors.line,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ],
      ],
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

/// A segmented pill control (e.g. goal, weeks/days, sex).
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
      height: 54,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.fieldFill,
        borderRadius: BorderRadius.circular(AppRadius.field),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: options.map((o) {
          final sel = o.value == selected;
          return Expanded(
            child: GestureDetector(
              onTap: () => onChanged(o.value),
              child: AnimatedContainer(
                duration: motion(context, 180),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  color: sel ? AppColors.brand : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: sel
                      ? [
                          BoxShadow(
                            color: AppColors.brand.withValues(alpha: 0.15),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (o.icon != null) ...[
                      Icon(o.icon,
                          size: 16, color: sel ? Colors.white : AppColors.inkMuted),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        o.label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: sel ? Colors.white : AppColors.inkMuted,
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
        duration: motion(context, 160),
        padding: EdgeInsets.symmetric(horizontal: dense ? 14 : 16, vertical: dense ? 8 : 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.brand : AppColors.fieldFill,
          borderRadius: BorderRadius.circular(AppRadius.chip),
          border: Border.all(color: selected ? AppColors.brand : AppColors.line),
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

/// Live BMI readout with a one-tap "healthy target" shortcut for weight goals.
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
        borderRadius: BorderRadius.circular(16),
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
                    color: bmi.color, borderRadius: BorderRadius.circular(30)),
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

/// The gradient primary button used as a sticky CTA (reused across the app).
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
        gradient: AppColors.brandGradient,
        borderRadius: BorderRadius.circular(AppRadius.field),
        boxShadow: coralGlow(),
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
