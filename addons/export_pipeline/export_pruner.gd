@tool
extends EditorExportPlugin

## Skips runtime-unreachable files during export, using the unused set
## computed by addons/export_pipeline/analyzer/export_analyzer.gd (see
## tools/export_report.json).
##
## Fail-open by design: only files explicitly listed as unused are skipped;
## anything the analyzer has not seen (e.g. files added after the last
## analysis) is exported normally.
##
## Config (tools/export_analyzer.json):
##   prune_on_export: false          disables pruning entirely (default true)
##   prune_refresh_analysis: false   reuse the existing report instead of
##                                   re-running the analyzer (default true)
## A "no_prune" custom feature on the export preset also disables pruning.
##
## Domain-specific export behavior lives in the same extension scripts the
## analyzer loads (config "extensions"). Pruner-side hooks (all optional):
##   func export_begin(pruner, report: Dictionary, config: Dictionary,
##                     is_debug: bool) -> void
##       inspect the analysis/config; declare exclusions via
##       pruner.add_editor_only(prefix)
##   func should_skip(path: String) -> bool        # per-file veto
##   func wants_customization() -> bool            # gate resource rewriting
##   func customization_hash() -> int              # cache key contribution
##   func customize_resource(resource: Resource, path: String) -> Resource
##       return a modified copy, or null to leave unchanged (chained)
##   func export_end(pruner) -> void

const REPORT_PATH := "res://tools/export_report.json"
const CONFIG_PATH := "res://tools/export_analyzer.json"
const PRUNE_LOG_PATH := "res://tools/export_prune_log.json"
const BUILD_PROFILE_PATH := "res://tools/engine.build"

const PipelineDefaults := preload("pipeline_defaults.gd")

## Never exported regardless of analysis state — the analyzer excludes
## res://tools/ from its inventory, and this addon must not ship itself.
const ALWAYS_SKIP_PREFIXES := ["res://tools/", "res://addons/export_pipeline/"]

var _enabled := false
var _unused := {}
var _editor_only: Array = []  # config editor_only + extension declarations
var _extra_skip_prefixes: Array = []
var _skipped: Array[String] = []
var _removed_autoloads := {}  # setting name -> original value, restored at end
var _dropped_setting_names: Array = []  # for the prune log
var _ext: Array = []
var _ext_ready := false


func _get_name() -> String:
	return "ExportPruner"


# ── Public API for extensions ───────────────────────────────────────────────

## Declares a res:// prefix as editor-only for this export: its files are
## skipped and autoloads pointing into it are dropped from the exported
## settings.
func add_editor_only(prefix: String) -> void:
	if not prefix in _editor_only:
		_editor_only.append(prefix)
	if not prefix in _extra_skip_prefixes:
		_extra_skip_prefixes.append(prefix)

# ────────────────────────────────────────────────────────────────────────────


