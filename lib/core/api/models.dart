/// Data models for the OpenCode HTTP + SSE API.
///
/// Wire shapes follow the OpenCode v2 API (verified live against v2.2.6).
/// The v1 fallback client reuses the same internal shapes, so the rest of the
/// app never needs to know which generation it is talking to.
library;

// ---------------------------------------------------------------------------
// Health / server identity
// ---------------------------------------------------------------------------

class HealthInfo {
  const HealthInfo({required this.healthy, required this.version});

  final bool healthy;
  final String version;

  factory HealthInfo.fromJson(Map<String, dynamic> json) => HealthInfo(
        healthy: json['healthy'] as bool? ?? true,
        version: json['version'] as String? ?? '',
      );
}

/// Which generation of the server API a connection speaks.
enum ServerApi { v1, v2 }

class ServerIdentity {
  const ServerIdentity({required this.api, this.version});

  final ServerApi api;
  final String? version;
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

class TokenUsage {
  const TokenUsage({
    this.input = 0,
    this.output = 0,
    this.reasoning = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
  });

  final int input;
  final int output;
  final int reasoning;
  final int cacheRead;
  final int cacheWrite;

  factory TokenUsage.fromJson(Map<String, dynamic>? json) => TokenUsage(
        input: _asInt(json?['input']),
        output: _asInt(json?['output']),
        reasoning: _asInt(json?['reasoning']),
        cacheRead: _asInt(json?['cache']?['read']),
        cacheWrite: _asInt(json?['cache']?['write']),
      );

  Map<String, dynamic> toJson() => {
        'input': input,
        'output': output,
        'reasoning': reasoning,
        'cache': {'read': cacheRead, 'write': cacheWrite},
      };
}

class RevertBoundary {
  const RevertBoundary({required this.messageID, this.partID});

  final String messageID;
  final String? partID;
}

class PermissionRule {
  const PermissionRule({
    required this.action,
    required this.resource,
    required this.effect,
  });

  final String action;
  final String resource;

  /// allow | deny | ask
  final String effect;
}

class Session {
  const Session({
    required this.id,
    required this.projectID,
    this.parentID,
    this.agent,
    this.model,
    this.title = '',
    this.directory = '',
    this.created = 0,
    this.updated = 0,
    this.archived,
    this.idle,
    this.cost = 0,
    this.tokens = const TokenUsage(),
    this.outcome,
    this.revert,
    this.permissions = const [],
  });

  final String id;
  final String projectID;
  final String? parentID;
  final String? agent;
  final ModelRef? model;
  final String title;
  final String directory;
  final int created;
  final int updated;
  final int? archived;
  final int? idle;
  final double cost;
  final TokenUsage tokens;

  /// succeeded | failed | interrupted
  final String? outcome;
  final RevertBoundary? revert;
  final List<PermissionRule> permissions;

  bool get isArchived => archived != null;

  Session copyWith({
    String? title,
    int? updated,
    int? idle,
    String? outcome,
    double? cost,
    TokenUsage? tokens,
    ModelRef? model,
    String? agent,
    RevertBoundary? revert,
    bool clearRevert = false,
  }) =>
      Session(
        id: id,
        projectID: projectID,
        parentID: parentID,
        agent: agent ?? this.agent,
        model: model ?? this.model,
        title: title ?? this.title,
        directory: directory,
        created: created,
        updated: updated ?? this.updated,
        archived: archived,
        idle: idle ?? this.idle,
        cost: cost ?? this.cost,
        tokens: tokens ?? this.tokens,
        outcome: outcome ?? this.outcome,
        revert: clearRevert ? null : (revert ?? this.revert),
        permissions: permissions,
      );

