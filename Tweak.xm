//
//  BaiduNetdiskTools — 百度网盘 iOS 13.35.5 巨魔增强（All-in-One v4）
//
//  功能:
//    1) SVIP 标志 + 完整去广告（一比一还原原 baidudisk.dylib）
//    2) 抓真实下载直链(dlink)到 App 沙盒 Documents，供多线程下载器使用
//
//  v4 变更: 系统层 NSURLSession/NSURLConnection hook 抓不到（13.35.5 走自研网络库）。
//           改为直接 hook 百度自己的下载类:
//             BDPMDownloadOperation.setDlinkUrl:   / startDownTaskUrl:
//             BDPMFileDownloadModel.setDlink:
//             BDPBridgeAlbumFileDlinkItem.setDlink:
//             DownOperation.downWithServerFullPath:localFullPath:downsize:
//           无论底层网络怎么封装，直链必定流经这些入口。
//           另写 bnt_hooks.txt 记录哪个 hook 命中，便于诊断。
//
//  写文件位置: App 沙盒 Documents (NSSearchPathForDirectoriesInDomains)
//
#import <Foundation/Foundation.h>

static NSString *BNDocs(void) {
    NSArray *p = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return (p.count ? p[0] : @"/var/mobile/Documents");
}
static NSString *BNLinksFile(void)   { return [BNDocs() stringByAppendingPathComponent:@"baidu_links.txt"]; }
static NSString *BNDetailFile(void)  { return [BNDocs() stringByAppendingPathComponent:@"baidu_dlinks.txt"]; }
static NSString *BNMarkerFile(void)  { return [BNDocs() stringByAppendingPathComponent:@"bnt_loaded.txt"]; }
static NSString *BNHookFile(void)    { return [BNDocs() stringByAppendingPathComponent:@"bnt_hooks.txt"]; }

static BOOL BNIsDownloadURL(NSURL *u) {
    if (!u) return NO;
    NSString *s = [[u absoluteString] lowercaseString];
    if ([s containsString:@"d.pcs.baidu.com"] ||
        [s containsString:@"d-drive.pcs.baidu.com"] ||
        [s containsString:@"issuecdn.baidupcs.com"] ||
        [s containsString:@"sdata.baidupcs.com"] ||
        [s containsString:@"netdisk-wps.baidupcs.com"] ||
        [s containsString:@"cdndoc.pcs.baidu.com"] ||
        [s containsString:@"/rest/2.0/pcs/file"] ||
        [s containsString:@"method=download"]) return YES;
    return NO;
}

