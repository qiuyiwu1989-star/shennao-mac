#!/usr/bin/env bash
# 把 LuyinbiApp 包成一个能双击打开、权限申请不会崩的本地 .app。
#
# **不需要签名公证。** 这个 .app 只在本机跑，从来不离开这台机器——
# Developer ID + notarize 那一整套是给「要分发给别人」的场景用的
# （见 scripts/release-macos-beta.sh，那是给 apps/macos/DeepBrainRecorder
# 准备的，跟这个是两个不同的 App）。这里只需要 ad-hoc 签名：
# `codesign -s -`，够让 TCC 认出这是「同一个稳定身份」，不够也不需要
# 给别人验证「这是谁发布的」。
#
# **为什么裸 swift run/build 不行。** SwiftPM 的 executableTarget 只产出
# 一个裸 Mach-O 二进制，没有 Info.plist、没有 CFBundleIdentifier。
# 2026-09-02 实测：这种进程一碰 UNUserNotificationCenter 就抛不可捕获的
# Objective-C 异常直接崩溃；一碰蓝牙（CoreBluetooth）会被 TCC 判定
# 「访问隐私数据却没有权限说明」直接强杀（SIGABRT，日志在
# ~/Library/Logs/DiagnosticReports/，不是 stderr——排查这类问题
# 别在终端里找日志，去翻 .ips 文件）。真正的 .app bundle 把
# Info.plist 里已经写好的 NSBluetoothAlwaysUsageDescription /
# NSMicrophoneUsageDescription 带上，这两类崩溃才会消失。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="深脑"
BUNDLE_ID="com.qiuyiwu.luyinbi.app"
OUT="$ROOT/.build/local-app/$APP_NAME.app"

echo "构建 release..."
cd "$ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN_DIR/LuyinbiApp" "$OUT/Contents/MacOS/LuyinbiApp"
cp "$ROOT/Sources/LuyinbiApp/Info.plist" "$OUT/Contents/Info.plist"

# 图标：源头是 icon/make-icon.swift 矢量绘制，不入仓的是它的派生物
# （iconset/icns，见仓库根 .gitignore 的注释）。每次打包都从源头重出一份，
# 而不是指望某次手工生成的 .icns 一直躺在磁盘上——那样换一台机器
# 或者清过 icon/ 目录，图标就悄悄消失了，Info.plist 却还在喊 CFBundleIconFile。
echo "生成图标..."
ICONDIR="$ROOT/icon"
swiftc "$ICONDIR/make-icon.swift" -o "$ROOT/.build/make-icon"
"$ROOT/.build/make-icon" "$ICONDIR" >/dev/null
iconutil -c icns "$ICONDIR/深脑.iconset" -o "$ICONDIR/深脑.icns"
cp "$ICONDIR/深脑.icns" "$OUT/Contents/Resources/深脑.icns"

# ad-hoc 签名：够让系统认出这是「同一个身份」（TCC 权限记录、
# UNUserNotificationCenter 都靠 bundle identity 找配置），
# 不需要 Developer ID——那是给「发给别人」用的。
codesign --force --deep -s - "$OUT"

echo "打包完成：$OUT"
echo "双击打开，或：open \"$OUT\""
