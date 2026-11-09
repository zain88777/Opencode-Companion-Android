import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/models.dart';
import '../../core/connections/connection_store.dart';

/// Server-side file browser.
///
/// Paths are relative to the connection's directory (or the server's current
/// directory when the connection is not pinned to one).
class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({super.key, this.initialPath});

  final String? initialPath;

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  String _currentPath = '.';
  List<FileEntry> _entries = [];
  bool _loading = true;
  String? _error;
  FileContent? _openFile;

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath ?? '.';
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final store = context.read<ConnectionStore>();
    final client = store.clientFor(store.active!);
    try {
      final entries = await client.listFiles(path: _currentPath);
      entries.sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not list files: $e';
        _loading = false;
      });
    }
  }

  Future<void> _open(FileEntry entry) async {
    if (entry.isDirectory) {
      setState(() {
        _currentPath = entry.path;
        _openFile = null;
      });
      await _load();
      return;
    }
    final store = context.read<ConnectionStore>();
    final client = store.clientFor(store.active!);
    setState(() => _loading = true);
    try {
      final content = await client.readFile(entry.path);
      if (!mounted) return;
      setState(() {
        _openFile = content;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not read file: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _openFile?.path ?? _currentPath,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15, fontFamily: 'monospace'),
        ),
        leading: _openFile != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _openFile = null),
              )
            : null,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _load, child: const Text('Retry')),
                    ],
                  ),
                )
              : _openFile != null
                  ? _fileView(scheme)
                  : _fileList(scheme),
    );
  }

  Widget _fileList(ColorScheme scheme) {
    if (_entries.isEmpty) {
      return Center(
        child: Text('Empty folder', style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return ListView.builder(
      itemCount: _entries.length + (_currentPath == '.' ? 0 : 1),
      itemBuilder: (context, index) {
        if (_currentPath != '.' && index == 0) {
          return ListTile(
            leading: const Icon(Icons.arrow_upward),
            title: const Text('..'),
            onTap: () {
              final segments =
                  _currentPath.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
              segments.removeLast();
              setState(() {
                _currentPath = segments.isEmpty ? '.' : segments.join('/');
                _openFile = null;
              });
              _load();
            },
          );
        }
        final entry = _entries[_currentPath == '.' ? index : index - 1];
        return ListTile(
          leading: Icon(
            entry.isDirectory
                ? Icons.folder_outlined
                : Icons.insert_drive_file_outlined,
            color: entry.isDirectory ? scheme.primary : scheme.onSurfaceVariant,
          ),
          title: Text(
            entry.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          onTap: () => _open(entry),
        );
      },
    );
  }

  Widget _fileView(ColorScheme scheme) {
    final content = _openFile?.content ?? '';
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: scheme.surfaceContainerLow,
          child: Text(
            '${content.length} characters',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: SelectionArea(
              child: Text(
                content,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4),
              ),
            ),
          ),
        ),
      ],
    );
  }
}