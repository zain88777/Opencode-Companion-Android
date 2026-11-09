import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_detect.dart';
import '../api/client_config.dart';
import '../api/models.dart';
import '../api/opencode_client.dart';
import '../api/transport.dart';
import '../api/v1_client.dart';
import '../api/v2_client.dart';
import 'credential_store.dart';
import 'server_connection.dart';

/// Persists connections and their credentials, and vends clients for them.
///
/// Connection metadata lives in shared preferences (no secrets); passwords live
/// in the platform keystore via [CredentialStore].
class ConnectionStore extends ChangeNotifier {
  ConnectionStore({
    CredentialStore? credentials,
    SharedPreferences? prefs,
    HttpTransport? transport,
  })  : _credentials = credentials,
        _prefs = prefs,
        _transport = transport;

  static const _metadataKey = 'opencode_connections_v1';
  static const _activeKey = 'opencode_active_connection_v1';
  static const _passwordPrefix = 'conn_password_';

  final CredentialStore? _credentials;
  final SharedPreferences? _prefs;
  final HttpTransport? _transport;

  /// Transport used for probing and for clients, so tests can substitute one.
  HttpTransport get _http => _transport ?? IoHttpTransport();

  /// Public so flows that run before a client exists (QR pairing) can use it.
  HttpTransport get httpTransport => _http;

  /// Where passwords are stored. Defaults to the platform keystore.
  Future<CredentialStore> get _credentialStore async =>
      _credentials ?? KeystoreCredentialStore();

  final Map<String, OpencodeClient> _clients = {};
  final Map<String, String> _passwords = {};

  List<ServerConnection> connections = [];
  ServerConnection? active;
  bool loaded = false;

  OpencodeClient? get activeClient => active == null ? null : clientFor(active!);

  /// Loads saved connections from disk. Call once at startup.
  Future<void> load() async {
    if (loaded) return;
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final raw = prefs.getString(_metadataKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List;
        connections = decoded
            .whereType<Map>()
            .map((e) => ServerConnection.fromJson(e.cast<String, dynamic>()))
            .toList();
      } catch (_) {
        connections = [];
      }
    }

    final activeId = prefs.getString(_activeKey);
    if (activeId != null) {
      for (final c in connections) {
        if (c.id == activeId) {
          active = c;
          break;
        }
      }
    }

