import 'dart:async';

import 'package:flutter/services.dart';

import '../map/own_trail_buffer.dart';

/// Source of locally recorded GPS fixes from the device's own tracking pipeline
/// (no server round-trip).
abstract class LocalFixSource {
  /// Ensures the native/local fix recorder is observing the active tracker.
  Future<void> startRecording();

  /// Reads fixes already captured in the local ring buffer (e.g. while the UI
  /// was backgrounded during a flight).
  Future<List<LocalFix>> getRecentFixes();

  /// Clears buffered local fixes (e.g. when a flight ends).
  Future<void> clear();

  /// Broadcast or single-subscription stream of live local fixes while the map
  /// is visible in the foreground.
  Stream<LocalFix> watchFixes();
}

/// Platform-backed [LocalFixSource] reading accepted fixes from the running
/// Traccar SDK tracker state via `MainActivity` channels.
class PlatformLocalFixSource implements LocalFixSource {
  const PlatformLocalFixSource({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methodChannel = methodChannel ?? _defaultMethodChannel,
        _eventChannel = eventChannel ?? _defaultEventChannel;

  static const _defaultMethodChannel =
      MethodChannel('cl.heavenly.flightvis/tracking');
  static const _defaultEventChannel =
      EventChannel('cl.heavenly.flightvis/tracking_positions');

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  @override
  Future<void> startRecording() async {
    try {
      await _methodChannel.invokeMethod<void>('startLocalFixRecorder');
    } on MissingPluginException {
      // Non-Android platform or unit test without platform channel mock.
    } on PlatformException {
      // Best-effort local recorder.
    }
  }

  @override
  Future<List<LocalFix>> getRecentFixes() async {
    try {
      final raw =
          await _methodChannel.invokeListMethod<dynamic>('getRecentPositions');
      if (raw == null) return const [];
      final out = <LocalFix>[];
      for (final item in raw) {
        if (item is Map<Object?, Object?>) {
          final parsed = LocalFix.fromMap(item);
          if (parsed != null) out.add(parsed);
        }
      }
      return out;
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _methodChannel.invokeMethod<void>('clearRecentPositions');
    } on MissingPluginException {
      // No-op in tests / non-Android.
    } on PlatformException {
      // Best-effort clear.
    }
  }

  @override
  Stream<LocalFix> watchFixes() {
    final controller = StreamController<LocalFix>();
    StreamSubscription<dynamic>? sub;
    controller.onListen = () {
      try {
        sub = _eventChannel.receiveBroadcastStream().listen(
          (event) {
            if (event is Map<Object?, Object?>) {
              final fix = LocalFix.fromMap(event);
              if (fix != null && !controller.isClosed) {
                controller.add(fix);
              }
            }
          },
          onError: (_) {
            // Swallow platform channel errors gracefully in non-Android / tests.
          },
        );
      } on MissingPluginException {
        // No-op when plugin is absent.
      } on PlatformException {
        // No-op when platform event channel unavailable.
      }
    };
    controller.onCancel = () async {
      try {
        await sub?.cancel();
      } on MissingPluginException {
        // Ignore on test teardown.
      } on PlatformException {
        // Ignore on test teardown.
      }
      sub = null;
    };
    return controller.stream;
  }
}

/// Deterministic in-memory [LocalFixSource] for unit/widget/screenshot tests.
class InMemoryLocalFixSource implements LocalFixSource {
  InMemoryLocalFixSource({List<LocalFix> initialFixes = const []})
      : _fixes = List<LocalFix>.from(initialFixes);

  final List<LocalFix> _fixes;
  final _controller = StreamController<LocalFix>.broadcast();
  bool started = false;
  int clearCalls = 0;

  void emit(LocalFix fix) {
    _fixes.add(fix);
    if (!_controller.isClosed) {
      _controller.add(fix);
    }
  }

  @override
  Future<void> startRecording() async {
    started = true;
  }

  @override
  Future<List<LocalFix>> getRecentFixes() async => List<LocalFix>.unmodifiable(_fixes);

  @override
  Future<void> clear() async {
    clearCalls++;
    _fixes.clear();
  }

  @override
  Stream<LocalFix> watchFixes() => _controller.stream;

  Future<void> dispose() => _controller.close();
}
