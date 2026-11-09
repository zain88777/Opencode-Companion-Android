import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/api/models.dart';

/// A single tool invocation: name, status, input, and output.
///
/// On a 720p phone the side-by-side layout used on desktop does not fit, so the
/// input/output render as collapsible monospace blocks.
class ToolCallCard extends StatefulWidget {
  const ToolCallCard({super.key, required this.part});

  final Part part;

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = widget.part.state;
    final status = state?.status ?? ToolStatus.pending;
    final name = widget.part.tool ?? 'tool';
    final title = state?.title;

    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    _statusIcon(scheme, status),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title ?? name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (state?.input != null) ...[
                      _label(context, 'Input'),
                      _mono(context, _pretty(state!.input)),
                    ],
                    if (state?.output != null) ...[
                      const SizedBox(height: 8),
                      _label(context, 'Output'),
                      _mono(context, _pretty(state!.output)),
                    ],
                    if (state?.errorMessage != null) ...[
                      const SizedBox(height: 8),
                      _label(context, 'Error'),
                      _mono(context, state!.errorMessage!,
                          color: scheme.error),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statusIcon(ColorScheme scheme, ToolStatus status) {
    switch (status) {
      case ToolStatus.completed:
        return Icon(Icons.check_circle_outline,
            size: 16, color: scheme.primary);
      case ToolStatus.error:
        return Icon(Icons.error_outline, size: 16, color: scheme.error);
      case ToolStatus.running:
        return SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
        );
      case ToolStatus.pending:
        return Icon(Icons.schedule, size: 16, color: scheme.onSurfaceVariant);
    }
  }

  Widget _label(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _mono(BuildContext context, String text, {Color? color}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: SelectableText(
            text,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.3,
              color: color ?? scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  String _pretty(Object? value) {
    if (value is String) {
      try {
        final decoded = jsonDecode(value);
        return const JsonEncoder.withIndent('  ').convert(decoded);
      } catch (_) {
        return value;
      }
    }
    if (value is List || value is Map) {
      return const JsonEncoder.withIndent('  ').convert(value);
    }
    return value?.toString() ?? '';
  }
}