# Export Pipeline

[English](README.md) | [简体中文](README.zh-CN.md)

This is a Godot export tool I use internally. It is already in use in public
and private projects; see the examples below. AI did a substantial amount of
work on this plugin.

It mainly does two things:

- For the PCK: analyze which project files are actually reachable at runtime,
  then skip the rest during export.
- For the export template: find the engine classes and modules the project
  actually uses, generate a build profile, and print the SCons command for
  compiling a smaller template.

The two parts are independent. You can prune the PCK without compiling Godot.

The plugin only works during analysis and export. It does not rewrite your
scenes, resources, or scripts. It does write its configuration, reports, and
logs under `res://tools/`. If an exported build is missing files or no longer
runs after you follow the steps below, please open an
[issue](https://github.com/univeous/godot_export_pipeline/issues).

Only GDScript projects are supported at the moment. I have not implemented C#
source dependency analysis or tested this on a C# project, so do not rely on it
there yet. Current development and testing target Godot 4.7.

## Install and get started

Download the repository, copy `addons/export_pipeline/` to the same location in
your project, then enable **Export Pipeline** under
**Project > Project Settings > Plugins**.

### Pruning the PCK

Export as usual, with the preset's resource filter set to **Export all
resources**. The plugin runs its analysis during export and leaves unreachable
files out of the final PCK.

- If the project does not load resources through paths assembled at runtime,
  this is usually all you need.
- If it does, the analyzer reports `load()` / `ResourceLoader.load()` calls it
  cannot resolve. Add the relevant file or directory to
  `dynamic_load_whitelist` in `tools/export_analyzer.json`, then analyze again.
- To disable pruning for one preset, add `no_prune` to its custom features.
- Run **Project > Tools > Run Export Analysis** to analyze manually. Open
  `tools/export_report.html` to see what is kept, what is skipped, and why.

The first run creates `tools/export_analyzer.json`. I recommend committing this
configuration. The generated HTML/Markdown/JSON reports and prune log usually
do not need to be committed.

`res://tools/` is still hard-coded and cannot be changed in Project Settings. I
plan to move these paths into ProjectSettings and add a small first-run page,
but that work is not done yet.

This repository does not depend on `export.ps1` or `release.ps1`. Export from
the editor, or use Godot's own `--export-debug` / `--export-release` commands.

### Trimming the export template

You need a working Godot build environment before using this part. The plugin
does not install Python, SCons, a compiler, or platform SDKs. Start with the
[official Godot compilation documentation](https://docs.godotengine.org/en/stable/contributing/development/compiling/index.html).

Run **Project > Tools > Generate Build Profile**, or execute:

```sh
godot --headless --path . -s addons/export_pipeline/build_profile_gen.gd
```

This writes `tools/engine.build` and prints a SCons command for the host OS:
Windows, macOS, and Linux/BSD map to `windows`, `macos`, and `linuxbsd`.
For a cross-build, set `build_platform` and (if needed) `build_arch` in
`tools/export_analyzer.json`. Other accepted platforms are `web`, `android`,
and `ios`. The target toolchain is still your responsibility; follow that
platform's Godot build guide.

After compiling, select the resulting executable as the custom template in the
Godot export preset. The build profile can change as the project changes, so
regenerate and rebuild it before a final release. With the SCons cache intact,
this normally does not mean recompiling everything.

## Examples

[Purge Protocol](https://etheremia.itch.io/purge-protocol) was made for a game
jam. We put many experimental 3D models into the project while trying ideas,
then left a lot of them unused. Export Pipeline reduced the Windows build from
about 2 GB to 91 MB.

This is an unusually strong case. A project that plans its asset layout and
cleans up throughout development will normally see a smaller improvement. The
use of a custom trimmed engine template also affects the final number.

I also use the plugin in an unreleased commercial project. I cannot share more
about that project yet.

## Details

### How reachability is decided

Analysis starts from the main scene, autoloads, resource paths in
`project.godot`, and any roots added in the configuration. It then follows:

- `ext_resource` and resource paths in scenes, resources, and shaders;
- literal `preload()`, `load()`, and `extends` paths in GDScript, plus
  `class_name` and engine-class references;
- ResourceLoader dependencies of binary `.res` / `.scn` files;
- paths and global classes in configurable text formats such as `.dialogue`;
- `.import` and remap data for imported assets;
- asset-registry members and TileSet sources handled by built-in extensions.

A directory mentioned in code is not expanded automatically. The analyzer
cannot know which file will be selected from it at runtime, so it warns instead.
Add the directory to the whitelist when all or part of it must ship.

The policy is fail-open: remove what can be shown to be unused, and keep or
warn about uncertain cases. This does not make static analysis omniscient. It
cannot see C# dependencies or understand every path assembled at runtime, so a
real test of the exported build is still required.

### Configuration

Configuration lives in `tools/export_analyzer.json`. The commonly used keys are:

| Key | Purpose |
|---|---|
| `extra_roots` | Additional files or directories used as analysis roots |
| `dynamic_load_whitelist` | Files/directories loaded by name or computed path at runtime |
| `editor_only` | Path prefixes that must never ship in a runtime export |
| `ignored_settings` | `project.godot` settings that should not become roots |
| `ignored_autoloads` | Autoload names that should not ship |
| `text_scan_extensions` | Content-file extensions to scan as text |
| `extensions` | Analyzer/export extension scripts |
| `tileset_tree_shake_dirs` | TileSet directories whose unused sources may be removed |
| `tileset_tree_shake_keep` | TileSet sources used by runtime code and kept explicitly |
| `prune_on_export` | Enable PCK pruning during export |
| `prune_refresh_analysis` | Re-run analysis before every export |
| `build_text_server` | Use the `adv` or smaller `fb` text server in a custom template |
| `build_platform` | SCons target platform; `auto` follows the host OS |
| `build_arch` | Target architecture; `auto` follows the running Godot editor |
| `build_extra_modules` | Godot modules to add manually to a custom template |
| `build_exclude_modules` | Godot modules to exclude manually |

### Common warnings

- **Dynamic load**: the argument to `load()` is not a string literal. Add the
  target to the whitelist after checking it.
- **Directory reference ... not expanded**: code mentions a directory, but the
  analyzer did not expand it.
- **Format-string load target**: a path is assembled with `%s`, `%d`, or a
  similar format string.
- **Missing file / Unresolvable uid**: the project contains a broken reference.
- **Runtime file references editor-only**: a file that will ship refers to one
  marked editor-only; the current configuration would break the export.

The HTML report hides some `res://addons/` warnings by default to reduce noise
from third-party plugins. They can be shown from the report page.

### What happens during export

By default the plugin analyzes again before every export, then:

- skips unreachable files, `editor_only` paths, `res://tools/`, and itself;
- removes editor-only autoloads from the in-memory exported ProjectSettings
  without changing `project.godot` on disk;
- removes unused sources from exported TileSets when configured;
- disables unused TileMap navigation in exported scenes when navigation has
  already been compiled out of the custom build profile;
- writes `tools/export_prune_log.json` for inspection.

### How the custom export template is derived

`build_profile_gen.gd` combines engine classes found in the report, types stored
inside used resources, engine identifiers in GDScript, objects in project
settings, and the closure of API return/property types. It writes the result to
`tools/engine.build`.

3D, navigation, physics, advanced GUI, texture transcoders, and the text server
are kept from positive evidence. If the project uses reflection, runtime class
names, or another entry point the analyzer cannot see, add the required module
through `build_extra_modules`.

Always test a custom template. Export the PCK, run it with the new template, and
check stderr. A profile can become stale after the project gains new content or
features. The export plugin catches some known conflicts, but that check is not
a replacement for a smoke test.

### Extensions

Projects with special resource rules can add scripts to `extensions`. An
extension can take over dependency extraction for a file type, add reachable
files, explain why a file is unused, or customize resources and scenes during
export. The interfaces and built-in examples live in
`addons/export_pipeline/analyzer/ext/`.

## License

[MIT](LICENSE), Copyright © 2026 univeous.
