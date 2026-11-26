//
//  BaiduNetdiskTools — 百度网盘 iOS 13.35.5 巨魔增强 (v5 诊断版)
//
//  v4 问题: %ctor 能写 bnt_loaded.txt, 但所有 %hook 零命中(连 SVIP 去广告都失效)。
//  v5 方案: 不用 Theos %hook, 改在 %ctor 里用 MSHookMessageEx 运行时动态 hook,
//           并把「类是否存在 / 方法是否存在 / hook 是否安装 / 方法是否被调用」
//           全部写进 bnt_debug.txt, 一次测试定位根因。
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

/* ---------- 原函数指针 ---------- */
static void (*o_down)(id, SEL, id, id, long long) = NULL;
static void (*o_start)(id, SEL) = NULL;
static void (*o_startTask)(id, SEL) = NULL;
static void (*o_dlPCS)(id, SEL) = NULL;
static void (*o_startNormal)(id, SEL) = NULL;
static id  (*o_limit)(id, SEL) = NULL;
static id  (*o_token)(id, SEL) = NULL;
static void (*o_setDlink)(id, SEL, id) = NULL;
static void (*o_setDlinkUrl)(id, SEL, id) = NULL;
static BOOL (*o_isSVIP)(id, SEL) = NULL;
static void (*o_setAdModel)(id, SEL, id) = NULL;

/* ---------- Hook 实现 ---------- */
static void h_down(id self, SEL _cmd, id p, id l, long long sz) {
    BNHit(@"DownOperation.downWithServerFullPath");
    if (p) BNUrl(p, @"downWithServerFullPath");
    if (o_down) o_down(self, _cmd, p, l, sz);
}
static void h_start(id self, SEL _cmd) {
    BNHit(@"DownOperation.start");
    if (o_start) o_start(self, _cmd);
}
static void h_startTask(id self, SEL _cmd) {
    BNHit(@"DownOperation.startDownloadTask");
    if (o_startTask) o_startTask(self, _cmd);
}
static void h_dlPCS(id self, SEL _cmd) {
    BNHit(@"DownOperation.downloadFromPCS");
    if (o_dlPCS) o_dlPCS(self, _cmd);
}
static void h_startNormal(id self, SEL _cmd) {
    BNHit(@"DownOperation.startNormalDownload");
    if (o_startNormal) o_startNormal(self, _cmd);
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
    BNHit(@"setDlink");
    if (u) BNUrl(u, @"setDlink");
    if (o_setDlink) o_setDlink(self, _cmd, u);
}
static void h_setDlinkUrl(id self, SEL _cmd, id u) {
    BNHit(@"setDlinkUrl");
    if (u) BNUrl(u, @"setDlinkUrl");
    if (o_setDlinkUrl) o_setDlinkUrl(self, _cmd, u);
}
static BOOL h_isSVIP(id self, SEL _cmd) {
    BNHit(@"BDPanAccountInfo.isSVIP");
    return YES;
}
static void h_setAdModel(id self, SEL _cmd, id a) {
    BNHit(@"BDPanActivityFloatWidget.setAdModel");
    if (o_setAdModel) o_setAdModel(self, _cmd, nil);
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
    BNDebug([NSString stringWithFormat:@"HOOK %@.%@ before=%p after=%p %@",
             clsName, selName, before, after, (after != before ? @"OK" : @"FAILED")]);
}

%ctor {
    NSString *mark = [NSString stringWithFormat:@"loaded(v5) %@\ndocs=%@\n", [NSDate date], BNDocs()];
    [mark writeToFile:BNPath(@"bnt_loaded.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *f in @[@"bnt_hooks.txt", @"bnt_debug.txt", @"baidu_links.txt", @"baidu_dlinks.txt"]) {
        if (![fm fileExistsAtPath:BNPath(f)])
            [@"" writeToFile:BNPath(f) atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    BNDebug(@"=== v5 ctor start ===");

    // 诊断: 关键类是否注册
    for (NSString *cn in @[@"BDPanAccountInfo", @"DownOperation", @"FolderDownOperation",
                           @"ResourceDownOperation", @"BDPMDownloadOperation",
                           @"BDPMFileDownloadModel", @"BDPBridgeAlbumFileDlinkItem",
                           @"BDPanFileDownloadEngine"]) {
        BNDebug([NSString stringWithFormat:@"class %@ = %@",
                 cn, objc_getClass(cn.UTF8String) ? @"YES" : @"NO"]);
    }

    // 安装 hook
    hookMethod(@"DownOperation", @"downWithServerFullPath:localFullPath:downsize:", (IMP)h_down,  (IMP*)&o_down);
    hookMethod(@"DownOperation", @"start",                    (IMP)h_start,      (IMP*)&o_start);
    hookMethod(@"DownOperation", @"startDownloadTask",        (IMP)h_startTask,  (IMP*)&o_startTask);
    hookMethod(@"DownOperation", @"downloadFromPCS",          (IMP)h_dlPCS,      (IMP*)&o_dlPCS);
    hookMethod(@"DownOperation", @"startNormalDownload",      (IMP)h_startNormal,(IMP*)&o_startNormal);
    hookMethod(@"DownOperation", @"calucateDownloadSpeedLimit",(IMP)h_limit,     (IMP*)&o_limit);
    hookMethod(@"DownOperation", @"speedUpToken",             (IMP)h_token,      (IMP*)&o_token);
    hookMethod(@"BDPMDownloadOperation", @"setDlinkUrl:",      (IMP)h_setDlinkUrl,(IMP*)&o_setDlinkUrl);
    hookMethod(@"BDPMFileDownloadModel", @"setDlink:",         (IMP)h_setDlink,   (IMP*)&o_setDlink);
    hookMethod(@"BDPBridgeAlbumFileDlinkItem", @"setDlink:",   (IMP)h_setDlink,   (IMP*)&o_setDlink);
    hookMethod(@"BDPanAccountInfo", @"isSVIP",                 (IMP)h_isSVIP,     (IMP*)&o_isSVIP);
    hookMethod(@"BDPanActivityFloatWidget", @"setAdModel:",    (IMP)h_setAdModel, (IMP*)&o_setAdModel);

    BNDebug(@"=== v5 ctor end ===");
}
