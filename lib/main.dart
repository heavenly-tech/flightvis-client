import 'dart:async';

import 'package:flutter/material.dart';

import 'util/checkin_expiry_format.dart';
import 'util/flight_deep_link.dart';
import 'app_config.dart';
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
import 'ci_test_keys.dart';

Future<AppRepository> createAppRepository() => AppRepository.create();

/// Widget/integration tests invoke the real post-login handler without UI.
@visibleForTesting
Future<void> Function()? flightVisAppOnLoggedInTestHook;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  CheckinExpiryFormat.ensureInitialized();
  final repo = await createAppRepository();
  runApp(FlightVisApp(repo: repo));
}

class FlightVisApp extends StatefulWidget {
  const FlightVisApp({
    super.key,
    required this.repo,
    this.bindPlatformDeepLinks = true,
    this.stopStickyTrackerOnRestore = true,
  });

  final AppRepository repo;

  /// Widget tests set this to false to skip `app_links` platform setup.
  @visibleForTesting
  final bool bindPlatformDeepLinks;

  /// When false, widget tests avoid native Traccar [TrackingService.stop] on restore (L-33).
  @visibleForTesting
  final bool stopStickyTrackerOnRestore;

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
  bool _checkinRouteOpen = false;
  late Locale _locale;

  @override
  void initState() {
    super.initState();
    final device = WidgetsBinding.instance.platformDispatcher.locale;
    _locale = widget.repo.localePrefs.resolveLocale(device);
    widget.repo.syncApiLocale(_locale);
    DeepLinkTestHooks.handler = _onDeepLink;
    if (widget.bindPlatformDeepLinks) {
      _deepLinks.bind(_onDeepLink);
    }
    _restore();
    flightVisAppOnLoggedInTestHook = _onLoggedIn;
  }

  @override
  void dispose() {
    if (flightVisAppOnLoggedInTestHook == _onLoggedIn) {
      flightVisAppOnLoggedInTestHook = null;
    }
    if (DeepLinkTestHooks.handler == _onDeepLink) {
      DeepLinkTestHooks.handler = null;
    }
    _deepLinks.dispose();
    super.dispose();
  }

  Future<void> _onDeepLink(ParsedDeepLink link) async {
    if (link is AppHomeDeepLink) {
      if (!_appReady) return;
      if (_flow == _Flow.tracking) return;
      if (mounted) _goHub();
      return;
    }
    if (link is MagicLinkDeepLink) {
      try {
        final pilot = await widget.repo.client.completeMagicLink(
          link.token,
          clubSlug: widget.repo.prefs.activeClubSlug() ?? widget.repo.client.clubSlug,
        );
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

    _queuedCheckin = null;
    await _openCheckinScreen(link);
  }

  Future<void> _openCheckinScreen(CheckinDeepLink link) async {
    if (_checkinRouteOpen || !mounted) return;

    Future<void> pushWhenReady() async {
      if (!mounted || _checkinRouteOpen) return;
      final ctx = _navigatorKey.currentContext;
      if (ctx == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(pushWhenReady());
        });
        return;
      }
      _checkinRouteOpen = true;
      _queuedCheckin = null;
      await widget.repo.prefs.clearPendingCheckin();
      if (!mounted || !ctx.mounted) {
        _checkinRouteOpen = false;
        return;
      }
      final navigator = Navigator.of(ctx);
      // Return after the route is pushed; do not wait for the pilot to finish check-in.
      unawaited(
        navigator
            .push(
          MaterialPageRoute(
            builder: (_) => CheckinScreen(
              repo: widget.repo,
              initialScan: link.token,
              initialClubSlug: link.clubSlug,
              onCheckedIn: () async {
                await widget.repo.prefs.clearPendingCheckin();
              },
              onLoginRequired: () {
                if (mounted) setState(() => _flow = _Flow.login);
              },
            ),
          ),
        )
            .whenComplete(() {
          if (mounted) setState(() => _checkinRouteOpen = false);
        }),
      );
    }

    await pushWhenReady();
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
    if (AppConfig.screenshotTest) {
      // ignore: avoid_print
      print(
        'flightvis-ci: screenshot=1 baseUrl=${AppConfig.defaultBaseUrl} '
        'saved=${widget.repo.prefs.baseUrl()}',
      );
      if (!widget.repo.prefs.permissionsOnboardingComplete()) {
        await widget.repo.prefs.setPermissionsOnboardingComplete(true);
      }
    }
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
      final register = widget.repo.ensureDeviceRegistered(
        preferPilotRegistration: session != null,
      );
      if (AppConfig.screenshotTest) {
        await register.timeout(const Duration(seconds: 20));
      } else {
        await register;
      }
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
      } catch (e) {
        serverSaysActive = serverFlightActiveFromError(e);
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
    if (!resumeTracking && widget.stopStickyTrackerOnRestore) {
      await _tracking.stop();
      if (activeFlight != null) {
        await widget.repo.prefs.setActiveFlightId(null);
        activeFlight = null;
      }
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
      if (!widget.repo.prefs.permissionsOnboardingComplete() && !AppConfig.screenshotTest) {
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
          key: FlightVisTestKeys.appLoading,
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