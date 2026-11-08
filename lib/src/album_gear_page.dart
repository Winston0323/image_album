import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'album_shared_gear.dart';

/// The film rolls shared with ApertureDiary.
class AlbumFilmListPage extends StatefulWidget {
  const AlbumFilmListPage({super.key});

  @override
  State<AlbumFilmListPage> createState() => _AlbumFilmListPageState();
}

class _AlbumFilmListPageState extends State<AlbumFilmListPage> {
  List<AlbumSharedFilm> _films = const [];
  var _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final films = await albumLoadFilms();
    if (!mounted) return;
    setState(() {
      _films = films;
      _loading = false;
    });
  }

  Future<void> _edit([AlbumSharedFilm? film]) async {
    final cameras = await albumLoadCameras();
    final lenses = await albumLoadLenses();
    if (!mounted) return;
    final saved = await showDialog<AlbumSharedFilm>(
      context: context,
      builder: (context) =>
          _FilmDialog(existing: film, cameras: cameras, lenses: lenses),
    );
    if (saved == null) return;
    final next = [..._films];
    final index = next.indexWhere((item) => item.id == saved.id);
    if (index >= 0) {
      next[index] = saved;
    } else {
      next.insert(0, saved);
    }
    await albumSaveFilms(next);
    await _reload();
  }

  Future<void> _delete(AlbumSharedFilm film) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove film'),
        content: Text('Remove ${film.name} from the shared list?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await albumSaveFilms([
      for (final item in _films)
        if (item.id != film.id) item,
    ]);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Films'),
        actions: [
          IconButton(
            tooltip: 'Add film',
            onPressed: _edit,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _films.isEmpty
          ? const Center(child: Text('No films yet. Add a roll to share it.'))
          : ListView.separated(
              itemCount: _films.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final film = _films[index];
                return ListTile(
                  title: Text(film.name),
                  subtitle: Text(film.summary),
                  onTap: () => _edit(film),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    onPressed: () => _delete(film),
                    icon: const Icon(Icons.close_rounded),
                  ),
                );
              },
            ),
    );
  }
}

/// Cameras and lenses shared with ApertureDiary.
class AlbumGearPage extends StatefulWidget {
  const AlbumGearPage({super.key});

  @override
  State<AlbumGearPage> createState() => _AlbumGearPageState();
}

class _AlbumGearPageState extends State<AlbumGearPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  List<AlbumSharedCamera> _cameras = const [];
  List<AlbumSharedLens> _lenses = const [];
  var _loading = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _reload();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final cameras = await albumLoadCameras();
    final lenses = await albumLoadLenses();
    if (!mounted) return;
    setState(() {
      _cameras = cameras;
      _lenses = lenses;
      _loading = false;
    });
  }

  Future<void> _editCamera([AlbumSharedCamera? camera]) async {
    final saved = await showDialog<AlbumSharedCamera>(
      context: context,
      builder: (context) => _CameraDialog(existing: camera),
    );
    if (saved == null) return;
    final next = [..._cameras];
    final index = next.indexWhere((item) => item.id == saved.id);
    if (index >= 0) {
      next[index] = saved;
    } else {
      next.insert(0, saved);
    }
    await albumSaveCameras(next);
    await _reload();
  }

  Future<void> _editLens([AlbumSharedLens? lens]) async {
    final saved = await showDialog<AlbumSharedLens>(
      context: context,
      builder: (context) => _LensDialog(existing: lens),
    );
    if (saved == null) return;
    final next = [..._lenses];
    final index = next.indexWhere((item) => item.id == saved.id);
    if (index >= 0) {
      next[index] = saved;
    } else {
      next.insert(0, saved);
    }
    await albumSaveLenses(next);
    await _reload();
  }

  Future<void> _deleteCamera(AlbumSharedCamera camera) async {
    await albumSaveCameras([
      for (final item in _cameras)
        if (item.id != camera.id) item,
    ]);
    await _reload();
  }

  Future<void> _deleteLens(AlbumSharedLens lens) async {
    await albumSaveLenses([
      for (final item in _lenses)
        if (item.id != lens.id) item,
    ]);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cameras'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Cameras'),
            Tab(text: 'Lenses'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Add',
            onPressed: () => _tabs.index == 0 ? _editCamera() : _editLens(),
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabs,
              children: [
                _gearList(
                  empty: 'No cameras yet.',
                  count: _cameras.length,
                  title: (i) => _cameras[i].label,
                  subtitle: (i) => _cameras[i].summary,
                  onTap: (i) => _editCamera(_cameras[i]),
                  onDelete: (i) => _deleteCamera(_cameras[i]),
                ),
                _gearList(
                  empty: 'No lenses yet.',
                  count: _lenses.length,
                  title: (i) => _lenses[i].label,
                  subtitle: (i) => _lenses[i].summary,
                  onTap: (i) => _editLens(_lenses[i]),
                  onDelete: (i) => _deleteLens(_lenses[i]),
                ),
              ],
            ),
    );
  }

  Widget _gearList({
    required String empty,
    required int count,
    required String Function(int) title,
    required String Function(int) subtitle,
    required void Function(int) onTap,
    required void Function(int) onDelete,
  }) {
    if (count == 0) return Center(child: Text(empty));
    return ListView.separated(
      itemCount: count,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) => ListTile(
        title: Text(title(index)),
        subtitle: Text(subtitle(index)),
        onTap: () => onTap(index),
        trailing: IconButton(
          tooltip: 'Remove',
          onPressed: () => onDelete(index),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
    );
  }
}

