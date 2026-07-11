import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

String? validateEmail(String? v) {
  final s = (v ?? '').trim();
  if (s.isEmpty) return 'Required';
  if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(s)) {
    return 'Enter a valid email';
  }
  return null;
}

/// A labelled text field styled for the auth screens, with optional reveal toggle.
class AuthField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final IconData icon;
  final bool obscure;
  final VoidCallback? onToggleObscure;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onSubmitted;

  const AuthField({
    super.key,
    required this.controller,
    required this.label,
    required this.icon,
    this.hint,
    this.obscure = false,
    this.onToggleObscure,
    this.keyboardType,
    this.validator,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: AppColors.inkMuted,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
        TextFormField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction:
              onSubmitted != null ? TextInputAction.done : TextInputAction.next,
          style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink),
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: Icon(icon, size: 20),
            suffixIcon: onToggleObscure != null
                ? IconButton(
                    icon: Icon(
                      obscure
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      size: 20,
                      color: AppColors.inkMuted,
                    ),
                    onPressed: onToggleObscure,
                  )
                : null,
          ),
          validator: validator,
          onFieldSubmitted: onSubmitted,
        ),
      ],
    );
  }
}

/// Nocturne auth hero: the app-mark as a lit coral orb over a violet haze,
/// followed by a heavy title and a muted subtitle.
class AuthHero extends StatelessWidget {
  final String title;
  final String subtitle;
  const AuthHero({super.key, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 140,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    gradient: RadialGradient(
                      center: const Alignment(0, -0.2),
                      radius: 1.0,
                      colors: [
                        AppColors.violet.withValues(
                            alpha: AppColors.brightness == Brightness.dark
                                ? 0.20
                                : 0.12),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
              // The app mark — identical to the launcher icon: full coral
              // gradient tile, white leaf, white three-star sparkle.
              Container(
                width: 92,
                height: 92,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(26),
                  gradient: const RadialGradient(
                    center: Alignment(-0.45, -0.55),
                    radius: 1.35,
                    colors: [Color(0xFFFFB46B), Color(0xFFFF5D6D)],
                  ),
                  boxShadow: coralGlow(opacity: 0.20, blur: 16, y: 5),
                ),
                child: Stack(
                  children: [
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.only(top: 4, right: 4),
                        child:
                            Icon(Icons.eco_rounded, color: Colors.white, size: 42),
                      ),
                    ),
                    const Positioned.fill(
                      child: CustomPaint(painter: _SparkClusterPainter()),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Text(title,
            style: text.headlineMedium?.copyWith(
                fontWeight: FontWeight.w900, letterSpacing: -0.8, height: 1.05)),
        const SizedBox(height: 6),
        Text(subtitle,
            style: text.bodyMedium
                ?.copyWith(color: AppColors.inkMuted, height: 1.4)),
      ],
    );
  }
}

/// The white auto_awesome three-star cluster from the launcher icon —
/// one big four-point star with two small trailing ones, top-right.
/// Positions/radii are fractions of the tile width, taken from the icon art.
class _SparkClusterPainter extends CustomPainter {
  const _SparkClusterPainter();

  static const _stars = [
    (0.711, 0.275, 0.090), // big
    (0.816, 0.191, 0.039), // small, upper
    (0.826, 0.352, 0.029), // small, lower
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final paint = Paint()..color = Colors.white;
    for (final (fx, fy, fr) in _stars) {
      final cx = fx * w, cy = fy * w, r = fr * w;
      final k = 0.3125 * r; // auto_awesome waist ratio
      final path = Path()
        ..moveTo(cx, cy - r)
        ..lineTo(cx + k, cy - k)
        ..lineTo(cx + r, cy)
        ..lineTo(cx + k, cy + k)
        ..lineTo(cx, cy + r)
        ..lineTo(cx - k, cy + k)
        ..lineTo(cx - r, cy)
        ..lineTo(cx - k, cy - k)
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SparkClusterPainter old) => false;
}

/// A glass "working…" box shown in place of the CTA while busy.
class AuthBusyBox extends StatelessWidget {
  final String label;
  const AuthBusyBox({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 15),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.field),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
              width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Text(label,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: AppColors.inkMuted, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

/// A horizontal "or" separator.
class OrDivider extends StatelessWidget {
  const OrDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Divider(color: AppColors.line)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text('or',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.inkFaint, fontWeight: FontWeight.w700)),
        ),
        Expanded(child: Divider(color: AppColors.line)),
      ],
    );
  }
}

/// "Continue with Google" outlined button.
class GoogleSignInButton extends StatelessWidget {
  final VoidCallback? onPressed;
  const GoogleSignInButton({super.key, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: const Text(
          'G',
          style: TextStyle(
            color: Color(0xFF4285F4),
            fontWeight: FontWeight.w900,
            fontSize: 18,
          ),
        ),
        label: const Text('Continue with Google'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.ink,
          side: BorderSide(color: AppColors.line),
          padding: const EdgeInsets.symmetric(vertical: 14),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.field)),
        ),
      ),
    );
  }
}

/// "Don't have an account? Sign up" style footer.
class AuthFooter extends StatelessWidget {
  final String text;
  final String action;
  final VoidCallback? onTap;
  const AuthFooter({super.key, required this.text, required this.action, this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(text, style: t.bodyMedium?.copyWith(color: AppColors.inkMuted)),
        TextButton(onPressed: onTap, child: Text(action)),
      ],
    );
  }
}
