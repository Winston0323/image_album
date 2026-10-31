import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/image_album.dart';
import 'package:image_album_demo/main.dart';
import 'package:path/path.dart' as p;

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

/// Settles, then keeps waiting up to three seconds for [finder], for work that
/// ends with real file writes.
Future<void> _until(WidgetTester tester, Finder finder) async {
  await _settle(tester);
  for (var i = 0; i < 60 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('image_album_demo_test');
  });

  tearDown(() async {
    for (var attempt = 0; attempt < 40; attempt++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  Directory libraryDir() => Directory(p.join(temp.path, 'library'));

  /// Folders for the album to hold, saved in the album file as an earlier run
  /// would have left them.
  Future<List<String>> saveSources(WidgetTester tester, int count) async {
    final paths = <String>[];
    for (var i = 0; i < count; i++) {
      final dir = Directory(p.join(temp.path, 'photos$i'))..createSync();
      paths.add(dir.path);
    }
    await tester.runAsync(() async {
      final library = await AlbumLibrary.open(libraryDir());
      await library.setSources(paths);
      library.dispose();
    });
    return paths;
  }

  Future<List<String>> savedSources(WidgetTester tester) async {
    final library = (await tester.runAsync(
      () => AlbumLibrary.open(libraryDir()),
    ))!;
    final sources = library.sources;
    library.dispose();
    return sources;
  }

  void wide(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);
  }

  testWidgets('asks the user to choose a folder', (tester) async {
    await tester.pumpWidget(DemoApp(libraryDirectory: libraryDir()));
    await _settle(tester);

    expect(find.text('Image Album'), findsOneWidget);
    expect(find.text('Choose a folder'), findsOneWidget);
  });

  testWidgets('reopens the folders saved in the album file', (tester) async {
    wide(tester);
    await saveSources(tester, 2);

    await tester.pumpWidget(DemoApp(libraryDirectory: libraryDir()));
    await _settle(tester);

    expect(find.text('Choose a folder'), findsNothing);
    expect(find.text('2 folders'), findsOneWidget);
    expect(find.byTooltip('Remove folder'), findsNWidgets(2));
    expect(find.byTooltip('Add folder'), findsOneWidget);
  });

  testWidgets('removing a folder is saved, and can be undone', (tester) async {
    wide(tester);
    final paths = await saveSources(tester, 2);
    await tester.pumpWidget(DemoApp(libraryDirectory: libraryDir()));
    await _settle(tester);

    await tester.tap(find.byTooltip('Remove folder').last);
    await _until(tester, find.text('Removed ${p.basename(paths[1])}'));
    expect(find.text('Removed ${p.basename(paths[1])}'), findsOneWidget);
    expect(find.byTooltip('Remove folder'), findsOneWidget);
    expect(await savedSources(tester), [paths[0]]);

    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Undo'));
    await _until(tester, find.text('2 folders'));
    expect(find.byTooltip('Remove folder'), findsNWidgets(2));
    // The change is written to the album file a moment after it shows.
    var saved = await savedSources(tester);
    for (var i = 0; i < 60 && saved.length < 2; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      saved = await savedSources(tester);
    }
    expect(saved, paths);
  });

  testWidgets('removing the last folder leaves the album, not the welcome', (
    tester,
  ) async {
    wide(tester);
    await saveSources(tester, 1);
    await tester.pumpWidget(DemoApp(libraryDirectory: libraryDir()));
    await _settle(tester);

    await tester.tap(find.byTooltip('Remove folder'));
    await _settle(tester);

    expect(find.text('No folders yet'), findsOneWidget);
    expect(find.text('Choose a folder'), findsNothing);
  });

  testWidgets('opens the album for a folder path', (tester) async {
    final photos = Directory(p.join(temp.path, 'given'))..createSync();

    await tester.pumpWidget(
      DemoApp(libraryDirectory: libraryDir(), albumPath: photos.path),
    );
    await _until(tester, find.text('No photos'));

    expect(find.text('Image Album'), findsOneWidget);
    expect(find.text('No photos'), findsOneWidget);
    expect(await savedSources(tester), [photos.path]);
  });

  testWidgets('shows the cache and can clear it', (tester) async {
    await saveSources(tester, 1);
    await tester.pumpWidget(DemoApp(libraryDirectory: libraryDir()));
    await _settle(tester);

    await tester.tap(find.byTooltip('Cache'));
    await _settle(tester);
    expect(find.textContaining('0 thumbnails'), findsOneWidget);

    await tester.tap(find.text('Clear cache'));
    await _settle(tester);
    expect(find.text('Cache cleared.'), findsOneWidget);
  });
}
