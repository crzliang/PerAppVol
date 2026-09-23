// perappvol.m —— macOS 按 App 单独调音量（阶段 2：混音引擎）
//
// 原理:
//   每个要控制的 App 一个 Process Tap（CATapMuted = 音频被劫走，不再直通硬件）
//   + 一个 "exclude" 全局 tap 兜底（其余所有 App）
//   全部挂进一个【私有聚合设备】的 taps 列表；真实输出设备作为 sub-device 挂在同一个聚合里。
//   于是同一个 IOProc 回调里：inInputData = 每个 App 一路音频，outOutputData = 真实设备输出。
//   逐路乘增益再求和 → 就是 per-app 音量。同一时钟，零漂移。
//
// 编译: clang -fobjc-arc -O2 perappvol.m -o perappvol -framework CoreAudio -framework Foundation
//
// 用法:
//   perappvol demo <bundleID|pid> [秒]          目标 App 音量 0→100→0 扫动，其余 App 保持 100%
//   perappvol run  <id=vol> <id=vol> ... [秒]   静态增益；id 用 ALL 表示"其余全部"
//
// 例:
//   ./perappvol demo com.netease.163music 12
//   ./perappvol run com.netease.163music=0.2 ALL=1.0 10

#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreGraphics/CGWindow.h>
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <libproc.h>
#import <math.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>

#pragma mark - 通用工具

static AudioObjectPropertyAddress A_(AudioObjectPropertySelector s,
                                     AudioObjectPropertyScope sc,
                                     AudioObjectPropertyElement e) {
    AudioObjectPropertyAddress a = { s, sc, e };
    return a;
}

static NSString *strProp(AudioObjectID o, AudioObjectPropertySelector sel,
                         AudioObjectPropertyScope sc, AudioObjectPropertyElement el) {
    AudioObjectPropertyAddress a = A_(sel, sc, el);
    CFStringRef s = NULL;
    UInt32 size = sizeof(s);
    if (AudioObjectGetPropertyData(o, &a, 0, NULL, &size, &s) != noErr || !s) return nil;
    return CFBridgingRelease(s);
}

static uint32_t u32Prop(AudioObjectID o, AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress a = A_(sel, kAudioObjectPropertyScopeGlobal, 0);
    UInt32 v = 0, size = sizeof(v);
    AudioObjectGetPropertyData(o, &a, 0, NULL, &size, &v);
    return v;
}

static NSArray<NSNumber *> *processObjects(void) {
    AudioObjectPropertyAddress a = A_(kAudioHardwarePropertyProcessObjectList,
                                      kAudioObjectPropertyScopeGlobal, 0);
    UInt32 size = 0;
    AudioObjectGetPropertyDataSize((AudioObjectID)kAudioObjectSystemObject, &a, 0, NULL, &size);
    NSMutableArray *out = [NSMutableArray array];
    if (!size) return out;
    AudioObjectID *ids = calloc(size, 1);
    AudioObjectGetPropertyData((AudioObjectID)kAudioObjectSystemObject, &a, 0, NULL, &size, ids);
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) [out addObject:@(ids[i])];
    free(ids);
    return out;
}

static AudioObjectID findProcess(NSString *key) {
    if ([key isEqualToString:@"ALL"]) return kAudioObjectUnknown;
    BOOL byPid = [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[key characterAtIndex:0]];
    pid_t want = (pid_t)key.intValue;
    for (NSNumber *n in processObjects()) {
        AudioObjectID o = n.unsignedIntValue;
        if (byPid) {
            if ((pid_t)u32Prop(o, kAudioProcessPropertyPID) == want) return o;
        } else if ([strProp(o, kAudioProcessPropertyBundleID, kAudioObjectPropertyScopeGlobal, 0)
                    isEqualToString:key]) {
            return o;
        }
    }
    return kAudioObjectUnknown;
}

static AudioObjectID defaultOutputDevice(void) {
    AudioObjectPropertyAddress a = A_(kAudioHardwarePropertyDefaultOutputDevice,
                                      kAudioObjectPropertyScopeGlobal, 0);
    AudioObjectID d = 0;
    UInt32 size = sizeof(d);
    AudioObjectGetPropertyData((AudioObjectID)kAudioObjectSystemObject, &a, 0, NULL, &size, &d);
    return d;
}

#pragma mark - 数据平面（统一处理交错 / 非交错布局）

typedef struct { float *p; UInt32 stride; UInt32 frames; } Plane;

/// bufferList 的通道数（mNumberBuffers==1 时是交错/单声道，否则每 buffer 一个声道）
static UInt32 listChans(const AudioBufferList *bl) {
    if (bl->mNumberBuffers == 1) {
        UInt32 n = bl->mBuffers[0].mNumberChannels;
        return n ? n : 1;
    }
    return bl->mNumberBuffers;
}

/// 取第 c 个声道的数据平面。交错布局 stride=声道数，非交错 stride=1
static Plane planeOfList(const AudioBufferList *bl, UInt32 c) {
    Plane r = { 0, 1, 0 };
    if (bl->mNumberBuffers == 1) {
        AudioBuffer b = bl->mBuffers[0];
        UInt32 nch = b.mNumberChannels ? b.mNumberChannels : 1;
        if (!b.mData || c >= nch) return r;
        r.p = (float *)b.mData + c;
        r.stride = nch;
        r.frames = (b.mDataByteSize / sizeof(float)) / nch;
    } else if (c < bl->mNumberBuffers) {
        AudioBuffer b = bl->mBuffers[c];
        if (!b.mData) return r;
        r.p = (float *)b.mData;
        r.stride = 1;
        r.frames = b.mDataByteSize / sizeof(float);
    }
    return r;
}

/// 把单个 AudioBuffer 当成一个单元素 AudioBufferList 来取平面
static Plane planeOfBuffer(const AudioBuffer *b, UInt32 c) {
    AudioBufferList one = { 1, { *b } };
    return planeOfList(&one, c);
}

static UInt32 bufferChans(const AudioBuffer *b) {
    return b->mNumberChannels ? b->mNumberChannels : 1;
}

#pragma mark - 混音器状态

#define MAX_TAPS 32

typedef struct {
    AudioObjectID tapID;
    float targetGain;   // 0.0 - 1.0
    float curGain;      // 平滑后的当前增益
} TapSlot;

