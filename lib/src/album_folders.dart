import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'album_films.dart';
import 'album_gear_page.dart';
import 'album_photo.dart';
import 'album_widgets.dart';

/// One folder in the album's folder tree, with the photos inside it counted.
///
/// Only folders that hold photos, directly or deeper down, appear, so the tree
/// never lists empty branches.
class AlbumFolderNode {
  AlbumFolderNode._(
    this.path,
    this.name,
    this.parent,
    this.depth, {
    this.filmHeader = false,
    this.filmIcon,
  });

  /// Normalized path. This is the form exclusions are stored and compared in.
  final String path;

  final String name;
  final AlbumFolderNode? parent;

  /// 0 for the album's own folder.
  final int depth;

  /// A film stock. Its row wears the film box, and the folders under it are
  /// the rolls.
  final bool filmHeader;

  /// Box art for [filmHeader], or null for a letter tile.
  final String? filmIcon;

  /// Subfolders, sorted by name.
  final List<AlbumFolderNode> children = [];

  /// Photos directly in this folder.
  int directCount = 0;

  /// Photos in this folder and everything below it.
  int totalCount = 0;
}

/// Builds the folder tree for [photos], rooted at [root].
AlbumFolderNode buildAlbumFolderTree(List<AlbumPhoto> photos, String root) {
  final rootPath = p.normalize(root);
  final rootName = p.basename(rootPath);
  final top = AlbumFolderNode._(
    rootPath,
    rootName.isEmpty ? rootPath : rootName,
    null,
    0,
  );
  final byPath = <String, AlbumFolderNode>{rootPath: top};
  // Photos mostly share a handful of folders, so the work of normalizing and
  // looking up is done once per distinct folder string, not once per photo.
  final byRawDir = <String, AlbumFolderNode>{};

  AlbumFolderNode nodeFor(String directory) {
    final existing = byPath[directory];
    if (existing != null) return existing;
    final parentPath = p.dirname(directory);
    // A folder outside the root cannot occur for a scan of the root. If it
    // somehow did, it is filed at the top rather than climbing forever.
    final parent = parentPath == directory ? top : nodeFor(parentPath);
    final node = AlbumFolderNode._(
      directory,
      p.basename(directory),
      parent,
      parent.depth + 1,
    );
    parent.children.add(node);
    byPath[directory] = node;
    return node;
  }

  for (final photo in photos) {
    final raw = p.dirname(photo.file.path);
    final node = byRawDir.putIfAbsent(raw, () => nodeFor(p.normalize(raw)));
    node.directCount++;
  }

  int finish(AlbumFolderNode node) {
    node.children.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    var total = node.directCount;
    for (final child in node.children) {
      total += finish(child);
    }
    return node.totalCount = total;
  }

  finish(top);
  return top;
}

/// Every folder under [root]. A film tree drops folders that hold no pictures,
/// so an empty `120` or `135` folder is not listed. A digital tree keeps
/// empty folders.
///
/// Names that start with a dot are skipped. [AlbumFolderNode.directCount] is
/// the pictures sitting directly in that folder.
Future<AlbumFolderNode> buildAlbumDirectoryTree(
  String root, {
  bool filmHeader = false,
  String? filmIcon,
}) async {
  final rootPath = p.normalize(root);
  final rootName = p.basename(rootPath);
  final top = AlbumFolderNode._(
    rootPath,
    rootName.isEmpty ? rootPath : rootName,
    null,
    0,
    filmHeader: filmHeader,
    filmIcon: filmIcon,
  );

  Future<void> walk(Directory directory, AlbumFolderNode node) async {
    if (!await directory.exists()) return;
    final children = <AlbumFolderNode>[];
    await for (final entity in directory.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      if (entity is Directory) {
        final child = AlbumFolderNode._(
          p.normalize(entity.path),
          name,
          node,
          node.depth + 1,
        );
        await walk(entity, child);
        children.add(child);
        continue;
      }
      if (entity is File &&
          albumImageExtensions.contains(p.extension(name).toLowerCase())) {
        node.directCount++;
      }
    }
    children.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    for (final child in children) {
      // Lightroom Classic writes its JPEG exports into a JPG folder beside
      // the originals. That folder is the same roll, not another one.
      if (child.name.toLowerCase() == 'jpg' && node.directCount > 0) {
        node.directCount += child.directCount;
        continue;
      }
      node.children.add(child);
    }
  }

  await walk(Directory(rootPath), top);

  int finish(AlbumFolderNode node) {
    var total = node.directCount;
    for (final child in node.children) {
      total += finish(child);
    }
    return node.totalCount = total;
  }

  finish(top);
  if (filmHeader) _dropEmptyFolders(top);
  return top;
}

