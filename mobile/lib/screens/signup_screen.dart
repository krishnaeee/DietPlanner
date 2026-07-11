import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../widgets/auth_widgets.dart';
import '../widgets/fresh.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      await AuthService.instance.signup(_email.text.trim(), _password.text);
      // authState flipped → the gate underneath is now the home screen; pop the
      // signup route to reveal it.
      if (mounted) navigator.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _google() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      final ok = await AuthService.instance.googleLogin();
      if (ok && mounted) {
        navigator.pop(); // reveal the home screen the gate now shows
      } else if (mounted) {
        setState(() => _busy = false); // cancelled
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 24),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: HeaderCircleButton(
                  icon: Icons.arrow_back_rounded,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              ),
              const SizedBox(height: 4),
              const AuthHero(
                title: 'Create account.',
                subtitle: 'Sign up to start planning your meals.',
              ),
              const SizedBox(height: 26),
              AuthField(
                controller: _email,
                label: 'Email',
                hint: 'you@example.com',
                icon: Icons.mail_outline_rounded,
                keyboardType: TextInputType.emailAddress,
                validator: validateEmail,
              ),
              const SizedBox(height: 14),
              AuthField(
                controller: _password,
                label: 'Password',
                hint: 'At least 6 characters',
                icon: Icons.lock_outline_rounded,
                obscure: _obscure,
                onToggleObscure: () => setState(() => _obscure = !_obscure),
                validator: (v) =>
                    (v == null || v.length < 6) ? 'At least 6 characters' : null,
              ),
              const SizedBox(height: 14),
              AuthField(
                controller: _confirm,
                label: 'Confirm password',
                hint: 'Re-enter password',
                icon: Icons.lock_outline_rounded,
                obscure: _obscure,
                validator: (v) =>
                    v != _password.text ? 'Passwords do not match' : null,
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 22),
              _busy
                  ? const AuthBusyBox(label: 'Creating your account…')
                  : GradientButton(
                      label: 'Create account',
                      icon: Icons.auto_awesome_rounded,
                      onPressed: _submit,
                    ),
              const SizedBox(height: 18),
              const OrDivider(),
              const SizedBox(height: 16),
              GoogleSignInButton(onPressed: _busy ? null : _google),
              const SizedBox(height: 10),
              AuthFooter(
                text: 'Already have an account?',
                action: 'Log in',
                onTap: _busy ? null : () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
