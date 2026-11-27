import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:flight_vis/widgets/globe_view.dart';

/// Deterministic in-memory [GlobeWebViewController] for widget/golden tests.
class FakeGlobeWebViewController implements GlobeWebViewController {
  FakeGlobeWebViewController({
    this.autoEmitReady = true,
    this.readyDelay = Duration.zero,
    this.failMainFrameLoad = false,
    this.emitWebglError = false,
    this.onRunJavaScript,
    this.onLoadRequest,
    this.backgroundColor = const Color(0xFF07090D),
  });

  final bool autoEmitReady;
  final Duration readyDelay;
  final bool failMainFrameLoad;
  final bool emitWebglError;
  final void Function(String js)? onRunJavaScript;
  final void Function(Uri uri)? onLoadRequest;
  Color backgroundColor;

  final List<String> javaScriptCalls = <String>[];
  final List<Uri> loadedUris = <Uri>[];
  Uri? lastLoadedUri;
  void Function(String message)? _bridgeListener;

  void emitBridgeMessage(Map<String, dynamic> message) {
    _bridgeListener?.call(jsonEncode(message));
  }

  void emitReady({int protocol = 1}) {
    emitBridgeMessage(<String, dynamic>{
      'type': 'ready',
      'protocol': protocol,
      'version': 'test',
    });
  }

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {
    backgroundColor = color;
  }

  @override
  Future<void> addJavaScriptChannel(
    String name, {
    required void Function(String message) onMessageReceived,
  }) async {
    _bridgeListener = onMessageReceived;
  }

  @override
  Future<void> setNavigationDelegate({
    required FutureOr<NavigationDecision> Function(NavigationRequest request)
        onNavigationRequest,
    required void Function(WebResourceError error) onWebResourceError,
    required void Function(HttpResponseError error) onHttpError,
  }) async {
    if (failMainFrameLoad) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onWebResourceError(
          const WebResourceError(
            errorCode: -1,
            description: 'fake load error',
            isForMainFrame: true,
          ),
        );
      });
    }
  }

  @override
  Future<void> loadRequest(Uri uri) async {
    onLoadRequest?.call(uri);
    loadedUris.add(uri);
    lastLoadedUri = uri;
    if (failMainFrameLoad) return;
    if (!autoEmitReady) return;
    Future<void>.delayed(readyDelay, () {
      if (emitWebglError) {
        emitBridgeMessage(<String, dynamic>{
          'type': 'error',
          'code': 'webgl_unavailable',
        });
        return;
      }
      emitReady();
    });
  }

  @override
  Future<void> runJavaScript(String javaScript) async {
    onRunJavaScript?.call(javaScript);
    javaScriptCalls.add(javaScript);
  }

  @override
  Widget buildView({
    required Set<Factory<OneSequenceGestureRecognizer>> gestureRecognizers,
  }) {
    return ColoredBox(color: backgroundColor);
  }

  @override
  void dispose() {}
}