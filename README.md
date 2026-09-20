
# AHK2ManagerEx

基于 AutoHotkey v2 的脚本管理器。把你的 `.ahk` 脚本丢进 `scripts\` 目录，剩下的交给它：
统一启动、关闭、重启，全部收纳到一个托盘图标里。

[![Build](https://github.com/wfwuestc/AHK2ManagerEx/actions/workflows/main.yml/badge.svg)](https://github.com/wfwuestc/AHK2ManagerEx/actions/workflows/main.yml)

## 特性

- **统一管理**：一次性列出所有脚本实例，支持启动 / 关闭 / 重启 / 全部关闭
- **守护脚本**：不带前缀的脚本随管理器自动启动
- **子文件夹分组**：`scripts\` 下可以自由建目录，托盘菜单按文件夹名自动生成子菜单，层级不限
- **附加脚本自动过滤**：只被 `#Include` 引用的库文件（JSON 解析、公共函数等）不会出现在菜单里，也不会被单独启动
- **明暗主题**：跟随系统 `SystemUsesLightTheme` 自动切换图标与窗口主题
- **多语言**：内置 `en_us` / `zh_cn`，往 `lang\` 里加 ini 即可扩展
- **进程管理器**：查看每个运行中脚本的 PID 与内存占用
- **单实例运行**：管理器只占一个托盘图标

## 快速开始

### 1. 准备程序目录

把程序（编译好的 `AHK2ManagerEx.exe`，或源码 + `lib\` + `icons\` + `lang\`）放到任意目录，
例如 `D:\Tools\AutoHotKey\`。这个目录就是**程序目录**：

```
D:\Tools\AutoHotKey\
├── AHK2ManagerEx.exe
├── setting.ini            <- 首次运行自动生成
├── icons\                 <- 图标（编译版已内嵌，源码运行需要）
├── lang\                  <- 语言包 en_us.ini / zh_cn.ini
├── lib\                   <- 依赖库（编译版已内嵌，源码运行需要）
└── scripts\               <- ★ 你的脚本都放这里
```

### 2. 放入脚本

把你所有的 `.ahk` 脚本放进**程序目录下的 `scripts\`**，可以自由建子文件夹。
放进去就会自动被扫描到，无需登记。

### 3. 运行

```shell
# 编译版
AHK2ManagerEx.exe

# 或直接用解释器跑源码
AutoHotkey64.exe AHK2ManagerEx.ahk
```

托盘区出现图标即启动成功，之后的一切操作都从这个图标进入。

## 脚本的三种类型

### 字符模式（默认）

靠**文件名前缀**区分类型，前缀在任意子文件夹里都生效：

| 前缀 | 类型 | 枚举值 | 行为 |
|---|---|---|---|
| 无 | 守护脚本 DAEMON | `2` | 管理器启动时自动运行；出现在「关闭」「重新运行」菜单 |
| `!` | 临时脚本 TEMP | `1` | 不自动运行；出现在「运行」菜单，启动后可被关闭 / 重启 |
| `+` | 一次性脚本 ONCE | `0` | 只出现在「运行」菜单，点一次跑一次，不跟踪运行状态 |

### 版本控制模式

给 git / svn 仓库用：脚本文件名里不带符号和空格，类型改由 `setting.ini` 定义。

**方式 1：命令行自动切换（会重命名文件）**

> [!CAUTION]
> 该命令会把文件名里的 `!` `+` 前缀去掉，**重命名后不可恢复**。请在版本控制已提交的状态下操作。

```shell
# 切换到版本控制模式
AHK2ManagerEx.exe mode sc
# 切回字符模式
AHK2ManagerEx.exe mode char
```

**方式 2：手动改配置（不会动你的文件）**

1. 在 `setting.ini` 中设置 `mode=1`
2. 重启 AHK2ManagerEx

两种模式下脚本类型的枚举值一致：`0` = 一次性，`1` = 临时，`2` = 守护。

## 组织脚本：子文件夹

`scripts\` 支持任意层级的子文件夹，菜单会按文件夹名递归分组：

```
scripts\
├── Obsidian.ahk                      -> 根目录脚本，「运行」菜单里直接平铺
├── !临时工具.ahk                      -> 带 ! 前缀，放在哪一层都算临时脚本
└── EverythingToolbar\
    ├── Everything_Toolbar.ahk        -> 生成子菜单「EverythingToolbar」
    ├── EverythingToolbar.json        -> 只扫描 *.ahk，其他文件自然忽略
    └── Json.ahk                      -> 被 #Include 引用，自动过滤（见下节）