class _FilmDialog extends StatefulWidget {
  const _FilmDialog({
    this.existing,
    required this.cameras,
    required this.lenses,
  });

  final AlbumSharedFilm? existing;
  final List<AlbumSharedCamera> cameras;
  final List<AlbumSharedLens> lenses;

  @override
  State<_FilmDialog> createState() => _FilmDialogState();
}

class _FilmDialogState extends State<_FilmDialog> {
  late final TextEditingController _name;
  late final TextEditingController _iso;
  late String _type;
  late String _frame;
  String? _cameraId;
  String? _lensId;

  @override
  void initState() {
    super.initState();
    final film = widget.existing;
    _name = TextEditingController(text: film?.name ?? '');
    _iso = TextEditingController(text: '${film?.iso ?? 400}');
    _type = film?.type == '120' ? '120' : '135';
    _frame = film?.frameFormat ?? (_type == '135' ? '36x24' : '6x6');
    _cameraId = film?.cameraId;
    _lensId = film?.lensId;
  }

  @override
  void dispose() {
    _name.dispose();
    _iso.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final iso = int.tryParse(_iso.text.trim());
    if (name.isEmpty || iso == null || iso <= 0) return;
    final camera = _one(widget.cameras, _cameraId);
    final lens = _oneLens(widget.lenses, _lensId);
    final frame = _type == '135' ? '36x24' : _frame;
    final map =
        widget.existing?.map ??
        albumNewFilm(name: name, type: _type, iso: iso, frameFormat: frame);
    map['name'] = name;
    map['type'] = _type;
    map['iso'] = iso;
    map['frameFormat'] = frame;
    map['brand'] = albumFilmBrandName(name);
    _put(map, 'cameraId', camera?.id);
    _put(map, 'cameraLabel', camera?.label);
    _put(map, 'lensId', lens?.id);
    _put(map, 'lensLabel', lens?.label);
    Navigator.pop(context, AlbumSharedFilm(map));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add film' : 'Edit film'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: _iso,
                decoration: const InputDecoration(labelText: 'ISO'),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Format'),
                items: const [
                  DropdownMenuItem(value: '135', child: Text('135')),
                  DropdownMenuItem(value: '120', child: Text('120')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _type = value;
                    _frame = value == '135' ? '36x24' : '6x6';
                  });
                },
              ),
              if (_type == '120') ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _frame == '645' ? '645' : '6x6',
                  decoration: const InputDecoration(labelText: 'Frame'),
                  items: const [
                    DropdownMenuItem(value: '6x6', child: Text('6×6')),
                    DropdownMenuItem(value: '645', child: Text('645')),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _frame = value);
                  },
                ),
              ],
              const SizedBox(height: 12),
              _cameraMenu(widget.cameras, _cameraId, (id) => _cameraId = id),
              const SizedBox(height: 12),
              _lensMenu(widget.lenses, _lensId, (id) => _lensId = id),
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

