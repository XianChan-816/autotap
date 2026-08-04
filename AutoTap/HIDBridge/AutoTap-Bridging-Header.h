//
//  AutoTap-Bridging-Header.h
//  AutoTap
//
//  将 HID 注入层（Objective-C）暴露给 Swift 使用
//

#ifndef AutoTap_Bridging_Header_h
#define AutoTap_Bridging_Header_h

#import "HIDBridge.h"

// ---- 枚举已安装 App / 打开目标 App（私有 API，TrollStore 环境可用）----
@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allApplications;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end

#endif /* AutoTap_Bridging_Header_h */
