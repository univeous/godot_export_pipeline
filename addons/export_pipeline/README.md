# Export Pipeline

A reachability-based replacement for Godot's broken "Export selected scenes
(and dependencies)" mode, plus engine-template trimming. Three parts:

| Part | File | Role |
|---|---|---|
| Analyzer | `addons/export_pipeline/analyzer/export_analyzer.gd` | Computes which files the exported game can actually reach |
| Pruner | `addons/export_pipeline/` | Skips everything else during export |
| Template trimmer | `addons/export_pipeline/build_profile_gen.gd` | Derives an engine build profile + scons module list from the analysis |

Design principle: **fail-open**. Anything the analysis cannot prove unused is
exported. Anything it cannot see (dynamic `load()` with computed paths) is
surfaced as a warning for you to decide via config, never guessed.

## Quick start

```
# 1. Analyze (from the project root; also available in-editor:
#    Project > Tools > Run Export Analysis)
godot --headless --path . -s addons/export_pipeline/analyzer/export_analyzer.gd

# 2. Read the report
tools/export_report.html   # human-friendly (also .md / .json)

# 3. Fix warnings via tools/export_analyzer.json (see below), re-run,
#    repeat until the warnings you care about are gone.

# 4. Export normally. The export_pruner addon (enable it in Project
#    Settings > Plugins) re-runs the analysis and skips unused files.
```

The first run creates `tools/export_analyzer.json` with defaults.

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

```
godot --headless --path . -s addons/export_pipeline/build_profile_gen.gd
```

Reads the report and writes `tools/engine.build` (usable in the editor's
Engine Compilation Configuration dialog or directly with scons) and prints
the full scons command, including a derived
`modules_enabled_by_default=no` whitelist.

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
- 2D physics — CollisionObject2D/Joint2D evidence, or any used TileSet with
  physics layers (TileMapLayer talks to the physics server directly, with
  no physics node in any scene).

**Always validate**: build the template, then run your pruned pck on it
(put `game.pck` next to the renamed template exe) and watch stderr — every
line of the analysis→compile→smoke-test loop above was earned from a real
failure. Remaining blind spot: `ClassDB.instantiate()` with computed
strings; grep for it before trusting a profile.

## Known limitations

- Dynamic paths built at runtime are invisible; the warning + whitelist
  loop is the contract.
- Registry string-matching is fail-open: a member named `"test"` matches
  any `"test"` string in used code and stays.
- Content scans are lexical, not AST-level.
- The pruner does not rewrite `.godot/global_script_class_cache.cfg`;
  stale entries for pruned scripts are harmless in practice (verified),
  but a class cache filter may be added later.
