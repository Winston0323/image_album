import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/src/album_wic.dart';

final List<int> _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42Y'
  'AAAAASUVORK5CYII=',
);

void main() {
  test('the Windows codec returns the file\'s real pixel size', () {
    if (!Platform.isWindows) return;
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}album_wic_1x1.png',
    );
    file.writeAsBytesSync(_onePixelPng);
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });

    final image = albumWicBgra(file.path);

    expect(image, isNotNull);
    expect(image!.width, 1);
    expect(image.height, 1);
    expect(image.pixels.length, 4);
  });
}
