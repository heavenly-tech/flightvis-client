import 'package:flutter/material.dart';

import 'util/checkin_expiry_format.dart';
import 'util/flight_deep_link.dart';
import 'app_shell.dart';
import 'api/flight_vis_client.dart';
import 'screens/checkin_screen.dart';
import 'screens/home_hub_screen.dart';
import 'screens/login_screen.dart';
import 'screens/permissions_onboarding_screen.dart';
import 'screens/tracking_screen.dart';
import 'services/app_repository.dart';
import 'services/deep_link_dispatcher.dart';
import 'services/tracking_lifecycle.dart';
import 'services/tracking_service.dart';

Future<AppRepository> createAppRepository() => AppRepository.create();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  CheckinExpiryFormat.ensureInitialized();
  final repo = await createAppRepository();
  runApp(FlightVisApp(repo: repo));
}

class FlightVisApp extends StatefulWidget {
  const FlightVisApp({super.key, required this.repo});

  final AppRepository repo;

  @override
  State<FlightVisApp> createState() => _FlightVisAppState();
}

class _FlightVisAppState extends State<FlightVisApp> {
  final _tracking = TrackingService();
  final _deepLinks = DeepLinkDispatcher();
  final _navigatorKey = GlobalKey<NavigatorState>();
  _Flow _flow = _Flow.loading;
  PilotProfile? _pilot;
  String? _flightId;
  String? _tail;
  bool _appReady = false;
  CheckinDeepLink? _queuedCheckin;
  late Locale _locale;

  @override
  void initState() {
    super.initState();
    final device = WidgetsBinding.instance.platformDispatcher.locale;
    _locale = widget.repo.localePrefs.resolveLocale(device);
    widget.repo.syncApiLocale(_locale);
    DeepLinkTestHooks.handler = _onDeepLink;
    _deepLinks.bind(_onDeepLink);
    _restore();
  }

  @override
  void dispose() {
    if (DeepLinkTestHooks.handler == _onDeepLink) {
      DeepLinkTestHooks.handler = null;
    }
    _deepLinks.dispose();
    super.dispose();
  }

  Future<void> _onDeepLink(ParsedDeepLink link) async {
    if (link is MagicLinkDeepLink) {
      try {
        final pilot = await widget.repo.client.completeMagicLink(link.token);
        if (!pilot.isApproved) return;
        await widget.repo.persistSession();
        await widget.repo.ensureDeviceRegistered(preferPilotRegistration: true);
        if (mounted) {
          setState(() => _pilot = pilot);
          await _resumePendingCheckin();
          if (_queuedCheckin == null) _goHub();
        }
      } catch (_) {}
      return;
    }
    if (link is CheckinDeepLink) {
      await _rememberPendingCheckin(link);
      if (!_appReady) {
        _queuedCheckin = link;
        return;
      }
      await _presentCheckinDeepLink(link);
    }
  }

  Future<void> _rememberPendingCheckin(CheckinDeepLink link) async {
    await widget.repo.prefs.setPendingCheckin(slug: link.clubSlug, token: link.token);
    widget.repo.client.setClubSlug(link.clubSlug);
  }

  Future<void> _presentCheckinDeepLink(CheckinDeepLink link) async {
    if (!mounted) return;
    if (_flow == _Flow.tracking) return;

    if (_flow == _Flow.permissions) {
      _queuedCheckin = link;
      return;
    }

    await _openCheckinScreen(link);
  }

  Future<void> _openCheckinScreen(CheckinDeepLink link) async {
    final ctx = _navigatorKey.currentContext;
    if (ctx == null || !mounted) return;
    await Navigator.of(ctx).push(
      MaterialPageRoute(
        builder: (_) => CheckinScreen(
          repo: widget.repo,
          initialScan: link.token,
          initialClubSlug: link.clubSlug,
          onCheckedIn: () async {
            await widget.repo.prefs.clearPendingCheckin();
            if (ctx.mounted) Navigator.pop(ctx);
          },
          onLoginRequired: () {
            if (ctx.mounted) setState(() => _flow = _Flow.login);
          },
        ),
      ),
    );
  }

  Future<void> _resumePendingCheckin() async {
    final slug = widget.repo.prefs.pendingCheckinSlug();
    final token = widget.repo.prefs.pendingCheckinToken();
    if (slug == null || token == null) return;
    final link = CheckinDeepLink(clubSlug: slug, token: token);
    _queuedCheckin = null;
    if (_pilot != null && _pilot!.isApproved) {
      await _presentCheckinDeepLink(link);
    }
  }

