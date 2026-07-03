# godot-export-pipeline

A reachability-based export pipeline for Godot 4 — a working replacement
for the broken "Export selected scenes (and dependencies)" mode, plus
engine-template trimming.

Godot's dependency tracking cannot see script dependencies (`preload`,
`load`, `class_name` references — [godotengine/godot#90643](https://github.com/godotengine/godot/issues/90643)),
which makes selective export unusable in practice
([godot-proposals#11331](https://github.com/godotengine/godot-proposals/issues/11331)).
This addon solves it from the other direction: keep "export all resources",
compute what the game can actually reach, and skip the rest.

## What you get

- **Reachability analyzer** — follows scenes, scripts (`preload`/`load`/
  `class_name`/engine identifiers), binary resources, uid://, dialogue-style
  content DSLs and generated asset registries; everything it cannot prove
  is surfaced as an explicit warning to resolve via black/white lists,
  never guessed. HTML/Markdown/JSON reports.
- **Export pruner** — an `EditorExportPlugin` that skips every unreachable
  file at export time, drops dev-only autoloads from the exported settings,
  and rewrites resources through extensions (e.g. stripping dead tileset
  sources).
- **Engine build profile generator** — derives an `engine.build` profile
  (with API-closure over method return/property types, so GDScript type
  inference stays safe) and a full scons module whitelist from the
  analysis. Measured on a real project: official Windows template 104 MB →
  30.6 MB.
- **Extension mechanism** — one script carries both analyzer-side and
  pruner-side hooks. Ships with: asset-registry member gating, tileset
  tree-shaking, and folder-colors integration (folders colored
  "Don't Export" in the editor become editor-only declarations).
- **`release.ps1`** — one command: export → assert pck contents match the
  analysis (zero leaked / zero missing) → smoke-run; non-zero exit on any
  failure. CI-friendly.

## Install

Copy `addons/export_pipeline/` into your project and enable
**Export Pipeline** in Project Settings > Plugins. Per-project config and
generated reports live in `tools/` (created on first run).

## Quick start

```
godot --headless --path . -s addons/export_pipeline/analyzer/export_analyzer.gd
```

Read `tools/export_report.html`, resolve the warnings you care about via
`tools/export_analyzer.json`, then export normally — the pruner handles
the rest.

Full documentation: [English](addons/export_pipeline/README.md) ·
[中文](addons/export_pipeline/README.zh-CN.md)

## Status

Developed and validated against Godot 4.7 on real projects (a visual novel
and a tileset toolchain). The analysis is fail-open by construction:
anything it cannot prove unused ships.