/// A film folder with no pictures is not shown. An empty `120` or `135`
/// under Superia stays hidden.
void _dropEmptyFolders(AlbumFolderNode node) {
  node.children.removeWhere((child) => child.totalCount == 0);
  for (final child in node.children) {
    _dropEmptyFolders(child);
  }
}

/// [photos] without those in an excluded folder or any folder below one.
/// Order is kept. [excluded] holds folder paths; they need not be normalized.
List<AlbumPhoto> filterAlbumByExcluded(
  List<AlbumPhoto> photos,
  String root,
  Set<String> excluded,
) {
  if (excluded.isEmpty) return photos;
  final rootPath = p.normalize(root);
  final blocked = {for (final path in excluded) p.normalize(path)};
  final hiddenByDir = <String, bool>{};

  bool hidden(String directory) {
    var current = p.normalize(directory);
    while (true) {
      if (blocked.contains(current)) return true;
      if (current == rootPath) return false;
      final parent = p.dirname(current);
      if (parent == current) return false;
      current = parent;
    }
  }

  return [
    for (final photo in photos)
      if (!hiddenByDir.putIfAbsent(
        p.dirname(photo.file.path),
        () => hidden(p.dirname(photo.file.path)),
      ))
        photo,
  ];
}

/// The photos in [folder] or any folder below it, order kept. [folder] need
/// not be normalized.
List<AlbumPhoto> filterAlbumToFolder(List<AlbumPhoto> photos, String folder) {
  final target = p.normalize(folder);
  final inside = <String, bool>{};
  return [
    for (final photo in photos)
      if (inside.putIfAbsent(p.dirname(photo.file.path), () {
        final directory = p.normalize(p.dirname(photo.file.path));
        return directory == target || p.isWithin(target, directory);
      }))
        photo,
  ];
}

/// What a folder's checkbox shows.
enum AlbumFolderState {
  /// The folder and everything below it is shown.
  included,

  /// The folder is hidden: it, or a folder above it, was excluded.
  excluded,

  /// The folder is shown but something below it is hidden.
  partial,
}

/// State of every folder under [root], keyed by [AlbumFolderNode.path], in one
/// pass over the tree. [excluded] must hold normalized paths.
Map<String, AlbumFolderState> albumFolderStates(
  AlbumFolderNode root,
  Set<String> excluded,
) {
  final states = <String, AlbumFolderState>{};

  /// Returns whether anything at or below [node] is hidden.
  bool visit(AlbumFolderNode node, bool hiddenAbove) {
    final hidden = hiddenAbove || excluded.contains(node.path);
    var anyHiddenBelow = false;
    for (final child in node.children) {
      if (visit(child, hidden)) anyHiddenBelow = true;
    }
    states[node.path] = hidden
        ? AlbumFolderState.excluded
        : anyHiddenBelow
        ? AlbumFolderState.partial
        : AlbumFolderState.included;
    return hidden || anyHiddenBelow;
  }

  visit(root, false);
  return states;
}

/// The exclusions after the user clicks [node]'s checkbox, given the
/// [state] it was showing. [excluded] must hold normalized paths.
///
/// - A shown folder is hidden, along with everything below it.
/// - A partly shown folder becomes fully shown.
/// - A hidden folder is shown again. If it is hidden only because a folder
///   above it is, that folder is un-hidden and its other branches take over
///   the exclusion, so just this one comes back.
Set<String> albumToggleFolder(
  AlbumFolderNode node,
  Set<String> excluded,
  AlbumFolderState state,
) {
  final next = {...excluded};

  void dropBelow() => next.removeWhere(
    (path) => path != node.path && p.isWithin(node.path, path),
  );

  switch (state) {
    case AlbumFolderState.included:
      dropBelow();
      next.add(node.path);
    case AlbumFolderState.partial:
      dropBelow();
    case AlbumFolderState.excluded:
      if (next.remove(node.path)) return next;

      AlbumFolderNode? ancestor = node.parent;
      while (ancestor != null && !next.contains(ancestor.path)) {
        ancestor = ancestor.parent;
      }
      if (ancestor == null) return next;

      next.remove(ancestor.path);
      // Walk down from the excluded ancestor to the folder, excluding every
      // sibling branch passed on the way.
      final chain = <AlbumFolderNode>[];
      for (var n = node; n != ancestor; n = n.parent!) {
        chain.add(n);
      }
      var current = ancestor;
      for (final step in chain.reversed) {
        for (final sibling in current.children) {
          if (sibling != step) next.add(sibling.path);
        }
        current = step;
      }
  }
  return next;
}

