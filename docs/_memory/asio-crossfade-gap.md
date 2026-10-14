---
name: asio-crossfade-gap
description: 開発機は operator.txt api=4＝ASIO・そこではメドレーのクロスフェードが長らく無効だった（2026-07-23に修正）
metadata: 
  node_type: memory
  type: project
  originSessionId: ae7cd9e8-5770-4cba-a1c4-a9e299037700
  modified: 2026-07-22T18:41:00.677Z
---

開発機（この PC）の `operator.txt` は `api=4`＝**ASIO**（RtAudio 経路）。

`MasterClock::crossfadeToOgg` / `crossfadeToPrepared` が `ma_ == nullptr` で即 return していたため、**ASIO ではメドレーの曲間クロスフェードが毎回失敗**し、デバイス停止を伴うハード切替（音のぶつ切り）になっていた。2026-07-23 に「デバイスが1つも開いていない時だけ不可」へ修正済み（2スロットのミックスも権威時刻も `fillAudio` にあり両バックエンド共有なので本来バックエンド非依存）。

**教訓**: 音声まわりの挙動を開発機で確認するときは、**miniaudio 前提のコードパスが ASIO で無効化されていないか**を疑う。バックエンド分岐のガードは `ma_` 単独でなく `ma_ && rt_` の両方を見る。

関連: [[audio-backend-miniaudio]] / [[medley-fused-chart]]
