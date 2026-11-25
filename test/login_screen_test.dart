import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import 'package:flight_vis/app_shell.dart';
import 'package:flight_vis/ci_test_keys.dart';
import 'package:flight_vis/screens/login_screen.dart';
import 'package:flight_vis/api/flight_vis_client.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSecure extends SecureStore {
  @override
  Future<String?> readDeviceToken() async => null;
  @override
  Future<String?> readSessionId() async => null;
  @override
  Future<void> writeDeviceToken(String token) async {}
  @override
  Future<void> clearDeviceToken() async {}
  @override
  Future<void> writeSessionId(String sessionId) async {}
  @override
  Future<void> clearSessionId() async {}
  @override
  Future<void> clearAll() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppRepository> mockRepo({http.Client? httpClient}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesStore.open();
    return AppRepository(
      secure: _FakeSecure(),
      prefs: prefs,
      client: FlightVisClient(
        baseUrl: prefs.baseUrl(),
        httpClient: httpClient,
      ),
    );
  }

  Future<void> pumpLogin(
    WidgetTester tester, {
    required AppRepository repo,
    Future<bool> Function(String baseUrl)? signupAvailabilityProbe,
    VoidCallback? onContinueAsGuest,
  }) async {
    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: LoginScreen(
          repo: repo,
          onLoggedIn: () {},
          onContinueAsGuest: onContinueAsGuest,
          signupAvailabilityProbe: signupAvailabilityProbe,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('login shows create account when signup probe is true', (tester) async {
    final repo = await mockRepo();
    await pumpLogin(
      tester,
      repo: repo,
      signupAvailabilityProbe: (_) async => true,
    );
    expect(find.byKey(FlightVisTestKeys.loginRegister), findsOneWidget);
    expect(find.byKey(FlightVisTestKeys.loginRegisterNote), findsOneWidget);
    expect(find.text('Crear cuenta'), findsOneWidget);
    expect(find.textContaining('enlace para entrar'), findsOneWidget);
  });

  testWidgets('login hides create account when signup probe is false', (tester) async {
    final repo = await mockRepo();
    await pumpLogin(
      tester,
      repo: repo,
      signupAvailabilityProbe: (_) async => false,
    );
    expect(find.byKey(FlightVisTestKeys.loginRegister), findsNothing);
    expect(find.byKey(FlightVisTestKeys.loginRegisterNote), findsNothing);
    expect(find.text('Crear cuenta'), findsNothing);
    expect(find.text('Enviar enlace mágico'), findsOneWidget);
  });

  testWidgets('email field is ordered above passkey, magic link, and password toggle', (tester) async {
    final repo = await mockRepo();
    await pumpLogin(
      tester,
      repo: repo,
      signupAvailabilityProbe: (_) async => false,
    );

    final emailTop = tester.getTopLeft(find.widgetWithText(TextField, 'Correo')).dy;
    final passkeyTop = tester.getTopLeft(find.text('Iniciar con passkey')).dy;
    final magicTop = tester.getTopLeft(find.text('Enviar enlace mágico')).dy;
    final passwordToggleTop = tester.getTopLeft(find.text('Usar contraseña')).dy;

    expect(emailTop, lessThan(passkeyTop));
    expect(passkeyTop, lessThan(magicTop));
    expect(magicTop, lessThan(passwordToggleTop));
  });

  testWidgets('empty email shows required error for passkey and magic link', (tester) async {
    var networkCalls = 0;
    final client = http_testing.MockClient((request) async {
      networkCalls++;
      return http.Response('{}', 200);
    });

    final repo = await mockRepo(httpClient: client);
    await pumpLogin(
      tester,
      repo: repo,
      signupAvailabilityProbe: (_) async => false,
    );

    await tester.tap(find.text('Iniciar con passkey'));
    await tester.pump();
    expect(find.text('Ingresa tu correo para continuar.'), findsOneWidget);
    expect(networkCalls, 0);

    // Re-pump fresh state and verify magic link also displays the error instead of returning silently.
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpLogin(
      tester,
      repo: repo,
      signupAvailabilityProbe: (_) async => false,
    );
    expect(find.text('Ingresa tu correo para continuar.'), findsNothing);

    await tester.tap(find.text('Enviar enlace mágico'));
    await tester.pump();
    expect(find.text('Ingresa tu correo para continuar.'), findsOneWidget);
    expect(networkCalls, 0);
  });

  testWidgets('no overflow on small screen with keyboard inset', (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
    });

    final repo = await mockRepo();
    await pumpLogin(
      tester,
      repo: repo,
      signupAvailabilityProbe: (_) async => true,
      onContinueAsGuest: () {},
    );

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('Usar contraseña'));
    await tester.tap(find.text('Usar contraseña'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.byKey(FlightVisTestKeys.loginGuest));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}