/// What a folder's menu can do.
enum _FolderAction { focus, reveal, meta, import, rename, delete }

/// Folder trees, one per source folder, with a checkbox on every folder.
/// Unchecking one hides its photos from the album; the hidden folders can be
/// brought back at any time. Source folders can also be added and removed.
class AlbumFolderPanel extends StatefulWidget {
  const AlbumFolderPanel({
    super.key,
    required this.roots,
    required this.excluded,
    required this.onChanged,
    required this.shown,
    required this.total,
    this.highlighted,
    this.focused,
    this.onFocus,
    this.onDeleteFolder,
    this.onRenameFolder,
    this.onRevealFolder,
    this.onImportFolder,
    this.onFolderMeta,
    this.expandRoots = false,
    this.loading = false,
    this.onClose,
    this.onAddFolder,
    this.onRemoveFolder,
    this.filmKinds = const [],
    this.locatedFilmKeys = const {},
    this.filmFolderLabels = const {},
    this.selectedFilmKey,
    this.onFilmKindTap,
    this.onAssignFilmKind,
    this.onClearFilmKind,
    this.openFilmFolders = const [],
    this.filmPaths = const [],
    this.onFilmHeader,
    this.onPickFilmLibrary,
    this.filmLibraryChosen = false,
    this.showFolderTree = true,
    this.heading = 'Folders',
  });

  /// The source folders, each the top of its own tree.
  final List<AlbumFolderNode> roots;

  /// Adds an "add folder" button when set.
  final VoidCallback? onAddFolder;

  /// Adds a remove button to every source folder when set. Called with the
  /// source's path.
  final ValueChanged<String>? onRemoveFolder;

  /// ApertureDiary's film kinds, shown in the film tab.
  final List<AlbumFilmKind> filmKinds;

  /// Icon keys that already have a folder under the film library.
  final Set<String> locatedFilmKeys;

  /// Folder name to show for a located kind, such as the name Windows kept.
  final Map<String, String> filmFolderLabels;

  /// Icon key of the film open in the waterfall.
  final String? selectedFilmKey;

  /// Opens the pictures for a kind that has a folder.
  final ValueChanged<AlbumFilmKind>? onFilmKindTap;

  /// Right-click: the user picks the folder for this kind.
  final ValueChanged<AlbumFilmKind>? onAssignFilmKind;

  /// Right-click: drop the folder linked to this kind. The pictures stay.
  final ValueChanged<AlbumFilmKind>? onClearFilmKind;

  /// Folders directly under the open film.
  final List<AlbumFolderNode> openFilmFolders;

  /// Paths of film stocks. A folder at or under one of these is a film folder.
  final List<String> filmPaths;

  /// Opens or closes the film at this path: its folders fold out under the
  /// film box, and its pictures fill the grid.
  final ValueChanged<String>? onFilmHeader;

  /// Asks for the folder that holds the film scans.
  final VoidCallback? onPickFilmLibrary;

  /// Whether a film library has been chosen, so the button reads Change.
  final bool filmLibraryChosen;

  /// The digital folder tree. Off when the panel is showing films.
  final bool showFolderTree;

  /// Title at the top of the panel.
  final String heading;

  /// Normalized paths of the excluded folders.
  final Set<String> excluded;

  final ValueChanged<Set<String>> onChanged;

  /// Photos currently shown, and photos found in all folders.
  final int shown;
  final int total;

  /// Adds "Delete folder" to the menu of every folder but a source, with the
  /// folder to delete. The panel only asks; confirming and deleting are the
  /// caller's.
  final ValueChanged<AlbumFolderNode>? onDeleteFolder;

  /// Adds "Rename images…" to the menu of every folder, with the folder whose
  /// images are to be renamed. The panel only asks; the rest is the caller's.
  final ValueChanged<AlbumFolderNode>? onRenameFolder;

  /// Adds "Show in Explorer" to the menu of every folder, with the folder to
  /// show. The panel only asks; opening the file manager is the caller's.
  final ValueChanged<AlbumFolderNode>? onRevealFolder;

