import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_companion/core/api/api_detect.dart';
import 'package:opencode_companion/core/api/errors.dart';
import 'package:opencode_companion/core/api/models.dart';
import 'package:opencode_companion/core/api/transport.dart';

HttpResponse _res(int status, String contentType, String body) => HttpResponse(
      status: status,
      body: body,
      contentType: contentType,
    );

void main() {
  test('v2: /api/info answers 200 JSON', () async {
    final identity = await detectServerApi(
      (path) async => _res(200, 'application/json', '{"version":"2.2.6"}'),
    );
    expect(identity.api, ServerApi.v2);
    expect(identity.version, '2.2.6');
  });

  test('v2: /api/info 401 JSON means the route exists', () async {
    final identity = await detectServerApi(
      (path) async => _res(401, 'application/json', '{"error":"unauthorized"}'),
    );
    expect(identity.api, ServerApi.v2);
    expect(identity.version, isNull);
  });

  test('v1: /api/info falls through to HTML, /global/health is JSON', () async {
    final identity = await detectServerApi((path) async {
      if (path == '/api/info') return _res(200, 'text/html', '<html></html>');
      return _res(200, 'application/json', '{"healthy":true,"version":"1.18.32"}');
    });
    expect(identity.api, ServerApi.v1);
    expect(identity.version, '1.18.32');
  });

  test('status alone is not enough - HTML 200 is not a server', () async {
    expect(
      () => detectServerApi(
        (path) async => _res(200, 'text/html', '<html>app</html>'),
      ),
      throwsA(isA<UnsupportedServerException>()),
    );
  });

  test('a JSON error page is still treated as the matching generation', () async {
    final identity = await detectServerApi(
      (path) async => _res(403, 'application/json', '{"error":"forbidden"}'),
    );
    expect(identity.api, ServerApi.v2);
  });
}