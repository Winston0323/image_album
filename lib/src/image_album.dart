import 'dart:async';

import 'package:flutter/material.dart';

import 'album_photo.dart';
import 'album_preview_page.dart';

/// Asks whether [count] selected photos should be deleted. Return true to
/// delete the files.
typedef ConfirmAlbumDelete = Future<bool> Function(
  BuildContext context,
  int count,
);

/// Full-screen album of the images in [path].
///
/// Lists image files in that directory and lays them out as a three-column
/// grid grouped by day, newest first. Tap a tile to open the swipe preview;
/// long-press to select, then delete. Set [recursive] to include subfolders.
///
/// Own scroll controller, with `primary: false`, so the album can sit in an
/// [IndexedStack] beside other scrollables without sharing the ambient
/// [PrimaryScrollController].
class ImageAlbum extends StatefulWidget {
  const ImageAlbum({
    super.key,
    required this.path,
    this.title = const Text('Album'),
    this.actions = const [],
    this.empty,
    this.countLabel,
    this.confirmDelete,
    this.recursive = false,
  });

  /// Directory whose image files are shown. See [loadAlbumPhotos].
  final String path;

  /// When true, images in subfolders of [path] are included. Links are not
  /// followed. Defaults to false, which lists only files directly in [path].
  final bool recursive;

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
  bool _loading = true;
  String? _error;
  int _loadGeneration = 0;
  AlbumLoadToken? _scan;
  Timer? _progressTimer;
  List<AlbumPhoto>? _pendingFound;

