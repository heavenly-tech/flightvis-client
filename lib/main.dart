import 'package:flutter/material.dart';

import 'api/flight_vis_client.dart';
import 'screens/home_hub_screen.dart';
import 'screens/login_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/permissions_screen.dart';
import 'screens/tracking_screen.dart';
import 'services/app_repository.dart';
import 'services/tracking_service.dart';

Future<AppRepository> createAppRepository() => AppRepository.create();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  _Flow _flow = _Flow.loading;
  String? _pilotName;
  String? _flightId;
  String? _tail;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    widget.repo.refreshBaseUrl();
    final token = await widget.repo.secure.readDeviceToken();
    final session = await widget.repo.secure.readSessionId();
    if (session != null) {
      widget.repo.client.setSessionId(session);
    }
    if (token != null) {
      widget.repo.client.setDeviceToken(token);
    }
    PilotProfile? pilot;
    try {
      pilot = await widget.repo.client.meProfile();
    } catch (_) {
      pilot = null;
    }
    final activeFlight = widget.repo.prefs.activeFlightId();
    if (!mounted) return;
    setState(() {
      if (pilot == null || !pilot.isApproved) {
        _flow = _Flow.login;
        return;
      }
      _pilotName = pilot.name;
      if (activeFlight != null) {
        _flightId = activeFlight;
        _tail = _tail ?? '—';
        _flow = _Flow.tracking;
      } else if (token == null) {
        _flow = _Flow.pairing;
      } else {
        _flow = _Flow.hub;
      }
    });
  }

  void _onLoggedIn() => _restore();

  void _afterPairing() {
    setState(() => _flow = _Flow.permissions);
  }

  void _afterPermissions() => setState(() => _flow = _Flow.hub);

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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flight_vis',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B4D89)),
      ),
      home: switch (_flow) {
        _Flow.loading => const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
        _Flow.login => LoginScreen(
            repo: widget.repo,
            onLoggedIn: _onLoggedIn,
          ),
        _Flow.pairing => PairingScreen(
            repo: widget.repo,
            onPaired: _afterPairing,
          ),
        _Flow.permissions => PermissionsScreen(onContinue: _afterPermissions),
        _Flow.hub => HomeHubScreen(
            repo: widget.repo,
            pilotName: _pilotName ?? 'Pilot',
            onStartFlight: _startFlight,
            onLogout: () async {
              await widget.repo.client.logout();
              await widget.repo.secure.clearAll();
              if (mounted) setState(() => _flow = _Flow.login);
            },
          ),
        _Flow.tracking => TrackingScreen(
            repo: widget.repo,
            flightId: _flightId!,
            tail: _tail ?? '—',
            tracking: _tracking,
            onStopped: _stopped,
          ),
      },
    );
  }
}

enum _Flow { loading, login, pairing, permissions, hub, tracking }