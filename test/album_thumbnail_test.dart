import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_album/src/album_images.dart';

/// Resolves [provider] on the real event loop, since decoding and disk I/O
/// are not driven by the test clock.
Future<ui.Image> _resolve(WidgetTester tester, ImageProvider provider) async {
  // Forget anything held in memory, so each call is like a fresh app start
  // and only the thumbnails on disk can answer.
  PaintingBinding.instance.imageCache
    ..clear()
    ..clearLiveImages();
  return (await tester.runAsync(() {
    // Started inside runAsync too, so its continuations run on the real
    // event loop rather than the test's fake one.
    final done = Completer<ui.Image>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!done.isCompleted) done.complete(info.image.clone());
        stream.removeListener(listener);
      },
      onError: (error, stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    return done.future.timeout(const Duration(seconds: 20));
  }))!;
}

Future<List<File>> _thumbs(WidgetTester tester, Directory dir) async =>
    (await tester.runAsync(
      () async => [
        if (await dir.exists())
          ...dir.listSync().whereType<File>().where(
            (f) => f.path.endsWith('.thumb'),
          ),
      ],
    ))!;

/// A noisy [width]x[height] photo-like JPEG, big enough that its thumbnail is
/// meaningfully smaller than it.
Uint8List _photoJpeg(int width, int height) {
  final image = img.Image(width: width, height: height);
  for (final pixel in image) {
    pixel
      ..r = (pixel.x * 255 ~/ width)
      ..g = (pixel.y * 255 ~/ height)
      ..b = ((pixel.x * 7 + pixel.y * 13) % 256);
  }
  return img.encodeJpg(image, quality: 95);
}

void main() {
  late Directory temp;
  late Directory cache;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('image_album_thumb_test');
    cache = Directory('${temp.path}/cache');
  });

  tearDown(() async {
    // Saving a thumbnail and pruning are background work that may still hold
    // the folder, so deleting it is retried briefly.
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        if (await temp.exists()) await temp.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  testWidgets('shrinks a photo to thumbnail width and stores a small JPEG', (
    tester,
  ) async {
    final photo = File('${temp.path}/big.jpg');
    await tester.runAsync(() => photo.writeAsBytes(_photoJpeg(1600, 1200)));

    final image = await _resolve(
      tester,
      AlbumThumbnailProvider(photo, cacheDirectory: cache),
    );

    expect(image.width, albumThumbnailWidth);
    expect(image.height, 180);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    final stored = await _thumbs(tester, cache);
    expect(stored, hasLength(1));

    final bytes = await tester.runAsync(stored.single.readAsBytes);
    // JPEG signature, and far smaller than the original.
    expect(bytes!.sublist(0, 2), [0xff, 0xd8]);
    expect(bytes.length, lessThan(photo.lengthSync() ~/ 5));
  });

  testWidgets('reads the stored thumbnail, not the original, next time', (
    tester,
  ) async {
    final photo = File('${temp.path}/big.jpg');
    await tester.runAsync(() => photo.writeAsBytes(_photoJpeg(1200, 800)));
    await _resolve(
      tester,
      AlbumThumbnailProvider(photo, cacheDirectory: cache),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    final stored = (await _thumbs(tester, cache)).single;
    final modified = stored.lastModifiedSync();

    // A distinct provider instance, as after an app restart.
    final again = await _resolve(
      tester,
      AlbumThumbnailProvider(File(photo.path), cacheDirectory: cache),
    );

    expect(again.width, albumThumbnailWidth);
    expect(await _thumbs(tester, cache), hasLength(1));
    expect(stored.lastModifiedSync(), modified);
  });

  testWidgets('makes a new thumbnail when the photo changes', (tester) async {
    final photo = File('${temp.path}/p.jpg');
    await tester.runAsync(() => photo.writeAsBytes(_photoJpeg(1200, 800)));
    await _resolve(
      tester,
      AlbumThumbnailProvider(photo, cacheDirectory: cache),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );

    // Portrait now.
    await tester.runAsync(() async {
      await photo.writeAsBytes(_photoJpeg(800, 1200));
      await photo.setLastModified(DateTime(2030));
    });
    final image = await _resolve(
      tester,
      AlbumThumbnailProvider(File(photo.path), cacheDirectory: cache),
    );

    expect(image.height, greaterThan(image.width));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    expect(await _thumbs(tester, cache), hasLength(2));
  });

  testWidgets('keeps transparency by storing a PNG', (tester) async {
    final image = img.Image(width: 600, height: 400, numChannels: 4);
    image.clear(img.ColorRgba8(255, 0, 0, 0));
    final photo = File('${temp.path}/clear.png');
    await tester.runAsync(() => photo.writeAsBytes(img.encodePng(image)));

    final thumb = await _resolve(
      tester,
      AlbumThumbnailProvider(photo, cacheDirectory: cache),
    );
    final data = await tester.runAsync(
      () => thumb.toByteData(format: ui.ImageByteFormat.rawStraightRgba),
    );
    expect(data!.getUint8(3), 0);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    final bytes = await tester.runAsync(
      (await _thumbs(tester, cache)).single.readAsBytes,
    );
    expect(bytes!.sublist(1, 4), 'PNG'.codeUnits);
  });

  testWidgets('does not upscale a photo narrower than the thumbnail', (
    tester,
  ) async {
    final photo = File('${temp.path}/tiny.jpg');
    await tester.runAsync(() => photo.writeAsBytes(_photoJpeg(100, 50)));

    final image = await _resolve(
      tester,
      AlbumThumbnailProvider(photo, cacheDirectory: cache),
    );

    expect(image.width, 100);
  });

  testWidgets('replaces a damaged stored thumbnail', (tester) async {
    final photo = File('${temp.path}/big.jpg');
    await tester.runAsync(() => photo.writeAsBytes(_photoJpeg(1200, 800)));
    await _resolve(
      tester,
      AlbumThumbnailProvider(photo, cacheDirectory: cache),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    final stored = (await _thumbs(tester, cache)).single;
    await tester.runAsync(() => stored.writeAsBytes([1, 2, 3]));

    final image = await _resolve(
      tester,
      AlbumThumbnailProvider(File(photo.path), cacheDirectory: cache),
    );

    expect(image.width, albumThumbnailWidth);
  });

  testWidgets('reports an error for something that is not an image', (
    tester,
  ) async {
    final junk = File('${temp.path}/junk.jpg');
    await tester.runAsync(() => junk.writeAsBytes([1, 2, 3, 4]));

    Object? failure;
    try {
      await _resolve(
        tester,
        AlbumThumbnailProvider(junk, cacheDirectory: cache),
      );
    } catch (error) {
      failure = error;
    }
    expect(failure, isNotNull);
    // Flutter also reports a failed decode to the framework, as it does for
    // any image provider. Consume it so the test does not fail on it.
    tester.takeException();
  });

  testWidgets('pruning deletes the oldest thumbnails first', (tester) async {
    await tester.runAsync(() async {
      await cache.create(recursive: true);
      for (var i = 0; i < 5; i++) {
        final file = File('${cache.path}/t$i.thumb');
        await file.writeAsBytes(Uint8List(1000));
        await file.setLastModified(DateTime(2026, 1, 1 + i));
      }
      // 5000 bytes against a 4000 limit: trim to 3200, i.e. keep 3.
      await pruneAlbumThumbnails(cache, maxBytes: 4000);
    });

    final names = (await _thumbs(
      tester,
      cache,
    )).map((f) => f.uri.pathSegments.last).toSet();
    expect(names, {'t2.thumb', 't3.thumb', 't4.thumb'});
  });
}
