---
name: reply-in-japanese
description: User prefers all replies in Japanese; struggles reading long English text
metadata: 
  node_type: memory
  type: feedback
  originSessionId: fb721d07-aaf8-4d3c-8402-85d74ae23832
---

ユーザーは英語の長文を読むのが苦手。返答は日本語で行うこと（コード・コマンド・識別子はそのままでよいが、説明文・要約・見出しは日本語）。

**Why:** 2026-07-08 に明示的に依頼された。英語の長文だと読むのに負担がかかる。
**How to apply:** このプロジェクト（Gear / [[vulkan-migration]]）のやり取りは常に日本語で。技術用語やコマンドは原語のままで可。

- 🔴 **途中経過の一言（ツールの合間に書く文）も日本語で**。2026-10-03 に作業の合間の報告が英語になり、2回指摘された。

- 🟢 **2026-10-03 に仕組みで止めた**: フック `Gear-vk/.claude/hooks/lang_gate.py`（UserPromptSubmit で毎ターン注意を差し込み、Stop でこのターンの文章を判定して英語が主なら書き直させる）。過去ログを `--scan` したら英語の段落が 110 件あった＝作業の合間の報告がほぼ英語だった。
