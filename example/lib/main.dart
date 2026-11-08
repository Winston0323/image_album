import 'dart:io';
import 'dart:math';

import 'package:android_file_picker/android_file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_album/image_album.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:windows_file_picker/windows_file_picker.dart';

import 'pick_album_folder.dart';

/// Folder to open straight away, set with `--dart-define=ALBUM_PATH=...`.
/// Handy while developing; it is added to the folders already in the album.
const String _initialAlbumPath = String.fromEnvironment('ALBUM_PATH');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    FilePickerWindows.registerWith();
  } else if (Platform.isAndroid) {
    FilePickerAndroid.registerWith();
  }
  // The album file lives where the app keeps its own data, which the OS does
  // not clear the way it clears temporary files.
  final support = await getApplicationSupportDirectory();
  runApp(
    DemoApp(
      libraryDirectory: Directory(p.join(support.path, 'album')),
      albumPath: _initialAlbumPath.isEmpty ? null : _initialAlbumPath,
    ),
  );
}

/// Shows [ImageAlbum] for the folders the user adds.
///
/// The folders, the hidden subfolders and the caches are kept in an
/// [AlbumLibrary] in [libraryDirectory]. [albumPath] is added to it when given.
class DemoApp extends StatelessWidget {
  const DemoApp({super.key, required this.libraryDirectory, this.albumPath});

  final Directory libraryDirectory;
  final String? albumPath;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Image Album',
      debugShowCheckedModeBanner: false,
      theme: _theme(),
      builder: _scaleText,
      home: _AlbumHome(
        libraryDirectory: libraryDirectory,
        initialPath: albumPath,
      ),
    );
  }
}

class _AlbumHome extends StatefulWidget {
  const _AlbumHome({required this.libraryDirectory, this.initialPath});

  final Directory libraryDirectory;
  final String? initialPath;

  @override
  State<_AlbumHome> createState() => _AlbumHomeState();
}

class _AlbumHomeState extends State<_AlbumHome> {
  AlbumLibrary? _library;
  final GlobalKey<ImageAlbumState> _albumKey = GlobalKey();

  /// Thumbnails done and total while a background regenerate is running, or
  /// null when idle.
  (int, int)? _regenProgress;

