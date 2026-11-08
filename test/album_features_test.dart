import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/image_album.dart';

void main() {
  test('only the named features are included', () {
    const chosen = {AlbumFeature.preview, AlbumFeature.crop};
    final features = AlbumFeatures.only(chosen);

    expect(features.allows(AlbumFeature.preview), isTrue);
    expect(features.allows(AlbumFeature.crop), isTrue);
    expect(features.allows(AlbumFeature.delete), isFalse);
    expect(features.allows(AlbumFeature.import), isFalse);
    expect(features.allows(AlbumFeature.rename), isFalse);
    expect(AlbumFeatures.all.allows(AlbumFeature.delete), isTrue);
  });
}
