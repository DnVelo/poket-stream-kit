---
name: powershell-utf8-file-damage
description: PowerShell 5.1 は BOM なし UTF-8 を Shift_JIS と誤読する（=バグでなく既定値）・2026-07-23 に pwsh 7 へ完全移行済み（Claude のツールも含む）
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 1fab682b-bda1-4ccb-b8c3-bb8cfb0e9233
  modified: 2026-07-23T04:34:01.508Z
---

Windows PowerShell **5.1** は `Get-Content` の既定エンコーディングが**システム ANSI コードページ（この環境は CP932/Shift_JIS）**なので、**BOM なし UTF-8** を読むと文字化けする。壊れるのは読み込み側なので**書き戻しても復元不可**。2026-07-23 に `(Get-Content main.cpp) -replace ... | Set-Content` で日本語コメントを全滅させ `git checkout` で復旧した。

さらに悪いことに、5.1 は **`.ps1` スクリプト本体も同じ規則で読む**ため、BOM なし UTF-8 で日本語を含む .ps1 は**構文エラーで起動すらしない**（`Gear-app/run_device.ps1` が実際にそうだった。7 では 0 エラー）。

**対応（2026-07-23 実施・完了）**: PowerShell 7.6.4 をユーザースコープで導入（`winget install Microsoft.PowerShell --scope user`・管理者権限不要）。7 は既定が UTF-8(BOM なし) で往復しても無傷。Windows Terminal の `defaultProfile` を pwsh 7 の GUID `{574e775e-4f2a-5b96-ac1e-a2962a402336}` に変更（settings.json の隣に `.bak-before-pwsh7` あり）。

**Claude Code のシェルも pwsh 7 になった**（Claude Code 再起動後に確認済み: 実体 `WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe` / PSVersion 7.6.4 Core / 既定 utf-8）。Claude Code は**起動時に一度だけ**シェルを検出し、`pwsh`(PATH) → `%ProgramFiles%\PowerShell\7` → `%LOCALAPPDATA%\Microsoft\WindowsApps` → `%USERPROFILE%\.dotnet\tools` → `powershell`(5.1) の順に探す（内部テレメトリのラベルが `fell_back_to_powershell_5`）。**セッション中に pwsh を入れても反映されない＝再起動が要る**。

**How to apply**:
- ソースの文字列置換はシェルでやらず **Edit ツール**を使う（pwsh 7 でも、これが最優先の再発防止）。
- pwsh 7 では `&&`/`||`・三項演算子・`??` が使える。`Get-Content -Raw` も使える（5.1 では使えなかった）。
- 5.1 に戻る状況（他マシン等）では `-Encoding utf8` が **BOM 付き**になる点に注意（BOM なしは 7 の `utf8NoBOM` のみ）。
- Windows の「UTF-8 ベータ」(ACP=65001) は Shift_JIS 前提の旧ツールを壊すので採用しない。

関連: [[tools-locations]]
