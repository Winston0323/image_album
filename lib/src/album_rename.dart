import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// One file renamed: [from] became [to], both absolute paths.
class AlbumRenamePair {
  const AlbumRenamePair(this.from, this.to);

  final String from;
  final String to;
}

/// What [albumRenameImages] did: the files renamed, and a line for each one
/// that could not be.
class AlbumRenameResult {
  const AlbumRenameResult({required this.renamed, required this.errors});

  final List<AlbumRenamePair> renamed;
  final List<String> errors;

  int get successCount => renamed.length;
  int get failCount => errors.length;
}

/// [raw] made safe to put in a file name: surrounding space dropped, the
/// characters Windows forbids and runs of whitespace turned into `_`, and no
/// trailing dots or spaces, which Windows does not allow either.
String albumSanitizePrefix(String raw) {
  var text = raw.trim();
  text = text.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  text = text.replaceAll(RegExp(r'\s+'), '_');
  text = text.replaceAll(RegExp(r'[. ]+$'), '');
  return text;
}

/// The number put in a name, 1-based, padded to line up with the others: three
/// digits, or as many as the count needs beyond 999.
String albumOrderLabel(int index, int total) {
  final width = total < 1000 ? 3 : total.toString().length;
  return index.toString().padLeft(width, '0');
}

/// Compares the file names of two paths with numbers read as numbers, so
/// `img2` comes before `img10`. Only the order is taken from this: the number
/// a file is given is always its place in the sequence.
int albumCompareNames(String pathA, String pathB) {
  final a = p.basename(pathA);
  final b = p.basename(pathB);
  final partsA = RegExp(r'\d+|\D+').allMatches(a).iterator;
  final partsB = RegExp(r'\d+|\D+').allMatches(b).iterator;
  while (true) {
    final hasA = partsA.moveNext();
    final hasB = partsB.moveNext();
    if (!hasA && !hasB) return a.toLowerCase().compareTo(b.toLowerCase());
    if (!hasA) return -1;
    if (!hasB) return 1;
    final textA = partsA.current.group(0)!;
    final textB = partsB.current.group(0)!;
    final numberA = int.tryParse(textA);
    final numberB = int.tryParse(textB);
    if (numberA != null && numberB != null) {
      final byValue = numberA.compareTo(numberB);
      if (byValue != 0) return byValue;
      // Same value: the shorter run of digits first, so 2 comes before 02.
      final byLength = textA.length.compareTo(textB.length);
      if (byLength != 0) return byLength;
    } else {
      final byText = textA.toLowerCase().compareTo(textB.toLowerCase());
      if (byText != 0) return byText;
    }
  }
}

