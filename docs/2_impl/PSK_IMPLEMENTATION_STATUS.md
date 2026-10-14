# poket-stream-kit 実装ステータス — PSK_IMPLEMENTATION_STATUS.md

> 役割: 実装の現在地・コード地図・検証済みの事実・更新履歴。仕様の正は `docs/1_spec/`。
> 信頼度マーカーと書式は `PSK_README.md` 冒頭。

## 0. 一言サマリ
🟡 **仕様策定中**。仕様を決める前に作った JUCE 版の叩き台が置いてあるが、**構成が Zig ＋ C++ に決まったので不採用**（`PSK_ENGINE §1.1`）。
🟡 叩き台を消すか、クロック橋渡しの考え方（DriftFifo とそのテスト）だけ参考に残すかは未決。

## 1. コード地図（❌ 不採用の叩き台）
| パス | 中身 |
|---|---|
| `CMakeLists.txt` | JUCE 8.0.9 と ASIO SDK 2.3.4 を自動で取得してビルドする |
| `Source/AudioEngine.*` | モニター用（ASIO / WASAPI 排他）と配信用（WASAPI 共有 / DirectSound）のデバイス管理を2つ持ち、両方を同時に開く |
| `Source/DriftFifo.*` | 2つのクロックの橋渡し（PI 制御つき3次エルミート補間リサンプラー） |
| `Source/PluginChain.*` | VST3 を直列に挿すチェーン |
| `Source/MainComponent.*` `Source/Main.cpp` | 画面 |
| `Tests/DriftFifoTest.cpp` | クロックの橋渡しのシミュレーションテスト |
| `.github/workflows/build.yml` | Windows でのビルドとテスト |

## 2. 検証済みの事実
- 🟢 Linux（ALSA）でのビルドが警告なしで通る（2026-10-14）。
- 🟢 `DriftFifoTest`: クロックが ±200ppm ずれる条件と、48k⇔44.1k の変換を含む5ケースで、
  水位が目標 30ms の ±0.4ms に収まり、安定後の音切れは0回、SNR は約 100dB（2026-10-14・シミュレーション）。
- 🔴 Windows でのビルド結果は**未確認**（GitHub Actions の初回実行の結果を見ていない）。
- 🔴 実機（X390＋Play! 3）では**一度も動かしていない**。

## 3. 更新履歴（新しい順）

### 2026-10-14 — 仕様の第1回
- デスクトップ音と通話も拾う／ASIO は Creative ASIO／操作は X390 だけ／構成は Zig ＋ C++（極力 Zig・軽量化でバッファを切り詰める）に決定。
- JUCE の叩き台は不採用になった。

### 2026-10-14 — 叩き台の作成と、Gear-vk の運用の流用
- 仕様を決める前に JUCE 版の叩き台を作って push した（ユーザーの指摘で中断）。
- Gear-vk の資料の型・門番フック・日本語の出力スタイル・記憶のバックアップを持ち込んだ。
