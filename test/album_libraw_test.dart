import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/src/album_libraw.dart';

void main() {
  test('LibRaw reads the JPEG a Sony ARW names', () {
    const path = r'D:\New folder\DSC02208.ARW';
    if (!File(path).existsSync()) return;
    final thumb = albumLibRawThumbBytes(path);
    expect(thumb, isNotNull);
    expect(thumb!.length, greaterThan(4096));
    expect(thumb[0], 0xff);
    expect(thumb[1], 0xd8);
  });

  test(
    'LibRaw develops a Sony ARW faster than a full demosaic',
    () {
      const path = r'D:\New folder\DSC02208.ARW';
      if (!File(path).existsSync()) return;
      final watch = Stopwatch()..start();
      final image = albumLibRawRgba(path);
      watch.stop();
      expect(image, isNotNull);
      // Still the sensor image, not the small embedded preview, and quick
      // enough to open.
      expect(image!.width * image.height, greaterThan(20 * 1000 * 1000));
      expect(image.pixels.length, image.width * image.height * 4);
      expect(watch.elapsedMilliseconds, lessThan(4000));
      // ignore: avoid_print
      print(
        '${image.width}x${image.height} in ${watch.elapsedMilliseconds} ms',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