static TapSlot  gSlots[MAX_TAPS];
static NSString *gLabels[MAX_TAPS];   // bundleID / pid / "ALL"
static UInt32   gNSlots = 0;

static UInt32 gInputOrder[MAX_TAPS];  // input stream i -> slot index
static UInt32 gNInputs = 0;

static UInt32 gCalls = 0;
static double gInRMS[MAX_TAPS];
static double gInPeak[MAX_TAPS];   // 峰值保持：短促提示音（0.1s 级）不会被采样漏掉
static double gOutRMS = 0;
static double gOutPeak = 0;
static UInt32 gSeenBuffers = 0;

#pragma mark - 渲染：out = Σ in[i] * gain[i]

static void applyLimiter(AudioBufferList *out);

static void render(const AudioBufferList *inInputData, AudioBufferList *outOutputData) {
    // 1) 清零输出（HAL 不保证已清）
    UInt32 outCh = listChans(outOutputData);
    for (UInt32 c = 0; c < outCh; c++) {
        Plane o = planeOfList(outOutputData, c);
        for (UInt32 k = 0; k < o.frames; k++) o.p[k * o.stride] = 0;
    }

    if (gSeenBuffers == 0) {
        gSeenBuffers = inInputData->mNumberBuffers;
        fprintf(stderr, "[diag] inInputData->mNumberBuffers=%u 期望=%u  outCh=%u outFrames=%u\n",
                inInputData->mNumberBuffers, gNInputs, outCh,
                planeOfList(outOutputData, 0).frames);
        for (UInt32 i = 0; i < inInputData->mNumberBuffers; i++)
            fprintf(stderr, "[diag]   in buf%u ch=%u bytes=%u\n", i,
                    inInputData->mBuffers[i].mNumberChannels, inInputData->mBuffers[i].mDataByteSize);
    }

    // 2) 逐路叠加
    for (UInt32 i = 0; i < gNInputs && i < inInputData->mNumberBuffers; i++) {
        UInt32 slot = gInputOrder[i];
        const AudioBuffer *ib = &inInputData->mBuffers[i];
        UInt32 inCh = bufferChans(ib);

        // 增益线性斜坡（跨整个 buffer），拖滑块时不爆音
        float g0 = gSlots[slot].curGain;
        float g1 = gSlots[slot].targetGain;

        for (UInt32 c = 0; c < outCh; c++) {
            Plane o = planeOfList(outOutputData, c);
            Plane p = planeOfBuffer(ib, c % inCh);
            if (!o.p || !p.p) continue;
            UInt32 n = MIN(o.frames, p.frames);
            for (UInt32 k = 0; k < n; k++) {
                float g = g0 + (g1 - g0) * ((float)k / (float)n);
                o.p[k * o.stride] += p.p[k * p.stride] * g;
            }
            if (c == 0) {   // 只统计一次（取输入原始 RMS，不含增益）
                double acc = 0;
                for (UInt32 k = 0; k < n; k++) acc += (double)p.p[k * p.stride] * p.p[k * p.stride];
                gInRMS[slot] = sqrt(acc / (n ? n : 1));
                gInPeak[slot] = MAX(gInRMS[slot], gInPeak[slot] * 0.994);   // ~2.6s 衰减
            }
        }
        gSlots[slot].curGain = g1;
    }

    // 3) 限幅 + 输出 RMS（报的是限幅后的真实输出）
    applyLimiter(outOutputData);
    double outPow = 0; UInt32 outN = 0;
    for (UInt32 c = 0; c < outCh; c++) {
        Plane o = planeOfList(outOutputData, c);
        for (UInt32 k = 0; k < o.frames; k++) { double v = o.p[k * o.stride]; outPow += v * v; }
        outN += o.frames;
    }
    gOutRMS = outN ? sqrt(outPow / outN) : 0;
    gOutPeak = MAX(gOutRMS, gOutPeak * 0.994);
    gCalls++;
}

#pragma mark - 限幅器（多 App 叠加会过载削顶，实测 OUT RMS 曾到 1.2）

// 链接式峰值限幅器（立体声联动，避免声像漂移）：
//   peak > thresh 时压低整帧增益；快攻击（逐样本几乎瞬间），慢释放（~100ms），
//   完全不碰 thresh 以下的信号 → 无失真。
typedef struct {
    float gain;      // 当前增益（≤1）
    float thresh;    // 阈值
    float attack;    // 攻击系数（越大越快）
    float release;   // 释放系数（越小越慢）
} Limiter;

static Limiter gLimiter = { 1.0f, 0.98f, 0.55f, 0.0002f };
static float   gLimGR = 1.0f;      // 上一帧的增益（用于上报，dB）
static UInt32  gLimActive = 0;     // 限幅器介入过的帧数

static void applyLimiter(AudioBufferList *out) {
    UInt32 nch = MIN(listChans(out), 8);
    Plane ps[8];
    UInt32 frames = 0;
    for (UInt32 c = 0; c < nch; c++) {
        ps[c] = planeOfList(out, c);
        if (ps[c].frames > frames) frames = ps[c].frames;
    }
    BOOL acted = NO;
    for (UInt32 k = 0; k < frames; k++) {
        float peak = 0;
        for (UInt32 c = 0; c < nch; c++) {
            if (!ps[c].p) continue;
            float v = fabsf(ps[c].p[k * ps[c].stride]);
            if (v > peak) peak = v;
        }
        float target = (peak > gLimiter.thresh) ? (gLimiter.thresh / peak) : 1.0f;
        if (target < gLimiter.gain) acted = YES;
        float coef = (target < gLimiter.gain) ? gLimiter.attack : gLimiter.release;
        gLimiter.gain += (target - gLimiter.gain) * coef;
        for (UInt32 c = 0; c < nch; c++) {
            if (!ps[c].p) continue;
            ps[c].p[k * ps[c].stride] *= gLimiter.gain;
        }
    }
    gLimGR = gLimiter.gain;
    if (acted) gLimActive++;
}

#pragma mark - 建 tap

#pragma mark - App 识别

