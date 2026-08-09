//
//  BackboardSafeProbe.c — backboardd 注入加载安全验证（最小 dylib）
//
//  ⚠️ 目的：v2.1 的 BackboardInject 注入 backboardd 黑屏（8ddfa9e 实测）。
//  黑屏可能死在【ellekit 加载 dylib 本身】这个环节，也可能死在后续初始化。
//  本文件把它们分开验证——**只测"加载"是否安全**：
//
//  · constructor 只做 fopen/fprintf/fclose（写日志）
//  · 绝不 dlopen / dispatch / IOKit / ObjC / 任何框架 API
//  · 不注册回调、不建 socket、不碰触摸
//
//  预期结果：
//    · 装上重启后【不黑屏】→ 说明 ellekit 加载 backboardd dylib 本身安全
//      → 下一步才做「服务回调 + 触摸构造」（佳影式）
//    · 【黑屏】→ 加载环节就崩 → backboardd 注入路线彻底堵死，不再尝试
//
//  判断方式：/tmp/bb_safe_probe.log 有 ctor 行 = dylib 成功加载且活着
//

#include <stdio.h>
#include <unistd.h>

__attribute__((constructor))
static void BBSafeProbeCtor(void) {
    // 铁律（报告 §三）：backboardd 危险等级 1，constructor 阶段只许写文件日志。
    FILE *f = fopen("/tmp/bb_safe_probe.log", "a");
    if (f) {
        fprintf(f, "[SafeProbe] ctor pid=%d proc=%s (load OK)\n",
                (int)getpid(), getprogname() ? getprogname() : "?");
        fclose(f);
    }
}
