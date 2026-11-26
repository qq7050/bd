//
//  BaiduNetdiskTools — 百度网盘 iOS 13.35.5 巨魔增强 (v11)
//
//  v8 诊断: shouldSplashShow/isVipCanShowAdvertise 都 HIT 返回 NO 但广告还在
//           -> 说明广告走的是"贴片/激励视频"路径, 不是开屏开关。
//  v8 副作用: 只 hook isSVIP=YES, isBoughtSVip/vipLevel/有效期没配合,
//            -> 会员页 V10/已购会员/有效期消失。
//  v9 方案:
//   1) 补全全套会员字段(isVIP/isBoughtSVip/vipLevel=10/有效期=2099 等), 修复会员页显示。
//   2) 掐断真正的广告展示入口: showAdvertise(5类)/canShowRewardAlert/贴片广告启动方法。
//   3) 保留限速方法族 + JSON 抓直链。
//
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>

/* ---------- 文件工具 ---------- */
static NSString *BNDocs(void) {
    NSArray *p = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return (p.count ? p[0] : @"/var/mobile/Documents");
}
static NSString *BNPath(NSString *n) { return [BNDocs() stringByAppendingPathComponent:n]; }
static void BNAppend(NSString *file, NSString *line) {
    NSString *path = BNPath(file);
    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!old) old = @"";
    if ([old rangeOfString:line].location != NSNotFound) return;
    NSString *ns = old.length ? [old stringByAppendingFormat:@"\n%@", line] : line;
    [ns writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static void BNDebug(NSString *s) { BNAppend(@"bnt_debug.txt", s); }
static void BNHit(NSString *tag) { BNAppend(@"bnt_hooks.txt", [NSString stringWithFormat:@"HIT %@", tag]); }

/* ---------- JSON 响应抓 dlink ---------- */
static BOOL BNIsLinkKey(NSString *k) {
    NSString *s = [k lowercaseString];
    return ([s isEqualToString:@"dlink"] || [s hasSuffix:@"dlink"] ||
            [s rangeOfString:@"dlink"].location != NSNotFound ||
            [s isEqualToString:@"downloadlink"] || [s isEqualToString:@"downloadurl"]);
}
// 真实文件直链 vs App 资源包: 只导出 d.pcs.baidu.com 的到干净文件
static void BNRecordLink(NSString *link) {
    BNAppend(@"baidu_links.txt", link);  // 原始全量(兼容旧版)
    if ([link rangeOfString:@"d.pcs.baidu.com/file/"].location != NSNotFound ||
        [link rangeOfString:@"d-drive.pcs.baidu.com"].location != NSNotFound) {
        BNAppend(@"baidu_real_dlinks.txt", link);  // 干净直链
    }
}
// 导出 Cookie + UA (dlink 绑定登录态, 外部下载器必须带上)
static void BNExportCookies(void) {
    NSMutableString *hdr = [NSMutableString string];
    NSHTTPCookieStorage *store = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSHTTPCookie *c in [store cookies]) {
        NSString *dom = [c domain] ?: @"";
        if ([dom rangeOfString:@"baidu"].location == NSNotFound) continue;
        [hdr appendFormat:@"%@=%@; ", [c name], [c value]];
    }
    [hdr writeToFile:BNPath(@"baidu_cookie.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *ua = @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 netdisk_iPhone/13.35.5";
    [ua writeToFile:BNPath(@"baidu_ua.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static void BNScanJSON(id obj, int depth) {
    if (!obj || depth > 8) return;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)obj;
        for (id key in d) {
            if (![key isKindOfClass:[NSString class]]) continue;
            id v = [d objectForKey:key];
            if (BNIsLinkKey(key) && [v isKindOfClass:[NSString class]]) {
                NSString *link = (NSString *)v;
                if ([link hasPrefix:@"http"]) { BNRecordLink(link); BNExportCookies(); }
            }
            BNScanJSON(v, depth + 1);
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id v in (NSArray *)obj) BNScanJSON(v, depth + 1);
    }
}

/* ---------- 限速: 超大值 ---------- */
static NSNumber *BNHuge(void) {
    static NSNumber *v = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ v = [NSNumber numberWithLongLong:1024LL * 1024 * 1024 * 1024]; });
    return v;
}
// 会员有效期: 2099-01-01 (13 位毫秒时间戳)
// 修 bug: 之前用 10 位秒级 4070908800, 百度按毫秒解读当成 1970 年 -> 界面显示"已过期 N 天"
static double BNFutureTime(void) { return 4070908800000.0; }

