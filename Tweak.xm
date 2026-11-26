//
//  BaiduNetdiskTools — 百度网盘 iOS 13.35.5 巨魔增强 (v8)
//
//  路线修正:
//   - v6/v7 追 dlink dump 走偏了(DownOperation 实例里根本没有 dlink ivar, KVC/ivar 全取不到)。
//   - 回到旧 BaiduSpeedBoost.dylib 验证过的限速方法族, 并补齐它 hook 的全部 9 个方法。
//   - 去广告改用真正的总开关(BDPanPrologueAdManager.shouldSplashShow 等),
//     之前 hook 的 isVipCanShowAdvertise 不是主开关, 所以一直有广告。
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

/* ---------- JSON 响应抓 dlink (最可靠的直链来源) ---------- */
// dlink 是服务器 JSON 响应里的字段, 不在下载对象的 ivar 里。
// hook NSJSONSerialization 的解析结果, 递归扫描所有 "dlink"/"downloadlink" 等 key。
static BOOL BNIsLinkKey(NSString *k) {
    NSString *s = [k lowercaseString];
    return ([s isEqualToString:@"dlink"] || [s hasSuffix:@"dlink"] ||
            [s rangeOfString:@"dlink"].location != NSNotFound ||
            [s isEqualToString:@"downloadlink"] || [s isEqualToString:@"downloadurl"]);
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
                if ([link hasPrefix:@"http"]) BNAppend(@"baidu_links.txt", link);
            }
            BNScanJSON(v, depth + 1);
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id v in (NSArray *)obj) BNScanJSON(v, depth + 1);
    }
}

/* ---------- 限速: 超大值 ---------- */
// 旧 BaiduSpeedBoost.dylib 的核心: 把限速值换成极大 longLong。
// 服务端限速改不了, 但本地这些策略方法返回超大值, 至少让 App 不再自己限速。
static NSNumber *BNHuge(void) {
    static NSNumber *v = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ v = [NSNumber numberWithLongLong:1024LL * 1024 * 1024 * 1024]; });
    return v;
}

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
static BOOL (*o_isSVIP)(id, SEL) = NULL;
static BOOL (*o_isVipAd)(id, SEL) = NULL;
static BOOL (*o_shouldSplash)(id, SEL) = NULL;
static BOOL (*o_hostSplash)(id, SEL) = NULL;
static BOOL (*o_needFG)(id, SEL) = NULL;
static BOOL (*o_fixNeedPlay)(id, SEL) = NULL;
static void (*o_showAPISplash)(id, SEL, id) = NULL;
static void (*o_showBrandSplash)(id, SEL, id) = NULL;
static id (*o_JSONData)(id, SEL, id, unsigned long, id *) = NULL;
static id (*o_JSONStream)(id, SEL, id, unsigned long, id *) = NULL;

/* ---------- Hook 实现: 限速 ---------- */
static id h_calcLimit(id self, SEL _cmd) { BNHit(@"calcLimit"); return BNHuge(); }
static id h_calcAllow(id self, SEL _cmd, BOOL a) { BNHit(@"calcAllow"); return BNHuge(); }
static id h_downLimit(id self, SEL _cmd) { BNHit(@"downLoadSpeedLimit"); return BNHuge(); }
static id h_p2pLimit(id self, SEL _cmd) { BNHit(@"p2pDownloadSpeedLimit"); return BNHuge(); }
static long long h_fileLimit(id self, SEL _cmd) { BNHit(@"downloadFileSpeedLimit"); return 1024LL*1024*1024*1024; }
static BOOL h_shouldAccess(id self, SEL _cmd) { BNHit(@"shouldAccessSpeedLimit"); return NO; }  // NO=不走限速
static BOOL h_canSpeed(id self, SEL _cmd) { BNHit(@"canSpeedUp"); return YES; }
static BOOL h_keepOrig(id self, SEL _cmd) { BNHit(@"isKeepOriginalDownloadSpeed"); return YES; }
static BOOL h_hotUser(id self, SEL _cmd) { BNHit(@"isHotUserLimit"); return NO; }
static BOOL h_isSVIP(id self, SEL _cmd) { BNHit(@"isSVIP"); return YES; }

