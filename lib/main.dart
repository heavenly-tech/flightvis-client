import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import 'api/flight_vis_client.dart';
import 'app_config.dart';
import 'app_shell.dart';
import 'ci_test_keys.dart';
import 'l10n/api_errors.dart';
import 'l10n/pilot_l10n.dart';
import 'models/local_flight.dart';
import 'screens/checkin_screen.dart';
import 'screens/home_hub_screen.dart';
import 'screens/local_flight_screen.dart';
import 'screens/login_screen.dart';
import 'screens/permissions_onboarding_screen.dart';
import 'screens/tracking_screen.dart';
import 'services/app_repository.dart';
import 'services/deep_link_dispatcher.dart';
import 'services/device_location_provider.dart';
import 'services/flight_permissions.dart';
import 'services/flight_start_mode.dart';
import 'services/local_flight_recorder.dart';
import 'services/tracking_lifecycle.dart';
import 'services/tracking_service.dart';
import 'storage/local_flight_migration.dart';
import 'storage/local_flight_store.dart';
import 'util/checkin_expiry_format.dart';
import 'util/flight_deep_link.dart';

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
    this.trackingService,
    this.permissions,
    this.deviceLocationProvider,
    this.localRecorder,
    this.localFlightStore,
    this.tileProvider,
    this.enableMapPolling,
    this.profileRetryDelay = const Duration(seconds: 5),
  });

  final AppRepository repo;

  /// Widget tests set this to false to skip `app_links` platform setup.
  @visibleForTesting
  final bool bindPlatformDeepLinks;

  /// When false, widget tests avoid native Traccar [TrackingService.stop] on restore (L-33).
  @visibleForTesting
  final bool stopStickyTrackerOnRestore;

  /// Optional injectable [TrackingService] for widget tests.
  final TrackingService? trackingService;

  /// Optional injectable permissions adapter for widget tests.
  final FlightPermissionsClient? permissions;

  /// Optional injectable last-known location provider for tests.
  final DeviceLocationProvider? deviceLocationProvider;

  /// Optional injectable local-only flight recorder for tests.
  final LocalFlightRecorder? localRecorder;

  /// Optional injectable local flight store for tests.
  final LocalFlightStore? localFlightStore;

  /// Optional injectable map tile provider for tests.
  final TileProvider? tileProvider;

  /// Optional override for map polling in widget tests.
  final bool? enableMapPolling;

  /// Backoff delay before retrying `/api/club/me` after a transient error.
  final Duration profileRetryDelay;

  @override
  State<FlightVisApp> createState() => _FlightVisAppState();
}

