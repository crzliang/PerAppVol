#!/usr/bin/env swift
// volctl.swift — macOS 系统音量控制示例（纯公开 CoreAudio API，无需任何权限）
//
// 用法:
//   swift volctl.swift get
//   swift volctl.swift set 50        // 0 - 100
//   swift volctl.swift mute on|off|toggle
//   swift volctl.swift devices
//   swift volctl.swift setout <设备ID|名字子串>   切换默认输出设备
//   swift volctl.swift watch         // 监听音量/静音变化
//
// 编译成二进制: swiftc -O volctl.swift -o volctl

import CoreAudio
import Foundation

// MARK: - FourCharCodes (Swift 里没有 C 的 'volm' 字面量)

@inline(__always) func code(_ s: String) -> AudioObjectPropertySelector {
    var r: UInt32 = 0
    for b in s.utf8 { r = (r << 8) | UInt32(b) }
    return r
}

let kVMVC = code("vmvc")   // kAudioHardwareServiceDeviceProperty_VirtualMainVolume
let kVolm = code("volm")   // kAudioDevicePropertyVolumeScalar
let kMute = code("mute")   // kAudioDevicePropertyMute
let kStreams = code("stm#")

// MARK: - 低层封装

func defaultOutputDevice() -> AudioObjectID {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dev = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                    &addr, 0, nil, &size, &dev) == noErr else {
        fatalError("无法获取默认输出设备")
    }
    return dev
}

func deviceName(_ dev: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let name = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
    defer { name.deallocate() }
    name.initialize(to: nil)
    var size = UInt32(MemoryLayout<CFString?>.size)
    AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, name)
    return (name.pointee as String?) ?? "(unnamed)"
}

func isSettable(_ dev: AudioObjectID, _ addr: UnsafePointer<AudioObjectPropertyAddress>) -> Bool {
    var writable = DarwinBoolean(false)
    return AudioObjectIsPropertySettable(dev, addr, &writable) == noErr && writable.boolValue
}

func deviceHasVolume(_ dev: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    return AudioObjectHasProperty(dev, &addr) && isSettable(dev, &addr)
}

/// 读音量（0.0 - 1.0）。优先虚拟主音量，回退到每个声道。
func getVolume(_ dev: AudioObjectID) -> Float32? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kVMVC,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    var v: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    if AudioObjectHasProperty(dev, &addr),
       AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr {
        return v
    }
    // 回退：读声道 1
    addr.mSelector = kVolm
    addr.mElement = 1
    if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr { return v }
    return nil
}

/// 写音量。优先虚拟主音量，回退到逐声道写。
func setVolume(_ dev: AudioObjectID, _ value: Float32) -> Bool {
    let v = min(max(value, 0), 1)
    var addr = AudioObjectPropertyAddress(
        mSelector: kVMVC,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    let size = UInt32(MemoryLayout<Float32>.size)
    var val = v
    if AudioObjectHasProperty(dev, &addr),
       isSettable(dev, &addr),
       AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &val) == noErr {
        return true
    }
    // 回退：逐声道写
    addr.mSelector = kVolm
    var ok = false
    for ch: AudioObjectPropertyElement in [1, 2] {
        addr.mElement = ch
        if AudioObjectHasProperty(dev, &addr), isSettable(dev, &addr) {
            var v2 = v
            if AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &v2) == noErr { ok = true }
        }
    }
    return ok
}

func getMute(_ dev: AudioObjectID) -> Bool? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    if AudioObjectHasProperty(dev, &addr),
       AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr { return v != 0 }
    addr.mElement = 1
    if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr { return v != 0 }
    return nil
}