/// Renames [paths] to `prefix_001.ext`, `prefix_002.ext` and so on.
///
/// The files are grouped by the folder they are in, and each folder is
/// numbered on its own: its files are put in natural name order and given 1 to
/// N, however they were named before. The extension, in its own case, stays.
///
/// It is done in two passes through temporary names, so a file is never
/// written over another, not even one that already has the name it is about
/// to get. A file that cannot be renamed is put back as it was and reported;
/// the others still go ahead.
///
/// This does blocking file work. Use [albumRenameImagesInBackground] from
/// the UI.
AlbumRenameResult albumRenameImages({
  required List<String> paths,
  required String prefix,
}) {
  final clean = albumSanitizePrefix(prefix);
  if (clean.isEmpty) {
    return const AlbumRenameResult(renamed: [], errors: ['Prefix is empty']);
  }
  if (paths.isEmpty) {
    return const AlbumRenameResult(renamed: [], errors: []);
  }

  final byFolder = <String, List<String>>{};
  for (final path in paths) {
    byFolder.putIfAbsent(p.normalize(p.dirname(path)), () => []).add(path);
  }
  final folders = byFolder.keys.toList()..sort();
  for (final group in byFolder.values) {
    group.sort(albumCompareNames);
  }
  final ordered = [for (final folder in folders) ...byFolder[folder]!];

  final errors = <String>[];
  final renamed = <AlbumRenamePair>[];
  final stamp = DateTime.now().microsecondsSinceEpoch;

  // After a few files that stay busy for the whole wait, it is not a passing
  // lock but a folder that refuses, and waiting on every other file would
  // only make the user wait.
  var giveUps = 0;

  // First every file gets a name nobody else can have.
  final temps = <String?>[];
  for (var i = 0; i < ordered.length; i++) {
    final from = ordered[i];
    final temp = p.join(
      p.dirname(from),
      '__image_album_rename_${stamp}_$i${p.extension(from)}',
    );
    try {
      _renameFile(from, temp, attempts: giveUps >= 3 ? 1 : _busyAttempts);
      temps.add(temp);
    } on FileSystemException catch (error) {
      if (_isBusy(error)) giveUps++;
      errors.add(_describe(from, error));
      temps.add(null);
    }
  }

  // Then each takes its place in the sequence of its folder.
  final counts = <String, int>{};
  for (var i = 0; i < ordered.length; i++) {
    final temp = temps[i];
    if (temp == null) continue;
    final folder = p.normalize(p.dirname(temp));
    final place = (counts[folder] ?? 0) + 1;
    counts[folder] = place;
    final label = albumOrderLabel(place, byFolder[folder]!.length);
    var to = p.join(folder, '${clean}_$label${p.extension(temp)}');
    // Taken by a file this did not touch: keep both rather than lose either.
    if (File(to).existsSync()) {
      to = p.join(folder, '${clean}_${label}_$stamp${p.extension(temp)}');
    }
    try {
      _renameFile(temp, to, attempts: giveUps >= 3 ? 1 : _busyAttempts);
      renamed.add(AlbumRenamePair(ordered[i], to));
    } on FileSystemException catch (error) {
      if (_isBusy(error)) giveUps++;
      errors.add(_describe(ordered[i], error));
      try {
        _renameFile(temp, ordered[i], attempts: 3);
      } on FileSystemException {
        // Left under its temporary name; nothing more can be done.
      }
    }
  }
  return AlbumRenameResult(renamed: renamed, errors: errors);
}

/// Windows errors that mean "not now" more often than "never": access denied
/// (a virus scanner, the indexer or an Explorer preview holding the file for
/// a moment), a sharing or lock violation, and a file mapped by another
/// program.
const _busyErrors = {5, 32, 33, 1224};

/// How long a file that is busy is waited for, in all.
const _busyAttempts = 25;
const _busyPause = Duration(milliseconds: 120);

/// Renames [from] to [to], trying again for a few seconds while the file is
/// held by something else. Throws the last error when it never lets go.
void _renameFile(String from, String to, {int attempts = _busyAttempts}) {
  for (var attempt = 1; ; attempt++) {
    try {
      File(from).renameSync(to);
      return;
    } on FileSystemException catch (error) {
      if (!_isBusy(error) || attempt >= attempts) rethrow;
      sleep(_busyPause);
    }
  }
}

bool _isBusy(FileSystemException error) =>
    Platform.isWindows && _busyErrors.contains(error.osError?.errorCode);

/// What went wrong with [path], in a line: its name, the system's reason, and
/// the number Windows gave it, which is what to search for.
String _describe(String path, FileSystemException error) {
  final reason = error.osError?.message.trim();
  final code = error.osError?.errorCode;
  final text = reason == null || reason.isEmpty ? error.message : reason;
  return '${p.basename(path)}: $text${code == null ? '' : ' (error $code)'}';
}

/// [albumRenameImages] on a background isolate, so thousands of files do not
/// hold up the UI.
Future<AlbumRenameResult> albumRenameImagesInBackground({
  required List<String> paths,
  required String prefix,
}) => Isolate.run(() => albumRenameImages(paths: paths, prefix: prefix));
