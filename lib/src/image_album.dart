import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'album_drag_select.dart';
import 'album_folders.dart';
import 'album_library.dart';
import 'album_photo.dart';
import 'album_preview_page.dart';
import 'album_widgets.dart';

/// Asks whether [count] selected photos should be deleted. Return true to
/// delete the files.
typedef ConfirmAlbumDelete =
    Future<bool> Function(BuildContext context, int count);

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
    this.recursive = false,
    this.initialExcludedFolders = const {},
    this.onExcludedFoldersChanged,
    this.initialFileTypes = const {},
    this.onFileTypesChanged,
    this.onAddSource,
    this.onRemoveSource,
    this.library,
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
    super.dispose();
  }

  /// Re-reads every source folder. Safe to call after files appear or
  /// disappear outside this widget.
  Future<void> reload() {
    _errors.clear();
    final done = _startScans(_sources);
    if (mounted) setState(_rebuildData);
    return done;
  }

  /// Starts scanning [sources], replacing any scan already running for them.
  /// Completes when all of them have finished.
  Future<void> _startScans(Iterable<String> sources) {
    final started = <Future<void>>[];
    for (final source in sources) {
      _scans.remove(source)?.cancel();
      _errors.remove(source);
      final token = AlbumLoadToken();
      _scans[source] = token;
      started.add(_scan(source, token));
    }
    _loading = _scans.isNotEmpty;
    _error = null;
    return Future.wait(started);
  }

  Future<void> _scan(String source, AlbumLoadToken token) async {
    final library = widget.library;
    final recursive = widget.recursive;
    try {
      // A folder seen before shows its photos at once, from the saved index.
      if (library != null && (_found[source]?.isEmpty ?? true)) {
        final indexed = await readAlbumIndex(
          source,
          recursive: recursive,
          cacheDirectory: library.indexDirectory,
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

    final counts = <String, int>{};
    for (final photo in visible) {
      counts.update(photo.fileType, (n) => n + 1, ifAbsent: () => 1);
    }
    _typeCounts = counts;

    final shown = _types.isEmpty
        ? visible
        : [
            for (final photo in visible)
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

  Widget _folderPanel({VoidCallback? onClose}) {
    return ListenableBuilder(
      listenable: _foldersRevision,
      builder: (context, _) => AlbumFolderPanel(
        roots: _folderTrees,
        onAddFolder: widget.onAddSource,
        onRemoveFolder: widget.onRemoveSource,
        excluded: _excluded,
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

  void _openFolderSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.7,
        child: _folderPanel(onClose: () => Navigator.of(sheetContext).pop()),
      ),
    );
  }

  void _openPreview(List<AlbumPhoto> flatPhotos, AlbumPhoto photo) {
    Navigator.of(context).push(
      // Fades up from the grid rather than sliding over it: the photo is the
      // only thing that changes, so the motion stays out of the way.
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, _, _) => AlbumPreviewPage(
          photos: flatPhotos,
          initialIndex: flatPhotos.indexOf(photo),
          library: widget.library,
        ),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        ),
      ),
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
  }) {
    // The click that ends a drag-select is not a click.
    if (_dragKey.currentState?.justDragged ?? false) return;

    final keyboard = HardwareKeyboard.instance;
    final additive = keyboard.isControlPressed || keyboard.isMetaPressed;

    if (keyboard.isShiftPressed) {
      _selectRange(flatPhotos, photo);
    } else if (additive || _selected.isNotEmpty || !openIfIdle) {
      _toggle(photo);
    } else {
      _openPreview(flatPhotos, photo);
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

  int get _totalPhotos => _flatPhotos.length;

  String get _countText {
    final label = widget.countLabel;
    if (label != null) return label(_totalPhotos);
    final count = albumFormatCount(_totalPhotos);
    final text = _totalPhotos == 1 ? '1 photo' : '$count photos';
    final hidden = _allPhotos.length - _totalPhotos;
    return hidden > 0 ? '$text · ${albumFormatCount(hidden)} hidden' : text;
  }

  /// The bar button for the folder tree: it toggles the side panel on a wide
  /// window and opens the sheet on a narrow one. A dot marks hidden folders.
  Widget _foldersButton(bool wide) {
    final open = wide && !_panelHidden;
    return IconButton(
      tooltip: 'Folders',
      isSelected: open,
      onPressed: wide
          ? () => setState(() => _panelHidden = !_panelHidden)
          : _openFolderSheet,
      icon: Badge(
        smallSize: 8,
        isLabelVisible: _allPhotos.length > _inShownFolders,
        child: const Icon(Icons.account_tree_outlined),
      ),
      selectedIcon: Badge(
        smallSize: 8,
        isLabelVisible: _allPhotos.length > _inShownFolders,
        child: const Icon(Icons.account_tree),
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

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): () =>
            _selectAll(flatPhotos),
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true): () =>
            _selectAll(flatPhotos),
        if (selecting)
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              setState(_selected.clear),
      },
      child: Focus(
        autofocus: true,
        child: _scaffold(flatPhotos, scheme, album, wide, showPanel),
      ),
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
              actions: [
                ...widget.actions,
                if (_hasPanel) _foldersButton(wide),
                const SizedBox(width: 4),
              ],
              centerTitle: false,
            ),
      body: showPanel
          ? Row(
              children: [
                Expanded(child: album),
                VerticalDivider(width: 1, color: scheme.outlineVariant),
                SizedBox(
                  width: _sidePanelWidth,
                  child: _folderPanel(
                    onClose: () => setState(() => _panelHidden = true),
                  ),
                ),
              ],
            )
          : album,
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
              if (_typeCounts.length > 1 || _types.isNotEmpty)
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
      ),
    };
  }

  /// "JPG", "JPG or PNG", "JPG, PNG or GIF".
  static String _typeLabel(Set<String> types) {
    final list = types.toList()..sort();
    if (list.length < 2) return list.join();
    return '${list.take(list.length - 1).join(', ')} or ${list.last}';
  }

  /// The row of file-type chips: one for everything, then one per type found.
  /// Picking several shows all of them. A type that was picked and has since
  /// run out of photos stays in the row, so it can be unpicked.
  Widget _typeBar(ColorScheme scheme) {
    final types = {..._typeCounts.keys, ..._types}.toList()..sort();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: Row(
        children: [
          ChoiceChip(
            label: const Text('All'),
            selected: _types.isEmpty,
            onSelected: (_) => _setTypes(const {}),
          ),
          for (final type in types) ...[
            const SizedBox(width: 8),
            FilterChip(
              label: Text(
                '$type · ${albumFormatCount(_typeCounts[type] ?? 0)}',
              ),
              selected: _types.contains(type),
              onSelected: (_) => _toggleType(type),
            ),
          ],
        ],
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