  factory Session.fromJson(Map<String, dynamic> json) {
    final time = (json['time'] as Map<String, dynamic>?) ?? const {};
    final loc = (json['location'] as Map<String, dynamic>?) ?? const {};
    final model = json['model'] as Map<String, dynamic>?;
    final revert = json['revert'] as Map<String, dynamic>?;
    return Session(
      id: json['id'] as String,
      projectID: json['projectID'] as String? ?? '',
      parentID: json['parentID'] as String?,
      agent: json['agent'] as String?,
      model: model == null ? null : ModelRef.fromJson(model),
      title: json['title'] as String? ?? '',
      directory: loc['directory'] as String? ?? '',
      created: _asInt(time['created']),
      updated: _asInt(time['updated']),
      archived: _asInt(time['archived']),
      idle: _asInt(time['idle']),
      cost: _asDouble(json['cost']),
      tokens: TokenUsage.fromJson(json['tokens'] as Map<String, dynamic>?),
      outcome: json['outcome'] as String?,
      revert: revert == null
          ? null
          : RevertBoundary(
              messageID: revert['messageID'] as String,
              partID: revert['partID'] as String?,
            ),
      permissions: ((json['permissions'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => PermissionRule(
                action: e['action'] as String? ?? '',
                resource: e['resource'] as String? ?? '',
                effect: e['effect'] as String? ?? 'ask',
              ))
          .toList(),
    );
  }
}

// ---------------------------------------------------------------------------
// Messages and parts
// ---------------------------------------------------------------------------

enum PartType { text, reasoning, tool, file }

enum ToolStatus { pending, running, completed, error }

class ToolState {
  const ToolState({
    required this.status,
    this.input,
    this.output,
    this.title,
    this.errorMessage,
    this.start,
    this.end,
  });

  final ToolStatus status;
  final Object? input;
  final Object? output;
  final String? title;
  final String? errorMessage;
  final int? start;
  final int? end;

  ToolState copyWith({
    ToolStatus? status,
    Object? input,
    bool clearInput = false,
    Object? output,
    bool clearOutput = false,
    String? title,
    bool clearTitle = false,
    String? errorMessage,
    bool clearError = false,
    int? start,
    int? end,
  }) =>
      ToolState(
        status: status ?? this.status,
        input: clearInput ? null : (input ?? this.input),
        output: clearOutput ? null : (output ?? this.output),
        title: clearTitle ? null : (title ?? this.title),
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        start: start ?? this.start,
        end: end ?? this.end,
      );

  factory ToolState.fromJson(Map<String, dynamic> json) {
    final error = json['error'];
    final content = json['content'] as List?;
    final metadata = (json['metadata'] as Map?)?.cast<String, dynamic>();
    return ToolState(
      status: _toolStatus(json['status'] as String?),
      input: json['input'],
      output: _toolOutput(content),
      title: metadata?['title'] as String?,
      errorMessage:
          error == null ? null : (error['message'] as String? ?? error.toString()),
      start: _asInt(json['time']?['start']),
      end: _asInt(json['time']?['end']),
    );
  }

  Map<String, dynamic> toJson() => {
        'status': status.name,
        'input': input,
        'output': output,
        'title': title,
        'time': {'start': start, 'end': end},
      };
}

class Part {
  const Part({
    required this.id,
    required this.messageID,
    this.sessionID,
    required this.type,
    this.text,
    this.tool,
    this.callID,
    this.state,
    this.start,
    this.end,
    this.mime,
    this.url,
    this.filename,
  });

  final String id;
  final String messageID;
  final String? sessionID;
  final PartType type;
  final String? text;
  final String? tool;
  final String? callID;
  final ToolState? state;
  final int? start;
  final int? end;
  final String? mime;
  final String? url;
  final String? filename;

  Part copyWith({
    String? id,
    String? text,
    ToolState? state,
    int? start,
    int? end,
    String? url,
    String? filename,
    String? mime,
  }) =>
      Part(
        id: id ?? this.id,
        messageID: messageID,
        sessionID: sessionID,
        type: type,
        text: text ?? this.text,
        tool: tool,
        callID: callID,
        state: state ?? this.state,
        start: start ?? this.start,
        end: end ?? this.end,
        mime: mime ?? this.mime,
        url: url ?? this.url,
        filename: filename ?? this.filename,
      );

  factory Part.fromJson(Map<String, dynamic> json) => Part(
        id: json['id'] as String,
        messageID: json['messageID'] as String? ?? '',
        sessionID: json['sessionID'] as String?,
        type: _partType(json['type'] as String?),
        text: json['text'] as String?,
        tool: json['tool'] as String?,
        callID: json['callID'] as String?,
        state: json['state'] == null
            ? null
            : ToolState.fromJson(json['state'] as Map<String, dynamic>),
        start: _asInt(json['time']?['start'] ?? json['start']),
        end: _asInt(json['time']?['end'] ?? json['end']),
        mime: json['mime'] as String?,
        url: json['url'] as String?,
        filename: json['filename'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'messageID': messageID,
        'sessionID': sessionID,
        'type': type.name,
        'text': text,
        'tool': tool,
        'callID': callID,
        'state': state?.toJson(),
        'time': {'start': start, 'end': end},
        'mime': mime,
        'url': url,
        'filename': filename,
      };
}

class Message {
  const Message({
    required this.id,
    required this.sessionID,
    required this.role,
    this.created = 0,
    this.completed,
    this.agent,
    this.providerID,
    this.modelID,
    this.cost,
    this.tokens,
    this.error,
    this.finish,
  });

  final String id;
  final String sessionID;

  /// user | assistant
  final String role;
  final int created;
  final int? completed;
  final String? agent;
  final String? providerID;
  final String? modelID;
  final double? cost;
  final TokenUsage? tokens;
  final String? error;

  /// stop | length | tool-calls | content-filter | error | unknown
  final String? finish;

  bool get isAssistant => role == 'assistant';
  bool get isPending => id.startsWith('temp-');

  Message copyWith({
    int? completed,
    String? agent,
    String? providerID,
    String? modelID,
    double? cost,
    bool clearCost = false,
    TokenUsage? tokens,
    bool clearTokens = false,
    String? error,
    bool clearError = false,
    String? finish,
    bool clearFinish = false,
  }) =>
      Message(
        id: id,
        sessionID: sessionID,
        role: role,
        created: created,
        completed: completed ?? this.completed,
        agent: agent ?? this.agent,
        providerID: providerID ?? this.providerID,
        modelID: modelID ?? this.modelID,
        cost: clearCost ? null : (cost ?? this.cost),
        tokens: clearTokens ? null : (tokens ?? this.tokens),
        error: clearError ? null : (error ?? this.error),
        finish: clearFinish ? null : (finish ?? this.finish),
      );

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'] as String,
        sessionID: json['sessionID'] as String? ?? '',
        role: json['role'] as String? ?? 'assistant',
        created: _asInt(json['time']?['created']),
        completed: _asInt(json['time']?['completed']),
        agent: json['agent'] as String?,
        providerID: json['providerID'] as String?,
        modelID: json['modelID'] as String?,
        cost: _asDouble(json['cost']),
        tokens: json['tokens'] == null
            ? null
            : TokenUsage.fromJson(json['tokens'] as Map<String, dynamic>),
        error: json['error'] == null ? null : _errorMessage(json['error']),
        finish: json['finish'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'sessionID': sessionID,
        'role': role,
        'time': {'created': created, 'completed': completed},
        'agent': agent,
        'providerID': providerID,
        'modelID': modelID,
        'cost': cost,
        'tokens': tokens?.toJson(),
        'error': error,
        'finish': finish,
      };
}

class MessageWithParts {
  const MessageWithParts({required this.info, required this.parts});

  final Message info;
  final List<Part> parts;
}

// ---------------------------------------------------------------------------
// Agents / commands / projects
// ---------------------------------------------------------------------------

class AgentInfo {
  const AgentInfo({
    required this.id,
    required this.name,
    required this.mode,
    this.description,
    this.hidden = false,
    this.color,
    this.model,
    this.steps,
  });

  final String id;
  final String name;

  /// subagent | primary | all
  final String mode;
  final String? description;
  final bool hidden;
  final String? color;
  final ModelRef? model;
  final int? steps;
}

class CommandInfo {
  const CommandInfo({required this.name, this.description});

  final String name;
  final String? description;
}

class Project {
  const Project({required this.id, required this.canonical});

  final String id;
  final String canonical;
}

// ---------------------------------------------------------------------------
// Filesystem
// ---------------------------------------------------------------------------

class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.absolute,
    required this.isDirectory,
    this.ignored = false,
  });

