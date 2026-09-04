#!/usr/bin/env python3
"""菜单栏常驻同步器。

只做编排：定时唤起 pull.py 子进程去干活，自己不碰蓝牙。
这样避免 rumps 的 NSApplication 运行循环和 bleak 的 CoreBluetooth 队列打架，
子进程也天然继承本 .app 的 TCC 身份（蓝牙权限）。

不实现任何删除命令。设备上的录音一律保留。
"""
from __future__ import annotations

import json
import subprocess
import threading
import time
from pathlib import Path

import rumps

# 用运行时策略隐藏 Dock 图标，而不是 Info.plist 的 LSUIElement——
# 实测 LSUIElement=true 会让 LaunchServices 直接拒绝启动（open 报 -600）。
try:
    from AppKit import NSApplication, NSApplicationActivationPolicyAccessory
    NSApplication.sharedApplication().setActivationPolicy_(NSApplicationActivationPolicyAccessory)
except Exception:
    pass

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
DEST = ROOT / "导入"
OUT = ROOT / "out"
STATE = OUT / "menubar.json"
PY = Path.home() / ".venvs/luyinbi/bin/python"
AGENT = Path.home() / "Library/LaunchAgents/com.qiuyiwu.luyinbi.sync.plist"
APP = Path.home() / "Applications/录音笔导入器.app"

IDLE_TITLE = "录"
BUSY_TITLE = "录·"
DEFAULT_INTERVAL_MIN = 10


def load_state() -> dict:
    try:
        return json.loads(STATE.read_text())
    except Exception:
        return {"auto": True, "intervalMin": DEFAULT_INTERVAL_MIN, "lastRun": None,
                "lastResult": "尚未同步", "deleteAfterSync": False, "coolingDays": 3}


def save_state(s: dict) -> None:
    OUT.mkdir(exist_ok=True)
    STATE.write_text(json.dumps(s, ensure_ascii=False, indent=2))


def summarize(output: str) -> tuple[str, bool]:
    """把 pull.py 的输出压成一行人话。返回 (摘要, 是否有新东西)。"""
    if "没有新录音" in output:
        return "没有新录音", False
    if "没找到录音笔" in output:
        return "没找到录音笔", False
    done = [l for l in output.splitlines() if l.startswith("完成 ")]
    brain = output.count("-> 深脑会话")
    failed = output.count("! 推深脑失败")
    if done:
        n = done[-1].replace("完成 ", "").split("，")[0]
        parts = [f"导入 {n}"]
        if brain:
            parts.append(f"入深脑 {brain}")
        if failed:
            parts.append(f"推送失败 {failed}")
        return "，".join(parts), True
    return "本次没有结果", False


