# image_album

Day-grouped photo grid for the images in a local folder.

Pass a directory path. The album lists the image files directly in that folder and shows them in a grid grouped by day, newest first. Tiles keep a roughly constant size (about 140 logical pixels at most), so a phone shows three columns and a wide desktop window shows many more. Tap a tile to open the swipe preview. Long-press to select, then delete.

```dart
import 'package:flutter/material.dart';
import 'package:image_album/image_album.dart';

void main() {
  runApp(const MaterialApp(
    home: ImageAlbum(path: '/path/to/images'),
  ));
}
```

The shot date is the capture time stored in the photo, or the file's modification time when it has none. Subfolders are skipped unless `recursive` is true. Recognized extensions are jpg, jpeg, png, gif, webp, bmp, heic, and heif.

```dart
ImageAlbum(path: '/path/to/images', recursive: true)
```

```yaml
dependencies:
  image_album:
    git:
      url: https://github.com/Winston0323/image_album.git
```

Capture dates are cached per folder, keyed by each file's size and modification time, so reopening a folder does not re-read the images. Grid thumbnails are cached too: each photo is shrunk to 240 px and saved once as a JPEG of roughly 10 KB (a PNG when it has transparency), and later opens read only that file. The thumbnail cache is capped at 256 MB, oldest first, and is safe to delete. Previews decode each photo to fit the screen and load a sharper version (up to 4096 px) only once you zoom in.

By default both caches sit in the system temp directory, which the OS may clear. Give the album an album file to keep them, and your choices, somewhere durable.

## Album file

An `AlbumLibrary` is a folder of its own that holds everything the album needs to remember:

```
album/
  album.json     sources, hidden folders, cache options, a record of each index
  index/         one file per source folder: its photos, sizes, times and dates
  thumbs/        the small JPEG copies shown in the grid
```

```dart
final library = await AlbumLibrary.open(Directory('$appSupport/album'));

ImageAlbum(
  paths: library.sources,
  library: library,
  recursive: true,
  initialExcludedFolders: library.excluded,
  onExcludedFoldersChanged: library.setExcluded,
  onAddSource: () async => library.addSource(await pickFolder()),
  onRemoveSource: library.removeSource,
)
```

- **Instant reopening.** A folder scanned before shows its photos straight from `index/` while the folder is checked again in the background. When the check finishes, added and deleted files are applied. Until then a photo that has just been deleted may show as a broken tile.
- **Sources and hidden folders** are saved by `addSource`, `removeSource`, `setSources` and `setExcluded`, so the app needs no storage of its own. `library` is a `ChangeNotifier`, so you can rebuild when they change.
- **Cache options.** `setCacheOptions(AlbumCacheOptions(thumbnailWidth: 320, thumbnailQuality: 70, thumbnailMaxBytes: 64 << 20))` changes how thumbnails are made and how much room they may take. Thumbnails already stored keep their old look until they age out.
- **Housekeeping.** `cacheUsage()` reports what the caches take and `clearCaches()` empties them; only `album.json` holds anything that cannot be rebuilt. When the album file is opened, indexes nobody has refreshed for 30 days, and stray index files, are deleted. A manifest that cannot be read is kept as `album.json.damaged` and the album starts empty.

Put the album file somewhere the OS does not clear, such as the app's support directory. In the temp directory it still works, but loses the advantage of surviving between runs.

`ImageAlbum.reload` on `ImageAlbumState` re-reads the folder after files change.

## Several folders

Pass `paths` instead of `path` to show more than one folder in the same grid. Photos are merged and grouped by day as one album, and a photo that sits in two sources, because one folder is inside another, is listed once. Each source gets its own tree in the folder panel.

The album does not pick folders; your app does. Give it `onAddSource` and `onRemoveSource` and the folder panel gains an add button and a remove button on each source. Update `paths` in response and the album follows. Sources that stay are not scanned again, so adding a folder only reads that folder.

```dart
ImageAlbum(
  paths: sources,
  recursive: true,
  onAddSource: () async {
    final folder = await pickFolder(); // your folder picker
    if (folder != null) setState(() => sources = [...sources, folder]);
  },
  onRemoveSource: (path) => setState(() => sources.remove(path)),
)
```

An empty `paths` shows a "No folders yet" prompt with an add button. A source that cannot be read is left out as long as another one can; the error screen appears only when none can.

## Folder tree

With `recursive: true` the album shows a folder tree with a checkbox on every folder that holds photos, each with its photo count. Untick a folder to hide its photos and everything below it; a half-ticked box means something inside is hidden, and ticking it shows the whole folder again. You can also tick a folder that is hidden only because a parent is, and just that folder comes back. "Show all" clears every choice. On windows 900 dp or wider the tree sits beside the grid; on narrower ones the Folders button in the bar opens it as a sheet. A dot on that button marks hidden folders.

Hiding is applied to photos already scanned, so it is instant, and hidden photos are not selected, previewed or deleted. To keep the choice between runs, save what `onExcludedFoldersChanged` reports and pass it back as `initialExcludedFolders`:

```dart
ImageAlbum(
  path: path,
  recursive: true,
  initialExcludedFolders: saved,
  onExcludedFoldersChanged: (folders) => save(folders),
)
```

## Look and feel

Day headings stay pinned while their photos scroll, and read "Today", "Yesterday", the weekday, then the date. Tiles are rounded and fade in as they load. Hovering a tile on desktop shows a check badge for one-click selection; long-press does the same on touch. In the viewer, tap hides or shows the bars, double-tap zooms, and on desktop the arrow keys or side buttons move between photos and Escape closes it. Colors come from the app's Theme, so the album follows its light or dark scheme.

## Demo

`example` lets you pick a folder, then opens it in the album with subfolders and the folder tree on; you can add more folders and remove any of them from the folder panel. The folders, the hidden subfolders and the caches are kept in an album file in the app's support directory, and the app bar's storage button shows what the caches take and clears them. Windows uses the system folder dialog. On Android, grant all-files access when asked so the app can list that folder.

```bash
cd example
flutter run
```

The demo's icon, a stack of amber photos on the app's near-black surface, is drawn by `tool/make_icon.dart`. To change it, edit the script and run `dart run tool/make_icon.dart` from the package root. That rewrites the Windows `app_icon.ico`, the Android launcher icons and a 1024 px master at `example/icon/app_icon.png`.
