import 'dart:convert';

import '../events/event_translator.dart';
import '../events/server_event.dart';
import 'base_client.dart';
import 'errors.dart';
import 'models.dart';
import 'opencode_client.dart';

/// Client for the OpenCode v2 server API (`/api/*`, `{data, cursor}` envelopes,
/// `location[directory]` query scoping, typed execution events).
class V2Client extends BaseClient {
  V2Client(super.config);

  final EventTranslator _translator = EventTranslator();

  @override
  String get eventPath => '/api/event';

  @override
  List<ServerEvent> translate(Map<String, dynamic> raw) =>
      _translator.translate(raw);

  // -- health ---------------------------------------------------------------

  @override
  Future<HealthInfo> health() async {
    final json = await sendJson('GET', '/api/info', timeout: BaseClient.healthTimeout);
    return HealthInfo(
      healthy: true,
      version: json['version'] as String? ?? '',
    );
  }

  // -- sessions -------------------------------------------------------------

  @override
  Future<List<Session>> listSessions() async {
    final json = await sendJson(
      'GET',
      '/api/session',
      query: {'limit': '500', 'order': 'desc'},
    );
    final data = (json['data'] as List?) ?? const [];
    return data
        .whereType<Map>()
        .map((e) => Session.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  @override
  Future<Session?> getSession(String sessionID) async {
    try {
      final json = await sendJson('GET', '/api/session/$sessionID');
      final data = json['data'];
      if (data is! Map) return null;
      return Session.fromJson(data.cast<String, dynamic>());
    } on ApiException catch (e) {
      if (e.isNotFound) return null;
      rethrow;
    }
  }

  @override
  Future<Session> createSession({String? title}) async {
    final json = await sendJson('POST', '/api/session', body: {
      if (title != null && title.isNotEmpty) 'title': title,
    });
    final data = json['data'];
    if (data is! Map) {
      throw ApiException(200, 'Unexpected create session response');
    }
    return Session.fromJson(data.cast<String, dynamic>());
  }

  @override
  Future<void> deleteSession(String sessionID) async {
    await send('DELETE', '/api/session/$sessionID');
  }

  @override
  Future<Session> renameSession(String sessionID, String title) async {
    await send('PATCH', '/api/session/$sessionID', body: {'title': title});
    final session = await getSession(sessionID);
    if (session == null) {
      throw ApiException(404, 'Session $sessionID vanished after rename');
    }
    return session;
  }

  // -- messages -------------------------------------------------------------

  @override
  Future<List<MessageWithParts>> messages(String sessionID, {int? limit}) async {
    final List<Map<String, dynamic>> raw;
    if (limit != null) {
      final json = await sendJson(
        'GET',
        '/api/session/$sessionID/message',
        query: {'order': 'desc', 'limit': '$limit'},
      );
      raw = _messageList(json);
    } else {
      raw = [];
      String? cursor;
      for (var page = 0; page < 50; page++) {
        // The server rejects cursor+order together; the cursor encodes direction.
        final query = cursor == null ? {'order': 'desc'} : {'cursor': cursor};
        final json =
            await sendJson('GET', '/api/session/$sessionID/message', query: query);
        final pageMessages = _messageList(json);
        if (pageMessages.isEmpty) break;
        raw.addAll(pageMessages);
        // The server reports an empty string (not null) once it runs out of
        // history, so an empty cursor must end the walk - otherwise this loops
        // through every remaining page for nothing.
        final next = json['cursor']?['next'] as String?;
        cursor = (next == null || next.isEmpty) ? null : next;
        if (cursor == null) break;
      }
    }
    // Server pages newest-first; the chat UI is oldest-first.
    final shaped = raw.map(_toMessageWithParts).whereType<MessageWithParts>().toList();
    return shaped.reversed.toList();
  }

  List<Map<String, dynamic>> _messageList(Map<String, dynamic> json) {
    return ((json['data'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  MessageWithParts? _toMessageWithParts(Map<String, dynamic> m) {
    final id = m['id'] as String?;
    if (id == null) return null;
    final type = m['type'] as String? ?? '';
    final time = (m['time'] as Map?)?.cast<String, dynamic>() ?? const {};

    if (type == 'user') {
      final parts = <Part>[];
      final text = m['text'] as String?;
      if (text != null && text.isNotEmpty) {
        parts.add(Part(
          id: '$id-text',
          messageID: id,
          type: PartType.text,
          text: text,
        ));
      }
      for (final f in (m['files'] as List?) ?? const []) {
        if (f is! Map) continue;
        final uri = _attachmentUrl(f.cast<String, dynamic>());
        if (uri.isEmpty) continue;
        parts.add(Part(
          id: '$id-file',
          messageID: id,
          type: PartType.file,
          mime: f['mime'] as String?,
          url: uri,
          filename: f['name'] as String?,
        ));
      }
      return MessageWithParts(
        info: Message(
          id: id,
          sessionID: m['sessionID'] as String? ?? '',
          role: 'user',
          created: _asInt(time['created']),
        ),
        parts: parts,
      );
    }

    if (type == 'assistant') {
      final model = (m['model'] as Map?)?.cast<String, dynamic>();
      final parts = <Part>[];
      var index = 0;
      for (final c in (m['content'] as List?) ?? const []) {
        if (c is! Map) continue;
        final map = c.cast<String, dynamic>();
        final partType = _partType(map['type'] as String?);
        final partId = '$id-${map['type'] ?? 'part'}-$index';
        index++;
        if (partType == PartType.tool) {
          parts.add(Part(
            id: partId,
            messageID: id,
            type: PartType.tool,
            tool: map['name'] as String?,
            callID: map['id'] as String?,
            state: map['state'] == null
                ? null
                : ToolState.fromJson(map['state'] as Map<String, dynamic>),
            start: _asInt(map['time']?['created']),
            end: _asInt(map['time']?['completed']),
          ));
        } else {
          parts.add(Part(
            id: partId,
            messageID: id,
            type: partType,
            text: map['text'] as String? ?? '',
            start: _asInt(map['time']?['created']),
            end: _asInt(map['time']?['completed']),
          ));
        }
      }
      return MessageWithParts(
        info: Message(
          id: id,
          sessionID: m['sessionID'] as String? ?? '',
          role: 'assistant',
          created: _asInt(time['created']),
          completed: _asInt(time['completed']),
          agent: m['agent'] as String?,
          providerID: model?['providerID'] as String?,
          modelID: model?['id'] as String?,
          cost: _asDouble(m['cost']),
          tokens: m['tokens'] == null
              ? null
              : TokenUsage.fromJson(m['tokens'] as Map<String, dynamic>),
          error: m['error'] == null ? null : _errorMessage(m['error']),
          finish: m['finish'] as String?,
        ),
        parts: parts,
      );
    }

    // idle / agent-switched / model-switched / compaction / system markers
    // carry no chat content.
    return null;
  }

  @override
  Future<void> prompt(
    String sessionID, {
    required String text,
    List<PromptFile> files = const [],
    ModelRef? model,
    String? agent,
  }) async {
    if (model != null) {
      await send('POST', '/api/session/$sessionID/model', body: {
        'model': model.toJson(),
      });
    }
    if (agent != null && agent.isNotEmpty) {
      await send('POST', '/api/session/$sessionID/agent', body: {
        'agent': agent,
      });
    }
    await send('POST', '/api/session/$sessionID/prompt', body: {
      'text': text,
      if (files.isNotEmpty) 'files': files.map((f) => f.toJson()).toList(),
    });
  }

  @override
  Future<void> runCommand(String sessionID, String command, {String? args}) async {
    await send('POST', '/api/session/$sessionID/command', body: {
      'name': command,
      'text': args ?? '',
    });
  }

  @override
  Future<bool> interrupt(String sessionID) async {
    final json = await sendJson('POST', '/api/session/$sessionID/interrupt');
    return json['interrupted'] as bool? ?? false;
  }

  // -- diffs ----------------------------------------------------------------

  @override
  Future<List<DiffEntry>> diff(String sessionID) async {
    final json = await sendJson('GET', '/api/session/$sessionID/diff');
    return _parseDiffs(json['data']);
  }

  @override
  Future<List<DiffEntry>> vcsDiff({String mode = 'working'}) async {
    final json = await sendJson('GET', '/api/vcs/diff', query: {'mode': mode});
    return _parseDiffs(json['data']);
  }

  List<DiffEntry> _parseDiffs(Object? data) {
    if (data is! List) return const [];
    return data.whereType<Map>().map((e) {
      final m = e.cast<String, dynamic>();
      return DiffEntry(
        file: m['file'] as String? ?? m['path'] as String? ?? '',
        patch: m['patch'] as String? ?? '',
        status: m['status'] as String? ?? 'modified',
        additions: _asInt(m['additions']),
        deletions: _asInt(m['deletions']),
        more: m['more'] == true,
      );
    }).toList();
  }

  @override
  Future<bool> revert(String sessionID, String messageID) async {
    await send('POST', '/api/session/$sessionID/revert/stage',
        body: {'messageID': messageID});
    return true;
  }

  @override
  Future<bool> unrevert(String sessionID) async {
    await send('DELETE', '/api/session/$sessionID/revert');
    return true;
  }

  // -- approvals ------------------------------------------------------------

  @override
  Future<List<PermissionRequest>> permissions({String? sessionID}) async {
    final path = sessionID == null
        ? '/api/permission/request'
        : '/api/session/$sessionID/permission';
    final json = await sendJson('GET', path);
    return ((json['data'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => PermissionRequest.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  @override
  Future<bool> replyPermission(
    String sessionID,
    String requestID,
    String decision,
  ) async {
    await send(
      'POST',
      '/api/session/$sessionID/permission/$requestID/reply',
      body: {'decision': decision},
    );
    return true;
  }

  @override
  Future<List<QuestionRequest>> questions({String? sessionID}) async {
    final path = sessionID == null
        ? '/api/form'
        : '/api/session/$sessionID/form';
    final json = await sendJson('GET', path);
    return ((json['data'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => _questionFromForm(e.cast<String, dynamic>()))
        .whereType<QuestionRequest>()
        .toList();
  }

  QuestionRequest? _questionFromForm(Map<String, dynamic> form) {
    final id = form['id'] as String?;
    final sessionID = form['sessionID'] as String?;
    if (id == null || sessionID == null) return null;
    final fields = ((form['fields'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => FormField.fromJson(e.cast<String, dynamic>()))
        .toList();
    return QuestionRequest(
      id: id,
      sessionID: sessionID,
      title: form['title'] as String? ?? '',
      fields: fields,
      questions:
          fields.where((f) => !f.isExternal).map(_questionFromField).toList(),
    );
  }

  Question _questionFromField(FormField f) {
    if (f.type == 'boolean') {
      return Question(
        key: f.key,
        header: f.title ?? f.key,
        question: f.description ?? f.title ?? f.key,
        options: const [
          FormOption(value: 'true', label: 'Yes'),
          FormOption(value: 'false', label: 'No'),
        ],
      );
    }
    final hasOptions = f.options.isNotEmpty;
    return Question(
      key: f.key,
      header: f.title ?? f.key,
      question: f.description ?? f.title ?? f.key,
      options: f.options,
      multiple: f.type == 'multiselect',
      custom: f.custom ||
          ((f.type == 'string' || f.type == 'number' || f.type == 'integer') &&
              !hasOptions),
    );
  }

  @override
  Future<bool> replyQuestion(
    String sessionID,
    String requestID,
    Map<String, dynamic> answers,
  ) async {
    await send(
      'POST',
      '/api/session/$sessionID/form/$requestID/reply',
      body: {'answer': answers},
    );
    return true;
  }

  @override
  Future<bool> rejectQuestion(String sessionID, String requestID) async {
    await send('DELETE', '/api/session/$sessionID/form/$requestID');
    return true;
  }

  // -- catalog --------------------------------------------------------------

  @override
  Future<List<AgentInfo>> agents() async {
    final json = await sendJson('GET', '/api/agent');
    return ((json['data'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => _agentFrom(e.cast<String, dynamic>()))
        .toList();
  }

  AgentInfo _agentFrom(Map<String, dynamic> e) => AgentInfo(
        id: e['id'] as String? ?? e['name'] as String? ?? '',
        name: e['name'] as String? ?? e['id'] as String? ?? '',
        mode: e['mode'] as String? ?? 'all',
        description: e['description'] as String?,
        hidden: e['hidden'] as bool? ?? false,
        color: e['color'] as String?,
        model: e['model'] == null
            ? null
            : ModelRef.fromJson(e['model'] as Map<String, dynamic>),
        steps: _asInt(e['steps']),
      );

  @override
  Future<List<CommandInfo>> commands() async {
    final json = await sendJson('GET', '/api/command');
    return ((json['data'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => CommandInfo(
              name: e['name'] as String? ?? '',
              description: e['description'] as String?,
            ))
        .toList();
  }

  @override
  Future<ProviderCatalog> providerCatalog() async {
    final results = await Future.wait([
      sendJson('GET', '/api/provider'),
      sendJson('GET', '/api/model'),
      sendJson('GET', '/api/model/default'),
    ]);
    final providersJson = results[0];
    final modelsJson = results[1];
    final defaultJson = results[2];

    final providers = ((providersJson['data'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => ProviderInfo(
              id: e['id'] as String? ?? '',
              name: e['name'] as String? ?? e['id'] as String? ?? '',
              activation: e['activation'] as String?,
            ))
        .toList();

    final models = ((modelsJson['data'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => _modelFrom(e.cast<String, dynamic>()))
        .toList();

    final defaultData = defaultJson['data'];
    final defaultModel = defaultData is Map
        ? _modelFrom(defaultData.cast<String, dynamic>())
        : null;

    return ProviderCatalog(
      providers: providers,
      models: models,
      defaultModel: defaultModel,
    );
  }

  ModelInfo _modelFrom(Map<String, dynamic> e) {
    final capabilities =
        (e['capabilities'] as Map?)?.cast<String, dynamic>() ?? const {};
    final limit = (e['limit'] as Map?)?.cast<String, dynamic>() ?? const {};
    final variants = ((e['variants'] as List?) ?? const [])
        .whereType<Map>()
        .map((v) {
      final settings =
          (v['settings'] as Map?)?.cast<String, dynamic>() ?? const {};
      final reasoning = settings['reasoning'] as Map?;
      return ModelVariant(
        id: v['id'] as String? ?? '',
        reasoningEnabled: reasoning?['enabled'] as bool?,
        reasoningEffort: reasoning?['effort'] as String?,
      );
    }).toList();
    return ModelInfo(
      providerID: e['providerID'] as String? ?? '',
      modelID: e['modelID'] as String? ?? e['id'] as String? ?? '',
      name: e['name'] as String? ?? e['modelID'] as String? ?? '',
      hasTools: capabilities['tools'] as bool? ?? false,
      contextWindow: _asInt(limit['context']),
      maxOutput: _asInt(limit['output']),
      status: e['status'] as String?,
      enabled: e['enabled'] as bool? ?? true,
      variants: variants,
    );
  }

  @override
  Future<void> selectModel(String sessionID, ModelRef model) async {
    await send('POST', '/api/session/$sessionID/model', body: {
      'model': model.toJson(),
    });
  }

  @override
  Future<void> selectAgent(String sessionID, String agent) async {
    await send('POST', '/api/session/$sessionID/agent', body: {'agent': agent});
  }

  // -- filesystem -----------------------------------------------------------

  @override
  Future<List<FileEntry>> listFiles({String path = '.'}) async {
    final json = await sendJson('GET', '/api/fs/list', query: {'path': path});
    final location = (json['location'] as Map?)?.cast<String, dynamic>();
    final base = location?['directory'] as String? ?? '';
    return ((json['data'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) {
      final map = e.cast<String, dynamic>();
      final rawPath = map['path'] as String? ?? '';
      final segments =
          rawPath.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
      final name = segments.isEmpty ? rawPath : segments.last;
      return FileEntry(
        name: name,
        path: rawPath,
        absolute: rawPath.startsWith('/') || rawPath.contains(':\\')
            ? rawPath
            : '$base/$rawPath'.replaceAll(RegExp(r'/+'), '/'),
        isDirectory: map['type'] == 'directory',
      );
    }).toList();
  }

  @override
  Future<FileContent?> readFile(String path) async {
    final bytes = await sendBytes('GET', '/api/fs/read/${_encodePath(path)}');
    if (bytes == null) return null;
    return FileContent(
      path: path,
      content: utf8.decode(bytes, allowMalformed: true),
    );
  }

  @override
  Future<LocationInfo> location() async {
    final json = await sendJson('GET', '/api/location');
    final project = (json['project'] as Map?)?.cast<String, dynamic>();
    return LocationInfo(
      directory: json['directory'] as String? ?? '',
      projectID: project?['id'] as String?,
      projectDirectory: project?['directory'] as String?,
      projectCanonical: project?['canonical'] as String?,
    );
  }

  // -- helpers --------------------------------------------------------------

  String _encodePath(String path) => path
      .split(RegExp(r'[\\/]'))
      .map((segment) => Uri.encodeComponent(segment))
      .join('/');

  String _attachmentUrl(Map<String, dynamic> f) {
    final uri = f['uri'] as String?;
    if (uri != null && uri.isNotEmpty) return uri;
    final data = f['data'] as String?;
    final mime = f['mime'] as String?;
    if (data != null && data.isNotEmpty && mime != null) {
      return 'data:$mime;base64,$data';
    }
    final source = f['source'] as Map?;
    return source?['path'] as String? ?? '';
  }

  PartType _partType(String? raw) {
    switch (raw) {
      case 'reasoning':
        return PartType.reasoning;
      case 'tool':
        return PartType.tool;
      case 'file':
        return PartType.file;
      case 'text':
      default:
        return PartType.text;
    }
  }

  String _errorMessage(Object? error) {
    if (error == null) return 'Session error occurred';
    if (error is String) return error;
    if (error is Map) {
      final msg = error['message'] ?? error['data']?['message'];
      if (msg is String && msg.isNotEmpty) return msg;
      return error.toString();
    }
    return error.toString();
  }
}

int _asInt(Object? v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString()) ?? 0;
}

double _asDouble(Object? v) {
  if (v == null) return 0;
  if (v is double) return v;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString()) ?? 0;
}