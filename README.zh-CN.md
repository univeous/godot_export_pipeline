# Export Pipeline

[简体中文](README.zh-CN.md) | [English](README.md)

这是一个我在内部使用的 Godot 导出工具。我已经在公开和未公开的项目里用过
它，案例见下文。AI 在这个插件的开发中做了很多工作。

它主要做两件事：

- 对 PCK：分析项目里哪些文件在运行时真的可达，导出时跳过其余资源。
- 对导出模板：找出项目实际使用的引擎类和模块，生成 build profile，并给出
  编译较小导出模板的 SCons 命令。

两部分互相独立。只想裁 PCK，不想自己编译 Godot，也可以正常使用。

插件只在分析和导出阶段工作。它不会改写您的场景、资源或脚本；它会在
`res://tools/` 下写配置、报告和日志。如果您按照下面的步骤操作后，导出的
项目仍然无法运行或出现缺失资源，请到
[Issues](https://github.com/univeous/godot_export_pipeline/issues) 里告诉我。

目前只支持 GDScript 项目。我没有实现 C# 源码依赖分析，也没有在 C# 项目里
验证过它，所以暂时不要把它用在 C# 项目上。当前开发和测试版本是 Godot 4.7。

## 安装和快速上手

下载仓库，把 `addons/export_pipeline/` 放到项目的同名目录，然后在
**项目 > 项目设置 > 插件** 中启用 **Export Pipeline**。

### 裁剪 PCK

像以前一样导出，只需把导出预设的资源过滤设为**导出所有资源**。插件会在
导出时运行分析，并从最终 PCK 中跳过不可达文件。

- 如果项目没有通过拼接字符串等方式动态加载资源，通常到这里就够了。
- 如果有，分析器会把无法判断的 `load()` / `ResourceLoader.load()` 写进
  警告和报告。把对应文件或目录加入
  `tools/export_analyzer.json` 的 `dynamic_load_whitelist`，重新分析即可。
- 如果某个导出预设不想裁剪，在它的 custom features 中加入 `no_prune`。
- 可以从 **项目 > 工具 > Run Export Analysis** 手动分析。结果在
  `tools/export_report.html`，里面会说明哪些文件保留、哪些文件跳过，以及
  判断依据。

第一次运行会自动创建 `tools/export_analyzer.json`。这个配置建议提交到版本
控制；HTML/Markdown/JSON 报告和 prune log 通常不用提交。

`res://tools/` 目前还是固定路径，不能从项目设置里修改。我准备把这些路径放
进 ProjectSettings，再补一个简单的首次使用页面；现在还没有做。

这个仓库不依赖 `export.ps1` 或 `release.ps1`。从编辑器正常导出，或者使用
Godot 自带的 `--export-debug` / `--export-release` 即可。

### 裁剪导出模板

这一部分需要您事先配好 Godot 的编译环境。插件不会帮您安装 Python、SCons、
编译器或平台 SDK。请先看
[Godot 官方编译文档](https://docs.godotengine.org/zh-cn/stable/contributing/development/compiling/index.html)。

从 **项目 > 工具 > Generate Build Profile** 运行。菜单会先自动分析项目；首次
运行时也会一并创建默认配置和报告，然后再生成 build profile、打印 SCons
命令。

如果从命令行运行，请先执行分析器：

```sh
godot --headless --path . -s addons/export_pipeline/analyzer/export_analyzer.gd
godot --headless --path . -s addons/export_pipeline/build_profile_gen.gd
```

它会写出 `tools/engine.build`，并按本机 OS 打印 SCons 命令：Windows、
macOS、Linux/BSD 分别对应 `windows`、`macos`、`linuxbsd`。需要交叉编译时，
在 `tools/export_analyzer.json` 里设置 `build_platform`，必要时再设置
`build_arch`。另外也接受 `web`、`android` 和 `ios`。目标平台的工具链仍需
您自己准备，并按对应平台的官方编译文档配置。

编译完成后，在 Godot 的导出预设里把生成的可执行文件设为 custom template。
build profile 会随着项目内容变化。正式发布前最好重新生成并重新编译一次；
如果 SCons 缓存还在，通常不会重新编译全部文件。

## 案例

[Purge Protocol](https://etheremia.itch.io/purge-protocol) 是一个 game jam
作品。开发时为了试验方案，我们往项目里放了很多最后没有用到的 3D 模型。
使用这个插件后，Windows 成品从约 2 GB 缩小到 91 MB。

这是一个比较极端的例子。如果您从一开始就规划目录并持续清理资产，改善
一般不会这么大；使用的是不是自定义裁剪模板也会影响最终数字。

我还在一个未公开的商业项目里使用这个插件，目前不能提供更多细节。

## 细节

### 它怎么判断文件是否可达

分析从主场景、autoload、`project.godot` 中的资源路径，以及您手动配置的根
开始，然后继续追踪：

- 场景、资源和 shader 中的 `ext_resource` 与资源路径；
- GDScript 中字面量形式的 `preload()`、`load()`、`extends`、`class_name`
  和引擎类引用；
- 二进制 `.res` / `.scn` 的 ResourceLoader 依赖；
- `.dialogue` 等可配置文本格式里的路径和全局类；
- 导入资源的 `.import` / remap 关系；
- 内置扩展识别的 asset registry 成员和 TileSet source。

目录不会因为在脚本中出现就自动展开。分析器不知道运行时究竟会从目录里
取什么，所以只会报警；要保留整个目录，请明确加入白名单。

这个策略是 fail-open：能确认没用的才删除，拿不准的尽量保留或报警。不过
分析器看不到 C# 依赖，也不可能自动理解所有运行时拼出的路径，因此最终
发布前仍然需要实际运行导出成品。

### 配置

配置文件是 `tools/export_analyzer.json`。常用项目如下：

| 项目 | 用途 |
|---|---|
| `extra_roots` | 额外作为分析起点的文件或目录 |
| `dynamic_load_whitelist` | 运行时通过名字或拼接路径加载的文件/目录 |
| `editor_only` | 永远不进入运行时导出的路径前缀 |
| `ignored_settings` | 不应成为分析起点的 `project.godot` 设置 |
| `ignored_autoloads` | 不随游戏导出的 autoload 名称 |
| `text_scan_extensions` | 需要按文本扫描的内容文件扩展名 |
| `extensions` | 分析和导出扩展脚本 |
| `tileset_tree_shake_dirs` | 只保留实际使用 source 的 TileSet 目录 |
| `tileset_tree_shake_keep` | TileSet 中由运行时代码使用、必须额外保留的 source |
| `prune_on_export` | 是否在导出时启用 PCK 裁剪 |
| `prune_refresh_analysis` | 每次导出前是否重新分析 |
| `build_text_server` | 自定义模板使用 `adv` 还是较小的 `fb` text server |
| `build_platform` | SCons 目标平台；`auto` 跟随本机 OS |
| `build_arch` | 目标架构；`auto` 跟随当前 Godot 编辑器 |
| `build_extra_modules` | 自定义模板中手动补充的 Godot 模块 |
| `build_exclude_modules` | 自定义模板中手动排除的 Godot 模块 |

### 常见警告

- **Dynamic load**：`load()` 的参数不是字符串字面量。确认目标后加入白名单。
- **Directory reference ... not expanded**：代码提到了目录，但分析器没有展开。
- **Format-string load target**：路径通过 `%s` / `%d` 等格式化生成。
- **Missing file / Unresolvable uid**：项目里存在失效引用，需要修复或删除。
- **Runtime file references editor-only**：会导出的文件引用了被标记为
  editor-only 的文件，按当前配置导出后会坏。

HTML 报告默认隐藏一部分 `res://addons/` 警告，避免第三方插件噪音；需要时
可以在页面里显示。

### 导出时具体做什么

每次导出前，插件默认重新运行分析，然后：

- 跳过不可达文件、`editor_only` 路径、`res://tools/` 和插件自身；
- 从导出态 ProjectSettings 中移除 editor-only autoload，不修改磁盘上的
  `project.godot`；
- 按需从导出的 TileSet 中移除未使用 source；
- 如果自定义 build profile 已经编译掉 navigation，则同步关闭导出场景里
  未使用的 TileMap navigation；
- 写出 `tools/export_prune_log.json` 供检查。

### 自定义导出模板的判断

`build_profile_gen.gd` 会综合报告中的引擎类、已用资源的内部类型、GDScript
中的引擎类标识符、项目设置中的对象，以及 API 返回类型/属性类型的闭包，
生成 `tools/engine.build`。

3D、navigation、physics、advanced GUI、纹理转码器和 text server 等模块
会按正向证据保留。若项目有反射调用、运行时类名或其他分析器无法看到的
入口，可以通过 `build_extra_modules` 手动补充。

自定义模板必须实际测试。生成 PCK 后，用新模板运行它并检查 stderr。项目
增加资源或功能后，旧的 build profile 可能已经过期；导出插件会检查一部分
已知冲突，但不能替代完整的冒烟测试。

### 扩展

项目有特殊资源规则时，可以在 `extensions` 中加入脚本。扩展可以接管某类
文件的依赖提取、补充可达文件、解释 unused 原因，或在导出阶段定制资源和
场景。接口与内置例子位于 `addons/export_pipeline/analyzer/ext/`。

## 许可证

[MIT](LICENSE)，Copyright © 2026 univeous。
