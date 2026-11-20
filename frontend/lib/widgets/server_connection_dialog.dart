import 'package:flutter/material.dart';
import '../config.dart';
import '../services/backend_connection_service.dart';

class ServerConnectionDialog extends StatefulWidget {
  final String currentServer;
  final Future<void> Function(String) onConnected;
  final BackendConnectionService? connectionService;
  const ServerConnectionDialog(
      {super.key,
      required this.currentServer,
      required this.onConnected,
      this.connectionService});

  @override
  State<ServerConnectionDialog> createState() => _ServerConnectionDialogState();
}

class _ServerConnectionDialogState extends State<ServerConnectionDialog> {
  late final _address = TextEditingController(text: widget.currentServer);
  final _form = GlobalKey<FormState>();
  bool _connecting = false;
  String? _error;

  Future<void> _connect() async {
    if (_connecting || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final server =
          await (widget.connectionService ?? BackendConnectionService())
              .check(_address.text);
      if (!mounted) return;
      await widget.onConnected(server);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = error is BackendConnectionException
              ? error.message
              : 'Could not save this connection. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_connecting,
        child: AlertDialog(
          title: const Text('Connect to your music server'),
          scrollable: true,
          content: Form(
            key: _form,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                      'On your phone, use your PC’s Wi-Fi address. Keep the PC and its music server running while you stream.'),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _address,
                    enabled: !_connecting,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                        labelText: 'Server address',
                        hintText: 'http://192.168.1.20:8000'),
                    validator: (value) {
                      try {
                        AppConfig.normalizeServerUrl(value ?? '');
                        return null;
                      } on FormatException catch (error) {
                        return error.message;
                      }
                    },
                    onFieldSubmitted: (_) => _connect(),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                      '“localhost” connects to this device. For a hosted server, use its HTTPS address.'),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ],
                ]),
          ),
          actions: [
            TextButton(
                onPressed: _connecting ? null : () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: _connecting ? null : _connect,
                child: Text(_connecting ? 'Connecting…' : 'Connect')),
          ],
        ),
      );

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }
}
