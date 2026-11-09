import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/models.dart';
import '../../core/api/opencode_client.dart';
import '../../core/chat/message_merge.dart';
import '../../core/events/server_event.dart';

/// Owns the live state of one session's chat: messages, streaming parts,
/// execution status, and pending approvals.
///
/// The optimistic-send rule matters: a sent message is added immediately with a
/// `temp-` id and replaced by the real server message when it arrives. See
/// [mergeIncomingMessage] for why the replacement targets the oldest matching
/// placeholder rather than all of them.
class ChatController extends ChangeNotifier {
  ChatController({
    required this.client,
    required this.sessionID,
    this.title,
    ModelRef? model,
  }) : modelID = model?.id,
       providerID = model?.providerID,
       variant = model?.variant;

  final OpencodeClient client;
  final String sessionID;
  String? title;

  List<Message> messages = [];
  final Map<String, List<Part>> _parts = {};

  String status = 'idle';
  String? errorMessage;
  String? retryMessage;
  int? retryNext;

  final List<PermissionRequest> permissions = [];
  final List<QuestionRequest> questions = [];

  /// Files staged in the composer, sent with the next prompt.
  final List<PromptFile> pendingAttachments = [];

  /// Server-side record for this session, used by the info sheet.
  Session? session;

  bool loading = true;
  bool sending = false;
  String? modelID;
  String? providerID;
  String? variant;
  String? agent;

  StreamSubscription<ServerEvent>? _subscription;

  bool get isBusy => status == 'busy';

  /// Aggregate usage across the visible messages, for the info sheet.
  int get totalInputTokens =>
      messages.fold(0, (sum, m) => sum + (m.tokens?.input ?? 0));
  int get totalOutputTokens =>
      messages.fold(0, (sum, m) => sum + (m.tokens?.output ?? 0));
  int get totalReasoningTokens =>
      messages.fold(0, (sum, m) => sum + (m.tokens?.reasoning ?? 0));
  double get totalCost => messages.fold(0.0, (sum, m) => sum + (m.cost ?? 0));

  String get usageSummary {
    if (messages.isEmpty) return 'No usage yet';
    final parts = <String>[
      if (totalInputTokens > 0) '${_compact(totalInputTokens)} in',
      if (totalOutputTokens > 0) '${_compact(totalOutputTokens)} out',
      if (totalReasoningTokens > 0) '${_compact(totalReasoningTokens)} reasoning',
    ];
    if (parts.isEmpty) return 'No token usage';
    return parts.join(' · ');
  }

  static String _compact(int value) {
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
    return '$value';
  }

  List<Part> partsFor(String messageID) => _parts[messageID] ?? const [];

  int get pendingApprovalCount => permissions.length + questions.length;

  /// Loads history and subscribes to live events.
  Future<void> start() async {
    await load();
    _subscription ??= client.events.listen(
      _onEvent,
      onError: (Object e) {
        // The stream reconnects itself; surface nothing transient.
      },
    );
  }

  /// Loads history. [showSpinner] is false for silent refreshes (app resume),
  /// where a spinner would be visually jarring.
  Future<void> load({bool showSpinner = true}) async {
    if (showSpinner) {
      loading = true;
      notifyListeners();
    }
    try {
      // Fire both: history for the chat, the session record for the info sheet.
      final results = await Future.wait([
        client.messages(sessionID),
        client.getSession(sessionID).catchError((_) => null),
      ]);
      final history = results[0] as List<MessageWithParts>;
      session = results[1] as Session?;
      messages
        ..clear()
        ..addAll(history.map((m) => m.info));
      _parts
        ..clear()
        ..addEntries(history.map((m) => MapEntry(m.info.id, m.parts)));
      if (session != null) {
        title = session!.title.isEmpty ? title : session!.title;
        modelID = session!.model?.id ?? modelID;
        providerID = session!.model?.providerID ?? providerID;
        agent = session!.agent ?? agent;
      }
      if (title == null && messages.isNotEmpty) {
        final firstUser = messages.firstWhere(
          (m) => !m.isAssistant,
          orElse: () => messages.first,
        );
        final text = partsFor(firstUser.id)
            .where((p) => p.type == PartType.text)
            .map((p) => p.text ?? '')
            .join();
        if (text.isNotEmpty) title = text;
      }
    } catch (e) {
      errorMessage = 'Could not load this session: $e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void _onEvent(ServerEvent event) {
    switch (event) {
      case SessionStatusEvent():
        if (event.sessionID != sessionID) return;
        status = event.status;
        retryMessage = event.retryMessage;
        retryNext = event.retryNext;
        if (event.isIdle) sending = false;
        notifyListeners();

      case SessionErrorEvent():
        if (event.sessionID != sessionID) return;
        errorMessage = event.message;
        status = 'idle';
        sending = false;
        notifyListeners();

      case MessageUpdatedEvent():
        if (event.info.sessionID.isNotEmpty &&
            event.info.sessionID != sessionID) {
          return;
        }
        messages = mergeIncomingMessage(messages, event.info);
        _parts.putIfAbsent(event.info.id, () => const []);
        modelID = event.info.modelID ?? modelID;
        providerID = event.info.providerID ?? providerID;
        agent = event.info.agent ?? agent;
        notifyListeners();

      case MessagePartUpdatedEvent():
        if (event.part.sessionID != null &&
            event.part.sessionID!.isNotEmpty &&
            event.part.sessionID != sessionID) {
          return;
        }
        final merged = mergeIncomingPart(
          _parts[event.part.messageID] ?? const [],
          event.part,
        );
        _parts[event.part.messageID] = merged;
        notifyListeners();

      case MessageRemovedEvent():
        if (event.sessionID != sessionID) return;
        messages = messages.where((m) => m.id != event.messageID).toList();
        _parts.remove(event.messageID);
        notifyListeners();

      case PermissionAskedEvent():
        if (event.request.sessionID != sessionID) return;
        if (permissions.any((p) => p.id == event.request.id)) return;
        permissions.add(event.request);
        notifyListeners();

      case PermissionResolvedEvent():
        if (event.sessionID != sessionID) return;
        permissions.removeWhere((p) => p.id == event.requestID);
        notifyListeners();

      case QuestionAskedEvent():
        if (event.request.sessionID != sessionID) return;
        if (questions.any((q) => q.id == event.request.id)) return;
        questions.add(event.request);
        notifyListeners();

      case QuestionResolvedEvent():
        if (event.sessionID != sessionID) return;
        questions.removeWhere((q) => q.id == event.requestID);
        notifyListeners();

      case SessionCreatedEvent():
      case SessionUpdatedEvent():
      case SessionDeletedEvent():
      case SessionArchivedEvent():
      case FilesChangedEvent():
        break;
    }
  }

  /// Sends a prompt. The message appears immediately; the server's own copy
  /// replaces it via the event stream.
  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || sending) return;

