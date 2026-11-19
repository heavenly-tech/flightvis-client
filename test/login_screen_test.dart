import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

  Future<AppRepository> mockRepo() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesStore.open();
    return AppRepository(
      secure: _FakeSecure(),
      prefs: prefs,
      client: FlightVisClient(baseUrl: prefs.baseUrl()),
    );
  }

  Future<void> pumpLogin(
    WidgetTester tester, {
    required AppRepository repo,
    Future<bool> Function(String baseUrl)? signupAvailabilityProbe,
  }) async {
    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: LoginScreen(
          repo: repo,
          onLoggedIn: () {},
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
}