import 'package:flutter/material.dart';

/// Prompt input with an attachment button and a send/stop toggle.
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.onSend,
    required this.busy,
    required this.onInterrupt,
    required this.onAttach,
    this.enabled = true,
  });

  final Future<void> Function(String text) onSend;
  final bool busy;
  final VoidCallback onInterrupt;
  final VoidCallback onAttach;
  final bool enabled;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) setState(() => _hasText = hasText);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    await widget.onSend(text);
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            SizedBox(
              width: 44,
              height: 48,
              child: IconButton(
                onPressed: widget.enabled ? widget.onAttach : null,
                icon: const Icon(Icons.add_circle_outline),
                tooltip: 'Attach image',
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                enabled: widget.enabled,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: 'Message the agent...',
                ),
                onSubmitted: (_) => widget.busy ? null : _send(),
              ),
            ),
            const SizedBox(width: 8),
            if (widget.busy)
              SizedBox(
                width: 48,
                height: 48,
                child: IconButton.filledTonal(
                  onPressed: widget.onInterrupt,
                  icon: const Icon(Icons.stop),
                  tooltip: 'Stop',
                ),
              )
            else
              AnimatedOpacity(
                opacity: _hasText ? 1 : 0.4,
                duration: const Duration(milliseconds: 120),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: IconButton.filled(
                    onPressed: _hasText ? _send : null,
                    icon: const Icon(Icons.send),
                    tooltip: 'Send',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}