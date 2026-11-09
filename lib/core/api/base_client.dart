import 'dart:async';
import 'dart:convert';

import '../events/server_event.dart';
import 'errors.dart';
import 'opencode_client.dart';
import 'sse_stream.dart';
import 'transport.dart';

/// Shared plumbing: request sending, timeouts, and the event stream.
abstract class BaseClient extends OpencodeClient {
  BaseClient(super.config);

  static const Duration defaultTimeout = Duration(seconds: 30);
  static const Duration healthTimeout = Duration(seconds: 8);

  EventStream? _eventStream;
  Stream<ServerEvent>? _translated;

  /// Path of the SSE endpoint for this API generation.
  String get eventPath;

  /// Converts one raw SSE payload into typed events.
  List<ServerEvent> translate(Map<String, dynamic> raw);

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = config.baseUri;
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(
      path: '$basePath$path',
      queryParameters: query ?? const {},
    );
  }

  Map<String, String> _mergedQuery([Map<String, String>? extra]) {
    return {...config.locationQuery(), ...?extra};
  }

  Future<HttpResponse> send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Duration? timeout,
  }) async {
    final uri = _uri(path, _mergedQuery(query));
    final headers = config.headers(json: body != null || method != 'GET');
    try {
      final response = await config.transport
          .send(HttpRequest(
            method: method,
            url: uri,
            headers: headers,
            body: body,
          ))
          .timeout(timeout ?? defaultTimeout);
      if (!response.ok) throw apiErrorFor(response.status, response.body);
      return response;
    } on TimeoutException {
      throw RequestTimeoutException((timeout ?? defaultTimeout).inMilliseconds);
    }
  }

  Future<Map<String, dynamic>> sendJson(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Duration? timeout,
  }) async {
    final response = await send(method, path,
        query: query, body: body, timeout: timeout);
    return response.jsonMap;
  }

  Future<List<dynamic>> sendJsonList(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Duration? timeout,
  }) async {
    final response = await send(method, path,
        query: query, body: body, timeout: timeout);
    return response.jsonList;
  }

  /// Fetches a payload as raw bytes (file reads).
  Future<List<int>?> sendBytes(
    String method,
    String path, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    final uri = _uri(path, _mergedQuery(query));
    try {
      final response = await config.transport
          .sendBytes(HttpRequest(
            method: method,
            url: uri,
            headers: config.headers(json: false),
          ))
          .timeout(timeout ?? defaultTimeout);
      if (!response.ok) {
        throw apiErrorFor(
          response.status,
          utf8.decode(response.bytes, allowMalformed: true),
        );
      }
      return response.bytes;
    } on TimeoutException {
      throw RequestTimeoutException((timeout ?? defaultTimeout).inMilliseconds);
    }
  }

  @override
  Stream<ServerEvent> get events {
    _eventStream ??= EventStream(
      url: _uri(eventPath),
      headers: config.headers(json: false)..remove('Content-Type'),
      transport: config.transport,
    );
    _eventStream!.start();
    // One shared translation pipeline per connection: the translator keeps
    // streaming buffers (text, tool input) that must be shared by every screen
    // listening to this server, and a broadcast stream lets several screens
    // subscribe without opening several SSE connections.
    return _translated ??= _eventStream!.events
        .asyncExpand((raw) => Stream.fromIterable(translate(raw)))
        .asBroadcastStream();
  }

  @override
  Future<void> dispose() async {
    await _eventStream?.dispose();
    _eventStream = null;
  }
}