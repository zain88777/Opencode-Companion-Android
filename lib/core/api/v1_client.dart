import 'dart:convert';

import '../events/server_event.dart';
import 'base_client.dart';
import 'errors.dart';
import 'models.dart';
import 'opencode_client.dart';

/// Client for the legacy OpenCode v1 server API (pre-2.0 routes).
///
/// Kept separate from [V2Client] rather than as fallbacks inside one request
/// path: the two generations differ in routing prefix, list envelopes, SSE
/// payload names and the approval endpoints, and mixing them is where silent
/// failures come from. Both return the same internal shapes.
class V1Client extends BaseClient {
  V1Client(super.config);

  @override
  String get eventPath => '/event';

  @override
  List<ServerEvent> translate(Map<String, dynamic> raw) => _translate(raw);

  // -- health ---------------------------------------------------------------

  @override
  Future<HealthInfo> health() async {
    final json =
        await sendJson('GET', '/global/health', timeout: BaseClient.healthTimeout);
    return HealthInfo.fromJson(json);
  }

  // -- sessions -------------------------------------------------------------

  @override
  Future<List<Session>> listSessions() async {
    try {
      final json = await sendJson(
        'GET',
        '/experimental/session',
        query: {'limit': '500', 'order': 'desc'},
      );
      final data = json['data'];
      if (data is List) {
        return data
            .whereType<Map>()
            .map((e) => Session.fromJson(e.cast<String, dynamic>()))
            .toList();
      }
    } on ApiException catch (e) {
      if (!e.isNotFound) rethrow;
    }
    final list = await sendJsonList('GET', '/session');
    return list
        .whereType<Map>()
        .map((e) => Session.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  @override
  Future<Session?> getSession(String sessionID) async {
    try {
      final json = await sendJson('GET', '/session/$sessionID');
      return Session.fromJson(json);
    } on ApiException catch (e) {
      if (e.isNotFound) return null;
      rethrow;
    }
  }

  @override
  Future<Session> createSession({String? title}) async {
    final json = await sendJson('POST', '/session', body: {
      if (title != null && title.isNotEmpty) 'title': title,
    });
    return Session.fromJson(json);
  }

  @override
  Future<void> deleteSession(String sessionID) async {
    await send('DELETE', '/session/$sessionID');
  }

  @override
  Future<Session> renameSession(String sessionID, String title) async {
    final json = await sendJson('PATCH', '/session/$sessionID', body: {
      'title': title,
    });
    return Session.fromJson(json);
  }

  // -- messages -------------------------------------------------------------

  @override
  Future<List<MessageWithParts>> messages(String sessionID, {int? limit}) async {
    final query = limit == null ? null : {'limit': '$limit'};
    final list = await sendJsonList(
      'GET',
      '/session/$sessionID/message',
      query: query,
    );
    return list
        .whereType<Map>()
        .map((e) => _messageWithParts(e.cast<String, dynamic>()))
        .whereType<MessageWithParts>()
        .toList();
  }

  MessageWithParts? _messageWithParts(Map<String, dynamic> json) {
    final info = json['info'];
    final parts = json['parts'];
    if (info is! Map) return null;
    final message = Message.fromJson(info.cast<String, dynamic>());
    final partList = (parts as List? ?? const [])
        .whereType<Map>()
        .map((p) => Part.fromJson(p.cast<String, dynamic>()))
        .toList();
    return MessageWithParts(info: message, parts: partList);
  }

  @override
  Future<void> prompt(
    String sessionID, {
    required String text,
    List<PromptFile> files = const [],
    ModelRef? model,
    String? agent,
  }) async {
    // Fire-and-forget: the SSE stream drives every real-time update.
    await send('POST', '/session/$sessionID/prompt_async', body: {
      'parts': [
        {'type': 'text', 'text': text},
        ...files.map((f) => {
              'type': 'file',
              'mime': f.mime,
              'url': f.uri,
              if (f.name != null) 'filename': f.name,
            }),
      ],
      if (model != null) 'model': model.toJson(),
      if (agent != null) 'agent': agent,
    });
  }

  @override
  Future<void> runCommand(String sessionID, String command, {String? args}) async {
    await send('POST', '/session/$sessionID/command', body: {
      'command': command,
      'arguments': args ?? '',
      'sessionID': sessionID,
    });
  }

  @override
  Future<bool> interrupt(String sessionID) async {
    await send('POST', '/session/$sessionID/abort');
    return true;
  }

  // -- diffs ----------------------------------------------------------------

  @override
  Future<List<DiffEntry>> diff(String sessionID) async {
    final list = await sendJsonList('GET', '/session/$sessionID/diff');
    return list.whereType<Map>().map((e) {
      final m = e.cast<String, dynamic>();
      return DiffEntry(
        file: m['file'] as String? ?? m['path'] as String? ?? '',
        patch: m['patch'] as String? ?? '',
        status: m['status'] as String? ?? 'modified',
        additions: _asInt(m['additions']),
        deletions: _asInt(m['deletions']),
      );
    }).toList();
  }

  @override
  Future<List<DiffEntry>> vcsDiff({String mode = 'working'}) async {
    // v1 has no separate VCS diff endpoint; the session diff is the best fit.
    return const [];
  }

  @override
  Future<bool> revert(String sessionID, String messageID) async {
    await send('POST', '/session/$sessionID/revert', body: {'messageID': messageID});
    return true;
  }

  @override
  Future<bool> unrevert(String sessionID) async {
    await send('POST', '/session/$sessionID/unrevert');
    return true;
  }

  // -- approvals ------------------------------------------------------------

  @override
  Future<List<PermissionRequest>> permissions({String? sessionID}) async {
    final list = await sendJsonList('GET', '/permission');
    return list
        .whereType<Map>()
        .map((e) => _permissionFrom(e.cast<String, dynamic>()))
        .whereType<PermissionRequest>()
        .where((p) => sessionID == null || p.sessionID == sessionID)
        .toList();
  }

  PermissionRequest? _permissionFrom(Map<String, dynamic> e) {
    final id = e['id'] as String?;
    final sessionID = e['sessionID'] as String?;
    if (id == null || sessionID == null) return null;
    if (e['action'] != null) {
      return PermissionRequest(
        id: id,
        sessionID: sessionID,
        action: e['action'] as String,
        resources: ((e['resources'] as List?) ?? const [])
            .map((r) => r.toString())
            .toList(),
      );
    }
    return PermissionRequest(
      id: id,
      sessionID: sessionID,
      action: e['tool'] as String? ?? '',
      resources: const [],
      metadata: (e['metadata'] as Map?)?.cast<String, dynamic>() ?? const {},
      sourceCallID: e['tool'] as String?,
    );
  }

  @override
  Future<bool> replyPermission(
    String sessionID,
    String requestID,
    String decision,
  ) async {
    await send('POST', '/permission/$requestID/reply', body: {'reply': decision});
    return true;
  }

  @override
  Future<List<QuestionRequest>> questions({String? sessionID}) async {
    final list = await sendJsonList('GET', '/question');
    return list
        .whereType<Map>()
        .map((e) => _questionFrom(e.cast<String, dynamic>()))
        .whereType<QuestionRequest>()
        .where((q) => sessionID == null || q.sessionID == sessionID)
        .toList();
  }

  QuestionRequest? _questionFrom(Map<String, dynamic> e) {
    final id = e['id'] as String?;
    final sessionID = e['sessionID'] as String?;
    if (id == null || sessionID == null) return null;
    final rawQuestions = (e['questions'] as List?) ?? const [];
    final fields = <FormField>[];
    final questions = <Question>[];
    for (var i = 0; i < rawQuestions.length; i++) {
      final q = rawQuestions[i];
      if (q is! Map) continue;
      final map = q.cast<String, dynamic>();
      fields.add(FormField(
        key: 'q$i',
        type: 'string',
        title: map['header'] as String?,
        description: map['question'] as String?,
      ));
      questions.add(Question(
        key: 'q$i',
        header: map['header'] as String? ?? 'Question',
        question: map['question'] as String? ?? '',
        options: ((map['options'] as List?) ?? const [])
            .whereType<Map>()
            .map((o) => FormOption(
                  label: o['label'] as String? ?? '',
                  value: o['value'] as String? ?? o['label'] as String? ?? '',
                ))
            .toList(),
        multiple: map['multiple'] as bool? ?? false,
      ));
    }
    return QuestionRequest(
      id: id,
      sessionID: sessionID,
      title: e['title'] as String? ?? '',
      fields: fields,
      questions: questions,
    );
  }

  @override
  Future<bool> replyQuestion(
    String sessionID,
    String requestID,
    Map<String, dynamic> answers,
  ) async {
    // v1 takes a positional list of selected labels per question.
    final positional = answers.values.map((v) {
      if (v is List) return v.map((e) => e.toString()).toList();
      return <String>[v.toString()];
    }).toList();
    await send('POST', '/question/$requestID/reply', body: {'answers': positional});
    return true;
  }

  @override
  Future<bool> rejectQuestion(String sessionID, String requestID) async {
    await send('POST', '/question/$requestID/reject');
    return true;
  }

  // -- catalog --------------------------------------------------------------

  @override
  Future<List<AgentInfo>> agents() async {
    final list = await sendJsonList('GET', '/agent');
    return list.whereType<Map>().map((e) {
      final m = e.cast<String, dynamic>();
      return AgentInfo(
        id: m['name'] as String? ?? '',
        name: m['name'] as String? ?? '',
        mode: m['mode'] as String? ?? 'all',
        description: m['description'] as String?,
        hidden: m['hidden'] as bool? ?? false,
        color: m['color'] as String?,
        model: m['model'] == null
            ? null
            : ModelRef.fromJson(m['model'] as Map<String, dynamic>),
        steps: _asInt(m['steps']),
      );
    }).toList();
  }

  @override
  Future<List<CommandInfo>> commands() async {
    final list = await sendJsonList('GET', '/command');
    return list.whereType<Map>().map((e) {
      final m = e.cast<String, dynamic>();
      return CommandInfo(
        name: m['name'] as String? ?? '',
        description: m['description'] as String?,
      );
    }).toList();
  }

  @override
  Future<ProviderCatalog> providerCatalog() async {
    final json = await sendJson('GET', '/provider');
    final all = (json['all'] as List?) ?? const [];
    final providers = <ProviderInfo>[];
    final models = <ModelInfo>[];
    for (final entry in all.whereType<Map>()) {
      final m = entry.cast<String, dynamic>();
      final id = m['id'] as String? ?? '';
      providers.add(ProviderInfo(
        id: id,
        name: m['name'] as String? ?? id,
      ));
      final providerModels = (m['models'] as Map?) ?? const {};
      for (final key in providerModels.keys) {
        final model = providerModels[key];
        if (model is! Map) continue;
        final mm = model.cast<String, dynamic>();
        models.add(ModelInfo(
          providerID: id,
          modelID: key,
          name: mm['name'] as String? ?? key,
          hasTools: mm['tools'] as bool? ?? false,
          contextWindow: _asInt(mm['limit']?['context']),
          maxOutput: _asInt(mm['limit']?['output']),
          status: mm['status'] as String?,
          enabled: mm['enabled'] as bool? ?? true,
        ));
      }
    }
    return ProviderCatalog(providers: providers, models: models);
  }

  @override
  Future<void> selectModel(String sessionID, ModelRef model) async {
    await send('POST', '/session/$sessionID/model', body: model.toJson());
  }

  @override
  Future<void> selectAgent(String sessionID, String agent) async {
    await send('POST', '/session/$sessionID/agent', body: {'agent': agent});
  }

  // -- filesystem -----------------------------------------------------------

  @override
  Future<List<FileEntry>> listFiles({String path = '.'}) async {
    final list = await sendJsonList('GET', '/file', query: {'path': path});
    return list.whereType<Map>().map((e) {
      final m = e.cast<String, dynamic>();
      final rawPath = m['path'] as String? ?? '';
      final segments =
          rawPath.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
      return FileEntry(
        name: segments.isEmpty ? rawPath : segments.last,
        path: rawPath,
        absolute: m['absolute'] as String? ?? rawPath,
        isDirectory: m['type'] == 'directory',
        ignored: m['ignored'] as bool? ?? false,
      );
    }).toList();
  }

  @override
  Future<FileContent?> readFile(String path) async {
    final bytes = await sendBytes('GET', '/file/content', query: {'path': path});
    if (bytes == null) return null;
    return FileContent(path: path, content: utf8.decode(bytes, allowMalformed: true));
  }

  @override
  Future<LocationInfo> location() async {
    final json = await sendJson('GET', '/path');
    return LocationInfo(
      directory: json['directory'] as String? ?? json['home'] as String? ?? '',
      projectCanonical: json['worktree'] as String?,
    );
  }

  // -- events ---------------------------------------------------------------

  List<ServerEvent> _translate(Map<String, dynamic> raw) {
    final type = raw['type'] as String? ?? '';
    final props = (raw['properties'] as Map?)?.cast<String, dynamic>() ??
        (raw['data'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};

    switch (type) {
      case 'message.updated':
        final info = props['info'];
        if (info is Map) {
          return [MessageUpdatedEvent(info: Message.fromJson(info.cast<String, dynamic>()))];
        }
        return const [];

      case 'message.part.updated':
        final part = props['part'];
        if (part is Map) {
          return [MessagePartUpdatedEvent(part: Part.fromJson(part.cast<String, dynamic>()))];
        }
        return const [];

      case 'message.removed':
        return [
          MessageRemovedEvent(
            sessionID: props['sessionID'] as String? ?? '',
            messageID: props['messageID'] as String? ?? '',
          ),
        ];

      case 'session.status':
        final status = props['status'];
        final statusMap = status is Map ? status.cast<String, dynamic>() : const <String, dynamic>{};
        return [
          SessionStatusEvent(
            sessionID: props['sessionID'] as String? ?? '',
            status: statusMap['type'] as String? ?? 'idle',
            retryMessage: statusMap['message'] as String?,
            retryNext: _asInt(statusMap['next']),
          ),
        ];

      case 'session.created':
      case 'session.updated':
        final info = props['info'];
        if (info is Map) {
          final session = Session.fromJson(info.cast<String, dynamic>());
          return [
            type == 'session.created'
                ? SessionCreatedEvent(session: session)
                : SessionUpdatedEvent(session: session),
          ];
        }
        return const [];

      case 'session.deleted':
        return [
          SessionDeletedEvent(sessionID: props['sessionID'] as String? ?? ''),
        ];

      case 'session.error':
        return [
          SessionErrorEvent(
            sessionID: props['sessionID'] as String? ?? '',
            message: _errorMessage(props['error']),
          ),
        ];

      case 'permission.asked':
      case 'permission.v2.asked':
        final request = _permissionFrom(props);
        if (request == null) return const [];
        return [PermissionAskedEvent(request: request)];

      case 'permission.replied':
      case 'permission.rejected':
        return [
          PermissionResolvedEvent(
            sessionID: props['sessionID'] as String? ?? '',
            requestID: props['requestID'] as String? ?? props['id'] as String? ?? '',
            reply: props['reply'] as String? ?? 'once',
          ),
        ];

      case 'question.asked':
        final request = _questionFrom(props);
        if (request == null) return const [];
        return [QuestionAskedEvent(request: request)];

      case 'question.replied':
      case 'question.rejected':
        return [
          QuestionResolvedEvent(
            sessionID: props['sessionID'] as String? ?? '',
            requestID: props['requestID'] as String? ?? props['id'] as String? ?? '',
            cancelled: type == 'question.rejected',
          ),
        ];

      case 'filesystem.changed':
        return [
          FilesChangedEvent(
            file: props['file'] as String? ?? props['path'] as String? ?? '',
            change: props['event'] as String? ?? 'change',
          ),
        ];

      default:
        return const [];
    }
  }

  String _errorMessage(Object? error) {
    if (error == null) return 'Session error occurred';
    if (error is String) return error;
    if (error is Map) {
      final msg = error['message'];
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