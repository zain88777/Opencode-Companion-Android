import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/models.dart';
import '../../core/connections/connection_store.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_screen.dart';
import '../onboarding/add_connection_screen.dart';
import '../onboarding/connection_list_screen.dart';
import 'session_list_controller.dart';

/// Session list for the active connection.
class SessionListScreen extends StatefulWidget {
  const SessionListScreen({super.key});

  @override
  State<SessionListScreen> createState() => _SessionListScreenState();
}

class _SessionListScreenState extends State<SessionListScreen> {
  SessionListController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = context.read<ConnectionStore>();
    final client = store.clientFor(store.active!);
    if (_controller == null || _controller!.client != client) {
      _controller?.dispose();
      _controller = SessionListController(client: client)..start();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return ChangeNotifierProvider<SessionListController>.value(
      value: controller,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Sessions'),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: () => controller.load(),
            ),
            PopupMenuButton<String>(
              onSelected: (value) async {
                if (value == 'switch') {
                  await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const ConnectionListScreen(),
                  ));
                } else if (value == 'add') {
                  await Navigator.of(context).push(MaterialPageRoute(
                    fullscreenDialog: true,
                    builder: (_) => const AddConnectionScreen(),
                  ));
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'switch', child: Text('Switch server')),
                PopupMenuItem(value: 'add', child: Text('Add server')),
              ],
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _createSession(context, controller),
          icon: const Icon(Icons.add),
          label: const Text('New session'),
        ),
        body: Consumer<SessionListController>(
          builder: (context, controller, _) {
            if (controller.loading && controller.sessions.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }
            if (controller.error != null) {
              return _ErrorView(
                message: controller.error!,
                onRetry: () => controller.load(),
                onDismiss: () => controller.clearError(),
              );
            }
            if (controller.sessions.isEmpty) {
              return const _EmptySessions();
            }
            return RefreshIndicator(
              onRefresh: () => controller.load(),
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: controller.sessions.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final session = controller.sessions[index];
                  return _SessionTile(
                    session: session,
                    status: controller.statuses[session.id] ?? 'idle',
                    error: controller.errors[session.id],
                    onTap: () => _openSession(context, session),
                    onRename: () => _renameSession(context, controller, session),
                    onDelete: () => _deleteSession(context, controller, session),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _createSession(
    BuildContext context,
    SessionListController controller,
  ) async {
    final titleController = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New session'),
        content: TextField(
          controller: titleController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Title (optional)',
            hintText: 'Fix the login bug',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, titleController.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    final session = await controller.create(title: title);
    if (session == null || !context.mounted) return;
    await _openSession(context, session);
  }

  Future<void> _openSession(BuildContext context, Session session) async {
    final store = context.read<ConnectionStore>();
    final client = store.clientFor(store.active!);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChangeNotifierProvider(
        create: (_) => ChatController(
          client: client,
          sessionID: session.id,
          title: session.title,
          model: session.model,
        )..start(),
        child: ChatScreen(sessionID: session.id, initialTitle: session.title),
      ),
    ));
    if (mounted) await _controller?.load();
  }

  Future<void> _renameSession(
    BuildContext context,
    SessionListController controller,
    Session session,
  ) async {
    final textController = TextEditingController(text: session.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename session'),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Title'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, textController.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (title == null || title.trim().isEmpty) return;
    await controller.rename(session, title.trim());
  }

  Future<void> _deleteSession(
    BuildContext context,
    SessionListController controller,
    Session session,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete session?'),
        content: const Text('This permanently removes the session and its messages.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.delete(session);
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.status,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
    this.error,
  });

  final Session session;
  final String status;
  final String? error;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = session.title.isEmpty ? 'Untitled session' : session.title;
    final subtitle = [
      if (session.model != null) '${session.model!.providerID}/${session.model!.id}',
      if (session.agent != null) session.agent!,
      _relativeTime(session.updated),
    ].join(' · ');

    return ListTile(
      leading: _statusIcon(scheme),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subtitle.isNotEmpty)
            Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (error != null)
            Text(
              error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.error, fontSize: 12),
            ),
        ],
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) {
          if (value == 'rename') onRename();
          if (value == 'delete') onDelete();
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
      onTap: onTap,
    );
  }

  Widget _statusIcon(ColorScheme scheme) {
    if (status == 'busy') {
      return const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      );
    }
    if (status == 'retry') {
      return Icon(Icons.error_outline, color: scheme.error);
    }
    return Icon(Icons.chat_bubble_outline, color: scheme.onSurfaceVariant);
  }

  String _relativeTime(int epochMillis) {
    if (epochMillis == 0) return '';
    final time = DateTime.fromMillisecondsSinceEpoch(epochMillis);
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 30) return '${diff.inDays}d ago';
    return '${time.day}/${time.month}/${time.year}';
  }
}

class _EmptySessions extends StatelessWidget {
  const _EmptySessions();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined, size: 48, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text('No sessions yet', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Create one to start working',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.message,
    required this.onRetry,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 40, color: scheme.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed: onDismiss,
                  child: const Text('Dismiss'),
                ),
                const SizedBox(width: 12),
                FilledButton(onPressed: onRetry, child: const Text('Retry')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}