/// 可执行文件路径 -> 最外层的 .app 包
/// 关键：helper 往往是嵌套 .app，例如
///   /Applications/Google Chrome.app/.../Helpers/Google Chrome Helper.app/Contents/MacOS/...
///   /Applications/微信.app/Contents/MacOS/WeChatAppEx.app/...
/// 取【最外层】那个 .app 才是用户眼里的"一个 App"。
static NSString *outerAppPath(NSString *path) {
    NSArray<NSString *> *comps = path.pathComponents;
    NSMutableArray<NSString *> *acc = [NSMutableArray array];
    for (NSString *c in comps) {
        [acc addObject:c];
        if ([c hasSuffix:@".app"]) return [NSString pathWithComponents:acc];
    }
    return nil;
}

/// pid -> 可执行文件真实路径（对 helper / 守护进程都有效）
static NSString *procPathForPid(pid_t pid) {
    char buf[PROC_PIDPATHINFO_MAXSIZE] = { 0 };
    if (proc_pidpath(pid, buf, sizeof(buf)) <= 0) return nil;
    return [NSString stringWithUTF8String:buf];
}

/// 按 App 分组。归组依据优先级：
///   1) NSRunningApplication.bundleURL —— 即 .app 包路径。
///      这才是真正的"一个 App"：微信.app 里同时有 com.tencent.xinWeChat 和
///      com.tencent.flue.WeChatAppEx，Chrome.app 里有 Chrome / Chrome Helper，
///      用 bundleID 归并一定会拆散或漏掉。
///   2) bundle ID + helper 归并（`com.x.y.helper` -> `com.x.y`），给没有 .app 的后台进程用
///   3) 都没有 -> 不算 App（纯 CLI），跳过
/// key 的形态：.app 路径（真 App）/ bundleID / 本地化名（系统进程）
static NSDictionary<NSString *, NSArray<NSNumber *> *> *keyedProcs(void) {
    NSArray<NSNumber *> *objs = processObjects();
    NSMutableSet<NSString *> *allBundles = [NSMutableSet set];
    for (NSNumber *n in objs) {
        NSString *b = strProp(n.unsignedIntValue, kAudioProcessPropertyBundleID,
                              kAudioObjectPropertyScopeGlobal, 0);
        if (b.length) [allBundles addObject:b];
    }
    NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *map = [NSMutableDictionary dictionary];
    for (NSNumber *n in objs) {
        AudioObjectID o = n.unsignedIntValue;
        pid_t pid = (pid_t)u32Prop(o, kAudioProcessPropertyPID);
        NSString *bundleID = strProp(o, kAudioProcessPropertyBundleID,
                                     kAudioObjectPropertyScopeGlobal, 0);
        NSString *key = nil;

        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        // 1) 先用可执行文件路径找最外层 .app —— 覆盖嵌套 helper .app
        NSString *outer = outerAppPath(procPathForPid(pid) ?: app.bundleURL.path);
        if (outer) {
            key = outer;
        } else if (app.bundleIdentifier.length) {
            key = app.bundleIdentifier;
        } else if (app.localizedName.length) {
            key = app.localizedName;
        } else if (bundleID.length) {
            key = bundleID;
            for (NSString *b in allBundles) {        // helper -> 父 bundle
                if (![bundleID hasPrefix:b] || bundleID.length <= b.length) continue;
                if ([bundleID characterAtIndex:b.length] != '.') continue;
                key = b;
                break;
            }
        }
        if (!key) continue;
        NSMutableArray *list = map[key] ?: [NSMutableArray array];
        [list addObject:n];
        map[key] = list;
    }
    return map;
}

/// 系统提示音 / 通知提示音 / 警告音 —— 实测（beep、通知+sound name）都由 systemsoundserverd 混音输出。
/// 它不是 .app，但必须作为一等公民暴露给 UI，否则用户无法单独控制提示音。
/// 关键结论：给 QQ/微信/飞书 调音量管不到它们的【新消息提示音】，那要调这一路。
static NSDictionary<NSString *, NSString *> *specialServiceNames(void) {
    static NSDictionary *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = @{ @"systemsoundserverd": @"系统提示音" }; });
    return d;
}

/// key 是不是真实的 .app（用来在 UI 里过滤掉 com.apple.* 这类系统守护进程）
static BOOL keyIsRealApp(NSString *key) {
    return [key hasSuffix:@".app"] || specialServiceNames()[key] != nil;
}

/// label -> 它涵盖的全部进程对象（含 helper）
static NSArray<NSNumber *> *procsForLabel(NSString *label) {
    NSArray<NSNumber *> *found = keyedProcs()[label];
    if (found) return found;
    NSMutableArray *out = [NSMutableArray array];
    AudioObjectID p = findProcess(label);
    if (p != kAudioObjectUnknown) [out addObject:@(p)];
    return out;
}

/// key -> 显示名。
/// 注意：不能用进程的 localizedName —— helper 进程会显示成 "Lark Helper"。
/// key 是 .app 时应该用这个 .app 自己的 CFBundleDisplayName/Name。
static NSString *displayNameForKey(NSString *key) {
    NSString *svc = specialServiceNames()[key];
    if (svc) return svc;
    if ([key hasSuffix:@".app"]) {
        NSBundle *b = [NSBundle bundleWithPath:key];
        NSString *n = [b objectForInfoDictionaryKey:@"CFBundleDisplayName"]
                   ?: [b objectForInfoDictionaryKey:@"CFBundleName"]
                   ?: [[b bundlePath] lastPathComponent];
        if (n.length) return n;
        NSString *base = [key lastPathComponent];
        return [base substringToIndex:base.length - 4];
    }
    for (NSNumber *n in keyedProcs()[key]) {
        pid_t pid = (pid_t)u32Prop(n.unsignedIntValue, kAudioProcessPropertyPID);
        NSString *nm = [NSRunningApplication runningApplicationWithProcessIdentifier:pid].localizedName;
        if (nm.length) return nm;
    }
    return key;
}

/// 给 ALL 兜底 tap 用：只排除【已被单独控制的】App + 本进程。
/// 这样"其他所有 App"那一路才是真正意义上的"其余全部"。
/// （之前误写成排除"未被控制的"App，导致它们直通硬件 —— 那个滑块等于失效。）
static NSArray<NSNumber *> *catchAllExcludeList(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (UInt32 i = 0; i < gNSlots; i++) {
        if ([gLabels[i] isEqualToString:@"ALL"]) continue;
        [out addObjectsFromArray:procsForLabel(gLabels[i])];
    }
    // 必须把自己排除掉 —— 否则混音器自己的输出会被抓回来，形成自激反馈
    AudioObjectID selfProc = findProcess([NSString stringWithFormat:@"%d", getpid()]);
    if (selfProc != kAudioObjectUnknown) [out addObject:@(selfProc)];
    return out;
}

