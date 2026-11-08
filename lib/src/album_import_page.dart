import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'album_camera.dart';
import 'album_drag_select.dart';
import 'album_photo.dart';
import 'album_images.dart';
import 'album_preview_page.dart';
import 'album_preview_zoom.dart';
import 'album_widgets.dart';

/// The camera's shots, one tile per shutter press, to pick from and copy into
/// a new folder inside [parentPath].
///
/// The left column asks which removable drives to read and what to call the
/// new folder. A drive is listed only when it has a `DCIM` folder, with the
/// card's name when it has one, and it starts ticked. The shots fill the
/// grid on the right. [cards] lists the drive roots (`D:\`). A picture and a
/// raw that share a name are one shot whichever drive each is on.
/// [pickFolder] asks for some other folder, a fixed disk or anywhere else.
/// Pops with the folder name and what the copy did, or null when the page is
/// closed without importing.
class AlbumImportPage extends StatefulWidget {
  const AlbumImportPage({
    super.key,
    required this.parentPath,
    required this.parentName,
    required this.cards,
    this.pickFolder,
  });

  final String parentPath;

  /// The folder the new one is created in, used in the name card.
  final String parentName;

  /// The removable drives to consider. Tests pass their own.
  final Future<List<String>> Function() cards;

  /// Asks the user for a folder of photos. When null, the system folder
  /// dialog is used where there is one.
  final Future<String?> Function([String? initialDirectory])? pickFolder;

  @override
  State<AlbumImportPage> createState() => _AlbumImportPageState();
}

class _AlbumImportPageState extends State<AlbumImportPage> {
  List<AlbumCameraShot>? _shots;
  String? _error;
  var _reading = true;

  /// True while a camera folder is still being looked for. The files are
  /// listed only after that, so the path is on screen before any photo is.
  var _finding = true;

  /// Drive letters and folder names that produced shots, in the order found.
  var _volumes = <String>[];

  /// Drive letters that were asked and did not answer.
  var _missed = <String>[];

  /// The full path being looked at now.
  String? _readingPath;

  AlbumImportKind _kind = AlbumImportKind.both;
  var _deleteAfter = false;
  var _busy = false;

  /// Paths of the file each picked shot is shown as.
  final Set<String> _picked = {};

  /// The shot a shift-click selects a range from: the last one picked.
  String? _anchor;

  final GlobalKey<AlbumDragSelectState> _dragKey = GlobalKey();
  final ScrollController _gridController = ScrollController();

  late final TextEditingController _name = TextEditingController(
    text: _today(),
  );

  /// Removable drives that have a DCIM folder, in path order.
  var _drives = <AlbumCameraDrive>[];
  final Set<String> _chosen = {};

  /// Drives still being asked whether they have a DCIM folder.
  var _pending = 0;

  /// Reads still walking a card or a chosen folder.
  var _jobs = 0;

  /// Files found for each root, per folder, so unticking a drive hides its
  /// shots without reading the card again.
  final Map<String, Map<String, List<AlbumPhoto>>> _files = {};

  /// Roots from "Choose a folder", shown whether or not a drive is ticked.
  final Set<String> _extra = {};

  /// Drives whose camera folders have already been read.
  final Set<String> _read = {};

  @override
  void initState() {
    super.initState();
    _loadDrives();
  }

  @override
  void dispose() {
    _gridController.dispose();
    _name.dispose();
    super.dispose();
  }

  String get _clean => albumFolderName(_name.text);

  static String _today() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  bool _shown(String root) => _extra.contains(root) || _chosen.contains(root);

  List<AlbumPhoto> _collected() => [
    for (final entry in _files.entries)
      if (_shown(entry.key))
        for (final files in entry.value.values) ...files,
  ];