```

- 根目录下的脚本保持平铺，子文件夹变成子菜单，嵌套层级跟随你的目录层级
- 同名脚本不会打架：它们落在不同的子菜单里；如果某个脚本名和**同层的文件夹名**撞了
  （例如根目录既有 `根目录.ahk` 又有 `根目录\` 文件夹），该项标签会自动变成
  `根目录  (根目录.ahk)`

## 附加脚本（只被 #Include 的文件）

JSON 解析库、公共函数这类文件只是给别人 `#Include` 的，**不应该出现在菜单里，更不应该被单独启动**。
管理器会自动识别它们：扫描每个脚本里的 `#Include` / `#IncludeAgain` 指令，把被引用到的文件过滤掉。

解析规则：

- 相对路径**先按引用者所在目录**查找，再退回 `scripts\` 根目录
- 支持 `#Include *i File`、行尾 `;` 注释、`#Include 目录\`（展开为目录下所有 `.ahk`）
- `<Lib>` 形式与含变量的写法交给 AutoHotkey 自己解析，管理器不处理
- `!` / `+` 前缀可以**覆盖**识别结果，把脚本强制保留为独立条目
- **读取或解析失败时不做任何过滤**（fail open）：宁可多显示一个，也不会静默藏掉你的脚本

在此之上还有两条手动约定：

| 约定 | 效果 |
|---|---|
| 文件名以 `_` 开头，如 `_Json.ahk` | 直接当作附加脚本 |
| 文件夹名以 `_` 开头，如 `_lib\` | 整棵子树不参与扫描 |

想核对自己有没有被误判，在 `setting.ini` 的 `[Setting]` 段加一行 `showIgnored=1` 再重新加载，
托盘菜单会多出一个只读的「附加脚本（已忽略）」子菜单，列出所有被跳过的文件。

## 托盘菜单

单击托盘图标即可展开菜单（已设为单击触发）：

| 菜单项 | 作用 |
|---|---|
| AHK2ManagerEx | 菜单标题，同时是默认项 |
| 运行 | 展开「未运行脚本」列表：临时 / 一次性 / 守护脚本都在这 |
| 重新运行 | 展开「正在运行脚本」列表，点击即重启 |
| 关闭 | 展开「正在运行脚本」列表，点击即关闭 |
| 关闭所有 | 关闭所有由管理器启动的脚本 |
| 语言 | 切换界面语言（从 `lang\` 目录自动列出） |
| 任务管理器 | 进程列表：序号 / PID / 脚本相对路径 / 内存占用 |
| 附加脚本（已忽略） | 仅在 `showIgnored=1` 时出现，只读 |
| 重新加载 | 重新扫描 `scripts\` 并重建菜单，改了脚本文件名用它 |
| 退出 | 关闭所有脚本并退出管理器 |

## 快捷键

| 功能 | 快捷键 |
|---|---|
| 唤起「运行」菜单 | <kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>LButton</kbd> |
| 唤起「关闭」菜单 | <kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>RButton</kbd> |
| 唤起「重新运行」菜单 | <kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>MButton</kbd> |
| 重新加载管理器 | <kbd>Win</kbd> + <kbd>Shift</kbd> + <kbd>R</kbd> |

前三个是鼠标组合键，会挂全局鼠标钩子。和其他软件冲突时，在 `setting.ini` 的 `[Setting]` 段
加 `hotkeys=0` 再重启管理器即可关掉（<kbd>Win</kbd> + <kbd>Shift</kbd> + <kbd>R</kbd> 不受该开关影响）。

## 配置文件

`setting.ini` 与程序同目录，首次运行自动生成：

```ini
[Setting]
language=zh_cn
mode=0
showIgnored=0
hotkeys=1