class _CameraDialog extends StatefulWidget {
  const _CameraDialog({this.existing});

  final AlbumSharedCamera? existing;

  @override
  State<_CameraDialog> createState() => _CameraDialogState();
}

class _CameraDialogState extends State<_CameraDialog> {
  late final TextEditingController _name;
  late final TextEditingController _mount;
  late String _brand;
  late String _format;
  late bool _interchangeable;

  @override
  void initState() {
    super.initState();
    final camera = widget.existing;
    _name = TextEditingController(text: camera?.name ?? '');
    _mount = TextEditingController(text: camera?.mount ?? '');
    _brand = albumCameraBrands.contains(camera?.brand)
        ? camera!.brand
        : 'Other';
    const known = {'36x24', '6x6', '645', 'instax-mini', 'instax-sq'};
    _format = known.contains(camera?.formatId) ? camera!.formatId : '36x24';
    _interchangeable = camera?.interchangeableLenses ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _mount.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final map =
        widget.existing?.map ??
        albumNewCamera(
          brand: _brand,
          name: name,
          formatId: _format,
          interchangeable: _interchangeable,
        );
    map['brand'] = _brand;
    map['name'] = name;
    map['formatId'] = _format;
    map['interchangeableLenses'] = _interchangeable;
    map['mount'] = _interchangeable ? _mount.text.trim() : null;
    Navigator.pop(context, AlbumSharedCamera(map));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add camera' : 'Edit camera'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _brand,
              decoration: const InputDecoration(labelText: 'Brand'),
              items: [
                for (final brand in albumCameraBrands)
                  DropdownMenuItem(value: brand, child: Text(brand)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _brand = value);
              },
            ),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _format,
              decoration: const InputDecoration(labelText: 'Format'),
              items: const [
                DropdownMenuItem(value: '36x24', child: Text('135')),
                DropdownMenuItem(value: '6x6', child: Text('120 · 6×6')),
                DropdownMenuItem(value: '645', child: Text('120 · 645')),
                DropdownMenuItem(
                  value: 'instax-mini',
                  child: Text('Instax Mini'),
                ),
                DropdownMenuItem(value: 'instax-sq', child: Text('Instax SQ')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _format = value);
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Interchangeable lenses'),
              value: _interchangeable,
              onChanged: (value) => setState(() => _interchangeable = value),
            ),
            if (_interchangeable)
              TextField(
                controller: _mount,
                decoration: const InputDecoration(
                  labelText: 'Mount',
                  hintText: 'F, M, V…',
                ),
              ),
          ],
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

class _LensDialog extends StatefulWidget {
  const _LensDialog({this.existing});

  final AlbumSharedLens? existing;

  @override
  State<_LensDialog> createState() => _LensDialogState();
}

class _LensDialogState extends State<_LensDialog> {
  late final TextEditingController _name;
  late final TextEditingController _mount;
  late final TextEditingController _minFocal;
  late final TextEditingController _maxFocal;
  late final TextEditingController _maxAperture;
  late final TextEditingController _minAperture;
  late String _brand;

  @override
  void initState() {
    super.initState();
    final lens = widget.existing;
    _name = TextEditingController(text: lens?.name ?? '');
    _mount = TextEditingController(text: lens?.mount ?? '');
    _minFocal = TextEditingController(text: _num(lens?.minFocalMm));
    _maxFocal = TextEditingController(text: _num(lens?.maxFocalMm));
    _maxAperture = TextEditingController(text: _num(lens?.maxAperture));
    _minAperture = TextEditingController(text: _num(lens?.minAperture));
    _brand = albumCameraBrands.contains(lens?.brand) ? lens!.brand : 'Other';
  }