/// 创建指定槽位的 tap。CATapMuted = 音频被劫走，只从我们的混音器出去（否则会"双份声音"）
static OSStatus createTapAt(UInt32 i) {
    NSString *key = gLabels[i];
    CATapDescription *d;

    if (specialServiceNames()[key]) {
        // 系统服务是【短命进程】：systemsoundserverd 只在播提示音的那一瞬连上 coreaudiod，
        // 安静时就断开 —— 按 object ID 建 tap 会因为"此刻不在进程列表里"而
        // ERR cannot create tap，即使建成了，它重连后拿到新的 object ID 也接不上。
        //
        // 正解：macOS 26 的「按 bundle ID 常驻 tap」——
        //   bundleIDs              用 bundle ID 而非 object ID 圈定进程
        //   processRestoreEnabled  进程退出/重启后系统自动把它恢复到 tap 里
        // 这样 tap 一次建立，长期有效。
        d = [[CATapDescription alloc] initStereoMixdownOfProcesses:@[]];
        d.bundleIDs = @[ key ];                 // key 就是它上报的 bundleID
        d.processRestoreEnabled = YES;
    } else if ([key isEqualToString:@"ALL"]) {
        // 兜底 tap：只覆盖"没被单独控制的"App。排除列表见 catchAllExcludeList()。
        d = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:catchAllExcludeList()];
    } else {
        // 一个 App 可能有多个出声进程（主进程 / QQ Helper / Lark Helper …）——
        // 必须全部放进同一个 tap，否则提示音会漏。
        NSArray<NSNumber *> *procs = procsForLabel(key);
        if (procs.count == 0) {
            fprintf(stderr, "找不到 %s 的音频进程（可用 ./perappvol --list 查看）\n", key.UTF8String);
            return -1;
        }
        d = [[CATapDescription alloc] initStereoMixdownOfProcesses:procs];
    }
    d.name = [NSString stringWithFormat:@"ppv-%@", key];
    d.muteBehavior = CATapMuted;

    AudioObjectID tapID = 0;
    OSStatus s = AudioHardwareCreateProcessTap(d, &tapID);
    if (s != noErr) {
        fprintf(stderr, "创建 tap 失败 (%s): %d —— 多半是 TCC 权限（屏幕与系统音频录制）\n", key.UTF8String, (int)s);
        return s;
    }
    gSlots[i].tapID = tapID;
    return noErr;
}

static OSStatus buildTaps(NSArray<NSString *> *specs) {
    // 1) 解析 "id=vol" 到槽位
    for (NSString *spec in specs) {
        if (gNSlots >= MAX_TAPS) break;
        NSArray<NSString *> *kv = [spec componentsSeparatedByString:@"="];
        NSString *key = kv.firstObject;
        gLabels[gNSlots] = key;
        gSlots[gNSlots].targetGain = kv.count > 1 ? MIN(MAX(kv[1].floatValue, 0), 1) : 1.0f;
        gSlots[gNSlots].curGain = gSlots[gNSlots].targetGain;
        gNSlots++;
    }
    // 2) 逐槽建 tap
    for (UInt32 i = 0; i < gNSlots; i++) {
        if (createTapAt(i) != noErr) return -1;
    }
    return noErr;
}

#pragma mark - 建聚合设备

static OSStatus buildAggregate(AudioObjectID *outAgg, AudioObjectID outDevice) {
    NSMutableArray *taps = [NSMutableArray array];
    NSMutableArray<NSString *> *tapUIDs = [NSMutableArray array];
    for (UInt32 i = 0; i < gNSlots; i++) {
        NSString *uid = strProp(gSlots[i].tapID, kAudioTapPropertyUID, kAudioObjectPropertyScopeGlobal, 0);
        if (!uid) return -1;
        [tapUIDs addObject:uid];
        [taps addObject:@{ @"uid": uid,
                           @"drift": @(kAudioAggregateDriftCompensationHighQuality) }];
    }

    NSString *devUID = strProp(outDevice, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, 0);
    if (!devUID) { fprintf(stderr, "拿不到输出设备 UID\n"); return -1; }

    // 真实输出设备做 sub-device，并作为时钟主设备（同一时钟 → 无漂移、低延迟）
    NSDictionary *comp = @{
        @"name": @"PerAppVolumeMixer",
        @"uid": [NSString stringWithFormat:@"com.mac-sound-control.mixer.%d", getpid()],
        @"private": @(1),
        @"master": devUID,
        @"subdevices": @[ @{ @"uid": devUID } ],
        @"taps": taps,
    };
    OSStatus s = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)comp, outAgg);
    if (s != noErr) { fprintf(stderr, "创建聚合设备失败: %d\n", (int)s); return s; }

    // 建 input stream i -> slot 的映射。
    // kAudioAggregateDevicePropertyFullSubDeviceList 的顺序决定聚合设备各流的顺序
    AudioObjectPropertyAddress a = A_(kAudioAggregateDevicePropertyFullSubDeviceList,
                                      kAudioObjectPropertyScopeGlobal, 0);
    CFArrayRef list = NULL;
    UInt32 size = sizeof(list);
    NSArray *order = nil;
    if (AudioObjectGetPropertyData(*outAgg, &a, 0, NULL, &size, &list) == noErr && list) {
        order = CFBridgingRelease(list);
    }
    fprintf(stderr, "[map] FullSubDeviceList 顺序 = %s\n", order.description.UTF8String);
    fprintf(stderr, "[map] tapUIDs            = %s\n", tapUIDs.description.UTF8String);

    gNInputs = 0;
    for (NSString *uid in order) {
        NSUInteger idx = [tapUIDs indexOfObject:uid];
        if (idx != NSNotFound) gInputOrder[gNInputs++] = (UInt32)idx;
    }
    if (gNInputs != gNSlots) {
        fprintf(stderr, "[map] 只映射到 %u/%u 路，退回创建顺序\n", gNInputs, gNSlots);
        for (UInt32 i = 0; i < gNSlots; i++) gInputOrder[i] = i;
        gNInputs = gNSlots;
    }
    for (UInt32 i = 0; i < gNInputs; i++)
        fprintf(stderr, "[map] input %u <- tap %s\n", i, gLabels[gInputOrder[i]].UTF8String);
    return noErr;
}

