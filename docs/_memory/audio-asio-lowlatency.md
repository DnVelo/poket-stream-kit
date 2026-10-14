---
name: audio-asio-lowlatency
description: ASIO低遅延を実現した構成(RtAudio経由/open-once/固定bit-Hz)と残る分裂(メニュー音統合③)
metadata: 
  node_type: memory
  type: project
  originSessionId: 14a37b1c-09f0-431c-96cf-3d4ad803c46d
---

**2026-07-21 達成**: 音ゲーとして意味ある低遅延が通った。入力(低遅延ドライバ=イベント駆動)＋出力(ASIO 1.5ms)。
ユーザー実機で「明らかに遅延激減」を確認。

**構成（source of truth はコード。要点のみ）:**
- **ASIO は RtAudio(WINDOWS_ASIO) 経由**。miniaudio に ASIO は無い([[audio-backend-miniaudio化]] のトリム版)ので
  RtAudio を温存して使う。ASIO⇔非ASIO の切替は要再起動。ASIO失敗時は WASAPI共有へ自動フォールバック。
- **open-once（clock.cpp）**: 曲間で ASIO を close せず stopStream/startStream で保持。以前は曲ごとに
  close→再オープンして SSL 再取得に失敗し「no devices」→WASAPIフォールバック(=2曲目で遅延復活)していた。
  start()は開設定(api/dev/hz/bits)一致で resume・変化で closeAudio→開き直し。medley はシームレス維持。
- **固定 bit/Hz（オペレーター設定・operator.txt bits=/hz=）**: デバイスをこの固定値で開き全音源を
  conformToDevice でそのレートへ整合。設定以下=アップサンプル無劣化/設定超=抑制(onboard保護)。
  ASIO は最大32bit/192kHz、非ASIO は最大24bit/48kHz にクランプ(main.cpp clampAudioFmt)。既定=WASAPI共有256。
- ハイレゾ源(WAV/FLAC 24/32bit)デコードは**次フェーズ**(今は OGG を任意レートでネイティブ再生まで=A案)。

**Why:** WASAPI排他(~5ms)とASIO(1.5ms)は音ゲーで体感差あり(ユーザー判断)。ダウンサンプルは音質劣化なので回避。

**③統合 完了(2026-07-21):** 選曲プレビュー(compat_preview)とUI音(compat_sound)を **MasterClock の
ミックスソース(addMixSource/removeMixSource・最大4)** に合流させ、全音声を1デバイス(SSL/ASIO)に集約。
- clock: fillAudio がマスター段直前で各ソースを out へ加算。extern C ブリッジ gear_audio_bind_clock/
  out_rate/add_mix/remove_mix。デバイスは**起動時**に open(メニュー中も鳴らすため)。
- 各ソースは device rate へオンザフライ線形リサンプル(UI音=ボイス毎/プレビュー=リング読みwhile pop)。
- 寿命安全: PreviewStream は per-Music(new/delete)なので removeMixSource は cb_epoch でコールバック2巡
  待ち(非稼働時は即抜け)＝audio スレッド in-flight と delete の競合防止。UI音は singleton で待ち不要。
- プレビューEQ は今回省略(将来 device rate で復活可)。要実機確認=曲送り連打でクラッシュしないか。

**運用メモ:** SSL USB Control Panel/DAW を開いていると SSL ASIO を掴まれ「no devices」になる→検証時は閉じる。
DIパッド決定時の openDiDev は DIPROP_BUFFERSIZE の UBSan 誤検出対策で -fno-sanitize=alignment 済([[booth-home-xinput-distribution]] とは別)。
