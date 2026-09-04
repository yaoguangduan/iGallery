import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:igallery/app.dart';
import 'package:igallery/core/display_prefs.dart';
import 'package:igallery/core/server_state.dart';
import 'package:igallery/ui/shared/media_picker.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ServerState()),
          ChangeNotifierProvider(create: (_) => DisplayPrefs()),
        ],
        child: const IGalleryApp(),
      ),
    );
    await tester.pump();

    expect(find.byType(IGalleryApp), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('upload source picker offers photos and files', (tester) async {
    UploadSource? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selected = await showUploadSourcePicker(context);
            },
            child: const Text('打开上传'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开上传'));
    await tester.pumpAndSettle();
    expect(find.text('从相册选择'), findsOneWidget);
    expect(find.text('从文件选择'), findsOneWidget);

    await tester.tap(find.text('从文件选择'));
    await tester.pumpAndSettle();
    expect(selected, UploadSource.files);
  });
}
