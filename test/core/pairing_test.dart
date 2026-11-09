import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_companion/core/api/errors.dart';
import 'package:opencode_companion/core/api/pairing.dart';
import 'package:opencode_companion/core/api/transport.dart';

/// Routes by URL so the pairing flow can be exercised without a server.
class PairingTransport implements HttpTransport {
  PairingTransport(this.responses);

  /// Keyed by 'METHOD path'.
  final Map<String, HttpResponse> responses;
  final List<HttpRequest> requests = [];

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    requests.add(request);
    // Keyed by origin + path so several advertised addresses can behave
    // differently in one test.
    final key = '${request.method} ${request.url.origin}${request.url.path}';
    final response = responses[key];
    if (response != null) return response;
    return const HttpResponse(
      status: 500,
      body: 'unexpected request',
      contentType: 'text/plain',
    );
  }

  @override
  Future<HttpBytesResponse> sendBytes(HttpRequest request) async {
    return const HttpBytesResponse(status: 200, bytes: []);
  }

  @override
  Future<HttpStreamResponse> openStream(
      Uri url, Map<String, String> headers) async {
    throw UnimplementedError();
  }
}

HttpResponse _json(String body) => HttpResponse(
      status: 200,
      body: body,
      contentType: 'application/json',
    );

void main() {
  group('parsePairingPayload', () {
    test('parses the official code + urls payload', () {
      final payload = parsePairingPayload(
        '{"code":"fEluJAvuV3zz9d4yAz_2Nw","urls":["http://100.64.0.1:4096","https://t.example.com"]}',
      );
      expect(payload, isA<PairingCodePayload>());
      final code = payload as PairingCodePayload;
      expect(code.code, 'fEluJAvuV3zz9d4yAz_2Nw');
      expect(code.urls, ['http://100.64.0.1:4096', 'https://t.example.com']);
    });

    test('parses a printed /auth/connect link', () {
      final payload =
          parsePairingPayload('http://100.64.0.1:4096/auth/connect/abc-123_XY');
      expect(payload, isA<PairingLinkPayload>());
      final link = payload as PairingLinkPayload;
      expect(link.origin, 'http://100.64.0.1:4096');
      expect(link.code, 'abc-123_XY');
    });

    test('parses the tool/qr_serve credentials payload', () {
      final payload = parsePairingPayload(
        '{"v":1,"url":"http://100.64.0.1:4096","username":"opencode","password":"secret","name":"Home"}',
      );
      expect(payload, isA<ManualCredentialsPayload>());
      final manual = payload as ManualCredentialsPayload;
      expect(manual.url, 'http://100.64.0.1:4096');
      expect(manual.password, 'secret');
      expect(manual.name, 'Home');
    });

    test('defaults a missing username to opencode', () {
      final payload = parsePairingPayload('{"url":"http://h:4096"}');
      expect((payload as ManualCredentialsPayload).username, 'opencode');
    });

    test('parses a bare URL', () {
      final payload = parsePairingPayload('http://192.168.1.20:4096');
      expect(payload, isA<ManualUrlPayload>());
      expect((payload as ManualUrlPayload).url, 'http://192.168.1.20:4096');
    });

    test('keeps a reverse-proxy path prefix on a bare URL', () {
      final payload = parsePairingPayload('https://dev.example.com/opencode');
      expect((payload as ManualUrlPayload).url, 'https://dev.example.com/opencode');
    });

    test('rejects junk, non-http schemes and malformed JSON', () {
      expect(parsePairingPayload(''), isNull);
      expect(parsePairingPayload('hello world'), isNull);
      expect(parsePairingPayload('ftp://host:4096'), isNull);
      expect(parsePairingPayload('{"no_code_or_url":true}'), isNull);
    });

    test('tolerates a scheme prefix and surrounding whitespace', () {
      final payload = parsePairingPayload(
        '  opencode://http://100.64.0.1:4096/auth/connect/abc  ',
      );
      expect(payload, isA<PairingLinkPayload>());
    });
  });

  group('redeemPairingPayload', () {
    test('exchanges a link code for a token used as the password', () async {
      final transport = PairingTransport({
        'GET http://100.64.0.1:4096/auth/connect/abc':
            _json('{"token":"TOKEN_123"}'),
      });
      final result = await redeemPairingPayload(
        const PairingLinkPayload(origin: 'http://100.64.0.1:4096', code: 'abc'),
        transport,
      );
      expect(result.url, 'http://100.64.0.1:4096');
      expect(result.username, 'opencode');
      expect(result.password, 'TOKEN_123');
      // The exchange must not carry basic auth: the code is the credential.
      expect(transport.requests.single.headers.containsKey('Authorization'), isFalse);
    });

    test('tries the next advertised address when the first is unreachable',
        () async {
      final transport = PairingTransport({
        'GET http://100.64.0.1:4096/auth/connect/abc':
            _json('{"token":"TOKEN_123"}'),
      });
      final result = await redeemPairingPayload(
        const PairingCodePayload(
          code: 'abc',
          urls: ['http://192.0.2.1:4096', 'http://100.64.0.1:4096'],
        ),
        transport,
      );
      expect(result.url, 'http://100.64.0.1:4096');
      expect(transport.requests, hasLength(2));
    });

    test('a 401 means the code was already spent', () async {
      final transport = PairingTransport({
        'GET http://100.64.0.1:4096/auth/connect/abc': const HttpResponse(
          status: 401,
          body: 'unauthorized',
          contentType: 'application/json',
        ),
      });
      expect(
        () => redeemPairingPayload(
          const PairingLinkPayload(origin: 'http://100.64.0.1:4096', code: 'abc'),
          transport,
        ),
        throwsA(isA<PairingExpiredException>()),
      );
    });

    test('all-unreachable addresses report unreachable, not expired', () async {
      final transport = PairingTransport({});
      expect(
        () => redeemPairingPayload(
          const PairingCodePayload(code: 'abc', urls: ['http://192.0.2.1:4096']),
          transport,
        ),
        throwsA(isA<PairingUnreachableException>()),
      );
    });

    test('a code payload with no urls cannot be redeemed', () async {
      expect(
        () => redeemPairingPayload(
          const PairingCodePayload(code: 'abc', urls: []),
          PairingTransport({}),
        ),
        throwsA(isA<PairingUnreachableException>()),
      );
    });

    test('manual credentials pass straight through', () async {
      final result = await redeemPairingPayload(
        const ManualCredentialsPayload(
          url: 'http://100.64.0.1:4096',
          username: 'opencode',
          password: 'secret',
        ),
        PairingTransport({}),
      );
      expect(result.password, 'secret');
      expect(result.username, 'opencode');
    });

    test('a missing token in the response is a server error', () async {
      final transport = PairingTransport({
        'GET http://h:4096/auth/connect/abc': _json('{"unexpected":true}'),
      });
      expect(
        () => redeemPairingPayload(
          const PairingLinkPayload(origin: 'http://h:4096', code: 'abc'),
          transport,
        ),
        throwsA(isA<ApiException>()),
      );
    });
  });
}