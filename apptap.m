// apptap.m — per-app 音频抓取 PoC（验证 CoreAudio Process Tap 链路）
//
// 编译: clang -fobjc-arc apptap.m -o apptap -framework CoreAudio -framework Foundation -framework CoreGraphics
// 用法:
//   apptap procs                       列出所有 HAL 进程对象 + 是否正在出声
//   apptap tap <bundleID|pid|ALL> [秒] 抓取该 app 的音频并打印 RMS
//   多个 id 可同时传，即多路 per-app 抓取（per-app 音量的基础）
// 环境变量:
//   APPTAP_MUTE=1    同时把音频从硬件劫走（CATapMuted）
//   APPTAP_DUMP=1    打印聚合设备构成
//   APPTAP_PRIVATE=1 使用私有 tap
//   APPTAP_REQUEST=1 先申请 TCC 权限（屏幕与系统音频录制）

#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CGWindow.h>
#import <math.h>

#pragma mark - 通用小工具

static AudioObjectPropertyAddress A(AudioObjectPropertySelector s,
                                    AudioObjectPropertyScope sc,
                                    AudioObjectPropertyElement e) {
    AudioObjectPropertyAddress a = { s, sc, e };
    return a;
}

static NSString *strProp(AudioObjectID o, AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress a = A(sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    CFStringRef s = NULL;
    UInt32 size = sizeof(s);
    if (AudioObjectGetPropertyData(o, &a, 0, NULL, &size, &s) != noErr || !s) return nil;
    return CFBridgingRelease(s);
}

static uint32_t u32Prop(AudioObjectID o, AudioObjectPropertySelector sel,
                        AudioObjectPropertyScope sc, AudioObjectPropertyElement el) {
    AudioObjectPropertyAddress a = A(sel, sc, el);
    UInt32 v = 0, size = sizeof(v);
    AudioObjectGetPropertyData(o, &a, 0, NULL, &size, &v);
    return v;
}

static NSArray<NSNumber *> *processObjects(void) {
    AudioObjectPropertyAddress a = A(kAudioHardwarePropertyProcessObjectList,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain);
    UInt32 size = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size);
    NSMutableArray *out = [NSMutableArray array];
    if (size == 0) return out;
    AudioObjectID *ids = calloc(size, 1);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids);
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) [out addObject:@(ids[i])];
    free(ids);
    return out;
}

/// bundleID 或 pid -> AudioObjectID
static AudioObjectID findProcess(NSString *key) {
    pid_t wantPid = (pid_t)key.intValue;
    BOOL byPid = [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[key characterAtIndex:0]];
    for (NSNumber *n in processObjects()) {
        AudioObjectID o = n.unsignedIntValue;
        if (byPid) {
            if ((pid_t)u32Prop(o, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, 0) == wantPid) return o;
        } else {
            NSString *bid = strProp(o, kAudioProcessPropertyBundleID);
            if ([bid isEqualToString:key]) return o;
        }
    }
    return kAudioObjectUnknown;
}

#pragma mark - procs

static void cmdProcs(void) {
    printf("%-8s %-10s %-6s %-6s %s\n", "OBJID", "PID", "OUT", "IN", "BUNDLE ID");
    for (NSNumber *n in processObjects()) {
        AudioObjectID o = n.unsignedIntValue;
        pid_t pid = (pid_t)u32Prop(o, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, 0);
        uint32_t ro = u32Prop(o, kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal, 0);
        uint32_t ri = u32Prop(o, kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal, 0);
        NSString *bid = strProp(o, kAudioProcessPropertyBundleID) ?: @"(none)";
        printf("%-8u %-10d %-6s %-6s %s\n", o, pid, ro ? "yes" : "-", ri ? "yes" : "-", bid.UTF8String);
    }
}

#pragma mark - tap

static volatile double gRMS[16];
static volatile UInt32 gFrames[16];
static volatile double gMax[16];
static volatile double gDC[16];

static OSStatus buildAggregate(NSArray<NSNumber *> *tapIDs, AudioObjectID *outAgg) {
    NSMutableArray *taps = [NSMutableArray array];
    for (NSNumber *n in tapIDs) {
        AudioObjectID tapID = n.unsignedIntValue;
        NSString *uid = strProp(tapID, kAudioTapPropertyUID);
        if (!uid) { fprintf(stderr, "tap 无 UID\n"); return -1; }
        // Audio Sub-Tap 字典：kAudioSubTapUIDKey / kAudioSubTapDriftCompensationKey
        [taps addObject:@{ @"uid": uid,
                           @"drift": @(kAudioAggregateDriftCompensationHighQuality) }];
        AudioStreamBasicDescription f = {0};
        AudioObjectPropertyAddress a = A(kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, 0);
        UInt32 size = sizeof(f);
        if (AudioObjectGetPropertyData(tapID, &a, 0, NULL, &size, &f) == noErr) {
            fprintf(stderr, "  tap %u uid=%s fmt=%.1fkHz %u bit %u ch (interleaved=%d)\n",
                    tapID, uid.UTF8String, f.mSampleRate / 1000.0, f.mBitsPerChannel,
                    f.mChannelsPerFrame, (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 0 : 1);
        }
    }

    // 关键：private=1（tap 聚合必须私有，不持久化），taps 挂进聚合设备
    NSDictionary *comp = @{
        @"name": @"PerAppMixerTapAggregate",
        @"uid": [NSString stringWithFormat:@"com.mac-sound-control.agg.%d", getpid()],
        @"private": @(1),
        @"taps": taps,
    };
    OSStatus s = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)comp, outAgg);
    if (s != noErr) fprintf(stderr, "AudioHardwareCreateAggregateDevice 失败: %d\n", (int)s);
    return s;
}

