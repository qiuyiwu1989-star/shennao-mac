"""把设备吐的裸 OPUS 定长包封成 Ogg/Opus。

CB08 与 QS668 同一种码流：40 字节 = 一个 20ms 帧（config 9，16kHz 宽带）。
Ogg 的 granule 走 48kHz 时钟，所以每包推进 960。
源自项目内 qs668-raw-opus-to-ogg.py，改成可导入模块。
"""
from __future__ import annotations

import struct

PACKET_LEN = 40
FRAME_MS = 20
GRANULE_PER_PACKET = 960          # 20ms @ 48kHz
_CRC_POLY = 0x04C11DB7


def _build_crc_table() -> list[int]:
    table = []
    for value in range(256):
        reg = value << 24
        for _ in range(8):
            reg = ((reg << 1) ^ _CRC_POLY) & 0xFFFFFFFF if reg & 0x80000000 else (reg << 1) & 0xFFFFFFFF
        table.append(reg)
    return table


_CRC_TABLE = _build_crc_table()


def _ogg_crc(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ _CRC_TABLE[((crc >> 24) & 0xFF) ^ byte]
    return crc


def _page(payloads: list[bytes], granule: int, serial: int, seq: int, flags: int) -> bytes:
    laces: list[int] = []
    for payload in payloads:
        remaining = len(payload)
        while remaining >= 255:
            laces.append(255)
            remaining -= 255
        laces.append(remaining)
    header = bytearray(b"OggS" + bytes([0, flags]))
    header += struct.pack("<QIII", granule, serial, seq, 0)
    header += bytes([len(laces)]) + bytes(laces)
    page = header + b"".join(payloads)
    page[22:26] = struct.pack("<I", _ogg_crc(page))
    return bytes(page)


def wrap(raw: bytes, sample_rate: int = 16000, tag: str = "CB08") -> bytes:
    """裸包 -> Ogg/Opus 字节。长度不是 40 的整数倍时截掉尾部残包并照常封装。"""
    usable = len(raw) - (len(raw) % PACKET_LEN)
    packets = [raw[i:i + PACKET_LEN] for i in range(0, usable, PACKET_LEN)]
    if not packets:
        raise ValueError("没有完整的 OPUS 包")

    serial, seq, pages = 0x51533638, 0, []
    head = (b"OpusHead" + bytes([1, 1]) + struct.pack("<H", 312)
            + struct.pack("<I", sample_rate) + struct.pack("<h", 0) + bytes([0]))
    tag_b = tag.encode()
    tags = b"OpusTags" + struct.pack("<I", len(tag_b)) + tag_b + struct.pack("<I", 0)
    pages.append(_page([head], 0, serial, seq, 0x02)); seq += 1
    pages.append(_page([tags], 0, serial, seq, 0x00)); seq += 1

    granule = 0
    for start in range(0, len(packets), 50):
        group = packets[start:start + 50]
        granule += GRANULE_PER_PACKET * len(group)
        last = start + 50 >= len(packets)
        pages.append(_page(group, granule, serial, seq, 0x04 if last else 0x00))
        seq += 1
    return b"".join(pages)


def duration_seconds(raw_len: int) -> float:
    return raw_len // PACKET_LEN * FRAME_MS / 1000


def looks_raw(data: bytes) -> bool:
    return len(data) >= PACKET_LEN and len(data) % PACKET_LEN == 0 and data[:4] != b"OggS"
