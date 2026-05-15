import 'package:flutter_test/flutter_test.dart';

import 'package:hakurei_terminal/main.dart';

void main() {
  testWidgets('HakureiTerminal shell renders', (WidgetTester tester) async {
    await tester.pumpWidget(const HakureiTerminalApp(enableBridge: false));

    expect(find.text('HakureiTerminal'), findsOneWidget);
    expect(find.text('角色'), findsOneWidget);
    expect(find.byTooltip('设置'), findsOneWidget);
  });
}
