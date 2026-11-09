import '../api/models.dart';

/// Typed view of a raw SSE event from the OpenCode server.
///
/// The server emits a large taxonomy of events; the translator narrows them to
/// the ones the app actually renders. Anything else is dropped.
sealed class ServerEvent {
  const ServerEvent();
}

/// Execution state for a session.
class SessionStatusEvent extends ServerEvent {
  const SessionStatusEvent({
    required this.sessionID,
    required this.status,
    this.retryMessage,
    this.retryNext,
  });

  final String sessionID;

  /// idle | busy | retry
  final String status;
  final String? retryMessage;
  final int? retryNext;

  bool get isBusy => status == 'busy';
  bool get isIdle => status == 'idle';
}

class SessionErrorEvent extends ServerEvent {
  const SessionErrorEvent({required this.sessionID, required this.message});

  final String sessionID;
  final String message;
}

class MessageUpdatedEvent extends ServerEvent {
  const MessageUpdatedEvent({required this.info});

  final Message info;
}

class MessagePartUpdatedEvent extends ServerEvent {
  const MessagePartUpdatedEvent({required this.part});

  final Part part;
}

class MessageRemovedEvent extends ServerEvent {
  const MessageRemovedEvent({required this.sessionID, required this.messageID});

  final String sessionID;
  final String messageID;
}

class PermissionAskedEvent extends ServerEvent {
  const PermissionAskedEvent({required this.request});

  final PermissionRequest request;
}

class PermissionResolvedEvent extends ServerEvent {
  const PermissionResolvedEvent({
    required this.sessionID,
    required this.requestID,
    required this.reply,
  });

  final String sessionID;
  final String requestID;

  /// once | always | reject
  final String reply;
}

class QuestionAskedEvent extends ServerEvent {
  const QuestionAskedEvent({required this.request});

  final QuestionRequest request;
}

class QuestionResolvedEvent extends ServerEvent {
  const QuestionResolvedEvent({
    required this.sessionID,
    required this.requestID,
    required this.cancelled,
  });

  final String sessionID;
  final String requestID;
  final bool cancelled;
}

class SessionCreatedEvent extends ServerEvent {
  const SessionCreatedEvent({required this.session});

  final Session session;
}

class SessionUpdatedEvent extends ServerEvent {
  const SessionUpdatedEvent({required this.session});

  final Session session;
}

class SessionDeletedEvent extends ServerEvent {
  const SessionDeletedEvent({required this.sessionID});

  final String sessionID;
}

class SessionArchivedEvent extends ServerEvent {
  const SessionArchivedEvent({
    required this.sessionID,
    required this.archived,
  });

  final String sessionID;
  final bool archived;
}

class FilesChangedEvent extends ServerEvent {
  const FilesChangedEvent({required this.file, required this.change});

  final String file;

  /// add | change | unlink
  final String change;
}