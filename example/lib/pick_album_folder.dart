import 'dart:io';

import 'package:android_file_picker/android_file_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:windows_file_picker/windows_file_picker.dart';

/// Lets the user choose a folder and returns its path.
///
/// Windows opens the system folder dialog. Android opens the system
/// document-tree picker and returns a real directory path the album can
/// list. Returns null when the user cancels or access is denied.
Future<String?> pickAlbumFolder(BuildContext context) {
  if (Platform.isWindows) return _pickWindowsFolder(context);
  if (Platform.isAndroid) return _pickAndroidFolder(context);
  return _unsupported(context);
}

Future<String?> _pickWindowsFolder(BuildContext context) async {
  // The Windows implementation is a Dart plugin. Register it here so the
  // dialog is available even when the generated registrant has not run.
  FilePickerWindows.registerWith();
  try {
    // The dialog runs on another thread. Parenting it to the Flutter
    // window from that thread makes the dialog fail to show, so leave it
    // unowned.
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose a photo folder',
      windowsOptions: const FilePickerWindowsOptions(lockParentWindow: false),
    );
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
    return _usableFolder(context, path);
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