/* ---------- Hook 实现: 去广告 ---------- */
static BOOL h_isVipAd(id self, SEL _cmd) { BNHit(@"isVipCanShowAdvertise"); return NO; }
static BOOL h_shouldSplash(id self, SEL _cmd) { BNHit(@"shouldSplashShow"); return NO; }   // 开屏总开关
static BOOL h_hostSplash(id self, SEL _cmd) { BNHit(@"shouldHostControlSplashShow"); return NO; }
static BOOL h_needFG(id self, SEL _cmd) { BNHit(@"needToShowSplashInForeground"); return NO; }
static BOOL h_fixNeedPlay(id self, SEL _cmd) { BNHit(@"fixSplashNeedPlay"); return NO; }
static void h_showAPISplash(id self, SEL _cmd, id vc) { BNHit(@"BDNCAPISplashAd.show"); /* block: 不调 orig */ }
static void h_showBrandSplash(id self, SEL _cmd, id vc) { BNHit(@"BDNCBrandSplashAd.show"); /* block */ }

/* ---------- Hook 实现: JSON 抓直链 ---------- */
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
    NSString *mark = [NSString stringWithFormat:@"loaded(v8) %@\ndocs=%@\n", [NSDate date], BNDocs()];
    [mark writeToFile:BNPath(@"bnt_loaded.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *f in @[@"bnt_hooks.txt", @"bnt_debug.txt"]) {
        if (![fm fileExistsAtPath:BNPath(f)])
            [@"" writeToFile:BNPath(f) atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    BNDebug(@"=== v8 ctor start ===");

    // === 限速方法族(旧 BaiduSpeedBoost.dylib 验证过的全部方法) ===
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

    // === SVIP + 去广告总开关 ===
    hookMethod(@"BDPanAccountInfo", @"isSVIP",                        (IMP)h_isSVIP,      (IMP*)&o_isSVIP);
    hookMethod(@"BDNCAdvertisesManage", @"isVipCanShowAdvertise",     (IMP)h_isVipAd,     (IMP*)&o_isVipAd);
    hookMethod(@"BDPanPrologueAdManager", @"shouldSplashShow",        (IMP)h_shouldSplash, (IMP*)&o_shouldSplash);
    hookMethod(@"BDPanPrologueAdManager", @"shouldHostControlSplashShow",(IMP)h_hostSplash,(IMP*)&o_hostSplash);
    hookMethod(@"BDPanGlobalSplashAdvertiseManager", @"needToShowSplashInForeground",(IMP)h_needFG,(IMP*)&o_needFG);
    hookMethod(@"BDPanVideoFixSplashAdvertiseHandler", @"needPlay",   (IMP)h_fixNeedPlay, (IMP*)&o_fixNeedPlay);
    hookMethod(@"BDNCAPISplashAd", @"showSplashViewInRootViewController:",(IMP)h_showAPISplash,(IMP*)&o_showAPISplash);
    hookMethod(@"BDNCBrandSplashAd", @"showSplashViewInRootViewController:",(IMP)h_showBrandSplash,(IMP*)&o_showBrandSplash);

    // === JSON 响应抓 dlink (类方法, 用元类 hook) ===
    Class jsonMeta = objc_getMetaClass("NSJSONSerialization");
    if (jsonMeta) {
        SEL s1 = NSSelectorFromString(@"JSONObjectWithData:options:error:");
        Method m1 = class_getClassMethod([NSJSONSerialization class], s1);
        if (m1) { MSHookMessageEx(jsonMeta, s1, (IMP)h_JSONData, (IMP*)&o_JSONData); BNDebug(@"HOOK NSJSONSerialization.data OK"); }
        SEL s2 = NSSelectorFromString(@"JSONObjectWithStream:options:error:");
        Method m2 = class_getClassMethod([NSJSONSerialization class], s2);
        if (m2) { MSHookMessageEx(jsonMeta, s2, (IMP)h_JSONStream, (IMP*)&o_JSONStream); BNDebug(@"HOOK NSJSONSerialization.stream OK"); }
    }

    BNDebug(@"=== v8 ctor end ===");
}
