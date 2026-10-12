## Writes the files an export prunes into one export preset as an exclusion
## list (export_filter "exclude" + export_files), so Godot itself leaves them
## out instead of only the pruner skipping them.
##
## Why: Godot builds the exported UID cache (.godot/uid_cache.bin) and the
## global class list from the preset's file set BEFORE export plugins run,
## and EditorExportPlugin.skip() does not take a file out of that set
## (EditorExportPlatform::_get_filtered_cache, Godot 4.7). Skipping alone
## therefore keeps every pruned file listed by path in the shipped PCK —
## with "Export all resources", every file in the project. Presets have no
## scripting setters, so the list must already be in export_presets.cfg when
## the export process starts.
##
## The list is the pruner's own decision (PipelineDefaults.skips: unused
## files, res://tools/, this addon, editor_only prefixes, extension vetoes),
## for the same build mode. Only "all_resources" and "exclude" presets are
## changed (the other filters already export a chosen set); an existing
## exclude list is kept. prune_on_export false, or a preset with the no_prune
## feature, leaves the preset alone. Re-runs the analysis first unless
## prune_refresh_analysis is false. Like set_preset_template.gd, this never
## backs up or restores export_presets.cfg; the caller owns that lifecycle
## (the pruner reports a leftover list that would drop used files).
##
## Usage:
##   godot --headless --path . -s addons/export_pipeline/set_preset_exclusions.gd -- <preset name> [release|debug]
extends SceneTree

const PRESETS_PATH := "res://export_presets.cfg"
const REPORT_PATH := "res://tools/export_report.json"
const CONFIG_PATH := "res://tools/export_analyzer.json"
const ANALYZER := "addons/export_pipeline/analyzer/export_analyzer.gd"

const PipelineDefaults := preload("pipeline_defaults.gd")

var _prefixes: Array = []


## What extensions call on the pruner in export_begin (see export_pruner.gd).
func add_editor_only(prefix: String) -> void:
	if not prefix in _prefixes:
		_prefixes.append(prefix)


func _init() -> void:
	quit(_run(OS.get_cmdline_user_args()))


func _run(args: PackedStringArray) -> int:
	if args.is_empty():
		push_error("usage: set_preset_exclusions.gd -- <preset name> [release|debug]")
		return 1
	var preset_name := args[0]
	var is_debug := args.size() > 1 and args[1] == "debug"

	var presets := ConfigFile.new()
	var err := presets.load(PRESETS_PATH)
	if err != OK:
		push_error("failed to load %s: %d" % [PRESETS_PATH, err])
		return 1
	var section := ""
	for candidate in presets.get_sections():
		if candidate.begins_with("preset.") and not candidate.ends_with(".options") \
				and String(presets.get_value(candidate, "name", "")) == preset_name:
			section = candidate
			break
	if section.is_empty():
		push_error("no preset named '%s' in %s" % [preset_name, PRESETS_PATH])
		return 1

	var config := _load_json(CONFIG_PATH)
	if not bool(config.get("prune_on_export", true)):
		print("[set_preset_exclusions] prune_on_export is false — preset left unchanged.")
		return 0
	var features := Array(String(presets.get_value(section, "custom_features", "")).split(",", false)).map(func(f: String) -> String: return f.strip_edges())
	if "no_prune" in features:
		print("[set_preset_exclusions] preset has the no_prune feature — left unchanged.")
		return 0
	var filter := String(presets.get_value(section, "export_filter", "all_resources"))
	if filter != "all_resources" and filter != "exclude":
		print("[set_preset_exclusions] export_filter is '%s' (exports a chosen set) — left unchanged." % filter)
		return 0

	if bool(config.get("prune_refresh_analysis", true)):
		var output := []
		var code := OS.execute(OS.get_executable_path(), [
			"--headless", "--path", ProjectSettings.globalize_path("res://"), "-s", ANALYZER,
		], output, true)
		if code != 0:
			push_error("analysis failed (exit %d) — preset left unchanged." % code)
			return 1
	var report := _load_json(REPORT_PATH)
	if report.is_empty():
		push_error("no readable report at %s — preset left unchanged." % REPORT_PATH)
		return 1

	# The pruner's inputs, built the way its _export_begin builds them.
	var unused := {}
	for path in report.get("unused", []):
		unused[path] = true
	_prefixes = PipelineDefaults.ALWAYS_SKIP_PREFIXES.duplicate()
	for prefix in config.get("editor_only", []):
		add_editor_only(String(prefix))
	var extensions: Array = []
	for ext_path in config.get("extensions", PipelineDefaults.DEFAULT_EXTENSIONS):
		var script = load(String(ext_path))
		if script != null:
			extensions.append(script.new())
	for e in extensions:
		if e.has_method("export_begin"):
			e.export_begin(self, report, config, is_debug)

	var files := PackedStringArray(presets.get_value(section, "export_files", PackedStringArray())) if filter == "exclude" else PackedStringArray()
	var kept := files.size()
	var listed := {}
	for path in files:
		listed[path] = true
	var project_files := PackedStringArray()
	_walk("res://", project_files)
	for path in project_files:
		if not listed.has(path) and PipelineDefaults.skips(path, unused, _prefixes, extensions):
			files.append(path)
			listed[path] = true
	files.sort()

	presets.set_value(section, "export_filter", "exclude")
	presets.set_value(section, "export_files", files)
	err = presets.save(PRESETS_PATH)
	if err != OK:
		push_error("failed to save %s: %d" % [PRESETS_PATH, err])
		return 1
	print("[set_preset_exclusions] %s (%s): %d file(s) excluded (%d already listed)" % [preset_name, "debug" if is_debug else "release", files.size(), kept])
	return 0


## Every file Godot can list for export: res:// minus .godot/, directories
## with .gdignore, and the .import / .uid sidecars (exported with their
## resource, not by path).
func _walk(dir_path: String, out: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null or dir.file_exists(".gdignore"):
		return
	dir.include_hidden = false
	for sub in dir.get_directories():
		if dir_path == "res://" and sub == ".godot":
			continue
		_walk(dir_path.path_join(sub), out)
	for file in dir.get_files():
		var ext := file.get_extension()
		if ext != "import" and ext != "uid":
			out.append(dir_path.path_join(file))


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}