class _FlightVisAppState extends State<FlightVisApp>
    with WidgetsBindingObserver {
  late final TrackingService _defaultTracking;
  final _deepLinks = DeepLinkDispatcher();
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final LocalFlightRecorder _defaultLocalRecorder;
  late final LocalFlightStore _defaultLocalFlightStore;

  _Flow _flow = _Flow.loading;
  PilotProfile? _pilot;
  AccountProfile? _accountProfile;
  String? _flightId;
  String? _tail;
  String _activeFlightMode = 'club';
  String? _localTail;
  LocalFlightReason _localReason = LocalFlightReason.signedOut;
  bool _appReady = false;
  bool _sessionExpiredNotice = false;
  bool _clubUnavailableNotice = false;
  String? _magicLinkNotice;
  bool _magicLinkNoticeIsError = false;
  bool _profileRetryPending = false;
  int _localFlightsRevision = 0;
  bool _migrationPromptOpen = false;
  Timer? _profileRetryTimer;
  CheckinDeepLink? _queuedCheckin;
  bool _checkinRouteOpen = false;
  late Locale _locale;

  TrackingService get _tracking => widget.trackingService ?? _defaultTracking;

  LocalFlightRecorder get _localRecorder =>
      widget.localRecorder ?? _defaultLocalRecorder;

  LocalFlightStore get _localFlightStore =>
      widget.localFlightStore ?? _defaultLocalFlightStore;

  String get _currentFlightBucket => LocalFlightStore.bucketForPilot(_pilot);

  @override
  void initState() {
    super.initState();
    _defaultTracking = TrackingService();
    _defaultLocalRecorder = PlatformLocalFlightRecorder();
    _defaultLocalFlightStore = FileLocalFlightStore();
    WidgetsBinding.instance.addObserver(this);
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
    WidgetsBinding.instance.removeObserver(this);
    _profileRetryTimer?.cancel();
    _profileRetryTimer = null;
    if (flightVisAppOnLoggedInTestHook == _onLoggedIn) {
      flightVisAppOnLoggedInTestHook = null;
    }
    if (DeepLinkTestHooks.handler == _onDeepLink) {
      DeepLinkTestHooks.handler = null;
    }
    _deepLinks.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _profileRetryPending) {
      unawaited(_retryProfileRefresh());
    }
  }

  Future<void> _onDeepLink(ParsedDeepLink link) async {
    if (link is AppHomeDeepLink) {
      if (!_appReady) return;
      if (_flow == _Flow.tracking || _flow == _Flow.localTracking) return;
      if (mounted) _goHub();
      return;
    }
    if (link is AccountMagicLinkDeepLink) {
      try {
        widget.repo.refreshBaseUrl();
        String? installId;
        try {
          installId = await widget.repo.readInstallId();
        } catch (_) {}
        final model = await widget.repo.readDeviceModel();
        final auth = await widget.repo.client.completeAccountMagicLink(
          link.token,
          purpose: link.purpose,
          installId: installId,
          label: 'Android',
          model: model,
        );
        await widget.repo.persistSession();
        final device = auth.device;
        if (device != null && device.token.isNotEmpty) {
          if (auth.profile.activeMembershipId == null) {
            await widget.repo.persistPersonalDeviceToken(device.token);
          } else {
            await widget.repo.persistDeviceToken(device.token);
          }
        }
        var account = auth.profile;
        try {
          final fresh = await widget.repo.client.accountMe();
          if (fresh != null) account = fresh;
        } catch (_) {}
        await widget.repo.prefs.setCachedAccountProfile(account);
        PilotProfile? pilot;
        final activeMem = account.activeMembership;
        if (activeMem != null) {
          await widget.repo.setActiveClub(
            slug: activeMem.slug,
            name: activeMem.name,
          );
          try {
            pilot = await widget.repo.client.meProfile();
          } catch (_) {}
        }
        pilot ??= account.toPersonalPilotProfile();
        await widget.repo.prefs.setCachedPilotProfile(pilot);
        if (mounted) {
          setState(() {
            _accountProfile = account;
            _pilot = pilot;
            _sessionExpiredNotice = false;
            _clubUnavailableNotice = false;
            _profileRetryPending = false;
            _magicLinkNotice = null;
            _magicLinkNoticeIsError = false;
          });
          _profileRetryTimer?.cancel();
          await _resumePendingCheckin();
          if (_queuedCheckin == null) {
            _goHub();
            unawaited(_maybePromptLocalFlightsMigration());
          }
        }
      } on FlightVisException catch (e) {
        if (mounted) {
          final ctx = _navigatorKey.currentContext;
          final msg = (ctx != null && ctx.mounted)
              ? localizeApiException(ctx.pilotL10n, e)
              : e.message;
          setState(() {
            _magicLinkNotice = msg;
            _magicLinkNoticeIsError = true;
          });
        }
      } catch (_) {}
      return;
    }
    if (link is MagicLinkDeepLink) {
      try {
        var pilot = await widget.repo.client.completeMagicLink(
          link.token,
          clubSlug: widget.repo.prefs.activeClubSlug() ?? widget.repo.client.clubSlug,
        );
        if (!pilot.isApproved) return;
        try {
          final me = await widget.repo.client.meProfile();
          if (me != null) pilot = me;
        } catch (_) {}
        await widget.repo.persistSession();
        await widget.repo.prefs.setCachedPilotProfile(pilot);
        await widget.repo.ensureDeviceRegistered(preferPilotRegistration: true);
        if (mounted) {
          setState(() {
            _pilot = pilot;
            _sessionExpiredNotice = false;
            _clubUnavailableNotice = false;
            _profileRetryPending = false;
          });
          _profileRetryTimer?.cancel();
          await _resumePendingCheckin();
          if (_queuedCheckin == null) {
            _goHub();
            unawaited(_maybePromptLocalFlightsMigration());
          }
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
    if (_flow == _Flow.tracking || _flow == _Flow.localTracking) return;

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
      unawaited(
        navigator
            .push(
          MaterialPageRoute(
            builder: (_) => CheckinScreen(
              repo: widget.repo,
              pilot: _pilot,
              permissions: widget.permissions,
              initialScan: link.token,
              initialClubSlug: link.clubSlug,
              onCheckedIn: () async {
                await widget.repo.prefs.clearPendingCheckin();
                if (mounted) setState(() {});
              },
              onLoginRequired: () {
                if (mounted) setState(() => _flow = _Flow.login);
              },
              onStartFlight: _startFlight,
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
    await _presentCheckinDeepLink(link);
  }

  /// Stops active club tracking and clears active flight + check-in state
  /// consistently on both logout and session expiry (M-24).
  Future<void> _stopClubTrackingAndClearCheckin() async {
    await _tracking.stop();
    await widget.repo.prefs.setActiveFlightId(null);
    await widget.repo.prefs.setCheckinExpiresAtMs(null);
    await widget.repo.prefs.setActiveClub(slug: null, name: null);
    widget.repo.client.setClubSlug(null);
    _flightId = null;
    _tail = null;
  }

  Future<void> _clearExpiredSession({bool clearDeviceToken = false}) async {
    await _stopClubTrackingAndClearCheckin();
    await widget.repo.secure.clearSessionId();
    await widget.repo.secure.clearAccountSessionId();
    widget.repo.client.setSessionId(null);
    widget.repo.client.setAccountSessionId(null);
    if (clearDeviceToken) {
      await widget.repo.secure.clearDeviceToken();
      await widget.repo.secure.clearPersonalDeviceToken();
      widget.repo.client.setDeviceToken(null);
      widget.repo.client.setPersonalDeviceToken(null);
    }
    await widget.repo.prefs.setCachedPilotProfile(null);
    await widget.repo.prefs.setCachedAccountProfile(null);
    await widget.repo.prefs.setClubTrailMinutesDefault(null);
    _accountProfile = null;
    _profileRetryTimer?.cancel();
    _profileRetryTimer = null;
    _profileRetryPending = false;
    _clubUnavailableNotice = false;
    _sessionExpiredNotice = true;
  }

  void _scheduleProfileRetry() {
    if (AppConfig.screenshotTest) return;
    _profileRetryPending = true;
    _profileRetryTimer?.cancel();
    _profileRetryTimer = Timer(widget.profileRetryDelay, () {
      unawaited(_retryProfileRefresh());
    });
  }

  Future<void> _retryProfileRefresh() async {
    if (!mounted || !widget.repo.client.hasAnySession) {
      _profileRetryPending = false;
      return;
    }
    if (widget.repo.client.hasAccountSession) {
      try {
        final account = await widget.repo.client.accountMe();
        if (!mounted) return;
        if (account == null) {
          await _clearExpiredSession();
          if (mounted) {
            setState(() {
              _pilot = null;
              _accountProfile = null;
              if (_flow == _Flow.tracking) _flow = _Flow.hub;
            });
          }
          return;
        }
        await widget.repo.prefs.setCachedAccountProfile(account);
        PilotProfile? pilot;
        var clubUnavailable = false;
        if (account.activeMembershipId != null) {
          try {
            pilot = await widget.repo.client.meProfile();
          } on FlightVisException catch (e) {
            if (e.isClubUnavailable) {
              clubUnavailable = true;
            }
          } catch (_) {}
        }
        pilot ??= account.toPersonalPilotProfile();
        await widget.repo.prefs.setCachedPilotProfile(pilot);
        await widget.repo.prefs.setClubTrailMinutesDefault(
          widget.repo.client.clubTrailMinutesDefault,
        );
        _profileRetryPending = clubUnavailable;
        if (!clubUnavailable) {
          _profileRetryTimer?.cancel();
          _profileRetryTimer = null;
        }
        if (mounted) {
          setState(() {
            _accountProfile = account;
            _pilot = pilot;
            _sessionExpiredNotice = false;
            _clubUnavailableNotice = clubUnavailable;
          });
        }
        return;
      } on FlightVisException catch (e) {
        if (!mounted) return;
        if (e.statusCode == 401) {
          await _clearExpiredSession(
            clearDeviceToken: e.reason == 'invalid_device',
          );
          if (mounted) {
            setState(() {
              _pilot = null;
              _accountProfile = null;
              if (_flow == _Flow.tracking) _flow = _Flow.hub;
            });
          }
          return;
        }
        _profileRetryPending = true;
        return;
      } catch (_) {
        if (mounted) _profileRetryPending = true;
        return;
      }
    }
    try {
      final pilot = await widget.repo.client.meProfile();
      if (!mounted) return;
      if (pilot != null) {
        await widget.repo.prefs.setCachedPilotProfile(pilot);
        await widget.repo.prefs.setClubTrailMinutesDefault(
          widget.repo.client.clubTrailMinutesDefault,
        );
        _profileRetryPending = false;
        _profileRetryTimer?.cancel();
        _profileRetryTimer = null;
        if (mounted) {
          setState(() {
            _pilot = pilot;
            _sessionExpiredNotice = false;
            _clubUnavailableNotice = false;
          });
        }
      } else {
        await _clearExpiredSession();
        if (mounted) {
          setState(() {
            _pilot = null;
            if (_flow == _Flow.tracking) _flow = _Flow.hub;
          });
        }
      }
    } on FlightVisException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 401) {
        await _clearExpiredSession(
          clearDeviceToken: e.reason == 'invalid_device',
        );
        if (mounted) {
          setState(() {
            _pilot = null;
            if (_flow == _Flow.tracking) _flow = _Flow.hub;
          });
        }
      } else if (e.isClubUnavailable) {
        if (_flow == _Flow.tracking && _activeFlightMode != 'personal') {
          await _tracking.stop();
          await widget.repo.prefs.setActiveFlightId(null);
          _flightId = null;
          _tail = null;
        }
        _profileRetryPending = true;
        if (mounted) {
          setState(() {
            _clubUnavailableNotice = true;
            _sessionExpiredNotice = false;
            if (_flow == _Flow.tracking && _activeFlightMode != 'personal') {
              _flow = _Flow.hub;
            }
          });
        }
      } else {
        _profileRetryPending = true;
      }
    } catch (_) {
      if (mounted) _profileRetryPending = true;
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
    final rawSession = await widget.repo.secure.readSessionId();
    final session = rawSession?.trim();
    var hasClubSession = session != null && session.isNotEmpty;
    final rawAccountSession = await widget.repo.secure.readAccountSessionId();
    final accountSession = rawAccountSession?.trim();
    var hasAccountSession =
        accountSession != null && accountSession.isNotEmpty;
    final rawToken = await widget.repo.secure.readDeviceToken();
    final token = rawToken?.trim();
    final rawPersonalToken =
        await widget.repo.secure.readPersonalDeviceToken();
    final personalToken = rawPersonalToken?.trim();
    widget.repo.client.setSessionId(hasClubSession ? session : null);
    widget.repo.client
        .setAccountSessionId(hasAccountSession ? accountSession : null);
    if (token != null && token.isNotEmpty) {
      widget.repo.client.setDeviceToken(token);
    }
    if (personalToken != null && personalToken.isNotEmpty) {
      widget.repo.client.setPersonalDeviceToken(personalToken);
    }

    PilotProfile? pilot;
    AccountProfile? account;
    if (hasAccountSession) {
      try {
        account = await widget.repo.client.accountMe();
        if (account != null) {
          await widget.repo.prefs.setCachedAccountProfile(account);
          _sessionExpiredNotice = false;
          _clubUnavailableNotice = false;
          _profileRetryPending = false;
          _profileRetryTimer?.cancel();
          _profileRetryTimer = null;
          final activeMem = account.activeMembership;
          if (activeMem != null) {
            await widget.repo.setActiveClub(
              slug: activeMem.slug,
              name: activeMem.name,
            );
            try {
              pilot = await widget.repo.client.meProfile();
              await widget.repo.prefs.setClubTrailMinutesDefault(
                widget.repo.client.clubTrailMinutesDefault,
              );
            } on FlightVisException catch (e) {
              if (e.isClubUnavailable) {
                _clubUnavailableNotice = true;
                _scheduleProfileRetry();
              }
            } catch (_) {}
          }
          pilot ??= account.toPersonalPilotProfile();
          await widget.repo.prefs.setCachedPilotProfile(pilot);
        } else {
          await _clearExpiredSession();
          hasAccountSession = false;
          hasClubSession = false;
          pilot = null;
          account = null;
        }
      } on FlightVisException catch (e) {
        if (e.statusCode == 401) {
          await _clearExpiredSession(
            clearDeviceToken: e.reason == 'invalid_device',
          );
          hasAccountSession = false;
          hasClubSession = false;
          pilot = null;
          account = null;
        } else {
          account = widget.repo.prefs.cachedAccountProfile();
          pilot = widget.repo.prefs.cachedPilotProfile() ??
              account?.toPersonalPilotProfile();
          _scheduleProfileRetry();
        }
      } catch (_) {
        account = widget.repo.prefs.cachedAccountProfile();
        pilot = widget.repo.prefs.cachedPilotProfile() ??
            account?.toPersonalPilotProfile();
        _scheduleProfileRetry();
      }
    } else if (hasClubSession) {
      try {
        pilot = await widget.repo.client.meProfile();
        if (pilot != null) {
          await widget.repo.prefs.setCachedPilotProfile(pilot);
          await widget.repo.prefs.setClubTrailMinutesDefault(
            widget.repo.client.clubTrailMinutesDefault,
          );
          _sessionExpiredNotice = false;
          _clubUnavailableNotice = false;
          _profileRetryPending = false;
          _profileRetryTimer?.cancel();
          _profileRetryTimer = null;
        } else {
          // Server reported pilot=null for a stored session -> expired/stale.
          await _clearExpiredSession();
          hasClubSession = false;
          pilot = null;
        }
      } on FlightVisException catch (e) {
        if (e.statusCode == 401) {
          await _clearExpiredSession(
            clearDeviceToken: e.reason == 'invalid_device',
          );
          hasClubSession = false;
          pilot = null;
        } else if (e.isClubUnavailable) {
          // Suspended club (403 {"error":"club unavailable"}) is NOT expiry:
          // keep session & cached profile, show banner, block club broadcast.
          _clubUnavailableNotice = true;
          _sessionExpiredNotice = false;
          pilot = widget.repo.prefs.cachedPilotProfile();
          _scheduleProfileRetry();
        } else {
          // Transient 5xx/other server error: keep session & cached profile, retry later.
          pilot = widget.repo.prefs.cachedPilotProfile();
          _scheduleProfileRetry();
        }
      } catch (_) {
        // Network / offline error: keep session & cached profile, retry later.
        pilot = widget.repo.prefs.cachedPilotProfile();
        _scheduleProfileRetry();
      }
    } else {
      _clubUnavailableNotice = false;
    }

    final hasAnySession = hasClubSession || hasAccountSession;
    if (hasClubSession && pilot != null && !pilot.isClublessAccount && !_clubUnavailableNotice) {
      try {
        final register = widget.repo.ensureDeviceRegistered(
          preferPilotRegistration: true,
        );
        if (AppConfig.screenshotTest) {
          await register.timeout(const Duration(seconds: 20));
        } else {
          await register;
        }
      } catch (_) {}
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    var activeFlight = widget.repo.prefs.activeFlightId();
    final activeFlightMode = widget.repo.prefs.activeFlightMode();
    final isPersonalActive = activeFlightMode == 'personal';
    final canResumeSession = isPersonalActive
        ? hasAnySession
        : (hasAnySession && !_clubUnavailableNotice);
    bool? serverSaysActive;
    if (activeFlight != null && canResumeSession) {
      try {
        final activeToken = await widget.repo.readDeviceTokenForMode(
          activeFlightMode,
        );
        serverSaysActive = await widget.repo.client.isFlightActiveOnServer(
          activeFlight,
          mode: isPersonalActive ? 'personal' : null,
          deviceToken: isPersonalActive ? activeToken : null,
        );
      } catch (e) {
        serverSaysActive = serverFlightActiveFromError(e);
      }
    } else if (activeFlight != null) {
      serverSaysActive = false;
    }
    final resumeTracking = shouldResumeTracking(
      activeFlightId: activeFlight,
      serverSaysActive: serverSaysActive,
      checkinExpiresAtMs: widget.repo.prefs.checkinExpiresAtMs(),
      nowMs: nowMs,
      hasSession: canResumeSession,
      isPersonalFlight: isPersonalActive,
    );
    if (!resumeTracking) {
      if (widget.stopStickyTrackerOnRestore || activeFlight != null) {
        await _tracking.stop();
      }
      if (activeFlight != null) {
        await widget.repo.prefs.setActiveFlightId(null);
        activeFlight = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _accountProfile = account;
      _pilot = pilot;
      if (activeFlight != null) {
        _flightId = activeFlight;
        _activeFlightMode = activeFlightMode;
        _tail = widget.repo.prefs.activeFlightTail() ?? _tail ?? '—';
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
    } else if (_flow == _Flow.hub) {
      await _maybePromptLocalFlightsMigration();
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
    _sessionExpiredNotice = false;
    _clubUnavailableNotice = false;
    await _restore();
  }

  Future<BuildContext?> _waitForNavigatorContext() async {
    final immediate = _navigatorKey.currentContext;
    if (immediate != null && immediate.mounted) return immediate;
    if (!mounted) return null;
    final completer = Completer<BuildContext?>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _navigatorKey.currentContext;
      completer.complete(mounted && ctx != null && ctx.mounted ? ctx : null);
    });
    return completer.future;
  }

  Future<void> _maybePromptLocalFlightsMigration() async {
    if (_migrationPromptOpen) return;
    final pilot = _pilot;
    if (!mounted || pilot == null || !pilot.isApproved) return;
    if (_flow != _Flow.hub || _checkinRouteOpen || _queuedCheckin != null) return;
    if (widget.repo.prefs.pendingCheckinSlug() != null) return;
    if (AppConfig.screenshotTest) return;
    final accountBucket = LocalFlightStore.bucketForPilot(pilot);
    if (accountBucket == LocalFlightStore.guestBucket ||
        LocalFlightStore.isReservedBucket(accountBucket)) {
      return;
    }

    _migrationPromptOpen = true;
    try {
      await _promptLegacyFlightsOnce(accountBucket);
      if (!mounted ||
          _pilot == null ||
          LocalFlightStore.bucketForPilot(_pilot) != accountBucket ||
          _flow != _Flow.hub) {
        return;
      }
      await _promptGuestFlightsAdoption(accountBucket);
    } finally {
      _migrationPromptOpen = false;
    }
  }

  Future<void> _promptLegacyFlightsOnce(String accountBucket) async {
    int legacyCount;
    try {
      legacyCount = await LocalFlightMigration.claimOrCheckLegacyFlights(
        store: _localFlightStore,
        prefs: widget.repo.prefs,
        accountBucket: accountBucket,
      );
    } catch (_) {
      return;
    }
    if (!mounted || legacyCount <= 0) return;

    while (mounted) {
      final ctx = await _waitForNavigatorContext();
      if (!mounted || ctx == null || !ctx.mounted) return;
      final l10n = ctx.pilotL10n;
      final choice = await showDialog<_LegacyChoice>(
        context: ctx,
        barrierDismissible: true,
        builder: (dialogCtx) => AlertDialog(
          key: FlightVisTestKeys.localFlightsLegacyDialog,
          title: Text(l10n.localFlightsLegacyTitle(legacyCount)),
          content: Text(l10n.localFlightsLegacyBody(legacyCount)),
          actions: [
            TextButton(
              key: FlightVisTestKeys.localFlightsLegacyDelete,
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(dialogCtx).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(dialogCtx, _LegacyChoice.delete),
              child: Text(l10n.localFlightDeleteConfirmAction),
            ),
            FilledButton(
              key: FlightVisTestKeys.localFlightsLegacyAdopt,
              onPressed: () => Navigator.pop(dialogCtx, _LegacyChoice.adopt),
              child: Text(l10n.localFlightsMoveToAccountAction),
            ),
          ],
        ),
      );

      if (choice == _LegacyChoice.adopt) {
        try {
          await LocalFlightMigration.adoptClaimedLegacyFlights(
            store: _localFlightStore,
            prefs: widget.repo.prefs,
            accountBucket: accountBucket,
          );
          if (mounted) {
            setState(() => _localFlightsRevision++);
          }
        } catch (_) {}
        return;
      }

      if (choice == _LegacyChoice.delete) {
        if (!mounted || !ctx.mounted) return;
        final confirmed = await showDialog<bool>(
          context: ctx,
          builder: (confirmCtx) => AlertDialog(
            key: FlightVisTestKeys.localFlightsLegacyDeleteConfirmDialog,
            title: Text(l10n.localFlightsLegacyDeleteConfirmTitle(legacyCount)),
            content: Text(
              l10n.localFlightsLegacyDeleteConfirmBody(legacyCount),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(confirmCtx, false),
                child: Text(l10n.cancelButton),
              ),
              FilledButton(
                key: FlightVisTestKeys.localFlightsLegacyDeleteConfirm,
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(confirmCtx).colorScheme.error,
                  foregroundColor: Theme.of(confirmCtx).colorScheme.onError,
                ),
                onPressed: () => Navigator.pop(confirmCtx, true),
                child: Text(l10n.localFlightDeleteConfirmAction),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          try {
            await LocalFlightMigration.deleteClaimedLegacyFlights(
              store: _localFlightStore,
              prefs: widget.repo.prefs,
              accountBucket: accountBucket,
            );
            if (mounted) {
              setState(() => _localFlightsRevision++);
            }
          } catch (_) {}
          return;
        }
        // User cancelled delete confirmation: re-show the choice so they can
        // adopt, retry delete, or dismiss without deciding.
        continue;
      }

      // Dismissed without deciding: claimant bucket is already persisted so
      // only this account is ever offered these legacy flights again.
      return;
    }
  }

  Future<void> _promptGuestFlightsAdoption(String accountBucket) async {
    List<LocalFlight> guestFlights;
    try {
      guestFlights = await LocalFlightMigration.unacknowledgedGuestFlights(
        store: _localFlightStore,
        prefs: widget.repo.prefs,
        accountBucket: accountBucket,
      );
    } catch (_) {
      return;
    }
    if (!mounted || guestFlights.isEmpty) return;
    final ctx = await _waitForNavigatorContext();
    if (!mounted || ctx == null || !ctx.mounted) return;
    final l10n = ctx.pilotL10n;
    final moveToAccount = await showDialog<bool>(
      context: ctx,
      barrierDismissible: true,
      builder: (dialogCtx) => AlertDialog(
        key: FlightVisTestKeys.localFlightsGuestDialog,
        title: Text(l10n.localFlightsGuestBannerTitle(guestFlights.length)),
        actions: [
          TextButton(
            key: FlightVisTestKeys.localFlightsKeepOnPhone,
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text(l10n.localFlightsKeepOnPhoneAction),
          ),
          FilledButton(
            key: FlightVisTestKeys.localFlightsMoveToAccount,
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(l10n.localFlightsMoveToAccountAction),
          ),
        ],
      ),
    );
    final guestIds = guestFlights.map((f) => f.id).toSet();
    if (moveToAccount == true) {
      try {
        await _localFlightStore.moveFlights(
          fromBucket: LocalFlightStore.guestBucket,
          toBucket: accountBucket,
          flightIds: guestIds,
        );
        if (mounted) {
          setState(() => _localFlightsRevision++);
        }
      } catch (_) {}
    } else if (moveToAccount == false) {
      try {
        await widget.repo.prefs.markGuestFlightsKeptOnPhone(
          accountBucket,
          guestIds,
        );
      } catch (_) {}
    }
  }

  void _afterPermissions() async {
    await widget.repo.prefs.setPermissionsOnboardingComplete(true);
    _goHub();
    final queued = _queuedCheckin;
    if (queued != null) {
      await _presentCheckinDeepLink(queued);
    } else if (widget.repo.prefs.pendingCheckinSlug() != null) {
      await _resumePendingCheckin();
    } else {
      await _maybePromptLocalFlightsMigration();
    }
  }

  void _startFlight(String id, String tail) =>
      _startBroadcastFlight(id, tail, flightMode: 'club');

  void _startBroadcastFlight(
    String id,
    String tail, {
    String flightMode = 'club',
  }) async {
    await widget.repo.prefs.setActiveFlightId(id);
    await widget.repo.prefs.setActiveFlightMode(flightMode);
    await widget.repo.prefs.setActiveFlightTail(tail);
    if (!mounted) return;
    setState(() {
      _flightId = id;
      _tail = tail;
      _activeFlightMode = flightMode;
      _flow = _Flow.tracking;
    });
  }

  Future<void> _switchClub(AccountMembership membership) async {
    final prevSlug = widget.repo.prefs.activeClubSlug();
    final result = await widget.repo.client.switchClub(membership.id);
    await widget.repo.persistSession();
    if (prevSlug != null && prevSlug != result.clubSlug) {
      await widget.repo.prefs.setCheckinExpiresAtMs(null);
    }
    await widget.repo.setActiveClub(
      slug: result.clubSlug,
      name: result.clubName,
    );
    var account = _accountProfile;
    try {
      final fresh = await widget.repo.client.accountMe();
      if (fresh != null) account = fresh;
    } catch (_) {}
    if (account != null) {
      await widget.repo.prefs.setCachedAccountProfile(account);
    }
    PilotProfile? pilot = _pilot;
    try {
      final clubPilot = await widget.repo.client.meProfile();
      if (clubPilot != null) pilot = clubPilot;
      await widget.repo.prefs.setClubTrailMinutesDefault(
        widget.repo.client.clubTrailMinutesDefault,
      );
    } catch (_) {}
    if (pilot != null) {
      await widget.repo.prefs.setCachedPilotProfile(pilot);
    }
    try {
      final installId = await widget.repo.readInstallId();
      final model = await widget.repo.readDeviceModel();
      final reg = await widget.repo.client.registerAccountDevice(
        mode: 'club',
        installId: installId,
        label: 'Android',
        model: model,
      );
      await widget.repo.persistDeviceToken(reg.token);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _accountProfile = account;
      _pilot = pilot;
      _clubUnavailableNotice = false;
    });
  }

  void _startLocalFlight({String? tail, required LocalFlightReason reason}) {
    setState(() {
      _localTail = tail;
      _localReason = reason;
      _flow = _Flow.localTracking;
    });
  }

  void _stopped() {
    setState(() {
      _flightId = null;
      _tail = null;
      _activeFlightMode = 'club';
      _flow = _Flow.hub;
    });
  }

  void _localStopped() {
    setState(() {
      _localTail = null;
      _flow = _Flow.hub;
    });
  }

  Future<void> _logout() async {
    try {
      await widget.repo.client.logout();
    } catch (_) {}
    await _stopClubTrackingAndClearCheckin();
    await widget.repo.secure.clearSessionId();
    await widget.repo.secure.clearAccountSessionId();
    widget.repo.client.setSessionId(null);
    widget.repo.client.setAccountSessionId(null);
    await widget.repo.prefs.setCachedPilotProfile(null);
    await widget.repo.prefs.setCachedAccountProfile(null);
    await widget.repo.prefs.setClubTrailMinutesDefault(null);
    await widget.repo.prefs.setPreferredFlightMode(null);
    _accountProfile = null;
    _sessionExpiredNotice = false;
    _clubUnavailableNotice = false;
    _magicLinkNotice = null;
    _magicLinkNoticeIsError = false;
    _profileRetryPending = false;
    _profileRetryTimer?.cancel();
    _profileRetryTimer = null;
    await _restore();
  }

  void _openSignInFromActiveFlight() {
    final ctx = _navigatorKey.currentContext;
    if (ctx == null) {
      setState(() {
        _sessionExpiredNotice = true;
        _flow = _Flow.login;
      });
      return;
    }
    Navigator.of(ctx).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => LoginScreen(
          repo: widget.repo,
          notice: routeContext.pilotL10n.sessionExpiredPrompt,
          onLoggedIn: () async {
            Navigator.of(routeContext).pop();
            await _retryProfileRefresh();
          },
        ),
      ),
    );
  }

  Widget _home(BuildContext context) {
    return switch (_flow) {
      _Flow.loading => const Scaffold(
          key: FlightVisTestKeys.appLoading,
          body: Center(child: CircularProgressIndicator()),
        ),
      _Flow.login => LoginScreen(
          repo: widget.repo,
          notice: _sessionExpiredNotice
              ? context.pilotL10n.sessionExpiredPrompt
              : null,
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
          permissions: widget.permissions,
        ),
      _Flow.hub => HomeHubScreen(
          repo: widget.repo,
          pilot: _pilot,
          accountProfile: _accountProfile,
          onStartFlight: _startFlight,
          onStartBroadcastFlight: _startBroadcastFlight,
          onSwitchClub: _switchClub,
          onStartLocalFlight: _startLocalFlight,
          onRequestLogin: () => setState(() => _flow = _Flow.login),
          onLogout: _logout,
          onLocaleChanged: _refreshLocale,
          permissions: widget.permissions,
          deviceLocationProvider: widget.deviceLocationProvider,
          localRecorder: _localRecorder,
          localFlightStore: _localFlightStore,
          sessionExpiredNotice: _sessionExpiredNotice,
          clubUnavailableNotice: _clubUnavailableNotice,
          magicLinkNotice: _magicLinkNotice,
          magicLinkNoticeIsError: _magicLinkNoticeIsError,
          localFlightsRevision: _localFlightsRevision,
          tileProvider: widget.tileProvider,
          enableMapPolling: widget.enableMapPolling,
        ),
      _Flow.tracking => TrackingScreen(
          repo: widget.repo,
          flightId: _flightId!,
          tail: _tail ?? '—',
          flightMode: _activeFlightMode,
          accountBucket: _currentFlightBucket,
          tracking: _tracking,
          onStopped: _stopped,
          onSessionExpired: _openSignInFromActiveFlight,
          deviceLocationProvider: widget.deviceLocationProvider,
          tileProvider: widget.tileProvider,
          enableMapPolling: widget.enableMapPolling,
        ),
      _Flow.localTracking => LocalFlightScreen(
          repo: widget.repo,
          localRecorder: _localRecorder,
          localFlightStore: _localFlightStore,
          storageBucket: _currentFlightBucket,
          localReason: _localReason,
          tail: _localTail,
          onStopped: _localStopped,
          onSessionExpired: _openSignInFromActiveFlight,
          deviceLocationProvider: widget.deviceLocationProvider,
          tileProvider: widget.tileProvider,
          enableMapPolling: widget.enableMapPolling,
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return PilotAppShell(
      navigatorKey: _navigatorKey,
      locale: _locale,
      home: Builder(builder: _home),
    );
  }
}

enum _Flow { loading, login, permissions, hub, tracking, localTracking }

enum _LegacyChoice { adopt, delete }