/* ---------- 原函数指针 ---------- */
static id  (*o_calcLimit)(id, SEL) = NULL;
static id  (*o_calcAllow)(id, SEL, BOOL) = NULL;
static id  (*o_downLimit)(id, SEL) = NULL;
static id  (*o_p2pLimit)(id, SEL) = NULL;
static long long (*o_fileLimit)(id, SEL) = NULL;
static BOOL (*o_shouldAccess)(id, SEL) = NULL;
static BOOL (*o_canSpeed)(id, SEL) = NULL;
static BOOL (*o_keepOrigP)(id, SEL) = NULL;
static BOOL (*o_keepOrigS)(id, SEL) = NULL;
static BOOL (*o_hotUser)(id, SEL) = NULL;
static id (*o_JSONData)(id, SEL, id, unsigned long, id *) = NULL;
static id (*o_JSONStream)(id, SEL, id, unsigned long, id *) = NULL;

/* ---------- Hook: 限速 ---------- */
static id h_calcLimit(id self, SEL _cmd) { BNHit(@"calcLimit"); return BNHuge(); }
static id h_calcAllow(id self, SEL _cmd, BOOL a) { BNHit(@"calcAllow"); return BNHuge(); }
static id h_downLimit(id self, SEL _cmd) { BNHit(@"downLoadSpeedLimit"); return BNHuge(); }
static id h_p2pLimit(id self, SEL _cmd) { BNHit(@"p2pDownloadSpeedLimit"); return BNHuge(); }
static long long h_fileLimit(id self, SEL _cmd) { BNHit(@"downloadFileSpeedLimit"); return 1024LL*1024*1024*1024; }
static BOOL h_shouldAccess(id self, SEL _cmd) { BNHit(@"shouldAccessSpeedLimit"); return NO; }
static BOOL h_canSpeed(id self, SEL _cmd) { BNHit(@"canSpeedUp"); return YES; }
static BOOL h_keepOrig(id self, SEL _cmd) { BNHit(@"isKeepOriginalDownloadSpeed"); return YES; }
static BOOL h_hotUser(id self, SEL _cmd) { BNHit(@"isHotUserLimit"); return NO; }

/* ---------- Hook: 会员信息补全 (修复 V10/已购/有效期) ---------- */
static BOOL h_yes(id self, SEL _cmd) { BNHit(NSStringFromSelector(_cmd)); return YES; }
static long long h_vipLevel(id self, SEL _cmd) { BNHit(@"vipLevel"); return 10; }
static double h_expire(id self, SEL _cmd) { BNHit(NSStringFromSelector(_cmd)); return BNFutureTime(); }
// 抑制 SVIP 专属图标引导弹窗: 让 App 认为已经弹过很多次/最近刚弹过
static long long h_guideTimes(id self, SEL _cmd) { BNHit(@"iconGuideTimes"); return 9999; }
static id h_guideDate(id self, SEL _cmd) { BNHit(@"iconGuideDate"); return [NSDate date]; }
static void h_iconNotify(id self, SEL _cmd, id n) { BNHit(@"iconNotifyBlocked"); /* 不调 orig, 拦掉弹窗触发 */ }

/* ---------- Hook: 广告展示入口 (真正掐断) ---------- */
// showAdvertise 系列: v16@0:8, 不调 orig 直接阻断广告展示
static void h_noShow(id self, SEL _cmd) { BNHit(NSStringFromSelector(_cmd)); /* block, 不调 orig */ }
// 贴片广告启动: v28@0:8B16q20, 不调 orig
static void h_noStartAd(id self, SEL _cmd, BOOL b, long long i) { BNHit(@"startAdvertise"); /* block */ }
static BOOL h_noRewardAlert(id self, SEL _cmd) { BNHit(@"canShowRewardAlert"); return NO; }
// 开屏广告(保留)
static BOOL h_no(id self, SEL _cmd) { BNHit(NSStringFromSelector(_cmd)); return NO; }
static void h_noShowVC(id self, SEL _cmd, id vc) { BNHit(NSStringFromSelector(_cmd)); /* block */ }