  @override
  void dispose() {
    _name.dispose();
    _mount.dispose();
    _minFocal.dispose();
    _maxFocal.dispose();
    _maxAperture.dispose();
    _minAperture.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final minFocal = double.tryParse(_minFocal.text.trim());
    if (name.isEmpty || minFocal == null || minFocal <= 0) return;
    final map =
        widget.existing?.map ??
        albumNewLens(brand: _brand, name: name, minFocalMm: minFocal);
    map['brand'] = _brand;
    map['name'] = name;
    map['minFocalMm'] = minFocal;
    map['maxFocalMm'] = double.tryParse(_maxFocal.text.trim());
    map['maxAperture'] = double.tryParse(_maxAperture.text.trim());
    map['minAperture'] = double.tryParse(_minAperture.text.trim());
    map['mount'] = _mount.text.trim().isEmpty ? null : _mount.text.trim();
    Navigator.pop(context, AlbumSharedLens(map));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add lens' : 'Edit lens'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _brand,
                decoration: const InputDecoration(labelText: 'Brand'),
                items: [
                  for (final brand in albumCameraBrands)
                    DropdownMenuItem(value: brand, child: Text(brand)),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _brand = value);
                },
              ),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: _minFocal,
                decoration: const InputDecoration(
                  labelText: 'Focal length (mm)',
                ),
                keyboardType: TextInputType.number,
              ),
              TextField(
                controller: _maxFocal,
                decoration: const InputDecoration(
                  labelText: 'Long end (mm)',
                  hintText: 'Leave empty for a prime',
                ),
                keyboardType: TextInputType.number,
              ),
              TextField(
                controller: _maxAperture,
                decoration: const InputDecoration(
                  labelText: 'Widest aperture',
                  hintText: '2.8',
                ),
                keyboardType: TextInputType.number,
              ),
              TextField(
                controller: _minAperture,
                decoration: const InputDecoration(
                  labelText: 'Smallest aperture',
                  hintText: '22',
                ),
                keyboardType: TextInputType.number,
              ),
              TextField(
                controller: _mount,
                decoration: const InputDecoration(labelText: 'Mount'),
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

String _num(double? value) {
  if (value == null) return '';
  return value == value.roundToDouble() ? '${value.round()}' : '$value';
}

void _put(Map<String, dynamic> map, String key, String? value) {
  if (value == null || value.isEmpty) {
    map.remove(key);
  } else {
    map[key] = value;
  }
}

AlbumSharedCamera? _one(List<AlbumSharedCamera> cameras, String? id) {
  for (final camera in cameras) {
    if (camera.id == id) return camera;
  }
  return null;
}

AlbumSharedLens? _oneLens(List<AlbumSharedLens> lenses, String? id) {
  for (final lens in lenses) {
    if (lens.id == id) return lens;
  }
  return null;
}

Widget _cameraMenu(
  List<AlbumSharedCamera> cameras,
  String? selected,
  ValueChanged<String?> onChanged,
) {
  return DropdownButtonFormField<String?>(
    initialValue: cameras.any((c) => c.id == selected) ? selected : null,
    decoration: const InputDecoration(labelText: 'Camera'),
    items: [
      const DropdownMenuItem(value: null, child: Text('None')),
      for (final camera in cameras)
        DropdownMenuItem(value: camera.id, child: Text(camera.label)),
    ],
    onChanged: onChanged,
  );
}

Widget _lensMenu(
  List<AlbumSharedLens> lenses,
  String? selected,
  ValueChanged<String?> onChanged,
) {
  return DropdownButtonFormField<String?>(
    initialValue: lenses.any((l) => l.id == selected) ? selected : null,
    decoration: const InputDecoration(labelText: 'Lens'),
    items: [
      const DropdownMenuItem(value: null, child: Text('None')),
      for (final lens in lenses)
        DropdownMenuItem(
          value: lens.id,
          child: Text(
            lens.summary.isEmpty
                ? lens.label
                : '${lens.label} · ${lens.summary}',
          ),
        ),
    ],
    onChanged: onChanged,
  );
}
