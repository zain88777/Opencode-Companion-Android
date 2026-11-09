import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_companion/app.dart';
import 'package:opencode_companion/core/api/transport.dart';
import 'package:opencode_companion/core/connections/connection_store.dart';
import 'package:opencode_companion/core/connections/credential_store.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serves canned OpenCode v2 responses and an SSE stream that stays open, so
/// the whole app can be driven without a server or a device.
///
/// Like the real server, it refuses unauthenticated requests - which is what
/// makes the "not a server" path testable.
class FakeServer implements HttpTransport {
  FakeServer();

  final StreamController<List<int>> _events =
      StreamController<List<int>>.broadcast();
  final List<HttpRequest> requests = [];

  static const _info = '{"version":"2.2.6"}';
  static const _sessionList = '''
{"data":[{
  "id":"ses_1","projectID":"proj_1","agent":"build",
  "model":{"id":"mimo-v2.6-flash","providerID":"mimo-token-plan"},
  "cost":0.05,"tokens":{"input":100,"output":20,"reasoning":5,"cache":{"read":1000,"write":0}},
  "outcome":"succeeded",
  "time":{"created":1700000000000,"updated":1700000060000,"idle":1700000050000},
  "title":"Fix the login bug",
  "location":{"directory":"C:/Users/me/project"}
}]}
''';
  static const _messages = '''
{"data":[
  {"id":"msg_2","time":{"created":1700000010000,"completed":1700000020000},
   "type":"assistant","agent":"build","model":{"id":"mimo-v2.6-flash","providerID":"mimo-token-plan"},
   "content":[{"type":"text","text":"hello"}],"finish":"stop"},
  {"id":"msg_1","time":{"created":1700000000000},"text":"do it","type":"user"}
]}
''';

  void emit(String json) {
    _events.add(utf8.encode('data: $json\n\n'));
  }

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    requests.add(request);
    final key = '${request.method} ${request.url.path}';
    final authorised = request.headers.containsKey('Authorization');
    final body = switch (key) {
      'GET /api/info' => authorised ? _info : null,
      'GET /api/session' => authorised ? _sessionList : null,
      'GET /api/session/ses_1/message' => authorised ? _messages : null,
      'POST /api/session' => authorised
          ? '{"data":{"id":"ses_1","projectID":"proj_1","time":{"created":1,"updated":1},"location":{"directory":"C:/p"}}}'
          : null,
      _ => null,
    };
    if (body == null) {
      return HttpResponse(
          status: 404, body: 'not found', contentType: 'text/plain');
    }
    return HttpResponse(
        status: 200, body: body, contentType: 'application/json');
  }

  @override
  Future<HttpBytesResponse> sendBytes(HttpRequest request) async {
    return const HttpBytesResponse(status: 200, bytes: [104, 105]);
  }

  @override
  Future<HttpStreamResponse> openStream(
      Uri url, Map<String, String> headers) async {
    emit('{"type":"server.connected","data":{}}');
    return HttpStreamResponse(status: 200, stream: _events.stream);
  }

  Future<void> dispose() async {
    await _events.close();
  }
}

void main() {
  late FakeServer server;
  late ConnectionStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    server = FakeServer();
    store = ConnectionStore(
      transport: server,
      credentials: InMemoryCredentialStore(),
    );
    await store.load();
  });

  tearDown(() async {
    await server.dispose();
  });

  /// Pumps a fixed number of frames instead of pumpAndSettle: the app has
  /// indeterminate progress indicators (and text cursors) that never settle.
  Future<void> settle(WidgetTester tester, [int times = 30]) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ConnectionStore>.value(
        value: store,
        child: const OpenCodeApp(),
      ),
    );
    await settle(tester);
  }

  Future<void> fillServerForm(
    WidgetTester tester, {
    required String url,
    String? password,
  }) async {
    await tester.tap(find.text('Add server'));
    await settle(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Server address'),
      url,
    );
    if (password != null) {
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        password,
      );
    }
    await tester.pump();
  }

  testWidgets('connect, list sessions, open a chat', (tester) async {
    try {
      await pumpApp(tester);

      // First run: the connect screen.
      expect(find.text('Connect to your server'), findsOneWidget);

      await fillServerForm(
        tester,
        url: 'http://127.0.0.1:4096',
        password: 'secret',
      );
      await tester.tap(find.text('Save server'));
      await settle(tester, 60);

      // Back on the home screen, now showing sessions.
      expect(find.text('Sessions'), findsOneWidget);
      expect(find.text('Fix the login bug'), findsOneWidget);

      // Open the chat.
      await tester.tap(find.text('Fix the login bug'));
      await settle(tester, 60);

      expect(find.text('Message the agent...'), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
      expect(find.text('do it'), findsOneWidget);
    } finally {
      await store.shutdown();
    }
  });

  testWidgets('Test button reports the detected API version', (tester) async {
    try {
      await pumpApp(tester);

      await fillServerForm(
        tester,
        url: 'http://127.0.0.1:4096',
        password: 'secret',
      );
      await tester.tap(find.text('Test'));
      await settle(tester, 40);

      expect(find.textContaining('v2 API'), findsOneWidget);
    } finally {
      await store.shutdown();
    }
  });

  testWidgets('an unauthenticated server is rejected with a clear error',
      (tester) async {
    try {
      await pumpApp(tester);

      // No password entered: the server refuses every route, so neither probe
      // path answers as JSON and the app says it is not an OpenCode server.
      await fillServerForm(tester, url: 'http://127.0.0.1:4096');
      await tester.tap(find.text('Test'));
      await settle(tester, 40);

      expect(find.textContaining('not a server API'), findsOneWidget);
    } finally {
      await store.shutdown();
    }
  });
}