func _export_begin(features: PackedStringArray, is_debug: bool, path: String, flags: int) -> void:
	_enabled = false
	_unused.clear()
	_editor_only = []
	_extra_skip_prefixes = ALWAYS_SKIP_PREFIXES.duplicate()
	_skipped.clear()
	_dropped_setting_names = []

	var config := _load_json(CONFIG_PATH)
	if not bool(config.get("prune_on_export", true)):
		print("[export_pruner] prune_on_export is false — exporting unpruned.")
		return
	if "no_prune" in features:
		print("[export_pruner] preset has 'no_prune' feature — exporting unpruned.")
		return

	if bool(config.get("prune_refresh_analysis", true)) and not _ext_ready:
		var output := []
		var exit_code := OS.execute(OS.get_executable_path(), [
			"--headless", "--path", ProjectSettings.globalize_path("res://"),
			"-s", "addons/export_pipeline/analyzer/export_analyzer.gd",
		], output, true)
		if exit_code != 0:
			push_warning("[export_pruner] analysis refresh failed (exit %d) — falling back to the existing report." % exit_code)
		elif FileAccess.file_exists(BUILD_PROFILE_PATH):
			# Newly used engine classes must reach engine.build too. Safe to
			# do every export: the generator is write-if-changed, so an
			# unchanged profile keeps its mtime and templates stay fresh.
			var profile_exit := OS.execute(OS.get_executable_path(), [
				"--headless", "--path", ProjectSettings.globalize_path("res://"),
				"-s", "addons/export_pipeline/build_profile_gen.gd",
			], output, true)
			if profile_exit != 0:
				push_warning("[export_pruner] build profile refresh failed (exit %d) — engine.build may be stale." % profile_exit)

	var report := _load_json(REPORT_PATH)
	if report.is_empty():
		push_warning("[export_pruner] no readable report at %s — exporting unpruned." % REPORT_PATH)
		return
	for unused_path in report.get("unused", []):
		_unused[unused_path] = true
	# The analyzer already refuses to mark these used; skipping them here
	# covers files it keeps out of its inventory (e.g. non-resource files).
	for prefix in config.get("editor_only", []):
		add_editor_only(String(prefix))

	_init_extensions(config, report, features)

	# Autoloads that will not ship — listed in ignored_autoloads, or whose
	# script lives under an editor-only prefix (config or extension-declared)
	# — must also disappear from the exported project settings, or startup
	# fails on the missing singleton script. In-memory only: project.godot
	# on disk is never written, and the values are restored in _export_end.
	for setting in _autoloads_to_drop(config):
		if ProjectSettings.has_setting(setting):
			_removed_autoloads[setting] = ProjectSettings.get_setting(setting)
			ProjectSettings.set_setting(setting, null)

	# Settings owned by excluded addons ([location_manager] data blobs,
	# addons/<name>/ config, their editor_plugins/enabled entries) are
	# editor-side leftovers — strip them from the exported settings via the
	# same in-memory + restore mechanism.
	for setting in _plugin_settings_to_drop():
		if ProjectSettings.has_setting(setting):
			_removed_autoloads[setting] = ProjectSettings.get_setting(setting)
			ProjectSettings.set_setting(setting, null)
	var enabled_plugins: PackedStringArray = ProjectSettings.get_setting("editor_plugins/enabled", PackedStringArray())
	var kept_plugins := PackedStringArray()
	for cfg_path in enabled_plugins:
		var excluded := false
		for prefix in _extra_skip_prefixes:
			if String(cfg_path).begins_with(String(prefix)):
				excluded = true
				break
		if not excluded:
			kept_plugins.append(cfg_path)
	if kept_plugins.size() != enabled_plugins.size():
		_removed_autoloads["editor_plugins/enabled"] = enabled_plugins
		ProjectSettings.set_setting("editor_plugins/enabled", kept_plugins)

	if not _removed_autoloads.is_empty():
		_dropped_setting_names = _removed_autoloads.keys()
		_dropped_setting_names.sort()
		print("[export_pruner] dropped %d setting(s) from the exported project settings (full list in the prune log)." % _dropped_setting_names.size())

	_warn_if_build_profile_stale(report)
	_report_template_status()

	_enabled = true
	print("[export_pruner] pruning %d unused files (report generated %s, %d warnings)." % [
		_unused.size(), report.get("generated", "?"), report.get("warnings", []).size(),
	])


func _export_file(path: String, type: String, features: PackedStringArray) -> void:
	if not _enabled:
		return
	var prune := _unused.has(path)
	if not prune:
		for prefix in _extra_skip_prefixes:
			if path.begins_with(prefix):
				prune = true
				break
	if not prune:
		for e in _ext:
			if e.has_method("should_skip") and e.should_skip(path):
				prune = true
				break
	if prune:
		_skipped.append(path)
		skip()


func _export_end() -> void:
	for setting in _removed_autoloads:
		ProjectSettings.set_setting(setting, _removed_autoloads[setting])
	_removed_autoloads.clear()
	for e in _ext:
		if e.has_method("export_end"):
			e.export_end(self)
	_ext.clear()
	_ext_ready = false
	if not _enabled:
		return
	_skipped.sort()
	var f := FileAccess.open(PRUNE_LOG_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({
			"exported_at": Time.get_datetime_string_from_system(),
			"skipped_count": _skipped.size(),
			"dropped_settings": _dropped_setting_names,
			"skipped": _skipped,
		}, "\t") + "\n")
		f.close()
	print("[export_pruner] skipped %d files; list written to %s" % [_skipped.size(), PRUNE_LOG_PATH])


# ── Extension loading ───────────────────────────────────────────────────────

func _init_extensions(config: Dictionary, report: Dictionary, features: PackedStringArray) -> void:
	if _ext_ready:
		return
	_ext_ready = true
	var is_debug := "debug" in features
	for ext_path in config.get("extensions", PipelineDefaults.DEFAULT_EXTENSIONS):
		var script = load(String(ext_path))
		if script == null:
			push_warning("[export_pruner] cannot load extension %s" % ext_path)
			continue
		_ext.append(script.new())
	for e in _ext:
		if e.has_method("export_begin"):
			e.export_begin(self, report, config, is_debug)


## Resource customization callbacks may fire before _export_begin; load
## extensions on demand from the persisted config/report in that case.
func _ensure_extensions(features: PackedStringArray) -> void:
	if _ext_ready:
		return
	var config := _load_json(CONFIG_PATH)
	if not bool(config.get("prune_on_export", true)):
		_ext_ready = true
		return
	_init_extensions(config, _load_json(REPORT_PATH), features)

# ── Resource customization (delegated to extensions) ───────────────────────

func _begin_customize_resources(platform: EditorExportPlatform, features: PackedStringArray) -> bool:
	if "no_prune" in features:
		return false
	_ensure_extensions(features)
	for e in _ext:
		if e.has_method("customize_resource") and (not e.has_method("wants_customization") or e.wants_customization()):
			return true
	return false


