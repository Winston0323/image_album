# image_album

Day-grouped photo grid for the images in a local folder.

Pass a directory path. The album lists the image files directly in that folder and shows them in a grid grouped by day, newest first. Tiles keep a roughly constant size (about 140 logical pixels at most), so a phone shows three columns and a wide desktop window shows many more. Tap a tile to open the swipe preview. The box on a day's heading selects that day's photos. Long-press a tile, or click its check, to select one; drag across tiles to select several. Once any are selected, the bar can select the rest or delete the selection.

```dart
import 'package:flutter/material.dart';
import 'package:image_album/image_album.dart';

void main() {
  runApp(const MaterialApp(
    home: ImageAlbum(path: '/path/to/images'),
  ));
}
```

A drop-down above the grid filters by file type. It always shows what is on screen: the folder's one type when it holds only one ("JPG · 12"), "All types" for a mix, or the types ticked ("JPG, PNG · 15"). Its menu lists each type with a count and stays open while several are ticked; "All types" clears the filter.

The shot date is the capture time stored in the photo, or the file's modification time when it has none. Subfolders are skipped unless `recursive` is true. Recognized extensions are jpg, jpeg, png, gif, webp, bmp, heic, heif, tif, tiff, fff, and arw.

TIFF, Hasselblad/Imacon FFF and Sony ARW are not formats Flutter can draw, so the album converts them. All three are TIFF containers. For a camera raw (ARW, FFF) the album shows the JPEG preview the camera stored in the file, found without reading through the whole raw, and turned upright by the camera's orientation; the sensor data is not developed (a "JPEG" in the file that is lossless or more than 8 bits a sample is that sensor data and is never taken for a preview). A plain TIFF is decoded (uncompressed, LZW, deflate, PackBits and the others the `image` package reads; TIFFs with their colours stored in separate planes, which that package gets wrong, are read by the album itself; a fourth channel that is empty all through is not taken as transparency) and shrunk to fit; one over 120 megapixels is shown as an empty tile rather than risk the memory. The shot date and the size in the info panel are read from the TIFF structure with a few small reads, so a folder of 50 MB raws is not loaded to be listed. A raw with no preview inside, or a TIFF the decoder cannot read, shows an error tile.

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

## Folder catalog

Each folder the album shows gets a hidden catalog, `.image_album.iacx`, listing its photos with their sizes, times and capture dates. Paths in it are relative, so it stays valid when the folder is moved, renamed or opened from another machine, and it covers the whole tree whether or not `recursive` was on. A folder with a catalog opens at once, even with a new install or an empty album file, and the album then checks the folder in the background.

To spare the work of looking at every file again, the album believes a catalog that was verified within the last day: files it lists are not checked, and only photos that were added or removed show up. A photo edited in place, keeping its name, is picked up once the catalog is a day old, or when the user pulls to refresh (`ImageAlbum.reload`), which checks every file.

The catalog is hidden (a leading dot, plus the hidden attribute on Windows), is safe to delete, and is rebuilt on the next scan. A folder that cannot be written to simply goes without one. `AlbumLibrary.clearCaches` deletes the catalogs of its folders, and `cacheUsage` counts them with the indexes. Pass `useCatalog: false` to leave the folders untouched.

The extension is `.iacx` on purpose: `.ia` is the Rollei RAW photo format, which darktable, XnView and Explorer thumbnail handlers would try to open.

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

With `recursive: true` the album shows a folder tree with a checkbox on every folder that holds photos, each with its photo count. Untick a folder to hide its photos and everything below it; a half-ticked box means something inside is hidden, and ticking it shows the whole folder again. You can also tick a folder that is hidden only because a parent is, and just that folder comes back. "Show all" clears every choice. On windows 900 dp or wider the tree sits on the left, beside the grid, and slides open and closed; on narrower ones the Folders icon on the left opens it as a sheet. A dot on that icon marks hidden folders. Opening a photo on a wide window shows the preview in the space beside the tree, so the tree stays where it is until you close it.

While a photo is open in the preview, the tree shades the folder it is in and follows it from photo to photo; the shade goes when the preview closes. That is the only mark the tree ever has: on the waterfall no folder is shaded, narrowed to one or not.

Only one album is open in the tree at a time. Clicking a folder opens it (its subfolders appear) and folds every other album; clicking a photo does the same for the album the photo is in, and the arrow on a row still opens or closes that one folder by hand.

