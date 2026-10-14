#!/usr/bin/env python3
# 🔴 コードを触る前に「その領域の資料」を**目次から辿らせる**門番（2026-09-02 / 2026-09-08 全面改修）。
# ⭐ Gear-vk から流用（2026-10-14）。変えたのは ROOT（このファイルの位置から求める）・MAP と HINTS（本リポの資料と語）・凍結リポ判定の削除だけ。
#   下の経緯コメントは Gear-vk でのもの。
#
# ⚠ 旧版は `additionalContext` を出すだけで**ブロックしなかった**。結果（2026-09-08 実測）:
#   1日で4件、資料を開かずに断定した。⭐ **助言は無視できる。無視できないのは拒否だけ。**
#
# ⚠ さらに、拒否にしただけでも足りないと分かった。**固定の節を抜粋しても、それが今の作業と
#   関係あるとは限らない**（`src/core/` を触ると常に §1.2 が出る、等）。⭐ 欠けていたのは
#   「**目次を見て、いまの疑問に当たる節を自分で選ぶ**」という行為そのもの。
#   だから抜粋ではなく**目次を出す**。選ぶ手間を消さずに、探す手間だけを消す。
#
# 仕組み:
#   ① 該当領域を触ろうとしたら **deny**。理由に**その資料の目次**を出す。
#   ② いま触っているファイル名から拾った語が見出しに含まれていれば **←** を付けて目立たせる。
#      ⚠ あくまで手がかり。⭐ 正解を指すのではなく、**選ぶのは読む側**。
#   ③ 解除は `Read <資料>` の1手だけ。読めばしばらく黙る（④）。
#   ④ 🔴 **既読は忘れる**（2026-10-12・ユーザー指摘「コードに手を入れるとき全般で資料を確認」）。
#      ⚠ 旧版は「一度読めばそのセッションでは黙る」だった。⚠ ところがこのプロジェクトは**1つのセッションを
#        要約（compaction）で何週間も続けている**ので、主な資料は9月に読んだ記録が残り、門番は**二度と鳴らなかった**
#        （既読 1132 行・TEST に項目を足すとき `REVIEW_TESTMENU` の過去の判断を読まずに進めかけた）。
#      ⭐ 既読は「**最後の要約より後**」かつ「**TTL（3時間）以内**」に読んだものだけ数える。要約で中身を忘れた
#        資料は、もう読んでいないのと同じ。要約は記録（transcript）の `compact_boundary` を後ろから拾う。
#   ⑤ ⭐ 網は**全般**（2026-10-12）: Gear-app / Gear-fw-a/b / テーマ素材 / tools / build.zig まで広げ、
#      どれにも当たらない Gear-vk のコードは索引（GEAR_README.md）を必読にする。
#      決定が複数の資料に分かれている場所（TEST メニュー）は**全部**読むまで通さない。
#
# ⚠ 行き止まり防止: `.claude/`（門番自身）と `docs/`（資料を書く作業）は素通し。
# ⚠ hook は落ちても黙って無視される＝**気づかないまま門番が死ぬ**。触ったら必ず4通り試すこと
#   （未読で拒否／読んだら通る／門番自身は素通し／読むだけの Bash は鳴らない）。
import json, os, re, sys

# ⚠ Windows の既定は cp932 で ⭐/🔴 が出せず落ちる（2026-09-02 実測）。UTF-8 を明示する。
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))).replace("\\", "/")
STATE_DIR = os.path.join(ROOT, ".claude", "state")

# (パターン, 必読ファイル)
# ⚠ **網の穴が一番怖い**。2026-09-08 に `main.cpp` と `*.inc` が丸ごと外れていた
#   （実際に外した4件のうち2件がそこだった）。⭐ 迷ったら広く取る。
MAP = [
    # ⭐ オーディオ経路・デバイス・クロック・プラグイン＝技術仕様と現在地の**両方**。
    (r"(src|Source|Tests)/.*([Aa]udio|[Ff]ifo|[Dd]rift|[Cc]lock|[Dd]evice|[Pp]lugin|[Cc]hain|asio|wasapi)",
     ("docs/1_spec/PSK_ENGINE.md", "docs/2_impl/PSK_IMPLEMENTATION_STATUS.md")),
    # ⭐ それ以外のコードとビルド定義＝**索引**を読む（そこから2ファイルを決める）。
    (r"(^|[\s'\"=(/])(src|Source|Tests|tools)/|CMakeLists\.txt|build\.zig|\.github/workflows/",
     "PSK_README.md"),
]

