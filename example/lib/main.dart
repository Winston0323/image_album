import 'dart:io';

import 'package:android_file_picker/android_file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_album/image_album.dart';
import 'package:path/path.dart' as p;
import 'package:windows_file_picker/windows_file_picker.dart';

import 'pick_album_folder.dart';

void main() {
  if (Platform.isWindows) {
    FilePickerWindows.registerWith();
  } else if (Platform.isAndroid) {
    FilePickerAndroid.registerWith();
  }
  runApp(const DemoApp());
}

/// Shows [ImageAlbum] for a folder the user picks.
///
/// [albumPath] opens that folder immediately and skips the first picker.
class DemoApp extends StatelessWidget {
  const DemoApp({super.key, this.albumPath});

  final String? albumPath;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Image Album',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFF5A623),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: _AlbumHome(initialPath: albumPath),
    );
  }
}

class _AlbumHome extends StatefulWidget {
  const _AlbumHome({this.initialPath});

  final String? initialPath;

  @override
  State<_AlbumHome> createState() => _AlbumHomeState();
}

class _AlbumHomeState extends State<_AlbumHome> {
  String? _path;
  bool _recursive = false;

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
  }

  Future<void> _chooseFolder() async {
    final path = await pickAlbumFolder(context);
    if (!mounted || path == null) return;
    setState(() => _path = path);
  }

  @override
  Widget build(BuildContext context) {
    final path = _path;
    if (path == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Image Album')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.photo_library_outlined,
                  size: 56,
                  color: Theme.of(context).disabledColor,
                ),
                const SizedBox(height: 16),
                Text(
                  'Choose a folder of photos',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _chooseFolder,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Choose a folder'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final folder = p.basename(path);
    return ImageAlbum(
      key: ValueKey(path),
      path: path,
      recursive: _recursive,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Image Album'),
          Text(
            folder.isEmpty ? path : folder,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).hintColor,
                ),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: _recursive ? 'This folder only' : 'Include subfolders',
          isSelected: _recursive,
          onPressed: () => setState(() => _recursive = !_recursive),
          icon: const Icon(Icons.account_tree_outlined),
          selectedIcon: const Icon(Icons.account_tree),
        ),
        IconButton(
          tooltip: 'Choose folder',
          onPressed: _chooseFolder,
          icon: const Icon(Icons.folder_open),
        ),
      ],
    );
  }
}
