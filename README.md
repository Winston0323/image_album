# image_album

Day-grouped photo grid for the images in a local folder.

Pass a directory path. The album lists the image files directly in that folder and shows them in a three-column grid grouped by day, newest first. Tap a tile to open the swipe preview. Long-press to select, then delete.

```dart
import 'package:flutter/material.dart';
import 'package:image_album/image_album.dart';

void main() {
  runApp(const MaterialApp(
    home: ImageAlbum(path: '/path/to/images'),
  ));
}
```

The shot date is the file's modification time. Subfolders are not walked. Recognized extensions are jpg, jpeg, png, gif, webp, bmp, heic, and heif.

```yaml
dependencies:
  image_album:
    git:
      url: https://github.com/Winston0323/image_album.git
```

`ImageAlbum.reload` on `ImageAlbumState` re-reads the folder after files change.
