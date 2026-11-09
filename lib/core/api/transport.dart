import 'dart:convert';
import 'dart:io';

import 'errors.dart';

/// A single HTTP request, independent of any particular client implementation.
class HttpRequest {
  const HttpRequest({
    required this.method,
    required this.url,
    this.headers = const {},
    this.body,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final Object? body;
}

class HttpResponse {
  const HttpResponse({
    required this.status,
    required this.body,
    this.contentType = '',
  });

  final int status;
  final String body;
  final String contentType;

  bool get isJson => contentType.toLowerCase().contains('application/json');
  bool get ok => status >= 200 && status < 300;
  bool get wantsAuth => status == 401 || status == 403;

  dynamic get json => body.isEmpty ? null : jsonDecode(body);

  Map<String, dynamic> get jsonMap {
    final decoded = json;
    if (decoded is Map<String, dynamic>) return decoded;
    throw ApiException(status, body);
  }

  List<dynamic> get jsonList {
    final decoded = json;
    if (decoded is List) return decoded;
    throw ApiException(status, body);
  }
}

/// A response whose payload is raw bytes rather than text.
class HttpBytesResponse {
  const HttpBytesResponse({
    required this.status,
    required this.bytes,
    this.contentType = '',
  });

  final int status;
  final List<int> bytes;
  final String contentType;

  bool get ok => status >= 200 && status < 300;
  bool get wantsAuth => status == 401 || status == 403;
}

/// An opened SSE stream, with its HTTP status so the caller can reject non-200s.
class HttpStreamResponse {
  const HttpStreamResponse({
    required this.status,
    required this.stream,
    this.contentType = '',
  });

  final int status;
  final Stream<List<int>> stream;
  final String contentType;

  bool get ok => status == 200;
}

/// Abstraction over the HTTP stack so the client and the API-version probe can
/// be unit tested with a fake transport.
abstract class HttpTransport {
  Future<HttpResponse> send(HttpRequest request);

  /// Fetches a payload as raw bytes (used for file reads).
  Future<HttpBytesResponse> sendBytes(HttpRequest request);

  /// Opens the SSE event stream.
  Future<HttpStreamResponse> openStream(
      Uri url, Map<String, String> headers);
}

/// Production transport backed by dart:io.
class IoHttpTransport implements HttpTransport {
  IoHttpTransport({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    final req = await _client.openUrl(request.method, request.url);
    request.headers.forEach((k, v) => req.headers.set(k, v));
    final body = request.body;
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(body)));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    return HttpResponse(
      status: res.statusCode,
      body: text,
      contentType: res.headers.value(HttpHeaders.contentTypeHeader) ?? '',
    );
  }

  @override
  Future<HttpBytesResponse> sendBytes(HttpRequest request) async {
    final req = await _client.openUrl(request.method, request.url);
    request.headers.forEach((k, v) => req.headers.set(k, v));
    if (request.body != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(request.body)));
    }
    final res = await req.close();
    final bytes = await res.fold<List<int>>(
      <int>[],
      (previous, element) => previous..addAll(element),
    );
    return HttpBytesResponse(
      status: res.statusCode,
      bytes: bytes,
      contentType: res.headers.value(HttpHeaders.contentTypeHeader) ?? '',
    );
  }

  @override
  Future<HttpStreamResponse> openStream(
      Uri url, Map<String, String> headers) async {
    final req = await _client.openUrl('GET', url);
    headers.forEach((k, v) => req.headers.set(k, v));
    final response = await req.close();
    return HttpStreamResponse(
      status: response.statusCode,
      stream: response,
      contentType:
          response.headers.value(HttpHeaders.contentTypeHeader) ?? '',
    );
  }
}