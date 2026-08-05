//
//  Tweak.xm
//  FloatingTap
//
//  ⚠️ 空壳诊断版 v1.0.8（ONLY FOR DEBUG）
//  %ctor 完全空、什么都不做、不注册通知、不启动任何定时器。
//  用途：二分定位「装 deb 后重启卡屏」问题。
//  - 空壳也卡 → 问题在 dylib 加载/注入/环境，与代码无关
//  - 空壳不卡 → 逐步加回代码找元凶
//

#import "FloatingBallView.h"

%ctor {
    // 空壳：什么都不做
}
