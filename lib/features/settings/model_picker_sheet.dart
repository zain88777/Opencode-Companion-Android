import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import '../../core/api/opencode_client.dart';

/// Bottom sheet for choosing a provider/model (and optional variant).
///
/// Returns the selected [ModelRef], or null when dismissed.
class ModelPickerSheet extends StatefulWidget {
  const ModelPickerSheet({super.key, required this.client});

  final OpencodeClient client;

  @override
  State<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<ModelPickerSheet> {
  ProviderCatalog? _catalog;
  String? _error;
  bool _loading = true;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final catalog = await widget.client.providerCatalog();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load models: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final catalog = _catalog;
    final models = catalog?.models ?? const <ModelInfo>[];
    final filtered = _search.isEmpty
        ? models
        : models
            .where((m) =>
                m.name.toLowerCase().contains(_search.toLowerCase()) ||
                m.modelID.toLowerCase().contains(_search.toLowerCase()) ||
                m.providerID.toLowerCase().contains(_search.toLowerCase()))
            .toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Model', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search models',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                  onChanged: (value) => setState(() => _search = value),
                ),
              ],
            ),
          ),
          if (catalog?.defaultModel != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(Icons.star_outline, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Default: ${catalog!.defaultModel!.providerID}/${catalog.defaultModel!.modelID}',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text(_error!))
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final model = filtered[index];
                          return ExpansionTile(
                            leading: Icon(
                              model.hasTools ? Icons.build_outlined : Icons.chat_bubble_outline,
                              size: 20,
                              color: scheme.primary,
                            ),
                            title: Text(
                              model.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14),
                            ),
                            subtitle: Text(
                              '${model.providerID}/${model.modelID}'
                              '${model.contextWindow > 0 ? ' - ${_formatContext(model.contextWindow)}' : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                            children: [
                              if (model.variants.isEmpty)
                                ListTile(
                                  dense: true,
                                  title: const Text('Default variant'),
                                  onTap: () => Navigator.pop(
                                    context,
                                    ModelRef(
                                      id: model.modelID,
                                      providerID: model.providerID,
                                    ),
                                  ),
                                )
                              else
                                for (final variant in model.variants)
                                  ListTile(
                                    dense: true,
                                    title: Text(variant.id),
                                    subtitle: variant.reasoningEffort == null
                                        ? null
                                        : Text('reasoning: ${variant.reasoningEffort}'),
                                    onTap: () => Navigator.pop(
                                      context,
                                      ModelRef(
                                        id: model.modelID,
                                        providerID: model.providerID,
                                        variant: variant.id,
                                      ),
                                    ),
                                  ),
                            ],
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  String _formatContext(int tokens) {
    if (tokens >= 1000000) return '${(tokens / 1000000).toStringAsFixed(1)}M ctx';
    if (tokens >= 1000) return '${(tokens / 1000).round()}k ctx';
    return '$tokens ctx';
  }
}