import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'album_camera.dart';
import 'album_drag_select.dart';
import 'album_features.dart';
import 'album_film_home.dart';
import 'album_films.dart';
import 'album_meta_dialog.dart';
import 'album_folders.dart';
import 'album_images.dart';
import 'album_import_page.dart';
import 'album_library.dart';
import 'album_photo.dart';
import 'album_preview_page.dart';
import 'album_preview_zoom.dart';
import 'album_rename.dart';
import 'album_rename_dialog.dart';
import 'album_view.dart';
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
/// * Ctrl-click (cmd-click) picks or unpicks one photo. Shift-click adds
///   every photo from the one picked last to the one clicked, leaving what
///   is already picked alone. With nothing picked, the shift-clicked photo
///   is the start.
/// * Press the mouse on a tile and drag to pick every tile the pointer goes
///   over, or on a picked tile to unpick them. On a touch screen, long-press
///   and keep the finger down. The grid scrolls when the pointer reaches its
///   top or bottom edge.
/// * Ctrl+A (cmd+A) picks everything. Escape, or a click on empty space,
///   lets go.
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
    this.filmLibraryPath,
    this.onFilmLibraryChanged,
    this.recursive = false,
    this.initialExcludedFolders = const {},
    this.onExcludedFoldersChanged,
    this.initialFileTypes = const {},
    this.onFileTypesChanged,
    this.onAddSource,
    this.onImportDigital,
    this.onRemoveSource,
    this.library,
    this.useCatalog = true,
    this.features = const AlbumFeatures(),
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

  /// The functions this album offers. Anything left out of [features] is not
  /// shown and cannot be started. The default includes every function.
  final AlbumFeatures features;

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
  ///
  /// When [pickFolder] is set, the album picks the folder itself and asks
  /// whether it is film or digital. A digital choice is reported here as
  /// [onImportDigital] when that is set, and otherwise as this callback.
  final VoidCallback? onAddSource;

  /// Called with the path when the user imports a chosen folder as digital
  /// photos. Used together with [pickFolder].
  final ValueChanged<String>? onImportDigital;

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

  /// Asks for a folder when "Choose a folder" is used on the import page,
  /// and when the film library is chosen from the folder tab. When null,
  /// Windows opens its folder dialog for import. Return null when cancelled.
  final Future<String?> Function([String? initialDirectory])? pickFolder;

  /// Folder whose children are film stocks. Each folder under a stock is one
  /// scanned roll. The roll's format lives in a hidden file inside it.
  final String? filmLibraryPath;

  /// Called with the folder the user picked for [filmLibraryPath].
  final ValueChanged<String>? onFilmLibraryChanged;

  @override
  State<ImageAlbum> createState() => ImageAlbumState();
}

