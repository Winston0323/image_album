import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/image_album.dart';
import 'package:image_album/src/album_cache.dart';
import 'package:path/path.dart' as p;

final List<int> _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42Y'
  'AAAAASUVORK5CYII=',
);

void main() {
  late Directory temp;
  late Directory photos;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('image_album_lib_widget_test');
    photos = Directory(p.join(temp.path, 'photos'));
    await photos.create();
  });

  tearDown(() async {
    for (var attempt = 0; attempt < 40; attempt++) {
      try {
        if (await temp.exists()) await temp.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  Future<void> writePhotos(WidgetTester tester, int count) =>
      tester.runAsync(() async {
        for (var i = 0; i < count; i++) {
          final file = File(p.join(photos.path, 'p$i.png'));
          await file.writeAsBytes(_onePixelPng);
          await file.setLastModified(
            DateTime.now().subtract(Duration(minutes: i)),
          );
        }
      });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
  }

  Future<AlbumLibrary> openLibrary(WidgetTester tester) async =>
      (await tester.runAsync(
        () => AlbumLibrary.open(Directory(p.join(temp.path, 'library'))),
      ))!;

  Widget app(AlbumLibrary library) => MaterialApp(
    home: ImageAlbum(path: photos.path, library: library),
  );

  testWidgets('records each scan and keeps its index in the album file', (
    tester,
  ) async {
    await writePhotos(tester, 3);
    final library = await openLibrary(tester);

    await tester.pumpWidget(app(library));
    await settle(tester);

    expect(find.byType(Image), findsNWidgets(3));
    final info = library.indexFor(photos.path)!;
    expect(info.photoCount, 3);
    expect(
      await tester.runAsync(
        () => File(
          p.join(
            library.indexDirectory.path,
            albumIndexName(photos.path, false),
          ),
        ).exists(),
      ),
      true,
    );

    // The record reached the manifest, not just memory.
    final reopened = await tester.runAsync(
      () => AlbumLibrary.open(library.directory),
    );
    expect(reopened!.indexFor(photos.path)!.photoCount, 3);
  });

  testWidgets('stores thumbnails in the album file', (tester) async {
    await writePhotos(tester, 2);
    final library = await openLibrary(tester);

    await tester.pumpWidget(app(library));
    await settle(tester);

    // Saving a thumbnail is not waited on by the tile, so give it a moment.
    var stored = 0;
    for (var i = 0; i < 40 && stored < 2; i++) {
      stored = (await tester.runAsync(library.cacheUsage))!.thumbnailCount;
      if (stored < 2) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
      }
    }
    expect(stored, 2);
  });

  testWidgets('an out-of-date index gives way to what is in the folder', (
    tester,
  ) async {
    await writePhotos(tester, 2);
    final library = await openLibrary(tester);

    // Index left by an earlier opening: it knows a photo that has since gone.
    await tester.runAsync(() async {
      await loadAlbumPhotos(
        photos.path,
        cacheDirectory: library.indexDirectory,
      );
      final index = File(
        p.join(library.indexDirectory.path, albumIndexName(photos.path, false)),
      );
      final ghost = p.join(photos.path, 'ghost.png');
      await index.writeAsString(
        '${await index.readAsString()}'
        '$ghost\t1\t1\t${DateTime.now().microsecondsSinceEpoch}\n',
      );
    });

    await tester.pumpWidget(app(library));
    await settle(tester);

    expect(find.byType(Image), findsNWidgets(2));
    expect(find.text('2 photos'), findsOneWidget);
    // And the index is the truth again.
    expect(
      (await tester.runAsync(
        () =>
            readAlbumIndex(photos.path, cacheDirectory: library.indexDirectory),
      ))!.map((photo) => photo.fileName),
      isNot(contains('ghost.png')),
    );
  });

  testWidgets('a photo added since the last opening shows up', (tester) async {
    await writePhotos(tester, 2);
    final library = await openLibrary(tester);
    await tester.pumpWidget(app(library));
    await settle(tester);
    expect(find.byType(Image), findsNWidgets(2));

    // Closed, a photo arrives, and the album is opened again.
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await File(p.join(photos.path, 'new.png')).writeAsBytes(_onePixelPng);
    });
    await tester.pumpWidget(app(library));
    await settle(tester);

    expect(find.byType(Image), findsNWidgets(3));
    expect(library.indexFor(photos.path)!.photoCount, 3);
  });

  testWidgets('works without a library, as before', (tester) async {
    await writePhotos(tester, 2);

    await tester.pumpWidget(MaterialApp(home: ImageAlbum(path: photos.path)));
    await settle(tester);

    expect(find.byType(Image), findsNWidgets(2));
  });
}
