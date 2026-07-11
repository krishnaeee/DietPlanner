import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../widgets/auth_widgets.dart';
import '../widgets/fresh.dart';
import 'signup_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await AuthService.instance.login(_email.text.trim(), _password.text);
      // On success authState flips → AuthGate swaps to the home screen.
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _google() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await AuthService.instance.googleLogin();
      // Success → AuthGate swaps to home; cancel → just re-enable the button.
      if (mounted) setState(() => _busy = false);
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
              const AuthHero(
                title: 'Welcome back.',
                subtitle: 'Log in to keep your streak alive.',
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
                hint: '••••••••',
                icon: Icons.lock_outline_rounded,
                obscure: _obscure,
                onToggleObscure: () => setState(() => _obscure = !_obscure),
                validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 22),
              _busy
                  ? const AuthBusyBox(label: 'Logging in…')
                  : GradientButton(
                      label: 'Log in',
                      icon: Icons.login_rounded,
                      onPressed: _submit,
                    ),
              const SizedBox(height: 18),
              const OrDivider(),
              const SizedBox(height: 16),
              GoogleSignInButton(onPressed: _busy ? null : _google),
              const SizedBox(height: 10),
              AuthFooter(
                text: "Don't have an account?",
                action: 'Sign up',
                onTap: _busy
                    ? null
                    : () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const SignupScreen()),
                        ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
