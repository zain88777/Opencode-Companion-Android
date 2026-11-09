import 'dart:convert';

import '../api/models.dart';
import 'server_event.dart';

/// Converts raw OpenCode SSE events into the typed events the UI consumes.
///
/// Content events can arrive before `session.step.started` for a step, so the
/// translator keeps assistant messages and streaming text buffers of its own
/// and synthesises a message the first time it sees an assistantMessageID.
/// That guarantees the chat always has a bubble to attach parts to.
///
/// Ported from the reference client's v2-shape.ts translator, adjusted for the
/// payloads verified against a live v2.2.6 server.
class EventTranslator {
  final Map<String, Message> _assistants = {};
  final Map<String, String> _textBuf = {};
  final Map<String, String> _reasoningBuf = {};
  final Map<String, _ToolBuf> _tools = {};

  void reset() {
    _assistants.clear();
    _textBuf.clear();
    _reasoningBuf.clear();
    _tools.clear();
  }

  List<ServerEvent> translate(Map<String, dynamic> raw) {
    final type = raw['type'] as String? ?? '';
    final data = (raw['data'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final created = _asInt(raw['created']);

    switch (type) {
      case 'server.connected':
      case 'project.updated':
      case 'session.inbox.delivered':
      case 'session.viewed':
      case 'session.metadata.updated':
      case 'session.model.selected':
      case 'session.agent.selected':
      case 'session.usage.recorded':
      case 'session.instructions.updated':
      case 'session.step.streamed':
        return const [];

      case 'session.execution.started':
        final sessionID = data['sessionID'] as String?;
        if (sessionID == null) return const [];
        return [SessionStatusEvent(sessionID: sessionID, status: 'busy')];

      case 'session.execution.succeeded':
      case 'session.execution.interrupted':
        final sessionID = data['sessionID'] as String?;
        if (sessionID == null) return const [];
        return [SessionStatusEvent(sessionID: sessionID, status: 'idle')];

      case 'session.execution.failed':
        final sessionID = data['sessionID'] as String?;
        if (sessionID == null) return const [];
        return [
          SessionErrorEvent(
            sessionID: sessionID,
            message: _errorMessage(data['error']),
          ),
          SessionStatusEvent(sessionID: sessionID, status: 'idle'),
        ];

      case 'session.error':
        final sessionID = data['sessionID'] as String?;
        if (sessionID == null) return const [];
        return [
          SessionErrorEvent(
            sessionID: sessionID,
            message: _errorMessage(data['error']),
          ),
        ];

      case 'session.status':
        final sessionID = data['sessionID'] as String?;
        final status = (data['status'] as Map?)?.cast<String, dynamic>();
        if (sessionID == null || status == null) return const [];
        return [
          SessionStatusEvent(
            sessionID: sessionID,
            status: status['type'] as String? ?? 'idle',
            retryMessage: status['message'] as String?,
            retryNext: _asInt(status['next']),
          ),
        ];

      case 'session.idle':
        final sessionID = data['sessionID'] as String?;
        if (sessionID == null) return const [];
        return [SessionStatusEvent(sessionID: sessionID, status: 'idle')];

      case 'session.step.started':
        final sessionID = data['sessionID'] as String?;
        final messageID = data['assistantMessageID'] as String?;
        if (sessionID == null || messageID == null) return const [];
        final model = data['model'] as Map<String, dynamic>?;
        final message = Message(
          id: messageID,
          sessionID: sessionID,
          role: 'assistant',
          created: _asInt(data['started'] ?? created),
          agent: data['agent'] as String?,
          providerID: model?['providerID'] as String?,
          modelID: model?['id'] as String?,
        );
        _assistants[messageID] = message;
        return [MessageUpdatedEvent(info: message)];

      case 'session.step.ended':
        final messageID = data['assistantMessageID'] as String?;
        if (messageID == null) return const [];
        final base = _assistant(messageID, data['sessionID'] as String? ?? '',
            created);
        final tokens = data['tokens'] as Map<String, dynamic>?;
        final updated = base.copyWith(
          completed: created,
          finish: data['finish'] as String?,
          cost: _asDouble(data['cost']),
          tokens: tokens == null ? null : TokenUsage.fromJson(tokens),
          clearCost: data['cost'] == null,
          clearTokens: tokens == null,
        );
        _assistants[messageID] = updated;
        return [MessageUpdatedEvent(info: updated)];

      case 'session.step.failed':
        final messageID = data['assistantMessageID'] as String?;
        if (messageID == null) return const [];
        final base = _assistant(messageID, data['sessionID'] as String? ?? '',
            created);
        final updated = base.copyWith(
          completed: created,
          error: _errorMessage(data['error']),
          finish: data['finish'] as String? ?? 'error',
        );
        _assistants[messageID] = updated;
        return [MessageUpdatedEvent(info: updated)];

      case 'session.usage.updated':
        final sessionID = data['sessionID'] as String?;
        if (sessionID == null) return const [];
        Message? latest;
        for (final m in _assistants.values) {
          if (m.sessionID == sessionID) latest = m;
        }
        if (latest == null) return const [];
        final tokens = data['tokens'] as Map<String, dynamic>?;
        final updated = latest.copyWith(
          cost: _asDouble(data['cost']),
          tokens: tokens == null ? null : TokenUsage.fromJson(tokens),
          clearCost: data['cost'] == null,
          clearTokens: tokens == null,
        );
        _assistants[latest.id] = updated;
        return [MessageUpdatedEvent(info: updated)];

      case 'session.text.started':
      case 'session.text.delta':
      case 'session.text.ended':
        return _streamedText(
          data: data,
          created: created,
          kind: 'text',
          partType: PartType.text,
          buffer: _textBuf,
        );

      case 'session.reasoning.started':
      case 'session.reasoning.delta':
      case 'session.reasoning.ended':
        return _streamedText(
          data: data,
          created: created,
          kind: 'reasoning',
          partType: PartType.reasoning,
          buffer: _reasoningBuf,
        );

      case 'session.tool.input.started':
      case 'session.tool.input.delta':
      case 'session.tool.input.ended':
      case 'session.tool.called':
      case 'session.tool.progress':
      case 'session.tool.success':
      case 'session.tool.failed':
        return _toolEvents(data: data, created: created, type: type);

      case 'session.inbox.enqueued':
        final sessionID = data['sessionID'] as String?;
        final inboxID = data['inboxID'] as String?;
        if (sessionID == null || inboxID == null) return const [];
        final item = (data['item'] as Map?)?.cast<String, dynamic>();
        final payload = (item?['payload'] as Map?)?.cast<String, dynamic>() ??
            item ??
            const <String, dynamic>{};
        final out = <ServerEvent>[
          MessageUpdatedEvent(
            info: Message(
              id: inboxID,
              sessionID: sessionID,
              role: 'user',
              created: created,
            ),
          ),
        ];
        final text = payload['text'] as String?;
        if (text != null && text.isNotEmpty) {
          out.add(MessagePartUpdatedEvent(
            part: Part(
              id: '$inboxID-text',
              messageID: inboxID,
              sessionID: sessionID,
              type: PartType.text,
              text: text,
            ),
          ));
        }
        for (final f in (payload['files'] as List?) ?? const []) {
          if (f is! Map) continue;
          final url = _attachmentUrl(f.cast<String, dynamic>());
          if (url.isEmpty) continue;
          out.add(MessagePartUpdatedEvent(
            part: Part(
              id: '$inboxID-file',
              messageID: inboxID,
              sessionID: sessionID,
              type: PartType.file,
              mime: f['mime'] as String?,
              url: url,
              filename: f['name'] as String?,
            ),
          ));
        }
        return out;

      case 'session.inbox.cancelled':
        final sessionID = data['sessionID'] as String?;
        final inboxID = data['inboxID'] as String?;
        if (sessionID == null || inboxID == null) return const [];
        return [
          MessageRemovedEvent(sessionID: sessionID, messageID: inboxID),
        ];

      case 'session.created':
        final session = _sessionFromCreated(data);
        if (session == null) return const [];
        return [SessionCreatedEvent(session: session)];

      case 'session.renamed':
        final sessionID = data['sessionID'] as String?;
        final title = data['title'] as String?;
        if (sessionID == null) return const [];
        return [
          SessionUpdatedEvent(
            session: Session(
              id: sessionID,
              projectID: '',
              title: title ?? '',
              created: 0,
              updated: created,
            ),
          ),
        ];

      case 'session.updated':
      case 'session.moved':
      case 'session.forked':
        final sessionID = data['sessionID'] as String?;
        if (sessionID == null) return const [];
        return [
          SessionUpdatedEvent(
            session: Session(
              id: sessionID,
              projectID: data['projectID'] as String? ?? '',
              parentID: data['parentID'] as String?,
              directory: _locationDirectory(data['location']),
              updated: created,
            ),
          ),
        ];

      case 'session.deleted':
        final sessionID = data['sessionID'] as String?;
        if (sessionID == null) return const [];
        return [SessionDeletedEvent(sessionID: sessionID)];

      case 'session.archived':
      case 'session.unarchived':
        final sessionID = data['sessionID'] as String?;
        if (sessionID == null) return const [];
        return [
          SessionArchivedEvent(
            sessionID: sessionID,
            archived: type == 'session.archived',
          ),
        ];

      case 'permission.asked':
        final request = PermissionRequest.fromJson(data);
        if (request.id.isEmpty) return const [];
        return [PermissionAskedEvent(request: request)];

      case 'permission.replied':
      case 'permission.rejected':
        final requestID = data['requestID'] as String? ?? data['id'] as String?;
        final sessionID = data['sessionID'] as String?;
        if (requestID == null || sessionID == null) return const [];
        return [
          PermissionResolvedEvent(
            sessionID: sessionID,
            requestID: requestID,
            reply: (data['reply'] as String?) ?? 'once',
          ),
        ];

      case 'form.created':
        // v2 nests the form under `data.form`; some versions send it flat.
        final form = (data['form'] as Map?)?.cast<String, dynamic>() ?? data;
        final request = _questionFromForm(form);
        if (request == null) return const [];
        return [QuestionAskedEvent(request: request)];

      case 'form.replied':
      case 'form.cancelled':
        final requestID = data['requestID'] as String? ?? data['id'] as String?;
        final sessionID = data['sessionID'] as String?;
        if (requestID == null || sessionID == null) return const [];
        return [
          QuestionResolvedEvent(
            sessionID: sessionID,
            requestID: requestID,
            cancelled: type == 'form.cancelled',
          ),
        ];

      case 'filesystem.changed':
        return [
          FilesChangedEvent(
            file: data['file'] as String? ?? '',
            change: data['event'] as String? ?? 'change',
          ),
        ];

      default:
        return const [];
    }
  }

  // -- helpers ---------------------------------------------------------------

  List<ServerEvent> _streamedText({
    required Map<String, dynamic> data,
    required int created,
    required String kind,
    required PartType partType,
    required Map<String, String> buffer,
  }) {
    final sessionID = data['sessionID'] as String?;
    final messageID = data['assistantMessageID'] as String?;
    if (sessionID == null || messageID == null) return const [];
    final pre = _ensureAssistant(sessionID, messageID, created);
    final key = '$messageID|${_asInt(data['ordinal'])}';

    if (data.containsKey('delta')) {
      buffer[key] = (buffer[key] ?? '') + (data['delta'] as String? ?? '');
    } else if (data['text'] is String && data.containsKey('text')) {
      // started/ended carry the authoritative text
      buffer[key] = data['text'] as String;
    } else if (!buffer.containsKey(key)) {
      buffer[key] = '';
    }

    return [
      ...pre,
      MessagePartUpdatedEvent(
        part: Part(
          id: '$kind-$key',
          messageID: messageID,
          sessionID: sessionID,
          type: partType,
          text: buffer[key] ?? '',
        ),
      ),
    ];
  }

  List<ServerEvent> _toolEvents({
    required Map<String, dynamic> data,
    required int created,
    required String type,
  }) {
    final sessionID = data['sessionID'] as String?;
    final messageID = data['assistantMessageID'] as String?;
    final callID = data['id'] as String?;
    if (sessionID == null || messageID == null || callID == null) {
      return const [];
    }
    final pre = _ensureAssistant(sessionID, messageID, created);

    var buf = _tools[callID];
    if (buf == null) {
      buf = _ToolBuf(
        name: data['name'] as String? ?? 'tool',
      );
      _tools[callID] = buf;
    }
    final name = data['name'] as String?;
    if (name != null) buf.name = name;
    final delta = data['delta'] as String?;
    if (delta != null) buf.input += delta;
    final text = data['text'] as String?;
    if (text != null) buf.input = text;
    buf.start ??= created;

    final metadata = (data['metadata'] as Map?)?.cast<String, dynamic>();
    final title = metadata?['title'] as String?;

    ToolState state;
    final isSuccess = type == 'session.tool.success';
    final isFailed = type == 'session.tool.failed';

    if (isSuccess) {
      state = ToolState(
        status: ToolStatus.completed,
        input: _parseToolInput(buf.input),
        output: _toolOutput(data['content'] as List?),
        title: title,
        start: buf.start,
        end: created,
      );
    } else if (isFailed) {
      state = ToolState(
        status: ToolStatus.error,
        input: _parseToolInput(buf.input),
        output: _toolOutput(data['content'] as List?),
        title: title,
        errorMessage: _errorMessage(data['error']),
        start: buf.start,
        end: created,
      );
    } else {
      state = ToolState(
        status: ToolStatus.running,
        input: data['input'] ?? _parseToolInput(buf.input),
        title: title,
        start: buf.start,
      );
    }

    return [
      ...pre,
      MessagePartUpdatedEvent(
        part: Part(
          id: 'tool-$callID',
          messageID: messageID,
          sessionID: sessionID,
          type: PartType.tool,
          tool: buf.name,
          callID: callID,
          state: state,
          start: buf.start,
          end: isSuccess || isFailed ? created : null,
        ),
      ),
    ];
  }

  List<ServerEvent> _ensureAssistant(
      String sessionID, String messageID, int created) {
    if (_assistants.containsKey(messageID)) return const [];
    final message = Message(
      id: messageID,
      sessionID: sessionID,
      role: 'assistant',
      created: created,
    );
    _assistants[messageID] = message;
    return [MessageUpdatedEvent(info: message)];
  }

  Message _assistant(String messageID, String sessionID, int created) {
    return _assistants.putIfAbsent(
      messageID,
      () => Message(
        id: messageID,
        sessionID: sessionID,
        role: 'assistant',
        created: created,
      ),
    );
  }

  Session? _sessionFromCreated(Map<String, dynamic> data) {
    final id = data['sessionID'] as String? ?? data['id'] as String?;
    if (id == null) return null;
    final location = (data['location'] as Map?)?.cast<String, dynamic>();
    final model = data['model'] as Map<String, dynamic>?;
    return Session(
      id: id,
      projectID: data['projectID'] as String? ?? '',
      parentID: data['parentID'] as String?,
      agent: data['agent'] as String?,
      model: model == null ? null : ModelRef.fromJson(model),
      title: data['title'] as String? ?? '',
      directory: location?['directory'] as String? ?? '',
      created: 0,
      updated: 0,
    );
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
      questions: fields.where((f) => !f.isExternal).map(_questionFromField).toList(),
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
        multiple: false,
        custom: false,
      );
    }
    final options = f.options;
    final hasOptions = options.isNotEmpty;
    return Question(
      key: f.key,
      header: f.title ?? f.key,
      question: f.description ?? f.title ?? f.key,
      options: options,
      multiple: f.type == 'multiselect',
      custom: f.custom ||
          (f.type == 'string' || f.type == 'number' || f.type == 'integer') &&
              !hasOptions,
    );
  }

  String _locationDirectory(Object? location) {
    if (location is Map && location['directory'] is String) {
      return location['directory'] as String;
    }
    return '';
  }

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

  Object? _toolOutput(List<dynamic>? content) {
    if (content == null || content.isEmpty) return null;
    final texts = <String>[];
    for (final c in content) {
      if (c is! Map) continue;
      if (c['type'] == 'text' && c['text'] is String) {
        texts.add(c['text'] as String);
      } else if (c['type'] == 'file') {
        texts.add('[${(c['name'] as String?) ?? (c['uri'] as String?) ?? ''}]');
      }
    }
    return texts.isEmpty ? null : texts.join('\n');
  }

  Object? _parseToolInput(String input) {
    if (input.isEmpty) return null;
    try {
      return jsonDecode(input);
    } catch (_) {
      return input;
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

class _ToolBuf {
  _ToolBuf({required this.name});

  String name;
  String input = '';
  int? start;
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