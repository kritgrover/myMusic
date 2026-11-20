import 'package:flutter/material.dart';
import '../utils/responsive_utils.dart';
import '../services/auth_service.dart';

class LoginScreen extends StatefulWidget {
  final AuthService authService;
  final String? serverAddress;
  final VoidCallback? onChangeServer;

  const LoginScreen(
      {super.key,
      required this.authService,
      this.serverAddress,
      this.onChangeServer});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  String? _error;
  bool _isSubmitting = false;

  Future<void> _submit() async {
    if (_isSubmitting || widget.authService.isLoading) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _error = null;
      _isSubmitting = true;
    });

    final ok = await widget.authService.login(
      _usernameController.text.trim(),
      _passwordController.text,
    );
    if (mounted) {
      setState(() {
        _isSubmitting = false;
        if (!ok) {
          _error = widget.authService.lastLoginError ??
              'Could not sign you in. Please try again.';
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
          child: Center(
              child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            margin: ResponsiveUtils.responsivePadding(context),
            child: Padding(
              padding: ResponsiveUtils.responsivePadding(context),
              child: AutofillGroup(
                  child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Sign in to myMusic',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _usernameController,
                      autofillHints: const [AutofillHints.username],
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(labelText: 'Username'),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Username is required';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _passwordController,
                      decoration: const InputDecoration(labelText: 'Password'),
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      textInputAction: TextInputAction.done,
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Password is required';
                        }
                        return null;
                      },
                      onFieldSubmitted: (_) => _submit(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                    ],
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: ListenableBuilder(
                        listenable: widget.authService,
                        builder: (context, _) {
                          final loading =
                              _isSubmitting || widget.authService.isLoading;
                          return ElevatedButton(
                            onPressed: loading ? null : _submit,
                            child: loading
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Text('Login'),
                          );
                        },
                      ),
                    ),
                    if (widget.onChangeServer != null) ...[
                      const SizedBox(height: 16),
                      Text('Music server',
                          style: Theme.of(context).textTheme.labelMedium),
                      const SizedBox(height: 4),
                      Text(widget.serverAddress ?? '', softWrap: true),
                      ListenableBuilder(
                        listenable: widget.authService,
                        builder: (context, _) => TextButton.icon(
                          onPressed:
                              _isSubmitting || widget.authService.isLoading
                                  ? null
                                  : widget.onChangeServer,
                          icon: const Icon(Icons.dns_outlined),
                          label: const Text('Change server'),
                        ),
                      ),
                    ],
                  ],
                ),
              )),
            ),
          ),
        ),
      ))),
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }
}
