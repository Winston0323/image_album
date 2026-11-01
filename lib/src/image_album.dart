import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'album_camera.dart';
import 'album_drag_select.dart';
import 'album_folders.dart';
import 'album_import_page.dart';
import 'album_library.dart';
import 'album_photo.dart';
import 'album_preview_page.dart';
import 'album_rename.dart';
import 'album_rename_dialog.dart';
import 'album_widgets.dart';

/// Asks whether [count] selected photos should be deleted. Return true to
/// delete the files.
typedef ConfirmAlbumDelete =
    Future<bool> Function(BuildContext context, int count);

/// Asks whether the folder called [folderName], holding [count] photos with
/// those of the folders inside it, should be deleted. Return true to delete.
typedef ConfirmAlbumFolderDelete =
    Future<bool> Function(BuildContext context, String folderName, int count);

/// About how wide a grid tile gets, in logical pixels. Three columns fit on
/// phones up to about 420 dp; beyond that columns are added instead of growing
/// tiles. The columns share the width evenly, so a tile can be a hair wider.
const double albumTileMaxExtent = 140;

/// Full-screen album of the images in one or more source folders.
///
/// Pass one folder as [path], or several as [paths]; their photos are merged
/// into a single grid grouped by day, newest first. Tiles are about
/// [albumTileMaxExtent] wide at most, so a phone gets three columns and a wider
/// window gets proportionally more. Tap a tile to open the swipe preview.
/// Set [recursive] to include subfolders.
///
/// To select photos, then delete them:
///
/// * Click a tile's check mark, or long-press a tile.
/// * Ctrl-click (cmd-click) picks or unpicks one photo; shift-click picks
///   the range from the last pick, and ctrl+shift-click adds that range to
///   what is already picked.
/// * Press the mouse on a tile and drag to pick every tile the pointer goes
///   over, or on a picked tile to unpick them. On a touch screen, long-press
///   and keep the finger down. The grid scrolls when the pointer reaches its
///   top or bottom edge.
/// * Ctrl+A (cmd+A) picks everything and Escape lets go.
///
/// The album does not choose folders itself. Give it [onAddSource] and
/// [onRemoveSource] and the folder panel offers to add and remove sources;
/// the app picks the folder, changes [paths], and passes the new list in.
/// Sources already scanned are kept, so adding one only scans the new folder.
///
/// Own scroll controller, with `primary: false`, so the album can sit in an
/// [IndexedStack] beside other scrollables without sharing the ambient
/// [PrimaryScrollController].
class ImageAlbum extends StatefulWidget {
  const ImageAlbum({
    super.key,
    this.path,
    this.paths,
    this.title = const Text('Album'),
    this.actions = const [],
    this.empty,
    this.countLabel,
    this.confirmDelete,
    this.confirmDeleteFolder,
    this.revealFolder,
    this.cameraCards,
    this.pickFolder,
    this.recursive = false,
    this.initialExcludedFolders = const {},
    this.onExcludedFoldersChanged,
    this.initialFileTypes = const {},
    this.onFileTypesChanged,
    this.onAddSource,
    this.onRemoveSource,
    this.library,
    this.useCatalog = true,
  }) : assert(
         (path == null) != (paths == null),
         'Pass either path or paths, not both',
       );

  /// The one folder whose image files are shown. Use [paths] for several.
  /// See [loadAlbumPhotos].
  final String? path;

  /// The folders whose image files are shown together. May be empty, which
  /// shows an invitation to add one when [onAddSource] is set.
  final List<String>? paths;

  /// Every source folder, however they were given.
  List<String> get sources => paths ?? [path!];

  /// When true, images in subfolders of each source are included, and a
  /// folder tree lets the user hide any of them. Links are not followed.
  /// Defaults to false, which lists only files directly in each source.
  final bool recursive;

  /// The album file whose caches to use. With it, a folder opened before shows
  /// its photos at once from the saved index while the folder is checked again,
  /// thumbnails are kept in the file and made to its [AlbumLibrary.cache]
  /// options, and each scan is recorded in it. Without, the caches live in the
  /// system temp directory, which the OS may clear.
  ///
  /// The album only uses the library's caches. Which folders to show and which
  /// to hide still come from [paths] and [initialExcludedFolders]; keep them
  /// in the library with [AlbumLibrary.addSource] and friends if you like.
  final AlbumLibrary? library;

  /// Keeps a hidden catalog, [albumCatalogName], in each source folder: an
  /// index of its photos that opens the folder at once and spares most of the
  /// work of checking it again. It travels with the folder and can be deleted
  /// at any time. Set to false to leave the folders untouched, for instance
  /// when they are read-only.
  ///
  /// Photos edited in place, keeping their name, are picked up when the
  /// catalog is a day old or the album is refreshed. See [loadAlbumPhotos].
  final bool useCatalog;

  /// Called when the user asks to add a source folder. Set it, with
  /// [onRemoveSource], to let the user manage sources from the folder panel.
  final VoidCallback? onAddSource;

  /// Called with a source's path when the user asks to remove it. The album
  /// keeps showing it until [paths] no longer lists it.
  final ValueChanged<String>? onRemoveSource;

  /// Folders hidden when the album opens: their photos, and those in folders
  /// below them, are left out. Paths as [onExcludedFoldersChanged] reports
  /// them. Read when the album is created; after that the user's choices in
  /// the folder tree take over. Paths are absolute, so one set serves every
  /// source.
  final Set<String> initialExcludedFolders;

  /// Called with the full set of hidden folders each time the user changes it,
  /// so the choice can be saved and passed back as [initialExcludedFolders]
  /// next time.
  final ValueChanged<Set<String>>? onExcludedFoldersChanged;

  /// The file types shown when the album opens, as [albumFileType] labels
  /// such as `JPG` and `PNG`. Empty shows every type. Read when the album is
  /// created; after that the user's choice in the filter bar takes over.
  final Set<String> initialFileTypes;

  /// Called with the chosen file types each time the user changes them, so
  /// the choice can be saved and passed back as [initialFileTypes] next time.
  /// An empty set means every type.
  final ValueChanged<Set<String>>? onFileTypesChanged;

