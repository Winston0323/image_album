import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/src/album_rename.dart';
import 'package:path/path.dart' as p;

void main() {
  group('albumSanitizePrefix', () {
    test('keeps a plain name', () {
      expect(albumSanitizePrefix('Holiday'), 'Holiday');
    });

    test('turns forbidden characters and spaces into underscores', () {
      expect(
        albumSanitizePrefix(' a/b:c*d?e "f" <g>|h  i '),
        'a_b_c_d_e__f___g__h_i',
      );
    });

    test('drops trailing dots and spaces', () {
      expect(albumSanitizePrefix('trip...'), 'trip');
      expect(albumSanitizePrefix('   '), '');
    });
  });

  group('albumOrderLabel', () {
    test('is three digits for up to 999', () {
      expect(albumOrderLabel(1, 5), '001');
      expect(albumOrderLabel(999, 999), '999');
    });

    test('grows past 999', () {
      expect(albumOrderLabel(7, 1000), '0007');
      expect(albumOrderLabel(12, 12345), '00012');
    });
  });

  group('albumCompareNames', () {
    test('reads numbers as numbers', () {
      final names = ['img10.jpg', 'img2.jpg', 'img1.jpg']
        ..sort(albumCompareNames);
      expect(names, ['img1.jpg', 'img2.jpg', 'img10.jpg']);
    });

    test('ignores case', () {
      final names = ['b.jpg', 'A.jpg']..sort(albumCompareNames);
      expect(names, ['A.jpg', 'b.jpg']);
    });

    test('puts 2 before 02', () {
      expect(albumCompareNames('2.jpg', '02.jpg'), lessThan(0));
    });

    test('compares only the file name, not the folder', () {
      expect(
        albumCompareNames(p.join('z', 'a.jpg'), p.join('a', 'b.jpg')),
        lessThan(0),
      );
    });
  });

  group('albumRenameImages', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('image_album_rename_test');
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    String touch(String relative, [String content = '']) {
      final file = File(p.join(temp.path, relative));
      file.createSync(recursive: true);
      file.writeAsStringSync(content.isEmpty ? relative : content);
      return file.path;
    }

    List<String> names(String relative) =>
        Directory(p.join(temp.path, relative))
            .listSync()
            .whereType<File>()
            .map((file) => p.basename(file.path))
            .toList()
          ..sort();

    test('numbers files in natural name order and keeps extensions', () {
      final paths = [touch('img10.JPG'), touch('img2.png'), touch('img1.jpg')];

      final result = albumRenameImages(paths: paths, prefix: 'trip');

      expect(result.errors, isEmpty);
      expect(result.successCount, 3);
      expect(names('.'), ['trip_001.jpg', 'trip_002.png', 'trip_003.JPG']);
      // The content went along with the name.
      expect(
        File(p.join(temp.path, 'trip_001.jpg')).readAsStringSync(),
        'img1.jpg',
      );
      expect(
        File(p.join(temp.path, 'trip_003.JPG')).readAsStringSync(),
        'img10.JPG',
      );
    });

    test('reports each pair', () {
      final a = touch('a.jpg');

      final result = albumRenameImages(paths: [a], prefix: 'x');

      expect(result.renamed.single.from, a);
      expect(result.renamed.single.to, p.join(temp.path, 'x_001.jpg'));
    });

    test('numbers every folder on its own', () {
      final paths = [
        touch('a.jpg'),
        touch('b.jpg'),
        touch(p.join('sub', 'c.jpg')),
        touch(p.join('sub', 'd.jpg')),
        touch(p.join('sub', 'e.jpg')),
      ];

      albumRenameImages(paths: paths, prefix: 'p');

      expect(names('.'), ['p_001.jpg', 'p_002.jpg']);
      expect(names('sub'), ['p_001.jpg', 'p_002.jpg', 'p_003.jpg']);
    });

    test('a file already called what it will get is not lost', () {
      // Naming 2 -> 1 and 1 -> 2 at once would overwrite without temp names.
      final paths = [touch('p_002.jpg', 'first'), touch('p_001.jpg', 'second')];

      final result = albumRenameImages(paths: paths, prefix: 'p');

      expect(result.errors, isEmpty);
      expect(names('.'), ['p_001.jpg', 'p_002.jpg']);
      expect(File(p.join(temp.path, 'p_001.jpg')).readAsStringSync(), 'second');
      expect(File(p.join(temp.path, 'p_002.jpg')).readAsStringSync(), 'first');
    });

    test('keeps both when a file left out already has the new name', () {
      final other = touch('p_001.txt', 'other');
      final a = touch('a.txt', 'mine');
      // Same extension as the one it would take.
      final result = albumRenameImages(paths: [a], prefix: 'p');

      expect(result.errors, isEmpty);
      expect(File(other).readAsStringSync(), 'other');
      expect(names('.').where((name) => name.endsWith('.txt')).length, 2);
    });

    test('leaves no temporary name behind', () {
      final paths = [touch('a.jpg'), touch('b.jpg')];

      albumRenameImages(paths: paths, prefix: 'z');

      expect(names('.').any((name) => name.contains('__image_album')), isFalse);
    });

    test('an empty prefix does nothing', () {
      final a = touch('a.jpg');

      final result = albumRenameImages(paths: [a], prefix: ' . ');

      expect(result.successCount, 0);
      expect(result.errors, isNotEmpty);
      expect(File(a).existsSync(), isTrue);
    });

    test('nothing to rename is fine', () {
      final result = albumRenameImages(paths: const [], prefix: 'p');

      expect(result.successCount, 0);
      expect(result.errors, isEmpty);
    });

    test('a file that is gone is reported and the rest go on', () {
      final a = touch('a.jpg');
      final gone = p.join(temp.path, 'gone.jpg');
      final c = touch('c.jpg');

      final result = albumRenameImages(paths: [a, gone, c], prefix: 'p');

      expect(result.failCount, 1);
      expect(result.errors.single, startsWith('gone.jpg'));
      expect(result.successCount, 2);
      expect(names('.'), ['p_001.jpg', 'p_002.jpg']);
    });

    test(
      'waits for a file something else lets go of a moment later',
      () async {
        final a = touch('a.jpg');
        final b = touch('b.jpg');
        // Held open, as a thumbnail being read or a scanner looking at it does.
        final held = File(a).openSync();
        Future<void>.delayed(const Duration(milliseconds: 500), held.closeSync);

        final result = await albumRenameImagesInBackground(
          paths: [a, b],
          prefix: 'w',
        );

        expect(result.errors, isEmpty);
        expect(names('.'), ['w_001.jpg', 'w_002.jpg']);
      },
      skip: Platform.isWindows
          ? false
          : 'only Windows refuses to rename an open file',
    );

    test(
      'a file held for good is reported by name and error number, and put back',
      () async {
        final a = touch('a.jpg');
        final b = touch('b.jpg');
        final held = File(a).openSync();
        addTearDown(held.closeSync);

        final result = await albumRenameImagesInBackground(
          paths: [a, b],
          prefix: 'w',
        );

        expect(result.failCount, 1);
        expect(result.errors.single, startsWith('a.jpg: '));
        expect(result.errors.single, matches(RegExp(r'\(error \d+\)$')));
        // The other one went ahead; the held one is where it was.
        expect(File(a).existsSync(), isTrue);
        expect(names('.'), ['a.jpg', 'w_001.jpg']);
      },
      skip: Platform.isWindows
          ? false
          : 'only Windows refuses to rename an open file',
    );

    test('runs on a background isolate too', () async {
      final paths = [touch('a.jpg'), touch('b.jpg')];

      final result = await albumRenameImagesInBackground(
        paths: paths,
        prefix: 'bg',
      );

      expect(result.successCount, 2);
      expect(names('.'), ['bg_001.jpg', 'bg_002.jpg']);
    });
  });
}
