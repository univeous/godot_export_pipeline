# 导出管线

基于可达性分析的导出方案，替代 Godot 自带的"导出选中场景及依赖"（该模式
在 Godot 4 中无法正确追踪脚本依赖），并附带引擎模板裁剪。三个部分：

| 部分 | 文件 | 职责 |
|---|---|---|
| 分析器 | `addons/export_pipeline/analyzer/export_analyzer.gd` | 计算导出后的游戏实际可达的文件集合 |
| 裁剪插件 | `addons/export_pipeline/` | 导出时跳过其余所有文件 |
| 模板裁剪 | `addons/export_pipeline/build_profile_gen.gd` | 从分析结果推导引擎 build profile 和 scons 模块清单 |

设计原则：**fail-open（宁多勿漏）**。分析无法证明未使用的文件一律导出；
分析看不见的东西（动态拼路径的 `load()`）一律以警告的形式交给你用配置
决定，绝不猜测。

## 快速上手

```
# 1. 分析（在项目根目录执行；编辑器内也可：Project > Tools > Run Export Analysis）
godot --headless --path . -s addons/export_pipeline/analyzer/export_analyzer.gd

# 2. 看报告
tools/export_report.html   # 人类友好（另有 .md / .json）

# 3. 根据警告调整 tools/export_analyzer.json（见下），重跑，
#    直到你关心的警告清零。

# 4. 正常导出。export_pruner 插件（在 Project Settings > Plugins 启用）
#    会自动重跑分析并跳过未使用文件。
```

首次运行会生成带默认值的 `tools/export_analyzer.json`。

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
```

分析器 API：`mark_used(path, referrer)`、`is_used(path)`、`used_files()`、
`get_config(key, default)`、`get_text_cache()`、`warn(msg)`。

内置扩展：`asset_registry.gd`（生成式资产注册表的成员级 gating——只有被
已用代码引用的成员才拉入其资产）和 `tileset_tree_shake.gd`（TileSet 只保
留场景里实际画过的 atlas source；解析 `tile_map_data`）。

## 自定义导出模板（引擎裁剪）

```
godot --headless --path . -s addons/export_pipeline/build_profile_gen.gd
```

读取报告，写出 `tools/engine.build`（可在编辑器的 Engine Compilation
Configuration 对话框中使用，或直接喂给 scons），并打印完整 scons 命令，
含推导出的 `modules_enabled_by_default=no` 模块白名单。

保留集的推导：报告里的引擎类 + 所有已用资源的深度遍历（覆盖二进制内部
类型与纯代码加载的资产）+ 已用脚本中的引擎类标识符（剥离注释）+
`InputEvent`/`StyleBox` 必留子树 + 设置内嵌对象 + **API 闭包**（保留类
的方法返回类型与属性类型——GDScript 类型推断可能依赖源码中从未出现的
类名）。只有 Node/Resource 后代会被禁用。

**务必实测**：编出模板后，把剪枝 pck 与改名后的模板 exe 同名放一起运行
并盯 stderr——上面"分析→编译→冒烟"闭环里的每一条规则都来自一次真实
失败。剩余盲区：`ClassDB.instantiate()` 传入运行时拼出的字符串；信任
profile 前先 grep 一遍。

## 已知局限

- 运行时拼出的路径不可见；"警告 + 白名单"循环就是契约。
- registry 字符串匹配是 fail-open 的：名叫 `"test"` 的成员会被任何
  `"test"` 字符串保活。
- 内容扫描是词法级而非 AST 级。
- 裁剪插件不改写 `.godot/global_script_class_cache.cfg`；被剪脚本的
  残留条目实测无害，后续可能加过滤。