#pragma mark - 运行时控制（Unix socket，供 UI/脚本驱动）

// 协议（每行一条，\n 结尾，应答同样按行）：
//   set <label> <0.0-1.0>   设置某路增益   -> OK | ERR <msg>
//   gain <label> <0-100>    同上，单位百分比
//   mute <label> <on|off>
//   get                     -> "<label> <gain>" 多行，最后 "END"
//   stat                    -> cb/out/lim + 每路 in 电平，最后 "END"
//   add <label> [gain]      运行时新增一路 per-app 控制
//   remove <label>          运行时移除
//   list                    -> 所有 HAL 进程（objID pid runningOut bundleID），最后 "END"
//   quit                    -> OK，然后断开

static NSString *addSlot(NSString *key, float gain);
static NSString *removeSlot(NSString *key);
UInt32 procSlotIndex(NSString *label);

static int handleControl(int fd) {
    char buf[512];
    NSMutableData *acc = [NSMutableData data];
    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n <= 0) break;
        [acc appendBytes:buf length:(NSUInteger)n];
        const char *bytes = acc.bytes;
        NSUInteger len = acc.length, start = 0;
        for (NSUInteger i = 0; i < len; i++) {
            if (bytes[i] != '\n') continue;
            NSString *line = [[NSString alloc] initWithBytes:bytes + start
                                                      length:i - start
                                                    encoding:NSUTF8StringEncoding];
            start = i + 1;

            // 协议：`cmd [label（可含空格）] [数字]`
            // label 不能按空格硬切 —— "/Applications/Google Chrome.app" 里就有空格。
            // 规则：数字参数在最后，中间整体是 label。
            NSArray<NSString *> *parts =
                [[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                    componentsSeparatedByString:@" "];
            NSMutableArray<NSString *> *tok = [NSMutableArray array];
            NSArray<NSString *> *labelCmds = @[ @"set", @"gain", @"mute", @"add", @"remove" ];
            if (parts.count) [tok addObject:parts.firstObject];
            NSArray<NSString *> *rest = parts.count > 1
                ? [parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] : @[];
            if ([labelCmds containsObject:parts.firstObject.lowercaseString] && rest.count) {
                NSString *label = [rest componentsJoinedByString:@" "];
                NSString *num = nil;
                if (rest.count >= 2) {
                    NSScanner *sc = [NSScanner scannerWithString:rest.lastObject];
                    double dv = 0;
                    if ([sc scanDouble:&dv] && sc.isAtEnd) {
                        num = rest.lastObject;
                        label = [[rest subarrayWithRange:NSMakeRange(0, rest.count - 1)]
                                    componentsJoinedByString:@" "];
                    }
                }
                if (label.length) [tok addObject:label];
                if (num) [tok addObject:num];
            } else {
                [tok addObjectsFromArray:rest];
            }
            NSString *cmd = tok.count ? tok[0].lowercaseString : @"";
            {   // 调试：UI 拖了滑块没反应时，看 /tmp/perappvol-engine.log 就知道指令到没到
                FILE *lf = fopen("/tmp/perappvol-engine.log", "a");
                if (lf) { fprintf(lf, "CMD %s\n", line.UTF8String); fclose(lf); }
            }
            NSString *resp = nil;

            if (([cmd isEqualToString:@"set"] || [cmd isEqualToString:@"gain"]) && tok.count >= 3) {
                float v = tok[2].floatValue / ([cmd isEqualToString:@"gain"] ? 100.0f : 1.0f);
                BOOL ok = NO;
                for (UInt32 s = 0; s < gNSlots; s++) if ([gLabels[s] isEqualToString:tok[1]]) {
                    gSlots[s].targetGain = MIN(MAX(v, 0), 1); ok = YES;
                }
                resp = ok ? @"OK" : [NSString stringWithFormat:@"ERR unknown label %@", tok[1]];
            } else if ([cmd isEqualToString:@"mute"] && tok.count >= 3) {
                BOOL on = [tok[2] isEqualToString:@"on"];
                BOOL ok = NO;
                for (UInt32 s = 0; s < gNSlots; s++) if ([gLabels[s] isEqualToString:tok[1]]) {
                    gSlots[s].targetGain = on ? 0 : 1; ok = YES;
                }
                resp = ok ? @"OK" : [NSString stringWithFormat:@"ERR unknown label %@", tok[1]];
            } else if ([cmd isEqualToString:@"get"]) {
                NSMutableString *m = [NSMutableString string];
                for (UInt32 s = 0; s < gNSlots; s++)
                    [m appendFormat:@"%@ %.3f\n", gLabels[s], gSlots[s].targetGain];
                [m appendString:@"END\n"];
                resp = m;
            } else if ([cmd isEqualToString:@"add"] && tok.count >= 2) {
                float g = tok.count >= 3 ? tok[2].floatValue : 1.0f;
                resp = [addSlot(tok[1], g) stringByAppendingString:@"\n"];
            } else if ([cmd isEqualToString:@"remove"] && tok.count >= 2) {
                UInt32 idx = procSlotIndex(tok[1]);
                if (idx == gNSlots) resp = [NSString stringWithFormat:@"ERR unknown label %@\n", tok[1]];
                else resp = [removeSlot(gLabels[idx]) stringByAppendingString:@"\n"];
            } else if ([cmd isEqualToString:@"list"]) {
                // 供 UI 用：App 级列表（helper 已归并）。
                // TAB 分隔 —— 名字和 .app 路径里都可能有空格。
                // 字段: app \t realApp(0/1) \t playing(0/1) \t pid \t 名字 \t key
                NSDictionary *map = keyedProcs();
                NSMutableArray<NSString *> *rows = [NSMutableArray array];
                for (NSString *key in map) {
                    NSArray<NSNumber *> *plist = map[key];
                    BOOL playing = NO;
                    pid_t firstPid = 0;
                    for (NSNumber *n in plist) {
                        AudioObjectID o = n.unsignedIntValue;
                        if (!firstPid) firstPid = (pid_t)u32Prop(o, kAudioProcessPropertyPID);
                        if (u32Prop(o, kAudioProcessPropertyIsRunningOutput)) playing = YES;
                    }
                    [rows addObject:[NSString stringWithFormat:@"app\t%d\t%d\t%d\t%@\t%@",
                                     keyIsRealApp(key) ? 1 : 0, playing ? 1 : 0,
                                     (int)firstPid, displayNameForKey(key), key]];
                }
                [rows sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                    NSArray *pa = [a componentsSeparatedByString:@"\t"];
                    NSArray *pb = [b componentsSeparatedByString:@"\t"];
                    if (pa[2] != pb[2]) return [pb[2] compare:pa[2]];   // 出声的排前面
                    return [pa[4] localizedCompare:pb[4]];
                }];
                NSMutableString *m = [NSMutableString string];
                for (NSString *r in rows) [m appendFormat:@"%@\n", r];
                [m appendString:@"END\n"];
                resp = m;
            } else if ([cmd isEqualToString:@"stat"]) {
                // 电平：UI 可用它做电平表；也用于验证输出通路
                NSMutableString *m = [NSMutableString string];
                [m appendFormat:@"cb %u\nout %.5f\nopk %.5f\nlim %.5f\n",
                                 gCalls, gOutRMS, gOutPeak, (double)gLimGR];
                for (UInt32 s = 0; s < gNSlots; s++)
                    [m appendFormat:@"in %@ rms=%.5f pk=%.5f gain=%.3f\n",
                                 gLabels[s], gInRMS[s], gInPeak[s], gSlots[s].targetGain];
                [m appendString:@"END\n"];
                resp = m;
            } else if ([cmd isEqualToString:@"quit"]) {
                dprintf(fd, "OK\n");
                return 1;
            } else {
                resp = @"ERR unknown command";
            }
            if (resp) dprintf(fd, "%s", resp.UTF8String);
        }
        [acc replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
    }
    return 0;
}

