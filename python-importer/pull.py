#!/usr/bin/env python3
"""录音笔批量导入。连接 -> 列表 -> 只导新的 -> 封 Ogg -> 出报告。

只读设备。**不实现任何删除命令**，导完设备里的文件原样保留。
    python pull.py              # 导入所有还没导过的
    python pull.py --all        # 连导过的也重导
    python pull.py --index 2,5  # 只导指定序号
"""
from __future__ import annotations

import argparse
import asyncio
import html
import json
import subprocess
import sys
import time
from pathlib import Path

import ble
import cleanup as cleanup_mod
import deepbrain
import oggwrap
import protocol as P

ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / "导入"
RAW = DEST / "原始包"
MANIFEST = DEST / "manifest.json"
REPORT = DEST / "导入报告.html"


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{int(n)}B" if unit == "B" else f"{n:,.1f}{unit}"
        n /= 1024
    return ""


def hhmmss(sec: float) -> str:
    sec = int(sec)
    return (f"{sec//3600}:{sec%3600//60:02d}:{sec%60:02d}" if sec >= 3600
            else f"{sec//60}:{sec%60:02d}")


def notify(text: str, title: str = "录音笔导入器") -> None:
    try:
        subprocess.run(["osascript", "-e",
                        f'display notification "{text}" with title "{title}"'],
                       capture_output=True, timeout=5)
    except Exception:
        pass


def load_manifest() -> dict:
    if MANIFEST.exists():
        try:
            return json.loads(MANIFEST.read_text())
        except Exception:
            pass
    return {"imported": {}}


def key_of(entry) -> str:
    return f"{entry.name}|{entry.time}|{entry.size}"


def write_report(rows: list[dict], device: dict) -> None:
    def td(x, cls=""):
        return f'<td class="{cls}">{html.escape(str(x))}</td>'
    body = "\n".join(
        "<tr>" + td(r["name"]) + td(r["duration"], "num") + td(r["size"], "num")
        + td(r["speed"], "num") + td(r["status"], "ok" if r["ok"] else "bad")
        + td(r.get("brain", "-"), "ok" if r.get("brain") == "已入深脑" else "") + "</tr>"
        for r in rows)
    total_ok = sum(1 for r in rows if r["ok"])
    note = (f'<p class="empty">{html.escape(device["note"])}</p>'
            if device.get("note") else "")
    REPORT.write_text(f"""<!doctype html><html lang="zh"><head><meta charset="utf-8">
<title>录音导入报告</title><style>
:root{{--bg:#fff;--fg:#18181b;--mut:#71717a;--line:#e4e4e7;--ok:#15803d;--bad:#b91c1c;--card:#fafafa}}
@media(prefers-color-scheme:dark){{:root{{--bg:#0c0c0d;--fg:#e8e8ea;--mut:#8b8b93;--line:#27272a;--ok:#4ade80;--bad:#f87171;--card:#141416}}}}
*{{box-sizing:border-box}}body{{margin:0;padding:40px 28px;background:var(--bg);color:var(--fg);
font:15px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}}
.wrap{{max-width:860px;margin:0 auto}}h1{{font-size:22px;margin:0 0 4px}}
.sub{{color:var(--mut);font-size:13px;margin-bottom:28px}}
.meta{{display:flex;gap:28px;flex-wrap:wrap;background:var(--card);border:1px solid var(--line);
border-radius:10px;padding:16px 20px;margin-bottom:24px}}
.meta div span{{display:block;color:var(--mut);font-size:12px}}
.meta div b{{font-weight:600;font-size:15px}}
table{{width:100%;border-collapse:collapse;font-size:14px}}
th{{text-align:left;color:var(--mut);font-weight:500;font-size:12px;padding:8px 10px;
border-bottom:1px solid var(--line)}}
td{{padding:9px 10px;border-bottom:1px solid var(--line)}}
.num{{text-align:right;font-variant-numeric:tabular-nums}}
.ok{{color:var(--ok)}}.bad{{color:var(--bad)}}
.foot{{color:var(--mut);font-size:12px;margin-top:22px;line-height:1.7}}
.empty{{background:var(--card);border:1px solid var(--line);border-radius:10px;
padding:18px 20px;color:var(--mut);margin:0 0 20px}}
</style></head><body><div class="wrap">
<h1>录音导入报告</h1>
<div class="sub">{html.escape(device.get('time',''))}</div>
<div class="meta">
<div><span>设备</span><b>{html.escape(device.get('name','-'))}</b></div>
<div><span>固件</span><b>{html.escape(device.get('fw','-'))}</b></div>
<div><span>电量</span><b>{html.escape(device.get('batt','-'))}</b></div>
<div><span>录音增益</span><b>{html.escape(device.get('gain','-'))}</b></div>
<div><span>本次导入</span><b>{total_ok} / {len(rows)}</b></div>
</div>
{note}
<table><thead><tr><th>文件</th><th class="num">时长</th><th class="num">体积</th>
<th class="num">速率</th><th>状态</th><th>深脑</th></tr></thead><tbody>{body}</tbody></table>
<p class="foot">音频已封装为 Ogg/Opus（<code>{html.escape(str(DEST))}</code>），
设备裸包留档在「原始包」。<br>设备内文件未做任何删除。</p>
</div></body></html>""", encoding="utf-8")