    // Passwords are read lazily per connection so a missing keystore entry does
    // not block startup.
    loaded = true;
    if (active != null) {
      await passwordFor(active!);
    }
    notifyListeners();
  }

  Future<SharedPreferences> get _preferences async =>
      _prefs ?? await SharedPreferences.getInstance();

  Future<String?> passwordFor(ServerConnection connection) async {
    if (_passwords.containsKey(connection.id)) {
      return _passwords[connection.id];
    }
    try {
      final store = await _credentialStore;
      final value = await store.read('$_passwordPrefix${connection.id}');
      _passwords[connection.id] = value ?? '';
      return value;
    } catch (e) {
      // A broken keystore must not brick the app; treat the password as absent.
      debugPrint('secure storage read failed: $e');
      _passwords[connection.id] = '';
      return '';
    }
  }

  /// Probes a URL without saving it. Returns the detected API generation.
  Future<ServerIdentity> probe(
      String url, String username, String password) async {
    final base = Uri.parse(ServerConnection.normalizeUrl(url));
    final config = ClientConfig(
      baseUri: base,
      api: ServerApi.v2,
      username: username.isEmpty ? 'opencode' : username,
      password: password,
      transport: _http,
    );
    return detectServerApi((path) async {
      final basePath = base.path.endsWith('/')
          ? base.path.substring(0, base.path.length - 1)
          : base.path;
      final uri = base.replace(
        path: '$basePath$path',
        queryParameters: const {},
      );
      return config.transport
          .send(HttpRequest(
            method: 'GET',
            url: uri,
            headers: config.headers(json: false),
          ))
          .timeout(const Duration(seconds: 8));
    });
  }

  /// Saves a new connection (or updates an existing one with the same id).
  Future<void> save(
    ServerConnection connection, {
    String? password,
    bool setActive = true,
  }) async {
    final index = connections.indexWhere((c) => c.id == connection.id);
    if (index >= 0) {
      final existing = connections[index];
      final merged = existing.copyWith(
        name: connection.name,
        url: connection.url,
        username: connection.username,
        api: connection.api,
        directory: connection.directory,
        clearDirectory: connection.directory == null,
        serverVersion: connection.serverVersion,
        lastUsed: DateTime.now().millisecondsSinceEpoch,
      );
      connections[index] = merged;
      connection = merged;
    } else {
      connections.add(connection.copyWith(
        lastUsed: DateTime.now().millisecondsSinceEpoch,
      ));
      connection = connections.last;
    }

    if (password != null) {
      try {
        final store = await _credentialStore;
        if (password.isEmpty) {
          await store.delete('$_passwordPrefix${connection.id}');
        } else {
          await store.write('$_passwordPrefix${connection.id}', password);
        }
      } catch (e) {
        debugPrint('secure storage write failed: $e');
      }
      // Keep the in-memory cache current either way, so the client can be
      // built without touching the keystore again.
      _passwords[connection.id] = password;
    }

    if (setActive) active = connection;

    // A new or changed connection needs a fresh client (fresh SSE stream).
    await disposeClient(connection.id);
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    connections = connections.where((c) => c.id != id).toList();
    if (active?.id == id) {
      active = connections.isEmpty ? null : connections.first;
      final prefs = await _preferences;
      if (active == null) {
        await prefs.remove(_activeKey);
      } else {
        await prefs.setString(_activeKey, active!.id);
      }
    }
    await disposeClient(id);
    _passwords.remove(id);
    try {
      final store = await _credentialStore;
      await store.delete('$_passwordPrefix$id');
    } catch (e) {
      debugPrint('secure storage delete failed: $e');
    }
    await _persist();
    notifyListeners();
  }

  Future<void> setActive(ServerConnection connection) async {
    active = connection;
    final prefs = await _preferences;
    await prefs.setString(_activeKey, connection.id);
    await save(connection);
  }

  /// Returns a cached client for [connection], creating it on first use.
  OpencodeClient clientFor(ServerConnection connection) {
    return _clients.putIfAbsent(connection.id, () {
      final password = _passwords[connection.id] ?? '';
      final config = ClientConfig(
        baseUri: Uri.parse(connection.url),
        api: connection.api,
        directory: connection.directory,
        username: connection.username.isEmpty ? 'opencode' : connection.username,
        password: password,
        transport: _http,
      );
      return switch (connection.api) {
        ServerApi.v2 => V2Client(config),
        ServerApi.v1 => V1Client(config),
      };
    });
  }

  /// Loads a password into the cache without exposing it to the caller.
  Future<void> primePassword(ServerConnection connection) async {
    await passwordFor(connection);
  }

  Future<void> disposeClient(String id) async {
    final client = _clients.remove(id);
    await client?.dispose();
  }

  Future<void> _persist() async {
    final prefs = await _preferences;
    await prefs.setString(
      _metadataKey,
      jsonEncode(connections.map((c) => c.toJson()).toList()),
    );
    if (active != null) {
      await prefs.setString(_activeKey, active!.id);
    }
  }

  /// Disposes every live client and its event stream.
  ///
  /// [dispose] is synchronous (ChangeNotifier contract), so callers that need
  /// to await cleanup - tests, app shutdown - should use this.
  Future<void> shutdown() async {
    for (final client in _clients.values) {
      await client.dispose();
    }
    _clients.clear();
  }

  @override
  void dispose() {
    for (final client in _clients.values) {
      client.dispose();
    }
    _clients.clear();
    super.dispose();
  }
}