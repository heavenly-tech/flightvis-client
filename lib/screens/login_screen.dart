import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/flight_vis_client.dart';
import '../l10n/api_errors.dart';
import '../l10n/pilot_l10n.dart';
import '../services/app_repository.dart';
import '../ci_test_keys.dart';
import '../services/passkey_auth.dart';
import '../util/account_signup_availability.dart';
import '../util/account_signup_url.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.repo,
    required this.onLoggedIn,
    this.onContinueAsGuest,
    this.notice,
    this.signupAvailabilityProbe,
  });

  final AppRepository repo;
  final VoidCallback onLoggedIn;
  final VoidCallback? onContinueAsGuest;

  /// Optional banner text (e.g. session expiry reason).
  final String? notice;

  /// Tests inject a probe; production uses [AccountSignupAvailability.isAvailable].
  final AccountSignupAvailabilityProbe? signupAvailabilityProbe;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _passkeyAuth = PasskeyAuth();
  bool _busy = false;
  bool _showPassword = false;
  bool _signupAvailable = false;
  String? _error;
  String? _info;

  @override
  void initState() {
    super.initState();
    _passkeyAuth.bindClient(widget.repo.client);
    _refreshSignupAvailability();
  }

  Future<void> _refreshSignupAvailability() async {
    widget.repo.refreshBaseUrl();
    final base = widget.repo.prefs.baseUrl();
    final probe =
        widget.signupAvailabilityProbe ?? AccountSignupAvailability.isAvailable;
    final available = await probe(base);
    if (!mounted) return;
    setState(() => _signupAvailable = available);
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
    await widget.repo.clearPersonalDeviceTokenIfAccountChanged(pilot.id);
    await widget.repo.prefs.clearPendingMagicLinkRequest();
    await widget.repo.persistSession();
    await widget.repo.prefs.setCachedPilotProfile(pilot);
    await widget.repo.ensureDeviceRegistered(preferPilotRegistration: true);
    if (mounted) {
      setState(() => _busy = false);
      widget.onLoggedIn();
    }
  }

  Future<void> _passkey() async {
    final l10n = context.pilotL10n;
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() {
        _error = l10n.loginEmailRequired;
        _info = null;
        _busy = false;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      widget.repo.refreshBaseUrl();
      widget.repo.syncClubFromPrefs();
      final pilot = await _passkeyAuth.login(email);
      await _afterPilot(pilot);
    } on FlightVisException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = localizeApiException(context.pilotL10n, e);
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Future<void> _afterAccountAuth(AccountAuthResult result) async {
    await widget.repo.clearPersonalDeviceTokenIfAccountChanged(
      result.profile.id,
    );
    await widget.repo.prefs.clearPendingMagicLinkRequest();
    await widget.repo.persistSession();
    final device = result.device;
    if (device != null && device.token.isNotEmpty) {
      if (result.profile.activeMembershipId == null) {
        await widget.repo.persistPersonalDeviceToken(device.token);
      } else {
        await widget.repo.persistDeviceToken(device.token);
      }
    }
    var account = result.profile;
    try {
      final fresh = await widget.repo.client.accountMe();
      if (fresh != null) account = fresh;
    } catch (_) {}
    await widget.repo.clearPersonalDeviceTokenIfAccountChanged(account.id);
    await widget.repo.prefs.setCachedAccountProfile(account);
    PilotProfile? pilot;
    if (account.activeMembershipId != null) {
      try {
        pilot = await widget.repo.client.meProfile();
      } catch (_) {}
    }
    pilot ??= account.toPersonalPilotProfile();
    await widget.repo.prefs.setCachedPilotProfile(pilot);
    if (mounted) {
      setState(() => _busy = false);
      widget.onLoggedIn();
    }
  }

  Future<void> _sendMagic() async {
    final l10n = context.pilotL10n;
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() {
        _error = l10n.loginEmailRequired;
        _info = null;
        _busy = false;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      widget.repo.refreshBaseUrl();
      try {
        await widget.repo.client.sendAccountMagicLink(
          email,
          locale: widget.repo.client.acceptLanguage,
        );
      } on FlightVisException catch (e) {
        if (e.statusCode == 404) {
          await widget.repo.client.sendMagicLink(
            email,
            locale: widget.repo.client.acceptLanguage,
          );
        } else {
          rethrow;
        }
      }
      await widget.repo.prefs.recordMagicLinkRequest(
        email: email,
        nowMs: widget.repo.nowMs(),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _info = context.pilotL10n.pilotMagicLinkSent;
      });
    } on FlightVisException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = localizeApiException(context.pilotL10n, e);
        _busy = false;
      });
    }
  }

  Future<void> _openAccountSignupBrowser() async {
    final l10n = context.pilotL10n;
    widget.repo.refreshBaseUrl();
    final uri = AccountSignupUrl.build(serverBaseUrl: widget.repo.prefs.baseUrl());
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      setState(() => _error = l10n.pilotCreateAccountOpenFailed);
    }
  }

  Future<void> _openAccountSignup() async {
    setState(() {
      _error = null;
      _info = null;
    });
    final sent = await showDialog<bool>(
      context: context,
      builder: (_) => _AccountSignupDialog(
        repo: widget.repo,
        initialEmail: _email.text.trim(),
        onOpenBrowser: _openAccountSignupBrowser,
      ),
    );
    if (sent == true && mounted) {
      setState(() => _info = context.pilotL10n.pilotCreateAccountSent);
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
      String? installId;
      try {
        installId = await widget.repo.readInstallId();
      } catch (_) {}
      final model = await widget.repo.readDeviceModel();
      try {
        final accountAuth = await widget.repo.client.accountLogin(
          _email.text,
          _password.text,
          installId: installId,
          label: 'Android',
          model: model,
        );
        await _afterAccountAuth(accountAuth);
        return;
      } on FlightVisException catch (e) {
        // Fall back to legacy club password login only on 401/404; never swallow 429.
        if (e.statusCode != 401 && e.statusCode != 404) {
          rethrow;
        }
      }
      final pilot = await widget.repo.client.login(
        _email.text,
        _password.text,
        installId: installId,
      );
      await _afterPilot(pilot);
    } on FlightVisException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = localizeApiException(context.pilotL10n, e);
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
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
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.pilotSignInTitle,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            if (widget.notice != null && widget.notice!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    widget.notice!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(l10n.pilotSignInIntro),
            if (_signupAvailable) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                key: FlightVisTestKeys.loginRegister,
                onPressed: _busy ? null : _openAccountSignup,
                child: Text(l10n.pilotCreateAccountButton),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.pilotCreateAccountNote,
                key: FlightVisTestKeys.loginRegisterNote,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
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
            FilledButton.icon(
              onPressed: _busy ? null : _passkey,
              icon: const Icon(Icons.fingerprint),
              label: Text(l10n.pilotSignInPasskey),
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
            if (widget.onContinueAsGuest != null) ...[
              const SizedBox(height: 24),
              TextButton(
                key: FlightVisTestKeys.loginGuest,
                onPressed: _busy ? null : widget.onContinueAsGuest,
                child: Text(l10n.pilotContinueAsGuest),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AccountSignupDialog extends StatefulWidget {
  const _AccountSignupDialog({
    required this.repo,
    required this.initialEmail,
    required this.onOpenBrowser,
  });

  final AppRepository repo;
  final String initialEmail;
  final Future<void> Function() onOpenBrowser;

  @override
  State<_AccountSignupDialog> createState() => _AccountSignupDialogState();
}

class _AccountSignupDialogState extends State<_AccountSignupDialog> {
  late final TextEditingController _emailController;
  final TextEditingController _passwordController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController(text: widget.initialEmail);
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = context.pilotL10n;
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = l10n.loginEmailRequired);
      return;
    }
    final password = _passwordController.text;
    if (password.isNotEmpty && password.length < 8) {
      setState(() => _error = l10n.errorWeakPassword);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      widget.repo.refreshBaseUrl();
      await widget.repo.client.accountSignup(
        email: email,
        password: password.isEmpty ? null : password,
      );
      await widget.repo.prefs.recordMagicLinkRequest(
        email: email,
        nowMs: widget.repo.nowMs(),
      );
      if (mounted) Navigator.pop(context, true);
    } on FlightVisException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = localizeApiException(context.pilotL10n, e);
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = context.pilotL10n.errorSignupFailed;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    return AlertDialog(
      key: FlightVisTestKeys.loginSignupDialog,
      title: Text(l10n.pilotCreateAccountTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.pilotCreateAccountNote,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              key: FlightVisTestKeys.loginSignupEmail,
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: InputDecoration(
                labelText: l10n.pilotEmailLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: FlightVisTestKeys.loginSignupPassword,
              controller: _passwordController,
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              decoration: InputDecoration(
                labelText: l10n.pilotCreateAccountPasswordOptional,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _busy ? null : _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        Navigator.pop(context, false);
                        await widget.onOpenBrowser();
                      },
                child: Text(l10n.pilotCreateAccountBrowserFallback),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          key: FlightVisTestKeys.loginSignupSubmit,
          onPressed: _busy ? null : _submit,
          child: Text(l10n.pilotCreateAccountSubmit),
        ),
      ],
    );
  }
}