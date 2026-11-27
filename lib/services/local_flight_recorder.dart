import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_config.dart';
import '../map/own_trail_buffer.dart';
import 'local_fix_source.dart';

/// Strictly local GPS flight recorder (zero server/network uploads).
abstract class LocalFlightRecorder {
  LocalFixSource get fixSource;

  /// Starts local foreground GPS recording. Returns `false` if unavailable or
  /// permission was denied.
  Future<bool> start();

  /// Stops local recording and returns all captured fixes for the flight.
  Future<List<LocalFix>> stop();

  Future<bool> isRecording();
}

/// Android platform implementation backed by `LocalFlightRecorderService`
/// (`LocationManager` only — no Traccar SDK, no network stack).
class PlatformLocalFlightRecorder implements LocalFlightRecorder {
  PlatformLocalFlightRecorder({
    MethodChannel? methodChannel,
    LocalFixSource? fixSource,
  })  : _channel = methodChannel ?? _defaultChannel,
        _fixSource = fixSource ?? const PlatformLocalFixSource();

  static const _defaultChannel =
      MethodChannel('cl.heavenly.flightvis/tracking');

  final MethodChannel _channel;
  final LocalFixSource _fixSource;

  @override
  LocalFixSource get fixSource => _fixSource;

  @override
  Future<bool> start() async {
    if (AppConfig.screenshotTest) return true;
    try {
      final ok = await _channel.invokeMethod<bool>('startLocalFlightRecording');
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      if (kDebugMode) {
        debugPrint('LocalFlightRecorder.start failed: ${e.code} ${e.message}');
      }
      return false;
    }
  }

  @override
  Future<List<LocalFix>> stop() async {
    if (AppConfig.screenshotTest) return const [];
    try {
      final raw = await _channel.invokeListMethod<dynamic>(
        'stopLocalFlightRecording',
      );
      if (raw == null) return const [];
      final out = <LocalFix>[];
      for (final item in raw) {
        if (item is Map<Object?, Object?>) {
          final fix = LocalFix.fromMap(item);
          if (fix != null) out.add(fix);
        }
      }
      return out;
    } on MissingPluginException {
      return const [];
    } on PlatformException catch (e) {
      if (kDebugMode) {
        debugPrint('LocalFlightRecorder.stop failed: ${e.code} ${e.message}');
      }
      return const [];
    }
  }

  @override
  Future<bool> isRecording() async {
    if (AppConfig.screenshotTest) return true;
    try {
      final active = await _channel.invokeMethod<bool>('isLocalFlightRecording');
      return active ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

/// Deterministic in-memory [LocalFlightRecorder] for unit/widget/golden tests.
class FakeLocalFlightRecorder implements LocalFlightRecorder {
  FakeLocalFlightRecorder({
    this.startResult = true,
    List<LocalFix> initialFixes = const [],
  }) : _fixSource = InMemoryLocalFixSource(initialFixes: initialFixes);

  final bool startResult;
  final InMemoryLocalFixSource _fixSource;
  bool recording = false;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  LocalFixSource get fixSource => _fixSource;

  void emitFix(LocalFix fix) => _fixSource.emit(fix);

  @override
  Future<bool> start() async {
    startCalls++;
    if (!startResult) return false;
    recording = true;
    await _fixSource.startRecording();
    return true;
  }

  @override
  Future<List<LocalFix>> stop() async {
    stopCalls++;
    recording = false;
    final fixes = await _fixSource.getRecentFixes();
    return List<LocalFix>.from(fixes);
  }

  @override
  Future<bool> isRecording() async => recording;

  Future<void> dispose() => _fixSource.dispose();
}
