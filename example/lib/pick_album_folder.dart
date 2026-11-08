import 'dart:io';

import 'package:android_file_picker/android_file_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

/// Lets the user choose a folder and returns its path.
///
/// Windows opens the system folder dialog. Android opens the system
/// document-tree picker and returns a real directory path the album can
/// list. Returns null when the user cancels or access is denied.
/// The last folder this picker showed. The system folder window is not used
/// on Windows: it reports that it cannot open a folder after that folder is
/// renamed, and then refuses to open at all.
String? _lastFolder;

Future<String?> pickAlbumFolder(
  BuildContext context, {
  String? initialDirectory,
}) {
  if (Platform.isWindows) {
    return _pickWindowsFolder(context, initialDirectory: initialDirectory);
  }
  if (Platform.isAndroid) return _pickAndroidFolder(context);
  return _unsupported(context);
}

/// [preferred] if it exists, otherwise the nearest parent that does.
Future<String?> _existingDirectory(String? preferred) async {
  var current = preferred ?? _lastFolder;
  while (current != null && current.isNotEmpty) {
    if (await Directory(current).exists()) return current;
    final parent = p.dirname(current);
    if (parent == current) break;
    current = parent;
  }
  return null;
}

Future<String?> _pickWindowsFolder(
  BuildContext context, {
  String? initialDirectory,
}) async {
  final start =
      await _existingDirectory(initialDirectory) ??
      Platform.environment['USERPROFILE'] ??
      r'C:\';
  if (!context.mounted) return null;
  final path = await showDialog<String>(
    context: context,
    builder: (context) => _WindowsFolderDialog(start: start),
  );
  if (path != null && path.isNotEmpty) _lastFolder = path;
  if (!context.mounted) return null;
  return _usableFolder(context, path);
}

Future<String?> _pickAndroidFolder(BuildContext context) async {
  FilePickerAndroid.registerWith();
  final allowed = await _allowAndroidFolderRead(context);
  if (!allowed || !context.mounted) return null;

  try {
    // FilePickerAndroidOptions makes the plugin return a content URI.
    // The album lists a directory with dart:io, so ask for a file path.
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose a photo folder',
      androidOptions: const AndroidOptions(),
    );
    if (!context.mounted) return null;
    return await _usableFolder(context, path);
  } on Exception catch (error) {
    if (!context.mounted) return null;
    await _tell(context, 'Could not open the folder picker.\n$error');
    return null;
  }
}

Future<String?> _unsupported(BuildContext context) async {
  await _tell(
    context,
    'Choosing a folder is available on Windows and Android.',
  );
  return null;
}

Future<bool> _allowAndroidFolderRead(BuildContext context) async {
  final allFiles = await Permission.manageExternalStorage.status;
  if (allFiles.isGranted) return true;

  // All-files access does not exist before Android 11. The storage
  // permission is enough to list a folder on those versions.
  if (allFiles.isRestricted) {
    final storage = await Permission.storage.request();
    if (storage.isGranted) return true;
    final photos = await Permission.photos.request();
    return photos.isGranted || photos.isLimited;
  }

  if (!context.mounted) return false;
  final proceed = await _confirm(
    context,
    title: 'Folder access',
    message:
        'Android needs all-files access so this demo can list the images in the folder you pick.',
    confirm: 'Continue',
  );
  if (!proceed || !context.mounted) return false;

  final requested = await Permission.manageExternalStorage.request();
  if (requested.isGranted) return true;

  if (!context.mounted) return false;
  final openSettings = await _confirm(
    context,
    title: 'Folder access',
    message:
        'All-files access was not granted. Allow it for this app in system settings, then choose a folder again.',
    confirm: 'Open settings',
  );
  if (openSettings) await openAppSettings();
  return false;
}

Future<String?> _usableFolder(BuildContext context, String? path) async {
  if (path == null || path.isEmpty) return null;
  if (path.startsWith('content:')) {
    await _tell(
      context,
      'Android did not return a folder path this app can read. Pick a folder on internal storage.',
    );
    return null;
  }

  try {
    if (await Directory(path).exists()) return path;
  } on FileSystemException catch (error) {
    if (!context.mounted) return null;
    await _tell(context, 'Could not read that folder.\n$error');
    return null;
  }

  if (!context.mounted) return null;
  await _tell(context, 'That folder is not available.\n$path');
  return null;
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirm,
}) async {
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return accepted ?? false;
}

/// Lists folders in the app. A click selects one. The arrow opens it.
class _WindowsFolderDialog extends StatefulWidget {
  const _WindowsFolderDialog({required this.start});

  final String start;

  @override
  State<_WindowsFolderDialog> createState() => _WindowsFolderDialogState();
}

class _WindowsFolderDialogState extends State<_WindowsFolderDialog> {
  /// Null lists the drives.
  String? _current;
  String? _selected;
  late Future<List<String>> _entries;

  @override
  void initState() {
    super.initState();
    _show(widget.start);
  }

  void _show(String? path) {
    _current = path;
    _selected = null;
    _entries = path == null ? _drives() : _folders(path);
  }

  void _go(String? path) => setState(() => _show(path));

  void _up() {
    final current = _current;
    if (current == null) return;
    final parent = p.dirname(current);
    _go(parent == current ? null : parent);
  }

  Future<List<String>> _folders(String path) async {
    final found = <String>[];
    await for (final entity in Directory(path).list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      found.add(entity.path);
    }
    found.sort(
      (a, b) =>
          p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()),
    );
    return found;
  }

  Future<List<String>> _drives() async {
    final found = <String>[];
    for (var code = 65; code <= 90; code++) {
      final root = '${String.fromCharCode(code)}:\\';
      if (await Directory(root).exists()) found.add(root);
    }
    return found;
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final chosen = _selected ?? current;
    return Dialog(
      child: SizedBox(
        width: 520,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Up',
                    onPressed: current == null ? null : _up,
                    icon: const Icon(Icons.arrow_upward_rounded),
                  ),
                  Expanded(
                    child: Text(
                      current ?? 'This PC',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder<List<String>>(
                future: _entries,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        'This folder cannot be read.\n${snapshot.error}',
                      ),
                    );
                  }
                  final entries = snapshot.data ?? const <String>[];
                  if (entries.isEmpty) {
                    return const Center(child: Text('No folders here'));
                  }
                  return ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final path = entries[index];
                      final name = current == null ? path : p.basename(path);
                      return ListTile(
                        selected: path == _selected,
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: 'Open',
                          icon: const Icon(Icons.chevron_right_rounded),
                          onPressed: () => _go(path),
                        ),
                        onTap: () => setState(() => _selected = path),
                      );
                    },
                  );
                },
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: chosen == null
                        ? null
                        : () => Navigator.of(context).pop(chosen),
                    child: const Text('Use this folder'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _tell(BuildContext context, String message) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
