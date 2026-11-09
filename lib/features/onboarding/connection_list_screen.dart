import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/connections/connection_store.dart';
import '../../core/connections/server_connection.dart';
import '../../core/api/models.dart';
import 'add_connection_screen.dart';

/// First-run screen: pick a saved server or add one.
class ConnectionListScreen extends StatelessWidget {
  const ConnectionListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ConnectionStore>();
    final connections = store.connections;

    return Scaffold(
      appBar: AppBar(
        title: const Text('OpenCode'),
        actions: [
          IconButton(
            tooltip: 'Add server',
            icon: const Icon(Icons.add),
            onPressed: () => _openAdd(context),
          ),
        ],
      ),
      floatingActionButton: connections.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openAdd(context),
              icon: const Icon(Icons.add),
              label: const Text('Add server'),
            ),
      body: connections.isEmpty
          ? const _EmptyState()
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: connections.length,
              itemBuilder: (context, index) {
                final connection = connections[index];
                return _ConnectionTile(
                  connection: connection,
                  active: store.active?.id == connection.id,
                  onTap: () async {
                    await store.primePassword(connection);
                    await store.setActive(connection);
                  },
                );
              },
            ),
    );
  }

  Future<void> _openAdd(BuildContext context) async {
    await Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => const AddConnectionScreen(),
    ));
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal_outlined, size: 56, color: scheme.primary),
            const SizedBox(height: 16),
            Text('Connect to your server',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Run on the machine that hosts your project:\n'
              'opencode serve --hostname 0.0.0.0 --port 4096',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                fullscreenDialog: true,
                builder: (_) => const AddConnectionScreen(),
              )),
              icon: const Icon(Icons.add),
              label: const Text('Add server'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionTile extends StatelessWidget {
  const _ConnectionTile({
    required this.connection,
    required this.active,
    required this.onTap,
  });

  final ServerConnection connection;
  final bool active;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        active ? Icons.check_circle : Icons.dns_outlined,
        color: active ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(
        connection.name.isEmpty ? connection.url : connection.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          connection.url,
          if (connection.serverVersion != null) connection.serverVersion!,
          connection.api == ServerApi.v1 ? 'v1 API' : 'v2 API',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) async {
          if (value == 'edit') {
            await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => AddConnectionScreen(existing: connection),
            ));
          } else if (value == 'remove') {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Remove server?'),
                content: Text(
                  'This deletes the saved connection and its stored password '
                  'for "${connection.name.isEmpty ? connection.url : connection.name}".',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Remove'),
                  ),
                ],
              ),
            );
            if (confirmed == true && context.mounted) {
              await context.read<ConnectionStore>().remove(connection.id);
            }
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'remove', child: Text('Remove')),
        ],
      ),
      onTap: () => onTap(),
    );
  }
}