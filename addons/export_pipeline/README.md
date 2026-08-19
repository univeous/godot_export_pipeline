# Export Pipeline

[English](README.md) | [简体中文](README.zh-CN.md)

Export Pipeline makes smaller Godot exports at two independent layers. Its main
workflow traces which project files the game can actually reach and removes
files proven unused from the exported PCK (or an executable with an embedded
PCK). Its optional advanced workflow also derives a smaller custom Godot export
template by disabling unused engine classes and modules.

For GDScript projects, this is a safer alternative to maintaining a manual
export allow-list when scripts, autoloads, resources, translations, or
dynamically loaded content are involved.

The plugin has three parts:

| Part | File | Role |
|---|---|---|
| Analyzer | `addons/export_pipeline/analyzer/export_analyzer.gd` | Computes which files the exported game can actually reach |
| PCK pruner | `addons/export_pipeline/` | Skips unreachable project files while Godot builds the PCK |
| Template trimmer (optional) | `addons/export_pipeline/build_profile_gen.gd` | Derives an engine build profile + SCons module list from the analysis |

Its design principle is **fail-open**: anything the analysis cannot prove unused
stays in the export. Ambiguous cases, such as a computed path passed to `load()`,
become actionable warnings instead of being removed by guesswork.

## Features

- Produces HTML, Markdown, and JSON reachability reports with evidence for every
  unused file.
- Prunes unreachable project files from the exported PCK without rewriting the
  project on disk.
- Handles scenes, resources, scripts, autoloads, translations, imported assets,
  text-based content files, asset registries, and TileSet source trimming.
- Supports project-specific analyzer and export extensions.
- Separately and optionally derives a custom engine build profile and SCons
  module allow-list; PCK pruning does not require a custom engine build.
- Allows per-preset opt-out through the `no_prune` custom feature.

## Results in practice

