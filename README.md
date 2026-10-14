# Pocket Stream Host

配信用の「とても小さなDAW / VSTホスト」。
**ASIO（ヘッドホンへの低遅延モニター）と WASAPI共有 / DirectSound（VB-CABLE → OBS）を同時に開く**ことに特化しています。

```
             ┌──────────── dry ───────────┐
ASIO in ──▶ 入力ゲイン ──▶ [VST3チェーン] ──┴─▶ モニター音量 ──▶ ASIO out（ヘッドホン）
                              │
                              └─▶ 配信音量 ──▶ DriftFifo ──▶ WASAPI共有 out（CABLE Input → OBS）
```

- **モニター側**: ASIO / WASAPI排他 / WASAPI低遅延共有から選べます。オーディオの主クロックはこちらです。
- **配信側**: WASAPI共有 / DirectSound。2つのデバイスはクロックが独立しているので、間に
  **ドリフト補正FIFO**（PI制御つき3次エルミート補間リサンプラー）を挟んで、
  バッファの水位を目標値（初期値30ms）に保ちます。48k⇔44.1kの変換も同じ仕組みで処理します。
  ブロックの間引き・複製をしないので、長時間配信してもプチノイズが出ません。
- **プラグイン**: VST3を直列に挿す方式（RX 8、T-De-Esser など）。バイパス、並べ替え、エディタ表示ができ、状態は保存されます。
- **モニターのDry/Wet切り替え**: RXのDe-noiseなどプラグインのレイテンシが大きいとき、
  ヘッドホンだけDry（プラグイン遅延ゼロ）にして、OBSには処理後の音を送れます。
- 設定は終了時に `%APPDATA%\PocketStreamHost\state.xml` に自動保存されます（Saveボタンでも保存できます）。

## ビルド

Windows + Visual Studio 2022 + CMake 3.22以上。JUCE 8 と Steinberg ASIO SDK はCMakeが自動で取得します。

```bat
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
```

`build\PocketStreamHost_artefacts\Release\Pocket Stream Host.exe` ができます。
GitHub Actions（`.github/workflows/build.yml`）でもビルドしていて、exeはArtifactからダウンロードできます。

## X390 + Sound Blaster Play! 3 でのセットアップ

1. **VB-CABLE** をインストールします。
2. **ASIOドライバ**: Play! 3には純正のASIOドライバがない想定です。次のどれかを使ってください。
   - **ASIO4ALL**（WDM-KS）: 一番低遅延です。Play! 3を占有するので、他のアプリの音はPlay! 3から出なくなります。
   - **FlexASIO**（WASAPIベース）: 他のアプリとPlay! 3を共有できます。
   - ASIOを使わずに、モニターデバイスの種類で **Windows Audio (Exclusive Mode)** を選ぶこともできます。
     USB Audio Class機器ではASIO4ALLと同程度の遅延になることが多いです。
3. アプリを起動します。
   - **Monitor device**: ASIO → ASIO4ALLなど、48kHz、バッファは128（ノイズが出るなら256）。
   - **Stream device**: Windows Audio → `CABLE Input (VB-Audio Virtual Cable)`（初回起動時に自動で選ばれます）。
4. **+ Add** でVST3を追加します（`C:\Program Files\Common Files\VST3` を自動で探します。別のフォルダも追加できます）。
5. OBSで「音声入力キャプチャ」→ `CABLE Output` を追加します。
6. 画面下部のステータスに、モニターの往復遅延、プラグイン遅延、配信バッファの水位、ドリフト補正量（ppm）、アンダーランの回数が表示されます。
   アンダーランが増えるときは **Stream buffer** を40〜60msに上げてください（OBSへの遅延が増えるだけで、モニターには影響しません）。

VTube Studio（iOSトラッキング / Tailscale）はこのアプリとは独立に動くので、今まで通りOBSに取り込めばOKです。
口の動きと音のズレは、OBS側の「同期オフセット」で合わせてください。

## 注意

- VST2は非対応です（VST2 SDKが配布終了のため）。T-De-EsserもRX 8もVST3版を使ってください。
- ライセンス: JUCE（AGPLv3 / 商用）と ASIO SDK（GPLv3 / Steinberg独自）を使っています。
  個人で使う分には問題ありませんが、バイナリを配布する場合は、これらのライセンスに従ってソースを公開する必要があります。

## テスト

```sh
cmake -S . -B build -DPSH_BUILD_TESTS=ON && cmake --build build --target DriftFifoTest
ctest --test-dir build
```

独立したクロック（±200ppm、44.1k⇔48k）で走る2つのデバイスをシミュレーションし、
FIFOが目標水位に収束すること、アンダーランが0であること、SNRが60dBを超えることを確認します。
