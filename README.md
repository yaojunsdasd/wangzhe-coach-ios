# 全能签自签方案（最终版）

**基于「全能签自签」这一确定前提设计。** 不用 Apple 开发者账号，不用 App Groups。

---

## 一、架构（针对全能签优化）

```
┌─────────────────────────────────────────────────┐
│ 主 App（全能签签名安装）                          │
│   ├─ BackgroundKeeper ─ 静音音频保活             │
│   │    └ 防止切到王者后被 iOS 挂起                │
│   ├─ SharedStore ─ 监听 127.0.0.1:8765           │
│   └─ PiPOverlay ─ 系统级画中画，浮在王者上        │
├─────────────────────────────────────────────────┤
│ 广播扩展（同一 IPA 内的 App Extension）           │
│   ├─ ReplayKit 读屏（唯一能拿屏幕帧的途径）        │
│   ├─ 小地图解析 + 贝叶斯跟踪                      │
│   └─ 连接 127.0.0.1:8765 发送结果                 │
└─────────────────────────────────────────────────┘
```

### 为什么用 socket 而不是 App Groups

Apple 文档明确：App Groups 必须 **register on the Apple Developer website**。
全能签用的是别人的企业证书 + 固定通配 profile，
里面不可能有你注册的 group id → **entitlement 对不上，签名失败**。

**socket 不需要任何 entitlement** —— 网络访问是 iOS 的默认能力。
主 App bind、扩展 connect，两者都在同一台设备上，走回环地址。

---

## 二、最关键的技术点：后台保活

**这是整个方案成败的核心。**

### 问题

用户切到王者后，主 App 进后台。iOS 约 30 秒后挂起它：

| 被挂起后 | 后果 |
|---|---|
| socket 监听线程冻结 | 扩展连不上 → 数据断流 |
| PiP 渲染循环停止 | 提示不再更新 |
| **结果** | **切进游戏后提示就死了** |

### 解法

声明 `UIBackgroundModes = audio` + 持续播放**静音音频**。
iOS 认为 App 正在播放音频 → **不挂起它**。

### 为什么这是正当的

**PiP 本身就要求活跃音频会话** ——
`AVPictureInPictureController` 在无音频会话时根本不会启动。

所以音频会话是 PiP 的**必要前提**，保活是它的自然副产品，不是钻空子。

### 代价

- 状态栏可能显示音频图标
- 轻微耗电（8kHz 单声道静音，解码开销可忽略）

代码见 `App/BackgroundKeeper.swift`，含中断处理（来电后自动恢复）。

---

## 三、App 内的诊断界面

装好后**第一眼看这里**，它直接告诉你架构是否成立：

```
✅ 保活：运行中
✅ 通信：socket :8765
✅ 扩展：已连接
✅ 数据：0.3s 前  (共 42 帧)
   威胁：78%
   标记：G,0.60,0.44,0.15,5;S,0.62,0.88,0.02,-
```

| 显示 | 含义 | 处理 |
|---|---|---|
| ❌ 保活：未启动 | 音频会话失败 | 检查静音音频生成 |
| ❌ 通信：不可用 | 端口被占用 | 换端口 |
| ⏳ 扩展：等待连接 | 扩展没跑起来 | 确认广播已启动 |
| ❌ 数据：xx s 前 | 扩展连上但断了 | **看是不是切后台被挂起** |

**最后一行是决定性的**：切到王者后如果数据年龄一直涨，说明保活没生效。

---

## 四、编译与签名

### 编译（GitHub Actions，Windows 也能做）

1. 推 `ios/` 到 GitHub
2. Actions 在 macOS runner 上跑 `xcodebuild`
3. 产出 `WangzheCoach-unsigned.ipa`

### 签名（全能签）

用全能签重签这个未签名 IPA。**注意两点**：

1. **Bundle ID 与扩展 ID 必须匹配**
   ```
   主 App:  com.wangzhe.coach
   扩展:    com.wangzhe.coach.BroadcastExtension
   ```
   全能签签名时，扩展的 bundle id 必须是主 App 的**子前缀**，否则系统不认。

2. **entitlements 里只留全能签支持的**
   我已经把两个 entitlements 文件做成**最小化**：
   ```xml
   <key>com.apple.security.application-groups</key>  <!-- 全能签不支持，删掉 -->
   <key>get-task-allow</key>
   <key>com.apple.developer.replaykit.broadcast-extended-memory</key>
   ```
   如果签名报错，**先把 App Groups 那段删掉**（代码已支持降级到 socket）。

---

## 五、⚠️ 未验证的假设（我必须列出来）

| # | 假设 | 若失败 | 验证方式 |
|---|---|---|---|
| 1 | 全能签能签出**带扩展**的 IPA | 架构作废 | 装上看"扩展：已连接" |
| 2 | 扩展能用 localhost 连主 App | 换通信方式 | 同上 |
| 3 | **保活能让 App 不被挂起** | 切游戏后断流 | 看"数据：x s 前" |
| 4 | 扩展在 ~50MB 内存下跑得动 | 降精度 | 看日志内存数字 |

**假设 3 是最大的风险点**，因为它依赖 iOS 的后台策略。
我在代码里做了**双保险**：
- 静音音频（主要手段）
- `beginBackgroundTask` 自动续期（兜底）

**但双保险也不是 100% 保证** —— 需要实机验证。

---

## 六、文件清单

```
ios/WangzheCoach/
├── App/
│   ├── MainViewController.swift    主界面 + 诊断显示
│   ├── PiPOverlay.swift            PiP 悬浮层渲染
│   ├── BackgroundKeeper.swift      ★ 后台保活（核心）
│   ├── ProbeViewController.swift   最小验证（可先跑这个）
│   └── Info.plist                  UIBackgroundModes = audio
├── Shared/
│   ├── Geometry.swift              地图 + Dijkstra
│   ├── BeliefTracker.swift         贝叶斯跟踪 + 可达域
│   ├── MinimapParser.swift         小地图 HSV + 连通域
│   ├── GhostRenderer.swift         三态（SOLID/GHOST/HIDDEN）
│   ├── SelfHeroLocator.swift       我方位置识别
│   └── SharedStore.swift           ★ socket 通信（核心）
└── BroadcastExtension/
    └── SampleHandler.swift         ReplayKit 读屏入口
```

---

## 七、推进顺序（重要）

**不要一上来就跑完整功能。** 按这个顺序：

### 第 1 步：跑 ProbeViewController

我写了一个最小验证界面。它只做一件事：
**显示从扩展收到的帧计数**。

数字会动 = 假设 1 + 2 成立 → 继续
不会动 = 立刻停下，换方案

### 第 2 步：验证保活

在 Probe 界面开广播 → 切到别的 App → 等 60 秒 → 切回来。

**数字还在涨** = 保活成立（假设 3 通过）
**数字停了** = 保活失败，要改方案

### 第 3 步：看内存

日志里的 `mem=` 数字。超过 45MB 就要警惕。

### 第 4 步：接完整功能

前三步都过了，再启用主界面 + PiP + 算法。

---

## 八、能力边界

**能做到**：防 GANK 预警（窗口 9.5 秒）、敌方大致方位、三态显示（可见=实心 / 推断=幽灵 / **信息不足=不画**）

**做不到**：视野外敌方精确坐标、草丛内位置

**只用官方 API**：ReplayKit + PiP。不注入、不读游戏内存、不改文件、不发伪造请求、不做自动操作。
