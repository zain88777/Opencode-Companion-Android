import 'package:flutter/material.dart';

import '../../../core/api/models.dart';

/// Bottom sheet with the server-side session record: model, agent, directory,
/// usage and cost.
class SessionInfoSheet extends StatelessWidget {
  const SessionInfoSheet({super.key, required this.session, required this.usage});

  final Session? session;
  final String usage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final session = this.session;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text('Session', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 14),
            if (session == null)
              Text(
                'Server record unavailable',
                style: TextStyle(color: scheme.onSurfaceVariant),
              )
            else ...[
              _row(context, 'Title',
                  session.title.isEmpty ? 'Untitled session' : session.title),
              if (session.model != null)
                _row(context, 'Model',
                    '${session.model!.providerID}/${session.model!.id}'),
              if (session.agent != null) _row(context, 'Agent', session.agent!),
              if (session.outcome != null)
                _row(context, 'Outcome', session.outcome!),
              if (session.directory.isNotEmpty)
                _row(context, 'Directory', session.directory, mono: true),
              _row(context, 'Created', _formatDate(session.created)),
              _row(context, 'Updated', _formatDate(session.updated)),
              if (session.id.isNotEmpty)
                _row(context, 'ID', session.id, mono: true),
            ],
            const Divider(height: 28),
            Text('Usage', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(usage, style: TextStyle(color: scheme.onSurfaceVariant)),
            Text(
              'Cost: \$${session?.cost.toStringAsFixed(4) ?? '0.0000'}',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value,
      {bool mono = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                fontFamily: mono ? 'monospace' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(int epochMillis) {
    if (epochMillis == 0) return '-';
    final time = DateTime.fromMillisecondsSinceEpoch(epochMillis);
    final now = DateTime.now();
    final label =
        '${time.year}-${_two(time.month)}-${_two(time.day)} ${_two(time.hour)}:${_two(time.minute)}';
    if (time.year == now.year && time.month == now.month && time.day == now.day) {
      return 'Today ${_two(time.hour)}:${_two(time.minute)}';
    }
    return label;
  }

  String _two(int value) => value.toString().padLeft(2, '0');
}