func setMute(_ dev: AudioObjectID, _ muted: Bool) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    var val: UInt32 = muted ? 1 : 0
    let size = UInt32(MemoryLayout<UInt32>.size)
    if AudioObjectHasProperty(dev, &addr),
       isSettable(dev, &addr),
       AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &val) == noErr { return true }
    var ok = false
    for ch: AudioObjectPropertyElement in [1, 2] {
        addr.mElement = ch
        if AudioObjectHasProperty(dev, &addr), isSettable(dev, &addr) {
            var v2: UInt32 = muted ? 1 : 0
            if AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &v2) == noErr { ok = true }
        }
    }
    return ok
}

func allOutputDevices() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    let n = Int(size) / MemoryLayout<AudioObjectID>.size
    var devs = [AudioObjectID](repeating: 0, count: n)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devs) == noErr else { return [] }
    return devs.filter { d in
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyDirection,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var s: UInt32 = 0
        // kAudioDevicePropertyStreams 有输出流即视为输出设备
        a.mSelector = kAudioDevicePropertyStreams
        a.mScope = kAudioDevicePropertyScopeOutput
        return AudioObjectGetPropertyDataSize(d, &a, 0, nil, &s) == noErr && s > 0
    }
}

// MARK: - CLI

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "get"
let dev = defaultOutputDevice()

switch cmd {
case "get":
    if let v = getVolume(dev) {
        let mute = getMute(dev) ?? false
        print(String(format: "%.0f%%%@", v * 100, mute ? "  [muted]" : ""))
    } else {
        print("当前设备不支持音量控制: \(deviceName(dev))")
        exit(1)
    }

case "set":
    guard args.count > 2, let pct = Float32(args[2]) else {
        print("用法: volctl set <0-100>"); exit(2)
    }
    precondition(setVolume(dev, pct / 100), "写入失败：设备不支持")
    print(String(format: "已设置 %.0f%%", pct))

case "mute":
    let mode = args.count > 2 ? args[2] : "toggle"
    let cur = getMute(dev) ?? false
    let target = mode == "toggle" ? !cur : (mode == "on")
    precondition(setMute(dev, target), "写入失败：设备不支持静音")
    print(target ? "已静音" : "已取消静音")

case "setout":
    guard args.count > 2 else { print("用法: volctl setout <设备ID|名字子串>"); exit(2) }
    let key = args[2].lowercased()
    guard let t = allOutputDevices().first(where: {
        String($0) == args[2] || deviceName($0).lowercased().contains(key)
    }) else {
        print("找不到输出设备 \(args[2])。可用：")
        for d in allOutputDevices() { print("  \(d)\t\(deviceName(d))") }
        exit(1)
    }
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dev = t
    let size = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                        &addr, 0, nil, size, &dev)
    if st != noErr {
        print("切换失败: \(st)"); exit(1)
    }
    print("默认输出设备已切换到 \(deviceName(t))")

case "devices":
    for d in allOutputDevices() {
        let mark = d == dev ? " (default)" : ""
        let canVol = deviceHasVolume(d, selector: kVMVC) || deviceHasVolume(d, selector: kVolm)
        print("\(d)\t\(deviceName(d))\(mark)\t\(canVol ? "volume=yes" : "volume=no")")
    }

case "watch":
    print("监听中（Ctrl-C 退出）...")
    let queue = DispatchQueue(label: "coreaudio.watch")
    let cb: AudioObjectPropertyListenerBlock = { _, _ in
        let v = getVolume(dev).map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"
        let m = getMute(dev).map { $0 ? "muted" : "unmuted" } ?? "n/a"
        print("[\(Date())] volume=\(v) \(m)")
    }
    var a1 = AudioObjectPropertyAddress(
        mSelector: kVMVC, mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    var a2 = AudioObjectPropertyAddress(
        mSelector: kMute, mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectAddPropertyListenerBlock(dev, &a1, queue, cb)
    AudioObjectAddPropertyListenerBlock(dev, &a2, queue, cb)
    dispatchMain()

default:
    print("用法: swift volctl.swift get|set <0-100>|mute on|off|toggle|devices|watch")
    exit(2)
}
