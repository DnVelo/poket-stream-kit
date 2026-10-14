---
name: audio-backend-miniaudio
description: 音声デバイス層を RtAudio→miniaudio(MIT-0)へ置換・WASAPI排他≈5.3ms実機実証・ASIOはその後RtAudio経由で復活(1.5ms)・EQ/音量プロフィールoverride実装
metadata: 
  node_type: memory
  type: project
  originSessionId: b8a92d47-8720-4d79-8d45-08eba894b2f2
  modified: 2026-07-29T16:56:26.001Z
---

2026-07-12、`MasterClock`（`src/audio/clock.{h,cpp}`）のデバイス層を **RtAudio → miniaudio**（`src/third_party/miniaudio`・MIT-0/public domain・単一ヘッダ、実体化は `miniaudio_impl.c`）へ置換。ミキシング（2スロット/クロスフェード/SE）は無改変で流用＝差し替えたのはデバイス開閉/コールバック/列挙/API選択だけ。仕様=`GEAR_SMARTPHONE_LINK_SPEC.md §13.17`。コミット Gear-vk `1752ddd` / Gear-app `879cf52`。

**なぜ切り替えたか（重要）**: RtAudio の WASAPI 排他は本家でも TODO で、**単一スレッドループが排他イベント駆動（イベント待ち→バッファ全体書き）に噛み合わず破綻**（コールバックが回らずクロック停止→動画停止/判定不能、または~4%遅い+ぷつぷつ）。ログ計測で「排他 Initialize は成功するが描画ループが `ReleaseBuffer` 失敗で即死／`GetCurrentPadding` が排他では全バッファを返し空き=0」と特定。RtAudio ループを作り直しても限界だったため、**排他を正しく実装済みの miniaudio へ**。切替後 **buffer16・WASAPI排他がノイズ皆無で N100 でも動作**（ユーザー「他音ゲーでもここまで詰められたことがない」）。

**確定事項**:
- **WASAPI排他レイテンシ ≈ 5.3ms**（デバイス最小周期×2周期・実測。要求16frは機器最小周期255@96k=2.66msに丸められる）。**periods=1 は miniaudio が周期を約2倍に膨らませ補うので遅延同じ→periods=2（二重バッファ=安全）**。判定はオーディオクロック＋オフセット較正なので体感ゼロ。
- **ASIO は一度打ち切ったが、2026-07-21 に RtAudio 経由で実装・実機達成（1.5ms）＝この行の「未実装」は失効**（→[[audio-asio-lowlatency]] が新しい・そちらが正）。現状: `clock.cpp` の `startAsio()` が `api_==GA_ASIO`（`operator.txt` の `api=4`）時だけ `RtAudio(WINDOWS_ASIO)` で開き、失敗すれば WASAPI 共有へ自動フォールバック。**miniaudio と RtAudio は排他＝同時に一方のみ**（`ma_` / `rt_`）。API 切替は要再起動。
  ⚠ **Steinberg ASIO SDK は再配布不可**＝`src/third_party/asiosdk/` は `.gitignore` 済みで**リポジトリにも配布物にも入らない**。手動配置したビルドでのみ `build.zig` が `__WINDOWS_ASIO__` を有効化する。**ASIO 入りビルドを配布するなら Steinberg との個別契約が別途必要**（`GEAR_LICENSES.md`）。
  ⚠ バックエンド分岐のガードは `ma_` 単独でなく `ma_ && rt_` の両方を見ること（→[[asio-crossfade-gap]]＝開発機が api=4 のため miniaudio 前提のコードが長らく無効だった事故）。
- **デバイス抜けフォールバック**: miniaudio 通知で意図しない停止を検知→`pollDevice()`（ゲームスレッド毎フレーム）が既定デバイスへ再起動（`frames_`/トラック保持＝BGM継続）。`intentional_stop_` ガードで自前 stop を誤検知しない。実機（WIN4ヘッドホン抜き）で復帰確認。
- **EQ/音量プロフィール override（§audio）**: スマホプロフィールに 5バンドEQ(60/250/1k/4k/12k)＋Master/BGM/SE、各 -5..+5 の11段(1段≈2dB)。提出body に `u8 snd_len|i8×8`（name の後・golden 更新）。筐体はセッション開始で**マスター段の RBJ peaking バイカッド（1サンプル=遅延ゼロ）＋音量倍率**を適用、Attract でニュートラル復帰（BG FILTER 同様の一時override）。アプリ=`sound_settings_screen.dart`（縦11段スライダー）。※EQは実機end-to-end未確認（コミット時スマホ未接続・golden/コンパイルは検証済）。

関連: [[smartphone-link-poc]]（提出プロトコル・§13）／[[compat-layer-pivot]]（Vulkan互換層）。