- [Purge Protocol](https://etheremia.itch.io/purge-protocol), a shipped Windows
  game, was reduced from approximately **2 GB to 91 MB** using Export Pipeline.
- The plugin is also in active use in an unreleased commercial project.

Purge Protocol was built for a game jam, and many experimental 3D models were
left in the project while ideas were being tested. That made it an unusually
strong pruning case. These are author-reported production results, not a fixed
compression ratio: a project that plans and cleans up its assets throughout
development will usually see a smaller reduction. Savings also depend on whether
the optional custom engine-template trimming workflow is used.

## Requirements and compatibility

- Godot 4.7 is the current development target.
- Earlier Godot 4 releases are not part of the compatibility promise yet.
- Dependency analysis currently supports **GDScript projects only**. C# source
  references are not analyzed or tested, so C# projects are not currently
  supported for safe pruning.
- The standard export-pruning workflow has no external dependencies.
- Building a trimmed custom engine template requires a matching Godot source
  checkout, SCons 4.4 or newer (or `uvx scons`), and the platform toolchain.

## Installation

1. Copy `addons/export_pipeline/` into the same path in your Godot project.
2. Open **Project > Project Settings > Plugins** and enable **Export Pipeline**.
3. Keep the export preset's resource filter set to **Export all resources**.
   The plugin performs the subtraction during export.

The plugin creates `tools/export_analyzer.json` on first analysis. Commit that
configuration if it describes project behavior; generated reports and prune logs
can usually remain untracked.

## Quick start

```
# 1. Analyze (from the project root; also available in-editor:
#    Project > Tools > Run Export Analysis)
godot --headless --path . -s addons/export_pipeline/analyzer/export_analyzer.gd

# 2. Read the report
tools/export_report.html   # human-friendly (also .md / .json)
#    Every unused file carries evidence: excluded on purpose (and by which
#    config entry / extension), gated by an extension (e.g. an unused
#    registry member), referenced only from unreachable files, or genuinely
#    unreferenced. Files that are excluded BUT still referenced from
#    reachable code get their own section — pruning would break those.

# 3. Fix warnings via tools/export_analyzer.json (see below), re-run,
#    repeat until the warnings you care about are gone.

# 4. Export normally from the editor or Godot CLI. The enabled export plugin
#    re-runs the analysis and skips files proven unused.
```

The first run creates `tools/export_analyzer.json` with defaults.

This repository does **not** require or provide an `export.ps1` or
`release.ps1`. Export with the Godot editor or `godot --export-debug` /
`godot --export-release`. Any project-specific release orchestration should
call those standard commands and then smoke-test the produced build.

## How reachability works

Roots: the main scene, autoloads, `res://` / `uid://` values in
project.godot (minus known editor-only settings), and everything in
`extra_roots` / `dynamic_load_whitelist`. From there the analyzer follows:

- `ext_resource` / quoted paths in `.tscn` / `.tres` / shaders
- `preload` / `load` / `extends` string literals in scripts (absolute and
  relative), `class_name` references, engine-class identifiers
- dependencies of binary `.res` / `.scn` (via the resource loader)
- content DSL files (`text_scan_extensions`, default `.dialogue`):
  quoted paths + global class references
- asset-registry members and tileset sources (see Extensions)

Directories are **never** expanded implicitly: a directory path found in a
script or setting only produces a warning; only configured whitelist
entries expand.

## Configuration (`tools/export_analyzer.json`)

| Key | Meaning |
|---|---|
| `extra_roots` | Files/dirs treated as reachable roots |
| `dynamic_load_whitelist` | Same as extra_roots; declares dirs loaded at runtime by computed names |
| `editor_only` | `res://` prefixes that never ship, even if referenced. Autoloads pointing here are dropped from exported settings |
| `ignored_settings` | Additional project.godot settings whose paths are not roots |
| `ignored_autoloads` | Autoload names that never ship (when `editor_only` on the addon dir isn't suitable) |
| `text_scan_extensions` | Content DSL extensions to scan (default `["dialogue"]`) |
| `extensions` | Analyzer extension scripts (default: asset_registry) |
| `registry_markers` / `registry_scripts` | How registry scripts are recognized (marker string in file, or explicit paths) |
| `registry_patterns` | Wrapper-member asset templates, e.g. `{"Character": "res://game/scenes/portraits/{member}.tscn"}` (string or array) |
| `tileset_tree_shake_dirs` | TileSet dirs shaken to painted sources |
| `tileset_tree_shake_keep` | `{path: [source ids]}` or `{path: "all"}` for runtime-driven tiles |
| `prune_on_export` | Master switch for the pruner (default true) |
| `prune_refresh_analysis` | Re-run analysis at export time (default true) |
| `build_text_server` | `"adv"` (default) or `"fb"`; fb is much smaller but RichTextLabel requires adv |
| `build_extra_modules` / `build_exclude_modules` | Manual scons module list adjustments |

## Reading warnings

Every warning is a decision the analysis could not make for you:

- **Dynamic load in X:N** — a `load()` with a non-literal argument.
  Whitelist the target directory, or ignore if it's editor-only code.
- **Directory reference ... not expanded** — a script/setting mentions a
  directory. Add to `dynamic_load_whitelist` if its contents load at
  runtime; ignore otherwise.
- **Format-string load target** — same, for `"%s%s.ext" % [...]` patterns.
- **Missing file / Unresolvable uid** — a genuinely broken reference in
  your project. Fix or delete.
- **Runtime file references editor-only 'X'** — a file that ships imports
  one that doesn't. This will break at runtime; restructure or whitelist.

In the HTML report, warnings mentioning `res://addons/` are hidden by
default (usually third-party noise) — tick the checkbox to see them.

## The pruner (`addons/export_pipeline/`)

On every export it re-runs the analysis (unless `prune_refresh_analysis`
is false), then:

- `skip()`s every unused file, everything under `editor_only` prefixes,
  `res://tools/`, and itself;
- drops `ignored_autoloads` and editor-only autoloads from the exported
  project settings (in-memory only; your project.godot is never written);
- strips dead tileset sources from exported TileSets (resource
  customization), so they never reference pruned textures;
- disables TileMapLayer/TileMap navigation in exported scenes when the
  build profile compiled navigation out (`disable_navigation_2d` in
  `tools/engine.build`): the flag defaults to on, and against a template
  without the navigation module every nav-enabled cell spams
  `navigation_map.is_null()` errors. Set `"strip_unused_navigation": false`
  in the config to keep the flags;
- writes `tools/export_prune_log.json` (audit list of skipped files).

Add a `no_prune` custom feature to an export preset to bypass pruning for
that preset. Keep `export_filter="all_resources"` — pruning is subtractive.

## Analyzer extensions

Project-specific semantics plug in via scripts listed in `extensions`.
All methods optional:

```gdscript
func extension_name() -> String
func setup(analyzer) -> void
func claim_file(path) -> bool        # own this file's dependency extraction
func process_script(analyzer, path, raw, code) -> bool
                                     # true = suppress default path marking
func finalize(analyzer) -> bool     # fixpoint pass; true = marked new files
func report(analyzer) -> Dictionary # merged into report JSON
func report_markdown(analyzer) -> PackedStringArray
func explain_unused(analyzer, path) -> String
                                     # evidence line for an unused file the
                                     # extension gated ("" = no claim)
# pruner-side (see export_pruner.gd header for the full list):
func customize_resource(resource, path) -> Resource  # or null = unchanged
func customize_scene(scene: Node, path) -> Node      # or null = unchanged
```

Analyzer API: `mark_used(path, referrer)`, `is_used(path)`, `used_files()`,
`get_config(key, default)`, `get_text_cache()`, `warn(msg)`.

Built-ins: `asset_registry.gd` (member-level gating of generated asset
registries — only members referenced from used code pull their assets) and
`tileset_tree_shake.gd` (TileSets keep only atlas sources actually painted
in used scenes; parses `tile_map_data`).

## Custom export template (engine trimming)

This is optional and independent from PCK pruning. You can use the standard
Godot export template and still remove unreachable project files from the PCK.

Before generating a trimmed template, prepare:

- a Godot source checkout matching the exact engine version used by the project;
- Python and SCons 4.4 or newer (or `uv`, so the command can use `uvx scons`);
- a supported C/C++ compiler and the SDK/toolchain for the target platform.

The plugin does not install these build dependencies. Follow Godot's
[official compilation documentation](https://docs.godotengine.org/en/stable/contributing/development/compiling/index.html)
and the linked page for the target platform.

```
godot --headless --path . -s addons/export_pipeline/build_profile_gen.gd
```

Reads the report and writes `tools/engine.build` (usable in the editor's
Engine Compilation Configuration dialog or directly with scons) and prints
the full scons command, including a derived
`modules_enabled_by_default=no` whitelist.

The printed command uses `platform=windows` as a concrete example. To build for
another target, replace it with Godot's platform identifier, such as
`linuxbsd`, `macos`, `web`, `android`, or `ios`, then adjust `arch`, output
names, and toolchain-specific options according to that platform's compilation
guide. The generated `engine.build` and module choices remain inputs to the
build, but cross-compilation is only available where Godot and the installed
toolchain support it.

Keep-set derivation: report engine classes + deep walk of all used
resources (covers binary internals and code-only-loaded assets) + engine
identifiers in used scripts (comments stripped) + `InputEvent`/`StyleBox`
subtrees + settings-embedded objects + **API closure** over method-return
and property types (GDScript type inference can depend on classes never
named in source). Only Node/Resource descendants are disabled.

Build options and subsystem modules are decided from **positive evidence**,
never from the closure (which keeps `Camera3D` in every project via
`Viewport.get_camera_3d()`) and never from default-enabled flags
(`TileMapLayer.navigation_enabled` is on by default and proves nothing):

- `disable_3d` — no Node3D/VisualInstance3D descendant in scenes, scripts
  or resource data;
- navigation (`navigation_2d/3d` module vs `disable_navigation_2d/3d`) —
  nav node/resource classes actually referenced, `NavigationServer2D/3D`
  or the world navigation map touched in scripts, TileSets defining
  navigation layers, `bake_navigation` on GridMaps. Unused nav is compiled
  out AND stripped from exported scenes (see export_pruner above); force it
  with `"build_extra_modules": ["navigation_2d"]`;
- physics (`godot_physics_2d/3d`/`jolt_physics` module vs
  `disable_physics_2d/3d`) — collision/joint/raycast/shapecast node
  evidence, `Physics*QueryParameters*`/`PhysicsDirectSpaceState*`/
  `PhysicsServer2D/3D` references (query classes are RefCounted — a
  raycast-query-only project has physics with zero collision nodes),
  `direct_space_state` in script text, or any used TileSet with physics
  layers (TileMapLayer talks to the physics server directly, with no
  physics node in any scene); force with
  `"build_extra_modules": ["godot_physics_2d"]` (or `_3d`/`jolt_physics`);
- `disable_advanced_gui` — no class gated by `ADVANCED_GUI_DISABLED`
  (Tree, PopupMenu, TextEdit, RichTextLabel, GraphEdit, SpinBox,
  SubViewportContainer, dialogs, split containers, …) in the evidence set.

Two more derived pieces: textures imported as Basis Universal
(`compress/mode=4` in a used file's `.import` sidecar) pull in the
`basis_universal` transcoder module, and a `gl_compatibility`-only project
gets `vulkan=no` in the printed scons command (the RenderingDevice
backends can't be reached).

The class→option rules are shared with export_pruner
(`pipeline_defaults.gd`): its staleness check on every export flags used
classes that the current profile disables either by name or via a
`disable_*` build option.

**Always validate**: build the template, then run your pruned pck on it
(put `game.pck` next to the renamed template exe) and watch stderr — every
line of the analysis→compile→smoke-test loop above was earned from a real
failure. Remaining blind spot: `ClassDB.instantiate()` with computed
strings; grep for it before trusting a profile.

The profile generator prints the SCons command and template installation path.
After installing the template, select it in the export preset's
`custom_template` option, export through Godot, and smoke-test that artifact.
`set_preset_template.gd` is a low-level helper for release automation; callers
must back up and restore `export_presets.cfg` if the change should be temporary.

## Known limitations

- Dynamic paths built at runtime are invisible; the warning + whitelist
  loop is the contract.
- Registry string-matching is fail-open: a member named `"test"` matches
  any `"test"` string in used code and stays.
- Content scans are lexical, not AST-level.
- C# source dependencies are not analyzed; C# project support is unknown and
  must not be assumed.
- The pruner does not rewrite `.godot/global_script_class_cache.cfg`;
  stale entries for pruned scripts are harmless in practice (verified),
  but a class cache filter may be added later.

## License

[MIT](LICENSE) © 2026 univeous.
