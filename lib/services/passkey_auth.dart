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

  Future<PilotProfile> login(String email) async {
    final client = _client;
    if (client == null) {
      throw FlightVisException('API client not ready');
    }
    final begin = await client.passkeyLoginBegin(email);
    final nonce = begin['nonce'] as String?;
    final publicKey = begin['publicKey'];
    if (nonce == null || publicKey == null) {
      throw FlightVisException('passkey begin failed');
    }
    final request = AuthenticateRequestType.fromJsonString(jsonEncode(publicKey));
    final credential = await _authenticator.authenticate(request);
    final credMap = jsonDecode(credential.toJsonString()) as Map<String, dynamic>;
    return client.passkeyLoginFinish(nonce: nonce, credential: credMap);
  }
}