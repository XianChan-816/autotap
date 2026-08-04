# AutoTap — iOS 全局自动点击器（IOHIDEvent 私有接口）

在 iPhone 上模拟全局触摸点击：输入 X / Y 屏幕坐标和点击间隔（毫秒），
长按按钮触发，可切出 App 作用到游戏等其他应用界面。

> ⚠️ **适用范围与风险**
> - 使用苹果**私有 API（IOHIDEvent）与私有 entitlement**，**无法上架 App Store**，也无法用普通免费证书侧载生效。
> - 仅适用于 **TrollStore**（iOS 14.0 ~ 17.0 可安装）或**越狱**设备。
> - 仅建议用于个人自动化 / 无障碍测试。在游戏中使用可能违反其服务条款，后果自负。

---

## 功能

| 功能 | 说明 |
|---|---|
| 坐标输入 | X / Y 归一化坐标（0~1），可直接在 App 内画布上点击取点 |
| 间隔设置 | 毫秒级，最小 1ms，专用线程 + `mach_absolute_time` 高精度定时 |
| 屏幕方向 | 竖屏 / 横屏(Home右) / 横屏(Home左) 自动换算坐标 |
| 多点循环 | 可添加多个点击点，按顺序循环点击 |
| 长按触发 | 长按按钮开始，松手停止 |
| 连续模式 | 切到目标 App 后台继续运行；按**音量键**急停 |
| 后台保活 | 静音音频循环让系统不冻结 App，切后台不中断 |

---

## 原理

1. **注入路径**：`IOHIDEventSystemClient`（IOKit）→ 构造 `kIOHIDEventTypeDigitizer` 事件
   （父事件 + 手指子事件，携带相位 / 坐标 / 压力）→ `IOHIDEventSystemClientDispatchEvent`
   派发到系统 HID 服务，实现**全局触摸注入**，与真实手指点击等效。
2. **所需权限**（`AutoTap.entitlements`）：
   - `platform-application`
   - `com.apple.private.security.no-sandbox`
   - `com.apple.hid.system.server-access`（核心）
   - `com.apple.private.hid.client.event-dispatch`
3. **后台保活**：内存生成 3 秒静音 PCM 循环播放，App 以"后台音频"身份存活；
   音量键急停通过 KVO 监听系统音量变化实现。

---

## 构建

### 方式 A：GitHub 云端构建（无 Mac 也能用，推荐）

1. 把本目录推送到 GitHub 仓库（`main` 分支）；
2. Actions → 手动运行 **"Build IPA"**；
3. 构建完成后在 Artifacts 下载 `AutoTap.ipa`。

### 方式 B：本地 Mac 构建

```bash
cd AutoTap
make setup    # 安装 xcodegen
make ipa      # 生成 build/AutoTap.ipa（无签名）
```

---

## 安装与使用

1. iPhone 安装 **TrollStore**（支持 iOS 14.0 ~ 17.0，见 [TrollStore 官方文档](https://github.com/opa334/TrollStore)）；
2. 用 TrollStore 打开 `AutoTap.ipa` 安装（TrollStore 会注入 `platform-application`、`no-sandbox` 等权限）；
3. 打开 AutoTap：
   - 在画布上点击取点，或手动输入 X / Y（0~1）与间隔（ms）；
   - 选择目标 App 的屏幕方向；
   - **长按绿色按钮**开始点击，松手停止；
   - 想切到游戏：开启"连续模式"→ 长按启动 → 切到游戏 → 点完按**音量键**停止。

> 首次运行若状态显示"HID 连接失败"，说明 entitlement 未被注入（非 TrollStore / 越狱环境）。

---

## 工程结构

```
AutoTap/
├── project.yml                  # XcodeGen 工程定义（免手写 .xcodeproj）
├── Makefile                     # 本地构建脚本
├── HIDBridge/
│   ├── HIDBridge.h / .m         # IOHIDEvent 私有接口注入层（Objective-C）
│   └── AutoTap-Bridging-Header.h
├── Sources/
│   ├── AppDelegate.swift
│   ├── ViewController.swift     # 界面：坐标/间隔/取点/长按触发
│   ├── ClickerEngine.swift      # 高精度点击调度 + 多坐标循环 + 方向换算
│   └── KeepAlive.swift          # 静音保活 + 音量键急停
└── Resources/
    └── AutoTap.entitlements     # 私有权限
```

---

## 常见问题

**Q：为什么普通侧载（AltStore / Sideloadly）点了没反应？**
A：私有 entitlement 无法用免费证书签名注入；免费侧载 App 处于沙盒内，
`IOHIDEventSystemClientDispatchEvent` 会被系统拒绝。必须 TrollStore 或越狱。

**Q：点击没生效但也没报错？**
A：确认状态栏显示"运行中"且 HID 连接成功；检查坐标方向是否与目标 App
一致（横屏游戏请选对应横屏方向）。

**Q：切到游戏后 App 被系统冻结？**
A：确认 Info.plist 的 `UIBackgroundModes` 包含 `audio`，且"连续模式"已开启
（AppDelegate 会在进入后台时自动启动静音保活）。

**Q：间隔 1ms 太快没反应？**
A：部分游戏有最低输入间隔限制；建议从 50~200ms 起步测试。

---

# 悬浮球版（越狱 tweak）

> AutoTap App 的圆圈只能在自己界面里显示。若要在**任意 App（游戏）上看到可交互悬浮球**，
> 需要越狱环境，使用 `FloatingTap/` 目录的 tweak 工程：
>
> - 注入 SpringBoard，悬浮球全局显示，任意 App 上可见可操作
> - 拖动调位置、捏合调大小、**长按悬浮球触发点击 / 松手停止**
> - 点击位置 = 悬浮球圆心，点击注入复用 IOHIDEvent 方案（越狱环境权限完整）
> - 配置（位置/大小/间隔）保存在 `FloatingTap.intervalMs` 等 NSUserDefaults 键

**构建**（无需 Mac）：推送到 GitHub 自动触发 **Build FloatingTap Tweak** workflow，
在 Artifacts 下载 `FloatingTap.deb`。

**安装**（Dopamine 越狱）：把 .deb 传到 iPad → Sileo 里点"+ 添加本地包"导入，
或 Filza 打开 .deb 选择"安装" → 重启 SpringBoard（sbreload）生效。

**调整点击间隔**：默认 200ms。间隔与悬浮球位置/大小保存在 SpringBoard 进程的
NSUserDefaults（键 `FloatingTap.intervalMs` 等，见 `FloatingBallView.m`）。
v1 暂未做设置界面，后续版本会增加悬浮球菜单设置；当前可改源码默认值后重编。
