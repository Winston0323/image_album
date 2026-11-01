import 'package:flutter/material.dart';

import 'album_rename.dart';
import 'album_widgets.dart';

/// What the user asked for in the rename dialog.
class AlbumRenameRequest {
  const AlbumRenameRequest({required this.prefix, required this.recursive});

  /// The name to give, already made safe by [albumSanitizePrefix].
  final String prefix;

  /// Whether the folders inside the folder are renamed too.
  final bool recursive;
}

/// Asks how to rename the images in the folder called [folderName]: the
/// prefix, and whether the folders inside it are included. [directCount] is
/// how many images lie in the folder itself, [deepCount] how many with
/// everything below it. [exampleExtension] (with its dot) shapes the example
/// name. Null when cancelled.
Future<AlbumRenameRequest?> showAlbumRenameDialog(
  BuildContext context, {
  required String folderName,
  required int directCount,
  required int deepCount,
  String exampleExtension = '.jpg',
}) {
  return showDialog<AlbumRenameRequest>(
    context: context,
    builder: (context) => _RenameDialog(
      folderName: folderName,
      directCount: directCount,
      deepCount: deepCount,
      exampleExtension: exampleExtension,
    ),
  );
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({
    required this.folderName,
    required this.directCount,
    required this.deepCount,
    required this.exampleExtension,
  });

  final String folderName;
  final int directCount;
  final int deepCount;
  final String exampleExtension;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _prefix = TextEditingController(
    text: albumSanitizePrefix(widget.folderName),
  );
  bool _recursive = false;

  @override
  void dispose() {
    _prefix.dispose();
    super.dispose();
  }

  /// There is a choice only when the folders inside hold images the folder
  /// itself does not.
  bool get _hasSubfolders => widget.deepCount > widget.directCount;

  int get _count => _recursive ? widget.deepCount : widget.directCount;

  String get _clean => albumSanitizePrefix(_prefix.text);

  bool get _canRename => _clean.isNotEmpty && _count > 0;

  void _submit() {
    if (!_canRename) return;
    Navigator.of(
      context,
    ).pop(AlbumRenameRequest(prefix: _clean, recursive: _recursive));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final total = _count;
    final example = _clean.isEmpty ? 'name' : _clean;
    final first = '${example}_${albumOrderLabel(1, total)}';
    final last = '${example}_${albumOrderLabel(total < 1 ? 1 : total, total)}';

    return AlertDialog(
      icon: const Icon(Icons.drive_file_rename_outline),
      title: Text('Rename images in "${widget.folderName}"'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _prefix,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Name',
                helperText: 'Images become name_001, name_002, …',
              ),
            ),
            if (_hasSubfolders) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                value: _recursive,
                onChanged: (value) =>
                    setState(() => _recursive = value ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Include the folders inside'),
                subtitle: Text(
                  'Each folder is numbered on its own, from 001.',
                  style: TextStyle(color: muted),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              total == 0
                  ? 'There are no images to rename.'
                  : '${albumFormatCount(total)} '
                        '${total == 1 ? 'image' : 'images'}: '
                        '$first${widget.exampleExtension}'
                        '${total > 1 ? ' … $last${widget.exampleExtension}' : ''}',
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            const SizedBox(height: 4),
            Text(
              'Files are numbered in name order, and keep their extensions. '
              'This cannot be undone.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _canRename ? _submit : null,
          child: const Text('Rename'),
        ),
      ],
    );
  }
}
