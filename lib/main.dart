import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/connections/connection_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = ConnectionStore();
  await store.load();
  runApp(
    ChangeNotifierProvider<ConnectionStore>.value(
      value: store,
      child: const OpenCodeApp(),
    ),
  );
}