    final tempId = 'temp-${DateTime.now().millisecondsSinceEpoch}';
    final optimistic = Message(
      id: tempId,
      sessionID: sessionID,
      role: 'user',
      created: DateTime.now().millisecondsSinceEpoch,
    );
    messages = [...messages, optimistic];
    _parts[tempId] = [
      Part(
        id: '$tempId-text',
        messageID: tempId,
        sessionID: sessionID,
        type: PartType.text,
        text: trimmed,
      ),
    ];
    sending = true;
    errorMessage = null;
    notifyListeners();

    try {
      await client.prompt(
        sessionID,
        text: trimmed,
        files: pendingAttachments,
        model: modelID != null && providerID != null
            ? ModelRef(
                id: modelID!,
                providerID: providerID!,
                variant: variant,
              )
            : null,
        agent: agent,
      );
      pendingAttachments.clear();
      notifyListeners();
    } catch (e) {
      errorMessage = 'Send failed: $e';
      messages = messages.where((m) => m.id != tempId).toList();
      _parts.remove(tempId);
      sending = false;
      notifyListeners();
    }
  }

  /// Stages an image for the next prompt.
  ///
  /// The server runs on another machine, so the bytes travel inline: a data
  /// URL is converted server-side into an `inline` attachment.
  Future<void> attachImage() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 80,
    );
    if (picked == null) return;
    final bytes = await File(picked.path).readAsBytes();
    final mime = picked.mimeType ??
        (picked.path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg');
    pendingAttachments.add(PromptFile(
      uri: 'data:$mime;base64,${base64Encode(bytes)}',
      name: picked.name,
      mime: mime,
    ));
    notifyListeners();
  }

  void removeAttachment(int index) {
    if (index < 0 || index >= pendingAttachments.length) return;
    pendingAttachments.removeAt(index);
    notifyListeners();
  }

  void clearAttachments() {
    if (pendingAttachments.isEmpty) return;
    pendingAttachments.clear();
    notifyListeners();
  }

  /// Switches the session agent - OpenCode's `plan` agent is read-only, which
  /// is what "plan mode" means; `build` restores full tool access.
  Future<void> setAgent(String nextAgent) async {
    if (nextAgent == agent) return;
    await client.selectAgent(sessionID, nextAgent);
    agent = nextAgent;
    notifyListeners();
  }

  /// Applies a model chosen in the picker and notifies listeners, so the app
  /// bar reflects the new selection immediately.
  void applyModelSelection(ModelRef model) {
    modelID = model.id;
    providerID = model.providerID;
    variant = model.variant;
    notifyListeners();
  }

  Future<void> interrupt() async {
    try {
      await client.interrupt(sessionID);
    } catch (e) {
      errorMessage = 'Interrupt failed: $e';
      notifyListeners();
    }
  }

  Future<void> replyPermission(PermissionRequest request, String decision) async {
    try {
      await client.replyPermission(sessionID, request.id, decision);
      permissions.removeWhere((p) => p.id == request.id);
      notifyListeners();
    } catch (e) {
      errorMessage = 'Approval failed: $e';
      notifyListeners();
    }
  }

  Future<void> replyQuestion(
    QuestionRequest request,
    Map<String, dynamic> answers,
  ) async {
    try {
      await client.replyQuestion(sessionID, request.id, answers);
      questions.removeWhere((q) => q.id == request.id);
      notifyListeners();
    } catch (e) {
      errorMessage = 'Answer failed: $e';
      notifyListeners();
    }
  }

  Future<void> rejectQuestion(QuestionRequest request) async {
    try {
      await client.rejectQuestion(sessionID, request.id);
      questions.removeWhere((q) => q.id == request.id);
      notifyListeners();
    } catch (e) {
      errorMessage = 'Reject failed: $e';
      notifyListeners();
    }
  }

  void clearError() {
    errorMessage = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}