func _get_customization_configuration_hash() -> int:
	_ensure_extensions(PackedStringArray())
	var h := 0
	for e in _ext:
		if e.has_method("customization_hash"):
			h = hash([h, e.customization_hash()])
	return h


func _customize_resource(resource: Resource, path: String) -> Resource:
	var current := resource
	var changed := false
	for e in _ext:
		if e.has_method("customize_resource"):
			var result = e.customize_resource(current, path)
			if result is Resource:
				current = result
				changed = true
	return current if changed else null

# ────────────────────────────────────────────────────────────────────────────


## The pck refreshes automatically on export, but the engine build profile
## is a manually generated snapshot — when content starts using an engine
## class the profile disables, a custom template built from it crashes.
## Cross-check on every export so the drift is impossible to miss.
func _warn_if_build_profile_stale(report: Dictionary) -> void:
	if not FileAccess.file_exists(BUILD_PROFILE_PATH):
		return
	var disabled := {}
	for c in _load_json(BUILD_PROFILE_PATH).get("disabled_classes", []):
		disabled[c] = true
	var stale: Array[String] = []
	for c in report.get("engine_classes", []):
		if disabled.has(String(c)):
			stale.append(String(c))
	if stale.is_empty():
		return
	var msg := "[export_pruner] engine build profile is STALE — %d used class(es) are disabled in %s: %s. Regenerate it (addons/export_pipeline/build_profile_gen.gd) and recompile the custom template before shipping." % [stale.size(), BUILD_PROFILE_PATH, ", ".join(stale)]
	push_warning(msg)
	print("WARNING: " + msg)


func _autoloads_to_drop(config: Dictionary) -> Array[String]:
	var drop: Array[String] = []
	for autoload_name in config.get("ignored_autoloads", []):
		drop.append("autoload/%s" % autoload_name)
	for prop in ProjectSettings.get_property_list():
		var pname: String = prop["name"]
		if not pname.begins_with("autoload/") or pname in drop:
			continue
		var target := String(ProjectSettings.get_setting(pname)).trim_prefix("*")
		if target.begins_with("uid://"):
			var id := ResourceUID.text_to_id(target)
			if ResourceUID.has_id(id):
				target = ResourceUID.get_id_path(id)
		for prefix in _editor_only:
			if target.begins_with(String(prefix)):
				drop.append(pname)
				break
	return drop


## Self-built trimmed export templates live in res://tools/templates/ by
## convention. Export plugins cannot switch the preset's template mid-export
## (no scripting API for presets), so this reports the situation instead:
## the preset's custom_template must point at the template once, and
## release.ps1 auto-discovers it for smoke runs and artifact assembly.
func _report_template_status() -> void:
	if not FileAccess.file_exists(BUILD_PROFILE_PATH):
		return
	var newest := ""
	var newest_time := 0
	var dir := DirAccess.open("res://tools/templates")
	if dir:
		dir.list_dir_begin()
		var name := dir.get_next()
		while name != "":
			if not dir.current_is_dir() and name.get_extension() == "exe":
				var t := FileAccess.get_modified_time("res://tools/templates/" + name)
				if t > newest_time:
					newest_time = t
					newest = name
			name = dir.get_next()
		dir.list_dir_end()
	if newest.is_empty():
		print("[export_pruner] no self-built template in res://tools/templates/ — the stock export template is used (Project > Tools > Generate Build Profile to build a trimmed one).")
		return
	if newest_time < FileAccess.get_modified_time(BUILD_PROFILE_PATH):
		push_warning("[export_pruner] self-built template tools/templates/%s is OLDER than tools/engine.build — recompile it, or the exported game may miss engine classes." % newest)
	else:
		print("[export_pruner] up-to-date self-built template: tools/templates/%s (make sure the preset's custom_template points at it, or ship via release.ps1)." % newest)


## Settings owned by addons excluded via editor-only prefixes. Best-effort
## by naming convention — an addon res://addons/<name>/ usually keeps its
## settings under "addons/<name>/..." or "<name>/..." — but addons can
## register settings anywhere in ProjectSettings; anything the convention
## misses stays in the export (fail-open) and can be handled manually.
func _plugin_settings_to_drop() -> Array[String]:
	var addon_names: Array[String] = []
	for prefix in _editor_only:
		var p := String(prefix).trim_suffix("/")
		if p.begins_with("res://addons/") and p.count("/") == 3:
			addon_names.append(p.get_file())
	var drop: Array[String] = []
	if addon_names.is_empty():
		return drop
	for prop in ProjectSettings.get_property_list():
		var pname: String = prop["name"]
		for addon_name in addon_names:
			if pname.begins_with("addons/%s/" % addon_name) or pname.begins_with("%s/" % addon_name):
				drop.append(pname)
				break
	return drop


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}
