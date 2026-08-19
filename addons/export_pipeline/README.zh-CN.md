# 导出管线

[English](README.md) | [简体中文](README.zh-CN.md)

Export Pipeline（导出管线）从两个互相独立的层面缩小 Godot 导出体积。
主要流程追踪游戏实际可达的项目文件，从导出的 PCK（或内嵌 PCK 的可执行
文件）中移除已经证明不会使用的内容；可选的高级流程则通过禁用未使用的
引擎类和模块，生成更小的自定义 Godot 导出模板。

对于 GDScript 项目，当项目含有脚本、autoload、资源、翻译或动态加载内容
时，它比手工维护导出白名单更可靠。

插件由三个部分组成：

| 部分 | 文件 | 职责 |
|---|---|---|
| 分析器 | `addons/export_pipeline/analyzer/export_analyzer.gd` | 计算导出后的游戏实际可达的文件集合 |
| PCK 裁剪插件 | `addons/export_pipeline/` | Godot 构建 PCK 时跳过不可达的项目文件 |
| 模板裁剪（可选） | `addons/export_pipeline/build_profile_gen.gd` | 从分析结果推导引擎 build profile 和 SCons 模块清单 |

设计原则是 **fail-open（宁多勿漏）**：无法证明未使用的文件一律保留。
动态拼路径的 `load()` 等模糊情况会变成可处理的警告，不会被猜测性删除。

## 功能

- 生成 HTML、Markdown 和 JSON 可达性报告，并为每个 unused 文件提供证据；
- 从正常 Godot 导出生成的 PCK 中裁剪不可达项目文件，不改写磁盘上的项目内容；
- 处理场景、资源、脚本、autoload、翻译、导入资产、文本内容文件、
  asset registry 与 TileSet source 裁剪；
- 支持项目自定义的分析器扩展和导出扩展；
- 另行、可选生成自定义引擎 build profile 与 SCons 模块白名单；PCK 裁剪
  不要求使用自定义引擎；
- 可通过导出预设的 `no_prune` custom feature 单独关闭裁剪。

## 实际案例