  /// App-bar title while nothing is selected.
  final Widget title;

  /// App-bar actions while nothing is selected. Selection mode replaces the
  /// bar with cancel, select-all, and delete.
  final List<Widget> actions;

  /// Shown when [path] contains no images. Defaults to a short empty message.
  /// Wrapped in a scroll view so pull-to-refresh still works.
  final Widget? empty;

  /// Replaces the "N photos" line above the grid.
  final String Function(int count)? countLabel;

  /// Confirmation before selected files are deleted. When null, a generic
  /// dialog is shown. Return false to leave the files in place.
  final ConfirmAlbumDelete? confirmDelete;

  /// Confirmation before a folder is deleted from the folder panel's menu.
  /// When null, a generic dialog is shown. Return false to leave it alone.
  ///
  /// Deleting a folder deletes the photos in it and in the folders below it,
  /// then removes each of those folders that has nothing else left in it. A
  /// folder that still holds other files stays, with just those files.
  final ConfirmAlbumFolderDelete? confirmDeleteFolder;

  /// Opens a folder, by its path, in the system's file manager, for the
  /// "Show in Explorer" entry of the folder panel's menu. When null the entry
  /// is there on Windows only, and opens Explorer on the folder. Set it to
  /// add the entry on other platforms, or to open the folder some other way.
  final Future<void> Function(String path)? revealFolder;

  /// The drives "Import from camera…" reads, as `D:\`. Only removable drives
  /// are included. When null the album asks Windows for them. Tests pass a
  /// list of their own folders.
  final Future<List<String>> Function()? cameraCards;

  /// Asks for a folder when "Choose a folder" is used on the import page.
  /// When null, Windows opens its folder dialog. Return null when cancelled.
  final Future<String?> Function()? pickFolder;

  @override
  State<ImageAlbum> createState() => ImageAlbumState();
}

class ImageAlbumState extends State<ImageAlbum> {
  final ScrollController _gridController = ScrollController();
  final ScrollController _fillerController = ScrollController();

  List<AlbumDaySection> _sections = const [];

  /// Every photo in grid order. Kept beside [_sections] rather than rebuilt in
  /// [build], which runs on every selection change and scan batch.
  List<AlbumPhoto> _flatPhotos = const [];

  /// Everything found in all sources, before hidden folders are taken out.
  List<AlbumPhoto> _allPhotos = const [];

  /// File types picked in the filter bar, as [albumFileType] labels. Empty
  /// shows them all.
  Set<String> _types = {};

  /// How many photos of each type the shown folders hold, whatever the filter.
  /// Feeds the filter bar.
  Map<String, int> _typeCounts = const {};

  /// Photos in the shown folders, before the type filter.
  int _inShownFolders = 0;

  /// What each source's scan has found so far, hidden folders not yet taken
  /// out, newest first. Kept per source so that hiding a folder is instant, a
  /// dropped source needs no rescan of the others, and a hidden folder is only
  /// looked for inside the source it was chosen in.
  final Map<String, List<AlbumPhoto>> _found = {};

  /// Why each source that could not be read failed.
  final Map<String, String> _errors = {};

  /// The source folders as normalized paths, in the order given.
  late List<String> _sources;

  /// Normalized paths of the hidden folders.
  late Set<String> _excluded;

  List<AlbumFolderNode>? _trees;
  bool _treeStale = true;
  final Stopwatch _treeAge = Stopwatch();

  /// Bumped whenever the folder panel's inputs change, so a panel shown in a
  /// bottom sheet (a separate route) updates along with the grid.
  final ValueNotifier<int> _foldersRevision = ValueNotifier(0);

  /// Whether the user closed the side panel on a wide window.
  bool _panelHidden = false;

  /// The photos of the preview shown over the grid, or null with none open.
  /// Only used when the folder panel sits beside the grid: the preview then
  /// fills the room next to the panel, so the panel stays where it is until
  /// the user closes it. Otherwise the preview is a route of its own.
  List<AlbumPhoto>? _previewPhotos;
  int _previewIndex = 0;

  /// Tells one opening of the preview from the next, so a new one is built
  /// fresh rather than reusing the one that is fading out.
  int _previewSerial = 0;

  /// Normalized path of the folder the album is narrowed to, or null while it
  /// shows everything. Set by clicking a folder in the panel.
  String? _scope;

  /// Normalized path of the folder of the photo open in the preview, which the
  /// folder panel marks. It follows the preview as it moves between photos,
  /// and is cleared when the preview closes.
  String? _activeFolder;

  void _markFolderOf(AlbumPhoto photo) {
    final folder = p.normalize(p.dirname(photo.file.path));
    if (folder == _activeFolder) return;
    _activeFolder = folder;
    _foldersRevision.value++;
  }

  void _unmarkFolder() {
    if (_activeFolder == null) return;
    _activeFolder = null;
    _foldersRevision.value++;
  }

  /// Holds the keyboard for the album, and takes it back when a preview shown
  /// over the grid closes.
  final FocusNode _focus = FocusNode(debugLabel: 'ImageAlbum');

  bool _loading = true;
  String? _error;

  /// The scan running for each source. A scan whose token is no longer the
  /// one recorded here was replaced or cancelled, and its results are dropped.
  final Map<String, AlbumLoadToken> _scans = {};
  Timer? _progressTimer;

  /// Photos picked for deletion, by [AlbumPhoto.id]. Non-empty is what puts
  /// the screen in selection mode.
  final Set<String> _selected = {};

  /// The photo a shift-click selects a range from: the last one picked.
  String? _anchor;