  /// Adds "Import from camera…" to the menu of every folder, with the folder
  /// the import creates its new folder in.
  final ValueChanged<AlbumFolderNode>? onImportFolder;

  /// Right-click "Metadata…" for a folder. Used for a film's folders.
  final ValueChanged<AlbumFolderNode>? onFolderMeta;

  /// Opens each root when the panel is first shown, so the folders under a
  /// film are visible without an extra click.
  final bool expandRoots;

  /// Normalized path of the folder to mark, the one of the photo open in the
  /// preview. Its row is shaded, and the tree opens and scrolls as needed to
  /// show it. While no photo is open, [focused] is shaded instead.
  final String? highlighted;

  /// Normalized path of the folder the album is narrowed to, if any. Its row
  /// is shaded while no photo is open. The tree opens it and folds the other
  /// albums, and its menu offers the way back.
  final String? focused;

  /// Called with a folder's path when its row is clicked, to narrow the album
  /// to it, or to widen it again when it is the focused one. Without it a
  /// click on a row ticks its box, as the box itself does.
  final ValueChanged<String>? onFocus;

  /// Whether the folder is still being scanned, so the counts may grow.
  final bool loading;

  /// Adds a close button when set.
  final VoidCallback? onClose;

  @override
  State<AlbumFolderPanel> createState() => _AlbumFolderPanelState();
}

class _AlbumFolderPanelState extends State<AlbumFolderPanel> {
  /// Folders the user has opened. Everything starts collapsed.
  final Set<String> _opened = {};

