import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_companion/core/api/client_config.dart';
import 'package:opencode_companion/core/api/models.dart';
import 'package:opencode_companion/core/api/transport.dart';
import 'package:opencode_companion/core/api/v2_client.dart';

/// Routes requests to canned responses captured from a live opencode v2.2.6
/// server, so the client layer is tested against real wire shapes.
class FakeTransport implements HttpTransport {
  FakeTransport(this.routes);

  final Map<String, Object> routes;
  final List<HttpRequest> requests = [];

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    requests.add(request);
    final key = '${request.method} ${request.url.path}';
    final body = routes[key];
    if (body == null) {
      return HttpResponse(status: 404, body: 'not found', contentType: 'text/plain');
    }
    return HttpResponse(
      status: 200,
      body: body is String ? body : body.toString(),
      contentType: 'application/json',
    );
  }

  @override
  Future<HttpBytesResponse> sendBytes(HttpRequest request) async {
    requests.add(request);
    return const HttpBytesResponse(status: 200, bytes: [1, 2, 3]);
  }

  @override
  Future<HttpStreamResponse> openStream(
      Uri url, Map<String, String> headers) async {
    throw UnimplementedError();
  }
}

const _info = '{"version":"2.2.6","pid":1}';

const _sessionList = '''
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

const _messages = '''
{"data":[
  {"id":"msg_3","time":{"created":1700000060000},"type":"idle","outcome":"succeeded"},
  {"id":"msg_2","time":{"created":1700000010000,"completed":1700000020000},
   "type":"assistant","agent":"build","model":{"id":"mimo-v2.6-flash","providerID":"mimo-token-plan"},
   "content":[
     {"type":"reasoning","text":"thinking"},
     {"type":"text","text":"hello"},
     {"type":"tool","id":"call_1","name":"read","state":{"status":"completed","input":{"path":"a.txt"},"content":[{"type":"text","text":"file body"}]}}
   ],
   "finish":"stop","cost":0.01,
   "tokens":{"input":10,"output":2,"reasoning":1,"cache":{"read":0,"write":0}}},
  {"id":"msg_1","time":{"created":1700000000000},"text":"do it","type":"user"}
]}
''';

const _diff = '''
{"data":[{"file":"lib/main.dart","patch":"@@ -1 +1 @@\\n-old\\n+new","additions":1,"deletions":1,"status":"modified"}]}
''';

const _agents = '''
{"data":[{"id":"build","name":"build","mode":"primary","description":"Main agent","hidden":false}]}
''';

const _models = '''
{"data":[{
  "id":"mimo-v2.6-flash","modelID":"mimo-v2.6-flash","providerID":"mimo-token-plan",
  "name":"MiMo V2.6 Flash","capabilities":{"tools":true,"input":["text"],"output":["text"]},
  "variants":[{"id":"low","settings":{"reasoning":{"effort":"low"}}},{"id":"high"}],
  "status":"active","enabled":true,"limit":{"context":200000,"output":32000}
}]}
''';

const _modelDefault = '''
{"data":{
  "id":"mimo-v2.6-flash","modelID":"mimo-v2.6-flash","providerID":"mimo-token-plan",
  "name":"MiMo V2.6 Flash","capabilities":{"tools":true},
  "variants":[],"status":"active","enabled":true,"limit":{"context":200000,"output":32000}
}}
''';

void main() {
  late V2Client client;
  late FakeTransport transport;
  setUp(() {
    transport = FakeTransport({
      'GET /api/info': _info,
      'GET /api/session': _sessionList,
      'GET /api/session/ses_1/message': _messages,
      'GET /api/session/ses_1/diff': _diff,
      'GET /api/agent': _agents,
      'GET /api/model': _models,
      'GET /api/model/default': _modelDefault,
      'GET /api/provider': '{"data":[{"id":"mimo-token-plan","name":"MiMo"}]}',
      'GET /api/location':
          '{"directory":"C:/Users/me/project","project":{"id":"proj_1","directory":"C:/Users/me/project","canonical":"C:/Users/me/project"}}',
      'POST /api/session/ses_1/prompt': '{"data":{}}',
      'POST /api/session/ses_1/model': '{"data":{}}',
      'POST /api/session/ses_1/interrupt': '{"interrupted":true}',
    });
    client = V2Client(ClientConfig(
      baseUri: Uri.parse('http://127.0.0.1:4096'),
      api: ServerApi.v2,
      username: 'opencode',
      password: 'secret',
      transport: transport,
    ));
  });

  test('health parses /api/info', () async {
    final health = await client.health();
    expect(health.healthy, isTrue);
    expect(health.version, '2.2.6');
  });

  test('requests carry basic auth', () async {
    await client.health();
    final request = transport.requests.single;
    expect(
      request.headers['Authorization'],
      'Basic ${base64Encode(utf8.encode('opencode:secret'))}',
    );
  });

  test('listSessions maps the v2 session shape', () async {
    final sessions = await client.listSessions();
    expect(sessions, hasLength(1));
    final session = sessions.single;
    expect(session.id, 'ses_1');
    expect(session.title, 'Fix the login bug');
    expect(session.model?.id, 'mimo-v2.6-flash');
    expect(session.model?.providerID, 'mimo-token-plan');
    expect(session.directory, 'C:/Users/me/project');
    expect(session.outcome, 'succeeded');
    expect(session.tokens.input, 100);
    expect(session.tokens.cacheRead, 1000);
  });

  test('messages drops idle markers and returns oldest-first', () async {
    final messages = await client.messages('ses_1');
    expect(messages.map((m) => m.info.id).toList(), ['msg_1', 'msg_2']);

    final user = messages[0];
    expect(user.info.role, 'user');
    expect(user.parts.single.text, 'do it');

    final assistant = messages[1];
    expect(assistant.info.role, 'assistant');
    expect(assistant.info.finish, 'stop');
    expect(assistant.info.tokens?.input, 10);
    expect(assistant.parts.map((p) => p.type).toList(), [
      PartType.reasoning,
      PartType.text,
      PartType.tool,
    ]);
    expect(assistant.parts.last.state?.status, ToolStatus.completed);
    expect(assistant.parts.last.state?.output, 'file body');
  });

  test('prompt posts text to the session prompt endpoint', () async {
    await client.prompt('ses_1', text: 'hello');
    final request = transport.requests.single;
    expect(request.method, 'POST');
    expect(request.url.path, '/api/session/ses_1/prompt');
    expect(request.body, isA<Map>());
    expect((request.body as Map)['text'], 'hello');
  });

  test('prompt selects the model before prompting', () async {
    await client.prompt(
      'ses_1',
      text: 'hi',
      model: const ModelRef(id: 'm', providerID: 'p', variant: 'high'),
    );
    expect(transport.requests, hasLength(2));
    expect(transport.requests[0].url.path, '/api/session/ses_1/model');
    expect(transport.requests[1].url.path, '/api/session/ses_1/prompt');
  });

  test('diff parses FileDiffInfo entries', () async {
    final diff = await client.diff('ses_1');
    expect(diff, hasLength(1));
    expect(diff.single.file, 'lib/main.dart');
    expect(diff.single.additions, 1);
    expect(diff.single.status, 'modified');
    expect(diff.single.patch, contains('@@'));
  });

  test('agents maps mode and model', () async {
    final agents = await client.agents();
    expect(agents.single.id, 'build');
    expect(agents.single.mode, 'primary');
  });

  test('providerCatalog merges provider, model and default', () async {
    final catalog = await client.providerCatalog();
    expect(catalog.providers.single.id, 'mimo-token-plan');
    expect(catalog.models, hasLength(1));
    expect(catalog.models.single.name, 'MiMo V2.6 Flash');
    expect(catalog.models.single.contextWindow, 200000);
    expect(catalog.models.single.variants, hasLength(2));
    expect(catalog.models.single.variants.first.reasoningEffort, 'low');
    expect(catalog.defaultModel?.modelID, 'mimo-v2.6-flash');
  });

  test('location maps the public info shape', () async {
    final location = await client.location();
    expect(location.directory, 'C:/Users/me/project');
    expect(location.projectID, 'proj_1');
  });

  test('interrupt hits the v2 endpoint', () async {
    await client.interrupt('ses_1');
    expect(transport.requests.single.url.path,
        '/api/session/ses_1/interrupt');
  });

  test('directory scope travels as a bracketed location query', () async {
    final scopedTransport = FakeTransport({
      'GET /api/location':
          '{"directory":"C:/Users/me/project","project":{"id":"p","directory":"d","canonical":"c"}}',
    });
    final scoped = V2Client(ClientConfig(
      baseUri: Uri.parse('http://127.0.0.1:4096'),
      api: ServerApi.v2,
      directory: 'C:/Users/me/project',
      transport: scopedTransport,
    ));
    await scoped.location();
    final uri = scopedTransport.requests.single.url;
    expect(uri.queryParametersAll.containsKey('location[directory]'), isTrue);
    expect(
      uri.queryParametersAll['location[directory]'],
      ['C:/Users/me/project'],
    );
  });
}