  final String name;
  final String path;
  final String absolute;
  final bool isDirectory;
  final bool ignored;
}

class FileContent {
  const FileContent({required this.path, required this.content});

  final String path;
  final String content;
}

class LocationInfo {
  const LocationInfo({
    required this.directory,
    this.projectID,
    this.projectDirectory,
    this.projectCanonical,
  });

  final String directory;
  final String? projectID;
  final String? projectDirectory;
  final String? projectCanonical;
}

// ---------------------------------------------------------------------------
// Permissions and forms
// ---------------------------------------------------------------------------

class PermissionRequest {
  const PermissionRequest({
    required this.id,
    required this.sessionID,
    required this.action,
    required this.resources,
    this.metadata = const {},
    this.sourceType,
    this.sourceMessageID,
    this.sourceCallID,
    this.message,
  });

  final String id;
  final String sessionID;

  /// The tool asking for permission, e.g. "bash", "edit".
  final String action;
  final List<String> resources;
  final Map<String, dynamic> metadata;
  final String? sourceType;
  final String? sourceMessageID;
  final String? sourceCallID;
  final String? message;

  factory PermissionRequest.fromJson(Map<String, dynamic> json) => PermissionRequest(
        id: json['id'] as String,
        sessionID: json['sessionID'] as String? ?? '',
        action: json['action'] as String? ?? '',
        resources: ((json['resources'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        metadata: (json['metadata'] as Map?)?.cast<String, dynamic>() ?? const {},
        sourceType: json['source']?['type'] as String?,
        sourceMessageID: json['source']?['messageID'] as String?,
        sourceCallID: json['source']?['id'] as String?,
        message: json['message'] as String?,
      );
}

class FormOption {
  const FormOption({required this.value, required this.label, this.description});

  final String value;
  final String label;
  final String? description;
}

class FormField {
  const FormField({
    required this.key,
    required this.type,
    this.title,
    this.description,
    this.options = const [],
    this.custom = false,
    this.url,
  });

  final String key;

  /// string | number | integer | boolean | multiselect | external
  final String type;
  final String? title;
  final String? description;
  final List<FormOption> options;
  final bool custom;
  final String? url;

  bool get isExternal => type == 'external';

  factory FormField.fromJson(Map<String, dynamic> json) => FormField(
        key: json['key'] as String? ?? '',
        type: json['type'] as String? ?? 'string',
        title: json['title'] as String?,
        description: json['description'] as String?,
        options: ((json['options'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => FormOption(
                  value: e['value'] as String? ?? '',
                  label: e['label'] as String? ?? e['value'] as String? ?? '',
                  description: e['description'] as String?,
                ))
            .toList(),
        custom: json['custom'] as bool? ?? false,
        url: json['url'] as String?,
      );
}

class Question {
  const Question({
    required this.key,
    required this.header,
    required this.question,
    this.options = const [],
    this.multiple = false,
    this.custom = false,
  });

  /// Key of the [FormField] this question came from; used to build the answer.
  final String key;
  final String header;
  final String question;
  final List<FormOption> options;
  final bool multiple;
  final bool custom;
}

class QuestionRequest {
  const QuestionRequest({
    required this.id,
    required this.sessionID,
    required this.title,
    required this.fields,
    required this.questions,
  });

  final String id;
  final String sessionID;
  final String title;
  final List<FormField> fields;
  final List<Question> questions;
}

// ---------------------------------------------------------------------------
// Providers and models
// ---------------------------------------------------------------------------

class ModelRef {
  const ModelRef({required this.id, required this.providerID, this.variant});

  final String id;
  final String providerID;
  final String? variant;

  factory ModelRef.fromJson(Map<String, dynamic> json) => ModelRef(
        id: json['id'] as String? ?? json['modelID'] as String? ?? '',
        providerID: json['providerID'] as String? ?? '',
        variant: json['variant'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'providerID': providerID,
        if (variant != null) 'variant': variant,
      };

  @override
  bool operator ==(Object other) =>
      other is ModelRef &&
      other.id == id &&
      other.providerID == providerID &&
      other.variant == variant;

  @override
  int get hashCode => Object.hash(id, providerID, variant);
}

class ModelVariant {
  const ModelVariant({required this.id, this.reasoningEnabled, this.reasoningEffort});

  final String id;
  final bool? reasoningEnabled;
  final String? reasoningEffort;
}

class ModelInfo {
  const ModelInfo({
    required this.providerID,
    required this.modelID,
    required this.name,
    this.hasTools = false,
    this.contextWindow = 0,
    this.maxOutput = 0,
    this.status,
    this.enabled = true,
    this.variants = const [],
  });

  final String providerID;
  final String modelID;
  final String name;
  final bool hasTools;
  final int contextWindow;
  final int maxOutput;
  final String? status;
  final bool enabled;
  final List<ModelVariant> variants;
}

class ProviderInfo {
  const ProviderInfo({required this.id, required this.name, this.activation});

  final String id;
  final String name;

  /// auto | enabled | disabled
  final String? activation;
}

class ProviderCatalog {
  const ProviderCatalog({
    required this.providers,
    required this.models,
    this.defaultModel,
  });

  final List<ProviderInfo> providers;
  final List<ModelInfo> models;
  final ModelInfo? defaultModel;
}

// ---------------------------------------------------------------------------
// Diffs
// ---------------------------------------------------------------------------

class DiffEntry {
  const DiffEntry({
    required this.file,
    required this.patch,
    required this.status,
    this.additions = 0,
    this.deletions = 0,
    this.more = false,
  });

  final String file;

  /// Unified diff text, as returned by the server.
  final String patch;

  /// added | deleted | modified
  final String status;
  final int additions;
  final int deletions;
  final bool more;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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

ToolStatus _toolStatus(String? raw) {
  switch (raw) {
    case 'streaming':
    case 'running':
      return ToolStatus.running;
    case 'completed':
      return ToolStatus.completed;
    case 'error':
      return ToolStatus.error;
    case 'pending':
    default:
      return ToolStatus.pending;
  }
}

Object? _toolOutput(List<dynamic>? content) {
  if (content == null || content.isEmpty) return null;
  final texts = <String>[];
  for (final c in content) {
    if (c is! Map) continue;
    if (c['type'] == 'text' && c['text'] is String) {
      texts.add(c['text'] as String);
    } else if (c['type'] == 'file') {
      final name = (c['name'] as String?) ?? (c['uri'] as String?) ?? '';
      texts.add('[$name]');
    }
  }
  return texts.isEmpty ? null : texts.join('\n');
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