/* ---------- Hook: JSON 抓直链 ---------- */
static id h_JSONData(id self, SEL _cmd, id data, unsigned long opt, id *err) {
    id r = o_JSONData ? o_JSONData(self, _cmd, data, opt, err) : nil;
    if (r) { BNHit(@"JSONData"); BNScanJSON(r, 0); }
    return r;
}
static id h_JSONStream(id self, SEL _cmd, id stream, unsigned long opt, id *err) {
    id r = o_JSONStream ? o_JSONStream(self, _cmd, stream, opt, err) : nil;
    if (r) { BNHit(@"JSONStream"); BNScanJSON(r, 0); }
    return r;
}

/* ---------- 动态 hook 安装器 ---------- */
static void hookMethod(NSString *clsName, NSString *selName, IMP replacement, IMP *orig) {
    Class c = objc_getClass(clsName.UTF8String);
    if (!c) { BNDebug([NSString stringWithFormat:@"CLASS MISSING %@.%@", clsName, selName]); return; }
    SEL s = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(c, s);
    if (!m) { BNDebug([NSString stringWithFormat:@"METHOD MISSING %@.%@", clsName, selName]); return; }
    IMP before = method_getImplementation(m);
    MSHookMessageEx(c, s, replacement, orig);
    IMP after = method_getImplementation(m);
    BNDebug([NSString stringWithFormat:@"HOOK %@.%@ %@", clsName, selName,
             (after != before ? @"OK" : @"FAILED")]);
}