[SCRIPTS]
```

| 键 | 含义 |
|---|---|
| `language` | 界面语言，对应 `lang\` 下的文件名（`en_us` / `zh_cn`） |
| `mode` | `0` = 字符模式，`1` = 版本控制模式 |
| `showIgnored` | `1` = 在托盘菜单显示被忽略的附加脚本清单。**默认没有这一行，要自己加** |
| `hotkeys` | `0` = 不注册下面那三个鼠标组合键。**默认也没有这一行，要自己加** |

`[SCRIPTS]` 段仅版本控制模式使用，记录每个脚本的类型，由程序自动维护。

> [!NOTE]
> 这个文件每次保存都会被程序整体重写，手写的注释会被抹掉，所以说明写在上面这张表里而不是 ini 里。

版本控制模式下，`[SCRIPTS]` 的键是脚本**相对 `scripts\` 的路径去掉扩展名**，所以
子文件夹里的脚本也能各自独立配置：

```ini
[SCRIPTS]
Obsidian=2
EverythingToolbar\Everything_Toolbar=2
```

## 从源码构建

需要 [Ahk2Exe](https://www.autohotkey.com/docs/v2/Scripts.htm#ahk2exe)（AutoHotkey 官方编译器，**不随解释器分发**）。
`build.ps1` 会按「环境变量 → 项目内 `tools\` → Program Files」的顺序自动找工具链，
所以最省事的做法是把编译器放进项目里（`tools\` 已在 `.gitignore` 中，不会进版本库）：

```powershell
curl.exe -L --fail -o tools\Ahk2Exe.zip https://github.com/AutoHotkey/Ahk2Exe/releases/download/Ahk2Exe1.1.37.02a2/Ahk2Exe1.1.37.02a2.zip
Expand-Archive tools\Ahk2Exe.zip -DestinationPath tools\Compiler -Force
Copy-Item "<你的 AutoHotkey 目录>\AutoHotkey64.exe" tools\AutoHotkey64.exe    # x64 编译基准
```

也可以不改目录，直接用环境变量指定：`AHK2EXE`（编译器路径）、`AHK_BASE_X64`（基准文件路径）。

```powershell
npm run test     # 编译到 test\，用于本地验证
npm run build    # 编译到 build\，产出 AHK2ManagerEx.exe / AHK2ManagerEx.zip / checksums.txt
```

不想编译的话，直接用解释器运行源码即可，只要保证 `lib\`、`icons\`、`lang\` 与
`AHK2ManagerEx.ahk` 同级：

```shell
AutoHotkey64.exe AHK2ManagerEx.ahk
```

## 常见问题

**脚本放进去了，菜单里没有？**

依次检查：扩展名是不是 `.ahk`；是否放在以 `_` 开头的目录里；是否被判定成了附加脚本
（打开 `showIgnored=1` 看清单里有没有它）。

**两个不同文件夹里有同名脚本，怎么区分？**

它们会被分到各自的子菜单里。管理器内部用「相对路径」作为唯一标识，不会互相覆盖。

**某个脚本既被 `#Include`，也想单独启动？**

给它加上 `!` 或 `+` 前缀，就会覆盖自动识别、保留为独立条目。反过来，想让某个脚本被忽略，
把文件名加上 `_` 前缀即可。

**改了脚本文件名，需要重启管理器吗？**

不需要。托盘菜单里的「重新加载」或 <kbd>Win</kbd> + <kbd>Shift</kbd> + <kbd>R</kbd> 即可重新扫描。

**点了「关闭」但脚本没关掉？**

管理器是靠窗口标题 `<脚本的完整路径> - AutoHotkey` 判断脚本是否在运行的。如果系统上的
窗口标题只保留了裸文件名，那么分布在不同文件夹里的同名脚本，运行状态可能会互相干扰
——这是 AutoHotkey 窗口标题机制本身的限制。

## 已实现

- [x] 一次性 / 临时 / 守护 三种类型脚本管理
- [x] 明暗主题自动适配
- [x] 多语言支持
- [x] 版本控制模式
- [x] 子文件夹结构，以及只被 `#Include` 的附加脚本自动过滤

## 致谢

- [tex2e/AHKManager](https://github.com/tex2e/AHKManager) —— 最初的灵感来源
- [Jvcon/AHK2Manager](https://github.com/Jvcon/AHK2Manager) —— 本仓库的上游项目

## 许可

[GPL v2](LICENSE)。

本仓库基于 [Jvcon/AHK2Manager](https://github.com/Jvcon/AHK2Manager) 修改，原作者的版权声明一并保留。
改动部分（子文件夹结构支持、`#Include` 附加脚本过滤、中文文档、构建脚本可移植化）版权归本仓库作者所有，
同样以 GPL v2 发布。