/// 单实例锁（flock，进程死亡自动释放）。
/// 之前没有这层保护：UI 探测超时就再拉一个引擎 → 两个引擎抢同一个 socket，
/// 还会互相把对方的输出抓回来（自激反馈 + 双份声音）。
static int acquireSingleInstanceLock(void) {
    int fd = open("/tmp/mac-sound-control.pid", O_RDWR | O_CREAT, 0644);
    if (fd < 0) { perror("open pidfile"); return -1; }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        fprintf(stderr, "已有另一个引擎实例在运行（/tmp/mac-sound-control.pid 被锁），本实例退出。\n");
        close(fd);
        return -1;
    }
    ftruncate(fd, 0);
    dprintf(fd, "%d\n", getpid());
    return fd;   // 保持打开：进程退出时 flock 自动释放
}

/// 后台接受控制连接（Unix domain socket）
static void startControlServer(NSString *path) {
    if (acquireSingleInstanceLock() < 0) exit(3);
    unlink(path.fileSystemRepresentation);
    int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (lfd < 0) { perror("socket"); return; }
    struct sockaddr_un addr = { 0 };
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path.fileSystemRepresentation);
    if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("bind"); return; }
    listen(lfd, 32);
    fprintf(stderr, "[ctl] 控制套接字: %s   （试: printf 'set ALL 0.5\\nget\\n' | nc -U %s）\n",
            path.UTF8String, path.UTF8String);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (;;) {
            int cfd = accept(lfd, NULL, NULL);
            if (cfd < 0) break;
            // 每条连接独立处理：之前是串行服务，一条连接慢就把后面的全堵住。
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                handleControl(cfd);
                close(cfd);
            });
        }
    });
}

#pragma mark - 进程清单 / 进程集监听

/// 列出 HAL 里所有可识别的 App（含进程总数、出声进程数），按 App 名排序
static void listHalProcs(void) {
    NSDictionary<NSString *, NSArray<NSNumber *> *> *map = keyedProcs();
    NSMutableArray<NSArray *> *rows = [NSMutableArray array];
    for (NSString *key in map) {
        NSArray<NSNumber *> *list = map[key];
        NSUInteger playing = 0;
        NSMutableString *ids = [NSMutableString string];
        for (NSNumber *n in list) {
            AudioObjectID o = n.unsignedIntValue;
            BOOL out = u32Prop(o, kAudioProcessPropertyIsRunningOutput) != 0;
            if (out) playing++;
            [ids appendFormat:@"%u:%d:%@ ", o, (int)u32Prop(o, kAudioProcessPropertyPID), out ? @"1" : @"0"];
        }
        NSString *name = displayNameForKey(key);
        [rows addObject:@[ name, key, @(list.count), @(playing), ids ]];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [a[0] localizedCompare:b[0]];
    }];
    fprintf(stderr, "%-3s %-30s %-34s %-5s %-4s %s\n", "#", "App 名", "Bundle ID", "#进程", "出声", "objID:pid:out");
    NSInteger i = 0;
    for (NSArray *r in rows) {
        fprintf(stderr, "%-3ld %-30s %-34s %-5lu %-4s %s\n", (long)++i,
                [r[0] UTF8String], [r[1] UTF8String],
                (unsigned long)[r[2] unsignedLongValue],
                [r[3] unsignedLongValue] ? "YES" : "-",
                [r[4] UTF8String]);
    }
}

/// 所有受控 App 当前解析到的进程对象集合（用于检测变化）
static NSString *procSetKey(void) {
    NSMutableString *s = [NSMutableString string];
    for (UInt32 i = 0; i < gNSlots; i++) {
        if ([gLabels[i] isEqualToString:@"ALL"]) continue;
        [s appendFormat:@"%@", gLabels[i]];
        for (NSNumber *n in procsForLabel(gLabels[i])) [s appendFormat:@":%u", n.unsignedIntValue];
        [s appendString:@"|"];
    }
    return s;
}

/// label -> 槽位下标；带 helper 的 App 用父 key 也能命中
UInt32 procSlotIndex(NSString *label) {
    for (UInt32 i = 0; i < gNSlots; i++)
        if ([gLabels[i] isEqualToString:label]) return i;
    for (UInt32 i = 0; i < gNSlots; i++) {
        NSString *b = gLabels[i];
        if (label.length > b.length && [label hasPrefix:b] && [label characterAtIndex:b.length] == '.') return i;
    }
    return gNSlots;
}

