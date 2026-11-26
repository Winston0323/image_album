---
id: 002
title: 从胶片库切换回数码库卡顿
tags: [性能, 卡顿, 切换, 索引, 文件类型, 复杂度]
date: 2026-11-25
severity: high
status: fixed
---

# 从胶片库切换回数码库卡顿

> 一句话摘要：每个网格 tile 都全量扫描一遍所有照片来查找兄弟文件（TIFF/JPG），切换回数码时几十个可见 tile 触发数百万次字符串操作，阻塞 UI；改为一次性 O(n) 建索引 + O(1) 查询后解决。

## 现象（Symptom）

从胶片（film）模式切换回数码（digital）模式时，界面明显卡顿；切换后滚动或触发重建时也反复卡顿。

## 根因（Root Cause）

`lib/src/image_album.dart` 的 `_sectionTile` 对每个 tile 都调用：

```dart
types: albumShotFileTypes(photo, _shotPhotos),
```

而 `albumShotFileTypes(photo, photos)`（`lib/src/album_photo.dart`）会**遍历整份 `photos`**，逐个做 `p.basenameWithoutExtension`、`toLowerCase`、`p.dirname`、`p.basename` 的字符串匹配，来找出该照片的兄弟文件（如 TIFF 旁边的 JPG）。

复杂度是 **O(可见 tile 数 × 全量照片数)**。数码库几万张照片时，首屏几十个 tile 每个都全量扫一遍，等于数百万次路径字符串操作，且全部在 UI isolate 同步执行，导致切换与后续每次重建都卡。

## 修复（Fix）

把「逐 tile 全量扫描」改成「一次性建索引 + O(1) 查询」：

- 新增 `albumShotFileTypesIndex()`：一次 O(n) 遍历，按 `目录 + 文件名` 分组，产出 `photo.id → 格式列表` 的映射（保持"自身格式在前、兄弟格式去重"的语义）。
- 在 `ImageAlbumState` 缓存 `_shotTypes`（`Map<String, List<String>>`），并在照片集合变化时重建：
  - `_recompute`（数码照片变化）
  - `_applyFilmView`（胶片照片变化）
  - `_selectLibrary` / `_importFolder` 切回数码时
- `_sectionTile` 改为 `_shotTypes[photo.id] ?? [photo.fileType]` 的 O(1) 查询。

## 涉及文件（Files）

- `lib/src/album_photo.dart`：新增 `albumShotFileTypesIndex()` 一次性索引函数。
- `lib/src/image_album.dart`：新增 `_shotTypes` 缓存字段与 `_rebuildShotTypes()`，在 `_recompute` / `_applyFilmView` / `_selectLibrary` / `_importFolder` 重建索引；`_sectionTile` 改为索引查询。

## 验证（Verification）

- `flutter analyze lib`：无问题。
- `flutter test test/album_photo_test.dart test/image_album_test.dart test/album_widgets_test.dart test/album_library_widget_test.dart`：55 项全部通过。

## 备注（Notes）

切换回数码时仍有一次 O(n) 建索引的同步开销（约几十毫秒）。如需进一步消除，可将 `albumShotFileTypesIndex` 挪到后台 isolate 异步构建；当前已从「每次重建都卡」降到「仅切换瞬间一次」。
