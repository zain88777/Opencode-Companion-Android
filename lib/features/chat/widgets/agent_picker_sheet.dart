import 'package:flutter/material.dart';

import '../../../core/api/models.dart';
import '../../../core/api/opencode_client.dart';

/// Bottom sheet for choosing the session agent.
///
/// OpenCode ships a read-only `plan` agent alongside the default `build` agent;
/// switching between them is what "plan mode" means. The sheet surfaces that
/// distinction rather than burying it in a flat list.
class AgentPickerSheet extends StatefulWidget {
  const AgentPickerSheet({
    super.key,
    required this.client,
    required this.currentAgent,
  });

  final OpencodeClient client;
  final String? currentAgent;

  @override
  State<AgentPickerSheet> createState() => _AgentPickerSheetState();
}

class _AgentPickerSheetState extends State<AgentPickerSheet> {
  List<AgentInfo>? _agents;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final agents = await widget.client.agents();
      agents.sort((a, b) => a.id == b.id ? 0 : a.id.compareTo(b.id));
      if (!mounted) return;
      setState(() {
        _agents = agents;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load agents: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Agent', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  'Plan is read-only - it can explore but not change anything. '
                  'Build has full tool access.',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text(_error!))
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: _agents!.length,
                        itemBuilder: (context, index) {
                          final agent = _agents![index];
                          final selected = agent.id == widget.currentAgent;
                          final readOnly = agent.id.toLowerCase() == 'plan' ||
                              agent.id.toLowerCase().contains('plan');
                          return ListTile(
                            leading: Icon(
                              readOnly
                                  ? Icons.visibility_outlined
                                  : agent.mode == 'subagent'
                                      ? Icons.account_tree_outlined
                                      : Icons.build_outlined,
                              color: selected ? scheme.primary : scheme.onSurfaceVariant,
                            ),
                            title: Text(
                              agent.name.isEmpty ? agent.id : agent.name,
                              style: TextStyle(
                                fontWeight:
                                    selected ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                            subtitle: Text(
                              readOnly
                                  ? 'Read-only · planning'
                                  : agent.mode == 'subagent'
                                      ? 'Subagent · ${agent.id}'
                                      : 'Full access · ${agent.id}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: selected
                                ? Icon(Icons.check, color: scheme.primary, size: 20)
                                : null,
                            selected: selected,
                            onTap: () => Navigator.pop(context, agent.id),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}