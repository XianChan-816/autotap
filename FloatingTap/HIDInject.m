//
//  HIDInject.m
//  FloatingTap
//
//  IOHIDEvent 系统事件注入：构造 kIOHIDEventTypeDigitizer 事件（父事件 + 手指子事件），
//  通过 IOHIDEventSystemClientDispatchEvent 派发到系统 HID 服务，实现全局触摸注入。
//
//  SpringBoard 进程自身具备 HID entitlement，越狱环境可直接调用。
//  所有类型使用本地 AT_ 前缀定义，避免与 SDK IOKit 头冲突。
//

#import "HIDInject.h"
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <dlfcn.h>

// MARK: - 私有类型与常量

typedef struct __IOHIDEvent * AT_IOHIDEventRef;
typedef struct __IOHIDEventSystemClient * AT_IOHIDEventSystemClientRef;
typedef struct __IOHIDService * AT_IOHIDServiceRef;
typedef int32_t AT_IOReturn;
typedef uint32_t AT_IOOptionBits;
static const AT_IOReturn AT_kIOReturnSuccess = 0;

typedef void (*AT_IOHIDSystemCallback)(void *target, void *refcon, AT_IOHIDServiceRef service, AT_IOHIDEventRef event);

/* 事件类型（本地前缀） */
typedef CF_ENUM(uint32_t, AT_IOHIDEventType) {
    AT_kIOHIDEventTypeNULL = 0,
    AT_kIOHIDEventTypeDigitizer = 11,
};

/* 触控 digitizer 事件位掩码（值参考私有头 IOHIDEventTypes.h） */
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

// MARK: - 私有函数指针

static AT_IOHIDEventRef (*p_IOHIDEventCreateDigitizerEvent)(CFAllocatorRef,
                                                           uint64_t timeStamp,
                                                           AT_IOHIDEventType type,
                                                           uint32_t options,
                                                           uint32_t index,
                                                           uint32_t identity,
                                                           uint32_t eventMask,
                                                           uint32_t buttonMask,
                                                           double x, double y, double z,
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
                                                                 double x, double y, double z,
                                                                 double tipPressure,
                                                                 double twist,
                                                                 Boolean range,
                                                                 Boolean touch,
                                                                 AT_IOOptionBits optionsBits);

static AT_IOHIDEventSystemClientRef (*p_IOHIDEventSystemClientCreate)(CFAllocatorRef);
static AT_IOReturn (*p_IOHIDEventSystemClientDispatchEvent)(AT_IOHIDEventSystemClientRef, AT_IOHIDEventRef);
static void (*p_IOHIDEventAppendEvent)(AT_IOHIDEventRef, AT_IOHIDEventRef, AT_IOOptionBits);
static void (*p_IOHIDEventSetSenderID)(AT_IOHIDEventRef, uint64_t);

@interface HIDInject ()
@property (nonatomic, assign) AT_IOHIDEventSystemClientRef client;
@end

@implementation HIDInject

+ (instancetype)shared {
    static HIDInject *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[HIDInject alloc] init]; });
    return instance;
}

- (void)dealloc {
    if (_client) {
        CFRelease(_client);
        _client = NULL;
    }
}

// MARK: - 符号解析

- (BOOL)loadSymbols {
    static BOOL loaded = NO;
    if (loaded) return YES;

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

    loaded = (p_IOHIDEventCreateDigitizerEvent &&
              p_IOHIDEventCreateDigitizerFingerEvent &&
              p_IOHIDEventSystemClientCreate &&
              p_IOHIDEventSystemClientDispatchEvent &&
              p_IOHIDEventAppendEvent &&
              p_IOHIDEventSetSenderID);
    return loaded;
}

// MARK: - 连接

- (BOOL)isConnected {
    return self.client != NULL;
}

- (BOOL)connect {
    if (self.client) return YES;
    if (![self loadSymbols]) {
        NSLog(@"[FloatingTap] HID 符号加载失败");
        return NO;
    }
    self.client = p_IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!self.client) {
        NSLog(@"[FloatingTap] HID 系统连接失败");
        return NO;
    }
    NSLog(@"[FloatingTap] HID 系统连接成功");
    return YES;
}

// MARK: - 事件构造

static uint64_t NowNanoseconds(void) {
    static mach_timebase_info_data_t s_tb;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{ mach_timebase_info(&s_tb); });
    uint64_t now = mach_absolute_time();
    return now * s_tb.numer / s_tb.denom;
}

static uint64_t SenderID(void) {
    return 0x8000000817371935ULL;
}

- (AT_IOHIDEventRef)digitizerEventWithPhase:(BOOL)down normalizedX:(CGFloat)x normalizedY:(CGFloat)y {
    uint64_t now = NowNanoseconds();

    AT_IOHIDEventRef finger = p_IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault,
        now,
        0, 0x1,
        down ? (AT_kIOHIDDigitizerEventRange | AT_kIOHIDDigitizerEventTouch |
                AT_kIOHIDDigitizerEventPosition | AT_kIOHIDDigitizerEventTip |
                AT_kIOHIDDigitizerEventIdentity)
             : (AT_kIOHIDDigitizerEventRange | AT_kIOHIDDigitizerEventIdentity),
        0,
        x, y, 0.0,
        down ? 1.0 : 0.0,
        0.0,
        true, down,
        0);
    if (!finger) return NULL;

    AT_IOHIDEventRef parent = p_IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault,
        now,
        AT_kIOHIDEventTypeDigitizer,
        0,
        0, 0x1,
        AT_kIOHIDDigitizerEventRange | AT_kIOHIDDigitizerEventTouch | AT_kIOHIDDigitizerEventIdentity,
        0,
        0, 0, 0,
        0, 0,
        true, true,
        0);
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
        NSLog(@"[FloatingTap] DispatchEvent 失败: 0x%x", ret);
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
