---
name: heredoc-newline-escape-trap
description: ヒアドキュメント経由のPythonで書くと \n が実改行になりビルドが落ちる（今日6回踏んだ）
metadata:
  node_type: memory
  type: feedback
  originSessionId: cf7d18bc-a2f3-476b-a12e-3835d67a132c
  modified: 2026-10-11T17:38:26.314Z
---

Bash のヒアドキュメント（`python - <<'PY'`）から C/Zig のソースへ文字列を書くとき、
`"...\n"` を素直に書くと **実際の改行になってしまい、文字列リテラルが閉じない**。

```
error: string literal contains invalid byte: '\n'    （Zig）
error: missing terminating '"' character             （C/C++）
```

**Why:** 2026-08-28〜29 に**6回**同じ所で落ちた。毎回ビルドを1往復無駄にしている。
⚠ しかも Windows 側のビルドが先に別の理由で止まると**気づかずに Pi へ送ってしまう**。

**How to apply:**
- ⭐ `BS = chr(92)` を定義し、`u'...' + BS + u'n"'` のように**連結で書く**。
- ⭐ 置換ではなく**行番号で丸ごと差し替える**ほうが事故が少ない
  （長い日本語コメントを含む `old` 文字列の完全一致は、インデント差でよく外れる）。
- ⚠ 書いたら **`sed -n 'N,Mp' file | cat -A`** で実体を確認してからビルドする。
- ⭐ そもそも短い1行なら Edit ツールで直接書くほうが速い。
- ⚠ **探す側（置換の old 文字列）でも同じことが起きる**（2026-10-12 に 5 回）。`<<'PYEOF'` と引用しても、
  この環境では `\\n` が実改行・`\\d` が `\d` に化けて、ソース中の `\n` と一致せず assert で止まる。
  ⭐ `\n` を含む行の置換は最初から Edit ツールで（assert で止まるので壊れはしないが、往復が無駄）。

関連: [[read-the-spec-docs-first]]

## 🔴 書き込みそのものも危ない（2026-08-30 に 1751 行を消した）

`io.open(p,'w')` は**開いた瞬間に中身を捨てる**。書く文字列に UTF-8 で表せないもの
（絵文字をサロゲートでエスケープした表記など）が混じると **write で例外→ファイルが空のまま残る**。
実際 `draw_screens.inc`（1751行）を空にした。直前にコミットしていたので `git checkout` で助かった。

⭐ **必ず一時ファイルへ書いて `os.replace` で差し替える**:

```python
tmp = p + ".tmp"
with io.open(tmp, 'w', encoding='utf-8') as f: f.write(out)
os.replace(tmp, p)
```

⚠ 絵文字は**エスケープせず literal で書く**（サロゲート表記は encode で落ちる）。
⚠ ビルド中は Windows がファイルを掴んで `os.replace` が `PermissionError` になる。数秒リトライする。
⚠ 改行の件と合わせ、**Python 経由でソースを書くときは毎回この2点**（BSn は chr(92)+"n"、書き込みは一時ファイル）。
- 🔴 2026-10-08 にも3回踏んだ（printf の「バックスラッシュ n」を含む C の行を Python の置換で書いた）。⭐ **C の文字列リテラルを含む編集は最初から Edit ツールで行う**。Python 置換は文字列リテラルを含まない行だけに使う。
