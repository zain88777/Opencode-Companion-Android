import 'dart:convert';

import 'models.dart';
import 'transport.dart';

/// Everything a client needs to reach one OpenCode server.
class ClientConfig {
  const ClientConfig({
    required this.baseUri,
    required this.api,
    this.directory,
    this.username = 'opencode',
    this.password,
    HttpTransport? transport,
  }) : _transport = transport;

  /// e.g. http://100.64.0.1:4096 (no trailing slash) or a tunnel https URL.
  final Uri baseUri;
  final ServerApi api;

  /// Optional project directory the connection is pinned to.
  final String? directory;
  final String username;
  final String? password;
  final HttpTransport? _transport;

  HttpTransport get transport => _transport ?? IoHttpTransport();

  ClientConfig copyWith({
    Uri? baseUri,
    ServerApi? api,
    String? directory,
    bool clearDirectory = false,
    String? username,
    String? password,
    bool clearPassword = false,
  }) =>
      ClientConfig(
        baseUri: baseUri ?? this.baseUri,
        api: api ?? this.api,
        directory: clearDirectory ? null : (directory ?? this.directory),
        username: username ?? this.username,
        password: clearPassword ? null : (password ?? this.password),
        transport: _transport,
      );

  /// Request headers, including basic auth and the tunnel-bypass hints some
  /// tunnel providers (ngrok/Cloudflare) require to skip their interstitial.
  Map<String, String> headers({bool json = true}) {
    final h = <String, String>{
      if (json) 'Content-Type': 'application/json',
      'Bypass-Tunnel-Reminder': 'true',
      'ngrok-skip-browser-warning': 'true',
      'Accept': 'application/json',
    };
    if (password != null && password!.isNotEmpty) {
      final credentials = base64Encode(utf8.encode('$username:$password'));
      h['Authorization'] = 'Basic $credentials';
    }
    return h;
  }

  /// Query params carrying the optional directory scope, in the bracketed form
  /// the v2 server accepts (`location[directory]=...`).
  Map<String, String> locationQuery() {
    if (directory == null || directory!.isEmpty) return const {};
    return {'location[directory]': directory!};
  }
}