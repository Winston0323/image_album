import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'album_photo.dart';
import 'album_widgets.dart';

/// One folder in the album's folder tree, with the photos inside it counted.
///
/// Only folders that hold photos, directly or deeper down, appear, so the tree
/// never lists empty branches.
class AlbumFolderNode {
  AlbumFolderNode._(this.path, this.name, this.parent, this.depth);

  /// Normalized path. This is the form exclusions are stored and compared in.
  final String path;

  final String name;
  final AlbumFolderNode? parent;

  /// 0 for the album's own folder.
  final int depth;

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
    this.loading = false,
    this.onClose,
    this.onAddFolder,
    this.onRemoveFolder,
  });

  /// The source folders, each the top of its own tree.
  final List<AlbumFolderNode> roots;

  /// Adds an "add folder" button when set.
  final VoidCallback? onAddFolder;

  /// Adds a remove button to every source folder when set. Called with the
  /// source's path.
  final ValueChanged<String>? onRemoveFolder;

  /// Normalized paths of the excluded folders.
  final Set<String> excluded;

  final ValueChanged<Set<String>> onChanged;

  /// Photos currently shown, and photos found in all folders.
  final int shown;
  final int total;

  /// Whether the folder is still being scanned, so the counts may grow.
  final bool loading;

  /// Adds a close button when set.
  final VoidCallback? onClose;

  @override
  State<AlbumFolderPanel> createState() => _AlbumFolderPanelState();
}

class _AlbumFolderPanelState extends State<AlbumFolderPanel> {
  /// Folders the user flipped from their default. Only the album's own folder
  /// starts open, which lists its direct subfolders and nothing deeper.
  final Set<String> _flipped = {};

  bool _isOpen(AlbumFolderNode node) =>
      (node.depth < 1) != _flipped.contains(node.path);

  void _toggleOpen(AlbumFolderNode node) {
    setState(() {
      if (!_flipped.remove(node.path)) _flipped.add(node.path);
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
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Folders',
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
                        widget.roots.single.children.isEmpty &&
                        widget.onRemoveFolder == null &&
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
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemExtent: _FolderRow.heightFor(context),
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final node = rows[index];
                      final state = states[node.path]!;
                      final remove = widget.onRemoveFolder;
                      return _FolderRow(
                        node: node,
                        label: labels[node.path] ?? node.name,
                        reserveRemove: remove != null,
                        onRemove: node.depth == 0 && remove != null
                            ? () => remove(node.path)
                            : null,
                        state: state,
                        open: _isOpen(node),
                        onToggleOpen: node.children.isEmpty
                            ? null
                            : () => _toggleOpen(node),
                        onToggleChecked: () => widget.onChanged(
                          albumToggleFolder(node, widget.excluded, state),
                        ),
                      );
                    },
                  ),
          ),
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

    return InkWell(
      onTap: onToggleChecked,
      child: Padding(
        padding: EdgeInsets.only(left: 4.0 + 16.0 * node.depth, right: 12),
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
            Icon(
              hidden ? Icons.folder_off_outlined : Icons.folder_outlined,
              size: 20,
              color: hidden ? scheme.outline : scheme.onSurfaceVariant,
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
                    color: textColor,
                    decoration: hidden ? TextDecoration.lineThrough : null,
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
            else if (reserveRemove)
              const SizedBox(width: 32),
          ],
        ),
      ),
    );
  }
}
