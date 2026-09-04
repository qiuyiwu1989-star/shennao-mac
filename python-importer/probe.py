#!/usr/bin/env python3
"""真机体检：一条命令回答“这个方案到底行不行”。

不做任何写入/删除，只读设备。输出一份结论，用来决定后续形态。
    python probe.py                 # 扫描并体检第一个候选设备
    python probe.py --name CB08     # 指定设备名
    python probe.py --no-download   # 只看列表，不测速
"""
from __future__ import annotations

import argparse
import asyncio
import sys
import time
from pathlib import Path

import ble
import protocol as P

OUT = Path(__file__).resolve().parent.parent / "out"


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:,.1f}{unit}" if unit != "B" else f"{int(n)}B"
        n /= 1024
    return ""


def hhmmss(sec: float) -> str:
    sec = int(sec)
    return f"{sec // 3600}:{sec % 3600 // 60:02d}:{sec % 60:02d}" if sec >= 3600 \
        else f"{sec // 60}:{sec % 60:02d}"


def sniff(data: bytes) -> str:
    if data[:4] == b"RIFF" and data[8:12] == b"WAVE":
        return "WAV (RIFF/WAVE)"
    if data[:4] == b"OggS":
        return "Ogg 封装（已含 OpusHead，可直接播）"
    if len(data) % 40 == 0:
        return "疑似裸 OPUS 定长包（40B 对齐，需自行封 Ogg）"
    return f"未知格式，前 16 字节: {data[:16].hex(' ')}"


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="", help="设备名关键字，如 CB08 / QS668")
    ap.add_argument("--scan-timeout", type=float, default=8.0)
    ap.add_argument("--no-download", action="store_true", help="跳过测速")
    ap.add_argument("--verbose", action="store_true", help="打印每一帧")
    args = ap.parse_args()

    print("=" * 60)
    print("步骤 1｜扫描 BLE 设备")
    found = await ble.scan(args.scan_timeout, args.name)
    if not found:
        print("  没扫到任何设备。确认录音笔已开机、未被其他 App/手机占用连接。")
        return 1
    for i, f in enumerate(found[:12]):
        tag = "  <- 广播含 AE20 服务" if f.by_service else ""
        print(f"  [{i}] {f.name:<24} rssi={f.rssi} {f.address}{tag}")
    # 绝不盲连列表里第一个设备——那可能是你的电脑、耳机或别人的手机。
    # 只认两种目标：广播了 AE20 服务的，或名字明确匹配 --name 的。
    target = next((f for f in found if f.by_service), None)
    if target is None and args.name:
        target = next((f for f in found if args.name.lower() in f.name.lower()), None)
    if target is None:
        print("\n  没有任何设备广播 AE20 服务。录音笔没在广播。")
        print("  依次检查：")
        print("    1. 录音笔是否开机（按一下电源/录音键唤醒，多数机型只在唤醒后广播）")
        print("    2. 是否仍被手机或原厂 App 占着连接（BLE 同一时间只能连一个主机）")
        print("    3. 距离是否太远")
        print("  确认名字不叫 CB08 的话，用 --name 指定，例如：--name 你的设备名")
        return 1
    print(f"\n  目标: {target.name} ({target.address})"
          f"{'' if target.by_service else '  （按名字匹配，未广播 AE20）'}")

    print("\n" + "=" * 60)
    print("步骤 2｜连接、协商 MTU、订阅通知")
    async with ble.Recorder(target.device, verbose=args.verbose) as rec:
        print(f"  已连接。ATT_MTU = {rec.mtu}"
              f"{'  （常规命令单次载荷 = MTU-3 = %d）' % (rec.mtu - 3) if rec.mtu else ''}")
        if rec.mtu and rec.mtu < 39:
            print("  ! MTU 偏小：2-2 需要一次写入 36B，接近上限，留意写入失败")
        print("  AE22 已订阅（控制/列表/文件/音频）")

        print("\n" + "=" * 60)
        print("步骤 3｜控制命令连通性（同时验证端序与 CRC 已对齐）")
        batt = await ble.get_battery(rec)
        if batt is None:
            print("  ! 电量无应答。端序/CRC 可能没对上，或设备不响应 0-3。")
            print("    解析器统计:", rec.parser_stats)
            return 2
        print(f"  电量 0-4 应答: {batt}" + ("（充电中）" if batt == 110 else "%"))
        print("  -> 帧头小端 + CRC-16/XMODEM 已确认可用")

        for cmd, ack, label, dec in (
            (10, 11, "固件版本", lambda b: b.decode("ascii", "replace").strip("\x00")),
            (1, 2, "容量", lambda b: f"剩余 {int.from_bytes(b[:4],'little'):,} / "
                                    f"总 {int.from_bytes(b[4:8],'little'):,}（单位见固件）"),
        ):
            await rec.send(P.T.CTRL, cmd)
            fr = await rec.expect(P.T.CTRL, ack, 3.0)
            print(f"  {label}: {dec(fr.body) if fr and fr.body else '无应答（可选命令，不致命）'}")

        print("\n" + "=" * 60)
        print("步骤 4｜文件列表")
        t0 = time.monotonic()
        entries, got_done = await ble.get_file_list(rec)
        print(f"  {len(entries)} 条，耗时 {time.monotonic()-t0:.1f}s，"
              f"{'收到 2-18 结束帧' if got_done else '未收到 2-18，靠空闲收尾（旧固件）'}")
        if not entries:
            print("  设备内没有文件，或列表命令不被支持。")
            return 3
        print(f"\n  {'#':<3} {'文件名(20B截断)':<22} {'时长':>8} {'设备内体积':>10} {'BLE估时@8KB/s':>14}")
        for i, e in enumerate(entries[:30]):
            print(f"  {i:<3} {e.name:<22} {hhmmss(e.time):>8} {human(e.size):>10} "
                  f"{hhmmss(e.size/8192):>14}")
        if len(entries) > 30:
            print(f"  ... 另有 {len(entries)-30} 条")
        total = sum(e.size for e in entries)
        print(f"\n  合计 {human(total)}，全量导入 @8KB/s 约需 {hhmmss(total/8192)}")

        if args.no_download:
            return 0

        print("\n" + "=" * 60)
        print("步骤 5｜下载测速（挑最小的文件，只读不删）")
        target_entry = min(entries, key=lambda e: e.size)
        cands = target_entry.candidates()
        print(f"  目标: {target_entry.name}  设备内 {human(target_entry.size)}")
        print(f"  候选名依次尝试: {cands}")

        last_print = [0.0]

        def progress(got: int, expect: int | None) -> None:
            now = time.monotonic()
            if now - last_print[0] < 0.5:
                return
            last_print[0] = now
            pct = f" {got/expect*100:5.1f}%" if expect else ""
            print(f"\r  收到 {human(got)}{pct}", end="", flush=True)

        res = await ble.download(rec, cands, target_entry.size, on_progress=progress)
        print()
        code = P.IMPORT_END_MEANING.get(res.end_code, res.end_code)
        print(f"  结束码 2-5: {res.end_code}（{code}）  实际文件名: {res.filename}")
        print(f"  收到 {human(len(res.data))}，耗时 {res.seconds:.1f}s，"
              f"续传 {res.resumes} 次")
        if not res.ok:
            print("  ! 下载未成功。尝试过的名字:", res.tried)
            print("  解析器统计:", rec.parser_stats)
            return 4

        speed = res.kbps
        OUT.mkdir(exist_ok=True)
        path = OUT / res.filename
        path.write_bytes(res.data)
        print(f"  已写盘: {path}")
        print(f"  内容识别: {sniff(res.data)}")
        if len(res.data) != target_entry.size:
            print(f"  ! 收到字节数 {len(res.data):,} != 列表声明 {target_entry.size:,}"
                  f"（若请求的是 .wav，设备转码后体积本就不同，属正常）")

        print("\n" + "=" * 60)
        print("体检结论")
        print(f"  实测速率        {speed:.1f} KB/s")
        print(f"  1 小时 opus 录音 约 7.2MB → 预计 {hhmmss(7.2*1024/speed)}")
        print(f"  1 小时 wav 录音  约 115MB → 预计 {hhmmss(115*1024/speed)}")
        print(f"  设备内全部文件  {human(total)} → 预计 {hhmmss(total/1024/speed)}")
        print(f"  帧解析健康度    {rec.parser_stats}")
        if speed >= 6:
            print("\n  速率可接受，桌面批量导入方案成立。")
        else:
            print("\n  ! 速率偏低，长录音导入体验会很差。优先确认设备是否支持 USB 存储模式。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except KeyboardInterrupt:
        print("\n已中断")
        sys.exit(130)