static void dumpAggregate(AudioObjectID agg) {
    AudioObjectPropertyAddress a = A(kAudioAggregateDevicePropertyComposition,
                                     kAudioObjectPropertyScopeGlobal, 0);
    CFDictionaryRef comp = NULL;
    UInt32 size = sizeof(comp);
    if (AudioObjectGetPropertyData(agg, &a, 0, NULL, &size, &comp) == noErr && comp) {
        NSLog(@"[dump] composition = %@", (__bridge NSDictionary *)comp);
        CFRelease(comp);
    } else {
        fprintf(stderr, "[dump] composition 读取失败\n");
    }
    for (int i = 0; i < 2; i++) {
        AudioObjectPropertyAddress b = A(i == 0 ? kAudioAggregateDevicePropertySubTapList
                                                : kAudioAggregateDevicePropertyActiveSubDeviceList,
                                         kAudioObjectPropertyScopeGlobal, 0);
        UInt32 sz = 0;
        AudioObjectGetPropertyDataSize(agg, &b, 0, NULL, &sz);
        fprintf(stderr, "[dump] %s count=%u\n",
                i == 0 ? "active sub-taps" : "active sub-devices", sz / (UInt32)sizeof(AudioObjectID));
    }
    for (int sc = 0; sc < 2; sc++) {
        AudioObjectPropertyAddress b = A(kAudioDevicePropertyStreams,
                                         sc == 0 ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, 0);
        UInt32 sz = 0;
        AudioObjectGetPropertyDataSize(agg, &b, 0, NULL, &sz);
        fprintf(stderr, "[dump] %s streams=%u\n",
                sc == 0 ? "input" : "output", sz / (UInt32)sizeof(AudioObjectID));
        if (sz) {
            AudioObjectID *ids = calloc(sz, 1);
            AudioObjectGetPropertyData(agg, &b, 0, NULL, &sz, ids);
            for (UInt32 i = 0; i < sz / sizeof(AudioObjectID); i++) {
                AudioStreamBasicDescription f = {0};
                AudioObjectPropertyAddress fa = A(kAudioStreamPropertyPhysicalFormat,
                                                  kAudioObjectPropertyScopeGlobal, 0);
                UInt32 fs = sizeof(f);
                AudioObjectGetPropertyData(ids[i], &fa, 0, NULL, &fs, &f);
                fprintf(stderr, "[dump]   stream %u: %.0fHz %u bit %u ch flags=0x%x\n",
                        ids[i], f.mSampleRate, f.mBitsPerChannel, f.mChannelsPerFrame, f.mFormatFlags);
            }
            free(ids);
        }
    }
}

