import 'package:flutter/material.dart';

import '../../../core/api/models.dart';

/// Approval card for a tool that wants to run something.
///
/// This is the feature that makes the phone a real companion: the agent stops
/// and waits for an explicit decision rather than running an unknown command.
class PermissionPrompt extends StatelessWidget {
  const PermissionPrompt({
    super.key,
    required this.request,
    required this.onReply,
    this.busy = false,
  });

  final PermissionRequest request;
  final Future<void> Function(String decision) onReply;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
              Icon(Icons.shield_outlined, size: 18, color: scheme.secondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Allow ${request.action}?',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          if (request.resources.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final resource in request.resources.take(3))
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  resource,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            if (request.resources.length > 3)
              Text(
                '+ ${request.resources.length - 3} more',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
          if (request.message != null && request.message!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(request.message!, style: const TextStyle(fontSize: 13)),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: busy ? null : () => onReply('once'),
                  child: const Text('Once'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : () => onReply('always'),
                  child: const Text('Always'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextButton(
                  onPressed: busy ? null : () => onReply('reject'),
                  child: const Text('Reject'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}