  /// Whether the album has had a folder this session. Until it has, no folders
  /// means the welcome screen. After, it means the album's own invitation to
  /// add one, so removing the last folder does not swap the screen out from
  /// under an open folder sheet.
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final library = await AlbumLibrary.open(widget.libraryDirectory);
    final initial = widget.initialPath;
    if (initial != null) await library.addSource(initial);
    if (!mounted) {
      library.dispose();
      return;
    }
    library.addListener(_changed);
    setState(() {
      _library = library;
      _started = library.sources.isNotEmpty;
    });
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _library?.removeListener(_changed);
    _library?.dispose();
    super.dispose();
  }

  void _tell(SnackBar bar) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(bar);
  }

  Future<void> _importFromWelcome() async {
    final path = await pickAlbumFolder(context);
    if (!mounted || path == null) return;
    final kind = await askAlbumFolderKind(context, path);
    if (!mounted || kind == null) return;
    if (kind == AlbumFolderKind.film) {
      await _library?.setFilmLibrary(path);
      if (mounted) setState(() => _started = true);
      return;
    }
    await _addDigital(path);
  }

  Future<void> _addDigital(String path) async {
    final library = _library;
    if (library == null || !mounted) return;
    try {
      if (await library.addSource(path)) {
        setState(() => _started = true);
      } else {
        _tell(const SnackBar(content: Text('That folder is already here.')));
      }
    } on FileSystemException {
      _tell(const SnackBar(content: Text('Could not save the album file.')));
    }
  }

  Future<void> _removeSource(String path) async {
    final library = _library;
    if (library == null) return;
    final before = library.sources;
    final index = before.indexWhere((source) => p.equals(source, path));
    if (index < 0) return;
    final removed = before[index];
    await library.removeSource(path);
    if (!mounted) return;
    _tell(
      SnackBar(
        content: Text('Removed ${p.basename(removed)}'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            final now = library.sources;
            if (now.any((source) => p.equals(source, removed))) return;
            library.setSources(
              [...now]..insert(min(index, now.length), removed),
            );
          },
        ),
      ),
    );
  }

  Future<void> _showCache() async {
    final library = _library;
    if (library == null) return;
    final usage = await library.cacheUsage();
    if (!mounted) return;
    final choice = await showDialog<_CacheAction>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Cache'),
        content: Text(
          '${usage.thumbnailCount} thumbnails, ${_size(usage.thumbnailBytes)}\n'
          '${usage.indexCount} folder indexes, ${_size(usage.indexBytes)}\n\n'
          'Thumbnails keep the grid quick and the indexes show a folder at '
          'once when it is opened again. Both are rebuilt as needed.\n\n'
          'Regenerate makes every thumbnail again, for when they look wrong.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _CacheAction.clear),
            child: const Text('Clear cache'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _CacheAction.regenerate),
            child: const Text('Regenerate'),
          ),
        ],
      ),
    );
    if (choice == _CacheAction.clear) {
      try {
        await library.clearCaches();
      } catch (_) {}
      if (mounted) {
        _tell(const SnackBar(content: Text('Cache cleared.')));
      }
    } else if (choice == _CacheAction.regenerate) {
      _regenerateInBackground();
    }
  }

  void _regenerateInBackground() {
    final album = _albumKey.currentState;
    if (album == null || _regenProgress != null) return;
    setState(() => _regenProgress = (0, 0));
    album
        .regenerateCache(
          onProgress: (done, total) {
            if (!mounted) return;
            final current = _regenProgress;
            // Skip rebuilds that do not move the bar by a visible amount.
            if (current != null &&
                total == current.$2 &&
                total > 0 &&
                (done - current.$1) * 40 < total &&
                done < total) {
              return;
            }
            setState(() => _regenProgress = (done, total));
          },
          cancelled: () => !mounted,
        )
        .then((made) {
          if (!mounted) return;
          _tell(
            SnackBar(content: Text('Cache regenerated: $made thumbnails.')),
          );
        })
        .whenComplete(() {
          if (mounted) setState(() => _regenProgress = null);
        });
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1 << 20) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  }

  String get _subtitle {
    final sources = _library?.sources ?? const <String>[];
    return switch (sources.length) {
      0 => 'No folders',
      1 =>
        p.basename(sources.single).isEmpty
            ? sources.single
            : p.basename(sources.single),
      final n => '$n folders',
    };
  }

  @override
  Widget build(BuildContext context) {
    final library = _library;
    // The album file is read before anything is shown, so neither the welcome
    // screen nor folders hidden last time flash up.
    if (library == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (library.sources.isEmpty && !_started) {
      return _Welcome(onChoose: _importFromWelcome);
    }

    return ImageAlbum(
      key: _albumKey,
      paths: library.sources,
      recursive: true,
      library: library,
      initialExcludedFolders: library.excluded,
      onExcludedFoldersChanged: (excluded) => library.setExcluded(excluded),
      initialFileTypes: library.fileTypes,
      onFileTypesChanged: (types) => library.setFileTypes(types),
      onImportDigital: _addDigital,
      onRemoveSource: _removeSource,
      pickFolder: ([initial]) => pickAlbumFolder(
        context,
        initialDirectory: initial ?? _library?.filmLibrary,
      ),
      filmLibraryPath: library.filmLibrary,
      onFilmLibraryChanged: (path) {
        library.setFilmLibrary(path);
        setState(() => _started = true);
      },
      actions: [
        if (_regenProgress case final progress?)
          Tooltip(
            message: progress.$2 == 0
                ? 'Regenerating cache…'
                : 'Regenerating ${progress.$1} of ${progress.$2}',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 96,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    LinearProgressIndicator(
                      value: progress.$2 == 0
                          ? null
                          : progress.$1 / progress.$2,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      progress.$2 == 0 ? '…' : '${progress.$1}/${progress.$2}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        IconButton(
          tooltip: 'Cache',
          onPressed: _showCache,
          icon: const Icon(Icons.storage_outlined),
        ),
      ],
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Image Album'),
          Text(
            _subtitle,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).hintColor,
            ),
          ),
        ],
      ),
    );
  }
}

enum _CacheAction { clear, regenerate }

/// How much larger than Material's default type scale the demo sets its text.
/// The default is tuned for phones held close; on a desktop monitor it reads
/// small.
const double _textScale = 1.2;

/// Dark, photo-friendly theme: a near-black surface so pictures carry the
/// color, with an amber accent for selection and actions.
ThemeData _theme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFFF5A623),
        brightness: Brightness.dark,
      ).copyWith(
        surface: const Color(0xFF121214),
        // Neutral greys: the amber seed would otherwise tint every container
        // brown, which muddies the photos sitting next to them.
        surfaceContainerLow: const Color(0xFF18181B),
        surfaceContainer: const Color(0xFF1C1C20),
        surfaceContainerHigh: const Color(0xFF242429),
        surfaceContainerHighest: const Color(0xFF2E2E34),
      );
  final theme = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20 * _textScale,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
  );
  return theme;
}

/// Wraps the app's screens in a theme whose type scale is [_textScale] times
/// Material's. It has to be done here, under [MaterialApp]: before that, the
/// theme's text styles have no sizes yet to multiply.
Widget _scaleText(BuildContext context, Widget? child) {
  final theme = Theme.of(context);
  return Theme(
    data: theme.copyWith(
      textTheme: theme.textTheme.apply(fontSizeFactor: _textScale),
    ),
    child: child!,
  );
}

/// First screen, before a folder is chosen.
class _Welcome extends StatelessWidget {
  const _Welcome({required this.onChoose});

  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.3),
            radius: 1.0,
            colors: [scheme.primary.withValues(alpha: 0.14), scheme.surface],
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 112,
                    height: 112,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.primary.withValues(alpha: 0.16),
                      border: Border.all(
                        color: scheme.primary.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Icon(
                      Icons.photo_library_rounded,
                      size: 52,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    'Image Album',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Pick a folder and browse its photos by day. Add more folders any time.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed: onChoose,
                    icon: const Icon(Icons.folder_open_rounded),
                    label: const Text('Choose a folder'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
