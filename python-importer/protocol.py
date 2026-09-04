"""CB08 录音笔 BLE 协议层：CRC、帧编解码、流式解析、字段解码。

依据《录音笔 BLE 通讯协议 V1.0》(2026-07-10)。
本层不碰蓝牙，纯字节进字节出，可离线单测。
"""
from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import Iterator

MAGIC = 0x5A
HEADER_LEN = 6

# --- BLE 传输层 UUID ---
def _u16(short: int) -> str:
    return f"0000{short:04x}-0000-1000-8000-00805f9b34fb"

SVC_MAIN = _u16(0xAE20)
CHR_WRITE = _u16(0xAE21)   # App -> Dev, WRITE_WITHOUT_RESPONSE
CHR_NOTIFY = _u16(0xAE22)  # Dev -> App, 控制/音频/列表/文件
CHR_KEY = _u16(0xAE23)     # Dev -> App, 机身按键与录音状态


# --- TYPE / CMD 常量 ---
class T:
    CTRL = 0
    AUDIO = 1
    FILE = 2
    KEY = 3


class KeyCmd:
    """TYPE=3 按键与录音控制"""
    STATUS_REQ = 19
    STATUS_ACK = 20          # 1=录音中 2=未录音 3=暂停
    CUR_NAME_REQ = 23
    CUR_NAME_ACK = 24


class FileCmd:
    LIST_REQ = 0
    LIST_DATA = 1
    IMPORT_REQ = 2
    IMPORT_BEGIN = 3
    IMPORT_DATA = 4
    IMPORT_END = 5
    IMPORT_ABORT = 7
    DEL_ONE = 8          # 危险，v1 不实现
    DEL_ALL = 9          # 危险，v1 不实现
    DEL_ALL_ACK = 10
    ABORT_ACK = 11
    IMPORT_RANGE = 12
    DEL_ONE_ACK = 13
    LIST_DONE = 18


IMPORT_END_MEANING = {
    0: "完成",
    1: "文件不存在",
    2: "offset 过大",
    3: "其他原因停止",
}


# --- CRC-16/XMODEM: poly 0x1021, init 0x0000, 不反转, xorout 0x0000 ---
def crc16_xmodem(data: bytes) -> int:
    crc = 0x0000
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


@dataclass(frozen=True)
class Frame:
    seq: int
    data: bytes

    @property
    def type(self) -> int | None:
        return self.data[0] if self.data else None

    @property
    def cmd(self) -> int | None:
        # DATA 只有一个 TYPE 字节时按 ACK 处理，没有 CMD
        return self.data[1] if len(self.data) >= 2 else None

    @property
    def body(self) -> bytes:
        return self.data[2:]

    def __repr__(self) -> str:
        return f"Frame(seq={self.seq}, {self.type}-{self.cmd}, body={len(self.body)}B)"


def build_frame(type_: int, cmd: int, params: bytes = b"", seq: int = 0) -> bytes:
    """构造完整协议帧。CRC 的输入是 LEN 的两个原始字节 + DATA，不含 MAGIC/SEQ/CRC。"""
    data = bytes([type_, cmd]) + params
    length = struct.pack("<H", len(data))
    crc = crc16_xmodem(length + data)
    return bytes([MAGIC, seq & 0xFF]) + struct.pack("<H", crc) + length + data


class FrameParser:
    """流式帧重组。一个 notify 可能含半帧，也可能含多帧。

    AE22 和 AE23 必须各用一个实例，两路字节交织会毁掉半帧。
    """

    MAX_BUF = 64 * 1024
    # LEN 合理性上限。音频/列表分片远小于此值。
    # 没有这道闸，坏帧后重同步撞上音频数据里的假 0x5A，会读出一个荒唐的 LEN
    # 而永久等数据——二进制码流里 0x5A 必然出现，这不是小概率。
    MAX_DATA_LEN = 8192

    def __init__(self, name: str = "") -> None:
        self.name = name
        self._buf = bytearray()
        self.crc_errors = 0
        self.resyncs = 0

    def feed(self, chunk: bytes) -> Iterator[Frame]:
        self._buf += chunk
        while True:
            # 丢弃 MAGIC 之前的垃圾字节
            if not self._buf:
                return
            if self._buf[0] != MAGIC:
                idx = self._buf.find(bytes([MAGIC]))
                if idx < 0:
                    self._buf.clear()
                    self.resyncs += 1
                    return
                del self._buf[:idx]
                self.resyncs += 1
            if len(self._buf) < HEADER_LEN:
                return
            crc = struct.unpack_from("<H", self._buf, 2)[0]
            length = struct.unpack_from("<H", self._buf, 4)[0]
            if length > self.MAX_DATA_LEN:
                # 不可能是真帧头，多半是数据里的假 0x5A，前进一字节继续找
                self.resyncs += 1
                del self._buf[:1]
                continue
            total = HEADER_LEN + length
            if len(self._buf) < total:
                if len(self._buf) > self.MAX_BUF:
                    self._buf.clear()  # 明显跑飞了，兜底
                return
            data = bytes(self._buf[HEADER_LEN:total])
            if crc16_xmodem(bytes(self._buf[4:6]) + data) != crc:
                # CRC 不过：不能整帧丢，可能是错位到了假 MAGIC 上，只前进一字节重找
                self.crc_errors += 1
                del self._buf[:1]
                continue
            seq = self._buf[1]
            del self._buf[:total]
            yield Frame(seq=seq, data=data)


