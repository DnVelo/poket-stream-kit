# poket-stream-kit 技術仕様 — PSK_ENGINE.md

> 役割: 技術スタック・信号経路・デバイスとクロック・プラグイン・UI・設定保存。なぜ作るか=VISION、索引=README。
> 信頼度マーカーと書式は `PSK_README.md` 冒頭。**この資料はまだ骨組み**で、🟡 の節は一緒に決めてから埋める。

## 1. 🟡 技術スタック（未決）

| 案 | 構成 | 長所 | 短所 |
|---|---|---|---|
| A. Gear-vk 流用 | Zig ビルド＋C++。WASAPI は miniaudio、ASIO は RtAudio[^gear-audio]。VST3 SDK を直接使う | 実機で詰めた経験とコードがある（ASIO 1.5ms・WASAPI 排他 5.3ms の実績[^gear-audio]）。ライセンスが軽い | VST3 ホストと UI を自分で持つ必要がある |
| B. JUCE（叩き台あり） | CMake＋JUCE 8。ASIO・WASAPI・VST3 ホストが揃っている | 早い。叩き台が Linux でビルド・テスト済み | AGPLv3（または商用ライセンス）に縛られる |

- ⚠ Gear-vk では miniaudio と RtAudio を**同時には開かない**設計だった[^gear-audio]。本ツールは**両方を同時に開くのが本題**なので、そこは新しく作る部分になる。
- ⚠ ASIO SDK のライセンス: Gear-vk の資料では「再配布不可」だが、**2.3.4（2025-10-15）から Steinberg 独自ライセンスと GPLv3 の選択制**になった[^asio-license]。

## 2. 信号経路（叩き台の構成・🟡 未確定）

```
ASIO in ─▶ 入力ゲイン ─▶ [プラグインチェーン] ─┬─▶ モニター音量 ─▶ ASIO out（ヘッドホン）
                                              └─▶ 配信音量 ─▶ クロック橋渡し ─▶ WASAPI 共有 out（CABLE Input → OBS）
```
- 🟡 モニターを「処理後」にするか「処理前（プラグイン遅延ゼロ）」にするかの切り替えを持つか。

## 3. デバイスとクロック

### 3.1 🟡 ASIO ドライバ
- 🔴 Play! 3 に純正の ASIO ドライバがあるかは**未確認**。
- 候補: ASIO4ALL（WDM-KS・Play! 3 を占有）／FlexASIO（WASAPI ベース・共有できる）／ASIO を使わず WASAPI 排他。

### 3.2 🟢 クロックの橋渡しは必須
- ASIO 側（Play! 3）と WASAPI 側（VB-CABLE）は**別のクロック**で動くので、ずれを吸収する仕組みが要る。
- 🟡 方式は未決。叩き台では「FIFO の水位を目標値に保つように、再生速度を PI 制御で微調整するリサンプラー」を実装し、シミュレーションで確かめた（`PSK_IMPLEMENTATION_STATUS §2`）。

## 4. 🟡 プロセス構成
- 🟡 1プロセスで両方のデバイスを開くか。

## 5. 🟡 プラグイン
- 🟡 使うもの: rovee（🔴 正体と対応形式を確認中）・iZotope RX 8（どのモジュールか）・T-De-Esser。
- 🟡 形式: VST3 だけか、VST2 も要るか。

## 6. 🟡 操作と UI
- 🟡 X390 の画面だけで操作するか。iOS（Tailscale 経由）からのリモート操作・ホットキー・OBS との連携は要るか。

## 7. 🟡 設定の保存
- 🟡 何を保存するか（デバイス・プラグインの状態・音量）、どこに置くか。

[^gear-audio]: Gear-vk の記憶 `audio-backend-miniaudio` と `audio-asio-lowlatency`（本リポの `docs/_memory/` に写しあり）。
[^asio-license]: ASIO SDK 2.3.4 の `common/LICENSE.txt`（2026-10-14 に取得して確認）。
