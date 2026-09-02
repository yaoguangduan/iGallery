import 'package:flutter_test/flutter_test.dart';

import 'package:igallery/app.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const IGalleryApp());
    await tester.pump();
  });
}
