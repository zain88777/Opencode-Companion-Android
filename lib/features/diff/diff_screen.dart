import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/models.dart';
import '../../core/connections/connection_store.dart';
import 'diff_view.dart';

/// Shows what changed: the session diff and the VCS working diff.
class DiffScreen extends StatefulWidget {
  const DiffScreen({super.key, required this.sessionID});

  final String sessionID;

  @override
  State<DiffScreen> createState() => _DiffScreenState();
}

class _DiffScreenState extends State<DiffScreen> {
  List<DiffEntry>? _sessionDiff;
  List<DiffEntry>? _vcsDiff;
  bool _loading = true;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final store = context.read<ConnectionStore>();
    final connection = store.active;
    if (connection == null) {
      setState(() {
        _loading = false;
        _error = 'No active server.';
      });
      return;
    }
    final client = store.clientFor(connection);
    try {
      final results = await Future.wait([
        client.diff(widget.sessionID).catchError((_) => <DiffEntry>[]),
        client.vcsDiff().catchError((_) => <DiffEntry>[]),
      ]);
      if (!mounted) return;
      setState(() {
        _sessionDiff = results[0];
        _vcsDiff = results[1];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load changes: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Changes'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _load,
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Session'),
              Tab(text: 'Working tree'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text(_error!))
                : TabBarView(
                    children: [
                      _list(scheme, _sessionDiff ?? const [], 'No session changes yet'),
                      _list(scheme, _vcsDiff ?? const [], 'No working-tree changes'),
                    ],
                  ),
      ),
    );
  }

  Widget _list(ColorScheme scheme, List<DiffEntry> entries, String emptyText) {
    if (entries.isEmpty) {
      return Center(
        child: Text(emptyText, style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return ExpansionTile(
          leading: Icon(
            entry.status == 'added'
                ? Icons.add_circle_outline
                : entry.status == 'deleted'
                    ? Icons.remove_circle_outline
                    : Icons.edit_outlined,
            size: 20,
            color: scheme.primary,
          ),
          title: Text(
            entry.file,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          subtitle: Text(
            '+${entry.additions} -${entry.deletions}',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: entry.patch.isEmpty
                  ? Center(
                      child: Text(
                        'No patch text (binary or large file)',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    )
                  : UnifiedPatchView(patch: entry.patch),
            ),
          ],
        );
      },
    );
  }
}