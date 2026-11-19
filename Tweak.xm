//
//  BaiduSpeedBoost — 百度网盘 iOS 13.35.5 本地限速链补强
//  目标 App: com.baidu.netdisk (netdisk_iPhone, 13.35.5.6)
//
//  设计原则（重要）:
//  1) 只 hook 已在 13.35.5 二进制中实测确认存在的方法（类名/方法名/类型编码均来自 IPA 逆向）。
//  2) 不碰 speedUpToken / 反作弊类（BDPanDownloadAnticheatProtocol / BDPanJailbreakDetectTool 等）——
//     这些是服务端校验与风控，本地伪造无效且有黑号风险。
//  3) 限速值采用"保底抬升"而非"硬编码覆盖": 服务端下发的值若高于阈值则原样放行，
//     只有低于阈值（典型非会员 100KB/s）时才抬到阈值。这样保留会员/加速通道的真实高速。
//  4) 所有 hook 都保留原实现调用（%orig），仅修正返回值，降低崩溃与安全模式风险。
//
//  注意: 本 tweak 不修改 isSVIP/vipLevel——你的 baidudisk.dylib 已做（isSVIP=YES, vipLevel=10）。
//        本 tweak 与它叠加生效，负责"会员标志之后"的限速数值链。
//

#import <Foundation/Foundation.h>

// ===== 可调参数 =====
// 下载速度下限（字节/秒）。8 * 1024 * 1024 = 8 MB/s。
// 若你希望更激进可调到 20MB/s；设 0 则完全关闭"数值保底"，只保留开关类 hook。
static const long long kSpeedFloorBytesPerSec = 8LL * 1024LL * 1024LL;

// 优先使用二进制里实测的 ivar/方法；若某些方法在个别小版本签名不同，用 respondsToSelector 兜底。

// 把任意 NSNumber / 数值对象规整为 long long
static inline long long BDNumValue(id v) {
    if (!v) return 0;
    if ([v isKindOfClass:[NSNumber class]]) return [v longLongValue];
    if ([v respondsToSelector:@selector(longLongValue)]) return [v longLongValue];
    return 0;
}

// 数值型限速保底：低于阈值抬到阈值，高于阈值原样返回
static inline id BDFloorNumber(id orig) {
    if (kSpeedFloorBytesPerSec <= 0) return orig;
    long long v = BDNumValue(orig);
    if (v < kSpeedFloorBytesPerSec) {
        return [NSNumber numberWithLongLong:kSpeedFloorBytesPerSec];
    }
    return orig;
}

// 原始 long long 保底
static inline long long BDFloorLongLong(long long v) {
    if (kSpeedFloorBytesPerSec <= 0) return v;
    return v < kSpeedFloorBytesPerSec ? kSpeedFloorBytesPerSec : v;
}

#pragma mark - 1. CDN 限速开关（实测纯 ivar getter，最干净的 hook 点）
// 类型编码 B16@0:8 → BOOL，无参。关闭 CDN 层限速准入。
%hook CDNRequestModel
- (BOOL)shouldAccessSpeedLimit {
    // NO = 不施加 CDN 限速
    return NO;
}
%end

#pragma mark - 2. 下载任务限速计算（DownOperation）
// 类型编码 @16@0:8 → 返回 NSNumber；@20@0:8B16 → 带 BOOL 参数。
%hook DownOperation
- (id)calucateDownloadSpeedLimit {
    id orig = %orig;
    return BDFloorNumber(orig);
}

- (id)calucateDownloadSpeedLimitForAllow:(BOOL)allow {
    id orig = %orig(allow);
    return BDFloorNumber(orig);
}

// 允许加速开关（B16@0:8）
- (BOOL)canSpeedUp {
    return YES;
}

// downLoadSpeedLimit / setDownLoadSpeedLimit: 为 ivar 存取（@16@0:8 / v24@0:8@16）
// 读时保底；setter 放行原值，避免破坏内部状态一致性。
- (id)downLoadSpeedLimit {
    id orig = %orig;
    return BDFloorNumber(orig);
}
%end

#pragma mark - 3. P2P 下载限速（CloudP2PCommandModel）
// downloadSpeedLimit 类型 @16@0:8 → NSNumber
%hook CloudP2PCommandModel
- (id)downloadSpeedLimit {
    id orig = %orig;
    return BDFloorNumber(orig);
}
%end

#pragma mark - 4. 全局限速设置（SettingManage）
// downloadFileSpeedLimit 类型 q16@0:8 → long long
// speedLimitLevel 类型 q16@0:8 → 限速等级（不确定映射区间，故只抬数值不降级）
%hook SettingManage
- (long long)downloadFileSpeedLimit {
    long long orig = %orig;
    return BDFloorLongLong(orig);
}

// 保留原始下载速度（不转码降速）开关（B16@0:8）
- (BOOL)isKeepOriginalDownloadSpeed {
    return YES;
}

// 热门用户限速判定（B16@0:8）——返回 NO 避开热点用户额外限速
- (BOOL)isHotUserLimit {
    return NO;
}
%end

#pragma mark - 5. 会员权益限速档（PrivilegeModel）
// isKeepOriginalDownloadSpeed 类型 B16@0:8
// speedLimitLevel 类型 q16@0:8 —— 会员等级换算的限速档，配合 isSVIP=10 已足够，
// 这里不改等级（避免破坏其他权益判断），仅开"保留原速"。
%hook PrivilegeModel
- (BOOL)isKeepOriginalDownloadSpeed {
    return YES;
}
%end

// ===== 印象笔记/系统事件回调留空，避免日志泄露判断逻辑 =====
%ctor {
    NSLog(@"[BaiduSpeedBoost] loaded. floor=%lld B/s, target=com.baidu.netdisk 13.35.5", kSpeedFloorBytesPerSec);
}