class ImageAlbumState extends State<ImageAlbum>
    with SingleTickerProviderStateMixin {
  final ScrollController _gridController = ScrollController();
  final ScrollController _fillerController = ScrollController();

  /// Open/close zoom when the preview sits over the grid (wide window with a
  /// folder panel). The Navigator route used otherwise has its own controller.
  late final AnimationController _previewMotion;

  /// Global bounds of the tile the open preview zoomed out of. Updated when
  /// the viewer moves to another photo so close zooms into that tile.
  Rect? _previewFromRect;

  /// Screen-sized image that flies during the zoom. Tracks the photo on
  /// screen, not only the one that opened the viewer.
  ImageProvider? _previewFlight;

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

  /// Which library the left buttons are showing.
  _LibraryMode _mode = _LibraryMode.digital;

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

  /// Crop and turn for each photo, keyed by absolute path. The files are
  /// unchanged. Loaded when the album opens and again when a preview closes.
  Map<String, AlbumViewAdjustment> _views = {};

  /// Film stocks under [ImageAlbum.filmLibraryPath].
  List<AlbumFilm> _films = const [];
  AlbumFilm? _openFilm;

  /// Film whose roll cards are on the waterfall. Photos stay closed until a
  /// roll is opened.
  AlbumFilm? _browsingFilm;
  var _filmLoading = false;
  var _filmScan = 0;
  List<AlbumDaySection> _filmSections = const [];
  List<AlbumPhoto> _filmPhotos = const [];
  List<AlbumPhoto> _filmAll = const [];
  List<AlbumFolderNode> _filmTrees = const [];
  Set<String> _filmExcluded = {};
  Set<String> _lightroomJpeg = {};
  Map<String, AlbumFolderMeta> _filmMeta = {};
  final Map<String, List<AlbumPhoto>> _filmPreviews = {};
  final Map<String, DateTime> _filmWhen = {};
  String? _filmScope;
  final Map<AlbumDaySection, ({String title, String subtitle})> _filmHeadings =
      {};
  String? _filmLibraryPath;

  Future<void> _loadViews() async {
    final saved = await albumViewAdjustments();
    if (!mounted) return;
    setState(() => _views = saved);
  }

  AlbumViewAdjustment _viewOf(AlbumPhoto photo) =>
      _views[photo.file.absolute.path] ?? const AlbumViewAdjustment();

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

  /// Paths already handed to the background thumbnail prefetch, so a scan's
  /// partial updates only queue the new ones.
  final Set<String> _thumbPrefetchQueued = {};

  final List<File> _thumbPrefetchPending = [];
  var _thumbPrefetchActive = 0;
  var _thumbPrefetchDone = 0;
  var _thumbPrefetchTotal = 0;

  /// How far background thumbnail building has got, or null when idle. Shown
  /// in the app bar so a large folder can fill its cache without blocking.
  (int, int)? _thumbPrefetchProgress;

  static const int _thumbPrefetchSlots = 2;

  @override
  void initState() {
    super.initState();
    _previewMotion = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
      reverseDuration: const Duration(milliseconds: 280),
    );
    _sources = _normalizedSources();
    _excluded = _normalized(widget.initialExcludedFolders);
    final library = widget.filmLibraryPath;
    if (library != null && library.isNotEmpty) {
      _mode = _LibraryMode.film;
    }
    _types = {
      for (final type in widget.initialFileTypes) type.trim().toUpperCase(),
    }..remove('');
    _filmLibraryPath = widget.filmLibraryPath;
    _loadViews();
    _scanFilms();
    _startScans(_sources);
  }

  @override
  void didUpdateWidget(ImageAlbum oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filmLibraryPath != oldWidget.filmLibraryPath &&
        widget.filmLibraryPath != _filmLibraryPath) {
      _filmLibraryPath = widget.filmLibraryPath;
      _scanFilms();
    }
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
    _previewMotion.dispose();
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

  /// Remakes every thumbnail. Use it when stored thumbnails are wrong, such
  /// as ones made before a decoding fix.
  ///
  /// Photos currently in the grid are remade first so the open view updates
  /// sooner. Folder indexes are left alone — they do not depend on thumbnail
  /// bytes. [onProgress] gets the thumbnails done and the total. Completes
  /// with how many were made. [cancelled] stops making them; the rest are
  /// made when next shown.
  Future<int> regenerateCache({
    void Function(int done, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final shown = <String>{};
    final files = <File>[
      for (final photo in _flatPhotos)
        if (shown.add(photo.file.path)) photo.file,
      for (final photo in _allPhotos)
        if (shown.add(photo.file.path)) photo.file,
    ];
    _resetThumbPrefetch();
    final made = await albumRegenerateThumbnails(
      files,
      library: widget.library,
      onProgress: onProgress,
      cancelled: () => !mounted || (cancelled?.call() ?? false),
    );
    // Revision was bumped inside; rebuild so every tile asks for remade files.
    // Prefetch marks everything queued so it does not redo the remade set.
    if (mounted) {
      setState(() {
        for (final file in files) {
          _thumbPrefetchQueued.add(file.path);
        }
        _thumbPrefetchDone = files.length;
        _thumbPrefetchTotal = files.length;
        _thumbPrefetchProgress = null;
      });
    }
    return made;
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
    _enqueueThumbPrefetch();
  }

  /// Queues thumbnails for every photo the grid can show and keeps a couple of
  /// workers building them in the background. On-screen tiles use a higher
  /// pool priority, so scrolling stays ahead of this backlog.
  void _enqueueThumbPrefetch() {
    for (final photo in _flatPhotos) {
      final path = photo.file.path;
      if (!_thumbPrefetchQueued.add(path)) continue;
      _thumbPrefetchPending.add(photo.file);
      _thumbPrefetchTotal++;
    }
    _pumpThumbPrefetch();
    _publishThumbPrefetchProgress();
  }

  void _pumpThumbPrefetch() {
    while (_thumbPrefetchActive < _thumbPrefetchSlots &&
        _thumbPrefetchPending.isNotEmpty) {
      if (!mounted) return;
      final file = _thumbPrefetchPending.removeAt(0);
      _thumbPrefetchActive++;
      unawaited(
        albumEnsureThumbnail(
          file,
          library: widget.library,
          priority: 0,
        ).catchError((_) {}).whenComplete(() {
          _thumbPrefetchActive--;
          _thumbPrefetchDone++;
          if (!mounted) return;
          _publishThumbPrefetchProgress();
          _pumpThumbPrefetch();
        }),
      );
    }
  }

  void _publishThumbPrefetchProgress() {
    final next =
        _thumbPrefetchTotal == 0 || _thumbPrefetchDone >= _thumbPrefetchTotal
        ? null
        : (_thumbPrefetchDone, _thumbPrefetchTotal);
    if (next == _thumbPrefetchProgress) return;
    // Coalesce tiny steps so a big album does not rebuild the app bar
    // hundreds of times a second.
    final previous = _thumbPrefetchProgress;
    if (next != null &&
        previous != null &&
        next.$2 == previous.$2 &&
        next.$2 > 0 &&
        (next.$1 - previous.$1) * 30 < next.$2 &&
        next.$1 < next.$2) {
      return;
    }
    setState(() => _thumbPrefetchProgress = next);
  }

  void _resetThumbPrefetch() {
    _thumbPrefetchQueued.clear();
    _thumbPrefetchPending.clear();
    _thumbPrefetchDone = 0;
    _thumbPrefetchTotal = 0;
    _thumbPrefetchProgress = null;
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
    _enqueueThumbPrefetch();
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
    _enqueueThumbPrefetch();
  }

  /// Back to the whole album.
  void _clearScope() {
    if (_scope == null) return;
    setState(() {
      _scope = null;
      _recompute();
    });
    _foldersRevision.value++;
    _enqueueThumbPrefetch();
  }

  void _setExcluded(Set<String> next) {
    setState(() {
      _excluded = next;
      _recompute();
    });
    _foldersRevision.value++;
    _enqueueThumbPrefetch();
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

  /// Whether [feature] was included for this album.
  bool _allows(AlbumFeature feature) => widget.features.allows(feature);

  /// Whether there is a folder panel at all: with subfolders to hide, or
  /// sources to manage.
  bool get _hasPanel =>
      widget.recursive ||
      widget.onAddSource != null ||
      widget.onRemoveSource != null ||
      _filmLibraryPath != null ||
      widget.onFilmLibraryChanged != null ||
      widget.pickFolder != null;

  List<AlbumPhoto> get _gridPhotos =>
      _openFilm == null ? _flatPhotos : _filmPhotos;

  List<AlbumDaySection> get _gridSections =>
      _openFilm == null ? _sections : _filmSections;

  Future<void> _scanFilms() async {
    final path = _filmLibraryPath;
    final generation = ++_filmScan;
    if (path == null || path.isEmpty) {
      if (!mounted) return;
      setState(() {
        _films = const [];
        _openFilm = null;
        _browsingFilm = null;
        _clearFilmView();
      });
      return;
    }
    // Folder names are enough to split Located and No location. Rolls and
    // pictures are filled in afterwards, so the list does not wait on them.
    final places = await listAlbumFilmPlaces(path);
    if (!mounted || generation != _filmScan) return;
    setState(() => _keepKnownFilms(places));
    final films = await scanAlbumFilms(path);
    if (!mounted || generation != _filmScan) return;
    setState(() {
      _films = films;
      _filmPreviews.clear();
      _filmWhen.clear();
      _settleOpenFilm(films);
    });
    _loadFilmPreviews(films, generation);
  }

  /// Shows [incoming] at once, keeping rolls already found for the same folder.
  void _keepKnownFilms(List<AlbumFilm> incoming) {
    final previous = _films;
    _films = [
      for (final film in incoming) _knownFilm(previous, film.path) ?? film,
    ];
    _settleOpenFilm(_films);
  }

  AlbumFilm? _knownFilm(List<AlbumFilm> films, String path) {
    for (final film in films) {
      if (p.equals(film.path, path)) return film;
    }
    return null;
  }

  void _settleOpenFilm(List<AlbumFilm> films) {
    if (_openFilm != null &&
        !films.any((film) => film.path == _openFilm!.path)) {
      _openFilm = null;
      _clearFilmPhotos();
    }
    final browsing = _browsingFilm;
    if (browsing == null) return;
    AlbumFilm? next;
    for (final film in films) {
      if (p.equals(film.path, browsing.path)) next = film;
    }
    _browsingFilm = next;
  }

  Future<DateTime> _folderModified(String path) async {
    try {
      return (await Directory(path).stat()).modified;
    } on Object {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  /// A short strip of each roll's scans for the film tab.
  Future<void> _loadFilmPreviews(List<AlbumFilm> films, int generation) async {
    for (final film in films) {
      if (!mounted || generation != _filmScan) return;
      List<AlbumPhoto> found;
      try {
        found = await loadAlbumPhotos(
          film.path,
          recursive: true,
          useCatalog: false,
          cacheDirectory: widget.library?.indexDirectory,
        );
      } on Object {
        found = const [];
      }
      if (!mounted || generation != _filmScan) return;
      final merged = albumPreferLightroomJpeg(found);
      final newest = [...merged.photos]
        ..sort((a, b) => b.takenAt.compareTo(a.takenAt));
      final buckets = <String, List<AlbumPhoto>>{
        for (final roll in film.rolls) p.normalize(roll.path): <AlbumPhoto>[],
      };
      if (film.rolls.isEmpty) {
        buckets[p.normalize(film.path)] = newest.take(8).toList();
      }
      for (final photo in newest) {
        final dir = albumRollFolder(
          p.dirname(photo.file.path),
          merged.jpegFolders,
        );
        AlbumFilmRoll? match;
        for (final roll in film.rolls) {
          final root = p.normalize(roll.path);
          if (dir == root || p.isWithin(root, dir)) {
            if (match == null || root.length > p.normalize(match.path).length) {
              match = roll;
            }
          }
        }
        if (match == null) continue;
        final shots = buckets[p.normalize(match.path)]!;
        if (shots.length < 8) shots.add(photo);
      }
      if (!mounted || generation != _filmScan) return;
      final times = <String, DateTime>{};
      final metas = <String, AlbumFolderMeta>{};
      for (final entry in buckets.entries) {
        final shots = entry.value;
        times[entry.key] = shots.isEmpty
            ? await _folderModified(entry.key)
            : shots.first.takenAt;
        metas[entry.key] = await readAlbumFolderMeta(entry.key);
        if (!mounted || generation != _filmScan) return;
      }
      setState(() {
        _filmPreviews.addAll(buckets);
        _filmWhen.addAll(times);
        _filmMeta.addAll(metas);
      });
    }
  }

  /// Picks a folder, then asks whether it is film scans or digital photos.
  /// Without [ImageAlbum.pickFolder], adding a folder is left to [onAddSource].
  Future<void> _importFolder() async {
    final pick = widget.pickFolder;
    if (pick == null) {
      widget.onAddSource?.call();
      return;
    }
    final path = await pick();
    if (!mounted || path == null || path.isEmpty) return;
    final kind = await askAlbumFolderKind(context, path);
    if (!mounted || kind == null) return;
    if (kind == AlbumFolderKind.film) {
      setState(() => _mode = _LibraryMode.film);
      _filmLibraryPath = path;
      widget.onFilmLibraryChanged?.call(path);
      await _scanFilms();
      return;
    }
    setState(() {
      _mode = _LibraryMode.digital;
      _openFilm = null;
      _browsingFilm = null;
      _clearFilmPhotos();
    });
    final onDigital = widget.onImportDigital;
    if (onDigital != null) {
      onDigital(path);
    } else {
      widget.onAddSource?.call();
    }
  }

  Future<void> _assignFilmKind(AlbumFilmKind kind) async {
    final pick = widget.pickFolder;
    if (pick == null) return;
    final path = await pick(_filmLibraryPath);
    if (!mounted || path == null || path.isEmpty) return;
    // A picture still open in this folder makes Windows refuse the rename.
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;
    final String? placed;
    try {
      placed = await albumPlaceFilmFolder(
        folder: path,
        kind: kind,
        libraryRoot: _filmLibraryPath,
      );
    } on FileSystemException catch (error) {
      if (!mounted) return;
      final detail = error.message.isEmpty
          ? 'Could not use that folder.'
          : error.message;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(detail)));
      return;
    }
    if (!mounted) return;
    if (placed == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('${kind.folderName} is already in the library.'),
        ),
      );
      return;
    }
    await _scanFilms();
  }

  Future<void> _clearFilmKind(AlbumFilmKind kind) async {
    String? folder;
    for (final film in _films) {
      if (albumFilmKindForFolder(film.name)?.iconKey == kind.iconKey) {
        folder = film.path;
        break;
      }
    }
    if (folder == null) return;
    try {
      await albumSetFilmFolderCleared(folder, true);
      final library = _filmLibraryPath;
      if (library != null && library.isNotEmpty) {
        await albumClearFilmLink(library, kind.iconKey);
      }
    } on FileSystemException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            error.message.isEmpty
                ? 'Could not clear that folder.'
                : error.message,
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    if (_openFilm != null &&
        albumFilmKindForFolder(_openFilm!.name)?.iconKey == kind.iconKey) {
      setState(() {
        _openFilm = null;
        _clearFilmPhotos();
      });
    }
    if (_browsingFilm != null &&
        albumFilmKindForFolder(_browsingFilm!.name)?.iconKey == kind.iconKey) {
      setState(() => _browsingFilm = null);
    }
    await _scanFilms();
  }

  /// Lists this film's rolls. A second tap, while the rolls are already
  /// showing, returns to every film. A tap while its photos are open returns
  /// to the rolls.
  void _showFilmRolls(AlbumFilm film) {
    setState(() {
      final showingPhotos = _openFilm?.path == film.path;
      final showingRolls =
          _openFilm == null && _browsingFilm?.path == film.path;
      if (showingPhotos) {
        _openFilm = null;
        _clearFilmPhotos();
        _browsingFilm = film;
        return;
      }
      if (showingRolls) {
        _browsingFilm = null;
        return;
      }
      _openFilm = null;
      _clearFilmPhotos();
      _browsingFilm = film;
    });
  }

  Future<void> _openRoll(AlbumFilm film, AlbumFilmRoll? roll) async {
    _browsingFilm = film;
    if (_openFilm?.path != film.path) {
      await _toggleFilm(film);
    }
    if (!mounted || _openFilm?.path != film.path || roll == null) return;
    setState(() {
      _filmScope = roll.path;
      _applyFilmView();
    });
  }

  Future<void> _toggleFilm(AlbumFilm film) async {
    if (_openFilm?.path == film.path) {
      setState(() {
        _openFilm = null;
        _filmLoading = false;
        _clearFilmPhotos();
      });
      return;
    }
    setState(() {
      _openFilm = film;
      _filmLoading = true;
      _clearFilmPhotos();
    });
    final List<AlbumPhoto> found;
    AlbumFolderNode tree;
    try {
      found = await loadAlbumPhotos(
        film.path,
        recursive: true,
        useCatalog: false,
        cacheDirectory: widget.library?.indexDirectory,
      );
      tree = await buildAlbumDirectoryTree(
        film.path,
        filmHeader: true,
        filmIcon: film.iconAsset,
      );
    } on Object {
      if (!mounted || _openFilm?.path != film.path) return;
      setState(() => _filmLoading = false);
      return;
    }
    if (!mounted || _openFilm?.path != film.path) return;
    final rolled = albumPreferLightroomJpeg(found);
    final meta = <String, AlbumFolderMeta>{};
    final dirs = <String>{
      for (final photo in rolled.photos)
        albumRollFolder(p.dirname(photo.file.path), rolled.jpegFolders),
    };
    for (final dir in dirs) {
      meta[p.normalize(dir)] = await readAlbumFolderMeta(dir);
      if (!mounted || _openFilm?.path != film.path) return;
    }
    setState(() {
      _filmMeta = meta;
      _filmAll = found;
      final next = [for (final node in _filmTrees) node];
      final index = next.indexWhere((node) => node.path == film.path);
      if (index < 0) {
        next.add(tree);
      } else {
        next[index] = tree;
      }
      _filmTrees = next;
      _filmLoading = false;
      _applyFilmView();
    });
  }

  void _clearFilmView() {
    _clearFilmPhotos();
    _filmTrees = const [];
    _filmPreviews.clear();
    _filmWhen.clear();
  }

  void _clearFilmPhotos() {
    _filmPhotos = const [];
    _filmAll = const [];
    _filmSections = const [];
    _filmExcluded = {};
    _filmScope = null;
    _lightroomJpeg = {};
    _filmMeta = {};
    _filmHeadings.clear();
  }

  AlbumFilm? _filmContaining(String path) {
    final normal = p.normalize(path);
    for (final film in _films) {
      final root = p.normalize(film.path);
      if (normal == root || p.isWithin(root, normal)) return film;
    }
    return null;
  }

  void _onTreeExcluded(Set<String> next) {
    final film = <String>{};
    final digital = <String>{};
    for (final path in next) {
      if (_filmContaining(path) != null) {
        film.add(path);
      } else {
        digital.add(path);
      }
    }
    final filmChanged =
        film.length != _filmExcluded.length || !film.containsAll(_filmExcluded);
    final digitalChanged =
        digital.length != _excluded.length || !digital.containsAll(_excluded);
    if (filmChanged) {
      setState(() {
        _filmExcluded = film;
        if (_openFilm != null) _applyFilmView();
      });
    }
    if (digitalChanged) _setExcluded(digital);
  }

  /// Narrows the open film to [path], or widens it when [path] is already open.
  void _focusFilmFolder(String path) {
    setState(() {
      _filmScope = _filmScope == path ? null : path;
      _applyFilmView();
    });
    _foldersRevision.value++;
  }

  Future<void> _editFolderMeta(AlbumFolderNode node) async {
    final saved = await showAlbumFolderMeta(context, node.path);
    if (saved == null || !mounted) return;
    setState(() {
      _filmMeta[p.normalize(node.path)] = saved;
      _films = [
        for (final film in _films)
          if (film.path == _openFilm?.path)
            _rollMeta(film, node.path, saved.format)
          else
            film,
      ];
      final open = _openFilm;
      if (open != null) _openFilm = _rollMeta(open, node.path, saved.format);
    });
  }

  AlbumFilm _rollMeta(AlbumFilm film, String folder, String format) {
    return AlbumFilm(
      name: film.name,
      path: film.path,
      iconAsset: film.iconAsset,
      hasPictures: film.hasPictures,
      rolls: [
        for (final roll in film.rolls)
          if (roll.path == folder)
            AlbumFilmRoll(name: roll.name, format: format, path: roll.path)
          else
            roll,
      ],
    );
  }

  /// Photos of the open film. One roll is one undated grid; a whole film
  /// still uses date + time dividers.
  void _applyFilmView() {
    final film = _openFilm;
    if (film == null) return;
    var photos = filterAlbumByExcluded(_filmAll, film.path, _filmExcluded);
    final scope = _filmScope;
    if (scope != null) photos = filterAlbumToFolder(photos, scope);
    final merged = albumPreferLightroomJpeg(photos);
    _lightroomJpeg = merged.jpegFolders;
    photos = merged.photos;
    _filmPhotos = photos;
    _filmHeadings.clear();
    if (scope != null) {
      _filmSections = photos.isEmpty
          ? const []
          : [AlbumDaySection(day: photos.first.takenAt, photos: photos)];
      return;
    }
    final byFolder = <String, List<AlbumPhoto>>{};
    for (final photo in photos) {
      final folder = albumRollFolder(
        p.dirname(photo.file.path),
        _lightroomJpeg,
      );
      byFolder.putIfAbsent(folder, () => []).add(photo);
    }
    final folders = byFolder.keys.toList()..sort();
    final built = <({AlbumDaySection section, String folder})>[];
    for (final folder in folders) {
      final base = p.basename(folder);
      final name = base.isEmpty ? folder : base;
      for (final group in groupAlbumByDay(byFolder[folder]!)) {
        built.add((section: group, folder: name));
      }
    }
    built.sort((a, b) {
      final byDay = b.section.day.compareTo(a.section.day);
      if (byDay != 0) return byDay;
      return a.folder.toLowerCase().compareTo(b.folder.toLowerCase());
    });
    _filmSections = [for (final item in built) item.section];
    for (final item in built) {
      final at = item.section.photos.first.takenAt.toLocal();
      final hour = at.hour.toString().padLeft(2, '0');
      final minute = at.minute.toString().padLeft(2, '0');
      _filmHeadings[item.section] = (
        title: albumFullDate(item.section.day),
        subtitle: '$hour:$minute',
      );
    }
  }

  /// The folder panel. With [closeOnFocus] it also closes (through [onClose])
  /// once a folder is picked, as a sheet should: the album is what the user
  /// came to see.
  Widget _folderPanel({VoidCallback? onClose, bool closeOnFocus = false}) {
    return ListenableBuilder(
      listenable: _foldersRevision,
      builder: (context, _) => AlbumFolderPanel(
        roots: _mode == _LibraryMode.film ? const [] : _folderTrees,
        showFolderTree: _mode != _LibraryMode.film,
        heading: _mode == _LibraryMode.film ? 'Films' : 'Folders',
        onAddFolder: widget.pickFolder != null || widget.onAddSource != null
            ? _importFolder
            : null,
        onRemoveFolder: widget.onRemoveSource,
        excluded: {..._excluded, ..._filmExcluded},
        highlighted: _openFilm == null ? _activeFolder : null,
        focused: _openFilm != null ? (_filmScope ?? _openFilm!.path) : _scope,
        onDeleteFolder: _allows(AlbumFeature.folderDelete)
            ? _deleteFolder
            : null,
        onRenameFolder: _allows(AlbumFeature.rename) ? _renameImages : null,
        onRevealFolder:
            _allows(AlbumFeature.reveal) &&
                (widget.revealFolder != null || Platform.isWindows)
            ? _revealFolder
            : null,
        onImportFolder: _allows(AlbumFeature.import) ? _importFromCamera : null,
        onFolderMeta: _editFolderMeta,
        onFocus: (path) {
          final film = _filmContaining(path);
          if (film != null) {
            if (_openFilm?.path != film.path) _toggleFilm(film);
            _focusFilmFolder(path);
          } else {
            _focusFolder(path);
          }
          if (closeOnFocus) onClose?.call();
        },
        shown: _openFilm == null ? _inShownFolders : _filmPhotos.length,
        total: _openFilm == null ? _allPhotos.length : _filmAll.length,
        loading: _mode == _LibraryMode.film ? _filmLoading : _loading,
        onChanged: _onTreeExcluded,
        onClose: onClose,
        filmKinds: _mode == _LibraryMode.film ? albumFilmKinds : const [],
        locatedFilmKeys: {
          for (final film in _films)
            if (albumFilmKindForFolder(film.name) case final kind?)
              kind.iconKey,
        },
        filmFolderLabels: {
          for (final film in _films)
            if (albumFilmKindForFolder(film.name) case final kind?)
              kind.iconKey: p.basename(film.path),
        },
        selectedFilmKey: () {
          final picked = _openFilm ?? _browsingFilm;
          if (picked == null) return null;
          return albumFilmKindForFolder(picked.name)?.iconKey;
        }(),
        onFilmKindTap: (kind) {
          for (final film in _films) {
            if (albumFilmKindForFolder(film.name)?.iconKey == kind.iconKey) {
              _showFilmRolls(film);
              return;
            }
          }
        },
        onAssignFilmKind: _assignFilmKind,
        onClearFilmKind: _clearFilmKind,
        openFilmFolders: [
          for (final tree in _filmTrees)
            if (tree.path == _openFilm?.path) ...tree.children,
        ],
        filmPaths: [for (final film in _films) film.path],
        onFilmHeader: (path) {
          final film = _filmContaining(path);
          if (film != null) _toggleFilm(film);
        },
        onPickFilmLibrary:
            _mode == _LibraryMode.film && widget.pickFolder != null
            ? _importFolder
            : null,
        filmLibraryChosen: _filmLibraryPath != null,
      ),
    );
  }

  /// Wide windows keep the folder tree beside the grid; narrow ones open it
  /// from the bar as a sheet.
  static const double _sidePanelMinWidth = 900;
  static const double _sidePanelWidth = 300;

  /// Opens or closes the side panel: beside the grid on a wide window, as a
  /// sheet on a narrow one. The Tab key toggles whatever is showing.
  void _toggleFolders(bool wide) {
    if (wide) {
      setState(() => _panelHidden = !_panelHidden);
    } else {
      _openFolderSheet();
    }
  }

  /// Film or digital. The same button again folds the panel; the other one
  /// switches the library and opens the panel.
  void _selectLibrary(_LibraryMode mode, bool wide) {
    final same = _mode == mode;
    if (!wide) {
      setState(() {
        _mode = mode;
        if (mode == _LibraryMode.digital) {
          _openFilm = null;
          _browsingFilm = null;
          _clearFilmPhotos();
        } else {
          _scope = null;
        }
      });
      _openFolderSheet();
      return;
    }
    setState(() {
      if (same) {
        _panelHidden = !_panelHidden;
        return;
      }
      _mode = mode;
      _panelHidden = false;
      if (mode == _LibraryMode.digital) {
        _openFilm = null;
        _browsingFilm = null;
        _clearFilmPhotos();
      } else {
        _scope = null;
      }
    });
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

  /// Global bounds of [photo]'s grid tile, if that tile is currently mounted.
  Rect? _rectOfPhotoTile(AlbumPhoto photo) {
    Rect? found;
    void visit(Element element) {
      if (found != null) return;
      final widget = element.widget;
      if (widget is AlbumPhotoTile && widget.photo.id == photo.id) {
        final box = element.renderObject as RenderBox?;
        if (box != null && box.hasSize && box.attached) {
          found = box.localToGlobal(Offset.zero) & box.size;
        }
        return;
      }
      element.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    return found;
  }

  /// Point the close/open flight at [photo] (its fitted decode and tile rect).
  void _aimPreviewFlightAt(AlbumPhoto photo) {
    final screen = MediaQuery.sizeOf(context);
    _previewFlight = albumFittedProvider(photo.file, screen);
    final rect = _rectOfPhotoTile(photo);
    if (rect != null) _previewFromRect = rect;
  }

  Future<void> _openPreview(
    List<AlbumPhoto> flatPhotos,
    AlbumPhoto photo, {
    Rect? origin,
  }) async {
    _markFolderOf(photo);
    // Narrowed to a folder, the grid is already the album to preview.
    if (_scope == null) flatPhotos = _albumOf(flatPhotos, photo);
    _previewFromRect = origin;
    final screen = MediaQuery.sizeOf(context);
    // Same screen-sized decode the preview page uses — fly that, not the
    // grid thumbnail, so there is never a soft→sharp handoff.
    _previewFlight = albumFittedProvider(photo.file, screen);
    try {
      await precacheImage(_previewFlight!, context);
    } on Object {
      // Still open; the Image will decode during the flight if needed.
    }
    if (!mounted || !_allows(AlbumFeature.preview)) return;
    final wide = screen.width >= _sidePanelMinWidth;
    if (_hasPanel && wide) {
      // Beside the folder panel, not over it.
      setState(() {
        _previewPhotos = flatPhotos;
        _previewIndex = flatPhotos.indexOf(photo);
        _previewSerial++;
      });
      // Wait one frame so the zoom host has a size to map [origin] into;
      // starting earlier flashes fullscreen for a frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _previewPhotos != null) {
          _previewMotion.forward(from: 0);
        }
      });
      return;
    }
    Navigator.of(context)
        .push(
          PageRouteBuilder<void>(
            opaque: false,
            transitionDuration: const Duration(milliseconds: 360),
            reverseTransitionDuration: const Duration(milliseconds: 280),
            pageBuilder: (_, _, _) => AlbumPreviewPage(
              photos: flatPhotos,
              initialIndex: flatPhotos.indexOf(photo),
              library: widget.library,
              onPhotoChanged: (next) {
                _markFolderOf(next);
                // Keep flight aimed at the photo on screen for zoom-out.
                _aimPreviewFlightAt(next);
              },
              onDelete: _allows(AlbumFeature.delete)
                  ? _deletePreviewPhoto
                  : null,
              crop: _allows(AlbumFeature.crop),
              info: _allows(AlbumFeature.info),
              filmstrip: _allows(AlbumFeature.filmstrip),
              reveal: _allows(AlbumFeature.reveal),
              veil: false,
            ),
            // Read the aimed flight/rect each build — not the values at push.
            transitionsBuilder: (_, animation, _, child) =>
                AlbumPreviewZoomTransition(
                  animation: animation,
                  fromGlobal: _previewFromRect,
                  flight: _previewFlight,
                  child: child,
                ),
          ),
        )
        .whenComplete(() {
          if (mounted) {
            _unmarkFolder();
            _previewFromRect = null;
            _previewFlight = null;
            _loadViews();
          }
        });
  }

  void _closePreview() {
    if (_previewPhotos == null) return;
    final photos = _previewPhotos!;
    if (photos.isNotEmpty) {
      final i = _previewIndex.clamp(0, photos.length - 1);
      _aimPreviewFlightAt(photos[i]);
    }
    if (_previewMotion.isDismissed) {
      setState(() {
        _previewPhotos = null;
        _previewFromRect = null;
        _previewFlight = null;
      });
      _unmarkFolder();
      _focus.requestFocus();
      _loadViews();
      return;
    }
    // Rebuild so the transition picks up the current photo before shrinking.
    setState(() {});
    _previewMotion.reverse().whenComplete(() {
      if (!mounted) return;
      setState(() {
        _previewPhotos = null;
        _previewFromRect = null;
        _previewFlight = null;
      });
      _unmarkFolder();
      _focus.requestFocus();
      _loadViews();
    });
  }

  /// The grid with the preview laid over it, when one is open. The page zooms
  /// out of the tapped tile and back into the current photo's tile on close.
  Widget _withPreview(Widget album) {
    final photos = _previewPhotos;
    final show = photos != null;
    return Stack(
      children: [
        Positioned.fill(child: album),
        if (show)
          Positioned.fill(
            child: AlbumPreviewZoomTransition(
              animation: _previewMotion,
              fromGlobal: _previewFromRect,
              flight: _previewFlight,
              child: AlbumPreviewPage(
                key: ValueKey(_previewSerial),
                photos: photos,
                initialIndex: _previewIndex,
                library: widget.library,
                onClose: _closePreview,
                onPhotoChanged: (photo) {
                  _markFolderOf(photo);
                  final i = photos.indexOf(photo);
                  setState(() {
                    if (i >= 0) _previewIndex = i;
                    _aimPreviewFlightAt(photo);
                  });
                },
                onDelete: _allows(AlbumFeature.delete)
                    ? _deletePreviewPhoto
                    : null,
                crop: _allows(AlbumFeature.crop),
                info: _allows(AlbumFeature.info),
                filmstrip: _allows(AlbumFeature.filmstrip),
                reveal: _allows(AlbumFeature.reveal),
                veil: false,
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

  /// Shift-click: adds every photo from the one picked last, the start, to
  /// [photo], the end, in grid order. Photos already picked are left as they
  /// are, whether inside the range or not.
  ///
  /// When nothing is picked, or the last pick is no longer picked or shown,
  /// there is no start, and [photo] becomes it. The end then is the start of
  /// the next range, so shift-clicking again carries on from there.
  void _selectRange(List<AlbumPhoto> flatPhotos, AlbumPhoto photo) {
    final to = flatPhotos.indexWhere((p) => p.id == photo.id);
    if (to < 0) return;

    final start = _anchor;
    final from = start != null && _selected.contains(start)
        ? flatPhotos.indexWhere((p) => p.id == start)
        : -1;

    setState(() {
      if (from < 0) {
        _selected.add(photo.id);
      } else {
        final lo = from < to ? from : to;
        final hi = from < to ? to : from;
        for (var i = lo; i <= hi; i++) {
          _selected.add(flatPhotos[i].id);
        }
      }
      _anchor = photo.id;
    });
  }

  /// A click on a tile, or on its check badge when [openIfIdle] is false.
  ///
  /// Shift adds the range from the last pick to the clicked photo, ctrl or cmd
  /// toggles just that photo, and a plain click toggles while picking is under
  /// way and otherwise opens the photo.
  void _click(
    List<AlbumPhoto> flatPhotos,
    AlbumPhoto photo, {
    required bool openIfIdle,
    Rect? origin,
  }) {
    // The click that ends a drag-select is not a click.
    if (_dragKey.currentState?.justDragged ?? false) return;

    final keyboard = HardwareKeyboard.instance;
    final additive = keyboard.isControlPressed || keyboard.isMetaPressed;
    final canSelect = _allows(AlbumFeature.selection);

    if (canSelect && keyboard.isShiftPressed) {
      _selectRange(flatPhotos, photo);
    } else if (canSelect && (additive || _selected.isNotEmpty || !openIfIdle)) {
      _toggle(photo);
    } else if (_allows(AlbumFeature.preview)) {
      _openPreview(flatPhotos, photo, origin: origin);
    }
  }

  /// A tap on empty space between and around the tiles unpicks everything.
  void _clickBlank() {
    if (_selected.isEmpty) return;
    if (_dragKey.currentState?.justDragged ?? false) return;
    setState(() {
      _selected.clear();
      _anchor = null;
    });
  }

  /// A long-press picks the photo, and keeping the finger down then sweeps
  /// over more.
  void _longPress(AlbumPhoto photo) {
    if (!_allows(AlbumFeature.selection)) return;
    if (_dragKey.currentState?.beginHold(photo) ?? false) return;
    _toggle(photo);
  }

  /// A drag-select began on [photo]. Returns whether it picks (true) or
  /// unpicks (false) the photos it crosses: unpicks only when it started on a
  /// photo that was already picked.
  bool _dragStart(AlbumPhoto photo) {
    if (!_allows(AlbumFeature.selection)) return true;
    final select = !_selected.contains(photo.id);
    _dragPaint([photo], select);
    _anchor = photo.id;
    return select;
  }

  void _dragPaint(Iterable<AlbumPhoto> photos, bool select) {
    if (!_allows(AlbumFeature.selection)) return;
    final ids = photos.map((photo) => photo.id).toList();
    final changes = select
        ? ids.any((id) => !_selected.contains(id))
        : ids.any(_selected.contains);
    if (!changes) return;
    setState(() {
      if (select) {
        _selected.addAll(ids);
        // The last photo the sweep picked is where a shift-click continues.
        _anchor = ids.last;
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

  /// Deletes one photo from the preview after asking. The viewer removes it
  /// from its own list when this returns true.
  Future<bool> _deletePreviewPhoto(AlbumPhoto photo) async {
    final confirm = widget.confirmDelete ?? _defaultConfirm;
    final confirmed = await confirm(context, 1);
    if (!confirmed || !mounted) return false;
    try {
      if (await photo.file.exists()) await photo.file.delete();
    } on FileSystemException {
      if (!mounted) return false;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Could not delete ${photo.fileName}')),
      );
      return false;
    }
    if (!mounted) return false;
    setState(() {
      _selected.remove(photo.id);
      final preview = _previewPhotos;
      if (preview != null) {
        final next = [
          for (final p in preview)
            if (p.id != photo.id) p,
        ];
        _previewPhotos = next.isEmpty ? null : next;
        if (_previewPhotos != null && _previewIndex >= _previewPhotos!.length) {
          _previewIndex = _previewPhotos!.length - 1;
        }
      }
    });
    await reload();
    return true;
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

  int get _totalPhotos => _gridPhotos.length;

  String get _countText {
    final label = widget.countLabel;
    if (label != null) return label(_totalPhotos);
    final count = albumFormatCount(_totalPhotos);
    final text = _totalPhotos == 1 ? '1 photo' : '$count photos';
    // Narrowed to a folder, the rest is set aside rather than hidden.
    if (_openFilm != null || _scope != null) return text;
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

  /// Film and digital, in place of the old folder button. The chosen one is
  /// filled while its panel is open.
  Widget _libraryBar(bool wide) {
    return Column(
      children: [
        _libraryButton(
          wide,
          mode: _LibraryMode.film,
          tooltip: 'Film',
          icon: Icons.camera_roll_outlined,
        ),
        _libraryButton(
          wide,
          mode: _LibraryMode.digital,
          tooltip: 'Digital',
          icon: Icons.photo_library_outlined,
        ),
      ],
    );
  }

  Widget _libraryButton(
    bool wide, {
    required _LibraryMode mode,
    required String tooltip,
    required IconData icon,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _mode == mode;
    final open = selected && wide && !_panelHidden;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: open ? scheme.surfaceContainerHigh : scheme.surfaceContainer,
        child: InkWell(
          onTap: () => _selectLibrary(mode, wide),
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(
              icon,
              color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final flatPhotos = _gridPhotos;
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
          if (_allows(AlbumFeature.selection)) ...{
            const SingleActivator(LogicalKeyboardKey.keyA, control: true): () =>
                _selectAll(flatPhotos),
            const SingleActivator(LogicalKeyboardKey.keyA, meta: true): () =>
                _selectAll(flatPhotos),
          },
          // Escape backs out of one thing at a time: picking first, then the
          // narrowing to a folder. A photo open on top takes it before either.
          if (selecting)
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                setState(_selected.clear)
          else if (_openFilm != null)
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                _showFilmRolls(_openFilm!)
          else if (_browsingFilm != null)
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                setState(() => _browsingFilm = null)
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
                if (_allows(AlbumFeature.delete))
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
              actions: [
                if (_thumbPrefetchProgress case final progress?)
                  Tooltip(
                    message:
                        'Loading thumbnails ${progress.$1} of ${progress.$2}',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: SizedBox(
                        width: 88,
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
                              '${progress.$1}/${progress.$2}',
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ...widget.actions,
                const SizedBox(width: 4),
              ],
              centerTitle: false,
            ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_hasPanel)
            Align(alignment: Alignment.topCenter, child: _libraryBar(wide)),
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
                      Expanded(
                        child: _withPreview(
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ?_filmBack,
                              Expanded(child: album),
                            ],
                          ),
                        ),
                      ),
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

  /// Back control at the top of the film waterfall. Rolls mode returns to
  /// every film. One roll's photos return to that film's rolls.
  Widget? get _filmBack {
    if (_mode != _LibraryMode.film) return null;
    final open = _openFilm;
    if (open != null) {
      final count = _filmPhotos.length;
      final name = _filmScope == null ? open.name : p.basename(_filmScope!);
      return _filmBackButton(
        label:
            '$name · ${albumFormatCount(count)} ${count == 1 ? 'photo' : 'photos'}',
        onPressed: () => _showFilmRolls(open),
        onDark: false,
      );
    }
    final browsing = _browsingFilm;
    if (browsing == null) return null;
    return _filmBackButton(
      label: browsing.name,
      onPressed: () => setState(() => _browsingFilm = null),
      onDark: true,
    );
  }

  Widget _filmBackButton({
    required String label,
    required VoidCallback onPressed,
    required bool onDark,
  }) {
    final foreground = onDark ? Colors.white : null;
    return ColoredBox(
      color: onDark ? const Color(0xFF0A0A0A) : Colors.transparent,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Tooltip(
          message: 'Back',
          child: TextButton.icon(
            onPressed: onPressed,
            style: TextButton.styleFrom(
              foregroundColor: foreground,
              visualDensity: VisualDensity.compact,
            ),
            icon: const Icon(Icons.arrow_back_rounded),
            label: Text(label, overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
    );
  }

  Widget _albumBody(ColorScheme scheme) {
    final flatPhotos = _gridPhotos;
    final sections = _gridSections;
    final selecting = _selected.isNotEmpty;
    final headerHeight = AlbumDayHeaderDelegate.heightFor(context);
    if (_openFilm != null && _filmLoading) {
      return _centered(const CircularProgressIndicator());
    }
    if (_mode == _LibraryMode.film && _openFilm == null) {
      if (_films.isEmpty) {
        return _centered(
          AlbumStateView(
            icon: Icons.camera_roll_outlined,
            title: 'No films',
            message: 'Choose a folder of film scans.',
            action: widget.pickFolder == null
                ? null
                : FilledButton.icon(
                    onPressed: _importFolder,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Choose folder'),
                  ),
          ),
        );
      }
      final browsing = _browsingFilm;
      final shown = browsing == null
          ? _films
          : [
              for (final film in _films)
                if (film.path == browsing.path) film,
            ];
      return AlbumFilmHome(
        films: shown.isEmpty ? _films : shown,
        previews: _filmPreviews,
        when: _filmWhen,
        meta: _filmMeta,
        library: widget.library,
        onOpen: _openRoll,
      );
    }
    if (_openFilm != null && sections.isEmpty) {
      return _centered(
        AlbumStateView(
          icon: Icons.camera_roll_outlined,
          title: 'No scans',
          message: 'This film has no pictures in its rolls yet.',
          action: TextButton(
            onPressed: () => _showFilmRolls(_openFilm!),
            child: const Text('Rolls'),
          ),
        ),
      );
    }
    if (_sources.isEmpty && _openFilm == null) {
      final add = widget.pickFolder != null
          ? _importFolder
          : widget.onAddSource;
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
    if (_openFilm == null && noneOfType) {
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
    if (_openFilm == null && allHidden) {
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
    return switch ((
      _openFilm == null && _loading,
      _openFilm == null ? _error : null,
      _openFilm == null && sections.isEmpty,
    )) {
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
        // A tap on bare space, which no tile, chip or button takes, lets go
        // of the selection.
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _clickBlank,
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
              for (final section in sections)
                // A group per day, so that day's heading stays pinned only
                // while its photos are on screen and the next day's heading
                // then takes its place, rather than headings piling up. One
                // open roll skips the day heading and shows every picture.
                SliverMainAxisGroup(
                  slivers: [
                    if (_filmScope == null)
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: AlbumDayHeaderDelegate(
                          section,
                          height: headerHeight,
                          title: _filmHeadings[section]?.title,
                          subtitle: _filmHeadings[section]?.subtitle,
                          selected: _allows(AlbumFeature.selection)
                              ? _dayChecked(section)
                              : null,
                          onSelect: _allows(AlbumFeature.selection)
                              ? () => _selectDay(section)
                              : null,
                        ),
                      ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        10,
                        _filmScope == null ? 2 : 8,
                        10,
                        8,
                      ),
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
                            selectable: _allows(AlbumFeature.selection),
                            adjustment: _viewOf(photo),
                            selected: _selected.contains(photo.id),
                            onTap: (origin) => _click(
                              flatPhotos,
                              photo,
                              openIfIdle: true,
                              origin: origin,
                            ),
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

enum _LibraryMode { film, digital }

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
      void cancel() => Navigator.of(context).pop(false);
      void confirm() => Navigator.of(context).pop(true);
      return CallbackShortcuts(
        bindings: {
          // Second D (or Enter) confirms after the first D opened this dialog.
          const SingleActivator(LogicalKeyboardKey.keyD): confirm,
          const SingleActivator(LogicalKeyboardKey.enter): confirm,
          const SingleActivator(LogicalKeyboardKey.escape): cancel,
        },
        child: Focus(
          autofocus: true,
          child: AlertDialog(
            icon: Icon(Icons.delete_outline_rounded, color: scheme.error),
            title: Text(
              count == 1 ? 'Delete 1 photo?' : 'Delete $count photos?',
            ),
            content: const Text(
              'This deletes the selected files from this folder.\n'
              'Press D again to delete.',
            ),
            actions: [
              TextButton(onPressed: cancel, child: const Text('Cancel')),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                ),
                onPressed: confirm,
                child: const Text('Delete'),
              ),
            ],
          ),
        ),
      );
    },
  );
  return confirmed ?? false;
}