  void _publish() {
    if (!mounted) return;
    final photos = _collected();
    final volumes = <String>[];
    for (final root in _files.keys) {
      if (!_shown(root)) continue;
      final label = albumCardLabel(root);
      if (!volumes.contains(label)) volumes.add(label);
    }
    setState(() {
      _volumes = volumes;
      _shots = albumGroupCameraShots(photos);
      // Shots start unpicked. Keep any the user already chose that are
      // still among the ones on screen.
      final ids = {for (final shot in _shots!) shot.display.file.path};
      _picked.removeWhere((id) => !ids.contains(id));
      if (_anchor != null && !_picked.contains(_anchor)) _anchor = null;
    });
  }

  void _finishIfIdle() {
    if (_pending > 0 || _jobs > 0 || !mounted) return;
    setState(() {
      _reading = false;
      _finding = false;
      _readingPath = null;
      _shots ??= const [];
    });
  }

  /// Lists [folder] of [root] into the waterfall, painting each batch before
  /// the next files are read. The same way the album's own grid fills.
  Future<void> _readFolder(String root, String folder) async {
    if (!mounted || !_shown(root)) return;
    setState(() {
      _reading = true;
      _finding = false;
      _readingPath = folder;
    });
    final files = await albumListCameraFiles(
      folder,
      onProgress: (soFar) async {
        if (!mounted || !_shown(root)) return;
        _files.putIfAbsent(root, () => {})[folder] = soFar;
        _publish();
        // Let the tiles paint, and be scrolled, before the next batch.
        await WidgetsBinding.instance.endOfFrame;
      },
    );
    if (!mounted || !_shown(root)) return;
    _files.putIfAbsent(root, () => {})[folder] = files;
    _publish();
  }

  Future<void> _readDrive(String root) async {
    if (_read.contains(root)) {
      _publish();
      return;
    }
    _read.add(root);
    _jobs++;
    try {
      final found = await albumCameraFolders(
        [root],
        onPath: (path) {
          if (!mounted || !_chosen.contains(root)) return;
          setState(() {
            _reading = true;
            _finding = true;
            _readingPath = path;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _missed = {
          for (final path in found.silent)
            if (!_volumes.contains(albumCardLabel(path))) albumCardLabel(path),
        }.toList();
      });
      for (final folder in found.reading) {
        if (!_chosen.contains(root)) break;
        await _readFolder(root, folder);
        if (!mounted) return;
      }
    } finally {
      _jobs--;
      _finishIfIdle();
    }
  }

  Future<void> _loadDrives() async {
    try {
      final roots = await widget.cards();
      if (!mounted) return;
      if (roots.isEmpty) {
        setState(() => _pending = 0);
        _finishIfIdle();
        return;
      }
      setState(() => _pending = roots.length);
      await Future.wait([for (final root in roots) _consider(root)]);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _pending = 0;
        _reading = false;
        _finding = false;
        _error = '$error';
      });
    }
  }

  /// Adds [root] to the drive card once its DCIM folder answers, then reads
  /// it. A root with no DCIM, or one that does not answer, is left off the
  /// card and does not hold up the ones that did.
  Future<void> _consider(String root) async {
    AlbumCameraDrive? drive;
    try {
      drive = await albumDriveIfDcim(root);
    } on Object {
      drive = null;
    }
    if (!mounted) return;
    setState(() {
      _pending--;
      if (drive != null) {
        _drives = [..._drives, drive]..sort((a, b) => a.root.compareTo(b.root));
        _chosen.add(drive.root);
      }
    });
    if (drive != null) await _readDrive(drive.root);
    _finishIfIdle();
  }

  void _toggleDrive(AlbumCameraDrive drive, bool on) {
    setState(() {
      if (on) {
        _chosen.add(drive.root);
      } else {
        _chosen.remove(drive.root);
      }
    });
    if (on) {
      _readDrive(drive.root);
    } else {
      _publish();
      _finishIfIdle();
    }
  }

