import 'package:flutter_test/flutter_test.dart';

import 'package:fluorine/main.dart';

void main() {
  testWidgets('送信元一覧が表示される', (tester) async {
    await tester.pumpWidget(const FluorineApp());
    expect(find.text('Fluorine'), findsOneWidget);
  });
}