class Importer(rumps.App):
    def __init__(self) -> None:
        super().__init__(IDLE_TITLE, quit_button=None)
        self.state = load_state()
        self.busy = False

        self.item_status = rumps.MenuItem(f"状态：{self.state.get('lastResult', '尚未同步')}")
        self.item_status.set_callback(None)                 # 只读行
        self.item_last = rumps.MenuItem("上次同步：从未")
        self.item_last.set_callback(None)
        self.item_auto = rumps.MenuItem("自动同步", callback=self.toggle_auto)
        self.item_auto.state = bool(self.state.get("auto", True))
        self.item_clean = rumps.MenuItem("同步后自动清理设备", callback=self.toggle_clean)
        self.item_clean.state = bool(self.state.get("deleteAfterSync", False))
        self.item_cooling = rumps.MenuItem(
            f"冷静期：{self.state.get('coolingDays', 3)} 天", callback=self.set_cooling)
        self.item_login = rumps.MenuItem("自启动（开机后常驻）", callback=self.toggle_login)
        self.item_login.state = AGENT.exists()

        self.menu = [
            self.item_status,
            self.item_last,
            None,
            rumps.MenuItem("立即同步", callback=self.sync_now),
            self.item_auto,
            rumps.MenuItem(f"同步间隔：{self.state.get('intervalMin', DEFAULT_INTERVAL_MIN)} 分钟",
                           callback=self.set_interval),
            None,
            rumps.MenuItem("打开导入文件夹", callback=lambda _: subprocess.run(["open", str(DEST)])),
            rumps.MenuItem("打开深脑", callback=lambda _: subprocess.run(
                ["open", "https://shennao.zaowuyun.com"])),
            rumps.MenuItem("查看最近日志", callback=self.open_log),
            None,
            self.item_clean,
            self.item_cooling,
            None,
            self.item_login,
            rumps.MenuItem("退出", callback=rumps.quit_application),
        ]
        self.refresh_last()
        self.timer = rumps.Timer(self.on_tick, 60)
        self.timer.start()
        self._next_due = time.time() + 20          # 启动 20 秒后先跑一次

    # --- 界面 ---
    def refresh_last(self) -> None:
        ts = self.state.get("lastRun")
        self.item_last.title = f"上次同步：{ts}" if ts else "上次同步：从未"
        self.item_status.title = f"状态：{self.state.get('lastResult', '尚未同步')}"

    def open_log(self, _) -> None:
        log = OUT / "导入日志-最近一次.txt"
        subprocess.run(["open", "-a", "TextEdit", str(log)] if log.exists()
                       else ["open", str(OUT)])

    def toggle_auto(self, sender) -> None:
        sender.state = not sender.state
        self.state["auto"] = bool(sender.state)
        save_state(self.state)

    def set_interval(self, sender) -> None:
        w = rumps.Window("多少分钟同步一次？", "同步间隔",
                         default_text=str(self.state.get("intervalMin", DEFAULT_INTERVAL_MIN)),
                         ok="确定", cancel="取消")
        r = w.run()
        if not r.clicked:
            return
        try:
            minutes = max(1, min(720, int(r.text.strip())))
        except ValueError:
            rumps.alert("请输入 1 到 720 之间的整数")
            return
        self.state["intervalMin"] = minutes
        save_state(self.state)
        sender.title = f"同步间隔：{minutes} 分钟"

    def toggle_clean(self, sender) -> None:
        if not sender.state:
            days = self.state.get("coolingDays", 3)
            ok = rumps.alert(
                "开启后会删除录音笔里的文件",
                "只删同时满足这些条件的：已进深脑并转写完成、本地有裸包和 ogg 两份留档、"
                f"字节数和时长都对得上、录制时间超过 {days} 天、且设备当前没在录音。\n\n"
                "任何一条拿不准都不删。删除不可逆。\n\n"
                "另外：深脑 30 天后会清掉原始音频（隐私承诺），"
                "所以长期归档实际靠本机「导入/原始包」文件夹，别把它删了。",
                ok="我明白，开启", cancel="取消")
            if not ok:
                return
        sender.state = not sender.state
        self.state["deleteAfterSync"] = bool(sender.state)
        save_state(self.state)

    def set_cooling(self, sender) -> None:
        w = rumps.Window("录制多少天之后才允许删除？（0 = 同步完立刻可删）", "冷静期",
                         default_text=str(self.state.get("coolingDays", 3)),
                         ok="确定", cancel="取消")
        r = w.run()
        if not r.clicked:
            return
        try:
            days = max(0, min(90, int(r.text.strip())))
        except ValueError:
            rumps.alert("请输入 0 到 90 之间的整数")
            return
        self.state["coolingDays"] = days
        save_state(self.state)
        sender.title = f"冷静期：{days} 天"

    def toggle_login(self, sender) -> None:
        if sender.state:
            subprocess.run(["launchctl", "unload", str(AGENT)], capture_output=True)
            AGENT.unlink(missing_ok=True)
            sender.state = False
            return
        AGENT.parent.mkdir(parents=True, exist_ok=True)
        AGENT.write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.qiuyiwu.luyinbi.sync</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/open</string><string>-a</string><string>{APP}</string>
         <string>--args</string><string>--menubar</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
""")
        subprocess.run(["launchctl", "load", str(AGENT)], capture_output=True)
        sender.state = True

    # --- 干活 ---
    def on_tick(self, _) -> None:
        if self.busy or not self.state.get("auto", True):
            return
        if time.time() >= self._next_due:
            self.run_sync(quiet=True)

    def sync_now(self, _) -> None:
        if self.busy:
            rumps.notification("录音笔导入器", "", "正在同步中，请稍候")
            return
        self.run_sync(quiet=False)

    def run_sync(self, quiet: bool) -> None:
        self.busy = True
        self.title = BUSY_TITLE
        self.item_status.title = "状态：同步中…"
        threading.Thread(target=self._worker, args=(quiet,), daemon=True).start()

    def _worker(self, quiet: bool) -> None:
        try:
            proc = subprocess.run([str(PY), "pull.py", "--no-open"], cwd=str(HERE),
                                  capture_output=True, text=True, timeout=3600)
            output = (proc.stdout or "") + (proc.stderr or "")
        except subprocess.TimeoutExpired:
            output = "同步超时"
        except Exception as exc:
            output = f"同步出错：{exc}"

        summary, changed = summarize(output)
        self.state["lastRun"] = time.strftime("%m-%d %H:%M")
        self.state["lastResult"] = summary
        save_state(self.state)
        self._next_due = time.time() + self.state.get("intervalMin", DEFAULT_INTERVAL_MIN) * 60
        self.busy = False
        self.title = IDLE_TITLE
        self.refresh_last()
        # 自动同步时只在真有新东西才打扰；手动点的一定给回音
        if changed or not quiet:
            rumps.notification("录音笔导入器", "", summary)


if __name__ == "__main__":
    Importer().run()
