# 蓝牙录音笔接入 + Mac 本地端

CB08 蓝牙录音笔 → 本机 → 深脑 的完整链路，以及 Mac 上的采集/管理客户端。

## 目录

- `Sources/LuyinbiCore/` — 引擎层：蓝牙协议、同步、音频、深脑客户端
- `Sources/LuyinbiApp/` — 界面层：内容库 / 设备 / 录音 三块
- `Sources/luyinbi-cli/` — 命令行，用来单独验链路的某一环
- `Sources/*SelfTest/` — 自检，不依赖蓝牙硬件（真机蓝牙在开发机上受 TCC 限制跑不起来）
- `python-importer/` — 最早的 Python 版，仍可用，与 Swift 版共用清单与幂等键
- `icon/make-icon.swift` — App 图标，矢量绘制后导出整套尺寸，不依赖设计工具
- `scripts/build-local-app.sh` — 打成能双击打开的 `.app`（ad-hoc 签名，仅本机/内部分发用）

## 链路

设备广播 → 连接 → 列文件 → 分片下载裸 opus（40 B = 20 ms）→ 封 ogg → 落盘记账
→ 六步上传深脑（建会话 / 票据 / PUT COS / 分片完成 / stop / finalize）
→ 服务端 ffmpeg 归一化 + 腾讯 ASR → 转写 → 自动排分析

## 几条踩过的硬规矩

- **下载完成 ≠ 设备说完成。** 收到的字节必须与设备报的大小一字不差、且能被 40 整除。
  曾经只认 `endCode == 0`，结果一条三小时会议只收到三分之一就被当成完整录音推走。
- **录制期间不压缩。** 实测 SIGKILL：裸 PCM 救回 638 秒，AAC 读出 0.00 秒。
- **设备有 3 小时上限**，到点自动断开、隔 1 秒开下一条。同一场会因此被切开，
  上传前按「前一条顶满上限 + 空档 ≤5 秒」两条同时成立才合并。
- **深脑是国内服务器，不走系统代理。** 跟随代理 2320ms，绕开 123ms，大文件分片直接断。
- **真实录音时刻在文件名里。** 不传 startedAt 的话深脑记的是上传时刻。

## 跑测试

```bash
swift build
for t in CoreSelfTest CleanupSelfTest AuditSelfTest VoiceSelfTest; do swift run -q $t; done
```
