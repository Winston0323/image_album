import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_album_demo/main.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void main() {
  testWidgets('asks the user to choose a folder', (tester) async {
    await tester.pumpWidget(const DemoApp());

    expect(find.text('Image Album'), findsOneWidget);
    expect(find.text('Choose a folder'), findsOneWidget);
  });

  testWidgets('opens the album for a folder path', (tester) async {
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('image_album_demo_test'),
    );

    await tester.pumpWidget(DemoApp(albumPath: dir!.path));
    await _settle(tester);

    expect(find.text('Image Album'), findsOneWidget);
    expect(find.text('No photos'), findsOneWidget);

    await tester.runAsync(() => dir.delete(recursive: true));
  });
}
