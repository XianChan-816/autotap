//
//  HIDBridge.m
//  AutoTap
//
//  私有 API 声明（IOHIDEvent 系列）：
//  IOKit.framework 公开了 IOHIDEvent 系统事件，但"向系统注入触摸"这一路径
//  属于私有能力：需要 platform-application + no-sandbox + hid.system.server-access
//  等 entitlement，并直接构造 IOHIDEvent 对象派发到 IOHIDEventSystemClient。
//
//  坐标以"竖屏 home 在下"的原生屏幕尺寸归一化（0~1），由上层负责方向换算。
//

#import "HIDBridge.h"
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <dlfcn.h>

// MARK: - 私有类型与常量
//
// 不导入 IOKit 头文件（iOS SDK 中 DispatchEvent 等为私有），
// 全部使用本地定义，AT_ 前缀避免与 SDK 公开 typedef 冲突。

typedef struct __IOHIDEvent * AT_IOHIDEventRef;
typedef struct __IOHIDEventSystemClient * AT_IOHIDEventSystemClientRef;
typedef struct __IOHIDService * AT_IOHIDServiceRef;
typedef int32_t AT_IOReturn;
typedef uint32_t AT_IOOptionBits;
static const AT_IOReturn AT_kIOReturnSuccess = 0;

typedef void (*AT_IOHIDSystemCallback)(void *target, void *refcon, AT_IOHIDServiceRef service, AT_IOHIDEventRef event);
typedef void (*AT_IOHIDServiceCallback)(void *target, void *refcon, AT_IOHIDEventRef event);

/* 事件类型（本地前缀，避免与 SDK IOKit 头中的同名枚举冲突） */
typedef CF_ENUM(uint32_t, AT_IOHIDEventType) {
    AT_kIOHIDEventTypeNULL = 0,
    AT_kIOHIDEventTypeDigitizer = 11,
};

/* 触控 digitizer 事件位掩码（本地前缀，值参考私有头 IOHIDEventTypes.h） */
typedef NS_OPTIONS(uint32_t, AT_IOHIDDigitizerEventMask) {
    AT_kIOHIDDigitizerEventRange       = 0x00000001,
    AT_kIOHIDDigitizerEventTouch       = 0x00000002,
    AT_kIOHIDDigitizerEventPosition    = 0x00000004,
    AT_kIOHIDDigitizerEventTip         = 0x00000008,
    AT_kIOHIDDigitizerEventIdentity    = 0x00000010,
    AT_kIOHIDDigitizerEventAttribute   = 0x00000020,
    AT_kIOHIDDigitizerEventCancel      = 0x00000040,
    AT_kIOHIDDigitizerEventResting     = 0x00000080,
    AT_kIOHIDDigitizerEventFromEdge    = 0x00000100,
    AT_kIOHIDDigitizerEventWillPause   = 0x00000200,
};

// MARK: - 私有函数指针（运行时解析，避免直接链接私有符号）

static AT_IOHIDEventRef (*p_IOHIDEventCreateDigitizerEvent)(CFAllocatorRef,
                                                           uint64_t timeStamp,
                                                           AT_IOHIDEventType type,
                                                           uint32_t options,
                                                           uint32_t index,
                                                           uint32_t identity,
                                                           uint32_t eventMask,
                                                           uint32_t buttonMask,
                                                           double x,
                                                           double y,
                                                           double z,
                                                           double tipPressure,
                                                           double barrelPressure,
                                                           Boolean range,
                                                           Boolean touch,
                                                           AT_IOOptionBits optionsBits);

static AT_IOHIDEventRef (*p_IOHIDEventCreateDigitizerFingerEvent)(CFAllocatorRef,
                                                                 uint64_t timeStamp,
                                                                 uint32_t index,
                                                                 uint32_t identity,
                                                                 uint32_t eventMask,
                                                                 uint32_t buttonMask,
                                                                 double x,
                                                                 double y,
                                                                 double z,
                                                                 double tipPressure,
                                                                 double twist,
                                                                 Boolean range,
                                                                 Boolean touch,
                                                                 AT_IOOptionBits optionsBits);

static AT_IOHIDEventSystemClientRef (*p_IOHIDEventSystemClientCreate)(CFAllocatorRef);
static AT_IOReturn (*p_IOHIDEventSystemClientDispatchEvent)(AT_IOHIDEventSystemClientRef, AT_IOHIDEventRef);
static void (*p_IOHIDEventAppendEvent)(AT_IOHIDEventRef, AT_IOHIDEventRef, AT_IOOptionBits);
static void (*p_IOHIDEventSetSenderID)(AT_IOHIDEventRef, uint64_t);
static void (*p_IOHIDEventSetTimeStamp)(AT_IOHIDEventRef, uint64_t);

@interface HIDBridge ()
@property (nonatomic, assign) AT_IOHIDEventSystemClientRef client;
@end

@implementation HIDBridge

+ (instancetype)shared {
    static HIDBridge *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[HIDBridge alloc] init];
    });
    return instance;
}

- (void)dealloc {
    [self disconnect];
}

// MARK: - 符号解析

