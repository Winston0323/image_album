---
id: 001
title: 网格缩略图右边和底边被裁掉
tags: [布局, 缩略图, 裁切, justified, 宽高比]
date: 2026-11-25
severity: medium
status: fixed
---

# 网格缩略图右边和底边被裁掉

> 一句话摘要：justified 网格给行高加了下限，导致含宽图（拼接全景）的行宽超出网格宽度，`BoxFit.cover` 把图片右缘和底缘裁掉；移除下限后恢复完整显示。

## 现象（Symptom）

数字库 / 胶片网格中，缩略图的**右边和底边被裁掉**，拼接出来的宽图（全景）尤其明显，图片看起来被"切"掉一部分。

## 根因（Root Cause）

`lib/src/album_justify.dart` 的 `albumJustifyRows()` 把行高做了下限 clamp：

```dart
height.clamp(minHeight, maxHeight)   // minHeight = albumJustifyRowMin = 140
```

- 当一行里有较宽的图（拼接产物），按宽高比算出的行高会低于 `140`，被强行抬到 `140`。
- 每张图的宽度是 `宽高比 × 行高`，行高被抬升后，整行总宽度超过网格宽度，右侧溢出被裁掉。
- filled 行的最后一张用 `Expanded` 拉伸到"剩余宽度"，宽高比被破坏，`BoxFit.cover` 又裁掉上下（即底边）。

## 修复（Fix）

移除行高的下界 clamp，只保留上界，让行宽始终精确等于网格宽度：

- 满行：`math.min(height, maxHeight)`
- 末尾不满行：`math.min(height, targetHeight)`

同步更新 `albumJustifyRowMin` 常量说明（保留以兼容源码）与函数文档注释，说明不再施加最低高度。

## 涉及文件（Files）

- `lib/src/album_justify.dart`：移除 `height.clamp(minHeight, ...)` 的下界，改为 `math.min`；更新常量与文档注释。

## 验证（Verification）

- `flutter analyze lib`：无问题。
- `flutter test test/image_album_test.dart test/album_widgets_test.dart`：34 项全部通过。

## 备注（Notes）

全量测试中另有一个 `album_import_test.dart` 的「preview 列出 shot 文件」用例失败，原因是找不到图标 `IconData(U+0F63B)`，与本改动无关，属既有的图标查找问题。
