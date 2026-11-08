/// A part of the album an app can leave out.
enum AlbumFeature {
  /// Opening a photo from the grid.
  preview,

  /// Turning and cropping a photo in the viewer. The file is not rewritten.
  crop,

  /// Deleting the photos that are picked, from the grid and from the viewer.
  delete,

  /// The photo info panel in the viewer.
  info,

  /// Showing a photo or a folder in the system file manager.
  reveal,

  /// The row of nearby photos along the bottom of the viewer.
  filmstrip,

  /// Importing from a camera card into a folder.
  import,

  /// Renaming the images in a folder.
  rename,

  /// Deleting a folder from the folder tree.
  folderDelete,

  /// Picking photos: the check, drag-select, and the box on a day.
  selection,
}

/// Which [AlbumFeature]s an app includes.
///
/// Every feature is included unless it is turned off, so an album that does
/// not say otherwise keeps the whole set. [AlbumFeatures.only] includes just
/// the features that are named.
class AlbumFeatures {
  const AlbumFeatures({
    this.preview = true,
    this.crop = true,
    this.delete = true,
    this.info = true,
    this.reveal = true,
    this.filmstrip = true,
    this.import = true,
    this.rename = true,
    this.folderDelete = true,
    this.selection = true,
  });

  /// Includes [included] and leaves every other feature out.
  factory AlbumFeatures.only(Set<AlbumFeature> included) {
    bool has(AlbumFeature feature) => included.contains(feature);
    return AlbumFeatures(
      preview: has(AlbumFeature.preview),
      crop: has(AlbumFeature.crop),
      delete: has(AlbumFeature.delete),
      info: has(AlbumFeature.info),
      reveal: has(AlbumFeature.reveal),
      filmstrip: has(AlbumFeature.filmstrip),
      import: has(AlbumFeature.import),
      rename: has(AlbumFeature.rename),
      folderDelete: has(AlbumFeature.folderDelete),
      selection: has(AlbumFeature.selection),
    );
  }

  /// Every feature.
  static const all = AlbumFeatures();

  final bool preview;
  final bool crop;
  final bool delete;
  final bool info;
  final bool reveal;
  final bool filmstrip;
  final bool import;
  final bool rename;
  final bool folderDelete;
  final bool selection;

  /// Whether [feature] is included.
  bool allows(AlbumFeature feature) => switch (feature) {
    AlbumFeature.preview => preview,
    AlbumFeature.crop => crop,
    AlbumFeature.delete => delete,
    AlbumFeature.info => info,
    AlbumFeature.reveal => reveal,
    AlbumFeature.filmstrip => filmstrip,
    AlbumFeature.import => import,
    AlbumFeature.rename => rename,
    AlbumFeature.folderDelete => folderDelete,
    AlbumFeature.selection => selection,
  };
}