  /// Which film group is listed. Null until a button is clicked, so the list
  /// opens on films that have a folder when any do.
  bool? _filmLocated;

  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    if (widget.expandRoots) {
      for (final root in widget.roots) {
        _opened.add(root.path);
      }
    }
    final focused = widget.focused;
    final highlighted = widget.highlighted;
    if (focused != null) {
      _reveal(focused, openTarget: true);
    } else if (highlighted != null) {
      _reveal(highlighted, openTarget: false);
    }
  }

  @override
  void didUpdateWidget(AlbumFolderPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final focused = widget.focused;
    final highlighted = widget.highlighted;
    if (widget.expandRoots) {
      for (final root in widget.roots) {
        _opened.add(root.path);
      }
    }
    if (focused != null && focused != oldWidget.focused) {
      // An album was clicked: it opens, and the others fold away.
      _reveal(focused, openTarget: true);
    } else if (highlighted != null && highlighted != oldWidget.highlighted) {
      _reveal(highlighted, openTarget: false);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool _isOpen(AlbumFolderNode node) => _opened.contains(node.path);

  bool _isFilmPath(String path) {
    final normal = p.normalize(path);
    for (final root in widget.filmPaths) {
      final film = p.normalize(root);
      if (normal == film || p.isWithin(film, normal)) return true;
    }
    return false;
  }

  Offset _menuOrigin() {
    final box = context.findRenderObject();
    if (box is! RenderBox) return Offset.zero;
    return box.localToGlobal(Offset.zero);
  }

  Future<void> _filmKindMenu(
    AlbumFilmKind kind,
    Offset position,
    bool located,
  ) async {
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        if (widget.onAssignFilmKind != null)
          const PopupMenuItem(value: 'set', child: Text('Set folder…')),
        if (located && widget.onClearFilmKind != null)
          const PopupMenuItem(value: 'clear', child: Text('Clear folder')),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'set':
        widget.onAssignFilmKind?.call(kind);
      case 'clear':
        widget.onClearFilmKind?.call(kind);
    }
  }

  void _openFilmHeader(AlbumFolderNode node) {
    if (node.children.isNotEmpty) _toggleOpen(node);
    widget.onFilmHeader?.call(node.path);
  }

  /// Narrows the album to [node], or widens it again when it is the one.
  void _focus(AlbumFolderNode node, AlbumFolderState state) {
    // A hidden folder cannot be looked at, so clicking one brings it back
    // first.
    if (state == AlbumFolderState.excluded) {
      widget.onChanged(albumToggleFolder(node, widget.excluded, state));
    }
    widget.onFocus!(node.path);
  }

  /// Whether the folder has anything to put in its menu.
  bool _hasMenu(AlbumFolderNode node) =>
      widget.onFocus != null ||
      widget.onRenameFolder != null ||
      widget.onRevealFolder != null ||
      widget.onImportFolder != null ||
      widget.onFolderMeta != null ||
      (widget.onDeleteFolder != null && node.depth > 0);

  /// The folder's menu, opened by a right click, a long press or the button
  /// on its row, with its corner at [position] on screen.
  Future<void> _showMenu(
    AlbumFolderNode node,
    AlbumFolderState state,
    Offset position,
  ) async {
    final scheme = Theme.of(context).colorScheme;
    final focused = node.path == widget.focused;
    final canDelete =
        widget.onDeleteFolder != null &&
        node.depth > 0 &&
        !_isFilmPath(node.path);
    final choice = await showMenu<_FolderAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        if (widget.onFocus != null)
          PopupMenuItem(
            value: _FolderAction.focus,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                focused ? Icons.unfold_more_rounded : Icons.folder_open_rounded,
              ),
              title: Text(
                focused ? 'Show the whole album' : 'Show only this folder',
              ),
            ),
          ),
        if (widget.onRevealFolder != null)
          const PopupMenuItem(
            value: _FolderAction.reveal,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.folder_shared_outlined),
              title: Text('Show in Explorer'),
            ),
          ),
        if (widget.onFolderMeta != null && _isFilmPath(node.path))
          const PopupMenuItem(
            value: _FolderAction.meta,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.edit_note_outlined),
              title: Text('Metadata…'),
            ),
          ),
        if (widget.onImportFolder != null && !_isFilmPath(node.path))
          const PopupMenuItem(
            value: _FolderAction.import,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.add_photo_alternate_outlined),
              title: Text('Import from camera…'),
            ),
          ),
        if (widget.onRenameFolder != null && !_isFilmPath(node.path))
          const PopupMenuItem(
            value: _FolderAction.rename,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.drive_file_rename_outline),
              title: Text('Rename images…'),
            ),
          ),
        if (canDelete) ...[
          if (widget.onFocus != null ||
              widget.onRevealFolder != null ||
              widget.onImportFolder != null ||
              widget.onRenameFolder != null)
            const PopupMenuDivider(),
          PopupMenuItem(
            value: _FolderAction.delete,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline_rounded, color: scheme.error),
              title: Text(
                'Delete folder…',
                style: TextStyle(color: scheme.error),
              ),
            ),
          ),
        ],
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case _FolderAction.focus:
        _focus(node, state);
      case _FolderAction.reveal:
        widget.onRevealFolder!(node);
      case _FolderAction.meta:
        widget.onFolderMeta!(node);
      case _FolderAction.import:
        widget.onImportFolder!(node);
      case _FolderAction.rename:
        widget.onRenameFolder!(node);
      case _FolderAction.delete:
        widget.onDeleteFolder!(node);
      case null:
        break;
    }
  }

  /// Opens the folders above [target] and, with [openTarget], the folder
  /// itself to show what is inside it; closes every album but the one it is
  /// in, so the tree shows one album at a time; then scrolls its row into
  /// view. Does nothing while the folder is not in the tree, as during a
  /// scan that has not reached it yet.
  void _reveal(String target, {required bool openTarget}) {
    AlbumFolderNode? node;
    for (final root in widget.roots) {
      if (root.path == target || p.isWithin(root.path, target)) {
        node = root;
        break;
      }
    }
    if (node == null) return;
    final above = <AlbumFolderNode>[];
    while (node!.path != target) {
      above.add(node);
      AlbumFolderNode? next;
      for (final child in node.children) {
        if (child.path == target || p.isWithin(child.path, target)) {
          next = child;
          break;
        }
      }
      if (next == null) return;
      node = next;
    }
    // The album is the folder one level under its source. The source itself,
    // and the photos lying in it, are in none.
    final album = above.length > 1 ? above[1] : (above.isEmpty ? null : node);
    final inAlbum = album == null
        ? (String _) => false
        : (String path) => path == album.path || p.isWithin(album.path, path);

    void closeOthers(AlbumFolderNode folder) {
      for (final child in folder.children) {
        if (!inAlbum(child.path) && _isOpen(child)) {
          _opened.remove(child.path);
        }
        closeOthers(child);
      }
    }

    widget.roots.forEach(closeOthers);

    for (final ancestor in above) {
      _opened.add(ancestor.path);
    }
    if (openTarget && node.children.isNotEmpty) {
      _opened.add(node.path);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(target));
  }

  void _scrollTo(String path) {
    if (!mounted || !_scroll.hasClients) return;
    final index = _rows().indexWhere((node) => node.path == path);
    if (index < 0) return;
    final extent = _FolderRow.heightFor(context);
    const padding = 6.0;
    final top = padding + index * extent;
    final position = _scroll.position;
    double? to;
    if (top - padding < position.pixels) {
      to = top - padding;
    } else if (top + extent + padding >
        position.pixels + position.viewportDimension) {
      to = top + extent + padding - position.viewportDimension;
    }
    if (to == null) return;
    _scroll.animateTo(
      to.clamp(position.minScrollExtent, position.maxScrollExtent),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _toggleOpen(AlbumFolderNode node) {
    setState(() {
      if (!_opened.remove(node.path)) _opened.add(node.path);
    });
  }

  /// The rows currently visible: the tree flattened, skipping closed folders.
  List<AlbumFolderNode> _rows() {
    final rows = <AlbumFolderNode>[];
    void add(AlbumFolderNode node) {
      rows.add(node);
      if (!_isOpen(node)) return;
      node.children.forEach(add);
    }

    widget.roots.forEach(add);
    return rows;
  }

  /// What to call each source. The folder's own name, unless another source
  /// has the same, in which case the folder it sits in is added.
  Map<String, String> _labels() {
    final names = <String, int>{};
    for (final root in widget.roots) {
      names.update(root.name, (n) => n + 1, ifAbsent: () => 1);
    }
    return {
      for (final root in widget.roots)
        root.path: names[root.name]! > 1
            ? '${root.name} (${p.basename(p.dirname(root.path))})'
            : root.name,
    };
  }

  Widget _filmList(ThemeData theme, ColorScheme scheme) {
    final locatedCount = widget.filmKinds
        .where((kind) => widget.locatedFilmKeys.contains(kind.iconKey))
        .length;
    final showLocated = _filmLocated ?? locatedCount > 0;
    final kinds = [
      for (final kind in widget.filmKinds)
        if (widget.locatedFilmKeys.contains(kind.iconKey) == showLocated) kind,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: SegmentedButton<bool>(
            expandedInsets: EdgeInsets.zero,
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              textStyle: theme.textTheme.labelMedium,
            ),
            segments: [
              ButtonSegment(value: true, label: Text('Located $locatedCount')),
              ButtonSegment(
                value: false,
                label: Text(
                  'No location ${widget.filmKinds.length - locatedCount}',
                ),
              ),
            ],
            selected: {showLocated},
            onSelectionChanged: (next) {
              setState(() => _filmLocated = next.first);
            },
          ),
        ),
        if (widget.onPickFilmLibrary != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: widget.onPickFilmLibrary,
              child: Text(
                widget.filmLibraryChosen ? 'Change' : 'Choose folder',
              ),
            ),
          ),
        Expanded(
          child: kinds.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      showLocated
                          ? 'No film has a folder yet.'
                          : 'Every film has a folder.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  itemCount: kinds.length,
                  itemBuilder: (context, index) {
                    final kind = kinds[index];
                    final marked = kind.iconKey == widget.selectedFilmKey;
                    final located = widget.locatedFilmKeys.contains(
                      kind.iconKey,
                    );
                    return Column(
                      children: [
                        Material(
                          color: marked
                              ? scheme.secondaryContainer
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: widget.onFilmKindTap == null
                                ? null
                                : () => widget.onFilmKindTap!(kind),
                            onSecondaryTapUp:
                                widget.onAssignFilmKind == null &&
                                    widget.onClearFilmKind == null
                                ? null
                                : (details) => _filmKindMenu(
                                    kind,
                                    details.globalPosition,
                                    located,
                                  ),
                            onLongPress:
                                widget.onAssignFilmKind == null &&
                                    widget.onClearFilmKind == null
                                ? null
                                : () => _filmKindMenu(
                                    kind,
                                    _menuOrigin(),
                                    located,
                                  ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 4,
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 40,
                                    height: 40,
                                    child: AlbumFilmIcon(
                                      asset: kind.iconAsset,
                                      name: kind.name,
                                      marked: marked,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          kind.name,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodyMedium
                                              ?.copyWith(
                                                color: marked
                                                    ? scheme
                                                          .onSecondaryContainer
                                                    : null,
                                                fontWeight: marked
                                                    ? FontWeight.w700
                                                    : null,
                                              ),
                                        ),
                                        Text(
                                          located
                                              ? (widget.filmFolderLabels[kind
                                                        .iconKey] ??
                                                    kind.folderName)
                                              : 'Right-click to set folder',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                                color: located
                                                    ? scheme.onSurfaceVariant
                                                    : scheme.outline,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final states = <String, AlbumFolderState>{
      for (final root in widget.roots)
        ...albumFolderStates(root, widget.excluded),
    };
    final anyHidden = states.values.any((s) => s != AlbumFolderState.included);
    final labels = _labels();
    final rows = _rows();
    final hiddenCount = widget.total - widget.shown;

    return Material(
      color: scheme.surfaceContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.heading,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (anyHidden)
                  TextButton(
                    onPressed: () => widget.onChanged(const {}),
                    child: const Text('Show all'),
                  ),
                IconButton(
                  tooltip: 'Film list',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AlbumFilmListPage(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.movie_creation_outlined),
                ),
                IconButton(
                  tooltip: 'Cameras',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AlbumGearPage(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.photo_camera_outlined),
                ),
                if (widget.onAddFolder != null)
                  IconButton(
                    tooltip: 'Add folder',
                    onPressed: widget.onAddFolder,
                    icon: const Icon(Icons.create_new_folder_outlined),
                  ),
                if (widget.onClose != null)
                  IconButton(
                    tooltip: 'Close',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    hiddenCount > 0
                        ? '${albumFormatCount(widget.shown)} of '
                              '${albumFormatCount(widget.total)} photos shown'
                        : '${albumFormatCount(widget.total)} '
                              '${widget.total == 1 ? 'photo' : 'photos'}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (widget.loading) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  ),
                ],
              ],
            ),
          ),
          if (widget.filmKinds.isNotEmpty)
            Expanded(child: _filmList(theme, scheme))
          else if (widget.onPickFilmLibrary != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: widget.onPickFilmLibrary,
                child: const Text('Choose folder'),
              ),
            ),
          if (widget.showFolderTree) ...[
            Divider(
              height: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
            Expanded(
              child:
                  (widget.roots.isEmpty ||
                      // A lone folder with nothing to expand is not worth a tree,
                      // unless its row is how it gets removed.
                      (widget.roots.length == 1 &&
                          !widget.roots.single.filmHeader &&
                          widget.roots.single.children.isEmpty &&
                          widget.onRemoveFolder == null &&
                          widget.onImportFolder == null &&
                          !widget.loading))
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        widget.roots.isEmpty
                            ? 'No folders yet.'
                            : 'No subfolders with photos.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemExtent: _FolderRow.heightFor(context),
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final node = rows[index];
                        final state = states[node.path]!;
                        final remove = widget.onRemoveFolder;
                        final marked = widget.highlighted ?? widget.focused;
                        return _FolderRow(
                          node: node,
                          label: labels[node.path] ?? node.name,
                          reserveRemove: remove != null,
                          onRemove:
                              node.depth == 0 &&
                                  remove != null &&
                                  !node.filmHeader
                              ? () => remove(node.path)
                              : null,
                          state: state,
                          highlighted: node.path == marked,
                          onTap: node.filmHeader
                              ? () => _openFilmHeader(node)
                              : widget.onFocus == null
                              ? null
                              : () => _focus(node, state),
                          onMenu: _hasMenu(node)
                              ? (position) => _showMenu(node, state, position)
                              : null,
                          open: _isOpen(node),
                          onToggleOpen: node.children.isEmpty
                              ? null
                              : node.filmHeader
                              ? () => _openFilmHeader(node)
                              : () => _toggleOpen(node),
                          onToggleChecked: () => widget.onChanged(
                            albumToggleFolder(node, widget.excluded, state),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.node,
    required this.label,
    required this.onRemove,
    required this.reserveRemove,
    required this.state,
    required this.highlighted,
    required this.onTap,
    required this.onMenu,
    required this.open,
    required this.onToggleOpen,
    required this.onToggleChecked,
  });

  /// Height of a row at the default text size.
  static const double baseHeight = 40;

  /// Row height, grown to keep room for the name when text is larger than
  /// the default. List rows have a fixed extent, so it cannot follow the text
  /// by itself.
  static double heightFor(BuildContext context) {
    const defaultSize = 14.0; // Material 3 bodyMedium
    final size =
        Theme.of(context).textTheme.bodyMedium?.fontSize ?? defaultSize;
    final scaled = MediaQuery.textScalerOf(context).scale(size);
    return baseHeight * math.max(1, scaled / defaultSize);
  }

  final AlbumFolderNode node;

  /// The name shown. Differs from [AlbumFolderNode.name] only for a source
  /// folder whose name another source shares.
  final String label;

  /// Set for a source folder that can be removed.
  final VoidCallback? onRemove;

  /// Keeps the count of a row without a remove button in line with the rows
  /// that have one.
  final bool reserveRemove;

  final AlbumFolderState state;

  /// Whether this row is the one the tree is marking.
  final bool highlighted;

  /// What a click on the row does. Null ticks the box.
  final VoidCallback? onTap;

  /// Opens the folder's menu with its corner at the given spot on screen.
  /// Null when the folder has no menu.
  final ValueChanged<Offset>? onMenu;
  final bool open;

  /// Null for a folder with no subfolders.
  final VoidCallback? onToggleOpen;

  final VoidCallback onToggleChecked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hidden = state == AlbumFolderState.excluded;
    final textColor = hidden ? scheme.onSurfaceVariant : scheme.onSurface;

    final fill = highlighted ? scheme.secondaryContainer : Colors.transparent;

    return Semantics(
      selected: highlighted,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          // The open photo's folder, or the album the grid is narrowed to.
          // Rounded in from the panel's edges.
          color: fill,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: GestureDetector(
            // A long press is how a touch screen asks for the menu; a right
            // click is how a mouse does.
            onLongPressStart: onMenu == null
                ? null
                : (details) => onMenu!(details.globalPosition),
            child: InkWell(
              onTap: onTap ?? onToggleChecked,
              onSecondaryTapUp: onMenu == null
                  ? null
                  : (details) => onMenu!(details.globalPosition),
              child: Padding(
                padding: EdgeInsets.only(left: 16.0 * node.depth, right: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 28,
                      child: onToggleOpen == null
                          ? null
                          : InkResponse(
                              onTap: onToggleOpen,
                              radius: 16,
                              child: Icon(
                                open
                                    ? Icons.expand_more_rounded
                                    : Icons.chevron_right_rounded,
                                size: 20,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                    ),
                    if (!node.filmHeader) ...[
                      Checkbox(
                        value: switch (state) {
                          AlbumFolderState.included => true,
                          AlbumFolderState.excluded => false,
                          AlbumFolderState.partial => null,
                        },
                        tristate: true,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: (_) => onToggleChecked(),
                      ),
                      const SizedBox(width: 4),
                    ],
                    if (node.filmHeader)
                      SizedBox(
                        width: 32,
                        height: 32,
                        child: AlbumFilmIcon(
                          asset: node.filmIcon,
                          name: node.name,
                          marked: highlighted,
                        ),
                      )
                    else
                      Icon(
                        hidden
                            ? Icons.folder_off_outlined
                            : Icons.folder_outlined,
                        size: 20,
                        color: hidden
                            ? scheme.outline
                            : scheme.onSurfaceVariant,
                      ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Tooltip(
                        // A source's full path tells apart folders that look alike.
                        message: node.depth == 0 ? node.path : '',
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: highlighted && !hidden
                                ? scheme.onSecondaryContainer
                                : textColor,
                            fontWeight: highlighted ? FontWeight.w700 : null,
                            decoration: hidden
                                ? TextDecoration.lineThrough
                                : null,
                            decorationColor: scheme.outline,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      albumFormatCount(node.totalCount),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (onRemove != null)
                      IconButton(
                        tooltip: 'Remove folder',
                        onPressed: onRemove,
                        iconSize: 18,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(
                          width: 32,
                          height: 32,
                        ),
                        padding: EdgeInsets.zero,
                        color: scheme.onSurfaceVariant,
                        icon: const Icon(Icons.close_rounded),
                      )
                    else if (onMenu != null)
                      Builder(
                        builder: (buttonContext) => IconButton(
                          tooltip: 'Folder options',
                          onPressed: () {
                            // Opens just under the button.
                            final box =
                                buttonContext.findRenderObject()! as RenderBox;
                            onMenu!(
                              box.localToGlobal(
                                Offset(box.size.width, box.size.height),
                              ),
                            );
                          },
                          iconSize: 18,
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints.tightFor(
                            width: 32,
                            height: 32,
                          ),
                          padding: EdgeInsets.zero,
                          color: scheme.onSurfaceVariant,
                          icon: const Icon(Icons.more_vert_rounded),
                        ),
                      )
                    else if (reserveRemove)
                      const SizedBox(width: 32),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