def cleanup_config() -> tuple[bool, int]:
    """从菜单栏的配置里读删除开关。默认关闭。"""
    try:
        cfg = json.loads((OUT / "menubar.json").read_text())
    except Exception:
        cfg = {}
    return bool(cfg.get("deleteAfterSync", False)), int(cfg.get("coolingDays", 3))


async def run_cleanup(rec, sess, manifest: dict, args, entries) -> None:
    """同步完成后清理设备。默认关闭；开了也只删判据全过的。"""
    if args.wipe_verified:
        return await run_wipe(rec, manifest, args)
    enabled, cooling = cleanup_config()
    dry = args.cleanup_dry or not enabled
    if sess is None:
        print("\n清理跳过：没接通深脑，无法确认是否已同步")
        return

    entries, _ = await ble.get_file_list(rec)          # 用最新列表，别用导入前的
    status = await ble.get_record_status(rec)
    current = await ble.get_current_filename(rec)
    decisions = cleanup_mod.plan(entries, manifest, DEST, RAW, sess, cooling,
                                 __import__("datetime").datetime.now(), status, current)

    deletable = [d for d in decisions if d.delete]
    print(f"\n设备清理（{'演示，不真删' if dry else '执行'}）"
          f"  冷静期 {cooling} 天  设备状态 {status}  当前文件 {current or '无'}")
    for d in decisions:
        mark = "删" if d.delete else "留"
        print(f"  [{mark}] {d.name:<24} {d.reason}")
    if not deletable:
        print("  没有满足全部删除条件的文件")
        return
    if dry:
        print(f"  以上 {len(deletable)} 条满足条件；开启「同步后自动清理」才会真删")
        return

    for d in deletable:
        entry = next((e for e in entries if e.name.rstrip(".") == d.name), None)
        if entry is None:
            continue
        ok, note = await ble.delete_one(rec, entry)
        print(f"  {'已删除' if ok else '删除失败'} {d.name}：{note}")
        if ok:
            manifest.setdefault("deleted", {})[d.name] = time.strftime("%Y-%m-%d %H:%M:%S")
    MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2))


async def run_wipe(rec, manifest: dict, args) -> None:
    """显式擦除。只认本地留档完整性，逐个删并重拉列表确认。"""
    entries, _ = await ble.get_file_list(rec)
    status = await ble.get_record_status(rec)
    current = await ble.get_current_filename(rec)
    decisions = cleanup_mod.plan_wipe(entries, DEST, RAW, status, current)
    dry = args.cleanup_dry
    print(f"\n显式擦除（{'演示' if dry else '执行'}）  设备状态 {status}  当前文件 {current or '无'}")
    for d in decisions:
        print(f"  [{'删' if d.delete else '留'}] {d.name:<24} {d.reason}")
    targets = [d for d in decisions if d.delete]
    if not targets or dry:
        print(f"  {len(targets)} 条满足条件" + ("（演示，未删）" if dry else ""))
        return
    for d in targets:
        entry = next((e for e in entries if e.name.rstrip(".") == d.name), None)
        if entry is None:
            continue
        ok, note = await ble.delete_one(rec, entry)
        print(f"  {'已删除' if ok else '删除失败'} {d.name}：{note}")
        if ok:
            manifest.setdefault("deleted", {})[d.name] = time.strftime("%Y-%m-%d %H:%M:%S")
            MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    left, _ = await ble.get_file_list(rec)
    print(f"\n设备剩余 {len(left)} 条" + ("：" + "、".join(e.name.rstrip('.') for e in left) if left else "（已清空）"))