  Future<void> _restore() async {
    widget.repo.refreshBaseUrl();
    widget.repo.syncClubFromPrefs();
    final session = await widget.repo.secure.readSessionId();
    final token = await widget.repo.secure.readDeviceToken();
    if (session != null) {
      widget.repo.client.setSessionId(session);
    }
    if (token != null) {
      widget.repo.client.setDeviceToken(token);
    }
    try {
      await widget.repo.ensureDeviceRegistered(
        preferPilotRegistration: session != null,
      );
    } catch (_) {}

    PilotProfile? pilot;
    if (session != null) {
      try {
        pilot = await widget.repo.client.meProfile();
      } catch (_) {
        pilot = null;
      }
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    var activeFlight = widget.repo.prefs.activeFlightId();
    bool? serverSaysActive;
    if (activeFlight != null && session != null) {
      try {
        serverSaysActive = await widget.repo.client.isFlightActiveOnServer(activeFlight);
      } catch (_) {
        serverSaysActive = false;
      }
    } else if (activeFlight != null) {
      serverSaysActive = null;
    }
    final resumeTracking = shouldResumeTracking(
      activeFlightId: activeFlight,
      serverSaysActive: serverSaysActive,
      checkinExpiresAtMs: widget.repo.prefs.checkinExpiresAtMs(),
      nowMs: nowMs,
    );
    if (!resumeTracking) {
      await _tracking.stop();
      if (activeFlight != null) {
        await widget.repo.prefs.setActiveFlightId(null);
      }
      activeFlight = null;
    }
    if (!mounted) return;
    setState(() {
      _pilot = pilot;
      if (activeFlight != null) {
        _flightId = activeFlight;
        _tail = _tail ?? '—';
        _flow = _Flow.tracking;
        _appReady = true;
        return;
      }
      if (!widget.repo.prefs.permissionsOnboardingComplete()) {
        _flow = _Flow.permissions;
      } else {
        _flow = _Flow.hub;
      }
      _appReady = true;
    });

    final queued = _queuedCheckin;
    if (queued != null) {
      await _presentCheckinDeepLink(queued);
    } else if (widget.repo.prefs.pendingCheckinSlug() != null) {
      await _resumePendingCheckin();
    }
  }

  void _goHub() => setState(() => _flow = _Flow.hub);

  void _refreshLocale() {
    final device = WidgetsBinding.instance.platformDispatcher.locale;
    final resolved = widget.repo.localePrefs.resolveLocale(device);
    widget.repo.syncApiLocale(resolved);
    setState(() => _locale = resolved);
  }

  Future<void> _onLoggedIn() async {
    await _restore();
    await _resumePendingCheckin();
  }

  void _afterPermissions() async {
    await widget.repo.prefs.setPermissionsOnboardingComplete(true);
    _goHub();
    final queued = _queuedCheckin;
    if (queued != null) {
      await _presentCheckinDeepLink(queued);
    }
  }

  void _startFlight(String id, String tail) async {
    await widget.repo.prefs.setActiveFlightId(id);
    setState(() {
      _flightId = id;
      _tail = tail;
      _flow = _Flow.tracking;
    });
  }

  void _stopped() {
    setState(() {
      _flightId = null;
      _tail = null;
      _flow = _Flow.hub;
    });
  }

  Future<void> _logout() async {
    await widget.repo.client.logout();
    await widget.repo.secure.clearSessionId();
    await _restore();
  }

  Widget _home() {
    return switch (_flow) {
      _Flow.loading => const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      _Flow.login => LoginScreen(
          repo: widget.repo,
          onLoggedIn: _onLoggedIn,
          onContinueAsGuest: () async {
            _goHub();
            final slug = widget.repo.prefs.pendingCheckinSlug();
            final token = widget.repo.prefs.pendingCheckinToken();
            if (slug != null && token != null) {
              await _openCheckinScreen(CheckinDeepLink(clubSlug: slug, token: token));
            }
          },
        ),
      _Flow.permissions => PermissionsOnboardingScreen(
          repo: widget.repo,
          onComplete: _afterPermissions,
        ),
      _Flow.hub => HomeHubScreen(
          repo: widget.repo,
          pilot: _pilot,
          onStartFlight: _startFlight,
          onRequestLogin: () => setState(() => _flow = _Flow.login),
          onLogout: _logout,
          onLocaleChanged: _refreshLocale,
        ),
      _Flow.tracking => TrackingScreen(
          repo: widget.repo,
          flightId: _flightId!,
          tail: _tail ?? '—',
          tracking: _tracking,
          onStopped: _stopped,
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return PilotAppShell(
      navigatorKey: _navigatorKey,
      locale: _locale,
      home: _home(),
    );
  }
}

enum _Flow { loading, login, permissions, hub, tracking }