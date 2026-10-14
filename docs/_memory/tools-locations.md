---
name: tools-locations
description: PATHに無いがインストール済のツールのフルパス。Git等。
metadata: 
  node_type: memory
  type: reference
  originSessionId: d9d0196f-ae52-4898-99ef-7033fa3b56ce
---

# ツールのフルパス（PATH 未設定）

- **git**: `D:\tools\git\bin\git.exe` (git version 2.55.0.windows.2)
  - PowerShell で使うときは事前に `$env:PATH = "D:\tools\git\bin;$env:PATH"` する
  - 呼び出し例: `cd D:\GAMES\Gear; git log --oneline HEAD -5`

- **gh**（GitHub CLI）: `D:\tools\gh\bin\gh.exe` (v2.98.0・2026-08-31 導入・公式 zip のポータブル配置)
  - ⚠ `winget`/管理者権限は使っていない。更新は `cli/cli` の releases から zip を取り直して同じ場所へ展開。
  - ⭐ 用途: リポジトリの新規作成（`git push` だけでは作れない）。⚠ **認証は本人が `gh auth login`** で行う
    （トークンは私が扱わない）。

- **node / npm**: `D:\tools\node\node.exe`（v24.21.0 LTS・npm 11.19.0・2026-09-30 導入・公式 zip を SHA256 照合してポータブル配置）
  - 用途: 譜面エディタ `cjeditor`（smeditor の fork・`D:\GAMES\cjeditor`）のビルド。bash では `PATH="/d/tools/node:$PATH"` を先頭に足す
  - ⚠ cjeditor の**コミット時に husky が `npx` を呼ぶ**ので、コミットのときも PATH に要る
  - ⚠ npm 11 は依存のインストール後スクリプトを既定で止める（`allowScripts` で個別に許可）

- **zig**: **`zig` は PATH 上(`C:\Zig\zig.exe`)＝バージョン 0.15.1 に統一済み(2026-07-15)**。プロジェクト全体（Gear-vk／Gear-fw-a／Gear-fw-b）を Zig 0.15.1 に統一。以前の 0.13.0(Gear-vk)/0.14.x(実験) は撤去。`D:\tools\zig-0.15.1` にも同一版あり（バックアップ）。microzig は各 firmware で **0.15.1** タグにピン。[[pico-firmware-toolchain]] 参照。

# コミット記録

- git がある場所を毎回探すのは無駄なので、上記パスを最優先で試すこと（`Get-Command git` は失敗する）。
- ⭐ **この端末の流儀＝ツールは `D:\tools\<名前>\` にポータブル配置**（PATH には入れない）。
  新しい道具を足すときも同じ形にすると、探し方が1つで済む。