async def upload_pending(sess, manifest: dict, args) -> int:
    """补推：本地有 ogg 但 manifest 里没记录已上传的，逐个推。

    下载和上传解耦——上传失败不必重新过一遍蓝牙。
    """
    if sess is None:
        print("没接通深脑，无法补推。先运行 deepbrain.py login")
        return 1
    done = manifest.setdefault("uploaded", {})
    pending = sorted(f for f in DEST.glob("*.ogg") if f.stem not in done)
    if not pending:
        print(f"没有待推的文件（本地 {len(list(DEST.glob('*.ogg')))} 条，已全部入深脑）")
        return 0
    print(f"待推 {len(pending)} 条\n")
    rows = []
    for i, f in enumerate(pending, 1):
        raw = RAW / f"{f.stem}.opus"
        dur = oggwrap.duration_seconds(raw.stat().st_size) if raw.exists() else 0.0
        print(f"[{i}/{len(pending)}] {f.stem}  {hhmmss(dur)}  {human(f.stat().st_size)}")
        row = {"name": f.stem, "duration": hhmmss(dur), "size": human(f.stat().st_size),
               "speed": "-", "ok": True, "status": "此前已下载", "brain": "-"}
        try:
            up = deepbrain.upload_recording(sess, f, title=f.stem, duration_sec=dur,
                                            on_step=lambda m: print(f"    深脑：{m}", flush=True))
            done[f.stem] = up["sessionId"]
            row["brain"] = "已入深脑"
            print(f"    -> 深脑会话 {up['sessionId']}")
            MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
        except Exception as exc:
            row["brain"] = "上传失败"
            print(f"    ! 失败：{exc}")
        rows.append(row)
    write_report(rows, {"name": "本地补推", "time": time.strftime("%Y-%m-%d %H:%M"),
                        "fw": "-", "batt": "-", "gain": "-"})
    ok = sum(1 for r in rows if r["brain"] == "已入深脑")
    print(f"\n入深脑 {ok}/{len(rows)}")
    notify(f"补推完成 {ok}/{len(rows)}")
    if not args.no_open:
        subprocess.run(["open", str(REPORT)], capture_output=True)
    return 0


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="CB08")
    ap.add_argument("--scan-timeout", type=float, default=8.0)
    ap.add_argument("--all", action="store_true", help="连导过的也重导")
    ap.add_argument("--index", default="", help="只导这些序号，逗号分隔")
    ap.add_argument("--no-open", action="store_true", help="结束后不打开报告")
    ap.add_argument("--no-upload", action="store_true", help="只落盘，不推深脑")
    ap.add_argument("--upload-only", action="store_true",
                    help="不碰蓝牙，只把本地已下好、还没推的 ogg 推给深脑")
    ap.add_argument("--wipe-verified", action="store_true",
                    help="显式擦除：删掉所有本地留档完整的设备文件（不看深脑、不看冷静期）")
    ap.add_argument("--cleanup-dry", action="store_true",
                    help="只演示会删哪些，不真删（无论配置如何都不删）")
    args = ap.parse_args()

    # 登录过就默认推深脑；没登录就只落盘，不打断导入。
    sess = None
    if not args.no_upload:
        try:
            sess = deepbrain.connect()
        except deepbrain.DeepBrainError as exc:
            print(f"深脑未接通（{exc}），本次只落盘")

    DEST.mkdir(exist_ok=True)
    RAW.mkdir(exist_ok=True)
    manifest = load_manifest()

    if args.upload_only:
        return await upload_pending(sess, manifest, args)

    print("扫描中…")
    found = await ble.scan(args.scan_timeout, args.name)
    target = next((f for f in found if args.name.lower() in f.name.lower()), None) \
        or next((f for f in found if f.by_service), None)
    if not target:
        notify("没找到录音笔，确认已开机且未被手机占用")
        print("没找到录音笔。确认已开机、未被手机 App 占用连接。")
        return 1
    print(f"目标 {target.name} rssi={target.rssi}")
    notify(f"已连接 {target.name}，开始读取列表")

    device = {"name": target.name, "time": time.strftime("%Y-%m-%d %H:%M")}
    async with ble.Recorder(target.device) as rec:
        batt = await ble.get_battery(rec)
        device["batt"] = "充电中" if batt == 110 else (f"{batt}%" if batt is not None else "-")
        await rec.send(P.T.CTRL, 10)
        fw = await rec.expect(P.T.CTRL, 11, 3)
        device["fw"] = fw.body.decode("ascii", "replace").strip("\x00") if fw and fw.body else "-"
        await rec.send(P.T.KEY, 25)
        g = await rec.expect(P.T.KEY, 26, 3)
        device["gain"] = {1: "低", 2: "中", 3: "高"}.get(g.body[0], "-") if g and g.body else "-"
        print(f"电量 {device['batt']}  固件 {device['fw']}  增益 {device['gain']}")

        entries, done = await ble.get_file_list(rec)
        if not entries:
            notify("设备里没有文件")
            print("设备内没有文件。")
            return 0
        print(f"列表 {len(entries)} 条{'' if done else '（未收到 2-18，按空闲收尾）'}")

        if args.index:
            want = {int(x) for x in args.index.split(",") if x.strip().isdigit()}
            todo = [e for i, e in enumerate(entries) if i in want]
        elif args.all:
            todo = entries
        else:
            todo = [e for e in entries if key_of(e) not in manifest["imported"]]
        skipped = len(entries) - len(todo)
        if not todo:
            notify(f"没有新录音，{skipped} 条已导过")
            print(f"没有新录音（{skipped} 条此前已导入）。")
            # 没有新录音也要跑清理——这恰恰是最常见的情况
            await run_cleanup(rec, sess, manifest, args, entries)
            device["note"] = f"设备内 {len(entries)} 条录音此前都已导入，本次没有新增。"
            write_report([], device)
            if not args.no_open:              # 双击后必须永远有东西出现
                subprocess.run(["open", str(REPORT)], capture_output=True)
            return 0
        print(f"待导入 {len(todo)} 条，跳过已导入 {skipped} 条\n")

        rows: list[dict] = []
        for i, e in enumerate(todo, 1):
            base = e.name.rstrip(".")
            head = f"[{i}/{len(todo)}] {base}  {hhmmss(e.time)}  {human(e.size)}"
            print(head, flush=True)
            # 交互终端用 \r 原地刷新；重定向到日志文件时改成每 10% 一行，
            # 否则整个进度条会在日志里糊成一大坨。
            tty = sys.stdout.isatty()
            last = [0.0, -1]

            def progress(got: int, expect: int | None) -> None:
                if tty:
                    now = time.monotonic()
                    if now - last[0] < 0.4:
                        return
                    last[0] = now
                    pct = f"{got/expect*100:5.1f}%" if expect else human(got)
                    print(f"\r    {pct}  {human(got)}", end="", flush=True)
                elif expect:
                    step = int(got / expect * 10)
                    if step > last[1]:
                        last[1] = step
                        print(f"    {step*10:3d}%  {human(got)}", flush=True)

            res = await ble.download(rec, e.candidates(), e.size, on_progress=progress)
            if tty:
                print("\r" + " " * 44, end="\r")

            row = {"name": base, "duration": hhmmss(e.time), "size": human(e.size),
                   "speed": f"{res.kbps:.1f} KB/s", "ok": False, "status": "", "brain": "-"}
            if not res.ok:
                row["status"] = f"失败：{P.IMPORT_END_MEANING.get(res.end_code, res.end_code)}"
                print(f"    {row['status']}（试过 {res.tried}）")
                rows.append(row)
                continue

            short = len(res.data) < e.size
            (RAW / f"{base}.opus").write_bytes(res.data)
            if oggwrap.looks_raw(res.data):
                (DEST / f"{base}.ogg").write_bytes(oggwrap.wrap(res.data))
                out_note = f"{base}.ogg"
            else:
                (DEST / res.filename).write_bytes(res.data)
                out_note = res.filename
            row["ok"] = True
            row["status"] = "完成" if not short else f"完成（偏短 {human(e.size-len(res.data))}）"
            row["brain"] = "未接"
            if sess and out_note.endswith(".ogg"):
                try:
                    up = deepbrain.upload_recording(
                        sess, DEST / out_note, title=base,
                        duration_sec=oggwrap.duration_seconds(len(res.data)),
                        on_step=lambda m: print(f"    深脑：{m}", flush=True))
                    row["brain"] = "已入深脑"
                    manifest.setdefault("uploaded", {})[base] = up["sessionId"]
                    print(f"    -> 深脑会话 {up['sessionId']}")
                except Exception as exc:                    # 上传失败不该毁掉已落盘的音频
                    row["brain"] = "上传失败"
                    print(f"    ! 推深脑失败：{exc}")
            row["speed"] = f"{res.kbps:.1f} KB/s"
            manifest["imported"][key_of(e)] = {
                "file": out_note, "bytes": len(res.data),
                "at": time.strftime("%Y-%m-%d %H:%M:%S"),
            }
            print(f"    -> {out_note}  {human(len(res.data))}  {res.kbps:.1f} KB/s"
                  f"{'  续传 %d 次' % res.resumes if res.resumes else ''}")
            rows.append(row)

        MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2))

        await run_cleanup(rec, sess, manifest, args, entries)

        write_report(rows, device)
        ok = sum(1 for r in rows if r["ok"])
        print(f"\n完成 {ok}/{len(rows)}，输出在 {DEST}")
        print(f"解析健康度 {rec.parser_stats}")
        notify(f"导入完成 {ok}/{len(rows)} 条")
        if not args.no_open:
            subprocess.run(["open", str(REPORT)], capture_output=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except KeyboardInterrupt:
        print("\n已中断")
        sys.exit(130)
