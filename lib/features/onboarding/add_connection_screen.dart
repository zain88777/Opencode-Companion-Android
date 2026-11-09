import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/errors.dart';
import '../../core/api/models.dart';
import '../../core/api/pairing.dart';
import '../../core/connections/connection_store.dart';
import '../../core/connections/server_connection.dart';
import 'qr_scan_screen.dart';

/// Add or edit a server connection.
///
/// The URL is probed before saving so the app knows which API generation it
/// will be talking to (v1 vs v2) - guessing from the URL is unreliable.
class AddConnectionScreen extends StatefulWidget {
  const AddConnectionScreen({super.key, this.existing});

  final ServerConnection? existing;

  @override
  State<AddConnectionScreen> createState() => _AddConnectionScreenState();
}

class _AddConnectionScreenState extends State<AddConnectionScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _directory;

  bool _obscure = true;
  bool _busy = false;
  ServerIdentity? _identity;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _url = TextEditingController(text: existing?.url ?? '');
    _username = TextEditingController(text: existing?.username ?? 'opencode');
    _directory = TextEditingController(text: existing?.directory ?? '');
    _password = TextEditingController();
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _directory.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    if (!_validate()) return;
    setState(() {
      _busy = true;
      _error = null;
      _identity = null;
    });
    try {
      final identity = await context.read<ConnectionStore>().probe(
            _url.text,
            _username.text,
            _password.text,
          );
      if (!mounted) return;
      setState(() => _identity = identity);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final store = context.read<ConnectionStore>();
      ServerIdentity identity;
      try {
        identity = await store.probe(_url.text, _username.text, _password.text);
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = _friendlyError(e);
        });
        return;
      }
      if (!mounted) return;

      final existing = widget.existing;
      final connection = ServerConnection(
        id: existing?.id ??
            'conn_${DateTime.now().millisecondsSinceEpoch}_${_url.hashCode.toRadixString(36)}',
        name: _name.text.trim(),
        url: ServerConnection.normalizeUrl(_url.text),
        username: _username.text.trim().isEmpty
            ? 'opencode'
            : _username.text.trim(),
        api: identity.api,
        directory: _directory.text.trim().isEmpty ? null : _directory.text.trim(),
        serverVersion: identity.version,
      );
      await store.save(connection, password: _password.text);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _friendlyError(e);
      });
    }
  }

  bool _validate() {
    if (_url.text.trim().isEmpty) {
      setState(() => _error = 'Enter the server address.');
      return false;
    }
    return _formKey.currentState?.validate() ?? true;
  }

  String _friendlyError(Object error) {
    if (error is ApiAuthException) return error.toString();
    if (error is UnsupportedServerException) return error.toString();
    if (error is ApiException) {
      if (error.isNotFound) return 'Server replied 404 - check the address and port.';
      return 'Server error ${error.status}.';
    }
    return error.toString();
  }

  /// Scans the server's pairing code and redeems it.
  ///
  /// OpenCode pairing codes are single-use and expire after five minutes, so
  /// this redeems immediately rather than filling the form for later.
  Future<void> _scanQr() async {
    final store = context.read<ConnectionStore>();
    final payload = await Navigator.of(context).push<PairingPayload>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (payload == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await redeemPairingPayload(payload, store.httpTransport);
      if (!mounted) return;
      setState(() {
        _url.text = result.url;
        _username.text = result.username;
        _password.text = result.password;
        if (result.name != null) _name.text = result.name!;
      });
      await _probe();
    } on PairingExpiredException catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } on PairingUnreachableException catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } catch (e) {
      if (mounted) setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final editing = widget.existing != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit server' : 'Add server'),
        actions: [
          IconButton(
            tooltip: 'Scan QR',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: _busy ? null : _scanQr,
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name (optional)',
                hintText: 'Home server',
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Server address',
                hintText: 'http://100.64.0.1:4096',
                helperText: 'LAN IP, Tailscale IP, or a tunnel URL',
              ),
              validator: (value) =>
                  value == null || value.trim().isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    controller: _username,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'Username'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: _password,
                    obscureText: _obscure,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure ? Icons.visibility : Icons.visibility_off,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _directory,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Project directory (optional)',
                hintText: 'C:\\Users\\me\\project',
                helperText: 'Pins this connection to one workspace',
              ),
            ),
            const SizedBox(height: 16),
            if (_identity != null) ...[
              Row(
                children: [
                  Icon(Icons.check_circle, color: scheme.primary, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Connected - ${_identity!.api == ServerApi.v2 ? 'v2' : 'v1'} API'
                    '${_identity!.version == null ? '' : ' ${_identity!.version}'}',
                    style: TextStyle(color: scheme.primary),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _probe,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_tethering),
                    label: const Text('Test'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _save,
                    icon: const Icon(Icons.save),
                    label: Text(editing ? 'Save changes' : 'Save server'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              'On the server machine:\n'
              '  opencode serve --hostname 0.0.0.0 --port 4096\n\n'
              'Set OPENCODE_SERVER_PASSWORD before starting so the app can '
              'authenticate.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}