# 既読を数える期間（秒）。⚠ 要約より前の既読も数えない（`compact_cutoff`）。
READ_TTL_SEC = 3 * 3600

# ⚠ Bash で「書き込みをしている」形（読むだけのコマンドでは鳴らさない）。
WRITES = re.compile(r"(sed\s+-i|>>?\s|\btee\b|\bcp\b|\bmv\b|\bopen\([^)]*['\"]w)")

# 見出しの手がかりに使う語（ファイル名の断片 → 資料で使われている言葉）。
HINTS = {
    "audio": "オーディオ", "clock": "クロック", "asio": "ASIO", "wasapi": "WASAPI",
    "fifo": "クロック", "drift": "クロック", "device": "デバイス", "plugin": "プラグイン", "chain": "プラグイン",
}


def state_path(sid):
    return os.path.join(STATE_DIR, (sid or "nosession")[:64] + ".read")


def already_read(sid, target, cutoff):
    """`cutoff`（epoch 秒）より後に読んでいれば真。行は `<epoch>\t<path>`。
    ⚠ 旧形式（時刻なしの path だけ）は**読んでいない**扱い＝改修前の既読は全部忘れる（それが狙い）。"""
    try:
        with open(state_path(sid), encoding="utf-8") as f:
            for x in f:
                ts, sep, p = x.rstrip("\n").partition("\t")
                if not sep:
                    continue
                try:
                    t = float(ts)
                except ValueError:
                    continue
                if t > cutoff and p.endswith(target):
                    return True
    except Exception:
        pass
    return False


def compact_cutoff(sid, transcript):
    """最後の要約（`compact_boundary`）の時刻（epoch 秒・無ければ 0）。
    ⚠ 記録は数百 MB になる（2026-10-12 で 411MB）。⭐ **前回どこまで見たか**を覚え、増えた分だけ探す。
      初回だけは後ろから 8MB ずつ遡って最後の1件を探す（先頭から読まない）。"""
    if not transcript:
        return 0.0
    meta = os.path.join(STATE_DIR, (sid or "nosession")[:64] + ".compact")
    st = {"offset": -1, "ts": 0.0}
    try:
        with open(meta, encoding="utf-8") as f:
            st.update(json.load(f))
    except Exception:
        pass
    key = b'"subtype":"compact_boundary"'
    try:
        size = os.path.getsize(transcript)
        with open(transcript, "rb") as f:
            hit = None  # 見つけた行（bytes）
            if st["offset"] < 0 or st["offset"] > size:
                pos = size
                tail = b""
                while pos > 0 and hit is None:
                    n = min(8 << 20, pos)
                    pos -= n
                    f.seek(pos)
                    buf = f.read(n) + tail
                    i = buf.rfind(key)
                    if i >= 0:
                        s = buf.rfind(b"\n", 0, i) + 1
                        e = buf.find(b"\n", i)
                        hit = buf[s:e if e >= 0 else len(buf)]
                    tail = buf[:4096]  # 境目で切れた鍵を拾う
            elif size > st["offset"]:
                f.seek(st["offset"])
                buf = f.read(size - st["offset"])
                i = buf.rfind(key)
                if i >= 0:
                    s = buf.rfind(b"\n", 0, i) + 1
                    e = buf.find(b"\n", i)
                    hit = buf[s:e if e >= 0 else len(buf)]
        if hit is not None:
            ts = 0.0
            try:
                import datetime
                iso = json.loads(hit.decode("utf-8", "replace")).get("timestamp") or ""
                ts = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()
            except Exception:
                import time
                ts = time.time()  # ⚠ 時刻が読めなければ「いま要約された」とみなす（忘れる側へ倒す）
            st["ts"] = max(st["ts"], ts)
        st["offset"] = size
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(meta, "w", encoding="utf-8") as f:
            json.dump(st, f)
    except Exception:
        pass
    return float(st.get("ts") or 0.0)


def record_read(sid, path):
    try:
        import time
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(state_path(sid), "a", encoding="utf-8") as f:
            f.write("%.0f\t%s\n" % (time.time(), path.replace("\\", "/")))
    except Exception:
        pass


