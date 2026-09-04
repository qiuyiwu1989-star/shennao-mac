"""BLE 会话层：扫描、连接、AE22/AE23 双缓存收帧、AE21 整帧单写。

安全约定：本模块不实现 2-8 / 2-9 删除命令。导入验证通过前不删设备内文件。
"""
from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass, field

from bleak import BleakClient, BleakScanner

import protocol as P
from protocol import Frame, FrameParser


@dataclass
class Found:
    device: object
    name: str
    address: str
    rssi: int | None
    by_service: bool


async def scan(timeout: float = 8.0, name_hint: str = "") -> list[Found]:
    """优先按广播的 AE20 服务筛选；部分固件广播里不带服务，再按名字兜底。"""
    seen = await BleakScanner.discover(timeout=timeout, return_adv=True)
    out: list[Found] = []
    for _, (dev, adv) in seen.items():
        uuids = [u.lower() for u in (adv.service_uuids or [])]
        by_svc = P.SVC_MAIN in uuids or any(u.startswith("0000ae20") for u in uuids)
        nm = (adv.local_name or dev.name or "") or "(无名)"
        hit = by_svc or (name_hint and name_hint.lower() in nm.lower())
        if hit or nm != "(无名)":
            out.append(Found(dev, nm, dev.address, adv.rssi, by_svc))
    out.sort(key=lambda f: (not f.by_service, -(f.rssi or -999)))
    return out


class Recorder:
    """一次连接会话。AE22 / AE23 各用独立 FrameParser，字节流不得交织。"""

    def __init__(self, device, verbose: bool = False) -> None:
        self._device = device
        self._client: BleakClient | None = None
        self._seq = 0
        self._verbose = verbose
        self._parsers = {"AE22": FrameParser("AE22"), "AE23": FrameParser("AE23")}
        self.frames: asyncio.Queue[tuple[str, Frame]] = asyncio.Queue()
        self.key_events: list[Frame] = []
        self.mtu: int | None = None
        self.rx_bytes = 0

    async def __aenter__(self) -> "Recorder":
        self._client = BleakClient(self._device, timeout=20)
        await self._client.connect()
        self.mtu = getattr(self._client, "mtu_size", None)
        await self._client.start_notify(P.CHR_NOTIFY, self._on_ae22)
        try:
            await self._client.start_notify(P.CHR_KEY, self._on_ae23)
        except Exception as exc:                      # AE23 缺失不致命
            print(f"  ! AE23 订阅失败（不致命）: {exc}")
        return self

    async def __aexit__(self, *_exc) -> None:
        if self._client and self._client.is_connected:
            try:
                await self._client.stop_notify(P.CHR_NOTIFY)
            except Exception:
                pass
            await self._client.disconnect()

    # --- 收 ---
    def _ingest(self, src: str, data: bytearray) -> None:
        self.rx_bytes += len(data)
        for frame in self._parsers[src].feed(bytes(data)):
            if self._verbose:
                print(f"  RX[{src}] {frame}")
            self.frames.put_nowait((src, frame))

    def _on_ae22(self, _c, data: bytearray) -> None:
        self._ingest("AE22", data)

    def _on_ae23(self, _c, data: bytearray) -> None:
        self._ingest("AE23", data)

    # --- 发 ---
    async def send_raw(self, frame: bytes) -> None:
        assert self._client is not None
        if self._verbose:
            print(f"  TX {len(frame)}B {frame[:8].hex(' ')}...")
        # 整帧一次写入。绝不在应用层分包——2-2 拆包会被设备解析成错误文件名。
        await self._client.write_gatt_char(P.CHR_WRITE, frame, response=False)

    async def send(self, type_: int, cmd: int, params: bytes = b"") -> None:
        self._seq = (self._seq + 1) & 0xFF
        await self.send_raw(P.build_frame(type_, cmd, params, self._seq))

    def next_seq(self) -> int:
        self._seq = (self._seq + 1) & 0xFF
        return self._seq

    # --- 等 ---
    async def expect(self, type_: int, cmd: int, timeout: float = 5.0) -> Frame | None:
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            try:
                _src, frame = await asyncio.wait_for(self.frames.get(), left)
            except asyncio.TimeoutError:
                return None
            if frame.type == type_ and frame.cmd == cmd:
                return frame

    @property
    def parser_stats(self) -> dict:
        return {k: {"crc_errors": v.crc_errors, "resyncs": v.resyncs}
                for k, v in self._parsers.items()}


# --- 高层：电量、文件列表 ---
async def get_battery(rec: Recorder, timeout: float = 5.0) -> int | None:
    await rec.send(P.T.CTRL, 3)
    frame = await rec.expect(P.T.CTRL, 4, timeout)
    return frame.body[0] if frame and frame.body else None


