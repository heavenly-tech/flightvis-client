import 'package:flutter/material.dart';

import 'util/checkin_expiry_format.dart';
import 'util/flight_deep_link.dart';
import 'app_shell.dart';
import 'api/flight_vis_client.dart';
import 'screens/checkin_screen.dart';
import 'screens/home_hub_screen.dart';
import 'screens/login_screen.dart';
import 'screens/permissions_screen.dart';
import 'screens/tracking_screen.dart';
import 'services/app_repository.dart';
import 'services/deep_link_dispatcher.dart';
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

  @override
  void initState() {
    super.initState();
    _deepLinks.bind(_onDeepLink);
    _restore();
  }

  @override
  void dispose() {
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
          _goHub();
        }
      } catch (_) {}
      return;
    }
    if (link is CheckinDeepLink) {
      widget.repo.client.setClubSlug(link.clubSlug);
      final ctx = _navigatorKey.currentContext;
      if (ctx == null) return;
      if (!mounted) return;
      await Navigator.of(ctx).push(
        MaterialPageRoute(
          builder: (_) => CheckinScreen(
            repo: widget.repo,
            initialScan: link.token,
            initialClubSlug: link.clubSlug,
            onCheckedIn: () => Navigator.pop(ctx),
          ),
        ),
      );
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

    final activeFlight = widget.repo.prefs.activeFlightId();
    if (!mounted) return;
    setState(() {
      _pilot = pilot;
      if (activeFlight != null) {
        _flightId = activeFlight;
        _tail = _tail ?? '—';
        _flow = _Flow.tracking;
        return;
      }
      if (!widget.repo.prefs.permissionsOnboardingComplete()) {
        _flow = _Flow.permissions;
      } else {
        _flow = _Flow.hub;
      }
    });
  }

  void _goHub() => setState(() => _flow = _Flow.hub);

  void _onLoggedIn() {
    _restore();
  }

  void _afterPermissions() async {
    await widget.repo.prefs.setPermissionsOnboardingComplete(true);
    _goHub();
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
          onContinueAsGuest: _goHub,
        ),
      _Flow.permissions => PermissionsScreen(onContinue: _afterPermissions),
      _Flow.hub => HomeHubScreen(
          repo: widget.repo,
          pilot: _pilot,
          onStartFlight: _startFlight,
          onRequestLogin: () => setState(() => _flow = _Flow.login),
          onLogout: _logout,
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
      locale: const Locale('es'),
      home: _home(),
    );
  }
}

enum _Flow { loading, login, permissions, hub, tracking }