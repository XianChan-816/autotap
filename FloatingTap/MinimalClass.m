//
//  MinimalClass.m
//  FloatingTap
//
//  ⚠️ v1.0.12 二分诊断：一个空的 ObjC 类。
//  目的：区分「任何 ObjC 类在设备上注入都会卡」vs「HIDInject.m 具体内容导致卡」。
//  - 空类也卡 → 设备/注入环境对 ObjC 类加载有问题（查 Dopamine/ellekit/Hestia）
//  - 空类不卡 → HIDInject.m 的具体代码有问题（再深挖）
//

#import <Foundation/Foundation.h>

@interface FTMinimalClass : NSObject
@end

@implementation FTMinimalClass
@end
