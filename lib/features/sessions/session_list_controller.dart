import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api/models.dart';
import '../../core/api/opencode_client.dart';
import '../../core/events/server_event.dart';

/// Lists sessions and tracks their live execution status.
class SessionListController extends ChangeNotifier {
  SessionListController({required this.client});

  final OpencodeClient client;

  List<Session> sessions = [];
  bool loading = true;
  String? error;

  /// sessionID -> idle | busy | retry
  final Map<String, String> statuses = {};

  /// sessionID -> latest error text
  final Map<String, String> errors = {};

  StreamSubscription<ServerEvent>? _subscription;

  bool get hasSessions => sessions.isNotEmpty;

  Future<void> start() async {
    await load();
    _subscription ??= client.events.listen(
      _onEvent,
      onError: (Object e) {
        // The stream reconnects itself; nothing to surface here.
      },
    );
  }

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      sessions = await client.listSessions();
      error = null;
    } catch (e) {
      error = 'Could not load sessions: $e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<Session?> create({String? title}) async {
    try {
      final session = await client.createSession(title: title);
      await load();
      return session;
    } catch (e) {
      error = 'Could not create a session: $e';
      notifyListeners();
      return null;
    }
  }

  Future<void> rename(Session session, String title) async {
    try {
      await client.renameSession(session.id, title);
      await load();
    } catch (e) {
      error = 'Rename failed: $e';
      notifyListeners();
    }
  }

  Future<void> delete(Session session) async {
    try {
      await client.deleteSession(session.id);
      sessions = sessions.where((s) => s.id != session.id).toList();
      notifyListeners();
    } catch (e) {
      error = 'Delete failed: $e';
      notifyListeners();
    }
  }

  Future<void> _onEvent(ServerEvent event) async {
    switch (event) {
      case SessionStatusEvent():
        statuses[event.sessionID] = event.status;
        notifyListeners();

      case SessionErrorEvent():
        errors[event.sessionID] = event.message;
        statuses[event.sessionID] = 'idle';
        notifyListeners();

      case SessionCreatedEvent():
        _upsert(event.session);
        notifyListeners();

      case SessionUpdatedEvent():
        _upsert(event.session);
        notifyListeners();

      case SessionDeletedEvent():
        sessions = sessions.where((s) => s.id != event.sessionID).toList();
        statuses.remove(event.sessionID);
        notifyListeners();

      case SessionArchivedEvent():
        // Archive state lives on the session record; reloading is cheaper than
        // threading another copyWith flag through the model.
        await load();
        break;

      default:
        break;
    }
  }

  void _upsert(Session session) {
    final index = sessions.indexWhere((s) => s.id == session.id);
    if (index >= 0) {
      final existing = sessions[index];
      sessions[index] = existing.copyWith(
        title: session.title.isEmpty ? existing.title : session.title,
        updated:
            session.updated != 0 ? session.updated : existing.updated,
      );
    } else {
      sessions = [session, ...sessions];
    }
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}