  /// Photos picked for deletion, by [AlbumPhoto.id]. Non-empty is what puts
  /// the screen in selection mode.
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _load(showSpinner: false);
  }

  @override
  void didUpdateWidget(ImageAlbum oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.recursive != widget.recursive) {
      _selected.clear();
      _loading = true;
      _error = null;
      _sections = const [];
      _load(showSpinner: false);
    }
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _scan?.cancel();
    _gridController.dispose();
    _fillerController.dispose();
    super.dispose();
  }

  /// Re-reads [ImageAlbum.path]. Safe to call after files appear or disappear
  /// outside this widget.
  Future<void> reload() => _load();

  Future<void> _load({bool showSpinner = true}) async {
    _progressTimer?.cancel();
    _progressTimer = null;
    _pendingFound = null;
    _scan?.cancel();
    final scan = AlbumLoadToken();
    _scan = scan;
    final generation = ++_loadGeneration;
    if (showSpinner) {
      if (!mounted) return;
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final photos = await loadAlbumPhotos(
        widget.path,
        recursive: widget.recursive,
        token: scan,
        onProgress: (found) => _publishFound(generation, found),
      );
      _publishFound(generation, photos, done: true);
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      _progressTimer?.cancel();
      _progressTimer = null;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// Applies a scan batch. The first tiles show up immediately; later batches
  /// are coalesced so rebuilding the grid does not hitch every few files.
  void _publishFound(
    int generation,
    List<AlbumPhoto> found, {
    bool done = false,
  }) {
    if (!mounted || generation != _loadGeneration) return;
    if (done) {
      _progressTimer?.cancel();
      _progressTimer = null;
      _pendingFound = null;
      _applyFound(found, loading: false);
      return;
    }
    _pendingFound = found;
    if (_sections.isEmpty) {
      _applyFound(found, loading: true);
      return;
    }
    _progressTimer ??= Timer(const Duration(milliseconds: 100), () {
      _progressTimer = null;
      final pending = _pendingFound;
      if (pending == null || !mounted || generation != _loadGeneration) return;
      _applyFound(pending, loading: true);
    });
  }

  void _applyFound(List<AlbumPhoto> found, {required bool loading}) {
    setState(() {
      _sections = groupAlbumByDay(found);
      _selected.removeWhere(
        (id) => !found.any((photo) => photo.id == id),
      );
      _loading = loading;
      _error = null;
    });
  }

  void _openPreview(List<AlbumPhoto> flatPhotos, AlbumPhoto photo) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AlbumPreviewPage(
          photos: flatPhotos,
          initialIndex: flatPhotos.indexOf(photo),
        ),
      ),
    );
  }

  void _toggle(AlbumPhoto photo) {
    setState(() {
      if (!_selected.remove(photo.id)) _selected.add(photo.id);
    });
  }

  void _selectAll(List<AlbumPhoto> flatPhotos) {
    setState(() => _selected.addAll(flatPhotos.map((photo) => photo.id)));
  }

  Future<void> _deleteSelected(List<AlbumPhoto> flatPhotos) async {
    final picked =
        flatPhotos.where((photo) => _selected.contains(photo.id)).toList();
    if (picked.isEmpty) return;

    final confirm = widget.confirmDelete ?? _defaultConfirm;
    final confirmed = await confirm(context, picked.length);
    if (!confirmed || !mounted) return;

    for (final photo in picked) {
      if (await photo.file.exists()) await photo.file.delete();
    }
    if (!mounted) return;
    setState(() => _selected.clear());
    await _load();
  }

  int get _totalPhotos =>
      _sections.fold(0, (sum, section) => sum + section.photos.length);

  String get _countText {
    final label = widget.countLabel;
    if (label != null) return label(_totalPhotos);
    return _totalPhotos == 1 ? '1 photo' : '$_totalPhotos photos';
  }

  @override
  Widget build(BuildContext context) {
    final flatPhotos = [
      for (final section in _sections) ...section.photos,
    ];
    final selecting = _selected.isNotEmpty;

    return Scaffold(
      appBar: selecting
          ? AppBar(
              leading: IconButton(
                tooltip: 'Cancel selection',
                onPressed: () => setState(_selected.clear),
                icon: const Icon(Icons.close),
              ),
              title: Text('${_selected.length} selected'),
              actions: [
                IconButton(
                  tooltip: 'Select all',
                  onPressed: _selected.length == flatPhotos.length
                      ? null
                      : () => _selectAll(flatPhotos),
                  icon: const Icon(Icons.select_all),
                ),
                IconButton(
                  tooltip: 'Delete',
                  onPressed: () => _deleteSelected(flatPhotos),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            )
          : AppBar(title: widget.title, actions: widget.actions),
      body: RefreshIndicator(
        onRefresh: () => _load(),
        child: switch ((_loading, _error, _sections.isEmpty)) {
          (_, final error?, _) => _centered(
              _ErrorBody(message: error, onRetry: () => _load()),
            ),
          (true, null, true) => _centered(const CircularProgressIndicator()),
          (false, null, true) =>
            _centered(widget.empty ?? const _DefaultEmpty()),
          _ => CustomScrollView(
              controller: _gridController,
              primary: false,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      children: [
                        Text(
                          _countText,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context).hintColor,
                                  ),
                        ),
                        if (_loading) ...[
                          const SizedBox(width: 8),
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
                for (final section in _sections) ...[
                  SliverToBoxAdapter(child: _DayHeader(section: section)),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    sliver: SliverGrid.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 4,
                        crossAxisSpacing: 4,
                      ),
                      itemCount: section.photos.length,
                      itemBuilder: (context, index) {
                        final photo = section.photos[index];
                        return _PhotoTile(
                          key: ValueKey(photo.id),
                          photo: photo,
                          selecting: selecting,
                          selected: _selected.contains(photo.id),
                          onTap: selecting
                              ? () => _toggle(photo)
                              : () => _openPreview(flatPhotos, photo),
                          onLongPress: () => _toggle(photo),
                        );
                      },
                    ),
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
              ],
            ),
        },
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
    builder: (context) => AlertDialog(
      title: Text(count == 1 ? 'Delete 1 photo?' : 'Delete $count photos?'),
      content: const Text('This deletes the selected files from this folder.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.section});

  final AlbumDaySection section;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(_dayLabel(section.day), style: theme.textTheme.titleSmall),
          ),
          Text(
            '${section.photos.length}',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }

  static String _dayLabel(DateTime day) {
    final today = DateTime.now();
    final startOfToday = DateTime(today.year, today.month, today.day);
    final difference = startOfToday.difference(day).inDays;
    if (difference == 0) return 'Today';
    if (difference == 1) return 'Yesterday';
    final month = day.month.toString().padLeft(2, '0');
    final dayOfMonth = day.day.toString().padLeft(2, '0');
    return '${day.year}-$month-$dayOfMonth';
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    super.key,
    required this.photo,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final AlbumPhoto photo;

  /// Whether the album is in selection mode — every tile then shows its
  /// check marker, not just the selected ones, so the mode is visible.
  final bool selecting;

  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Image.file(
              photo.file,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              // Decoded at roughly tile resolution rather than full size, so a
              // grid of full-resolution photos does not each cost a full decode
              // just to show a thumbnail.
              cacheWidth: 240,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.broken_image_outlined),
            ),
          ),
          if (selected)
            DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.25),
                border: Border.all(color: theme.colorScheme.primary, width: 2),
              ),
            ),
          if (selecting)
            Positioned(
              top: 4,
              right: 4,
              child: Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                size: 20,
                color: selected ? theme.colorScheme.primary : Colors.white70,
                shadows: const [Shadow(blurRadius: 4, color: Colors.black54)],
              ),
            ),
        ],
      ),
    );
  }
}

class _DefaultEmpty extends StatelessWidget {
  const _DefaultEmpty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.photo_library_outlined,
            size: 56,
            color: theme.disabledColor,
          ),
          const SizedBox(height: 16),
          Text('No photos', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Nothing in this folder yet.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.error_outline,
            size: 56,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 16),
          const Text('Could not load the album', textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 20),
          OutlinedButton(
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