- (BOOL)loadSymbols {
    static BOOL loaded = NO;
    if (loaded) return YES;

    // IOKit 私有接口实际上位于 libIOKit.dylib / IOKit.framework
    void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!handle) handle = dlopen("/usr/lib/libIOKit.dylib", RTLD_LAZY);
    if (!handle) return NO;

    p_IOHIDEventCreateDigitizerEvent =
        (typeof(p_IOHIDEventCreateDigitizerEvent))dlsym(handle, "IOHIDEventCreateDigitizerEvent");
    p_IOHIDEventCreateDigitizerFingerEvent =
        (typeof(p_IOHIDEventCreateDigitizerFingerEvent))dlsym(handle, "IOHIDEventCreateDigitizerFingerEvent");
    p_IOHIDEventSystemClientCreate =
        (typeof(p_IOHIDEventSystemClientCreate))dlsym(handle, "IOHIDEventSystemClientCreate");
    p_IOHIDEventSystemClientDispatchEvent =
        (typeof(p_IOHIDEventSystemClientDispatchEvent))dlsym(handle, "IOHIDEventSystemClientDispatchEvent");
    p_IOHIDEventAppendEvent =
        (typeof(p_IOHIDEventAppendEvent))dlsym(handle, "IOHIDEventAppendEvent");
    p_IOHIDEventSetSenderID =
        (typeof(p_IOHIDEventSetSenderID))dlsym(handle, "IOHIDEventSetSenderID");
    p_IOHIDEventSetTimeStamp =
        (typeof(p_IOHIDEventSetTimeStamp))dlsym(handle, "IOHIDEventSetTimeStamp");

    loaded = (p_IOHIDEventCreateDigitizerEvent &&
              p_IOHIDEventCreateDigitizerFingerEvent &&
              p_IOHIDEventSystemClientCreate &&
              p_IOHIDEventSystemClientDispatchEvent &&
              p_IOHIDEventAppendEvent &&
              p_IOHIDEventSetSenderID &&
              p_IOHIDEventSetTimeStamp);
    return loaded;
}

// MARK: - 连接

- (BOOL)isConnected {
    return self.client != NULL;
}

- (BOOL)connect {
    if (self.client) return YES;
    if (![self loadSymbols]) {
        NSLog(@"[HIDBridge] 私有符号加载失败");
        return NO;
    }
    self.client = p_IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!self.client) {
        NSLog(@"[HIDBridge] IOHIDEventSystemClientCreate 失败（缺少 entitlement）");
        return NO;
    }
    NSLog(@"[HIDBridge] HID 系统连接成功");
    return YES;
}

- (void)disconnect {
    if (self.client) {
        CFRelease(self.client);
        self.client = NULL;
    }
}

// MARK: - 事件注入

/// 当前时刻（mach_absolute_time 换算为纳秒）
static uint64_t NowNanoseconds(void) {
    static mach_timebase_info_data_t s_tb;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{ mach_timebase_info(&s_tb); });
    uint64_t now = mach_absolute_time();
    return now * s_tb.numer / s_tb.denom;
}

/// 合法 sender ID（模拟系统触摸源；数值为社区广泛使用的可用值）
static uint64_t SenderID(void) {
    return 0x8000000817371935ULL;
}

- (AT_IOHIDEventRef)digitizerEventWithPhase:(BOOL)down normalizedX:(CGFloat)x normalizedY:(CGFloat)y {

    uint64_t now = NowNanoseconds();

    /* 手指事件：携带坐标与相位 */
    AT_IOHIDEventRef finger = p_IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault,
        now,
        0,            // index
        0x1,          // identity
        down ? (AT_kIOHIDDigitizerEventRange | AT_kIOHIDDigitizerEventTouch |
                AT_kIOHIDDigitizerEventPosition | AT_kIOHIDDigitizerEventTip |
                AT_kIOHIDDigitizerEventIdentity)
             : (AT_kIOHIDDigitizerEventRange | AT_kIOHIDDigitizerEventIdentity),
        0,            // buttonMask
        x, y,         // 归一化坐标（0~1）
        0.0,          // z
        down ? 1.0 : 0.0,   // tipPressure
        0.0,          // twist
        true,         // range
        down,         // touch
        0             // options
    );
    if (!finger) return NULL;

    /* 父级 digitizer 事件：必须带 kIOHIDDigitizerEventRange | Touch | Identity */
    AT_IOHIDEventRef parent = p_IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault,
        now,
        AT_kIOHIDEventTypeDigitizer,
        0,
        0,            // index
        0x1,          // identity
        AT_kIOHIDDigitizerEventRange | AT_kIOHIDDigitizerEventTouch | AT_kIOHIDDigitizerEventIdentity,
        0,            // buttonMask
        0, 0, 0,      // 父事件不带坐标
        0, 0,
        true,         // range
        true,         // touch
        0
    );
    if (!parent) {
        CFRelease(finger);
        return NULL;
    }

    p_IOHIDEventAppendEvent(parent, finger, 0);
    CFRelease(finger);
    return parent;
}

- (void)dispatchEvent:(AT_IOHIDEventRef)event {
    if (!event || !self.client) return;
    p_IOHIDEventSetSenderID(event, SenderID());
    AT_IOReturn ret = p_IOHIDEventSystemClientDispatchEvent(self.client, event);
    if (ret != AT_kIOReturnSuccess) {
        NSLog(@"[HIDBridge] DispatchEvent 失败: 0x%x", ret);
    }
    CFRelease(event);
}

// MARK: - 对外接口

- (void)tapAt:(HIDTap *)tap {
    if (!self.client || !tap) return;
    [self dispatchEvent:[self digitizerEventWithPhase:YES normalizedX:tap.normalizedX normalizedY:tap.normalizedY]];
    [self dispatchEvent:[self digitizerEventWithPhase:NO normalizedX:tap.normalizedX normalizedY:tap.normalizedY]];
}

- (void)tapDown:(HIDTap *)tap {
    if (!self.client || !tap) return;
    [self dispatchEvent:[self digitizerEventWithPhase:YES normalizedX:tap.normalizedX normalizedY:tap.normalizedY]];
}

- (void)tapUp:(HIDTap *)tap {
    if (!self.client || !tap) return;
    [self dispatchEvent:[self digitizerEventWithPhase:NO normalizedX:tap.normalizedX normalizedY:tap.normalizedY]];
}

@end

// MARK: - HIDTap

@implementation HIDTap
@end