- 已发布的 Windows 游戏 [Purge Protocol](https://etheremia.itch.io/purge-protocol)
  使用 Export Pipeline 后，体积从约 **2 GB 缩小到 91 MB**；
- 本插件也正在一个尚未公开的商业项目中使用。

Purge Protocol 是 game jam 作品；为了快速试验不同方案，项目里曾放入大量
最终没有使用的 3D 模型，因此它是一个收益特别明显的裁剪案例。以上是作者
在真实项目中的结果，并不代表固定压缩率：如果项目从一开始就规划并持续
清理资产，通常不会得到同等幅度的缩减。实际结果也取决于是否同时采用可选
的自定义引擎模板裁剪流程。

## 要求与兼容性

- 当前开发目标为 Godot 4.7；
- 暂不承诺兼容更早的 Godot 4 版本；
- 依赖分析当前**仅支持 GDScript 项目**。插件不会分析 C# 源码中的资源引用，
  也未对 C# 项目做过验证，因此目前不能把 C# 项目视为安全支持范围；
- 标准的导出裁剪流程不依赖外部工具；
- 编译裁剪后的自定义引擎模板需要匹配版本的 Godot 源码、SCons 4.4+
  （或 `uvx scons`）以及目标平台工具链。

## 安装

1. 把 `addons/export_pipeline/` 复制到 Godot 项目的同名路径；
2. 打开 **项目 > 项目设置 > 插件**，启用 **Export Pipeline**；
3. 导出预设的资源过滤保持为**导出所有资源**，由本插件在导出阶段做减法。

首次分析会生成 `tools/export_analyzer.json`。若其中配置描述了项目的运行时
行为，建议纳入版本控制；自动生成的报告和裁剪日志通常无需提交。

## 快速上手

```
# 1. 分析（在项目根目录执行；编辑器内也可：Project > Tools > Run Export Analysis）
godot --headless --path . -s addons/export_pipeline/analyzer/export_analyzer.gd

# 2. 看报告
tools/export_report.html   # 人类友好（另有 .md / .json）
#    每个 unused 文件都带证据：被刻意排除（写明是哪条配置 / 哪个扩展）、
#    被扩展拦截（如未使用的 registry 成员）、只被其他不可达文件引用、
#    或确实全项目找不到任何引用。被排除但仍被可达代码引用的文件单列一节
#    ——剪掉它们会导致运行时缺文件。

# 3. 根据警告调整 tools/export_analyzer.json（见下），重跑，
#    直到你关心的警告清零。

# 4. 从编辑器或 Godot CLI 正常导出。启用后的导出插件会重跑分析，
#    并跳过已经证明未使用的文件。
```

首次运行会生成带默认值的 `tools/export_analyzer.json`。

本仓库**不要求也不提供** `export.ps1` 或 `release.ps1`。请使用 Godot 编辑器，
或 `godot --export-debug` / `godot --export-release` 完成导出。项目自己的发布
自动化只需调用这些标准命令，并对产物进行冒烟测试。

## 可达性如何计算

根集合：主场景、autoload、project.godot 里的 `res://` / `uid://` 值
（已知编辑器专用设置除外），以及 `extra_roots` / `dynamic_load_whitelist`
里的条目。从根出发追踪：

- `.tscn` / `.tres` / shader 里的 `ext_resource` 与引号路径
- 脚本里的 `preload` / `load` / `extends` 字符串字面量（绝对与相对）、
  `class_name` 引用、引擎类标识符
- 二进制 `.res` / `.scn` 的依赖（走引擎资源加载器）
- 内容 DSL 文件（`text_scan_extensions`，默认 `.dialogue`）：
  引号路径 + 全局类引用
- asset registry 成员与 tileset source（见"扩展"）

目录**永不**隐式展开：脚本或设置里出现的目录路径只产生警告，只有配置
白名单里的目录才会展开。

## 配置（`tools/export_analyzer.json`）

| 键 | 含义 |
|---|---|
| `extra_roots` | 作为可达根的文件/目录 |
| `dynamic_load_whitelist` | 同 extra_roots；声明"运行时按名字动态加载"的目录 |
| `editor_only` | 永不出货的 `res://` 前缀（被引用也不出）。指向这里的 autoload 会从导出设置中摘除 |
| `ignored_settings` | 额外的不作为根的 project.godot 设置 |
| `ignored_autoloads` | 按名字点名不出货的 autoload（不适合整目录拉黑时用） |
| `text_scan_extensions` | 要扫描的内容 DSL 扩展名（默认 `["dialogue"]`） |
| `extensions` | 分析器扩展脚本（默认含 asset_registry） |
| `registry_markers` / `registry_scripts` | registry 脚本的识别方式（文件内标记串，或显式路径） |
| `registry_patterns` | wrapper 成员的资产模板，如 `{"Character": "res://game/scenes/portraits/{member}.tscn"}`（字符串或数组） |
| `tileset_tree_shake_dirs` | 按"画过的 source"收缩的 TileSet 目录 |
| `tileset_tree_shake_keep` | `{路径: [source id]}` 或 `{路径: "all"}`，给运行时代码取用的 tile 兜底 |
| `prune_on_export` | 裁剪总开关（默认 true） |
| `prune_refresh_analysis` | 导出时是否重跑分析（默认 true） |
| `build_text_server` | `"adv"`（默认）或 `"fb"`；fb 小得多，但 RichTextLabel 必须 adv |
| `build_extra_modules` / `build_exclude_modules` | scons 模块清单的手动增删 |

## 警告怎么读

每条警告都是一个分析器无法替你做的决定：

- **Dynamic load in X:N** —— 非字面量参数的 `load()`。目标目录加白名单；
  若是编辑器专用代码则无视。
- **Directory reference ... not expanded** —— 脚本/设置里出现了目录。
  运行时确实会从中加载就加进 `dynamic_load_whitelist`，否则无视。
- **Format-string load target** —— 同上，针对 `"%s%s.ext" % [...]` 模式。
- **Missing file / Unresolvable uid** —— 项目里真实存在的坏引用，修或删。
- **Runtime file references editor-only 'X'** —— 会出货的文件引用了不出货
  的文件，运行时必炸；重构或调整名单。

HTML 报告里涉及 `res://addons/` 的警告默认隐藏（多为第三方噪音），勾选
复选框可展开。

## 裁剪插件（`addons/export_pipeline/`）

每次导出时先重跑分析（`prune_refresh_analysis` 可关），然后：

- 对所有未使用文件、`editor_only` 前缀、`res://tools/` 和它自己 `skip()`；
- 从导出设置中摘除 `ignored_autoloads` 与 editor_only 命中的 autoload
  （仅内存态，绝不改写磁盘上的 project.godot）；
- 通过资源定制从导出的 TileSet 里删掉死 source，保证不引用已剪贴图；
- 当 build profile 判定导航未使用（`tools/engine.build` 里
  `disable_navigation_2d`）时，在导出场景中关闭 TileMapLayer/TileMap 的
  navigation：该开关默认开启，而在没有 navigation 模块的模板上，每个
  开着 nav 的 cell 都会刷一条 `navigation_map.is_null()` 错误。配置
  `"strip_unused_navigation": false` 可保留原开关；
- 写出 `tools/export_prune_log.json`（被跳过文件的审计清单）。

给导出预设加 `no_prune` 自定义 feature 可单独跳过裁剪。预设保持
`export_filter="all_resources"`——裁剪是做减法的。

## 分析器扩展

项目特有的语义通过 `extensions` 里列的脚本接入。方法全部可选：

```gdscript
func extension_name() -> String
func setup(analyzer) -> void
func claim_file(path) -> bool        # 接管该文件的依赖提取
func process_script(analyzer, path, raw, code) -> bool
                                     # true = 抑制默认的路径标记
func finalize(analyzer) -> bool     # fixpoint 迭代；标记了新文件返回 true
func report(analyzer) -> Dictionary # 并入报告 JSON
func report_markdown(analyzer) -> PackedStringArray
func explain_unused(analyzer, path) -> String
                                     # 为扩展所拦截的 unused 文件给出证据行
                                     # （"" = 与本扩展无关）
# 裁剪侧钩子（完整清单见 export_pruner.gd 头部注释）：
func customize_resource(resource, path) -> Resource  # null = 不修改
func customize_scene(scene: Node, path) -> Node      # null = 不修改
```

分析器 API：`mark_used(path, referrer)`、`is_used(path)`、`used_files()`、
`get_config(key, default)`、`get_text_cache()`、`warn(msg)`。

内置扩展：`asset_registry.gd`（生成式资产注册表的成员级 gating——只有被
已用代码引用的成员才拉入其资产）和 `tileset_tree_shake.gd`（TileSet 只保
留场景里实际画过的 atlas source；解析 `tile_map_data`）。

## 自定义导出模板（引擎裁剪）

这一部分是可选功能，与 PCK 裁剪互相独立。即使继续使用 Godot 官方导出
模板，也可以从 PCK 中移除不可达的项目文件。

生成裁剪模板前，请自行准备：

- 与项目实际引擎版本完全一致的 Godot 源码；
- Python 与 SCons 4.4+（或安装 `uv`，让命令使用 `uvx scons`）；
- 受支持的 C/C++ 编译器，以及目标平台所需的 SDK / 工具链。

插件不会代为安装这些编译依赖。请先阅读 Godot 的
[官方编译文档](https://docs.godotengine.org/zh-cn/stable/contributing/development/compiling/index.html)，
再按其中链接进入目标平台对应页面。

```
godot --headless --path . -s addons/export_pipeline/build_profile_gen.gd
```

读取报告，写出 `tools/engine.build`（可在编辑器的 Engine Compilation
Configuration 对话框中使用，或直接喂给 scons），并打印完整 scons 命令，
含推导出的 `modules_enabled_by_default=no` 模块白名单。

打印出的命令以 `platform=windows` 作为具体示例。编译其他目标时，将它替换
为 Godot 的平台标识，例如 `linuxbsd`、`macos`、`web`、`android` 或 `ios`，
并按该平台的官方编译文档调整 `arch`、输出文件名和工具链选项。生成的
`engine.build` 与模块选择仍可作为构建输入；能否跨平台编译则取决于 Godot
及本机已安装工具链的支持范围。

保留集的推导：报告里的引擎类 + 所有已用资源的深度遍历（覆盖二进制内部
类型与纯代码加载的资产）+ 已用脚本中的引擎类标识符（剥离注释）+
`InputEvent`/`StyleBox` 必留子树 + 设置内嵌对象 + **API 闭包**（保留类
的方法返回类型与属性类型——GDScript 类型推断可能依赖源码中从未出现的
类名）。只有 Node/Resource 后代会被禁用。

编译选项与子系统模块只依据**正向证据**判定，绝不依据闭包（闭包会经由
`Viewport.get_camera_3d()` 给每个项目都保留 `Camera3D`），也绝不依据
默认开启的开关（`TileMapLayer.navigation_enabled` 默认为开，说明不了
任何事）：

- `disable_3d`——场景/脚本/资源数据中不存在任何 Node3D/VisualInstance3D
  后代；
- 导航（`navigation_2d/3d` 模块 vs `disable_navigation_2d/3d`）——真实引用
  了导航节点/资源类、脚本中调用 `NavigationServer2D/3D` 或触碰 world
  navigation map、TileSet 定义了 navigation layer、GridMap 开了
  `bake_navigation`。判定未使用则整体编译掉，且导出场景同步剥离（见上
  节裁剪插件）；可用 `"build_extra_modules": ["navigation_2d"]` 强制保留；
- 物理（`godot_physics_2d/3d`/`jolt_physics` 模块 vs
  `disable_physics_2d/3d`）——碰撞/关节/raycast/shapecast 节点证据、
  `Physics*QueryParameters*`/`PhysicsDirectSpaceState*`/`PhysicsServer2D/3D`
  引用（查询类是 RefCounted——纯射线查询的项目可以没有任何碰撞节点）、
  脚本文本中的 `direct_space_state`、或任一已用 TileSet 带 physics
  layer（TileMapLayer 直接对物理服务器建 body，场景里可以没有任何物理
  节点）；可用 `"build_extra_modules": ["godot_physics_2d"]`（或
  `_3d`/`jolt_physics`）强制保留；
- `disable_advanced_gui`——证据集中不存在任何被 `ADVANCED_GUI_DISABLED`
  门控的类（Tree、PopupMenu、TextEdit、RichTextLabel、GraphEdit、
  SpinBox、SubViewportContainer、各类对话框与分割容器等）。

另有两项推导：已用文件的 `.import` 里出现 Basis Universal
（`compress/mode=4`）则加入 `basis_universal` 转码模块；纯
`gl_compatibility` 项目的 scons 命令自动带上 `vulkan=no`（RenderingDevice
后端不可达）。

类→选项规则与裁剪插件共享（`pipeline_defaults.gd`）：每次导出的过期
检查会同时标出被 profile 按名字禁用、以及被 `disable_*` 编译选项整族
编掉的已用类。

**务必实测**：编出模板后，把剪枝 pck 与改名后的模板 exe 同名放一起运行
并盯 stderr——上面"分析→编译→冒烟"闭环里的每一条规则都来自一次真实
失败。剩余盲区：`ClassDB.instantiate()` 传入运行时拼出的字符串；信任
profile 前先 grep 一遍。

profile 生成器会打印 SCons 命令和模板安装路径。安装模板后，在导出预设的
`custom_template` 中选择它，再通过 Godot 导出并对产物做冒烟测试。
`set_preset_template.gd` 是供发布自动化使用的底层辅助脚本；如果修改只应
临时生效，调用方必须自行备份并恢复 `export_presets.cfg`。

## 已知局限

- 运行时拼出的路径不可见；"警告 + 白名单"循环就是契约。
- registry 字符串匹配是 fail-open 的：名叫 `"test"` 的成员会被任何
  `"test"` 字符串保活。
- 内容扫描是词法级而非 AST 级。
- 不分析 C# 源码依赖；C# 项目的兼容性未知，不能默认可用。
- 裁剪插件不改写 `.godot/global_script_class_cache.cfg`；被剪脚本的
  残留条目实测无害，后续可能加过滤。

## 许可证

[MIT](LICENSE) © 2026 univeous。