async def get_file_list(rec: Recorder, idle_fallback: float = 1.5,
                        hard_timeout: float = 30.0) -> tuple[list, bool]:
    """累积多帧 2-1，收到 2-18 交付。

    旧固件不发 2-18，退化为“空闲约 1.5 秒即收尾”。返回 (条目, 是否收到 2-18)。
    """
    await rec.send(P.T.FILE, P.FileCmd.LIST_REQ)
    entries: list = []
    got_done = False
    deadline = time.monotonic() + hard_timeout
    last = time.monotonic()
    while time.monotonic() < deadline:
        try:
            _src, frame = await asyncio.wait_for(rec.frames.get(), 0.3)
        except asyncio.TimeoutError:
            if entries and time.monotonic() - last > idle_fallback:
                break                                  # best-effort 收尾
            continue
        if frame.type != P.T.FILE:
            continue
        if frame.cmd == P.FileCmd.LIST_DATA:
            entries += P.decode_file_list(frame.body)
            last = time.monotonic()
        elif frame.cmd == P.FileCmd.LIST_DONE:
            got_done = True
            break
    return entries, got_done


@dataclass
class DownloadResult:
    filename: str
    data: bytes = b""
    end_code: int | None = None
    seconds: float = 0.0
    resumes: int = 0
    tried: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return self.end_code == 0 and len(self.data) > 0

    @property
    def kbps(self) -> float:
        return len(self.data) / 1024 / self.seconds if self.seconds > 0 else 0.0


async def download(rec: Recorder, candidates: list[str], expect_size: int | None = None,
                   idle_timeout: float = 12.0, max_resumes: int = 5,
                   on_progress=None) -> DownloadResult:
    """按候选名依次尝试下载；中途断流用 offset 续传，不换名字。

    关键区分（文档 9 节）：received==0 才换候选名；已经有数据了就只续传，
    换名字会把两个文件的字节拼在一起。
    """
    res = DownloadResult(filename=candidates[0])
    for name in candidates:
        res.tried.append(name)
        res.filename = name
        buf = bytearray()
        started = time.monotonic()
        resumes = 0
        while True:
            await rec.send_raw(P.build_import_req(name, len(buf), rec.next_seq()))
            stalled = False
            last = time.monotonic()
            while True:
                try:
                    _src, frame = await asyncio.wait_for(rec.frames.get(), 0.5)
                except asyncio.TimeoutError:
                    if time.monotonic() - last > idle_timeout:
                        stalled = True
                        break
                    continue
                if frame.type != P.T.FILE:
                    continue
                if frame.cmd == P.FileCmd.IMPORT_BEGIN:
                    last = time.monotonic()
                elif frame.cmd == P.FileCmd.IMPORT_DATA:
                    buf += frame.body
                    last = time.monotonic()
                    if on_progress:
                        on_progress(len(buf), expect_size)
                elif frame.cmd == P.FileCmd.IMPORT_END:
                    res.end_code = frame.body[0] if frame.body else None
                    break
            res.data = bytes(buf)
            res.seconds = time.monotonic() - started
            res.resumes = resumes
            if stalled and buf and resumes < max_resumes:
                resumes += 1
                continue                       # 有数据就续传，绝不换名
            break
        if res.end_code == 0 and buf:
            return res
        if res.end_code == 1 and not buf:
            continue                           # 文件不存在，换下一个候选名
        return res                             # 其余情况（含 code=2/3）交给上层判断
    return res


# --- 录音状态（删除前的安全闸）---
async def get_record_status(rec: Recorder, timeout: float = 4.0) -> int | None:
    """3-19/3-20：1=录音中 2=未录音 3=暂停。取不到返回 None（按最坏情况处理）。"""
    await rec.send(P.T.KEY, P.KeyCmd.STATUS_REQ)
    frame = await rec.expect(P.T.KEY, P.KeyCmd.STATUS_ACK, timeout)
    return frame.body[0] if frame and frame.body else None


async def get_current_filename(rec: Recorder, timeout: float = 4.0) -> str | None:
    """3-23/3-24：设备当前（正在录或最近一次）的文件名。"""
    await rec.send(P.T.KEY, P.KeyCmd.CUR_NAME_REQ)
    frame = await rec.expect(P.T.KEY, P.KeyCmd.CUR_NAME_ACK, timeout)
    if not frame or not frame.body:
        return None
    return frame.body.split(b"\x00")[0].decode("utf-8", "replace") or None


async def delete_one(rec: Recorder, entry, timeout: float = 6.0) -> tuple[bool, str]:
    """删除单个文件，然后重拉列表确认它真的消失了。

    列表里的文件名是 20B 截断的，删除要用重建出的完整名（同下载），
    所以按候选名依次试。以**重拉列表**为准，不以应答为准——旧固件可能不回 2-13。
    返回 (是否确认删除, 说明)。
    """
    notes = []
    for name in entry.candidates():
        await rec.send_raw(P.build_delete_one(name, rec.next_seq()))
        ack = await rec.expect(P.T.FILE, P.FileCmd.DEL_ONE_ACK, timeout)
        code = "无应答" if ack is None else (
            f"应答 {ack.body[0]}" if ack.body else "应答空")
        entries, _ = await get_file_list(rec)
        if not any(e.raw_name == entry.raw_name and e.size == entry.size for e in entries):
            return True, f"{name} → {code}，重拉列表已消失"
        notes.append(f"{name}:{code}")
    return False, "全部候选名都被拒绝（" + "；".join(notes) + "）"