  Future<void> _chooseFolder() async {
    final path = await (widget.pickFolder ?? albumPickFolder)();
    if (path == null || !mounted) return;
    final folders = await albumImportTargets(path);
    if (!mounted) return;
    if (folders.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No photos in ${albumCardLabel(path)}')),
      );
      return;
    }
    _jobs++;
    _extra.add(path);
    try {
      for (final folder in folders) {
        await _readFolder(path, folder);
        if (!mounted) return;
      }
    } finally {
      _jobs--;
      _finishIfIdle();
    }
  }

  List<AlbumDaySection> _sections(List<AlbumCameraShot> shots) =>
      groupAlbumByDay([for (final shot in shots) shot.display]);

  AlbumCameraShot? _shotOf(List<AlbumCameraShot> shots, AlbumPhoto photo) {
    for (final shot in shots) {
      for (final file in shot.files) {
        if (file.file.path == photo.file.path) return shot;
      }
    }
    return null;
  }

  void _toggle(AlbumCameraShot shot) {
    final id = shot.display.file.path;
    setState(() {
      if (!_picked.remove(id)) _picked.add(id);
      _anchor = id;
    });
  }

  /// Shift-click: adds every shot from the one picked last to [shot], leaving
  /// what is already picked alone. With nothing picked, [shot] is the start.
  void _selectRange(List<AlbumCameraShot> shots, AlbumCameraShot shot) {
    final ids = [for (final s in shots) s.display.file.path];
    final to = ids.indexOf(shot.display.file.path);
    if (to < 0) return;

    final start = _anchor;
    final from = start != null && _picked.contains(start)
        ? ids.indexOf(start)
        : -1;

    setState(() {
      if (from < 0) {
        _picked.add(shot.display.file.path);
      } else {
        final lo = from < to ? from : to;
        final hi = from < to ? to : from;
        for (var i = lo; i <= hi; i++) {
          _picked.add(ids[i]);
        }
      }
      _anchor = shot.display.file.path;
    });
  }

  /// A click on a tile, or on its check badge when [openIfIdle] is false.
  void _click(
    List<AlbumCameraShot> shots,
    List<AlbumPhoto> flat,
    AlbumCameraShot shot,
    int index, {
    required bool openIfIdle,
    Rect? origin,
  }) {
    if (_dragKey.currentState?.justDragged ?? false) return;

    final keyboard = HardwareKeyboard.instance;
    final additive = keyboard.isControlPressed || keyboard.isMetaPressed;

    if (keyboard.isShiftPressed) {
      _selectRange(shots, shot);
    } else if (additive || _picked.isNotEmpty || !openIfIdle) {
      _toggle(shot);
    } else {
      _open(shots, flat, index, origin: origin);
    }
  }

  void _clickBlank() {
    if (_picked.isEmpty) return;
    if (_dragKey.currentState?.justDragged ?? false) return;
    setState(() {
      _picked.clear();
      _anchor = null;
    });
  }

  void _longPress(AlbumCameraShot shot) {
    final photo = shot.display;
    if (_dragKey.currentState?.beginHold(photo) ?? false) return;
    _toggle(shot);
  }

  bool _dragStart(AlbumPhoto photo) {
    final shots = _shots;
    if (shots == null) return true;
    final shot = _shotOf(shots, photo);
    if (shot == null) return true;
    final id = shot.display.file.path;
    final select = !_picked.contains(id);
    _dragPaint([photo], select);
    _anchor = id;
    return select;
  }

  void _dragPaint(Iterable<AlbumPhoto> photos, bool select) {
    final shots = _shots;
    if (shots == null) return;
    final ids = <String>[
      for (final photo in photos)
        if (_shotOf(shots, photo) case final shot?) shot.display.file.path,
    ];
    if (ids.isEmpty) return;
    final changes = select
        ? ids.any((id) => !_picked.contains(id))
        : ids.any(_picked.contains);
    if (!changes) return;
    setState(() {
      if (select) {
        _picked.addAll(ids);
        _anchor = ids.last;
      } else {
        _picked.removeAll(ids);
      }
    });
  }

  /// Picks every shot from [section], or clears them when they already are.
  void _selectDay(AlbumDaySection section, List<AlbumCameraShot> shots) {
    final ids = <String>[
      for (final photo in section.photos)
        if (_shotOf(shots, photo) case final shot?) shot.display.file.path,
    ];
    final all = ids.isNotEmpty && ids.every(_picked.contains);
    setState(() {
      if (all) {
        _picked.removeAll(ids);
      } else {
        _picked.addAll(ids);
        if (ids.isNotEmpty) _anchor = ids.first;
      }
    });
  }

  void _selectAll(List<AlbumCameraShot> shots) {
    setState(() {
      _picked
        ..clear()
        ..addAll(shots.map((shot) => shot.display.file.path));
      if (shots.isNotEmpty) _anchor = shots.first.display.file.path;
    });
  }

  void _selectNone() {
    setState(() {
      _picked.clear();
      _anchor = null;
    });
  }

  bool _allPicked(List<AlbumCameraShot> shots) =>
      shots.isNotEmpty &&
      shots.every((shot) => _picked.contains(shot.display.file.path));

  bool? _dayChecked(AlbumDaySection section, List<AlbumCameraShot> shots) {
    var picked = 0;
    var total = 0;
    for (final photo in section.photos) {
      final shot = _shotOf(shots, photo);
      if (shot == null) continue;
      total++;
      if (_picked.contains(shot.display.file.path)) picked++;
    }
    if (picked == 0) return false;
    if (picked == total) return true;
    return null;
  }

  int _fileCount(List<AlbumCameraShot> shots) {
    var count = 0;
    for (final shot in shots) {
      if (!_picked.contains(shot.display.file.path)) continue;
      count += shot.filesFor(_kind).length;
    }
    return count;
  }

  List<AlbumCameraShot> _pickedShots(List<AlbumCameraShot> shots) => [
    for (final shot in shots)
      if (_picked.contains(shot.display.file.path)) shot,
  ];

  /// Drops files that are no longer on the card from the in-memory list, so
  /// the grid matches what is left. A shot with nothing left of either kind
  /// leaves the pick list too.
  void _forgetMissing() {
    for (final folders in _files.values) {
      for (final entry in folders.entries.toList()) {
        final kept = [
          for (final photo in entry.value)
            if (photo.file.existsSync()) photo,
        ];
        if (kept.isEmpty) {
          folders.remove(entry.key);
        } else {
          folders[entry.key] = kept;
        }
      }
    }
    _publish();
  }

  /// Deletes the picked shots from the cards, without copying them.
  Future<void> _delete(List<AlbumCameraShot> shots) async {
    final chosen = _pickedShots(shots);
    if (chosen.isEmpty || _busy) return;

    final files = _fileCount(shots);
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          Icons.delete_outline_rounded,
          color: Theme.of(context).colorScheme.error,
        ),
        title: Text(
          files == 1
              ? 'Delete 1 file from the camera?'
              : 'Delete $files files from the camera?',
        ),
        content: const Text(
          'The selected photos are removed from their cards. '
          'Nothing is copied into the album. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (agreed != true || !mounted) return;

    final cancelled = _Cancel();
    final progress = ValueNotifier<(int, int)>((0, 0));
    setState(() => _busy = true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Deleting'),
          content: ValueListenableBuilder<(int, int)>(
            valueListenable: progress,
            builder: (context, value, _) => Text(
              value.$2 == 0 ? 'Starting…' : '${value.$1} of ${value.$2} files',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => cancelled.value = true,
              child: const Text('Stop'),
            ),
          ],
        ),
      ),
    );

    AlbumImportResult? result;
    Object? failure;
    try {
      result = await albumDeleteShots(
        shots: chosen,
        kind: _kind,
        cancelled: () => cancelled.value,
        onProgress: (done, total) => progress.value = (done, total),
      );
    } on Object catch (error) {
      failure = error;
    } finally {
      if (mounted) Navigator.of(context).pop();
      progress.dispose();
    }
    if (!mounted) return;
    setState(() => _busy = false);

    if (failure != null || result == null) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('Could not delete: $failure')));
      return;
    }

    // Drop what was removed so the grid matches the cards.
    if (result.deleted > 0) _forgetMissing();

    final failed = result.errors.length;
    final summary = StringBuffer(
      'Removed ${albumFormatCount(result.deleted)} '
      '${result.deleted == 1 ? 'file' : 'files'} from the camera',
    );
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
  }

  Future<void> _import(List<AlbumCameraShot> shots) async {
    final chosen = _pickedShots(shots);
    final name = _clean;
    if (chosen.isEmpty || name.isEmpty || _busy) return;

    if (_deleteAfter) {
      final agreed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: Icon(
            Icons.delete_outline_rounded,
            color: Theme.of(context).colorScheme.error,
          ),
          title: const Text('Delete the photos from the camera?'),
          content: const Text(
            'Each photo is removed from its card after its copy is in '
            'place. A photo that could not be copied is left on the card. '
            'This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep them'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Copy and delete'),
            ),
          ],
        ),
      );
      if (agreed != true || !mounted) return;
    }

    final cancelled = _Cancel();
    final progress = ValueNotifier<AlbumCopyProgress?>(null);
    setState(() => _busy = true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Copying'),
          content: ValueListenableBuilder<AlbumCopyProgress?>(
            valueListenable: progress,
            builder: (context, value, _) => _CopyProgressView(progress: value),
          ),
          actions: [
            TextButton(
              onPressed: () => cancelled.value = true,
              child: const Text('Stop'),
            ),
          ],
        ),
      ),
    );

    AlbumImportResult? result;
    Object? failure;
    try {
      result = await albumCopyShots(
        shots: chosen,
        kind: _kind,
        destination: p.join(widget.parentPath, name),
        deleteAfter: _deleteAfter,
        cancelled: () => cancelled.value,
        onProgress: (value) => progress.value = value,
      );
    } on Object catch (error) {
      failure = error;
    } finally {
      if (mounted) Navigator.of(context).pop();
      progress.dispose();
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (failure != null || result == null) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('Could not copy: $failure')));
      return;
    }
    Navigator.of(context).pop((name, result));
  }

  Future<void> _open(
    List<AlbumCameraShot> shots,
    List<AlbumPhoto> flat,
    int index, {
    Rect? origin,
  }) async {
    final ordered = [for (final photo in flat) _shotOf(shots, photo)!];
    final screen = MediaQuery.sizeOf(context);
    final flight = albumFittedProvider(ordered[index].display.file, screen);
    try {
      await precacheImage(flight, context);
    } on Object {
      // Still open; the Image will decode during the flight if needed.
    }
    if (!mounted) return;
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 360),
        reverseTransitionDuration: const Duration(milliseconds: 280),
        pageBuilder: (_, _, _) =>
            _ShotPreview(shots: ordered, initialIndex: index),
        transitionsBuilder: (_, animation, _, child) =>
            AlbumPreviewZoomTransition(
              animation: animation,
              fromGlobal: origin,
              flight: flight,
              child: child,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shots = _shots;
    final clean = _clean;
    final waiting = shots == null || (shots.isEmpty && _reading);
    return Scaffold(
      appBar: AppBar(
        title: Text(clean.isEmpty ? 'Import' : 'Import into "$clean"'),
        actions: [
          if (shots != null) ...[
            IconButton(
              tooltip: _fileCount(shots) == 0
                  ? 'Delete from the camera'
                  : 'Delete ${_fileCount(shots)} from the camera',
              onPressed: _busy || _fileCount(shots) == 0
                  ? null
                  : () => _delete(shots),
              icon: const Icon(Icons.delete_outline_rounded),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: _busy || clean.isEmpty || _fileCount(shots) == 0
                    ? null
                    : () => _import(shots),
                child: Text('Import ${_fileCount(shots)}'),
              ),
            ),
          ],
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 320, child: _side()),
          Expanded(
            child: waiting
                ? _wait()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _bar(shots),
                      Expanded(child: _grid(shots)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// The drive choice and the folder name, one card each.
  Widget _side() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _card(
            title: 'Drives',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_error == null && _pending > 0 && _drives.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (_pending == 0 && _drives.isEmpty && _error == null)
                  const Text(
                    'No removable drive with a DCIM folder was found.',
                  ),
                for (final drive in _drives)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _chosen.contains(drive.root),
                    title: Text(albumCardLabel(drive.root)),
                    subtitle: Text(
                      drive.name.isEmpty
                          ? drive.root
                          : '${drive.name}\n${drive.root}',
                    ),
                    onChanged: _busy
                        ? null
                        : (value) => _toggleDrive(drive, value ?? false),
                  ),
                if (_pending > 0 && _drives.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _busy ? null : _chooseFolder,
                    icon: const Icon(Icons.folder_open_outlined),
                    label: const Text('Choose a folder'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card(
            title: 'Name',
            child: TextField(
              controller: _name,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Folder name',
                helperText: _clean.isEmpty
                    ? 'The name is empty, or one Windows keeps for itself.'
                    : 'A new folder, ${widget.parentName}\\$_clean',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({required String title, required Widget child}) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }

  Widget _wait() {
    if (_error != null) {
      return AlbumStateView(
        icon: Icons.no_photography_outlined,
        title: 'The camera could not be read',
        message: _error!,
      );
    }
    final label = _readingPath;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              _finding ? 'Finding photos' : 'Loading photos',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (label != null) ...[
              const SizedBox(height: 12),
              SelectableText(
                label,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _missedLine(List<String> missed) {
    if (missed.length == 1) return '${missed.single} did not answer';
    if (missed.length == 2) {
      return '${missed[0]} and ${missed[1]} did not answer';
    }
    final rest = missed.sublist(0, missed.length - 1).join(', ');
    return '$rest and ${missed.last} did not answer';
  }

  Widget _bar(List<AlbumCameraShot> shots) {
    final theme = Theme.of(context);
    final pairs = shots.where((shot) => shot.paired).length;
    final pictures = shots.where((shot) => shot.picture != null).length;
    final raws = shots.where((shot) => shot.raw != null).length;
    final cards = _volumes.length;
    final summary = cards == 0
        ? 'No photos found.'
        : '$cards ${cards == 1 ? 'card' : 'cards'} · '
              '${albumFormatCount(shots.length)} '
              '${shots.length == 1 ? 'shot' : 'shots'} · '
              '$pairs with both'
              '${pictures > 0 ? ' · $pictures JPEG' : ''}'
              '${raws > 0 ? ' · $raws raw' : ''}'
              '${_reading ? ' · still reading' : ''}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(summary, style: theme.textTheme.bodyMedium),
          if (_readingPath != null) ...[
            const SizedBox(height: 4),
            Text(
              _readingPath!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
          if (_volumes.isNotEmpty || _missed.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final volume in _volumes)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.sd_card_outlined, size: 18),
                    label: Text(volume),
                  ),
                if (_missed.isNotEmpty)
                  Text(
                    _missedLine(_missed),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<AlbumImportKind>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: AlbumImportKind.both,
                    label: Text('RAW + JPEG'),
                  ),
                  ButtonSegment(value: AlbumImportKind.raw, label: Text('RAW')),
                  ButtonSegment(
                    value: AlbumImportKind.jpeg,
                    label: Text('JPEG'),
                  ),
                ],
                selected: {_kind},
                onSelectionChanged: _busy
                    ? null
                    : (value) => setState(() => _kind = value.first),
              ),
              InkWell(
                onTap: _busy
                    ? null
                    : () => setState(() => _deleteAfter = !_deleteAfter),
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: _deleteAfter,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: _busy
                          ? null
                          : (value) =>
                                setState(() => _deleteAfter = value ?? false),
                    ),
                    const Text('Delete from the camera after copying'),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
              TextButton(
                onPressed: _allPicked(shots)
                    ? _selectNone
                    : () => _selectAll(shots),
                child: Text(_allPicked(shots) ? 'Select none' : 'Select all'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _grid(List<AlbumCameraShot> shots) {
    if (shots.isEmpty) {
      return const AlbumStateView(
        icon: Icons.photo_library_outlined,
        title: 'No photos on the cards',
        message:
            'Nothing was found in a camera folder. '
            'Choose a folder to look somewhere else.',
      );
    }
    final sections = _sections(shots);
    final flat = [for (final section in sections) ...section.photos];
    final headerHeight = AlbumDayHeaderDelegate.heightFor(context);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): () =>
            _selectAll(shots),
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true): () =>
            _selectAll(shots),
        if (_picked.isNotEmpty)
          const SingleActivator(LogicalKeyboardKey.escape): _selectNone,
      },
      child: Focus(
        autofocus: true,
        child: AlbumDragSelect(
          key: _dragKey,
          controller: _gridController,
          onStart: _dragStart,
          onPaint: _dragPaint,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _clickBlank,
            child: CustomScrollView(
              controller: _gridController,
              slivers: [
                for (final section in sections)
                  SliverMainAxisGroup(
                    slivers: [
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: AlbumDayHeaderDelegate(
                          section,
                          height: headerHeight,
                          selected: _dayChecked(section, shots),
                          onSelect: () => _selectDay(section, shots),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
                        sliver: SliverGrid.builder(
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                // The same size the album's own grid uses.
                                maxCrossAxisExtent: 140,
                                mainAxisSpacing: 4,
                                crossAxisSpacing: 4,
                              ),
                          itemCount: section.photos.length,
                          itemBuilder: (context, index) {
                            final photo = section.photos[index];
                            final shot = _shotOf(shots, photo)!;
                            final at = flat.indexOf(photo);
                            return AlbumPhotoTile(
                              key: ValueKey(shot.display.file.path),
                              photo: photo,
                              selecting: true,
                              selected: _picked.contains(
                                shot.display.file.path,
                              ),
                              onTap: (origin) => _click(
                                shots,
                                flat,
                                shot,
                                at,
                                openIfIdle: true,
                                origin: origin,
                              ),
                              onToggle: () => _click(
                                shots,
                                flat,
                                shot,
                                at,
                                openIfIdle: false,
                              ),
                              onLongPress: () => _longPress(shot),
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
      ),
    );
  }
}

/// File count, bytes and transfer speed in the copy dialog.
class _CopyProgressView extends StatelessWidget {
  const _CopyProgressView({required this.progress});

  final AlbumCopyProgress? progress;

  @override
  Widget build(BuildContext context) {
    final value = progress;
    if (value == null || value.total == 0) {
      return const Text('Starting…');
    }
    final theme = Theme.of(context);
    final fraction = value.bytesTotal == 0
        ? value.done / value.total
        : (value.bytesDone / value.bytesTotal).clamp(0.0, 1.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: fraction),
        const SizedBox(height: 14),
        Text('${value.done} of ${value.total} files'),
        if ([
              if (value.bytesTotal > 0)
                '${_formatBytes(value.bytesDone)} of ${_formatBytes(value.bytesTotal)}',
              if (value.bytesPerSecond case final speed?)
                '${_formatBytes(speed.round())}/s',
            ]
            case final parts when parts.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            parts.join(' · '),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(bytes < 10 * 1024 ? 1 : 0)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class _Cancel {
  bool value = false;
}

/// The preview of the import, with the shot's files at its top right. Tapping
/// one shows that file.
class _ShotPreview extends StatefulWidget {
  const _ShotPreview({required this.shots, required this.initialIndex});

  final List<AlbumCameraShot> shots;
  final int initialIndex;

  @override
  State<_ShotPreview> createState() => _ShotPreviewState();
}

class _ShotPreviewState extends State<_ShotPreview> {
  late final List<AlbumPhoto> _shown = [
    for (final shot in widget.shots) shot.display,
  ];

  @override
  Widget build(BuildContext context) {
    return AlbumPreviewPage(
      photos: _shown,
      initialIndex: widget.initialIndex,
      veil: false,
      corner: (photo) {
        final index = _shown.indexOf(photo);
        if (index < 0) return const SizedBox.shrink();
        final shot = widget.shots[index];
        return Material(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final file in shot.files)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: identical(file, photo)
                            ? Colors.white24
                            : Colors.transparent,
                        visualDensity: VisualDensity.compact,
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                      ),
                      onPressed: () => setState(() => _shown[index] = file),
                      child: Text(file.fileType),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
