# src/audio — 触る前に開く資料

- `docs/1_spec/PSK_ENGINE.md`（§1.2 ASIO と miniaudio・§3.2 クロックの橋渡し・§4 音のスレッドの約束）
- `docs/2_impl/PSK_IMPLEMENTATION_STATUS.md`（検証済みの事実と、まだ実機で見ていないもの）

🔴 **COM は ASIO 用の STA を、miniaudio より先に初期化する**（`asio.initCom` → `psk_ma_init` の順）。
逆だと miniaudio がスレッドを MTA にし、ASIO 側の STA 初期化が `RPC_E_CHANGED_MODE` で失敗する。

🔴 **持ち込んだ `miniaudio.h` には手を入れてある**（"poket-stream-kit patch" で検索）。
`ma_context_get_MMDevice__wasapi` が初期化の成否を見ずに `CoUninitialize` し、STA にしたスレッドの COM を壊していた。
⚠ miniaudio を更新したら、このパッチが要るか確かめる。症状は「デバイスを開いた直後から、同じスレッドの COM 呼び出しが全部失敗する」。

⚠ **Wine の空の音声機器（ALSA の null）は実時間で鳴らない**（1秒に 192,000 フレームを吸い出した）。
橋渡しの音切れを Wine で見ても意味がない。`psk-p1` の「ケーブル読み取り/秒」で機器の実際の速さを確かめてから読むこと。

⭐ 実機の無い環境で ASIO の経路を試すときは、`tools/fake_asio/`（偽 ASIO ドライバ）を Wine に登録する（手順はそのファイルの冒頭）。
