import 'package:flutter/material.dart';

import '../api/flight_vis_client.dart';
import '../l10n/pilot_l10n.dart';
import '../services/app_repository.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.repo, required this.onLoggedIn});

  final AppRepository repo;
  final VoidCallback onLoggedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      widget.repo.refreshBaseUrl();
      final pilot = await widget.repo.client.login(
        _email.text,
        _password.text,
      );
      if (!pilot.isApproved) {
        setState(() {
          _error = 'Your pilot account is not approved yet.';
          _busy = false;
        });
        return;
      }
      await widget.repo.persistSession();
      if (mounted) {
        setState(() => _busy = false);
        widget.onLoggedIn();
      }
    } on FlightVisException catch (e) {
      setState(() {
        _error = e.message;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    return Scaffold(
      appBar: AppBar(title: const Text('flight_vis')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.pilotSignInTitle,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text('Server: ${widget.repo.prefs.baseUrl()}'),
            const SizedBox(height: 24),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: InputDecoration(
                labelText: l10n.pilotEmailLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              decoration: InputDecoration(
                labelText: l10n.pilotPasswordLabel,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _busy ? null : _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const Spacer(),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.pilotSignInButton),
            ),
          ],
        ),
      ),
    );
  }
}