static void cmdTap(NSArray<NSString *> *keys, NSTimeInterval seconds) {
    NSMutableArray<NSNumber *> *tapIDs = [NSMutableArray array];

    for (NSString *k in keys) {
        CATapDescription *d = nil;
        if ([k isEqualToString:@"ALL"]) {
            // 全局 tap：抓所有进程（排除列表为空）
            d = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
        } else {
            AudioObjectID proc = findProcess(k);
            if (proc == kAudioObjectUnknown) {
                fprintf(stderr, "找不到进程 %s（注意：进程必须存在；正在出声的进程一定在列表里）\n", k.UTF8String);
                return;
            }
            // 一路 app = 一个 tap
            d = [[CATapDescription alloc] initStereoMixdownOfProcesses:@[@(proc)]];
            fprintf(stderr, "目标进程 object %u\n", proc);
        }
        d.name = [NSString stringWithFormat:@"tap-%@", k];
        if (getenv("APPTAP_PRIVATE")) d.privateTap = YES;
        // CATapMuted = 音频被劫走（真·per-app 音量需要）；CATapUnmuted = 旁路监听，不影响播放
        d.muteBehavior = getenv("APPTAP_MUTE") ? CATapMuted : CATapUnmuted;
        AudioObjectID tapID = 0;
        OSStatus s = AudioHardwareCreateProcessTap(d, &tapID);
        if (s != noErr) {
            fprintf(stderr, "AudioHardwareCreateProcessTap 失败: %d（权限不足？见 README）\n", (int)s);
            return;
        }
        [tapIDs addObject:@(tapID)];
        fprintf(stderr, "已创建 tap %u\n", tapID);
    }

    AudioObjectID agg = 0;
    if (buildAggregate(tapIDs, &agg) != noErr) return;
    fprintf(stderr, "聚合设备 %u 已创建，开始抓取 %.0f 秒...\n", agg, seconds);
    if (getenv("APPTAP_DUMP")) dumpAggregate(agg);

    __block UInt32 calls = 0;
    AudioDeviceIOProcID ioProc = NULL;
    OSStatus s = AudioDeviceCreateIOProcIDWithBlock(&ioProc, agg, NULL,
        ^(const AudioTimeStamp *inNow, const AudioBufferList *inInputData,
          const AudioTimeStamp *inInputTime, AudioBufferList *outOutputData,
          const AudioTimeStamp *inOutputTime) {
            (void)inNow; (void)inInputTime; (void)outOutputData; (void)inOutputTime;
            for (UInt32 b = 0; b < inInputData->mNumberBuffers && b < 16; b++) {
                AudioBuffer buf = inInputData->mBuffers[b];
                float *x = (float *)buf.mData;
                if (!x) continue;
                UInt32 n = buf.mDataByteSize / sizeof(float);
                double acc = 0, mx = 0, sx = 0;
                for (UInt32 i = 0; i < n; i++) {
                    double v = x[i];
                    acc += v * v; sx += v;
                    if (fabs(v) > mx) mx = fabs(v);
                }
                gRMS[b] = sqrt(acc / (n ? n : 1));
                gFrames[b] = n;
                gMax[b] = mx;
                gDC[b] = sx / (n ? n : 1);
            }
            if (calls++ == 0) {
                fprintf(stderr, "[diag] buffers=%u\n", inInputData->mNumberBuffers);
                for (UInt32 b = 0; b < inInputData->mNumberBuffers; b++) {
                    AudioBuffer buf = inInputData->mBuffers[b];
                    fprintf(stderr, "[diag]   buf%u ch=%u bytes=%u\n", b, buf.mNumberChannels, buf.mDataByteSize);
                    if (buf.mData) {
                        UInt32 *raw = (UInt32 *)buf.mData;
                        fprintf(stderr, "[diag]     raw[0..3]=%08x %08x %08x %08x\n", raw[0], raw[1], raw[2], raw[3]);
                    }
                }
            }
        });
    if (s != noErr || !ioProc) { fprintf(stderr, "CreateIOProcID 失败: %d\n", (int)s); return; }

    // tapautostart 未开启时这里会立刻跑；app 没出声就全是静音
    s = AudioDeviceStart(agg, ioProc);
    if (s != noErr) fprintf(stderr, "AudioDeviceStart 失败: %d\n", (int)s);

    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([end timeIntervalSinceNow] > 0) {
        usleep(500 * 1000);
        NSMutableString *line = [NSMutableString string];
        for (UInt32 b = 0; b < tapIDs.count; b++)
            [line appendFormat:@"  tap%u: rms=%-9.6f max=%-9.6f dc=%-9.6f frames=%u",
                              b, gRMS[b], gMax[b], gDC[b], gFrames[b]];
        fprintf(stderr, "[callbacks=%u]%s\n", calls, line.UTF8String);
    }

    AudioDeviceStop(agg, ioProc);
    AudioDeviceDestroyIOProcID(agg, ioProc);
    AudioHardwareDestroyAggregateDevice(agg);
    for (NSNumber *n in tapIDs) AudioHardwareDestroyProcessTap(n.unsignedIntValue);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "用法: apptap procs | tap <bundleID|pid>... [秒]\n");
            return 2;
        }
        NSString *cmd = @(argv[1]);
        if ([cmd isEqualToString:@"procs"]) { cmdProcs(); return 0; }

        NSMutableArray<NSString *> *keys = [NSMutableArray array];
        NSTimeInterval secs = 6;
        for (int i = 2; i < argc; i++) {
            NSString *a = @(argv[i]);
            if ([a doubleValue] > 0 && i == argc - 1) secs = a.doubleValue;
            else [keys addObject:a];
        }
        if (keys.count == 0) { fprintf(stderr, "需要至少一个 bundleID 或 pid\n"); return 2; }
        if (getenv("APPTAP_REQUEST")) {
            fprintf(stderr, "[auth] CGPreflightScreenCaptureAccess = %d\n", CGPreflightScreenCaptureAccess());
            if (!CGPreflightScreenCaptureAccess()) {
                fprintf(stderr, "[auth] 请在系统弹窗中点 “允许” (屏幕与系统音频录制) ...\n");
                bool ok = CGRequestScreenCaptureAccess();
                fprintf(stderr, "[auth] CGRequestScreenCaptureAccess = %d\n", ok);
            }
        }
        cmdTap(keys, secs);
    }
    return 0;
}
