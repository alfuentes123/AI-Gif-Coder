import 'package:flutter_test/flutter_test.dart';
import 'package:gif_coder/main.dart';
import 'package:gif_coder/settings_store.dart';

void main() {
  testWidgets('app loads with agent mode toggle', (WidgetTester tester) async {
    final store = SettingsStore()..isLoaded = true;

    await tester.pumpWidget(
      LMStudioApp(store: store, settingsReady: Future.value()),
    );
    await tester.pump();

    expect(find.text('CODE FILE OUTPUT'), findsOneWidget);
  });
}
