#!/usr/bin/env python3
"""删除命令诊断：对同一个文件依次试几种 2-8 参数写法，看设备接受哪一种。

只对最小的那个文件动手，且该文件本地已有完整留档。
"""
from __future__ import annotations
import asyncio, struct, sys, time
import ble, protocol as P


async def try_variant(rec, entry, name: str, params: bytes) -> tuple[bool, str]:
    frame = P.build_frame(P.T.FILE, P.FileCmd.DEL_ONE, params, rec.next_seq())
    print(f"\n  [{name}] params={len(params)}B  {params[:12].hex(' ')}…")
    await rec.send_raw(frame)
    ack = await rec.expect(P.T.FILE, P.FileCmd.DEL_ONE_ACK, 6.0)
    ack_s = "无应答" if ack is None else f"应答 body={ack.body.hex(' ') or '空'}"
    entries, _ = await ble.get_file_list(rec)
    gone = not any(e.raw_name == entry.raw_name and e.size == entry.size for e in entries)
    print(f"       {ack_s}  →  {'文件已消失（成功）' if gone else '文件还在'}")
    return gone, ack_s


async def main() -> int:
    found = await ble.scan(10, "CB08")
    target = next((f for f in found if f.by_service or "cb08" in f.name.lower()), None)
    if not target:
        print("没找到录音笔"); return 1
    async with ble.Recorder(target.device) as rec:
        entries, _ = await ble.get_file_list(rec)
        print(f"列表 {len(entries)} 条")
        st = await ble.get_record_status(rec)
        cur = await ble.get_current_filename(rec)
        print(f"录音状态 {st}（2=未录音）  当前文件 {cur}")
        if st != 2:
            print("设备不在安全状态，中止"); return 2

        e = min(entries, key=lambda x: x.size)
        print(f"\n试验对象: {e.name}  time={e.time} size={e.size}")
        print(f"列表原始 28B: {e.raw_entry.hex(' ')}")

        variants = [
            ("A 原样回放列表 28B", e.raw_entry),
            ("B time/size 小端", struct.pack("<II", e.time, e.size) + e.raw_name),
            ("C 仅文件名 20B", e.raw_name),
            ("D 文件名 24B 补零（同下载请求）",
             (e.name.rstrip(".") + ".opus").encode().ljust(24, b"\x00")),
            ("E 文件名 24B + 前置 offset0（完全照 2-2）",
             struct.pack("<I", 0) + (e.name.rstrip(".") + ".opus").encode().ljust(24, b"\x00")),
        ]
        for label, params in variants:
            gone, _ = await try_variant(rec, e, label, params)
            if gone:
                print(f"\n===> 有效写法：{label}")
                return 0
            await asyncio.sleep(0.4)
        print("\n===> 五种写法设备全部拒绝")
        left, _ = await ble.get_file_list(rec)
        print(f"设备仍有 {len(left)} 条，未丢失任何文件")
    return 3


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