static void BNAppendText(NSString *path, NSString *line) {
    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!old) old = @"";
    if ([old rangeOfString:line].location != NSNotFound) return;
    NSString *ns = old.length ? [old stringByAppendingFormat:@"\n%@", line] : line;
    [ns writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// 记录 hook 命中（诊断：确认类级 hook 是否真的触发）
static void BNMarkHook(NSString *tag) {
    BNAppendText(BNHookFile(), [NSString stringWithFormat:@"HIT %@", tag]);
}

// 通用：把一个可能是 URL 的对象写文件（NSString / NSURL 都支持）
static void BNRecordURL(id obj, NSString *tag) {
    BNMarkHook(tag);
    NSString *s = nil;
    if ([obj isKindOfClass:[NSString class]]) s = (NSString *)obj;
    else if ([obj isKindOfClass:[NSURL class]]) s = [(NSURL *)obj absoluteString];
    if (!s.length) return;
    if ([s hasPrefix:@"http://"] || [s hasPrefix:@"https://"]) {
        BNAppendText(BNLinksFile(), s);
        BNAppendText(BNDetailFile(), [NSString stringWithFormat:@"%@\t[%@]", s, tag]);
    } else {
        // 非完整 URL（如 serverFullPath）也记录，便于诊断
        BNAppendText(BNDetailFile(), [NSString stringWithFormat:@"RAW(%@): %@", tag, s]);
    }
}

static void BNHandleRequest(NSURLRequest *req) {
    if (!BNIsDownloadURL(req.URL)) return;
    NSString *url = req.URL.absoluteString;
    if (!url.length) return;
    BNAppendText(BNLinksFile(), url);
    NSMutableString *detail = [NSMutableString stringWithString:url];
    NSDictionary *h = req.allHTTPHeaderFields;
    for (NSString *k in h) [detail appendFormat:@"\t%@: %@", k, h[k]];
    BNAppendText(BNDetailFile(), detail);
}

#pragma mark - 1. SVIP + 完整去广告（一比一还原原 dylib）

%hook BDPanAccountInfo
- (BOOL)isSVIP { return YES; }
- (BOOL)isVipCanShowAdvertise { return NO; }
- (BOOL)hasPurchasedAdFree { return YES; }
- (NSInteger)vipLevel { return 10; }
%end

%hook BDPanActivityFloatWidget
- (void)setAdModel:(id)a { %orig(nil); }
%end

%hook BDPanHridWebViewController
- (void)setSplashWindow:(id)a { %orig(nil); }
%end

%hook BDPanPersonHeaderView
- (void)setTabBadgeNumber:(id)a maxNumber:(id)b atIndex:(NSInteger)i { %orig(nil, nil, i); }
%end

%hook BDPanPersonalWalletSection
- (void)setTabBadgeNumber:(id)a maxNumber:(id)b atIndex:(NSInteger)i { %orig(nil, nil, i); }
%end

%hook BDNCAdvertiseDataManage
- (void)setupViews { %orig; }
%end

#pragma mark - 2a. 系统网络层（兜底，v3 保留）

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)r { BNHandleRequest(r); return %orig; }
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)r { BNHandleRequest(r); return %orig; }
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)u {
    if (BNIsDownloadURL(u)) BNHandleRequest([NSURLRequest requestWithURL:u]);
    return %orig;
}
- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)u {
    if (BNIsDownloadURL(u)) BNHandleRequest([NSURLRequest requestWithURL:u]);
    return %orig;
}
%end

%hook NSURLConnection
+ (NSURLConnection *)connectionWithRequest:(NSURLRequest *)r delegate:(id)del { BNHandleRequest(r); return %orig; }
- (id)initWithRequest:(NSURLRequest *)r delegate:(id)del { BNHandleRequest(r); return %orig; }
%end

#pragma mark - 2b. 百度自研下载类（v4 核心：直链必经入口）

%hook BDPMDownloadOperation
// 直链 setter：服务器返回 dlink 后写入
- (void)setDlinkUrl:(id)url { BNRecordURL(url, @"BDPMDownloadOperation.setDlinkUrl"); %orig; }
// 下载任务启动：直接拿到要下载的 URL
- (void)startDownTaskUrl:(id)url { BNRecordURL(url, @"BDPMDownloadOperation.startDownTaskUrl"); %orig; }
%end

%hook BDPMFileDownloadModel
- (void)setDlink:(id)url { BNRecordURL(url, @"BDPMFileDownloadModel.setDlink"); %orig; }
%end

%hook BDPBridgeAlbumFileDlinkItem
- (void)setDlink:(id)url { BNRecordURL(url, @"BDPBridgeAlbumFileDlinkItem.setDlink"); %orig; }
%end

%hook DownOperation
// serverFullPath 是下载源路径，部分场景直接是完整 URL
- (void)downWithServerFullPath:(id)path localFullPath:(id)local downsize:(long long)size {
    BNRecordURL(path, @"DownOperation.downWithServerFullPath");
    %orig;
}
%end

%ctor {
    NSString *mark = [NSString stringWithFormat:@"loaded(v4) %@\ndocs=%@\n", [NSDate date], BNDocs()];
    [mark writeToFile:BNMarkerFile() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:BNLinksFile()])
        [@"" writeToFile:BNLinksFile() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (![fm fileExistsAtPath:BNDetailFile()])
        [@"" writeToFile:BNDetailFile() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (![fm fileExistsAtPath:BNHookFile()])
        [@"bnt_hooks: which dlink hook fired\n" writeToFile:BNHookFile() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[BNDTools] v4 loaded. docs=%@", BNDocs());
}
