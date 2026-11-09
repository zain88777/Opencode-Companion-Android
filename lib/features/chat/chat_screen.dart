import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/models.dart';
import '../../core/api/opencode_client.dart';
import '../../core/connections/connection_store.dart';
import '../diff/diff_screen.dart';
import '../files/file_browser_screen.dart';
import '../settings/model_picker_sheet.dart';
import 'chat_controller.dart';
import 'widgets/agent_picker_sheet.dart';
import 'widgets/composer.dart';
import 'widgets/message_bubble.dart';
import 'widgets/permission_prompt.dart';
import 'widgets/question_prompt.dart';
import 'widgets/session_info_sheet.dart';

/// Live chat for one session.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.sessionID, this.initialTitle});

  final String sessionID;
  final String? initialTitle;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _scrollController = ScrollController();
  ChatController? _controller;

  int _lastMessageCount = 0;
  DateTime _lastScroll = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final existing = context.read<ChatController>();
    if (_controller != existing) {
      _controller = existing;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }

  /// Android can leave an SSE socket half-open after the app is backgrounded;
  /// the watchdog drops it and reconnects, but anything that happened in
  /// between is missed. Refilling from the API on resume closes that gap.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<ChatController>().load(showSpinner: false);
    }
  }

  /// Follows new content, but no more than about four times a second: tokens
  /// stream in continuously and animating on every frame would jank a small
  /// device. A new message always scrolls immediately.
  void _autoScroll(ChatController controller) {
    final countChanged = controller.messages.length != _lastMessageCount;
    _lastMessageCount = controller.messages.length;
    final now = DateTime.now();
    if (!countChanged && now.difference(_lastScroll).inMilliseconds < 250) {
      return;
    }
    _lastScroll = now;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChatController>();
    _autoScroll(controller);

    return Scaffold(
      appBar: AppBar(
        // Tapping the title opens the session record - the quickest way to see
        // model, agent, directory and usage without leaving the chat.
        title: InkWell(
          onTap: () => _showSessionInfo(context, controller),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                controller.title?.isNotEmpty == true
                    ? controller.title!
                    : (widget.initialTitle ?? 'Session'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16),
              ),
              Text(
                [
                  if (controller.agent != null) controller.agent!,
                  if (controller.modelID != null)
                    '${controller.providerID ?? ''}/${controller.modelID!}',
                ].join(' · '),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Agent',
            icon: const Icon(Icons.smart_toy_outlined),
            onPressed: () => _pickAgent(context, controller),
          ),
          IconButton(
            tooltip: 'Model',
            icon: const Icon(Icons.tune),
            onPressed: () => _pickModel(context, controller),
          ),
          IconButton(
            tooltip: 'Files',
            icon: const Icon(Icons.folder_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const FileBrowserScreen(),
            )),
          ),
          IconButton(
            tooltip: 'Changes',
            icon: const Icon(Icons.difference),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DiffScreen(sessionID: widget.sessionID),
            )),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'info') _showSessionInfo(context, controller);
              if (value == 'refresh') controller.load();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'info', child: Text('Session info')),
              PopupMenuItem(value: 'refresh', child: Text('Reload messages')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (controller.errorMessage != null)
            _ErrorBanner(
              message: controller.errorMessage!,
              onDismiss: controller.clearError,
            ),
          if (controller.isBusy) const _StreamingIndicator(),
          Expanded(
            child: controller.loading
                ? const Center(child: CircularProgressIndicator())
                : controller.messages.isEmpty
                    ? const _EmptyChat()
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.only(top: 8, bottom: 8),
                        itemCount: controller.messages.length,
                        itemBuilder: (context, index) {
                          return _buildItem(context, controller, index);
                        },
                      ),
          ),
          if (controller.pendingAttachments.isNotEmpty)
            _AttachmentStrip(
              attachments: controller.pendingAttachments,
              onRemove: controller.removeAttachment,
            ),
          for (final request in controller.questions)
            QuestionPrompt(
              request: request,
              busy: controller.sending,
              onSubmit: (answers) =>
                  controller.replyQuestion(request, answers),
              onReject: () => controller.rejectQuestion(request),
            ),
          for (final request in controller.permissions)
            PermissionPrompt(
              request: request,
              busy: controller.sending,
              onReply: (decision) =>
                  controller.replyPermission(request, decision),
            ),
          Composer(
            onSend: controller.send,
            busy: controller.isBusy,
            onInterrupt: controller.interrupt,
            onAttach: controller.attachImage,
          ),
        ],
      ),
    );
  }

  /// Builds a message plus a time divider above it when the gap from the
  /// previous message is long enough to be meaningful.
  Widget _buildItem(
    BuildContext context,
    ChatController controller,
    int index,
  ) {
    final message = controller.messages[index];
    final scheme = Theme.of(context).colorScheme;
    final previous =
        index == 0 ? null : controller.messages[index - 1];
    final showDivider = previous == null ||
        message.created - previous.created > const Duration(minutes: 5).inMilliseconds;

    final isLatestAssistant =
        index == controller.messages.lastIndexWhere((m) => m.isAssistant);

    return Column(
      children: [
        if (showDivider)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              _formatTime(message.created),
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        MessageBubble(
          message: message,
          parts: controller.partsFor(message.id),
          isLatestAssistant: isLatestAssistant,
        ),
      ],
    );
  }

  String _formatTime(int epochMillis) {
    if (epochMillis == 0) return '';
    final time = DateTime.fromMillisecondsSinceEpoch(epochMillis);
    final now = DateTime.now();
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    final sameDay = time.year == now.year &&
        time.month == now.month &&
        time.day == now.day;
    if (sameDay) return '$hh:$mm';
    return '${time.day}/${time.month} $hh:$mm';
  }

  Future<void> _showSessionInfo(
    BuildContext context,
    ChatController controller,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SessionInfoSheet(
        session: controller.session,
        usage: controller.usageSummary,
      ),
    );
  }

  Future<void> _pickAgent(
    BuildContext context,
    ChatController controller,
  ) async {
    final store = context.read<ConnectionStore>();
    final connection = store.active;
    if (connection == null) return;
    final client = store.clientFor(connection);
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AgentPickerSheet(
        client: client,
        currentAgent: controller.agent,
      ),
    );
    if (selected == null) return;
    await controller.setAgent(selected);
  }

  Future<void> _pickModel(
    BuildContext context,
    ChatController controller,
  ) async {
    final store = context.read<ConnectionStore>();
    final connection = store.active;
    if (connection == null) return;
    final client = store.clientFor(connection);
    final selection = await showModalBottomSheet<ModelRef>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ModelPickerSheet(client: client),
    );
    if (selection == null) return;
    await client.selectModel(controller.sessionID, selection);
    controller.applyModelSelection(selection);
  }
}

/// Animated "the agent is working" indicator.
class _StreamingIndicator extends StatefulWidget {
  const _StreamingIndicator();

  @override
  State<_StreamingIndicator> createState() => _StreamingIndicatorState();
}

class _StreamingIndicatorState extends State<_StreamingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
          ),
          const SizedBox(width: 8),
          Text(
            'Working...',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Staged attachments, shown above the composer until sent.
class _AttachmentStrip extends StatelessWidget {
  const _AttachmentStrip({
    required this.attachments,
    required this.onRemove,
  });

  final List<PromptFile> attachments;
  final void Function(int index) onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var i = 0; i < attachments.length; i++)
            InputChip(
              avatar: Icon(
                attachments[i].mime?.startsWith('image/') == true
                    ? Icons.image_outlined
                    : Icons.attach_file,
                size: 18,
                color: scheme.primary,
              ),
              label: Text(
                attachments[i].name ?? 'attachment',
                overflow: TextOverflow.ellipsis,
              ),
              onDeleted: () => onRemove(i),
            ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 18, color: scheme.onErrorContainer),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined, size: 48, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text('No messages yet',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Ask the agent to do something',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}