import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../../core/api/models.dart';
import 'tool_call_card.dart';

/// Renders one chat message: reasoning, text, tool calls, and attachments.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.parts,
    required this.isLatestAssistant,
    this.compact = false,
  });

  final Message message;
  final List<Part> parts;
  final bool isLatestAssistant;

  /// Small-screen mode: tighter padding and no reasoning text by default.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = !message.isAssistant;

    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(left: 48, top: 6, bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: _userBody(context),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 12,
        vertical: 4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final part in parts) _part(context, part),
          if (message.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                message.error!,
                style: TextStyle(color: scheme.error, fontSize: 13),
              ),
            ),
          if (_hasUsage(message)) _usageLine(context, message),
          if (message.isPending && isLatestAssistant)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  bool _hasUsage(Message message) {
    final tokens = message.tokens;
    return (tokens != null &&
            (tokens.input > 0 || tokens.output > 0 || tokens.reasoning > 0)) ||
        (message.cost != null && message.cost! > 0);
  }

  Widget _usageLine(BuildContext context, Message message) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = message.tokens;
    final parts = <String>[
      if (tokens != null && tokens.input > 0) '${_compact(tokens.input)} in',
      if (tokens != null && tokens.output > 0) '${_compact(tokens.output)} out',
      if (tokens != null && tokens.reasoning > 0)
        '${_compact(tokens.reasoning)} reasoning',
      if (message.cost != null && message.cost! > 0)
        '\$${message.cost!.toStringAsFixed(4)}',
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        parts.join('  ·  '),
        style: TextStyle(
          fontSize: 11,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  static String _compact(int value) {
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
    return '$value';
  }

  Widget _userBody(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textParts = parts.where((p) => p.type == PartType.text).toList();
    if (textParts.isEmpty) {
      return Text(
        '(empty message)',
        style: TextStyle(color: scheme.onPrimaryContainer),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final part in textParts)
          SelectableText(
            part.text ?? '',
            style: TextStyle(
              color: scheme.onPrimaryContainer,
              fontSize: 15,
              height: 1.35,
            ),
          ),
        for (final part in parts.where((p) => p.type == PartType.file))
          _fileChip(context, part),
      ],
    );
  }

  Widget _part(BuildContext context, Part part) {
    switch (part.type) {
      case PartType.reasoning:
        return ReasoningBlock(text: part.text ?? '', compact: compact);
      case PartType.text:
        return _markdown(context, part.text ?? '');
      case PartType.tool:
        return ToolCallCard(part: part);
      case PartType.file:
        return _fileChip(context, part);
    }
  }

  Widget _markdown(BuildContext context, String text) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return MarkdownBody(
      data: text,
      selectable: true,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: TextStyle(fontSize: 15, height: 1.4, color: scheme.onSurface),
        code: TextStyle(
          fontSize: 13,
          fontFamily: 'monospace',
          backgroundColor: scheme.surfaceContainerHighest,
          color: scheme.onSurface,
        ),
        codeblockDecoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: scheme.primary, width: 3),
          ),
        ),
      ),
    );
  }

  Widget _fileChip(BuildContext context, Part part) {
    final scheme = Theme.of(context).colorScheme;
    final name = part.filename ?? part.url ?? 'attachment';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Chip(
        avatar: Icon(
          part.mime?.startsWith('image/') == true
              ? Icons.image_outlined
              : Icons.attach_file,
          size: 18,
          color: scheme.primary,
        ),
        label: Text(name, overflow: TextOverflow.ellipsis),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// Collapsible reasoning text, collapsed by default on small screens.
class ReasoningBlock extends StatefulWidget {
  const ReasoningBlock({super.key, required this.text, this.compact = false});

  final String text;
  final bool compact;

  @override
  State<ReasoningBlock> createState() => _ReasoningBlockState();
}

class _ReasoningBlockState extends State<ReasoningBlock> {
  late bool _expanded = !widget.compact && widget.text.length < 400;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (widget.text.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  'Reasoning',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 4),
              child: Text(
                widget.text,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: scheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }
}