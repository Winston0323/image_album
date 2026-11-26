import 'dart:io';

import 'package:android_file_picker/android_file_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:windows_file_picker/windows_file_picker.dart';

/// Lets the user choose a folder and returns its path.
///
/// Windows opens the system folder dialog. Android opens the system
/// document-tree picker and returns a real directory path the album can
/// list. Returns null when the user cancels or access is denied.
/// The last folder this picker showed, used as the fallback start location.
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

  // Windows：注册 file_picker 的实现后打开系统自带的文件夹选择对话框
  // （IFileOpenDialog + FOS_PICKFOLDERS，资源管理器风格）。
  FilePickerWindows.registerWith();
  try {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose a photo folder',
      initialDirectory: start,
    );
    if (path != null && path.isNotEmpty) _lastFolder = path;
    if (!context.mounted) return null;
    return _usableFolder(context, path);
  } on Exception catch (error) {
    if (!context.mounted) return null;
    await _tell(context, 'Could not open the folder picker.\n$error');
    return null;
  }
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

/// Lets the user choose a file, such as a zip of film scans.
Future<String?> pickAlbumFile(
  BuildContext context, {
  String? dialogTitle,
  List<String>? extensions,
}) async {
  if (Platform.isWindows) {
    FilePickerWindows.registerWith();
  } else if (Platform.isAndroid) {
    FilePickerAndroid.registerWith();
  } else {
    await _tell(
      context,
      'Choosing a file is available on Windows and Android.',
    );
    return null;
  }
  try {
    final files = await FilePicker.pickFiles(
      dialogTitle: dialogTitle ?? 'Choose a file',
      type: extensions == null || extensions.isEmpty
          ? FileType.any
          : FileType.custom,
      allowedExtensions: extensions == null || extensions.isEmpty
          ? null
          : extensions,
    );
    if (!context.mounted) return null;
    if (files.isEmpty) return null;
    final path = files.first.path;
    if (path == null || path.isEmpty) return null;
    if (!await File(path).exists()) {
      if (!context.mounted) return null;
      await _tell(context, 'That file is not available.\n$path');
      return null;
    }
    return path;
  } on Exception catch (error) {
    if (!context.mounted) return null;
    await _tell(context, 'Could not open the file picker.\n$error');
    return null;
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
