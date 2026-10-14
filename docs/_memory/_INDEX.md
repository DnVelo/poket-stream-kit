# Memory Index

> 🟢 下の14件は **Gear-vk の `docs/_memory/` から持ち込んだ写し**（2026-10-14）。
> ⚠ 中のパス・関数名・日付は Gear-vk のもの。このリポジトリに当てはめるときは「教訓」として読む。

## 進め方の教訓（Gear-vk から）
- [日本語で返答](reply-in-japanese.md) — ユーザーは英語長文が苦手・返答は日本語で
- [離れると聞いたら片道の変更をしない](no-one-way-changes-while-away.md) — 2026-08-26「夕方まで離れる」の5分後に起動順を変えて帰れなくなった・未確認の挙動に退路を賭けない
- [既にある仕組みを先に探す](look-for-existing-mechanism-first.md) — 2026-08-28に2回作り直した(build.zigの-Dsysroot / BuildrootのGETTY_PORT)・自前細工は空振りしても気づけないのが最悪
- [数値を引用する前に資料を読む](read-the-spec-docs-first.md) — 2026-08-28にスクリプトのコメントを根拠にして外した・コードが名指しした節(GEAR_LICENSES §4.4)を開かなかった
- [ヒアドキュメントの\n書き損じ](heredoc-newline-escape-trap.md) — Python経由でソースへ書くと\nが実改行になる・今日6回踏んだ・chr(92)で連結するか行番号で差し替える
- [要求されていない制約を発明しない](do-not-invent-constraints.md) — 時間制限と2秒を勝手に足した(2026-08-29)・指摘されたら既存規約に揃えるのではなく外す
- [ゼロの観測には対照が要る](null-result-needs-a-live-control.md) — 「反応が無い」と言う前に、計測が生きていた証拠を同じ記録に持たせる(2026-08-30に2回誤報)

## 開発環境（Gear-vk から・ユーザーの機材とツール）
- [開発リグ(GPD WIN4/Z Fold5)](dev-rig-gpdwin4-zfold5.md) — 開発機=GPD WIN4(電池摘出→ミニPC)・出先リモート/Winlator確認にZ Fold5・WinlatorのTurnip検証はV3DV移植の予行になるが遅延/判定は代表しない(2026-07-24)
- [PowerShell 5.1のUTF-8誤読→pwsh7へ移行完了](powershell-utf8-file-damage.md) — 5.1はBOMなしUTF-8をShift_JIS誤読(.ps1本体も)・2026-07-23にpwsh7導入＋WT既定＋Claudeのシェルも7に(検出は起動時1回)
- [ツール場所](tools-locations.md) — ツールは D:\tools\<名前>\ にポータブル配置(PATH未設定)・git と gh(2026-08-31導入)・node(2026-09-30・cjeditor 用)
- [WIN4は再起動でグラフィックが出ないことがある](win4-reboot-graphics-risk.md) — 電池摘出のGPD WIN4は再起動後に画面が出ず強制再起動の繰り返しになる→**再起動を複数回挟む作業(インプレース修復/機能更新)は提案しない**・Linuxホストが要るならライブUSB優先

## オーディオ（Gear-vk から・ASIO / WASAPI を実機で詰めた記録）
- [ASIOでクロスフェード無効だった](asio-crossfade-gap.md) — 開発機はapi=4(ASIO)・miniaudio前提のガードでメドレー曲間が長らくハード切替だった(2026-07-23修正)
- [ASIO低遅延達成(2026-07-21)](audio-asio-lowlatency.md) — RtAudio経由ASIO 1.5ms＋open-once(曲間保持)＋固定bit/Hz・残=メニュー音統合③(選曲/UI音が別デバイスで分裂)
- [音声バックエンドminiaudio化](audio-backend-miniaudio.md) — RtAudio→miniaudio(MIT-0)でWASAPI排他≈5.3ms実機実証・ASIO打ち切り(構成温存)・抜けフォールバック・EQ/音量プロフィールoverride

## poket-stream-kit で得たもの
（まだ無い）
