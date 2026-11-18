import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/flight_vis_client.dart';
import '../l10n/pilot_l10n.dart';
import '../services/app_repository.dart';
import '../ci_test_keys.dart';
import '../services/passkey_auth.dart';
import '../util/club_registration_url.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.repo,
    required this.onLoggedIn,
    this.onContinueAsGuest,
  });

  final AppRepository repo;
  final VoidCallback onLoggedIn;
  final VoidCallback? onContinueAsGuest;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _passkeyAuth = PasskeyAuth();
  bool _busy = false;
  bool _showPassword = false;
  String? _error;
  String? _info;

  @override
  void initState() {
    super.initState();
    _passkeyAuth.bindClient(widget.repo.client);
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _afterPilot(PilotProfile pilot) async {
    if (!pilot.isApproved) {
      setState(() {
        _error = context.pilotL10n.pilotPendingApproval;
        _busy = false;
      });
      return;
    }
    await widget.repo.persistSession();
    await widget.repo.ensureDeviceRegistered(preferPilotRegistration: true);
    if (mounted) {
      setState(() => _busy = false);
      widget.onLoggedIn();
    }
  }

  Future<void> _passkey() async {
    final l10n = context.pilotL10n;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      widget.repo.refreshBaseUrl();
      widget.repo.syncClubFromPrefs();
      final email = _email.text.trim();
      if (email.isEmpty) {
        setState(() {
          _error = l10n.pilotEmailLabel;
          _busy = false;
        });
        return;
      }
      final pilot = await _passkeyAuth.login(email);
      await _afterPilot(pilot);
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

  Future<void> _sendMagic() async {
    final email = _email.text.trim();
    if (email.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      widget.repo.refreshBaseUrl();
      await widget.repo.client.sendMagicLink(
        email,
        locale: widget.repo.client.acceptLanguage,
      );
      setState(() {
        _busy = false;
        _info = context.pilotL10n.pilotMagicLinkSent;
      });
    } on FlightVisException catch (e) {
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  Future<void> _openClubRegistration() async {
    final l10n = context.pilotL10n;
    setState(() {
      _error = null;
      _info = null;
    });
    widget.repo.refreshBaseUrl();
    widget.repo.syncClubFromPrefs();
    final slug = ClubRegistrationUrl.resolveClubSlug(
      activeClubSlug: widget.repo.prefs.activeClubSlug(),
      clientClubSlug: widget.repo.client.clubSlug,
    );
    final uri = ClubRegistrationUrl.build(
      serverBaseUrl: widget.repo.prefs.baseUrl(),
      clubSlug: slug,
    );
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      setState(() => _error = l10n.pilotRegisterOpenFailed);
    }
  }

  Future<void> _passwordLogin() async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      widget.repo.refreshBaseUrl();
      widget.repo.syncClubFromPrefs();
      final pilot = await widget.repo.client.login(_email.text, _password.text);
      await _afterPilot(pilot);
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
      appBar: AppBar(title: Text(l10n.appName)),
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
            Text(l10n.pilotSignInIntro),
            const SizedBox(height: 12),
            OutlinedButton(
              key: FlightVisTestKeys.loginRegister,
              onPressed: _busy ? null : _openClubRegistration,
              child: Text(l10n.pilotRegisterButton),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.pilotRegisterApprovalNote,
              key: FlightVisTestKeys.loginRegisterNote,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _passkey,
              icon: const Icon(Icons.fingerprint),
              label: Text(l10n.pilotSignInPasskey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: InputDecoration(
                labelText: l10n.pilotEmailLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: _busy ? null : _sendMagic,
              child: Text(l10n.pilotSignInMagicLink),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _busy ? null : () => setState(() => _showPassword = !_showPassword),
              child: Text(l10n.pilotSignInPasswordToggle),
            ),
            if (_showPassword) ...[
              TextField(
                controller: _password,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  labelText: l10n.pilotPasswordLabel,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _busy ? null : _passwordLogin(),
              ),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: _busy ? null : _passwordLogin,
                child: Text(l10n.pilotSignInButton),
              ),
            ],
            if (_info != null) ...[
              const SizedBox(height: 12),
              Text(_info!, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const Spacer(),
            if (widget.onContinueAsGuest != null)
              TextButton(
                key: FlightVisTestKeys.loginGuest,
                onPressed: _busy ? null : widget.onContinueAsGuest,
                child: Text(l10n.pilotContinueAsGuest),
              ),
          ],
        ),
      ),
    );
  }
}