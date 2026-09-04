"""设备端清理：只删「确认已进深脑」的录音，其余一律不动。

删除不可逆，所以判据宁可严。一条录音要被删，必须同时满足下面全部条件；
任何一条拿不准（包括查询失败、超时、解析不出来），一律判为「不删」。

  A. 深脑已 ready ——不是"上传成功"，是 session.status=='ready' 且有 final_transcript_id
  B. 本地有双份留档——原始包/<name>.opus 和 <name>.ogg 都在
  C. 字节完整 ——本地裸包字节数 == 设备列表 size，且能被 40 整除
  D. 时长吻合 ——裸包算出的时长与列表 time 相差不超过 2 秒
  E. 过了冷静期——从文件名解析的录制时间距今 >= coolingDays 天
  F. 设备不在录音——整机状态必须是「未录音」，且不是设备当前文件

另外两条硬规矩：
  * 只用 2-8 逐个删，每删一个重拉列表确认消失；永不使用 2-9 删除全部。
  * 深脑 30 天后会清掉原始音频（隐私承诺），所以长期归档实际靠本机「导入/原始包」。
    这就是条件 B 不能省的原因。
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

import deepbrain
import oggwrap

NAME_TIME = re.compile(r"(\d{8})-(\d{6})")
DURATION_TOLERANCE_SEC = 2
# 文件名时间戳的可信下限。设备掉电后 RTC 归零会造出 note20000101-xxxxxx，
# 被算成「录于 9000 多天前」，冷静期直接被绕过、一同步完就可删。
# 这是唯一一条能真正导致误删的洞。
EARLIEST_PLAUSIBLE = datetime(2020, 1, 1)


@dataclass
class Decision:
    name: str
    delete: bool
    reason: str


def recorded_at(name: str) -> datetime | None:
    m = NAME_TIME.search(name)
    if not m:
        return None
    try:
        return datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S")
    except ValueError:
        return None


def judge(entry, manifest: dict, dest: Path, raw_dir: Path, sess,
          cooling_days: int, now: datetime,
          device_current: str | None, session_cache: dict) -> Decision:
    base = entry.name.rstrip(".")

    # F-1 设备当前文件：正在录或刚录完的那条，绝不碰
    if device_current and base and base in device_current:
        return Decision(base, False, "是设备当前文件")

    # A 深脑已 ready
    session_id = (manifest.get("uploaded") or {}).get(base)
    if not session_id:
        return Decision(base, False, "没同步过深脑")
    state = session_cache.get(session_id)
    if state is None:
        try:
            status, body = deepbrain._request(
                "GET", f"{deepbrain.API}/api/recordings/{session_id}", headers=sess.headers)
            state = json.loads(body)["session"] if status == 200 else {}
        except Exception as exc:
            return Decision(base, False, f"查深脑失败：{str(exc)[:40]}")
        session_cache[session_id] = state
    if state.get("status") != "ready":
        return Decision(base, False, f"深脑状态是 {state.get('status') or '未知'}，不是 ready")
    if not state.get("final_transcript_id"):
        return Decision(base, False, "深脑没有转写结果")

    # B 本地双份留档
    raw_path, ogg_path = raw_dir / f"{base}.opus", dest / f"{base}.ogg"
    if not raw_path.exists() or not ogg_path.exists():
        return Decision(base, False, "本地留档不全")
    # ogg 光存在不算数：封装中途崩掉会留下 0 字节文件，那时「双份留档」是假的
    if ogg_path.read_bytes()[:4] != b"OggS":
        return Decision(base, False, "ogg 留档损坏（不是 OggS 开头）")

    # C 字节完整
    raw_size = raw_path.stat().st_size
    if raw_size != entry.size:
        return Decision(base, False, f"字节数对不上（本地 {raw_size} / 设备 {entry.size}）")
    if raw_size % oggwrap.PACKET_LEN != 0:
        return Decision(base, False, "裸包长度不是 40 的整数倍")

    # D 时长吻合
    local_sec = oggwrap.duration_seconds(raw_size)
    if abs(local_sec - entry.time) > DURATION_TOLERANCE_SEC:
        return Decision(base, False, f"时长对不上（本地 {local_sec:.1f}s / 设备 {entry.time}s）")

    # E 冷静期
    made = recorded_at(base)
    if made is None:
        return Decision(base, False, "文件名里解析不出录制时间")
    if not (EARLIEST_PLAUSIBLE <= made <= now + timedelta(days=1)):
        return Decision(base, False, "文件名时间戳不可信（设备 RTC 可能没对时），不删")
    age = now - made
    if age < timedelta(days=cooling_days):
        left = timedelta(days=cooling_days) - age
        return Decision(base, False, f"还在冷静期（还差 {left.days} 天 {left.seconds//3600} 小时）")

    return Decision(base, True, f"已入深脑并转写完成，本地留档完整，录于 {age.days} 天前")


def judge_wipe(entry, dest: Path, raw_dir: Path) -> Decision:
    """显式擦除模式的判据：只看「本地留档是否完整」，不看深脑、不看冷静期。

    用于「清空设备便于测试」这种明确诉求。**只能由 --wipe-verified 显式触发，
    永远不会被自动同步流程调用。** 本地留档不完整的照样不删。
    """
    base = entry.name.rstrip(".")
    raw_path, ogg_path = raw_dir / f"{base}.opus", dest / f"{base}.ogg"
    if not raw_path.exists() or not ogg_path.exists():
        return Decision(base, False, "本地留档不全，不删")
    if ogg_path.read_bytes()[:4] != b"OggS":
        return Decision(base, False, "ogg 留档损坏（不是 OggS 开头），不删")
    raw_size = raw_path.stat().st_size
    if raw_size != entry.size:
        return Decision(base, False, f"字节数对不上（本地 {raw_size} / 设备 {entry.size}）")
    if raw_size % oggwrap.PACKET_LEN != 0:
        return Decision(base, False, "裸包长度不是 40 的整数倍")
    local_sec = oggwrap.duration_seconds(raw_size)
    if abs(local_sec - entry.time) > DURATION_TOLERANCE_SEC:
        return Decision(base, False, f"时长对不上（本地 {local_sec:.1f}s / 设备 {entry.time}s）")
    return Decision(base, True, f"本地留档完整（{raw_size}B / {local_sec:.1f}s）")


def plan_wipe(entries, dest: Path, raw_dir: Path,
              record_status: int | None, device_current: str | None) -> list[Decision]:
    if record_status != 2:
        label = {1: "录音中", 3: "已暂停", None: "状态未知"}.get(record_status, f"状态 {record_status}")
        return [Decision(e.name.rstrip("."), False, f"设备{label}，不删任何文件") for e in entries]
    out = []
    for e in entries:
        base = e.name.rstrip(".")
        if device_current and base and base in device_current:
            out.append(Decision(base, False, "是设备当前文件"))
        else:
            out.append(judge_wipe(e, dest, raw_dir))
    return out


def plan(entries, manifest: dict, dest: Path, raw_dir: Path, sess,
         cooling_days: int, now: datetime, record_status: int | None,
         device_current: str | None) -> list[Decision]:
    """返回逐条判定。整机在录音时直接全部否决。"""
    if record_status != 2:                      # 2=未录音；None/1/3 都算不安全
        label = {1: "录音中", 3: "已暂停", None: "状态未知"}.get(record_status, f"状态 {record_status}")
        return [Decision(e.name.rstrip("."), False, f"设备{label}，本轮不删任何文件") for e in entries]
    cache: dict = {}
    return [judge(e, manifest, dest, raw_dir, sess, cooling_days, now, device_current, cache)
            for e in entries]
