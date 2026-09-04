"""离线单测：对照协议文档里的两个标准答案，不需要设备。"""
import struct
import sys

from protocol import (
    FrameParser, build_frame, build_import_req, build_import_range,
    crc16_xmodem, decode_file_list, FileEntry, T, FileCmd,
)

ok = fail = 0


def check(name, got, want):
    global ok, fail
    if got == want:
        ok += 1
        print(f"  PASS  {name}")
    else:
        fail += 1
        print(f"  FAIL  {name}\n        得到 {got!r}\n        期望 {want!r}")


print("1. CRC-16/XMODEM 标准检验向量")
check("\"123456789\" -> 0x31C3", hex(crc16_xmodem(b"123456789")), hex(0x31C3))

print("\n2. 文档 7.3 真机成功帧（下载 note20260710-162938.wav）")
DOC_FRAME = bytes.fromhex(
    "5a 03 9e 20 1e 00 02 02 00 00 00 00"
    "6e 6f 74 65 32 30 32 36 30 37 31 30 2d 31 36 32 39 33 38 2e"
    "77 61 76 00".replace(" ", "")
)
built = build_import_req("note20260710-162938.wav", offset=0, seq=3)
check("整帧字节完全一致", built.hex(" "), DOC_FRAME.hex(" "))
check("帧长 36B", len(built), 36)
check("CRC=0x209E", hex(struct.unpack_from("<H", built, 2)[0]), hex(0x209E))
check("LEN=30", struct.unpack_from("<H", built, 4)[0], 30)

print("\n3. 流式解析：在每一个字节位置切开都要能重组")
frames = [
    build_frame(T.CTRL, 4, bytes([87]), seq=1),
    build_frame(T.FILE, FileCmd.IMPORT_DATA, bytes(range(200)), seq=2),
    build_frame(T.FILE, FileCmd.IMPORT_END, bytes([0]), seq=3),
]
stream = b"".join(frames)
bad = []
for cut in range(1, len(stream)):
    p = FrameParser()
    got = list(p.feed(stream[:cut])) + list(p.feed(stream[cut:]))
    if [(f.seq, f.data) for f in got] != [(1, frames[0][6:]), (2, frames[1][6:]), (3, frames[2][6:])]:
        bad.append(cut)
check(f"{len(stream)-1} 个切点全部通过", bad, [])

print("\n4. 一个 notify 含多帧 / 20B 分片喂入")
p = FrameParser()
got = []
for i in range(0, len(stream), 20):
    got += list(p.feed(stream[i:i + 20]))
check("20B 分片喂入得到 3 帧", len(got), 3)
check("末帧是 2-5 code=0", (got[2].type, got[2].cmd, got[2].body), (2, 5, b"\x00"))

print("\n5. CRC 损坏帧不能污染后续帧")
corrupt = bytearray(stream)
corrupt[20] ^= 0xFF  # 第 1 帧占 0..8，第 2 帧占 9..216，打坏第 2 帧的 DATA
p = FrameParser()
got = list(p.feed(bytes(corrupt)))
check("坏帧之前的第 1 帧正常解出", [f.seq for f in got][:1], [1])
check("坏帧被丢弃", 2 in [f.seq for f in got], False)
check("坏帧之后的第 3 帧仍能解出（不卡死）", 3 in [f.seq for f in got], True)
check("CRC 错误被计数", p.crc_errors > 0, True)

print("\n6. 文件列表大端解码（帧头是小端，条目是大端）")
def entry(t, s, n):
    return struct.pack(">II", t, s) + n.encode().ljust(20, b"\x00")
body = struct.pack(">I", 2) + entry(3600, 7_200_000, "note20260710-162938.") \
                            + entry(72, 144_000, "note20260711-090000.")
lst = decode_file_list(body)
check("条目数", len(lst), 2)
check("时长 3600s", lst[0].time, 3600)
check("体积 7.2MB", lst[0].size, 7_200_000)
check("截断名", lst[0].name, "note20260710-162938.")
check("候选名 opus 优先", lst[0].candidates()[0], "note20260710-162938.opus")

print("\n7. 声明 count 大于实际字节时不越界")
check("截到实际条目数", len(decode_file_list(struct.pack(">I", 99) + entry(1, 2, "a"))), 1)

print("\n8. 长度护栏")
try:
    build_import_req("note20260710-162938-toolong.opus")
    check("超长文件名应拒绝", "没报错", "ValueError")
except ValueError:
    check("超长文件名被拒绝", True, True)
check("2-12 分段导入帧长 44B", len(build_import_range("a.opus", 0, 262144)), 6 + 2 + 8 + 24)

print(f"\n{'='*46}\n通过 {ok}，失败 {fail}")
sys.exit(1 if fail else 0)