# --- 文件列表 (2-1)：条目内整数为大端，与帧头的小端相反 ---
NAME_FIELD_LEN = 20
ENTRY_LEN = 28


@dataclass(frozen=True)
class FileEntry:
    time: int          # 录音时长，秒
    size: int          # 设备内压缩体积，Byte
    name: str          # 20B 截断名，扩展名可能不全
    raw_name: bytes
    raw_entry: bytes = b""   # 列表里原样收到的 28B，删除时原封不动发回最保险

    def candidates(self) -> list[str]:
        """列表字段只有 20B，note20260710-162938.opus 会被截成 ...938.
        下载时必须重建完整文件名。长文件优先 .opus，WAV 走 BLE 会慢一个数量级。
        """
        base = self.name.rstrip(".")
        out: list[str] = []
        for ext in (".opus", ".wav"):
            if base.lower().endswith(ext):
                out.append(base)
            else:
                out.append(base + ext)
        out.append(self.name)  # 兜底：列表原始截断名
        seen: set[str] = set()
        return [n for n in out if not (n in seen or seen.add(n))]


def decode_file_list(body: bytes) -> list[FileEntry]:
    """body = count:4B BE + N x 28B。count 是本帧条目数，不是文件总数。"""
    if len(body) < 4:
        raise ValueError(f"文件列表帧过短: {len(body)}B")
    count = struct.unpack_from(">I", body, 0)[0]
    avail = (len(body) - 4) // ENTRY_LEN
    if count > avail:
        count = avail  # 固件声明数与实际字节不符时以实际为准
    entries = []
    for i in range(count):
        off = 4 + i * ENTRY_LEN
        time_, size = struct.unpack_from(">II", body, off)
        raw = body[off + 8: off + 8 + NAME_FIELD_LEN]
        entries.append(FileEntry(
            time=time_, size=size,
            name=raw.split(b"\x00")[0].decode("utf-8", "replace"),
            raw_name=raw,
            raw_entry=bytes(body[off: off + ENTRY_LEN]),
        ))
    return entries


FILENAME_FIELD_LEN = 24


def build_import_req(filename: str, offset: int = 0, seq: int = 0) -> bytes:
    """2-2 请求导入。整帧固定 36B，必须一次 GATT 写入，拆包会返回“文件不存在”。"""
    name = filename.encode("utf-8")
    if len(name) > FILENAME_FIELD_LEN:
        raise ValueError(f"文件名超过 {FILENAME_FIELD_LEN}B: {filename!r}")
    params = struct.pack("<I", offset) + name.ljust(FILENAME_FIELD_LEN, b"\x00")
    frame = build_frame(T.FILE, FileCmd.IMPORT_REQ, params, seq)
    assert len(frame) == 36, f"2-2 帧长必须是 36B，得到 {len(frame)}B"
    return frame


def build_delete_one(filename: str, seq: int = 0) -> bytes:
    """2-8 删除单个文件。**破坏性且不可逆。**

    真机实测：厂商文档说参数是「与文件列表相同的 28B 条目」，**这是错的**。
    设备实际要的是和下载请求 2-2 完全一样的格式：offset:4B LE + filename:24B 补零，
    且文件名必须带完整扩展名。按文档那样发 28B 条目，设备一律回应答码 01 拒绝。
    （2026-08-28 在 CB08 / 固件 V1.0.0 上逐一试过五种写法验证。）

    不提供 2-9（删除全部）的构造函数——批量删除发出去无法挽回，
    且旧固件不回应答，连删没删成功都不知道。
    """
    name = filename.encode("utf-8")
    if len(name) > FILENAME_FIELD_LEN:
        raise ValueError(f"文件名超过 {FILENAME_FIELD_LEN}B: {filename!r}")
    params = struct.pack("<I", 0) + name.ljust(FILENAME_FIELD_LEN, b"\x00")
    return build_frame(T.FILE, FileCmd.DEL_ONE, params, seq)


def build_import_range(filename: str, start: int, end: int, seq: int = 0) -> bytes:
    """2-12 分段导入。长文件靠它分段拉，断了能续。"""
    name = filename.encode("utf-8")
    if len(name) > FILENAME_FIELD_LEN:
        raise ValueError(f"文件名超过 {FILENAME_FIELD_LEN}B: {filename!r}")
    params = struct.pack("<II", start, end) + name.ljust(FILENAME_FIELD_LEN, b"\x00")
    return build_frame(T.FILE, FileCmd.IMPORT_RANGE, params, seq)
