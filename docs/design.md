## hikkoshi 设计文档（草案）

> 版本：v0.1  
> 目标：把整体概念、语义和 CLI 行为说清楚，方便后续实现与维护。

---

## 1. 项目目标与概念

### 1.1 hikkoshi 是什么

`hikkoshi`（引っ越し，「搬家」）是一个命令行小工具，用来：

- 为不同的「配置环境」提供独立的 `HOME` / XDG 目录；
- 在指定环境下运行任意命令行程序；
- 避免配置文件堆在同一个 `~` 下面造成混乱。

核心思路：**每个 profile 就是一套独立的「虚拟 HOME + XDG 目录」配置**，`hikkoshi` 负责根据 profile 构造好环境变量，然后启动目标程序。

### 1.2 使用场景举例

- 给不同项目准备隔离的 `~/.config` / `~/.local/share`：编辑器、CLI 工具互不影响；
- 给「工作 / 私人 / 实验」准备完全不同的 HOME；
- 为某些应用做「一次性、可丢弃」的配置目录，避免污染主 HOME。

---

## 2. 核心概念

### 2.1 Profile（配置档案）

一个 profile 表示一套完整的环境配置，包含：

- 虚拟 `HOME` 路径（必填）；
- 一组 XDG 目录（可选，默认从 HOME 派生）；
- 一组额外的自定义环境变量。

在配置文件中，每个 profile 对应一个 `profiles.<name>` TOML 表。

### 2.2 虚拟 HOME

`home` 是 profile 的核心字段：

- 每个 profile 必须显式设置 `home`；
- 运行时 `hikkoshi` 会设置：
  - `HOME = <home 展开的绝对路径>`（不继承调用者的 HOME）；
- 所有 XDG 目录在未显式配置时，均从该 `HOME` 推导。

### 2.3 XDG 目录（简写）

为了方便书写，TOML 中不直接写 `XDG_*`，而是用简写：

- `config` → `XDG_CONFIG_HOME`
- `data`   → `XDG_DATA_HOME`
- `cache`  → `XDG_CACHE_HOME`
- `state`  → `XDG_STATE_HOME`

如果简写字段未设置，则从 `HOME` 推导：

- `config` 默认：`$HOME/.config`
- `data`   默认：`$HOME/.local/share`
- `cache`  默认：`$HOME/.cache`
- `state`  默认：`$HOME/.local/state`

### 2.4 自定义环境变量

每个 profile 可以定义自定义 env 表：

- `[profiles.<name>.env]`：键值对形式；
- 运行时会写入到子进程环境中；
- 特殊规则：为避免语义混乱，`env` 中定义的 `HOME` 或 `XDG_*` 将被忽略（由 profile 的字段统一控制）。

---

## 3. CLI 设计

### 3.1 核心运行用法

不提供默认 profile，必须显式指定：

```bash
hikkoshi <profile> <command> [args...]
 hikkoshi <profile> --sh '<shell-command>'
```

例如：

```bash
hikkoshi work nvim
hikkoshi dev node app.mjs
hikkoshi test python script.py
```

语义：

- 根据 `<profile>` 从配置文件中找到对应配置；
- 构造虚拟 `HOME` + 一组 XDG 环境变量 + 额外 env；
- 在该环境下执行 `<command> [args...]`；
- 若使用 `--sh` 形式，则在该 profile 环境下调用用户的 shell（优先使用 `SHELL` 环境变量，否则回退到 `/bin/sh`），以 `-lc '<shell-command>'` 的方式执行一整条命令行；
- `hikkoshi` 自己的退出码 = 子进程的退出码。

### 3.2 管理 / 查询子命令

暂定以下子命令（均不启动子进程）：

- `hikkoshi list`
  - 列出所有可用 profile 名称；
- `hikkoshi show <profile>`
  - 展示指定 profile 的解析结果（已展开的绝对路径和 env 列表）；
- `hikkoshi config-path`
  - 打印当前生效的配置文件路径；
- `hikkoshi example`
  - 输出一份示例配置（TOML），方便用户重定向到文件。

后续可以考虑（非 v0.1 必选）：

- `hikkoshi doctor`
  - 检查配置文件是否存在、是否能解析、目录是否存在等。

### 3.3 配置文件位置与优先级

配置文件默认路径：

- `~/.config/hikkoshi/config.toml`

支持显式指定其他路径：

- 环境变量：`HIKKOSHI_CONFIG=/path/to/config.toml`
- 命令行参数（可选特性，v0.1 可讨论实现与否）：
  - `hikkoshi --config /path/to/config.toml ...`

查找优先级（从高到低）：

1. 命令行 `--config`（如果实现）；  
2. 环境变量 `HIKKOSHI_CONFIG`；  
3. 默认路径 `~/.config/hikkoshi/config.toml`。

配置文件缺失时：

- 对运行命令（`<profile> <command>` / `list` / `show` 等）：
  - 报错并提示如何用 `hikkoshi example > ~/.config/hikkoshi/config.toml` 初始化；
- 对 `hikkoshi example`：
  - 永远可用，不依赖现有配置文件。

