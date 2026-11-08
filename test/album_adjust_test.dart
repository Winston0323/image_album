import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/src/album_adjust_page.dart';
import 'package:image_album/src/album_photo.dart';
import 'package:image_album/src/album_preview_page.dart';
import 'package:image_album/src/album_view.dart';

final List<int> _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42Y'
  'AAAAASUVORK5CYII=',
);

void main() {
  test('degrees wrap into one turn', () {
    expect(albumNormalizeDegrees(0), 0);
    expect(albumNormalizeDegrees(90), 90);
    expect(albumNormalizeDegrees(270), -90);
    expect(albumNormalizeDegrees(-180), 180);
    expect(albumNormalizeDegrees(360), 0);
    expect(albumNormalizeDegrees(10.04), 10);
    expect(albumCoverScale(degrees: 0, imageAspect: 1.5), 1);
    expect(albumCoverScale(degrees: 45, imageAspect: 1.5), greaterThan(1));
    final pan = albumClampPan(
      degrees: 40,
      imageAspect: 1.5,
      pan: const Offset(2, 2),
    );
    expect(pan.dx.abs(), lessThan(2));
    expect(pan.dy.abs(), lessThan(2));
  });

  test('a saved angle is not written into the photo', () async {
    final dir = await Directory.systemTemp.createTemp('album_view');
    addTearDown(() => dir.delete(recursive: true));
    final photo = File('${dir.path}/shot.png');
    await photo.writeAsBytes(_onePixelPng);
    final before = await photo.readAsBytes();
    final store = Directory('${dir.path}/store');

    await albumSetViewAdjustment(
      photo,
      const AlbumViewAdjustment(degrees: 33.2, panX: 0.02, panY: -0.01),
      store: store,
    );

    expect(await photo.readAsBytes(), before);
    final saved = await albumViewAdjustment(photo, store: store);
    expect(saved.degrees, 33.2);
    expect(saved.panX, 0.02);
    expect(saved.panY, -0.01);
    await albumSetViewAdjustment(
      photo,
      const AlbumViewAdjustment(),
      store: store,
    );
    expect((await albumViewAdjustment(photo, store: store)).isOriginal, isTrue);
    expect(File('${store.path}/view-adjustments.json').existsSync(), isFalse);
  });

  testWidgets('the adjust page spins by degrees and leaves the file alone', (
    tester,
  ) async {
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('album_adjust'),
    );
    addTearDown(() async {
      for (var attempt = 0; attempt < 10; attempt++) {
        try {
          if (dir!.existsSync()) await dir.delete(recursive: true);
          return;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });
    final photo = File('${dir!.path}/shot.png');
    final before = await tester.runAsync(() async {
      await photo.writeAsBytes(_onePixelPng);
      return photo.readAsBytes();
    });
    AlbumViewAdjustment? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              chosen = await Navigator.of(context).push<AlbumViewAdjustment>(
                MaterialPageRoute<AlbumViewAdjustment>(
                  builder: (context) => AlbumAdjustPage(file: photo),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('0°'), findsOneWidget);

    await tester.tap(find.byTooltip('Turn right 1 degree'));
    await tester.pump();
    expect(find.text('1°'), findsOneWidget);

    await tester.tap(find.byTooltip('Turn right 90 degrees'));
    await tester.pump();
    expect(find.text('91°'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(chosen?.degrees, 91);
    expect(chosen?.panX, 0);
    expect(chosen?.panY, 0);
    final after = await tester.runAsync(() => photo.readAsBytes());
    expect(after, before);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('cancel after a turn still shows the picture under the mouse', (
    tester,
  ) async {
    final errors = <Object>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details.exception);
      previous?.call(details);
    };
    addTearDown(() => FlutterError.onError = previous);

    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('album_adjust_cancel'),
    );
    addTearDown(() async {
      if (dir!.existsSync()) await dir.delete(recursive: true);
    });
    final photo = File('${dir!.path}/shot.png');
    await tester.runAsync(() => photo.writeAsBytes(_onePixelPng));
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 700);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: AlbumPreviewPage(
          photos: [AlbumPhoto(file: photo, takenAt: DateTime(2026, 7, 30))],
          initialIndex: 0,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(500, 350));
    await tester.pump();

    await tester.tap(find.byTooltip('Crop'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final slider = find.byType(Slider);
    await mouse.down(tester.getCenter(slider));
    await tester.pump();
    await mouse.moveBy(const Offset(120, 0));
    await tester.pump();
    await mouse.up();
    await tester.pump();

    await tester.tap(find.byTooltip('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await mouse.moveTo(const Offset(200, 200));
    await tester.pump();
    await mouse.moveTo(const Offset(700, 500));
    await tester.pump();

    expect(find.text('1 / 1'), findsOneWidget);
    expect(
      errors.where((error) => '$error'.contains('_debugDuringDeviceUpdate')),
      isEmpty,
    );
  });

  testWidgets('a turned picture in the preview survives the mouse', (
    tester,
  ) async {
    final errors = <Object>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details.exception);
      previous?.call(details);
    };
    addTearDown(() => FlutterError.onError = previous);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveViewer(
            constrained: false,
            child: AlbumFramedPhoto(
              adjustment: const AlbumViewAdjustment(degrees: 20),
              pixels: const Size(200, 100),
              image: const SizedBox(
                width: 200,
                height: 100,
                child: ColoredBox(color: Colors.red),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(40, 40));
    await tester.pump();
    await mouse.moveTo(const Offset(80, 60));
    await tester.pump();
    expect(
      errors.where((error) => '$error'.contains('_debugDuringDeviceUpdate')),
      isEmpty,
    );
  });

  testWidgets('a turned raw stack in the preview is laid out', (tester) async {
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details);
      previous?.call(details);
    };
    addTearDown(() => FlutterError.onError = previous);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveViewer(
            constrained: false,
            alignment: Alignment.topLeft,
            child: AlbumFramedPhoto(
              adjustment: const AlbumViewAdjustment(degrees: 20),
              pixels: const Size(400, 200),
              image: Stack(
                fit: StackFit.expand,
                children: const [
                  SizedBox(
                    width: 400,
                    height: 200,
                    child: ColoredBox(color: Colors.blue),
                  ),
                  SizedBox(
                    width: 400,
                    height: 200,
                    child: ColoredBox(color: Colors.red),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(30, 30));
    await tester.pump();
    await mouse.moveTo(const Offset(80, 50));
    await tester.pump();
    expect(errors, isEmpty, reason: errors.map((e) => e.exception).join('\n'));
  });
}
