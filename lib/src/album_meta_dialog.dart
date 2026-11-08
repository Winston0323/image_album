import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'album_films.dart';
import 'album_gear_page.dart';
import 'album_shared_gear.dart';

/// Asks for the camera, lens, and film of the scans in [folder].
///
/// The choices are the lists shared with ApertureDiary. Returns the saved
/// record, or null when cancelled.
Future<AlbumFolderMeta?> showAlbumFolderMeta(
  BuildContext context,
  String folder,
) async {
  final current = await readAlbumFolderMeta(folder);
  final films = await albumLoadFilms();
  final cameras = await albumLoadCameras();
  final lenses = await albumLoadLenses();
  if (!context.mounted) return null;
  final saved = await showDialog<AlbumFolderMeta>(
    context: context,
    builder: (context) => _MetaDialog(
      folder: folder,
      current: current,
      films: films,
      cameras: cameras,
      lenses: lenses,
    ),
  );
  if (saved == null) return null;
  await writeAlbumFolderMeta(folder, saved);
  return saved;
}

class _MetaDialog extends StatefulWidget {
  const _MetaDialog({
    required this.folder,
    required this.current,
    required this.films,
    required this.cameras,
    required this.lenses,
  });

  final String folder;
  final AlbumFolderMeta current;
  final List<AlbumSharedFilm> films;
  final List<AlbumSharedCamera> cameras;
  final List<AlbumSharedLens> lenses;

  @override
  State<_MetaDialog> createState() => _MetaDialogState();
}

class _MetaDialogState extends State<_MetaDialog> {
  late String _format;
  late final TextEditingController _iso;
  late final TextEditingController _notes;
  String? _filmId;
  String? _cameraId;
  String? _lensId;

  @override
  void initState() {
    super.initState();
    final current = widget.current;
    _format = current.format == '120' ? '120' : '135';
    _iso = TextEditingController(text: current.iso?.toString() ?? '');
    _notes = TextEditingController(text: current.notes ?? '');
    _filmId = current.filmId;
    _cameraId = current.cameraId;
    _lensId = current.lensId;
  }

  @override
  void dispose() {
    _iso.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _applyFilm(String? id) {
    AlbumSharedFilm? film;
    for (final item in widget.films) {
      if (item.id == id) film = item;
    }
    setState(() {
      _filmId = id;
      if (film == null) return;
      _format = film.type == '120' ? '120' : '135';
      _iso.text = '${film.iso}';
      _cameraId = film.cameraId ?? _cameraId;
      _lensId = film.lensId ?? _lensId;
    });
  }

  void _save() {
    AlbumSharedFilm? film;
    for (final item in widget.films) {
      if (item.id == _filmId) film = item;
    }
    AlbumSharedCamera? camera;
    for (final item in widget.cameras) {
      if (item.id == _cameraId) camera = item;
    }
    AlbumSharedLens? lens;
    for (final item in widget.lenses) {
      if (item.id == _lensId) lens = item;
    }
    final frame =
        film?.frameFormat ??
        widget.current.frameFormat ??
        (_format == '135' ? '36x24' : '6x6');
    Navigator.pop(
      context,
      AlbumFolderMeta(
        format: _format,
        filmId: film?.id,
        filmName: film?.name ?? widget.current.filmName,
        iso: int.tryParse(_iso.text.trim()),
        frameFormat: frame,
        cameraId: camera?.id,
        cameraLabel: camera?.label,
        lensId: lens?.id,
        lensLabel: lens?.label,
        notes: _notes.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = p.basename(widget.folder);
    return AlertDialog(
      title: Text(name.isEmpty ? 'Metadata' : name),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String?>(
                initialValue: widget.films.any((f) => f.id == _filmId)
                    ? _filmId
                    : null,
                decoration: const InputDecoration(labelText: 'Film'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('None')),
                  for (final film in widget.films)
                    DropdownMenuItem(value: film.id, child: Text(film.name)),
                ],
                onChanged: _applyFilm,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AlbumFilmListPage(),
                      ),
                    );
                  },
                  child: const Text('Film list'),
                ),
              ),
              DropdownButtonFormField<String>(
                initialValue: _format,
                decoration: const InputDecoration(labelText: 'Format'),
                items: const [
                  DropdownMenuItem(value: '135', child: Text('135')),
                  DropdownMenuItem(value: '120', child: Text('120')),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _format = value);
                },
              ),
              TextField(
                controller: _iso,
                decoration: const InputDecoration(labelText: 'ISO'),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: widget.cameras.any((c) => c.id == _cameraId)
                    ? _cameraId
                    : null,
                decoration: const InputDecoration(labelText: 'Camera'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('None')),
                  for (final camera in widget.cameras)
                    DropdownMenuItem(
                      value: camera.id,
                      child: Text(camera.label),
                    ),
                ],
                onChanged: (value) => setState(() => _cameraId = value),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: widget.lenses.any((l) => l.id == _lensId)
                    ? _lensId
                    : null,
                decoration: const InputDecoration(labelText: 'Lens'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('None')),
                  for (final lens in widget.lenses)
                    DropdownMenuItem(value: lens.id, child: Text(lens.label)),
                ],
                onChanged: (value) => setState(() => _lensId = value),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AlbumGearPage(),
                      ),
                    );
                  },
                  child: const Text('Cameras and lenses'),
                ),
              ),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(labelText: 'Notes'),
                minLines: 1,
                maxLines: 3,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