def toc(rel, path_for_hints, limit=40):
    """⭐ **目次を出す**。探す手間だけを消し、選ぶ手間は残す（選ぶのが欠けていた行為なので）。"""
    try:
        with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
            lines = f.read().splitlines()
    except Exception:
        return ""
    low = path_for_hints.lower()
    words = [w for k, w in HINTS.items() if k in low]
    heads = []
    for l in lines:
        if not l.startswith("#"):
            continue
        h = l.strip()
        if len(h) > 90:
            h = h[:90] + "…"
        mark = " ←" if any(w in h for w in words) else ""
        heads.append("  │ " + h + mark)
        if len(heads) >= limit:
            heads.append("  │ …（以降は実際に開くこと）")
            break
    return "\n".join(heads)


def emit(obj):
    print(json.dumps(obj, ensure_ascii=False))


def deny(reason):
    emit({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }})


def main():
    try:
        ev = json.load(sys.stdin)
    except Exception:
        return 0
    sid = ev.get("session_id") or ""
    tool = ev.get("tool_name") or ""
    ti = ev.get("tool_input") or {}

    # 「読んだ」を記録する。⚠ これが解除の唯一の条件＝行き止まりにならない。
    if tool in ("Read", "NotebookRead"):
        fp = ti.get("file_path") or ""
        if fp:
            record_read(sid, fp)
        return 0

    path = ti.get("file_path") or ""
    why = ""  # Bash のとき「何を書き込みと見なしたか」（誤検出を追えるように出す）
    if not path:
        # 🔴 Bash 経由の編集（sed -i / ヒアドキュメント / リダイレクト）は file_path を持たない。
        #    ⚠ ここを見ないと「Bash で書く」運用で門番が丸ごと無効になる（2026-09-03 判明）。
        cmd = ti.get("command") or ""
        # ⚠ **git は素通し**（2026-09-08）。`git commit -F -` の本文には、直した対象として
        #   守備範囲のパスが普通に書かれる＝**コミットそのものが止まる**。
        #   ⭐ git はソースを書き換えないので、ここで見る意味がない。
        w = cmd.strip().split()
        if len(w) >= 2 and w[0] == "git" and w[1] not in ("checkout", "restore", "apply", "stash"):
            return 0
        m = WRITES.search(cmd)
        if not m:
            return 0
        why = m.group(0)
        path = cmd
    p = path.replace("\\", "/")

    # ⚠ 凍結リポ判定は `Edit`/`Write` だけに掛ける（2026-09-08）。
    #   Bash のコマンド文字列には**そのパスを話題にしているだけ**の引用が普通に混ざり、
    #   書き込みかどうかを文字列から見分けられない（実際にこの検査自身のテストが止まった）。
    #   ⭐ 誤検出する規則は回避策を探されて形骸化するので、確実な場所にだけ置く。
    # ⚠ 行き止まり防止: 門番自身と資料は素通し。
    if "/.claude/" in p or "/docs/" in p:
        return 0

    docs = next((d for pat, d in MAP if re.search(pat, p)), None)
    if not docs:
        return 0
    if isinstance(docs, str):
        docs = (docs,)
    import time
    comp = compact_cutoff(sid, ev.get("transcript_path") or "")
    cutoff = max(comp, time.time() - READ_TTL_SEC)
    missing = [d for d in docs if not already_read(sid, d, cutoff)]
    if not missing:
        return 0
    doc = missing[0]

    body = toc(doc, p)
    reason = (
        "🔴 **資料を目次から辿る前に、この領域を触らない**（CLAUDE.md の規則）。\n"
        "  ⚠ 助言では守られなかったので拒否にしてある（2026-09-08・1日で4件外した）。\n"
        "  ⚠ 既読は**最後の要約より後・" + str(READ_TTL_SEC // 3600) + "時間以内**だけ数える（要約で中身は忘れている・2026-10-12）。\n"
        "  ⭐ 解除: `Read " + doc + "`" + ("（この場所は " + " と ".join(docs) + " の**両方**）" if len(docs) > 1 else "") + "。\n"
        "  ⚠ **開くだけで終わらせない**。下の目次から**いまの疑問に当たる節**を選んで読むこと。\n"
        "  ⚠ 挙動・数値を述べる前に、**呼び出し元が本当に1つか**（grep の件数）も確かめる。\n"
    )
    if why:
        # ⚠ 誤検出だったときに原因が分かるように、判定の根拠を必ず見せる。
        reason += "  （書き込みと見なした箇所: `" + why.strip() + "`）\n"
    if body:
        reason += "\n  ── " + doc + " の目次（← は今回の作業に関係しそうな節）──\n" + body + "\n"
    deny(reason)
    return 0


sys.exit(main())
