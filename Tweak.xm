//
//  BaiduNetdiskTools — 百度网盘 iOS 13.35.5 巨魔增强 (v6)
//
//  v5 结论: hook 机制完全成功(11个HOOK全OK, isSVIP/start/startDownloadTask命中),
//           但下载走 P2P 路径, downWithServerFullPath/setDlink 都没触发。
//  v6 方案:
//   1) 在 start/startDownloadTask 命中时, 直接 dump DownOperation 实例的 dlink 相关 ivar
//      (_dlink/_dlinkUrl/_serverFullPath/_downloadCDNHost/_downloadCDNPath/...),
//      不管它走哪条下载路径都能拿到直链。
//   2) 补 hook P2P 下载路径: startP2PUniversalDownload / startP2PNormalDownload
//   3) 修广告 hook: 用真实存在的 BDNCAdvertiseDataManage.setAdModel: 等
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
static void BNUrl(id obj, NSString *tag) {
    NSString *s = nil;
    if ([obj isKindOfClass:[NSString class]]) s = (NSString *)obj;
    else if ([obj isKindOfClass:[NSURL class]]) s = [(NSURL *)obj absoluteString];
    else if (obj) s = [obj description];
    if (!s.length) return;
    BNAppend(@"baidu_links.txt", s);
    BNAppend(@"baidu_dlinks.txt", [NSString stringWithFormat:@"%@\t[%@]", s, tag]);
}