/// 受控 App 的进程集合变了（App 启动 / 退出）→ 重建 tap。
/// 这是 QQ/飞书/微信 这类多进程 App 能一直跟得住的关键。
static dispatch_queue_t gEngineQ;          // 定义在后，此处前置声明
static void engineRebuild(const char *why);

static void watchProcessSet(void) {
    static NSString *last = nil;
    static dispatch_queue_t pq = nil;
    static dispatch_block_t pending = nil;
    static NSObject *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        last = procSetKey();
        pq = dispatch_queue_create("ppv.procset", DISPATCH_QUEUE_SERIAL);
        lock = [NSObject new];
    });
    AudioObjectPropertyAddress a = A_(kAudioHardwarePropertyProcessObjectList,
                                      kAudioObjectPropertyScopeGlobal, 0);
    AudioObjectAddPropertyListenerBlock((AudioObjectID)kAudioObjectSystemObject, &a, pq,
        ^(UInt32 n, const AudioObjectPropertyAddress *addrs) {
            (void)n; (void)addrs;
            // 防抖 1.5s：登录时会有一大波进程，不能每来一个就重建一次
            @synchronized (lock) {
                if (pending) dispatch_block_cancel(pending);
                dispatch_block_t job = dispatch_block_create(0, ^{
                    NSString *now = procSetKey();
                    if ([now isEqualToString:last]) return;
                    last = now;
                    if (gEngineQ) dispatch_sync(gEngineQ, ^{ engineRebuild("process set change"); });
                });
                pending = job;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), pq, job);
            }
        });
}

#pragma mark - 主流程

// 引擎生命周期（设备热切换时需要能拆了重建）
static AudioObjectID     gAgg = 0;
static AudioDeviceIOProcID gIOProc = NULL;

static void stopEngine(void) {
    if (!gAgg) return;
    AudioDeviceStop(gAgg, gIOProc);
    AudioDeviceDestroyIOProcID(gAgg, gIOProc);
    AudioHardwareDestroyAggregateDevice(gAgg);
    gAgg = 0;
    gIOProc = NULL;
}

static void startEngine(AudioObjectID outDev) {
    if (buildAggregate(&gAgg, outDev) != noErr) return;
    OSStatus s = AudioDeviceCreateIOProcIDWithBlock(&gIOProc, gAgg, NULL,
        ^(const AudioTimeStamp *inNow, const AudioBufferList *inInputData,
          const AudioTimeStamp *inInputTime, AudioBufferList *outOutputData,
          const AudioTimeStamp *inOutputTime) {
            (void)inNow; (void)inInputTime; (void)inOutputTime;
            render(inInputData, outOutputData);
        });
    if (s != noErr || !gIOProc) { fprintf(stderr, "CreateIOProcID 失败: %d\n", (int)s); return; }
    s = AudioDeviceStart(gAgg, gIOProc);
    if (s != noErr) fprintf(stderr, "AudioDeviceStart 失败: %d\n", (int)s);
}

// 串行化所有"重建"操作（设备切换 / 增删 App），避免与 IO 线程打架
static dispatch_queue_t gEngineQ = nil;

/// 重建引擎。注意：ALL 槽的排除列表依赖其他槽，必须重建它的 tap；其余 tap 保留
static void engineRebuild(const char *why) {
    for (UInt32 i = 0; i < gNSlots; i++) {
        if (![gLabels[i] isEqualToString:@"ALL"]) continue;
        if (gSlots[i].tapID) AudioHardwareDestroyProcessTap(gSlots[i].tapID);
        gSlots[i].tapID = 0;
        createTapAt(i);
    }
    AudioObjectID dev = defaultOutputDevice();
    stopEngine();
    startEngine(dev);
    fprintf(stderr, "[engine] 重建完成（%s）：%u 路 per-app 输入 -> %u %s\n", why, gNInputs, dev,
            [strProp(dev, kAudioDevicePropertyDeviceNameCFString,
                     kAudioObjectPropertyScopeGlobal, 0) UTF8String]);
}

/// 运行时新增一路 per-app 控制（UI 勾选某个 App 时调用）
static NSString *addSlot(NSString *key, float gain) {
    __block NSString *res = nil;
    dispatch_sync(gEngineQ, ^{
        for (UInt32 i = 0; i < gNSlots; i++)
            if ([gLabels[i] isEqualToString:key]) { res = @"ERR already exists"; return; }
        if (gNSlots >= MAX_TAPS) { res = @"ERR too many"; return; }
        UInt32 i = gNSlots;
        gLabels[i] = key;
        gSlots[i].targetGain = MIN(MAX(gain, 0), 1);
        gSlots[i].curGain = gSlots[i].targetGain;
        gSlots[i].tapID = 0;
        if (createTapAt(i) != noErr) { gLabels[i] = nil; res = @"ERR cannot create tap"; return; }
        gNSlots++;
        engineRebuild("add");
        res = @"OK";
    });
    return res;
}

/// 运行时移除一路
static NSString *removeSlot(NSString *key) {
    __block NSString *res = nil;
    dispatch_sync(gEngineQ, ^{
        UInt32 found = gNSlots;
        for (UInt32 i = 0; i < gNSlots; i++)
            if ([gLabels[i] isEqualToString:key]) { found = i; break; }
        if (found == gNSlots) { res = @"ERR unknown label"; return; }
        if (gSlots[found].tapID) AudioHardwareDestroyProcessTap(gSlots[found].tapID);
        for (UInt32 i = found; i + 1 < gNSlots; i++) {
            gSlots[i] = gSlots[i + 1];
            gLabels[i] = gLabels[i + 1];
        }
        gNSlots--;
        gLabels[gNSlots] = nil;
        engineRebuild("remove");
        res = @"OK";
    });
    return res;
}

/// 输出设备变了（耳机断开 / 切换输出）→ 重建聚合设备；tap 保留不动
static void rebuildForNewOutput(void) {
    dispatch_sync(gEngineQ, ^{ engineRebuild("output device change"); });
}