Click a folder's name in the tree to narrow the album to it: the grid then shows only the photos in that folder and below, a chip under the bar names it with a count (the row itself is not shaded: the waterfall marks no folder). Only the box ticks and unticks a folder; the rest of the row narrows. To go back to everything, press the cross on the chip, press Escape (which first closes an open photo, then ends picking, then ends the narrowing), or click the same folder again or the source's own row. Clicking a hidden folder brings it back first, and hiding the folder you are narrowed to ends the narrowing. On a narrow window the Folders sheet closes once a folder is picked. While narrowed, the preview holds what the grid shows.

Right-click a folder in the tree, long-press it, or press the ⋮ on its row to open its menu: "Show only this folder" (or "Show the whole album" on the one the album is narrowed to) and "Delete folder…". Deleting asks first, then deletes the photos in the folder and in the folders below it, and removes each of those folders that nothing else is left in; one that still holds other files stays, with just those files. A source folder has no delete entry, since it is the album itself; remove it with the remove button. Pass `confirmDeleteFolder` to ask in your own way.

On Windows the menu also has "Show in Explorer", which opens the folder in Explorer. Pass `revealFolder` to open it some other way, or to get the entry on other platforms (it is called with the folder's path).

The same menu has "Import from camera…". The page puts two cards on the left and the photos on the right. The first card lists the removable drives that have a `DCIM` folder, with the card's name beside the letter; a drive with no `DCIM` is left off the list, and one that does not answer is left off as the others appear. DCIM is read on the ones left ticked. The second card is the name of the new folder. The path being checked is shown before any photo is. Fixed disks are left out; "Choose a folder" on the drive card reads any other folder. Photos then fill the same grid as the album, a batch at a time, and a tile's picture loads when that tile is on screen. A JPEG and a raw that share a name are one shot whether they sit on the same card or on two. The preview's top right lists the shot's files, and tapping one shows it. Import copies the selection into the new folder as RAW + JPEG, RAW only, or JPEG only, and can delete each file from the card once its copy is in place and the same size. A file already in the folder is left as it is, and its original stays on the card.

The same menu has "Rename images…". It asks for a name (the folder's own name to start with) and, when the folder has folders inside it holding images, whether to include them. The images then become `name_001.jpg`, `name_002.png` and so on: put in natural name order (`img2` before `img10`), keeping their extensions, and each folder numbered on its own from 001 (four or more digits past 999 images). The renaming goes through temporary names, so a file is never written over another, even one that already has a name it is about to get; a file that cannot be renamed is put back and reported, and the rest go on. Folders themselves are not renamed. The same work is exported as `albumRenameImages` for use without the widget.

Each folder one level under a source is an album, together with everything below it, and the photos lying directly in the source make up one more. The grid shows them all together, but the preview holds only the album of the photo you opened: swiping, the arrow keys and the strip under the photo stay inside it. With several sources, the albums of each are kept apart, even when folder names match.

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

Day headings stay pinned while their photos scroll, and read "Today", "Yesterday", the weekday, then the date. The box on a heading selects every photo from that day, and selects them again to clear that day. Tiles are rounded and fade in as they load. Hovering a tile on desktop shows a check badge for one-click selection; long-press does the same on touch. In the viewer, tap hides or shows the bars, double-tap zooms, and on desktop the arrow keys, Page Up and Page Down or the side buttons move between photos and Escape closes it. A strip of small photos under the picture shows those before and after the current one, which has a highlighted border; tap one to go to it. The strip folds away with the bars. Tab opens and closes the folder tree, also while a photo is open. Colors come from the app's Theme, so the album follows its light or dark scheme.

## Demo

`example` lets you pick a folder, then opens it in the album with subfolders and the folder tree on; you can add more folders and remove any of them from the folder panel. The folders, the hidden subfolders and the caches are kept in an album file in the app's support directory, and the app bar's storage button shows what the caches take and clears them. Windows uses the system folder dialog. On Android, grant all-files access when asked so the app can list that folder.

```bash
cd example
flutter run
```

The demo's icon, a stack of amber photos on the app's near-black surface, is drawn by `tool/make_icon.dart`. To change it, edit the script and run `dart run tool/make_icon.dart` from the package root. That rewrites the Windows `app_icon.ico`, the Android launcher icons and a 1024 px master at `example/icon/app_icon.png`.
