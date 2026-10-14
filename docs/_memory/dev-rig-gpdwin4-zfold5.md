---
name: dev-rig-gpdwin4-zfold5
description: 開発機=GPD WIN4(バッテリー摘出→ミニデスクトップ化)・出先リモート/Winlator動作確認にZ Fold5導入(iPadは制約多く不採用・2026-07-24)
metadata: 
  node_type: memory
  type: user
  originSessionId: a2f785b8-b603-418d-9972-73a42c7cd39a
  modified: 2026-07-24T09:16:49.694Z
---

ユーザーの開発/検証リグ（2026-07-24 時点）:

- **メイン開発機 = GPD WIN4**。バッテリーが膨張したため**摘出**し、以後ミニデスクトップPCとして常用（x86ハンドヘルドを据置き運用）。
- **Z Fold5 を新規入手**。用途は (1) **出先からのリモート操作**（iPad は SSH/リモートデスクトップの制約が多く不採用。開いて7.6"＋Androidの方が素直）、(2) **Winlator での動作確認**（Windows x86 ビルドを Android 上で"無理やり"動かす）。

Gear 開発への含意:
- **Winlator 動作確認 = Vulkan の他GPU検証として有効**。Z Fold5 は Adreno 740 で、Wine→**Turnip**（Mesa の Adreno Vulkan）を通る。**Pi5 の V3DV も同じ Mesa 系の若いドライバ**なので、Turnip で通るか＝**V3DV 移植リスクの予行**（フォーマット/拡張/キュー構成の穴を Pi 実機前に炙り出せる）。→ [[vulkan-migration]] / [[compat-layer-pivot]] の可搬性チェックに使える。
- **⚠ レイテンシ/判定の検証には使えない**。Box64(x86→ARM64エミュ)＋Wine＋Androidオーディオが挟まるので、描画/機能の検証は◎だが、**判定のキレ・タップ音遅延・180Hz は全く代表しない**。音の"感触"は実機（デスクトップ/将来Pi）でのみ測る。
