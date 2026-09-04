"""删除判据的离线单测。每条闸都要能独立拦住。"""
import json, sys, tempfile
from datetime import datetime
from pathlib import Path
from unittest.mock import patch

import cleanup, oggwrap
from protocol import FileEntry

NOW = datetime(2026, 8, 28, 21, 0, 0)
ok = fail = 0

def check(name, got, want):
    global ok, fail
    if got == want: ok += 1; print(f"  PASS  {name}")
    else: fail += 1; print(f"  FAIL  {name}\n        得到 {got!r}\n        期望 {want!r}")

class Sess:
    headers = {}

def entry(name="note20260801-100000", secs=20, size=None):
    size = size if size is not None else secs * 2000      # 16kbps = 2000B/s
    raw = f"{name}.".encode().ljust(20, b"\x00")[:20]
    return FileEntry(time=secs, size=size, name=raw.split(b"\x00")[0].decode(), raw_name=raw)

_case = [0]

def setup(tmp, e, *, raw_size=None, ogg=True, raw=True, ogg_content=b"OggS"):
    # 每个用例独立目录：共用目录会让前一个用例造的文件把"缺留档"这类断言变成假阳性
    _case[0] += 1
    root = Path(tmp) / f"case{_case[0]}"
    dest, rawdir = root/"导入", root/"原始包"
    dest.mkdir(parents=True, exist_ok=True); rawdir.mkdir(parents=True, exist_ok=True)
    base = e.name.rstrip(".")
    if raw: (rawdir/f"{base}.opus").write_bytes(b"\x00" * (raw_size if raw_size is not None else e.size))
    if ogg: (dest/f"{base}.ogg").write_bytes(ogg_content)
    return dest, rawdir

def judge(e, tmp, *, uploaded=True, status="ready", tid="t1", cooling=3,
          current=None, **kw):
    dest, rawdir = setup(tmp, e, **kw)
    man = {"uploaded": {e.name.rstrip("."): "sess-1"} if uploaded else {}}
    with patch.object(cleanup.deepbrain, "_request",
                      return_value=(200, json.dumps({"session": {"status": status,
                                    "final_transcript_id": tid}}).encode())):
        return cleanup.judge(e, man, dest, rawdir, Sess(), cooling, NOW, current, {})

with tempfile.TemporaryDirectory() as tmp:
    print("1. 全部条件满足 → 删")
    check("允许删除", judge(entry(), tmp).delete, True)

    print("\n2. 每一条闸都要能独立拦住")
    check("没同步过", judge(entry(), tmp, uploaded=False).delete, False)
    check("深脑还在处理", judge(entry(), tmp, status="finalizing").delete, False)
    check("深脑失败", judge(entry(), tmp, status="failed").delete, False)
    check("深脑没转写", judge(entry(), tmp, tid=None).delete, False)
    check("缺 ogg 留档", judge(entry(), tmp, ogg=False).delete, False)
    check("缺裸包留档", judge(entry(), tmp, raw=False).delete, False)
    check("字节数对不上", judge(entry(), tmp, raw_size=40).delete, False)
    check("裸包非 40 倍数", judge(entry(secs=20, size=40001), tmp, raw_size=40001).delete, False)
    check("在冷静期内", judge(entry("note20260828-090000"), tmp, cooling=3).delete, False)
    check("是设备当前文件", judge(entry(), tmp, current="note20260801-100000.opus").delete, False)
    check("文件名无时间戳", judge(entry("recording-abc"), tmp).delete, False)

    print("\n2b. 文件名时间戳必须可信（RTC 归零会绕过冷静期）")
    check("RTC 归零的 note20000101 → 不删", judge(entry("note20000101-000000"), tmp).delete, False)
    check("未来时间戳 → 不删", judge(entry("note20991231-235959"), tmp).delete, False)

    print("\n2c. ogg 留档必须是真的")
    check("0 字节 ogg → 不删", judge(entry(), tmp, ogg_content=b"").delete, False)
    check("内容不是 OggS → 不删", judge(entry(), tmp, ogg_content=b"XXXX").delete, False)

    print("\n3. 时长必须吻合")
    e = entry(secs=20, size=20*2000)
    check("时长对得上", judge(e, tmp).delete, True)
    e2 = FileEntry(time=999, size=20*2000, name="note20260801-100000.",
                   raw_name=b"note20260801-100000.".ljust(20, b"\x00"))
    check("设备声称 999s 实际 20s → 拒绝", judge(e2, tmp).delete, False)

    print("\n4. 冷静期边界")
    check("冷静期 0 天时立刻可删", judge(entry("note20260828-090000"), tmp, cooling=0).delete, True)

    print("\n5. 整机在录音时全部否决")
    dest, rawdir = setup(tmp, entry())
    man = {"uploaded": {"note20260801-100000": "s"}}
    with patch.object(cleanup.deepbrain, "_request",
                      return_value=(200, b'{"session":{"status":"ready","final_transcript_id":"t"}}')):
        for st, label in [(1, "录音中"), (3, "暂停"), (None, "状态未知")]:
            ds = cleanup.plan([entry()], man, dest, rawdir, Sess(), 3, NOW, st, None)
            check(f"设备{label} → 一条都不删", any(d.delete for d in ds), False)
        ds = cleanup.plan([entry()], man, dest, rawdir, Sess(), 3, NOW, 2, None)
        check("设备未录音 → 正常判定", ds[0].delete, True)

    print("\n6. 查深脑失败时必须保守")
    dest, rawdir = setup(tmp, entry())
    with patch.object(cleanup.deepbrain, "_request", side_effect=OSError("网络断了")):
        d = cleanup.judge(entry(), man, dest, rawdir, Sess(), 3, NOW, None, {})
    check("查询异常 → 不删", d.delete, False)

print(f"\n{'='*46}\n通过 {ok}，失败 {fail}")
sys.exit(1 if fail else 0)