/* ---------- 核心: dump 对象 ivar 里的直链 ---------- */
static BOOL BNInterestingIvar(NSString *name) {
    NSString *s = [name lowercaseString];
    NSArray *kw = @[@"dlink", @"dlinkurl", @"serverfullpath", @"downloadcdn",
                    @"downloadurl", @"downloadlink", @"downpath", @"url", @"link", @"source"];
    for (NSString *k in kw) if ([s rangeOfString:k].location != NSNotFound) return YES;
    return NO;
}
// 把一个值转成安全字符串(NSString/NSURL/NSNumber), 其它对象一律不碰
static NSString *BNSafeString(id val) {
    if ([val isKindOfClass:[NSString class]]) return (NSString *)val;
    if ([val isKindOfClass:[NSURL class]]) return [(NSURL *)val absoluteString];
    if ([val isKindOfClass:[NSNumber class]]) return [(NSNumber *)val stringValue];
    return nil;
}
static void BNRecordField(NSString *tag, NSString *name, NSString *s) {
    if (!s.length) return;
    BNAppend(@"bnt_debug.txt", [NSString stringWithFormat:@"  %@.%@ = %@", tag, name, s]);
    if ([s hasPrefix:@"http"]) BNUrl(s, [NSString stringWithFormat:@"%@.%@", tag, name]);
    if ([name rangeOfString:@"serverfullpath" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [name rangeOfString:@"cdnpath" options:NSCaseInsensitiveSearch].location != NSNotFound)
        BNAppend(@"baidu_dlinks.txt", [NSString stringWithFormat:@"PATH(%@.%@): %@", tag, name, s]);
}
static void BNDumpIvars(id obj, NSString *tag) {
    if (!obj) return;
    BNAppend(@"bnt_debug.txt", [NSString stringWithFormat:@"DUMP BEGIN [%@] class=%@", tag, object_getClass(obj)]);

    // 方法1: KVC 取值(最安全, 自动搜索父类, 基本类型返回NSNumber包装不崩)
    // 直接按已知 key 取, 覆盖 dlink / serverFullPath / CDN 路径等全部关键字段
    NSArray *keys = @[@"dlink", @"dlinkUrl", @"dLink", @"dlinkURL",
                      @"serverFullPath", @"fileServerFullPath", @"associatedServerFullPath",
                      @"downloadCDNHost", @"downloadCDNPath", @"downloadCDNServerList", @"downloadCDNClientIp",
                      @"downloadUrl", @"downloadURL", @"downloadLink", @"downLoadLink",
                      @"dlinkVideoExt", @"dlinkVideoFileId", @"dlinkVideoStoryId",
                      @"encrypt_dlink", @"taskDownloadUrl", @"currentDownUrlArray"];
    for (NSString *k in keys) {
        id val = nil;
        @try { val = [obj valueForKey:k]; }
        @catch (NSException *e) { continue; }
        NSString *s = BNSafeString(val);
        BNRecordField(tag, k, s);
    }

    // 方法2: 逐层遍历继承链的 ivar, 只取对象类型(@)且非block, 避免野指针崩溃
    Class cls = object_getClass(obj);
    int depth = 0;
    while (cls && depth < 8) {
        unsigned int n = 0;
        Ivar *ivars = class_copyIvarList(cls, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *cn = ivar_getName(ivars[i]);
            if (!cn) continue;
            NSString *name = [NSString stringWithUTF8String:cn];
            if (!BNInterestingIvar(name)) continue;
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@' || type[1] == '?') continue;  // 跳过基本类型/block
            id val = nil;
            @try { val = object_getIvar(obj, ivars[i]); }
            @catch (NSException *e) { continue; }
            NSString *s = BNSafeString(val);
            if (s.length) BNRecordField(tag, [NSString stringWithFormat:@"ivar:%@", name], s);
        }
        free(ivars);
        cls = class_getSuperclass(cls);
        depth++;
    }
    BNAppend(@"bnt_debug.txt", [NSString stringWithFormat:@"DUMP END [%@] depth=%d", tag, depth]);
}

/* ---------- 原函数指针 ---------- */
static void (*o_down)(id, SEL, id, id, long long) = NULL;
static void (*o_start)(id, SEL) = NULL;
static void (*o_startTask)(id, SEL) = NULL;
static void (*o_dlPCS)(id, SEL) = NULL;
static void (*o_startNormal)(id, SEL) = NULL;
static void (*o_p2pUni)(id, SEL) = NULL;
static void (*o_p2pNormal)(id, SEL) = NULL;
static id  (*o_limit)(id, SEL) = NULL;
static id  (*o_token)(id, SEL) = NULL;
static void (*o_setDlink)(id, SEL, id) = NULL;
static void (*o_setDlinkUrl)(id, SEL, id) = NULL;
static BOOL (*o_isSVIP)(id, SEL) = NULL;
static void (*o_setAdModel)(id, SEL, id) = NULL;
static void (*o_setupAlert)(id, SEL) = NULL;
static void (*o_setupViews)(id, SEL) = NULL;
static BOOL (*o_isVipAd)(id, SEL) = NULL;

/* ---------- Hook 实现 ---------- */
static void h_down(id self, SEL _cmd, id p, id l, long long sz) {
    BNHit(@"DownOperation.downWithServerFullPath");
    if (p) BNUrl(p, @"downWithServerFullPath");
    if (o_down) o_down(self, _cmd, p, l, sz);
}
static void h_start(id self, SEL _cmd) {
    BNHit(@"DownOperation.start");
    BNDumpIvars(self, @"start");
    if (o_start) o_start(self, _cmd);
}
static void h_startTask(id self, SEL _cmd) {
    BNHit(@"DownOperation.startDownloadTask");
    BNDumpIvars(self, @"startDownloadTask");
    if (o_startTask) o_startTask(self, _cmd);
}
static void h_dlPCS(id self, SEL _cmd) {
    BNHit(@"DownOperation.downloadFromPCS");
    BNDumpIvars(self, @"downloadFromPCS");
    if (o_dlPCS) o_dlPCS(self, _cmd);
}
static void h_startNormal(id self, SEL _cmd) {
    BNHit(@"DownOperation.startNormalDownload");
    BNDumpIvars(self, @"startNormalDownload");
    if (o_startNormal) o_startNormal(self, _cmd);
}
static void h_p2pUni(id self, SEL _cmd) {
    BNHit(@"DownOperation.startP2PUniversalDownload");
    BNDumpIvars(self, @"startP2PUniversalDownload");
    if (o_p2pUni) o_p2pUni(self, _cmd);
}
static void h_p2pNormal(id self, SEL _cmd) {
    BNHit(@"DownOperation.startP2PNormalDownload");
    BNDumpIvars(self, @"startP2PNormalDownload");
    if (o_p2pNormal) o_p2pNormal(self, _cmd);
}
static id h_limit(id self, SEL _cmd) {
    BNHit(@"DownOperation.calucateDownloadSpeedLimit");
    id r = o_limit ? o_limit(self, _cmd) : nil;
    BNDebug([NSString stringWithFormat:@"speedLimit=%@", r]);
    return r;
}
static id h_token(id self, SEL _cmd) {
    BNHit(@"DownOperation.speedUpToken");
    id r = o_token ? o_token(self, _cmd) : nil;
    BNDebug([NSString stringWithFormat:@"speedUpToken=%@", r]);
    return r;
}
static void h_setDlink(id self, SEL _cmd, id u) {
    BNHit(@"setDlink"); if (u) BNUrl(u, @"setDlink");
    if (o_setDlink) o_setDlink(self, _cmd, u);
}
static void h_setDlinkUrl(id self, SEL _cmd, id u) {
    BNHit(@"setDlinkUrl"); if (u) BNUrl(u, @"setDlinkUrl");
    if (o_setDlinkUrl) o_setDlinkUrl(self, _cmd, u);
}
static BOOL h_isSVIP(id self, SEL _cmd) { BNHit(@"BDPanAccountInfo.isSVIP"); return YES; }
static BOOL h_isVipAd(id self, SEL _cmd) { BNHit(@"isVipCanShowAdvertise"); return NO; }
static void h_setAdModel(id self, SEL _cmd, id a) {
    BNHit(@"BDNCAdvertiseDataManage.setAdModel");
    // 传原值给 orig, 不置 nil(置 nil 可能让 orig 内部解引用崩溃)。去广告靠 isVipCanShowAdvertise=NO
    if (o_setAdModel) o_setAdModel(self, _cmd, a);
}
static void h_setupAlert(id self, SEL _cmd) {
    BNHit(@"BDPanAdvertiseVideoAlertViewController.setupAlertView");
    if (o_setupAlert) o_setupAlert(self, _cmd);
}
static void h_setupViews(id self, SEL _cmd) {
    BNHit(@"BDPanFlowPlayerAdvertiseView.setupViews");
    if (o_setupViews) o_setupViews(self, _cmd);
}
// (o_setupAlert / o_setupViews 已在上方原函数指针区声明)

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
    NSString *mark = [NSString stringWithFormat:@"loaded(v7) %@\ndocs=%@\n", [NSDate date], BNDocs()];
    [mark writeToFile:BNPath(@"bnt_loaded.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *f in @[@"bnt_hooks.txt", @"bnt_debug.txt", @"baidu_links.txt", @"baidu_dlinks.txt"]) {
        if (![fm fileExistsAtPath:BNPath(f)])
            [@"" writeToFile:BNPath(f) atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    BNDebug(@"=== v6 ctor start ===");

    // 下载主路径 + P2P
    hookMethod(@"DownOperation", @"downWithServerFullPath:localFullPath:downsize:", (IMP)h_down,  (IMP*)&o_down);
    hookMethod(@"DownOperation", @"start",                     (IMP)h_start,     (IMP*)&o_start);
    hookMethod(@"DownOperation", @"startDownloadTask",         (IMP)h_startTask, (IMP*)&o_startTask);
    hookMethod(@"DownOperation", @"downloadFromPCS",           (IMP)h_dlPCS,     (IMP*)&o_dlPCS);
    hookMethod(@"DownOperation", @"startNormalDownload",       (IMP)h_startNormal,(IMP*)&o_startNormal);
    hookMethod(@"DownOperation", @"startP2PUniversalDownload", (IMP)h_p2pUni,    (IMP*)&o_p2pUni);
    hookMethod(@"DownOperation", @"startP2PNormalDownload",    (IMP)h_p2pNormal, (IMP*)&o_p2pNormal);
    hookMethod(@"DownOperation", @"calucateDownloadSpeedLimit",(IMP)h_limit,     (IMP*)&o_limit);
    hookMethod(@"DownOperation", @"speedUpToken",              (IMP)h_token,     (IMP*)&o_token);
    hookMethod(@"BDPMDownloadOperation", @"setDlinkUrl:",       (IMP)h_setDlinkUrl,(IMP*)&o_setDlinkUrl);
    hookMethod(@"BDPMFileDownloadModel", @"setDlink:",          (IMP)h_setDlink,  (IMP*)&o_setDlink);
    hookMethod(@"BDPBridgeAlbumFileDlinkItem", @"setDlink:",    (IMP)h_setDlink,  (IMP*)&o_setDlink);
    // SVIP + 去广告(用真实方法名)
    hookMethod(@"BDPanAccountInfo", @"isSVIP",                  (IMP)h_isSVIP,    (IMP*)&o_isSVIP);
    hookMethod(@"BDNCAdvertisesManage", @"isVipCanShowAdvertise",(IMP)h_isVipAd,  (IMP*)&o_isVipAd);
    hookMethod(@"BDNCAdvertiseDataManage", @"setAdModel:",      (IMP)h_setAdModel,(IMP*)&o_setAdModel);
    hookMethod(@"BDPanAdvertiseVideoAlertViewController", @"setupAlertView", (IMP)h_setupAlert, (IMP*)&o_setupAlert);
    hookMethod(@"BDPanFlowPlayerAdvertiseView", @"setupViews",  (IMP)h_setupViews, (IMP*)&o_setupViews);

    BNDebug(@"=== v6 ctor end ===");
}
