# MenuBarSqueeze

**中文** | [English](README.md)

一个**原生 macOS 菜单栏小工具**（Swift + AppKit，零第三方依赖），解决带刘海 MacBook 的老问题：

> 菜单栏放不下的图标、被刘海盖住点不到的图标 —— **依然够得着**。

![MenuBarSqueeze 下拉列出全部菜单栏图标](docs/screenshot.png)

<p align="center">
  <em>菜单栏上的 ▾ 三角 → 下拉列出全部状态栏项（带图标）→ 点哪个就弹出哪个的菜单。</em>
</p>

## 为什么需要它

带刘海的 MacBook，菜单栏可用区域只有**刘海右侧**那一段。一旦塞满：

- 新增的状态栏项会被系统放到**刘海底下，根本不绘制**；
- 你看不到，也点不到。

**靠"隐藏其他图标"解决不了** —— 隐藏并不会变出空间。真正的解法是提供一个**二级入口**，把这些项列出来并能触发它们。这就是本工具做的事。

## 功能

### 1. 全部菜单栏图标列表（主要功能，需要辅助功能权限）

- 左键点 **▾** 图标 → 下拉列出**所有运行中 App 的菜单栏项**，每项带图标
- macOS 从未布局出来的项会标 `⛔`（照样列出、照样能点）
- 点某一项 → **弹出它的菜单**，等价于你亲手点了那个图标
- 按住 **⌥ (Option)** 点 → 直接**打开所属 App**
- 智能触发：
  1. 先试 `AXPress`（快，不动鼠标）
  2. 约 0.35 秒内没弹出菜单 → 在该图标真实坐标**合成一次鼠标点击**
  3. 把这个 App 记入名单，下次直接走合成点击

### 2. 可选的「收起 / squeeze」功能（默认关闭，无需任何权限）

在右键菜单里打开后，会多出一个 `↔` 分隔符：

```
[被收起的图标…]  [↔ 分隔符]  [▾ 三角]  [要常看的图标…]  [系统图标]
                     ↑ 撑开这里              ↑ 点它开关
```

收起时把分隔符的 `NSStatusItem.length` 设为 `min(屏宽 × 2, 10000)`，它左侧的图标被挤出屏幕。
与 [Hidden Bar](https://github.com/dwarvesf/hidden)（MIT）相同的公开技术。

## 系统要求

- macOS 13 或更高（Apple 芯片 / Intel 均可）
- 「全部图标」功能需要**辅助功能权限**（系统设置 › 隐私与安全性 › 辅助功能）
- 编译需要 Xcode 或 Command Line Tools（提供 `swiftc`）

## 编译与安装

```bash
./build.sh            # 构建到 ./build/MenuBarSqueeze.app
./build.sh install    # 构建 + 复制到 /Applications + 启动
```

签名策略：钥匙串里有 **Apple Development** 证书就优先用它 —— 这样**重编译后辅助功能授权依然有效**；
没有证书则退回 ad-hoc，**每次重编译都要重新授权**。

## 使用

| 图标 | 左键 | 右键 |
|---|---|---|
| **▾ 三角** | 列出全部菜单栏图标 | 设置菜单 |
| **↔ 分隔符**（启用收起后才有） | 收起 / 展开 | 设置菜单 |

### 设置菜单

| 菜单项 | 说明 |
|---|---|
| 启用「收起」功能 | 创建 `↔` 分隔符 |
| 闲置后自动收起 | 仅启用收起后显示 |
| 鼠标移到菜单栏时自动展开 | 仅启用收起后显示 |
| 开机自动启动 | 写用户级 LaunchAgent，不需要管理员密码 |
| 重新扫描 / 申请辅助功能权限 | 重新枚举并触发授权 |
| 退出 | — |

## 配置项

偏好域为 `local.menubarsqueeze`：

```bash
defaults write local.menubarsqueeze showSeparator            -bool false  # 收起功能（默认关）
defaults write local.menubarsqueeze autoCollapse             -bool false  # 闲置自动收起
defaults write local.menubarsqueeze hoverExpand              -bool false  # 悬停自动展开
defaults write local.menubarsqueeze syntheticClickBundleIDs  -array com.example.app  # 强制合成点击的 App
```

图标位置用系统标准的 autosave 键控制（**数值越小越靠右**）：

```
"NSStatusItem Preferred Position MenuBarSqueeze.toggle" = 10;
```

## 诊断文件

| 文件 | 内容 |
|---|---|
| `/tmp/menubarsqueeze-ax.txt` | 辅助功能授权状态 + 枚举到的菜单栏项（含 `x=` 坐标） |
| `/tmp/menubarsqueeze-action.log` | 每次点击走了哪条路径（AXPress / 合成点击）及结果 |
| `/tmp/menubarsqueeze-diag.txt` | 状态栏项坐标（开发时用） |

## 文件结构

```
main.swift       # 整个 App（单文件，约 600 行）
Info.plist       # LSUIElement 包（只驻菜单栏，不占 Dock）
build.sh         # swiftc 编译 + 打包 .app + 签名
README.md        # 英文文档
README.zh-CN.md  # 本文档
```

## 已知限制

- **macOS 27+**：经典"长度 trick"可能失效（系统改用原生可见性机制）；「全部图标」功能不受影响。
- 标记 `⛔` 的项（系统从未布局，`x=0`）能列出，但合成点击可能够不到 —— 用 ⌥ 点打开它的 App。
- 不使用任何私有 API，因此**做不出**"第二行真实图标"的渲染效果（那是 Bartender 用私有 API + 屏幕录制实现的）。

## 卸载

```bash
pkill -f MenuBarSqueeze
rm -rf /Applications/MenuBarSqueeze.app
launchctl bootout gui/$(id -u)/local.menubarsqueeze 2>/dev/null
rm -f ~/Library/LaunchAgents/local.menubarsqueeze.plist
defaults delete local.menubarsqueeze 2>/dev/null
```

## 许可

[MIT](LICENSE)
