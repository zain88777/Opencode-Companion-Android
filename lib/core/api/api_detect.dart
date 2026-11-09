/// Decides which server API generation a connection speaks, from the response
/// envelope alone.
///
/// Verified against live servers:
///   v2.x   GET /api/info      -> 401 application/json (route exists, auth
///                                 required) / 200 application/json when authed
///          GET /global/health -> 200 text/html (web SPA fall-through)
///   v1.x   GET /api/info      -> 200 text/html (SPA fall-through)
///          GET /global/health -> 200 application/json {healthy, version}
///
/// The discriminator is the content type, never the status code: an unknown
/// route on either server answers 200 with the web SPA's HTML, which is exactly
/// how a v1 server passes a v2 health check and then fails on every later call.
library;

import 'dart:convert';

import 'errors.dart';
import 'models.dart';
import 'transport.dart';


typedef ProbeRequest = Future<HttpResponse> Function(String path);

Future<ServerIdentity> detectServerApi(ProbeRequest probe) async {
  final info = await probe('/api/info');
  if (info.isJson && info.ok) {
    return ServerIdentity(api: ServerApi.v2, version: _versionFrom(info.body));
  }
  if (info.wantsAuth) return const ServerIdentity(api: ServerApi.v2);

  final health = await probe('/global/health');
  if (health.isJson && health.ok) {
    return ServerIdentity(api: ServerApi.v1, version: _versionFrom(health.body));
  }
  if (health.wantsAuth) return const ServerIdentity(api: ServerApi.v1);

  throw UnsupportedServerException(
    'Neither /api/info (v2) nor /global/health (v1) answered with JSON. '
    'This looks like an OpenCode web page, not a server API.',
  );
}

String? _versionFrom(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['version'] is String) {
      return decoded['version'] as String;
    }
  } catch (_) {}
  return null;
}