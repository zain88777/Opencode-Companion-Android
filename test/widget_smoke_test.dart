import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_companion/app.dart';
import 'package:opencode_companion/core/connections/connection_store.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('first run shows the connect screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = ConnectionStore();
    await store.load();

    await tester.pumpWidget(
      ChangeNotifierProvider<ConnectionStore>.value(
        value: store,
        child: const OpenCodeApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Connect to your server'), findsOneWidget);
  });
}