---

## 4. Profile 配置 Schema

### 4.1 顶层结构

使用 `[profiles.<name>]` 管理多个 profile：

```toml
[profiles.work]
home   = "~/profiles/work"
config = "~/profiles/work/.config"        # 可选
data   = "~/profiles/work/.local/share"   # 可选
cache  = "~/profiles/work/.cache"         # 可选
state  = "~/profiles/work/.local/state"   # 可选

[profiles.work.env]
APP_ENV = "work"
EDITOR  = "nvim"
```

约定：

- `home`：必填，虚拟 HOME；
- `config` / `data` / `cache` / `state`：可选，存在则覆盖从 HOME 推导的默认值；
- `env`：可选的子表，自定义环境变量；
- 所有路径字段支持 `~`，运行时展开为绝对路径；
- 不支持在配置中直接写 `XDG_*` 字段。

### 4.2 字段继承与覆盖规则

以 env map 的构造顺序来理解：

1. 基础环境：
   - 从当前进程环境复制一个 map（保证 PATH、LANG 等常规变量存在）；
2. 设置 `HOME`：
   - 使用 profile 的 `home` 字段（展开为绝对路径），覆盖原有 HOME；
3. 设置 XDG 目录：
   - 对每个简写字段：
     - 若 profile 显式设置（如 `config = "... "`）：
       - 展开路径后设置对应 `XDG_*`；
     - 若未设置：
       - 用基于 `HOME` 的默认值：
         - `XDG_CONFIG_HOME = "$HOME/.config"`
         - `XDG_DATA_HOME   = "$HOME/.local/share"`
         - `XDG_CACHE_HOME  = "$HOME/.cache"`
         - `XDG_STATE_HOME  = "$HOME/.local/state"`
4. 应用自定义 env：
   - 遍历 `[profiles.<name>.env]`：
     - 若键为 `HOME` 或以 `XDG_` 开头：忽略（可选：打印 debug 日志或警告）；
     - 否则写入/覆盖 map 中的值。

最终这个 env map 作为子进程环境。

---

## 5. 实现结构（Zig 视角）

### 5.1 模块划分

初步规划：

- `src/main.zig`
  - 程序入口；
  - 解析命令行参数；
  - 决定当前模式：运行子进程 / list / show / config-path / example；
  - 调用其他模块实现具体逻辑。

- `src/config.zig`
  - 使用 `zig-toml` 解析 TOML 配置；
  - 定义 `Config`、`Profile` 等结构体；
  - 负责：
    - 根据环境变量 / 默认路径决定实际配置文件路径；
    - 从文件加载并解析；
    - 提供按名称获取 profile 的 API；
    - 提供列出所有 profile 的 API。

- `src/env.zig`
  - 负责构造子进程用的环境变量列表；
  - 提供：
    - `buildEnvForProfile(profile: Profile, allocator, parent_env_map) !EnvList`；
  - 封装：
    - `HOME` / XDG 推导逻辑；
    - 自定义 env 的应用；
    - 禁止修改 `HOME` / `XDG_*` 的规则。

（如有需要，可以再增加 `src/cli.zig` 把命令行解析和 usage/help 文案独立出来。）

### 5.2 依赖：zig-toml

在 `build.zig.zon` 中引入 `sam701/zig-toml`，在 `build.zig` 里把 module 加入 root module：

- `config.zig` 中负责：
  - 用 `zig-toml` 解析原始 TOML；
  - 把泛型 AST 或中间结构转成强类型 `Config` / `Profile` 结构体；
  - 处理字段缺省和类型错误。

---

## 6. 错误处理与 UX

### 6.1 常见错误场景

- 配置文件不存在：
  - 提示实际查找路径；
  - 引导使用 `hikkoshi example > ~/.config/hikkoshi/config.toml`；
- TOML 解析失败：
  - 显示解析错误信息（来源于 zig-toml）；
  - 标注配置文件路径；
- profile 不存在：
  - 显示错误信息；
  - 列出现有 profile 名称；
  - 建议用 `hikkoshi list` 查看；
- 参数不完整：
  - 没有 `<profile>` 或 `<command>`；
  - 打印简明 usage。

### 6.2 帮助与文档

- `hikkoshi --help`：
  - 展示：
    - 基本用法：`hikkoshi <profile> <command> [args...]`；
    - 子命令：`list` / `show` / `config-path` / `example`；
    - TOML Schema 简要说明；
    - 示例配置片段。

---

## 7. 后续扩展方向（留坑）

这些不是 v0.1 必须实现，但设计时可以预留空间：

- Profile 继承 / 叠加：
  - 例如 `base = "work"`，在其基础上增加少量 env；
- 临时覆盖：
  - 通过命令行选项对某个 env 做一次性覆盖；
- 自动创建目录：
  - 在第一次使用某个 profile 时自动创建对应目录树；
- 更细粒度的 PATH 控制：
  - 在配置中对 PATH 做追加/前置，而不是完全覆盖。

目前版本的目标是：**先把「基于 HOME 的 XDG 环境 + 子进程运行」打通，并保持实现简单清晰。**
