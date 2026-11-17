import 'dart:convert';

import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';

import '../api/flight_vis_client.dart';

/// Passkey login via Android Credential Manager (RP ID [FlightVisClient.passkeyRpId]).
class PasskeyAuth {
  PasskeyAuth({PasskeyAuthenticator? authenticator, FlightVisClient? client})
      : _authenticator = authenticator ?? PasskeyAuthenticator(),
        _client = client;

  final PasskeyAuthenticator _authenticator;
  FlightVisClient? _client;

  void bindClient(FlightVisClient client) => _client = client;

  Future<PilotProfile> login() async {
    final client = _client;
    if (client == null) {
      throw FlightVisException('API client not ready');
    }
    final optionsJson = await client.passkeyLoginOptions();
    final request = AuthenticateRequestType.fromJsonString(jsonEncode(optionsJson));
    final credential = await _authenticator.authenticate(request);
    return client.passkeyLoginVerify(credential.toJsonString());
  }
}