  final GlobalKey<AlbumDragSelectState> _dragKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _sources = _normalizedSources();
    _excluded = _normalized(widget.initialExcludedFolders);
    _types = {
      for (final type in widget.initialFileTypes) type.trim().toUpperCase(),
    }..remove('');
    _startScans(_sources);
  }

  @override
  void didUpdateWidget(ImageAlbum oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sources = _normalizedSources();
    if (oldWidget.recursive != widget.recursive) {
      // Everything found so far was found the other way.
      _selected.clear();
      _sources = sources;
      _found.clear();
      _errors.clear();
      _startScans(_sources);
      _rebuildData();
      _trees = null;
    } else if (!_sameList(sources, _sources)) {
      final removed = _sources.where((s) => !sources.contains(s)).toList();
      final added = sources.where((s) => !_sources.contains(s)).toList();
      for (final source in removed) {
        _scans.remove(source)?.cancel();
        _found.remove(source);
        _errors.remove(source);
      }
      _sources = sources;
      // Sources that stay are not scanned again.
      _startScans(added);
      _rebuildData();
      _trees = null;
    } else {
      return;
    }
    // A folder sheet is on another route, which this rebuild does not reach.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _foldersRevision.value++;
    });
  }

  List<String> _normalizedSources() =>
      {for (final path in widget.sources) p.normalize(path)}.toList();

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Set<String> _normalized(Set<String> paths) => {
    for (final path in paths) p.normalize(path),
  };

  @override
  void dispose() {
    _progressTimer?.cancel();
    for (final scan in _scans.values) {
      scan.cancel();
    }
    _gridController.dispose();
    _fillerController.dispose();
    _foldersRevision.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Re-reads every source folder. Safe to call after files appear or
  /// disappear outside this widget.
  ///
  /// Every file is checked against the disk, so photos edited in place show
  /// up too, which a scan that trusts the folder's catalog would skip.
  Future<void> reload() {
    _errors.clear();
    final done = _startScans(_sources, verify: true);
    if (mounted) setState(_rebuildData);
    return done;
  }

  /// How long a folder's catalog is believed without checking its files again.
  static const Duration _trustCatalog = Duration(days: 1);

  /// Starts scanning [sources], replacing any scan already running for them.
  /// Completes when all of them have finished. With [verify] every file is
  /// checked, whatever the catalog says.
  Future<void> _startScans(Iterable<String> sources, {bool verify = false}) {
    final started = <Future<void>>[];
    for (final source in sources) {
      _scans.remove(source)?.cancel();
      _errors.remove(source);
      final token = AlbumLoadToken();
      _scans[source] = token;
      started.add(_scan(source, token, verify: verify));
    }
    _loading = _scans.isNotEmpty;
    _error = null;
    return Future.wait(started);
  }

  Future<void> _scan(
    String source,
    AlbumLoadToken token, {
    bool verify = false,
  }) async {
    final library = widget.library;
    final recursive = widget.recursive;
    final useCatalog = widget.useCatalog;
    try {
      // A folder seen before shows its photos at once, from the saved index,
      // which is the folder's own catalog when it has one.
      if ((library != null || useCatalog) &&
          (_found[source]?.isEmpty ?? true)) {
        final indexed = await readAlbumIndex(
          source,
          recursive: recursive,
          cacheDirectory: library?.indexDirectory,
          useCatalog: useCatalog,
        );
        if (!mounted || !identical(_scans[source], token)) return;
        if (indexed.isNotEmpty) _publishFound(source, token, indexed);
      }
      // With photos already on screen, the scan's partial lists would shrink
      // the grid before growing it again, so only its final answer is used.
      final showing = _found[source]?.isNotEmpty ?? false;
      final photos = await loadAlbumPhotos(
        source,
        recursive: recursive,
        token: token,
        cacheDirectory: library?.indexDirectory,
        useCatalog: useCatalog,
        trustCatalog: verify ? null : _trustCatalog,
        onProgress: showing
            ? null
            : (found) => _publishFound(source, token, found),
      );
      final current = identical(_scans[source], token);
      _publishFound(source, token, photos, done: true);
      if (current && library != null) {
        unawaited(library.recordScan(source, recursive, photos.length));
      }
    } catch (e) {
      if (!mounted || !identical(_scans[source], token)) return;
      _errors[source] = '$e';
      _publishFound(source, token, const [], done: true);
    }
  }

  /// Applies a scan batch. The first tiles show up immediately; later batches
  /// are coalesced so rebuilding the grid does not hitch every few files.
  void _publishFound(
    String source,
    AlbumLoadToken token,
    List<AlbumPhoto> found, {
    bool done = false,
  }) {
    if (!mounted || !identical(_scans[source], token)) return;
    _found[source] = found;
    if (done) _scans.remove(source);
    if (_scans.isEmpty) {
      _progressTimer?.cancel();
      _progressTimer = null;
      _applyFound();
      return;
    }
    if (_sections.isEmpty) {
      _applyFound();
      return;
    }
    _progressTimer ??= Timer(const Duration(milliseconds: 100), () {
      _progressTimer = null;
      if (mounted) _applyFound();
    });
  }

  void _applyFound() {
    setState(_rebuildData);
    _foldersRevision.value++;
  }

  /// Rebuilds what the grid shows from what the scans have found. Call inside
  /// [setState], or where a build follows anyway.
  void _rebuildData() {
    _allPhotos = mergeAlbumPhotos([
      for (final source in _sources) _found[source] ?? const [],
    ]);
    _treeStale = true;
    _recompute();
    _loading = _scans.isNotEmpty;
    // An error is only reported when no source could be read at all; a
    // folder that fails among others is left out.
    _error =
        !_loading && _sources.isNotEmpty && _sources.every(_errors.containsKey)
        ? _errors.values.first
        : null;
  }

  /// Rebuilds what the grid shows from the found photos and the hidden
  /// folders. Call inside [setState].
  void _recompute() {
    // With one source and nothing hidden, the scan is already in grid order
    // and doubles as the flat list.
    final visible = mergeAlbumPhotos([
      for (final source in _sources)
        filterAlbumByExcluded(_found[source] ?? const [], source, _excluded),
    ]);
    _inShownFolders = visible.length;

    // Narrowed to one folder: the rest of the album is set aside, but not
    // counted as hidden, since one click brings it back.
    final scope = _scope;
    if (scope != null && !_scopeStillValid(scope)) _scope = null;
    final inScope = _scope == null
        ? visible
        : filterAlbumToFolder(visible, _scope!);

    final counts = <String, int>{};
    for (final photo in inScope) {
      counts.update(photo.fileType, (n) => n + 1, ifAbsent: () => 1);
    }
    _typeCounts = counts;

    final shown = _types.isEmpty
        ? inScope
        : [
            for (final photo in inScope)
              if (_types.contains(photo.fileType)) photo,
          ];
    _flatPhotos = shown;
    _sections = groupAlbumByDay(shown);
    if (_selected.isNotEmpty) {
      final ids = {for (final photo in shown) photo.id};
      _selected.removeWhere((id) => !ids.contains(id));
    }
  }

  void _setTypes(Set<String> next) {
    setState(() {
      _types = next;
      _recompute();
    });
    widget.onFileTypesChanged?.call(Set.unmodifiable(next));
  }

  /// Picks or unpicks one file type in the filter.
  void _toggleType(String type) {
    _setTypes(
      _types.contains(type) ? ({..._types}..remove(type)) : {..._types, type},
    );
  }

  /// Whether [scope] still names a folder the album can show: inside a source
  /// and not hidden.
  bool _scopeStillValid(String scope) {
    if (!_hasPanel) return false;
    final inSource = _sources.any((s) => s == scope || p.isWithin(s, scope));
    if (!inSource) return false;
    return !_excluded.any((e) => e == scope || p.isWithin(e, scope));
  }

  /// Narrows the album to the folder at [path] and everything below it. A
  /// second click on the same folder, or one on the only source (which holds
  /// everything anyway), widens it again.
  void _focusFolder(String path) {
    final widen =
        path == _scope || (_sources.length == 1 && path == _sources.single);
    setState(() {
      _scope = widen ? null : path;
      _recompute();
    });
    _foldersRevision.value++;
  }

  /// Back to the whole album.
  void _clearScope() {
    if (_scope == null) return;
    setState(() {
      _scope = null;
      _recompute();
    });
    _foldersRevision.value++;
  }

  void _setExcluded(Set<String> next) {
    setState(() {
      _excluded = next;
      _recompute();
    });
    _foldersRevision.value++;
    widget.onExcludedFoldersChanged?.call(Set.unmodifiable(next));
  }

  /// One folder tree per source, of everything found. While scans run they are
  /// rebuilt at most twice a second, since building walks every photo.
  List<AlbumFolderNode> get _folderTrees {
    final current = _trees;
    final fresh =
        current != null &&
        (!_treeStale || (_loading && _treeAge.elapsedMilliseconds < 500));
    if (fresh) return current;
    _treeStale = false;
    _treeAge
      ..reset()
      ..start();
    return _trees = [
      for (final source in _sources)
        buildAlbumFolderTree(_found[source] ?? const [], source),
    ];
  }

  /// Whether there is a folder panel at all: with subfolders to hide, or
  /// sources to manage.
  bool get _hasPanel =>
      widget.recursive ||
      widget.onAddSource != null ||
      widget.onRemoveSource != null;

  /// The folder panel. With [closeOnFocus] it also closes (through [onClose])
  /// once a folder is picked, as a sheet should: the album is what the user
  /// came to see.
  Widget _folderPanel({VoidCallback? onClose, bool closeOnFocus = false}) {
    return ListenableBuilder(
      listenable: _foldersRevision,
      builder: (context, _) => AlbumFolderPanel(
        roots: _folderTrees,
        onAddFolder: widget.onAddSource,
        onRemoveFolder: widget.onRemoveSource,
        excluded: _excluded,
        highlighted: _activeFolder,
        focused: _scope,
        onDeleteFolder: _deleteFolder,
        onRenameFolder: _renameImages,
        onRevealFolder: widget.revealFolder != null || Platform.isWindows
            ? _revealFolder
            : null,
        onImportFolder: _importFromCamera,
        onFocus: (path) {
          _focusFolder(path);
          if (closeOnFocus) onClose?.call();
        },
        shown: _inShownFolders,
        total: _allPhotos.length,
        loading: _loading,
        onChanged: _setExcluded,
        onClose: onClose,
      ),
    );
  }

  /// Wide windows keep the folder tree beside the grid; narrow ones open it
  /// from the bar as a sheet.
  static const double _sidePanelMinWidth = 900;
  static const double _sidePanelWidth = 300;

  /// Opens or closes the folder tree: the side panel on a wide window, the
  /// sheet on a narrow one. The button and the Tab key both come here.
  void _toggleFolders(bool wide) {
    if (wide) {
      setState(() => _panelHidden = !_panelHidden);
    } else {
      _openFolderSheet();
    }
  }

  void _openFolderSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.7,
        child: _folderPanel(
          onClose: () => Navigator.of(sheetContext).pop(),
          closeOnFocus: true,
        ),
      ),
    );
  }

  /// The photos of the album [photo] belongs to, in grid order.
  ///
  /// Every folder one level under a source is an album, with everything
  /// below it. Photos lying directly in the source itself make up one more
  /// album of their own. A source with its photos in the open therefore
  /// previews only its loose photos, and one with a folder per trip, person
  /// or year previews one folder at a time.
  List<AlbumPhoto> _albumOf(List<AlbumPhoto> flatPhotos, AlbumPhoto photo) {
    // Longest first, so a source inside another one is its own.
    final sources = [..._sources]..sort((a, b) => b.length - a.length);
    final keys = <String, String?>{};

    String? keyFor(AlbumPhoto of) {
      final directory = p.normalize(p.dirname(of.file.path));
      return keys.putIfAbsent(directory, () {
        for (final source in sources) {
          if (directory == source) return source;
          if (!p.isWithin(source, directory)) continue;
          final first = p.split(p.relative(directory, from: source)).first;
          return p.join(source, first);
        }
        return null;
      });
    }

    final key = keyFor(photo);
    if (key == null) return flatPhotos;
    return [
      for (final other in flatPhotos)
        if (identical(other, photo) || keyFor(other) == key) other,
    ];
  }

  void _openPreview(List<AlbumPhoto> flatPhotos, AlbumPhoto photo) {
    _markFolderOf(photo);
    // Narrowed to a folder, the grid is already the album to preview.
    if (_scope == null) flatPhotos = _albumOf(flatPhotos, photo);
    final wide = MediaQuery.sizeOf(context).width >= _sidePanelMinWidth;
    if (_hasPanel && wide) {
      // Beside the folder panel, not over it.
      setState(() {
        _previewPhotos = flatPhotos;
        _previewIndex = flatPhotos.indexOf(photo);
        _previewSerial++;
      });
      return;
    }
    Navigator.of(context)
        .push(
          // Fades up from the grid rather than sliding over it: the photo is the
          // only thing that changes, so the motion stays out of the way.
          PageRouteBuilder<void>(
            transitionDuration: const Duration(milliseconds: 220),
            reverseTransitionDuration: const Duration(milliseconds: 180),
            pageBuilder: (_, _, _) => AlbumPreviewPage(
              photos: flatPhotos,
              initialIndex: flatPhotos.indexOf(photo),
              library: widget.library,
              onPhotoChanged: _markFolderOf,
            ),
            transitionsBuilder: (_, animation, _, child) => FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: Curves.easeOut,
              ),
              child: child,
            ),
          ),
        )
        .whenComplete(() {
          if (mounted) _unmarkFolder();
        });
  }

  void _closePreview() {
    if (_previewPhotos == null) return;
    setState(() => _previewPhotos = null);
    _unmarkFolder();
    _focus.requestFocus();
  }

  /// The grid with the preview laid over it, when one is open. The preview
  /// fades in and out over the grid's own area only, so the folder panel and
  /// the bar stay put.
  Widget _withPreview(Widget album) {
    final photos = _previewPhotos;
    return Stack(
      children: [
        Positioned.fill(child: album),
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            reverseDuration: const Duration(milliseconds: 180),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: photos == null
                ? const SizedBox.shrink(key: ValueKey('no-preview'))
                : AlbumPreviewPage(
                    key: ValueKey(_previewSerial),
                    photos: photos,
                    initialIndex: _previewIndex,
                    library: widget.library,
                    onClose: _closePreview,
                    onPhotoChanged: _markFolderOf,
                  ),
          ),
        ),
      ],
    );
  }

  void _toggle(AlbumPhoto photo) {
    setState(() {
      if (!_selected.remove(photo.id)) _selected.add(photo.id);
      _anchor = photo.id;
    });
  }

  /// Selects every photo from the anchor to [photo], in grid order. With
  /// [keep] the photos already picked stay picked; without it the range
  /// replaces them. The anchor stays put, so shift-clicking elsewhere
  /// re-aims the range from the same start.
  void _selectRange(
    List<AlbumPhoto> flatPhotos,
    AlbumPhoto photo, {
    required bool keep,
  }) {
    final to = flatPhotos.indexWhere((p) => p.id == photo.id);
    final from = _anchor == null
        ? -1
        : flatPhotos.indexWhere((p) => p.id == _anchor);
    if (to < 0) return;
    if (from < 0) {
      // Nothing to range from yet: this one becomes the start.
      setState(() {
        if (!keep) _selected.clear();
        _selected.add(photo.id);
        _anchor = photo.id;
      });
      return;
    }

    final lo = from < to ? from : to;
    final hi = from < to ? to : from;
    setState(() {
      if (!keep) _selected.clear();
      for (var i = lo; i <= hi; i++) {
        _selected.add(flatPhotos[i].id);
      }
    });
  }

  /// A click on a tile, or on its check badge when [openIfIdle] is false.
  ///
  /// Shift picks a range from the last pick (ctrl or cmd as well keeps what
  /// was already picked), ctrl or cmd toggles just that photo, and a plain
  /// click toggles while picking is under way and otherwise opens the photo.
  void _click(
    List<AlbumPhoto> flatPhotos,
    AlbumPhoto photo, {
    required bool openIfIdle,
  }) {
    // The click that ends a drag-select is not a click.
    if (_dragKey.currentState?.justDragged ?? false) return;

    final keyboard = HardwareKeyboard.instance;
    final additive = keyboard.isControlPressed || keyboard.isMetaPressed;

    if (keyboard.isShiftPressed) {
      _selectRange(flatPhotos, photo, keep: additive);
    } else if (additive || _selected.isNotEmpty || !openIfIdle) {
      _toggle(photo);
    } else {
      _openPreview(flatPhotos, photo);
    }
  }

  /// A long-press picks the photo, and keeping the finger down then sweeps
  /// over more.
  void _longPress(AlbumPhoto photo) {
    if (_dragKey.currentState?.beginHold(photo) ?? false) return;
    _toggle(photo);
  }

  /// A drag-select began on [photo]. Returns whether it picks (true) or
  /// unpicks (false) the photos it crosses: unpicks only when it started on a
  /// photo that was already picked.
  bool _dragStart(AlbumPhoto photo) {
    final select = !_selected.contains(photo.id);
    _dragPaint([photo], select);
    _anchor = photo.id;
    return select;
  }

  void _dragPaint(Iterable<AlbumPhoto> photos, bool select) {
    final ids = photos.map((photo) => photo.id);
    final changes = select
        ? ids.any((id) => !_selected.contains(id))
        : ids.any(_selected.contains);
    if (!changes) return;
    setState(() {
      if (select) {
        _selected.addAll(ids);
      } else {
        _selected.removeAll(ids);
      }
    });
  }

  void _selectAll(List<AlbumPhoto> flatPhotos) {
    setState(() => _selected.addAll(flatPhotos.map((photo) => photo.id)));
  }

  /// Picks every photo from [section], or clears them when they already
  /// are all picked.
  void _selectDay(AlbumDaySection section) {
    final ids = section.photos.map((photo) => photo.id);
    final all = section.photos.every((photo) => _selected.contains(photo.id));
    setState(() {
      if (all) {
        _selected.removeAll(ids);
      } else {
        _selected.addAll(ids);
      }
      if (section.photos.isNotEmpty) _anchor = section.photos.first.id;
    });
  }

  /// All of the day's photos, none of them, or some.
  bool? _dayChecked(AlbumDaySection section) {
    var picked = 0;
    for (final photo in section.photos) {
      if (_selected.contains(photo.id)) picked++;
    }
    if (picked == 0) return false;
    if (picked == section.photos.length) return true;
    return null;
  }

  Future<void> _deleteSelected(List<AlbumPhoto> flatPhotos) async {
    final picked = flatPhotos
        .where((photo) => _selected.contains(photo.id))
        .toList();
    if (picked.isEmpty) return;

    final confirm = widget.confirmDelete ?? _defaultConfirm;
    final confirmed = await confirm(context, picked.length);
    if (!confirmed || !mounted) return;

    for (final photo in picked) {
      if (await photo.file.exists()) await photo.file.delete();
    }
    if (!mounted) return;
    setState(() => _selected.clear());
    await reload();
  }

  /// Imports from the camera into a new folder inside [node]. The page lists
  /// the removable drives that have a DCIM folder and asks for the folder
  /// name beside the shots. See [AlbumImportPage].
  Future<void> _importFromCamera(AlbumFolderNode node) async {
    final imported = await Navigator.of(context)
        .push<(String, AlbumImportResult)>(
          MaterialPageRoute(
            builder: (context) => AlbumImportPage(
              parentPath: node.path,
              parentName: node.name,
              cards: widget.cameraCards ?? albumCameraCards,
              pickFolder: widget.pickFolder,
            ),
          ),
        );
    if (imported == null || !mounted) return;
    final (name, result) = imported;

    final failed = result.errors.length;
    final summary = StringBuffer(
      'Copied ${albumFormatCount(result.copied)} '
      '${result.copied == 1 ? 'file' : 'files'} into "$name"',
    );
    if (result.deleted > 0) {
      summary.write(
        ' and removed ${albumFormatCount(result.deleted)} from the camera',
      );
    }
    if (result.skipped > 0) {
      summary.write(
        ', ${albumFormatCount(result.skipped)} had nothing of that kind',
      );
    }
    if (result.stopped) summary.write(', and stopped early');
    if (failed > 0) summary.write('. ${result.errors.first}');
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(summary.toString())));
    await reload();
    if (!mounted || result.copied == 0) return;
    _focusFolder(p.normalize(p.join(node.path, name)));
  }

  /// Shows the folder [node] in the file manager.
  Future<void> _revealFolder(AlbumFolderNode node) async {
    try {
      final reveal = widget.revealFolder;
      if (reveal != null) {
        await reveal(node.path);
      } else {
        // Explorer reports a failure through its exit code even when it did
        // open the folder, so only a failure to start it is an error.
        await Process.start('explorer.exe', [
          p.normalize(node.path),
        ], mode: ProcessStartMode.detached);
      }
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Could not open the folder: $error')),
      );
    }
  }

  /// Renames the images of the folder [node] after asking how: the name to
  /// give them, and whether the folders inside are included. Each folder is
  /// numbered on its own. See [albumRenameImages].
  Future<void> _renameImages(AlbumFolderNode node) async {
    final everything = filterAlbumToFolder(_allPhotos, node.path);
    final direct = [
      for (final photo in everything)
        if (p.normalize(p.dirname(photo.file.path)) == node.path) photo,
    ];
    final request = await showAlbumRenameDialog(
      context,
      folderName: node.name,
      directCount: direct.length,
      deepCount: everything.length,
      exampleExtension: everything.isEmpty
          ? '.jpg'
          : p.extension(everything.first.file.path),
    );
    if (request == null || !mounted) return;

    final chosen = request.recursive ? everything : direct;
    // A photo open on top may be one of those being renamed.
    _closePreview();
    final result = await albumRenameImagesInBackground(
      paths: [for (final photo in chosen) photo.file.path],
      prefix: request.prefix,
    );
    if (!mounted) return;

    final renamed = {for (final pair in result.renamed) pair.from};
    setState(() {
      _selected.removeWhere(renamed.contains);
      if (renamed.contains(_anchor)) _anchor = null;
    });
    final failed = result.failCount;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? 'Renamed ${albumFormatCount(result.successCount)} '
                    '${result.successCount == 1 ? 'image' : 'images'}'
              : 'Renamed ${albumFormatCount(result.successCount)}, '
                    '$failed could not be renamed: ${result.errors.first}',
        ),
      ),
    );
    await reload();
  }

  /// Deletes the folder [node] after asking: its photos, and those below it,
  /// then every folder among them that nothing else is left in. A source
  /// folder is never deleted here.
  Future<void> _deleteFolder(AlbumFolderNode node) async {
    if (_sources.contains(node.path)) return;
    final photos = filterAlbumToFolder(_allPhotos, node.path);

    final confirm = widget.confirmDeleteFolder ?? _defaultConfirmFolder;
    final confirmed = await confirm(context, node.name, photos.length);
    if (!confirmed || !mounted) return;

    // A photo open on top may be one of those going.
    _closePreview();
    for (final photo in photos) {
      try {
        if (await photo.file.exists()) await photo.file.delete();
      } on FileSystemException {
        // Left in place; the reload below shows what is still there.
      }
    }
    // Deepest first, so a folder is empty by the time it is tried. A folder
    // with something else in it refuses, and stays.
    final directory = Directory(node.path);
    final folders = <Directory>[];
    try {
      if (await directory.exists()) {
        await for (final entity in directory.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is Directory) folders.add(entity);
        }
      }
    } on FileSystemException {
      // Whatever was found is still tried.
    }
    folders.sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final folder in [...folders, directory]) {
      try {
        await folder.delete();
      } on FileSystemException {
        // Not empty, or in use.
      }
    }
    if (!mounted) return;

    final scope = _scope;
    if (scope != null && (scope == node.path || p.isWithin(node.path, scope))) {
      _scope = null;
    }
    setState(
      () => _selected.removeWhere((id) => photos.any((x) => x.id == id)),
    );
    await reload();
  }

  int get _totalPhotos => _flatPhotos.length;

  String get _countText {
    final label = widget.countLabel;
    if (label != null) return label(_totalPhotos);
    final count = albumFormatCount(_totalPhotos);
    final text = _totalPhotos == 1 ? '1 photo' : '$count photos';
    // Narrowed to a folder, the rest is set aside rather than hidden.
    if (_scope != null) return text;
    final hidden = _allPhotos.length - _totalPhotos;
    return hidden > 0 ? '$text · ${albumFormatCount(hidden)} hidden' : text;
  }

  /// What the album is narrowed to, with the way back out: the cross, Escape,
  /// or a second click on the folder in the panel.
  Widget _scopeChip(int count) {
    final scope = _scope!;
    // A source is named by its folder, a folder inside it by its own name.
    final name = p.basename(scope).isEmpty ? scope : p.basename(scope);
    return Tooltip(
      message: scope,
      child: InputChip(
        avatar: const Icon(Icons.folder_open_rounded, size: 18),
        label: Text(
          '$name · ${albumFormatCount(count)} ${count == 1 ? 'photo' : 'photos'}',
          overflow: TextOverflow.ellipsis,
        ),
        onDeleted: _clearScope,
        deleteIcon: const Icon(Icons.close_rounded, size: 18),
        deleteButtonTooltipMessage: 'Show the whole album',
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  /// A square icon on the left. Tapping it opens the folder tree: beside the
  /// grid on a wide window, as a sheet on a narrow one. A dot marks hidden
  /// folders.
  Widget _foldersBar(bool wide) {
    final open = wide && !_panelHidden;
    final scheme = Theme.of(context).colorScheme;
    final hidden = _allPhotos.length > _inShownFolders;
    return Tooltip(
      message: 'Folders',
      child: Material(
        color: open ? scheme.surfaceContainerHigh : scheme.surfaceContainer,
        child: InkWell(
          onTap: () => _toggleFolders(wide),
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Badge(
                smallSize: 8,
                isLabelVisible: hidden,
                child: Icon(
                  open ? Icons.account_tree : Icons.account_tree_outlined,
                  color: open ? scheme.onSurface : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final flatPhotos = _flatPhotos;
    final selecting = _selected.isNotEmpty;
    final scheme = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= _sidePanelMinWidth;
    final showPanel = _hasPanel && wide && !_panelHidden;

    final album = RefreshIndicator(
      onRefresh: reload,
      child: _albumBody(scheme),
    );

    return PopScope(
      // A preview shown over the grid is not a route, so the system back
      // gesture closes it here.
      canPop: _previewPhotos == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closePreview();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyA, control: true): () =>
              _selectAll(flatPhotos),
          const SingleActivator(LogicalKeyboardKey.keyA, meta: true): () =>
              _selectAll(flatPhotos),
          // Escape backs out of one thing at a time: picking first, then the
          // narrowing to a folder. A photo open on top takes it before either.
          if (selecting)
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                setState(_selected.clear)
          else if (_scope != null)
            const SingleActivator(LogicalKeyboardKey.escape): _clearScope,
          // Tab folds the folder tree away and brings it back, even with a
          // photo open beside it.
          if (_hasPanel)
            const SingleActivator(LogicalKeyboardKey.tab): () =>
                _toggleFolders(wide),
        },
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          child: _scaffold(flatPhotos, scheme, album, wide, showPanel),
        ),
      ),
    );
  }

  /// The folder panel on the left, opened and closed with a slide. It keeps
  /// its full width and is revealed from its right edge, so nothing in it
  /// reflows, and the grid takes the room back as it goes.
  ///
  /// No line divides it from the grid: the panel is a shade lighter than the
  /// page, which is edge enough and keeps the two from looking boxed in.
  Widget _sidePanel(bool visible) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: visible ? 1 : 0),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeInOutCubic,
      builder: (context, t, _) {
        if (t == 0) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            alignment: Alignment.centerRight,
            widthFactor: t,
            child: SizedBox(
              width: _sidePanelWidth,
              child: _folderPanel(
                onClose: () => setState(() => _panelHidden = true),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _scaffold(
    List<AlbumPhoto> flatPhotos,
    ColorScheme scheme,
    Widget album,
    bool wide,
    bool showPanel,
  ) {
    final selecting = _selected.isNotEmpty;
    return Scaffold(
      appBar: selecting
          ? AppBar(
              backgroundColor: scheme.surfaceContainerHigh,
              foregroundColor: scheme.onSurface,
              leading: IconButton(
                tooltip: 'Cancel selection',
                onPressed: () => setState(_selected.clear),
                icon: const Icon(Icons.close_rounded),
              ),
              title: Text(
                '${_selected.length} selected',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              actions: [
                IconButton(
                  tooltip: 'Select all',
                  onPressed: _selected.length == flatPhotos.length
                      ? null
                      : () => _selectAll(flatPhotos),
                  icon: const Icon(Icons.select_all_rounded),
                ),
                IconButton(
                  tooltip: 'Delete',
                  onPressed: () => _deleteSelected(flatPhotos),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
                const SizedBox(width: 4),
              ],
            )
          : AppBar(
              title: widget.title,
              actions: [...widget.actions, const SizedBox(width: 4)],
              centerTitle: false,
            ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_hasPanel)
            Align(alignment: Alignment.topCenter, child: _foldersBar(wide)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_scope != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
                      child: _scopeChip(flatPhotos.length),
                    ),
                  ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _sidePanel(showPanel),
                      Expanded(child: _withPreview(album)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _albumBody(ColorScheme scheme) {
    final flatPhotos = _flatPhotos;
    final selecting = _selected.isNotEmpty;
    final headerHeight = AlbumDayHeaderDelegate.heightFor(context);
    if (_sources.isEmpty) {
      final add = widget.onAddSource;
      return _centered(
        AlbumStateView(
          icon: Icons.create_new_folder_outlined,
          title: 'No folders yet',
          message: 'Add a folder to see its photos.',
          action: add == null
              ? null
              : FilledButton.icon(
                  onPressed: add,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add folder'),
                ),
        ),
      );
    }
    final allHidden =
        !_loading &&
        _error == null &&
        _inShownFolders == 0 &&
        _allPhotos.isNotEmpty;
    final noneOfType =
        !_loading && _error == null && _sections.isEmpty && _inShownFolders > 0;
    if (noneOfType) {
      return _centered(
        AlbumStateView(
          icon: Icons.filter_alt_off_outlined,
          title: 'No photos of this type',
          message: 'None of the photos here are ${_typeLabel(_types)}.',
          action: OutlinedButton.icon(
            onPressed: () => _setTypes(const {}),
            icon: const Icon(Icons.filter_alt_off_outlined),
            label: const Text('Show all types'),
          ),
        ),
      );
    }
    if (allHidden) {
      return _centered(
        AlbumStateView(
          icon: Icons.folder_off_outlined,
          title: 'All folders are hidden',
          message: 'Every photo is in a folder you have hidden.',
          action: OutlinedButton.icon(
            onPressed: () => _setExcluded(const {}),
            icon: const Icon(Icons.visibility_outlined),
            label: const Text('Show all folders'),
          ),
        ),
      );
    }
    return switch ((_loading, _error, _sections.isEmpty)) {
      (_, final error?, _) => _centered(
        AlbumStateView(
          icon: Icons.error_outline_rounded,
          color: scheme.error,
          title: 'Could not load the album',
          message: error,
          action: OutlinedButton.icon(
            onPressed: reload,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry'),
          ),
        ),
      ),
      (true, null, true) => _centered(const CircularProgressIndicator()),
      (false, null, true) => _centered(
        widget.empty ??
            const AlbumStateView(
              icon: Icons.photo_library_outlined,
              title: 'No photos',
              message: 'Nothing in this folder yet.',
            ),
      ),
      _ => AlbumDragSelect(
        key: _dragKey,
        controller: _gridController,
        onStart: _dragStart,
        onPaint: _dragPaint,
        child: CustomScrollView(
          controller: _gridController,
          primary: false,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Row(
                  children: [
                    Text(
                      _countText,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (_loading) ...[
                      const SizedBox(width: 10),
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_typeCounts.isNotEmpty || _types.isNotEmpty)
              SliverToBoxAdapter(child: _typeBar(scheme)),
            for (final section in _sections)
              // A group per day, so that day's heading stays pinned only
              // while its photos are on screen and the next day's heading
              // then takes its place, rather than headings piling up.
              SliverMainAxisGroup(
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: AlbumDayHeaderDelegate(
                      section,
                      height: headerHeight,
                      selected: _dayChecked(section),
                      onSelect: () => _selectDay(section),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
                    sliver: SliverGrid.builder(
                      // Tiles stay about the same size and the number of
                      // columns follows the width: three on a phone, many
                      // more on a desktop window, rather than three huge
                      // tiles.
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: albumTileMaxExtent,
                            mainAxisSpacing: 4,
                            crossAxisSpacing: 4,
                          ),
                      itemCount: section.photos.length,
                      itemBuilder: (context, index) {
                        final photo = section.photos[index];
                        return AlbumPhotoTile(
                          key: ValueKey(photo.id),
                          library: widget.library,
                          photo: photo,
                          selecting: selecting,
                          selected: _selected.contains(photo.id),
                          onTap: () =>
                              _click(flatPhotos, photo, openIfIdle: true),
                          onToggle: () =>
                              _click(flatPhotos, photo, openIfIdle: false),
                          onLongPress: () => _longPress(photo),
                        );
                      },
                    ),
                  ),
                ],
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    };
  }

  /// "JPG", "JPG or PNG", "JPG, PNG or GIF".
  static String _typeLabel(Set<String> types) {
    final list = types.toList()..sort();
    if (list.length < 2) return list.join();
    return '${list.take(list.length - 1).join(', ')} or ${list.last}';
  }

  /// The file-type filter, a drop-down that says what is shown now: the one
  /// type the folder holds, "All types" for a mix, or the types picked. Its
  /// menu lists every type found with its count, and picking several shows
  /// all of them. A type that was picked and has since run out of photos stays
  /// in the menu, so it can be unpicked.
  Widget _typeBar(ColorScheme scheme) {
    final types = {..._typeCounts.keys, ..._types}.toList()..sort();
    int countOf(Iterable<String> some) =>
        some.fold(0, (sum, type) => sum + (_typeCounts[type] ?? 0));
    final everything = countOf(types);

    final String label;
    if (_types.isNotEmpty) {
      final picked = _types.toList()..sort();
      label = '${picked.join(', ')} · ${albumFormatCount(countOf(picked))}';
    } else if (types.length == 1) {
      label = '${types.first} · ${albumFormatCount(everything)}';
    } else {
      label = 'All types · ${albumFormatCount(everything)}';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: MenuAnchor(
          menuChildren: [
            CheckboxMenuButton(
              value: _types.isEmpty,
              onChanged: (_) => _setTypes(const {}),
              child: Text('All types · ${albumFormatCount(everything)}'),
            ),
            const Divider(height: 1),
            for (final type in types)
              CheckboxMenuButton(
                value: _types.contains(type),
                // Stays open, so several can be ticked in one go.
                closeOnActivate: false,
                onChanged: (_) => _toggleType(type),
                child: Text(
                  '$type · ${albumFormatCount(_typeCounts[type] ?? 0)}',
                ),
              ),
          ],
          builder: (context, controller, _) => OutlinedButton.icon(
            key: const ValueKey('albumTypeFilter'),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              backgroundColor: _types.isEmpty
                  ? null
                  : scheme.secondaryContainer,
            ),
            icon: const Icon(Icons.filter_alt_outlined, size: 18),
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label),
                const Icon(Icons.arrow_drop_down_rounded, size: 22),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _centered(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        controller: _fillerController,
        primary: false,
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(child: child),
        ),
      ),
    );
  }
}

Future<bool> _defaultConfirmFolder(
  BuildContext context,
  String folderName,
  int count,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        icon: Icon(Icons.folder_delete_outlined, color: scheme.error),
        title: Text('Delete the folder "$folderName"?'),
        content: Text(
          count == 0
              ? 'The folder has no photos. It is removed if nothing else '
                    'is in it.'
              : 'This deletes ${count == 1 ? '1 photo' : '$count photos'} '
                    'from the folder and the folders inside it, and removes '
                    'the folders that are then empty. It cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}

Future<bool> _defaultConfirm(BuildContext context, int count) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        icon: Icon(Icons.delete_outline_rounded, color: scheme.error),
        title: Text(count == 1 ? 'Delete 1 photo?' : 'Delete $count photos?'),
        content: const Text(
          'This deletes the selected files from this folder.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}