%ctor {
    NSString *mark = [NSString stringWithFormat:@"loaded(v11) %@\ndocs=%@\n", [NSDate date], BNDocs()];
    [mark writeToFile:BNPath(@"bnt_loaded.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *f in @[@"bnt_hooks.txt", @"bnt_debug.txt", @"baidu_real_dlinks.txt", @"baidu_cookie.txt", @"baidu_ua.txt"]) {
        if (![fm fileExistsAtPath:BNPath(f)])
            [@"" writeToFile:BNPath(f) atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    BNDebug(@"=== v11 ctor start ===");

    // === 限速方法族 ===
    hookMethod(@"DownOperation", @"calucateDownloadSpeedLimit",       (IMP)h_calcLimit,   (IMP*)&o_calcLimit);
    hookMethod(@"DownOperation", @"calucateDownloadSpeedLimitForAllow:",(IMP)h_calcAllow, (IMP*)&o_calcAllow);
    hookMethod(@"DownOperation", @"downLoadSpeedLimit",               (IMP)h_downLimit,   (IMP*)&o_downLimit);
    hookMethod(@"DownOperation", @"canSpeedUp",                       (IMP)h_canSpeed,    (IMP*)&o_canSpeed);
    hookMethod(@"CloudP2PCommandModel", @"downloadSpeedLimit",        (IMP)h_p2pLimit,    (IMP*)&o_p2pLimit);
    hookMethod(@"CDNRequestModel", @"shouldAccessSpeedLimit",         (IMP)h_shouldAccess,(IMP*)&o_shouldAccess);
    hookMethod(@"SettingManage", @"downloadFileSpeedLimit",           (IMP)h_fileLimit,   (IMP*)&o_fileLimit);
    hookMethod(@"SettingManage", @"isKeepOriginalDownloadSpeed",      (IMP)h_keepOrig,    (IMP*)&o_keepOrigS);
    hookMethod(@"SettingManage", @"isHotUserLimit",                   (IMP)h_hotUser,     (IMP*)&o_hotUser);
    hookMethod(@"PrivilegeModel", @"isKeepOriginalDownloadSpeed",     (IMP)h_keepOrig,    (IMP*)&o_keepOrigP);

    // === 会员信息补全: 修复 V10/已购会员/有效期 ===
    hookMethod(@"BDPanAccountInfo", @"isSVIP",            (IMP)h_yes,      NULL);
    hookMethod(@"BDPanAccountInfo", @"isVIP",             (IMP)h_yes,      NULL);
    hookMethod(@"BDPanAccountInfo", @"isBoughtSVip",      (IMP)h_yes,      NULL);
    hookMethod(@"BDPanAccountInfo", @"isExVIP",           (IMP)h_yes,      NULL);
    hookMethod(@"BDPanAccountInfo", @"isExSVIP",          (IMP)h_yes,      NULL);
    hookMethod(@"BDPanAccountInfo", @"isExperienceVIP",   (IMP)h_yes,      NULL);
    hookMethod(@"BDPanAccountInfo", @"spaceMember",       (IMP)h_yes,      NULL);
    hookMethod(@"BDPanAccountInfo", @"showLevel",         (IMP)h_yes,      NULL);
    hookMethod(@"BDPanAccountInfo", @"vipLevel",          (IMP)h_vipLevel, NULL);
    hookMethod(@"BDPanAccountInfo", @"vipExpireTime",     (IMP)h_expire,   NULL);
    hookMethod(@"BDPanAccountInfo", @"svipExpireTime",    (IMP)h_expire,   NULL);

    // === 抑制 SVIP 专属图标引导弹窗 ===
    hookMethod(@"BDPanChangeAppIconManage", @"guideShownTimes",      (IMP)h_guideTimes, NULL);
    hookMethod(@"BDPanChangeAppIconManage", @"lastGuideShownDate",   (IMP)h_guideDate,  NULL);
    hookMethod(@"BDPanChangeAppIconManage", @"usinfoFetchSuccessNotification:", (IMP)h_iconNotify, NULL);
    hookMethod(@"BDPanChangeAppIconManage", @"svipExpirationNotification:",     (IMP)h_iconNotify, NULL);

    // === 广告展示入口: 真正掐断 ===
    // 贴片/播放广告启动
    hookMethod(@"BDPanFlowPlayerAdvertiseView", @"startAdvertiseWithDisplayBottomPanel:index:", (IMP)h_noStartAd, NULL);
    // 各类 showAdvertise
    hookMethod(@"BDNCFlowPlayerAdBaseBiddingTask", @"showAdvertise", (IMP)h_noShow, NULL);
    hookMethod(@"BDNCRewardVideoAdBaseTask", @"showAdvertise", (IMP)h_noShow, NULL);
    hookMethod(@"BDNCGroMoreRewardVideoAdTask", @"showAdvertise", (IMP)h_noShow, NULL);
    hookMethod(@"BDNCCacheRewardVideoAdTask", @"showAdvertise", (IMP)h_noShow, NULL);
    hookMethod(@"BDNCCommerceRewardVideoAdTask", @"showAdvertise", (IMP)h_noShow, NULL);
    hookMethod(@"BDNCRewardVideoAdAlertHandler", @"canShowRewardAlert", (IMP)h_noRewardAlert, NULL);
    // 开屏(保留)
    hookMethod(@"BDNCAdvertisesManage", @"isVipCanShowAdvertise", (IMP)h_no, NULL);
    hookMethod(@"BDPanPrologueAdManager", @"shouldSplashShow", (IMP)h_no, NULL);
    hookMethod(@"BDPanGlobalSplashAdvertiseManager", @"needToShowSplashInForeground", (IMP)h_no, NULL);
    hookMethod(@"BDNCAPISplashAd", @"showSplashViewInRootViewController:", (IMP)h_noShowVC, NULL);
    hookMethod(@"BDNCBrandSplashAd", @"showSplashViewInRootViewController:", (IMP)h_noShowVC, NULL);

    // === JSON 响应抓 dlink (类方法, 元类 hook) ===
    Class jsonMeta = objc_getMetaClass("NSJSONSerialization");
    if (jsonMeta) {
        SEL s1 = NSSelectorFromString(@"JSONObjectWithData:options:error:");
        Method m1 = class_getClassMethod([NSJSONSerialization class], s1);
        if (m1) { MSHookMessageEx(jsonMeta, s1, (IMP)h_JSONData, (IMP*)&o_JSONData); BNDebug(@"HOOK NSJSONSerialization.data OK"); }
        SEL s2 = NSSelectorFromString(@"JSONObjectWithStream:options:error:");
        Method m2 = class_getClassMethod([NSJSONSerialization class], s2);
        if (m2) { MSHookMessageEx(jsonMeta, s2, (IMP)h_JSONStream, (IMP*)&o_JSONStream); BNDebug(@"HOOK NSJSONSerialization.stream OK"); }
    }

    BNDebug(@"=== v11 ctor end ===");
}
