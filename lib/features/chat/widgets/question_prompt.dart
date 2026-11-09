import 'package:flutter/material.dart';

import '../../../core/api/models.dart' hide FormField;

/// Answer card for a server "form" (the v2 name for a question prompt).
class QuestionPrompt extends StatefulWidget {
  const QuestionPrompt({
    super.key,
    required this.request,
    required this.onSubmit,
    required this.onReject,
    this.busy = false,
  });

  final QuestionRequest request;
  final Future<void> Function(Map<String, dynamic> answers) onSubmit;
  final Future<void> Function() onReject;
  final bool busy;

  @override
  State<QuestionPrompt> createState() => _QuestionPromptState();
}

class _QuestionPromptState extends State<QuestionPrompt> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, Set<String>> _selected = {};

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final questions = widget.request.questions;
    if (questions.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.secondary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline, size: 18, color: scheme.secondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.request.title.isEmpty
                      ? 'The agent needs input'
                      : widget.request.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final question in widget.request.questions)
            _question(context, question),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: widget.busy ? null : _submit,
                  child: const Text('Send'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextButton(
                  onPressed: widget.busy ? null : widget.onReject,
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _question(BuildContext context, Question question) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            question.header,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (question.question != question.header) ...[
            const SizedBox(height: 2),
            Text(question.question, style: const TextStyle(fontSize: 13)),
          ],
          const SizedBox(height: 6),
          if (question.options.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final option in question.options)
                  _optionChip(context, question, option),
              ],
            )
          else
            TextField(
              controller: _controllers.putIfAbsent(
                question.key,
                () => TextEditingController(),
              ),
              decoration: InputDecoration(
                isDense: true,
                hintText: question.custom ? 'Type an answer' : null,
              ),
            ),
        ],
      ),
    );
  }

  Widget _optionChip(BuildContext context, Question question, FormOption option) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selected[question.key]?.contains(option.value) ?? false;
    return FilterChip(
      label: Text(option.label),
      selected: selected,
      showCheckmark: false,
      onSelected: (value) {
        setState(() {
          final set = _selected.putIfAbsent(question.key, () => <String>{});
          if (question.multiple) {
            value ? set.add(option.value) : set.remove(option.value);
          } else {
            // Single choice: selecting one option replaces the previous one.
            set
              ..clear()
              ..add(option.value);
          }
        });
      },
      selectedColor: scheme.primaryContainer,
      backgroundColor: scheme.surfaceContainerHighest,
    );
  }

  void _submit() {
    final answers = <String, dynamic>{};
    for (final question in widget.request.questions) {
      final selected = _selected[question.key];
      if (selected != null && selected.isNotEmpty) {
        answers[question.key] = question.multiple
            ? selected.toList()
            : selected.first;
        continue;
      }
      final text = _controllers[question.key]?.text.trim() ?? '';
      if (text.isEmpty) continue;
      var type = 'string';
      for (final f in widget.request.fields) {
        if (f.key == question.key) {
          type = f.type;
          break;
        }
      }
      if (type == 'boolean') {
        answers[question.key] = text == 'true' || text == 'Yes';
      } else if (type == 'number' || type == 'integer') {
        answers[question.key] = num.tryParse(text) ?? text;
      } else {
        answers[question.key] = text;
      }
    }
    widget.onSubmit(answers);
  }
}