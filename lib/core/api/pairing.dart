import 'dart:convert';

import 'errors.dart';
import 'transport.dart';

/// What a scanned QR code asked the app to do.
sealed class PairingPayload {
  const PairingPayload();
}

/// The official OpenCode pairing QR payload: `{"code":"...","urls":["http://..."]}`.
///
/// The desktop app and `opencode pair` produce this; the code is single-use and
/// expires (five minutes from `POST /api/pair`).
class PairingCodePayload extends PairingPayload {
  const PairingCodePayload({required this.code, required this.urls});

  final String code;
  final List<String> urls;
}

/// A printed pairing link: `http://host:port/auth/connect/<code>`.
class PairingLinkPayload extends PairingPayload {
  const PairingLinkPayload({required this.origin, required this.code});

  /// Server origin (scheme + host + port), e.g. http://100.64.0.1:4096.
  final String origin;
  final String code;
}

/// Credentials produced by `tool/qr_serve` for headless servers:
/// `{"v":1,"url":...,"username":...,"password":...}`.
class ManualCredentialsPayload extends PairingPayload {
  const ManualCredentialsPayload({
    required this.url,
    required this.username,
    required this.password,
    this.name,
  });

  final String url;
  final String username;
  final String password;
  final String? name;
}

/// A bare server URL with no credentials - the user will type a password.
class ManualUrlPayload extends PairingPayload {
  const ManualUrlPayload({required this.url});

  final String url;
}

/// A resolved connection, ready to save.
class PairingResult {
  const PairingResult({
    required this.url,
    required this.username,
    required this.password,
    this.name,
  });

  final String url;
  final String username;
  final String password;
  final String? name;
}

/// The one-time code was already spent or expired.
class PairingExpiredException implements Exception {
  const PairingExpiredException();

  @override
  String toString() => 'This pairing code has expired. Generate a new code on '
      'the server and scan again.';
}

/// No advertised server address could be reached.
class PairingUnreachableException implements Exception {
  const PairingUnreachableException();

  @override
  String toString() => 'Could not reach the server at any of its addresses.';
}

final _codePattern = RegExp(r'^[A-Za-z0-9_-]+$');

/// Parses a scanned QR payload. Returns null when the content is not something
/// the app can use.
PairingPayload? parsePairingPayload(String raw) {
  if (raw.isEmpty) return null;
  var value = raw.trim();

  // Tolerate a scheme prefix.
  for (final prefix in ['opencode://', 'opencode:', 'qr:']) {
    if (value.startsWith(prefix)) {
      value = value.substring(prefix.length);
      break;
    }
  }

  // The official JSON payload.
  if (value.startsWith('{')) {
    final decoded = _tryJson(value);
    if (decoded != null) return decoded;
    return null;
  }

  final uri = Uri.tryParse(value);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }

  // http://host:port/auth/connect/<code>
  final segments = uri.pathSegments;
  if (segments.length == 3 &&
      segments[0] == 'auth' &&
      segments[1] == 'connect' &&
      _codePattern.hasMatch(segments[2])) {
    return PairingLinkPayload(
      origin: uri.origin,
      code: segments[2],
    );
  }

  // A bare origin, optionally with a path prefix from a reverse proxy.
  if (uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      uri.queryParameters.isEmpty &&
      uri.fragment.isEmpty) {
    return ManualUrlPayload(url: uri.origin + uri.path);
  }
  return null;
}

PairingPayload? _tryJson(String value) {
  try {
    final decoded = jsonDecode(value);
    if (decoded is! Map) return null;

    final code = decoded['code'];
    if (code is String && _codePattern.hasMatch(code)) {
      final urls = (decoded['urls'] as List?)
              ?.whereType<String>()
              .map((u) => u.trim())
              .where((u) => u.isNotEmpty)
              .toList() ??
          const <String>[];
      return PairingCodePayload(code: code, urls: urls);
    }

    final url = decoded['url'];
    if (url is String && url.isNotEmpty) {
      final username = decoded['username'];
      final password = decoded['password'];
      final name = decoded['name'];
      return ManualCredentialsPayload(
        url: url,
        username: username is String && username.isNotEmpty ? username : 'opencode',
        password: password is String ? password : '',
        name: name is String && name.isNotEmpty ? name : null,
      );
    }
  } catch (_) {}
  return null;
}

/// Resolves a payload into connection credentials.
///
/// Pairing codes are exchanged server-side for a session token, which the
/// server then accepts as the HTTP basic password for username `opencode` - the
/// same shape as `OPENCODE_SERVER_PASSWORD`, so the rest of the app needs no
/// special case.
Future<PairingResult> redeemPairingPayload(
  PairingPayload payload,
  HttpTransport transport,
) async {
  switch (payload) {
    case ManualCredentialsPayload():
      return PairingResult(
        url: payload.url,
        username: payload.username,
        password: payload.password,
        name: payload.name,
      );
    case ManualUrlPayload():
      return PairingResult(url: payload.url, username: 'opencode', password: '');
    case PairingLinkPayload():
      try {
        return await _connect(payload.origin, payload.code, transport);
      } on ApiAuthException {
        // The code is single-use, so a 401 means it was already spent.
        throw const PairingExpiredException();
      }
    case PairingCodePayload():
      if (payload.urls.isEmpty) {
        // No advertised address: the code cannot be redeemed.
        throw const PairingUnreachableException();
      }
      // The code is single-use, so at most one address can succeed. A 401 from
      // any address means another one already spent it.
      var sawUnauthorized = false;
      for (final url in payload.urls.toSet()) {
        try {
          return await _connect(url, payload.code, transport);
        } on ApiAuthException {
          sawUnauthorized = true;
        } catch (_) {
          // Try the next advertised address.
        }
      }
      if (sawUnauthorized) throw const PairingExpiredException();
      throw PairingUnreachableException();
  }
}

Future<PairingResult> _connect(
  String origin,
  String code,
  HttpTransport transport,
) async {
  final base = _normalize(origin);
  final uri = Uri.parse('$base/auth/connect/$code');
  final response = await transport
      .send(HttpRequest(
        method: 'GET',
        url: uri,
        headers: const {'Accept': 'application/json'},
      ))
      .timeout(const Duration(seconds: 8));
  if (response.status == 401 || response.status == 403) {
    throw ApiAuthException(response.status, response.body);
  }
  if (!response.ok) {
    throw ApiException(response.status, response.body);
  }
  final decoded = response.json;
  final token = decoded is Map ? decoded['token'] : null;
  if (token is! String || token.isEmpty) {
    throw ApiException(response.status, 'Pairing response had no token');
  }
  return PairingResult(
    url: base,
    username: 'opencode',
    password: token,
  );
}

String _normalize(String url) {
  var value = url.trim();
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}