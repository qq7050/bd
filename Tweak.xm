//
//  BaiduNetdiskTools — 百度网盘 iOS 13.35.5 巨魔增强（All-in-One v3）
//
//  功能:
//    1) SVIP 标志 + 完整去广告（一比一还原原 baidudisk.dylib，含所有广告管理类）
//    2) 拦截真实下载直链(dlink)写到 App 沙盒 Documents，供多线程下载器使用
//
//  写文件位置: App 沙盒 Documents（NSSearchPathForDirectoriesInDomains），
//              Filza 路径形如 /var/mobile/Containers/Data/Application/<UUID>/Documents/
//              同时写一个加载标记 bnt_loaded.txt 用于确认 tweak 是否注入成功。
//

#import <Foundation/Foundation.h>

// App 沙盒 Documents —— App 自己一定有权写
static NSString *BNDocs(void) {
    NSArray *p = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return (p.count ? p[0] : @"/var/mobile/Documents");
}
static NSString *BNLinksFile(void) { return [BNDocs() stringByAppendingPathComponent:@"baidu_links.txt"]; }
static NSString *BNDetailFile(void) { return [BNDocs() stringByAppendingPathComponent:@"baidu_dlinks.txt"]; }
static NSString *BNMarkerFile(void) { return [BNDocs() stringByAppendingPathComponent:@"bnt_loaded.txt"]; }

// 只抓真正的下载 CDN / 下载接口
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

// 角标：原 dylib 置 nil，值参数置 0/nil
%hook BDPanPersonHeaderView
- (void)setTabBadgeNumber:(id)a maxNumber:(id)b atIndex:(NSInteger)i { %orig(nil, nil, i); }
%end

%hook BDPanPersonalWalletSection
- (void)setTabBadgeNumber:(id)a maxNumber:(id)b atIndex:(NSInteger)i { %orig(nil, nil, i); }
%end

// 广告数据管理类
%hook BDNCAdvertiseDataManage
- (void)setupViews { %orig; }
%end

#pragma mark - 2. 网络层抓直链

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

%ctor {
    // 加载标记：证明 tweak 已注入并运行
    NSString *mark = [NSString stringWithFormat:@"loaded %@\ndocs=%@\n", [NSDate date], BNDocs()];
    [mark writeToFile:BNMarkerFile() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // 预建空文件，Filza 直接可见
    if (![[NSFileManager defaultManager] fileExistsAtPath:BNLinksFile()])
        [@"" writeToFile:BNLinksFile() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (![[NSFileManager defaultManager] fileExistsAtPath:BNDetailFile()])
        [@"" writeToFile:BNDetailFile() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[BNDTools] v3 loaded. docs=%@", BNDocs());
}
