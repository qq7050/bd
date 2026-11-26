//
//  BaiduNetdiskTools — 百度网盘 iOS 13.35.5 巨魔增强（All-in-One）
//
//  为什么改版:
//    旧版 BaiduSpeedBoost 只 hook 客户端限速数值, 但百度下载带宽是服务端按账号
//    等级下发的, 本地改数值堵不住 CDN 闸门 —— 实测两个 dylib 都注入仍无加速。
//    本版删除无效的限速数值 hook, 改为导出服务端签发的真实下载直链(dlink),
//    交给多线程下载器(Alook / 1DM / aria2)突破单连接限速。
//
//  功能:
//    1) 保留原 baidudisk.dylib 的 SVIP 标志 + 去广告(看高清/去广告继续有效)
//    2) 拦截 NSURLSession / NSURLConnection 的下载请求, 把含签名的真实直链
//       连同请求头写入 /var/mobile/Documents/baidu_dlinks.txt, 供外部多线程下载
//
//  重要: 直链带时效(通常十几分钟~数小时)且绑定 Cookie/UA, 导出后尽快用,
//        用 Filza 复制整行到下载器, 并保留 headers 里的 Cookie/User-Agent。
//

#import <Foundation/Foundation.h>

static NSString *const kOutPath = @"/var/mobile/Documents/baidu_dlinks.txt";
static NSString *const kLinkFile = @"/var/mobile/Documents/baidu_links.txt";

// 只抓真正的下载 CDN / 下载接口, 不碰登录/API 流量
static BOOL BDISDownloadURL(NSURL *u) {
    if (!u) return NO;
    NSString *s = [[u absoluteString] lowercaseString];
    if ([s containsString:@"d.pcs.baidu.com"] ||
        [s containsString:@"d-drive.pcs.baidu.com"] ||
        [s containsString:@"issuecdn.baidupcs.com"] ||
        [s containsString:@"sdata.baidupcs.com"] ||
        [s containsString:@"netdisk-wps.baidupcs.com"] ||
        [s containsString:@"cdndoc.pcs.baidu.com"] ||
        [s containsString:@"/rest/2.0/pcs/file"] ||
        [s containsString:@"method=download"]) {
        return YES;
    }
    return NO;
}

// 把请求序列化成一行可复制文本: URL 【TAB】 Header1: v1 【TAB】 ...
static NSString *BDSerializeRequest(NSURLRequest *req) {
    NSMutableString *out = [NSMutableString string];
    [out appendString:req.URL.absoluteString ?: @""];
    NSDictionary *h = req.allHTTPHeaderFields;
    for (NSString *k in h) {
        [out appendFormat:@"\t%@: %@", k, [h objectForKey:k]];
    }
    return out;
}

static void BDAppendLine(NSString *line) {
    NSString *content = [NSString stringWithContentsOfFile:kOutPath encoding:NSUTF8StringEncoding error:nil];
    if (!content) content = @"";
    // 去重: 同一条直链不重复写
    if ([content rangeOfString:line].location != NSNotFound) return;
    NSString *ns = [content length] ? [content stringByAppendingFormat:@"\n%@", line] : line;
    [ns writeToFile:kOutPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// 额外: 只写纯 URL 列表, 方便直接复制
static void BDAppendUrl(NSString *url) {
    NSString *content = [NSString stringWithContentsOfFile:kLinkFile encoding:NSUTF8StringEncoding error:nil];
    if (!content) content = @"";
    if ([content rangeOfString:url].location != NSNotFound) return;
    NSString *ns = [content length] ? [content stringByAppendingFormat:@"\n%@", url] : url;
    [ns writeToFile:kLinkFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void BDHandleRequest(NSURLRequest *req) {
    if (!BDISDownloadURL(req.URL)) return;
    NSString *url = req.URL.absoluteString;
    if (![url length]) return;
    BDAppendUrl(url);
    BDAppendLine(BDSerializeRequest(req));
    NSLog(@"[BNDTools] dlink captured: %@", [url substringToIndex:MIN((NSUInteger)160, [url length])]);
}

#pragma mark - 1. SVIP + 去广告（保留原 baidudisk.dylib 功能）

%hook BDPanAccountInfo
- (BOOL)isSVIP { return YES; }
- (BOOL)isVipCanShowAdvertise { return NO; }
- (NSInteger)vipLevel { return 10; }
%end

%hook BDPanActivityFloatWidget
- (void)setAdModel:(id)arg1 { %orig(nil); }
%end

%hook BDPanHridWebViewController
- (void)setSplashWindow:(id)arg1 { %orig(nil); }
%end

// 角标方法参数类型未知, 原样透传避免类型错配崩溃; 优先保证直链抓取主功能稳定
%hook BDPanPersonHeaderView
- (void)setTabBadgeNumber:(id)arg1 maxNumber:(id)arg2 atIndex:(NSInteger)arg3 { %orig; }
%end

%hook BDPanPersonalWalletSection
- (void)setTabBadgeNumber:(id)arg1 maxNumber:(id)arg2 atIndex:(NSInteger)arg3 { %orig; }
%end

#pragma mark - 2. 网络层抓真实下载直链

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)req {
    BDHandleRequest(req);
    return %orig;
}
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)req {
    BDHandleRequest(req);
    return %orig;
}
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url {
    if (BDISDownloadURL(url)) {
        NSURLRequest *r = [NSURLRequest requestWithURL:url];
        BDHandleRequest(r);
    }
    return %orig;
}
- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url {
    if (BDISDownloadURL(url)) {
        NSURLRequest *r = [NSURLRequest requestWithURL:url];
        BDHandleRequest(r);
    }
    return %orig;
}
%end

%hook NSURLConnection
+ (NSURLConnection *)connectionWithRequest:(NSURLRequest *)req delegate:(id)del {
    BDHandleRequest(req);
    return %orig;
}
- (id)initWithRequest:(NSURLRequest *)req delegate:(id)del {
    BDHandleRequest(req);
    return %orig;
}
%end

%ctor {
    // 初始化空文件, 便于 Filza 直接找到
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kOutPath]) [@"" writeToFile:kOutPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (![fm fileExistsAtPath:kLinkFile]) [@"" writeToFile:kLinkFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[BNDTools] loaded. dlink -> %@", kOutPath);
}
