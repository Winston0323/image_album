import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_album/src/album_bmp_convert.dart';
import 'package:path/path.dart' as p;

void main() {
  test('lists BMP files under a roll folder', () async {
    final root = await Directory.systemTemp.createTemp('album_bmp_list');
    addTearDown(() => root.delete(recursive: true));
    await File(p.join(root.path, 'a.bmp')).writeAsBytes([1]);
    await File(p.join(root.path, 'b.BMP')).writeAsBytes([1]);
    await File(p.join(root.path, 'c.jpg')).writeAsBytes([1]);
    await Directory(p.join(root.path, 'nested')).create();
    await File(p.join(root.path, 'nested', 'd.bmp')).writeAsBytes([1]);

    final found = await albumListBmpFiles(root.path);

    expect(found.map(p.basename).toList(), ['a.bmp', 'b.BMP', 'd.bmp']);
  });

  test('converts BMP to TIFF and removes the BMP', () async {
    final root = await Directory.systemTemp.createTemp('album_bmp_convert');
    addTearDown(() => root.delete(recursive: true));
    final frame = img.Image(width: 4, height: 4);
    for (final pixel in frame) {
      pixel
        ..r = 200
        ..g = 40
        ..b = 40
        ..a = 255;
    }
    final bmpPath = p.join(root.path, 'frame.bmp');
    await File(bmpPath).writeAsBytes(img.encodeBmp(frame));

    final result = await albumConvertBmpsToTif(bmpPaths: [bmpPath]);

    expect(result.converted, 1);
    expect(result.failed, 0);
    expect(await File(bmpPath).exists(), isFalse);
    expect(await File(p.join(root.path, 'frame.tif')).exists(), isTrue);
  });
}
