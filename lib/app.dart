import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/connections/connection_store.dart';
import 'features/onboarding/connection_list_screen.dart';
import 'features/sessions/session_list_screen.dart';
import 'shared/theme.dart';

class OpenCodeApp extends StatelessWidget {
  const OpenCodeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenCode',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      home: const _Home(),
    );
  }
}

class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ConnectionStore>();
    if (!store.loaded) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final active = store.active;
    if (active == null) {
      return const ConnectionListScreen();
    }
    return const SessionListScreen();
  }
}