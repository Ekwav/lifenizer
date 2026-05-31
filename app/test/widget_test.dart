import 'package:flutter_test/flutter_test.dart';

import 'package:app/app_state.dart';
import 'package:app/main.dart';

void main() {
  testWidgets('shows the vault login screen', (WidgetTester tester) async {
    await tester.pumpWidget(LifenizerApp(state: LifenizerAppState()));

    expect(find.text('Lifenizer'), findsOneWidget);
    expect(find.text('Enter vault'), findsOneWidget);
  });
}