static void watchOutputDevice(void) {
    AudioObjectPropertyAddress a = A_(kAudioHardwarePropertyDefaultOutputDevice,
                                      kAudioObjectPropertyScopeGlobal, 0);
    dispatch_queue_t q = dispatch_queue_create("ppv.devchange", DISPATCH_QUEUE_SERIAL);
    AudioObjectAddPropertyListenerBlock((AudioObjectID)kAudioObjectSystemObject, &a, q,
        ^(UInt32 n, const AudioObjectPropertyAddress *addrs) {
            (void)n; (void)addrs;
            rebuildForNewOutput();
        });
    // 设备被拔掉时默认输出也会变，这里只听默认输出即可覆盖绝大多数场景
}

static int runMixer(NSArray<NSString *> *specs, NSTimeInterval seconds, NSString *sockPath) {
    // 没权限时 tap 不报错、只给静音；而 CATapMuted 会把 App 的声音劫走 ——
    // 合起来就是【全机静音】。所以这里直接拒绝启动，不要默默弄没用户的声音。
    if (!CGPreflightScreenCaptureAccess()) {
        fprintf(stderr,
            "\n缺少「屏幕与系统音频录制」权限，拒绝启动（否则会把全机声音劫走变成静音）。\n"
            "请到：系统设置 → 隐私与安全性 → 屏幕与系统音频录制 → 打开本程序（或它的宿主终端）。\n"
            "也可以先跑 APPTAP_REQUEST=1 ./apptap tap ALL 1 触发系统弹窗。\n\n");
        return 1;
    }
    AudioObjectID outDev = defaultOutputDevice();
    fprintf(stderr, "输出设备: %u %s\n", outDev,
            [strProp(outDev, kAudioDevicePropertyDeviceNameCFString,
                     kAudioObjectPropertyScopeGlobal, 0) UTF8String]);

    if (buildTaps(specs) != noErr) return 1;
    gEngineQ = dispatch_queue_create("ppv.engine", DISPATCH_QUEUE_SERIAL);
    startEngine(outDev);
    if (!gAgg) return 1;

    fprintf(stderr, "混音器已启动：%u 路 per-app 输入，%.0f 秒后退出。\n", gNInputs, seconds);
    watchOutputDevice();
    watchProcessSet();
    if (sockPath) startControlServer(sockPath);

    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([end timeIntervalSinceNow] > 0) {
        usleep(250 * 1000);
        NSMutableString *line = [NSMutableString string];
        for (UInt32 i = 0; i < gNInputs; i++) {
            UInt32 slot = gInputOrder[i];
            [line appendFormat:@"  [%@ %3.0f%% pk=%-8.5f]", gLabels[slot],
                              gSlots[slot].targetGain * 100, gInPeak[slot]];
        }
        fprintf(stderr, "[cb=%-6u]%s  OUT rms=%-8.5f lim=%.1fdB\n", gCalls, line.UTF8String,
                gOutRMS, 20.0 * log10(gLimGR > 1e-6 ? gLimGR : 1e-6));
    }

    stopEngine();
    for (UInt32 i = 0; i < gNSlots; i++) AudioHardwareDestroyProcessTap(gSlots[i].tapID);
    fprintf(stderr, "已清理完毕（限幅器介入 %u 帧）\n", gLimActive);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // 注意：--list 只有一个参数，必须放在 argc 守卫【之前】
        if (argc == 2 && strcmp(argv[1], "--list") == 0) { listHalProcs(); return 0; }
        if (argc < 3) {
            fprintf(stderr,
                "用法:\n"
                "  perappvol --list                          列出可识别的 App（helper 已归并）\n"
                "  perappvol demo <bundleID|pid> [秒]         目标 App 音量 0->100->0 扫动\n"
                "  perappvol run  <id=vol> <id=vol> ... [秒]  静态增益，id=ALL 表示其余全部\n"
                "  perappvol serve <id=vol> ... [--socket P] [秒]  常驻 + 运行时调音量\n");
            return 2;
        }
        NSString *cmd = @(argv[1]);

        if ([cmd isEqualToString:@"demo"]) {
            NSString *target = @(argv[2]);
            NSTimeInterval secs = argc > 3 ? atof(argv[3]) : 12;
            // 默认：其余 App 保持 100%。PPV_OTHERS=0 可让目标 App 独占输出（便于验证）
            NSString *others = getenv("PPV_OTHERS") ? @(getenv("PPV_OTHERS")) : @"1.0";
            NSArray *specs = @[ [NSString stringWithFormat:@"%@=0", target],
                                [NSString stringWithFormat:@"ALL=%@", others] ];

            // 后台线程周期性扫动第 0 路（目标 App）的增益：0 -> 1 -> 0，周期 6 秒
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSDate *end = [NSDate dateWithTimeIntervalSinceNow:secs];
                double t = 0;
                while ([end timeIntervalSinceNow] > 0) {
                    if (gNSlots > 0) gSlots[0].targetGain = (float)(0.5 - 0.5 * cos(t * 2.0 * M_PI / 6.0));
                    usleep(50 * 1000);
                    t += 0.05;
                }
            });
            return runMixer(specs, secs, nil);
        }

        if ([cmd isEqualToString:@"run"]) {
            NSMutableArray<NSString *> *specs = [NSMutableArray array];
            NSTimeInterval secs = 10;
            for (int i = 2; i < argc; i++) {
                NSString *a = @(argv[i]);
                if (i == argc - 1 && ![a containsString:@"="] && a.doubleValue > 0) secs = a.doubleValue;
                else [specs addObject:a];
            }
            if (specs.count == 0) { fprintf(stderr, "需要至少一个 <id=vol>\n"); return 2; }
            return runMixer(specs, secs, nil);
        }

        if ([cmd isEqualToString:@"serve"]) {
            NSMutableArray<NSString *> *specs = [NSMutableArray array];
            NSTimeInterval secs = 3600 * 8;
            NSString *sock = @"/tmp/mac-sound-control.sock";
            for (int i = 2; i < argc; i++) {
                NSString *a = @(argv[i]);
                if ([a isEqualToString:@"--socket"] && i + 1 < argc) sock = @(argv[++i]);
                else if (i == argc - 1 && ![a containsString:@"="] && a.doubleValue > 0) secs = a.doubleValue;
                else [specs addObject:a];
            }
            if (specs.count == 0) {
                fprintf(stderr, "用法: perappvol serve <id=vol> ... [--socket /path] [秒]\n");
                return 2;
            }
            return runMixer(specs, secs, sock);
        }

        fprintf(stderr, "未知命令 %s\n", argv[1]);
        return 2;
    }
}
