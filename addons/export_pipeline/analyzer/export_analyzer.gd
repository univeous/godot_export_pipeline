## Export reachability analyzer.
##
## Computes the set of files actually reachable from the project's runtime
## roots (main scene, autoloads, project settings, configured extras), the
## set of files that are NOT reachable, and warnings for dynamic load()
## calls that static analysis cannot follow.
##
## Run headless from the project root:
##   godot --headless --path . -s addons/export_pipeline/analyzer/export_analyzer.gd
##
## Outputs:
##   tools/export_report.md    human-readable report
##   tools/export_report.json  machine-readable (feeds the future
##                              EditorExportPlugin skip-list and build profile)
##
## Config: tools/export_analyzer.json (created with defaults if missing).
extends SceneTree

const CONFIG_PATH := "res://tools/export_analyzer.json"
const REPORT_MD := "res://tools/export_report.md"
const REPORT_JSON := "res://tools/export_report.json"

## Extensions Godot exports as resources ("export all resources" mode).
## Everything else is grouped separately in the report.
const RESOURCE_EXTENSIONS := [
	"tscn", "scn", "tres", "res", "gd", "gdshader", "gdshaderinc",
	"png", "jpg", "jpeg", "svg", "webp", "bmp", "tga", "exr", "hdr", "dds",
	"ogg", "wav", "mp3",
	"ttf", "otf", "woff", "woff2", "fnt", "font",
	"json", "csv", "po", "mo",
	"glb", "gltf", "obj", "fbx", "dae",
	"ogv", "atlastex", "material", "anim",
]

const TEXT_FORMATS := ["tscn", "tres", "gdshader", "gdshaderinc"]

const SKIP_DIRS := [".godot", ".git", ".claude", ".vscode", ".idea"]

## project.godot settings that are editor-only by engine definition; the
## paths they hold must not become runtime roots. Extendable via the
## "ignored_settings" config key.
const EDITOR_ONLY_SETTINGS := [
	"editor_plugins/enabled",
	"file_customization/folder_colors",
	"internationalization/locale/translations_pot_files",
]

## project.godot settings whose quoted paths carry a trailing ":<locale>"
## that is NOT part of the path — translation remaps are stored as
##   { "res://icon.png": PackedStringArray("res://icon-ru.png:ru", ...) }
## and the engine splits at the last ':' (ResourceLoader::_path_remap).
const LOCALE_SUFFIXED_SETTINGS := [
	"internationalization/locale/translation_remaps",
]

var _config := {}
var _all_files := {}           # path -> size (resource-extension files only)
var _non_resource_files := {}  # path -> size
var _used := {}                # path -> Array[String] of referrers
var _queue: Array[String] = []
var _warnings: Array[String] = []
var _engine_classes := {}      # class name -> true
var _class_map := {}           # global class_name -> script path
var _class_regexes := {}       # global class_name -> RegEx

var _text_cache := {}  # path -> comment-stripped text of used scripts/content files
var _text_scan_exts: Array = []   # content extensions scanned like dialogue files

var _editor_only_sources := {}  # editor_only prefix -> who declared it (config / extension)
var _excluded_refs := {}        # editor-only path -> Array[String] referrers whose reference was dropped
var _unused_refs := {}          # unused path -> Array[String] unreachable files that reference it

## Analyzer extensions: scripts listed in the "extensions" config key.
## Contract (all methods optional):
##   func extension_name() -> String
##   func setup(analyzer) -> void
##   func claim_file(path: String) -> bool   # true = extension owns this
##                                           # file's dependency extraction
##   func process_script(analyzer, path, raw, code) -> bool
##                                           # called per traversed script;
##                                           # true = suppress default quoted
##                                           # path marking + dynamic-load
##                                           # warnings (class/ident scans
##                                           # still run)
##   func finalize(analyzer) -> bool         # post-traversal fixpoint pass;
##                                           # return true if new files were
##                                           # marked (will run again)
##   func report(analyzer) -> Dictionary     # merged into the report JSON
##   func report_markdown(analyzer) -> PackedStringArray  # md detail section
##   func explain_unused(analyzer, path) -> String
##                                           # evidence line for one unused
##                                           # file the extension gated
##                                           # ("" = no claim)
## Extensions use the public helpers below (mark_used, is_used, ...).
var _extensions: Array = []

var _re_quoted_path: RegEx
var _re_rel_path: RegEx
var _re_dynamic_load: RegEx
var _re_node_type: RegEx
var _re_extends: RegEx
var _re_engine_ident: RegEx


func _init() -> void:
	var start := Time.get_ticks_msec()
	_compile_regexes()
	_load_config()
	for prefix in _config.get("editor_only", []):
		_editor_only_sources[String(prefix)] = "config editor_only"
	_text_scan_exts = _config.get("text_scan_extensions", ["dialogue"])
	var defaults = load("res://addons/export_pipeline/pipeline_defaults.gd")
	for ext_path in _config.get("extensions", defaults.DEFAULT_EXTENSIONS):
		var script = load(String(ext_path))
		if script == null:
			push_error("[export_analyzer] cannot load extension %s" % ext_path)
			continue
		var inst = script.new()
		if inst.has_method("setup"):
			inst.setup(self)
		_extensions.append(inst)
	_build_class_map()
	_scan_filesystem("res://")
	_seed_roots()
	_traverse()
	_scan_unused_refs()
	_write_reports()
	print("[export_analyzer] done in %d ms" % (Time.get_ticks_msec() - start))
	quit()


func _compile_regexes() -> void:
	_re_quoted_path = RegEx.create_from_string("[\"']\\*?((?:res|uid)://[^\"'\\\\]+)[\"']")
	# preload("x.gd") / load("x.gd") / extends "x.gd" with a relative path
	_re_rel_path = RegEx.create_from_string("(?:preload|load)\\s*\\(\\s*\"([^\"]+)\"|extends\\s+\"([^\"]+)\"")
	# load(...) whose first argument is not a string literal
	_re_dynamic_load = RegEx.create_from_string("\\b(?:load|ResourceLoader\\s*\\.\\s*load)\\s*\\(\\s*([^\\s\"')][^,)\\n]*)")
	_re_node_type = RegEx.create_from_string("type=\"([A-Za-z0-9_]+)\"")
	_re_extends = RegEx.create_from_string("(?m)^extends\\s+([A-Za-z_]\\w*)")
	_re_engine_ident = RegEx.create_from_string("\\b[A-Z][A-Za-z0-9]+\\b")


func _load_config() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		_config = {
			"_comment": "extra_roots and dynamic_load_whitelist accept res:// files or directories; both are traversed as reachability roots. editor_only lists res:// prefixes that are never runtime-reachable, even if referenced. ignored_settings extends the built-in list of editor-only project.godot settings; ignored_autoloads lists autoload names that will not ship (dev tools). text_scan_extensions are content DSL files scanned for paths/classes/registry members. Scripts containing any registry_markers string (or listed in registry_scripts) are asset registries whose paths are gated by member usage; registry_patterns maps a registry class to one or more asset path templates for wrapper-style members, e.g. {\"Character\": \"res://game/scenes/portraits/{member}.tscn\"}.",
			"extra_roots": [],
			"dynamic_load_whitelist": [],
			"editor_only": [],
			"ignored_settings": [],
			"ignored_autoloads": [],
			"text_scan_extensions": ["dialogue"],
			"registry_markers": ["Generated by AssetRegistry"],
			"registry_scripts": [],
			"registry_patterns": {},
		}
		var f := FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
		f.store_string(JSON.stringify(_config, "\t") + "\n")
		f.close()
		print("[export_analyzer] created default config at ", CONFIG_PATH)
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	if parsed == null:
		push_error("[export_analyzer] failed to parse %s" % CONFIG_PATH)
		_config = {}
	else:
		_config = parsed


func _build_class_map() -> void:
	for entry in ProjectSettings.get_global_class_list():
		var cname := String(entry["class"])
		_class_map[cname] = String(entry["path"])
		_class_regexes[cname] = RegEx.create_from_string("\\b%s\\b" % cname)


func _scan_filesystem(dir_path: String) -> void:
	# Directories with a .gdignore marker are invisible to Godot (never
	# imported or exported) — keep them out of the inventory entirely.
	if FileAccess.file_exists(dir_path.path_join(".gdignore")):
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var path := dir_path.path_join(name)
		if dir.current_is_dir():
			if not name in SKIP_DIRS and not name.begins_with("."):
				_scan_filesystem(path)
		else:
			var ext := name.get_extension().to_lower()
			if ext in ["import", "uid"] or name == "project.godot":
				pass # sidecars follow their owner; project.godot always exported
			elif path.begins_with("res://tools/") or path.begins_with("res://addons/export_pipeline/"):
				pass # this pipeline's code, config and reports
			elif ext in RESOURCE_EXTENSIONS or ext in _text_scan_exts:
				_all_files[path] = _file_size(path)
			else:
				_non_resource_files[path] = _file_size(path)
		name = dir.get_next()
	dir.list_dir_end()


func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_length() if f else 0


func _seed_roots() -> void:
	var main_scene: String = ProjectSettings.get_setting("application/run/main_scene", "")
	if main_scene.is_empty():
		_warnings.append("No main scene set in project settings; reachability starts only from autoloads, project settings and configured extra_roots.")
	else:
		_mark_used(main_scene, "<main scene>")

	# Autoloads in ignored_autoloads (dev/editor-only singletons that will
	# be removed for release builds) are not roots.
	var ignored_autoloads: Array = _config.get("ignored_autoloads", [])
	for prop in ProjectSettings.get_property_list():
		var pname: String = prop["name"]
		if pname.begins_with("autoload/"):
			if pname.trim_prefix("autoload/") in ignored_autoloads:
				continue
			var value := String(ProjectSettings.get_setting(pname)).trim_prefix("*")
			var target := value
			if target.begins_with("uid://"):
				var id := ResourceUID.text_to_id(target)
				if ResourceUID.has_id(id):
					target = ResourceUID.get_id_path(id)
			var blacklisted := false
			for prefix in _config.get("editor_only", []):
				if target.begins_with(String(prefix)):
					_warnings.append("Autoload %s (%s) is under editor_only '%s' — not a root; export_pruner drops the autoload setting on export." % [pname, target, prefix])
					blacklisted = true
					break
			if not blacklisted:
				_mark_used(value, "<autoload %s>" % pname)

	# Any quoted res:// or uid:// value in project settings (icon, boot
	# splash, bus layout, ...) except settings known to be editor-only
	# (folder colors, POT sources, ...). The editor_only blacklist
	# additionally filters editor-side paths like addon config directories.
	var ignored: Array = _config.get("ignored_settings", []).duplicate()
	for autoload_name in ignored_autoloads:
		ignored.append("autoload/%s" % autoload_name)
	# Settings owned by excluded addons (res://addons/<name>/ in editor_only,
	# whether from config or extensions like colored folders) are editor-side
	# leftovers — their values must not become roots. Convention: an addon's
	# settings live under "addons/<name>/..." or "<name>/...".
	var ignored_prefixes: Array[String] = []
	for eo_prefix in _config.get("editor_only", []):
		var p := String(eo_prefix).trim_suffix("/")
		if p.begins_with("res://addons/") and p.count("/") == 3:
			ignored_prefixes.append("addons/%s/" % p.get_file())
			ignored_prefixes.append("%s/" % p.get_file())
	var re_prop := RegEx.create_from_string("^([A-Za-z_][\\w/.]*)=")
	var section2 := ""
	var prop := ""
	for line in FileAccess.get_file_as_string("res://project.godot").split("\n"):
		var stripped := line.strip_edges()
		if stripped.begins_with("[") and stripped.ends_with("]"):
			section2 = stripped.substr(1, stripped.length() - 2)
			continue
		var pm := re_prop.search(stripped)
		if pm:
			prop = section2.path_join(pm.get_string(1)) if not section2.is_empty() else pm.get_string(1)
		if prop in EDITOR_ONLY_SETTINGS or prop in ignored:
			continue
		if prop.begins_with("autoload/"):
			continue # the dedicated autoload loop above handled these (incl. editor-only drops)
		var owned_by_excluded_addon := false
		for ip in ignored_prefixes:
			if prop.begins_with(ip):
				owned_by_excluded_addon = true
				break
		if owned_by_excluded_addon:
			continue
		var locale_suffixed := prop in LOCALE_SUFFIXED_SETTINGS
		for m in _re_quoted_path.search_all(stripped):
			var ref := m.get_string(1)
			if locale_suffixed:
				ref = _strip_locale_suffix(ref)
			_mark_used(ref, "<project.godot %s>" % prop)

	for key in ["extra_roots", "dynamic_load_whitelist"]:
		for root in _config.get(key, []):
			_mark_used(String(root), "<config %s>" % key)


## Drops a translation remap's trailing ":<locale>" ("res://a.png:pt_BR").
## The dictionary keys (source paths) carry no suffix, and the only other
## ':' in a well-formed entry is the "res://" / "uid://" scheme separator —
## so a colon past the scheme is the locale separator, as the engine reads it.
func _strip_locale_suffix(ref: String) -> String:
	var split := ref.rfind(":")
	if split <= ref.find("://"):
		return ref
	return ref.left(split)


# ── Public API for analyzer extensions ─────────────────────────────────────

func mark_used(ref: String, referrer: String) -> void:
	_mark_used(ref, referrer)


func is_used(path: String) -> bool:
	return _used.has(path)


func used_files() -> Array:
	return _used.keys()


func get_config(key: String, default = null):
	return _config.get(key, default)


## Adds a res:// prefix to the editor_only blacklist at runtime (used by
## extensions that derive exclusions from project state, e.g. folder colors).
## `source` names the declarer so the report can say WHO excluded a file.
func add_editor_only(prefix: String, source := "extension") -> void:
	if not _config.has("editor_only"):
		_config["editor_only"] = []
	if not prefix in _config["editor_only"]:
		_config["editor_only"].append(prefix)
	if not _editor_only_sources.has(prefix):
		_editor_only_sources[prefix] = source


## Comment-stripped text of every traversed script/content file.
func get_text_cache() -> Dictionary:
	return _text_cache


func warn(message: String) -> void:
	if not message in _warnings:
		_warnings.append(message)

# ───────────────────────────────────────────────────────────────────────────


## Resolves uid:// to a path, expands directories, queues newly-seen files.
func _mark_used(ref: String, referrer: String) -> void:
	var path := ref
	if path.begins_with("uid://"):
		var id := ResourceUID.text_to_id(path)
		if ResourceUID.has_id(id):
			path = ResourceUID.get_id_path(id)
		else:
			_warnings.append("Unresolvable uid '%s' referenced by %s" % [ref, referrer])
			return
	if not path.begins_with("res://"):
		return
	if "%s" in path or "%d" in path:
		_warnings.append("Format-string load target '%s' in %s — resolves at runtime; whitelist the target directory." % [path, referrer])
		return
	path = path.simplify_path()

	for prefix in _config.get("editor_only", []):
		if path.begins_with(String(prefix)):
			# The reference is dropped, but not forgotten: the report must
			# distinguish "excluded and unreferenced" from "excluded BUT
			# something reachable still points at it".
			if not _excluded_refs.has(path):
				_excluded_refs[path] = []
			var excluded: Array = _excluded_refs[path]
			if excluded.size() < 8 and not referrer in excluded:
				excluded.append(referrer)
			# A reference from real runtime code into the editor-only
			# blacklist would break in the exported game — flag it.
			if referrer.begins_with("res://"):
				_warnings.append("Runtime file %s references editor-only '%s' — it will be missing from the export." % [referrer, path])
			return

	if DirAccess.dir_exists_absolute(path):
		# Only directories the user listed in the config are expanded.
		# A directory path appearing in a script or a setting is not
		# evidence its contents are runtime-loaded — surface it and let
		# the black/white lists decide.
		if not referrer.begins_with("<config"):
			for key in ["extra_roots", "dynamic_load_whitelist"]:
				for entry in _config.get(key, []):
					if String(entry).simplify_path().trim_suffix("/") == path.trim_suffix("/"):
						return # already expanded as a config root
			var note := "Directory reference '%s' from %s — not expanded; add to dynamic_load_whitelist if its contents are loaded at runtime." % [path, referrer]
			if not note in _warnings:
				_warnings.append(note)
			return
		if FileAccess.file_exists(path.path_join(".gdignore")):
			# Godot never exports .gdignore'd content; marking it used would
			# only produce false "missing from pck" verification failures.
			warn("Config root '%s' (via %s) is .gdignore'd — Godot cannot export it; entry has no effect." % [path, referrer])
			return
		var dir := DirAccess.open(path)
		if dir:
			dir.list_dir_begin()
			var name := dir.get_next()
			while name != "":
				if dir.current_is_dir():
					if not name.begins_with("."):
						_mark_used(path.path_join(name), referrer)
				elif not name.get_extension().to_lower() in ["import", "uid"]:
					_mark_used(path.path_join(name), referrer)
				name = dir.get_next()
			dir.list_dir_end()
		return

	if not FileAccess.file_exists(path):
		if not path.begins_with("res://.godot/"):
			_warnings.append("Missing file '%s' referenced by %s" % [path, referrer])
		return
	if referrer == path:
		return # a file's own uid/path appearing in its text is not a reference
	if _used.has(path):
		var referrers: Array = _used[path]
		if referrers.size() < 8 and not referrer in referrers:
			referrers.append(referrer)
		return
	_used[path] = [referrer]
	_queue.append(path)


func _traverse() -> void:
	_drain_queue()
	# Extension passes (registry members, tileset sources, ...) can pull in
	# new files whose contents create further usages — iterate to a fixpoint.
	var changed := true
	while changed:
		changed = false
		for e in _extensions:
			if e.has_method("finalize"):
				changed = e.finalize(self) or changed
		if changed:
			_drain_queue()


## Evidence pass over the files traversal never reached: unused files can
## still reference each other (an unreachable scene pulling an unreachable
## texture), and the report should say "referenced only from unreachable
## files X, Y" instead of leaving "unused" unexplained.
func _scan_unused_refs() -> void:
	for path in _all_files:
		if _used.has(String(path)):
			continue
		var targets := {}
		var ext := String(path).get_extension().to_lower()
		if ext == "gd" or ext in TEXT_FORMATS or ext in _text_scan_exts:
			var code := _strip_comments(FileAccess.get_file_as_string(path))
			for m in _re_quoted_path.search_all(code):
				targets[m.get_string(1)] = true
			if ext == "gd":
				for m in _re_rel_path.search_all(code):
					var rel := m.get_string(1)
					if rel.is_empty():
						rel = m.get_string(2)
					if not rel.begins_with("res://") and not rel.begins_with("uid://"):
						targets[String(path).get_base_dir().path_join(rel)] = true
		elif ext in ["res", "scn"]:
			for dep in ResourceLoader.get_dependencies(path):
				for piece in String(dep).split("::"):
					if piece.begins_with("res://") or piece.begins_with("uid://"):
						targets[piece] = true
		for t in targets:
			var target := _resolve_res_ref(String(t))
			if target.is_empty() or target == String(path):
				continue
			if not _all_files.has(target) or _used.has(target):
				continue
			if not _unused_refs.has(target):
				_unused_refs[target] = []
			var refs: Array = _unused_refs[target]
			if refs.size() < 8 and not String(path) in refs:
				refs.append(String(path))


## uid:// or res:// reference text -> canonical res:// path ("" if unresolvable).
func _resolve_res_ref(ref: String) -> String:
	var path := ref
	if path.begins_with("uid://"):
		var id := ResourceUID.text_to_id(path)
		if not ResourceUID.has_id(id):
			return ""
		path = ResourceUID.get_id_path(id)
	if not path.begins_with("res://"):
		return ""
	return path.simplify_path()


func _drain_queue() -> void:
	while not _queue.is_empty():
		var path: String = _queue.pop_back()
		var claimed := false
		for e in _extensions:
			if e.has_method("claim_file") and e.claim_file(path):
				claimed = true
				break
		if claimed:
			continue
		var ext := path.get_extension().to_lower()
		if ext == "gd":
			_extract_script_deps(path)
		elif ext in _text_scan_exts:
			_extract_content_deps(path)
		elif ext in TEXT_FORMATS:
			_extract_text_resource_deps(path)
		elif ext in ["res", "scn"]:
			_extract_loader_deps(path)
		else:
			_extract_imported_deps(path)


## Binary resources: GDScript's loader is broken (godot#90643) but the
## binary/text resource loaders do report dependencies correctly.
func _extract_loader_deps(path: String) -> void:
	for dep in ResourceLoader.get_dependencies(path):
		# Entries look like "uid://xxx::res://fallback/path" or just a path.
		for piece in String(dep).split("::"):
			if piece.begins_with("res://") or piece.begins_with("uid://"):
				_mark_used(piece, path)


## Everything that is not a script, a text resource or a .res/.scn.
##
## These used to be treated as dependency-free leaves, which is wrong for two
## common shapes and silently broke exports:
##
##   * Imported 3D scenes (.glb/.fbx/.gltf). Their textures are extracted by
##     the importer into sibling .png files, and only the *imported* .scn
##     references them. Calling get_dependencies() on the SOURCE path returns
##     nothing, so every extracted texture looked unreferenced.
##   * Binary resources with a project-specific extension (.lmbake holds a
##     LightmapGIData pointing at the baked .exr). Not "res"/"scn", so the
##     branch above never saw them.
##
## Pruning those leaves the exported .pck without the imported .ctex, the
## remap disappears, and the loader falls back to the raw source file:
##     No loader found for resource: res://....png (expected type: Texture2D)
## which aborts loading the whole scene.
##
## The .import sidecar is the only place that records where the imported
## artifacts live, so resolve through it before asking for dependencies.
func _extract_imported_deps(path: String) -> void:
	var import_path := path + ".import"
	if not FileAccess.file_exists(import_path):
		_mark_deps_of(path, path)
		return
	var cfg := ConfigFile.new()
	if cfg.load(import_path) != OK:
		return
	var target := str(cfg.get_value("remap", "path", ""))
	if not target.is_empty():
		_mark_deps_of(target, path)
		return
	# Multi-artifact importers write deps/dest_files instead of remap/path.
	for f in cfg.get_value("deps", "dest_files", []):
		_mark_deps_of(str(f), path)


func _mark_deps_of(target: String, referrer: String) -> void:
	if target.is_empty() or not ResourceLoader.exists(target):
		return
	for dep in ResourceLoader.get_dependencies(target):
		for piece in String(dep).split("::"):
			if piece.begins_with("res://") or piece.begins_with("uid://"):
				_mark_used(piece, referrer)


func _extract_text_resource_deps(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	for m in _re_quoted_path.search_all(text):
		_mark_used(m.get_string(1), path)
	for m in _re_node_type.search_all(text):
		_engine_classes[m.get_string(1)] = true


## Content text files (dialogue scripts and similar DSLs, see
## text_scan_extensions): they reference files via quoted res:// paths and
## call into global classes / registry members (e.g. `do Background.Dam01.enter(2)`).
func _extract_content_deps(path: String) -> void:
	var code := _strip_comments(FileAccess.get_file_as_string(path))
	_text_cache[path] = code
	for m in _re_quoted_path.search_all(code):
		_mark_used(m.get_string(1), path)
	for cname in _class_map:
		if _class_regexes[cname].search(code):
			_mark_used(_class_map[cname], "%s (class_name %s)" % [path, cname])


func _extract_script_deps(path: String) -> void:
	var raw := FileAccess.get_file_as_string(path)
	var code := _strip_comments(raw)
	_text_cache[path] = code

	var owned := false
	for e in _extensions:
		if e.has_method("process_script") and e.process_script(self, path, raw, code):
			owned = true
			break
	if not owned:
		for m in _re_quoted_path.search_all(code):
			_mark_used(m.get_string(1), path)

	for m in _re_rel_path.search_all(code):
		var rel := m.get_string(1)
		if rel.is_empty():
			rel = m.get_string(2)
		if not rel.begins_with("res://") and not rel.begins_with("uid://"):
			_mark_used(path.get_base_dir().path_join(rel), path)

	# class_name references: match identifiers against the global class list
	# on code with string literals blanked, so paths/UI text don't false-hit.
	var idents := _blank_strings(code)
	for cname in _class_map:
		if _class_map[cname] == path:
			continue
		if _class_regexes[cname].search(idents):
			_mark_used(_class_map[cname], "%s (class_name %s)" % [path, cname])

	# Engine classes referenced from code (Expression.new(), type hints,
	# static calls like Marshalls.base64_to_raw) — feeds the build profile.
	for m in _re_engine_ident.search_all(idents):
		var ident := m.get_string(0)
		if not _engine_classes.has(ident) and ClassDB.class_exists(ident):
			_engine_classes[ident] = true

	for m in _re_extends.search_all(idents):
		var base := m.get_string(1)
		if not _class_map.has(base):
			_engine_classes[base] = true

	if not owned:
		_find_dynamic_loads(path, raw)


func _find_dynamic_loads(path: String, raw: String) -> void:
	var lines := raw.split("\n")
	for i in lines.size():
		var line := _strip_comments(lines[i])
		var m := _re_dynamic_load.search(line)
		if m:
			_warnings.append("Dynamic load in %s:%d — load(%s…) is invisible to static analysis; whitelist its targets if needed." % [path, i + 1, m.get_string(1).strip_edges()])


## Removes '# ...' comments while respecting string literals.
func _strip_comments(code: String) -> String:
	var out := PackedStringArray()
	for line in code.split("\n"):
		var in_str := ""
		var cut := -1
		for i in line.length():
			var c := line[i]
			if in_str != "":
				if c == in_str and (i == 0 or line[i - 1] != "\\"):
					in_str = ""
			elif c == "\"" or c == "'":
				in_str = c
			elif c == "#":
				cut = i
				break
		out.append(line.substr(0, cut) if cut >= 0 else line)
	return "\n".join(out)


## Replaces string literal contents with nothing (quotes kept).
func _blank_strings(code: String) -> String:
	var re := RegEx.create_from_string("\"[^\"\\n]*\"|'[^'\\n]*'")
	return re.sub(code, "\"\"", true)


func _write_reports() -> void:
	var sizes := {}
	for path in _all_files:
		sizes[path] = _all_files[path]
	for path in _non_resource_files:
		sizes[path] = _non_resource_files[path]

	var used_paths := _used.keys()
	used_paths.sort()
	var unused_paths := []
	var used_size := 0
	var unused_size := 0
	for path in _all_files:
		if _used.has(path):
			used_size += _all_files[path]
		else:
			unused_paths.append(path)
			unused_size += _all_files[path]
	unused_paths.sort()
	var engine_classes := _engine_classes.keys()
	engine_classes.sort()

	# Per-file evidence: WHY is each unused file unused — deliberately
	# excluded (config/extension, and by whom), gated by an extension,
	# referenced only from unreachable files, or genuinely unreferenced.
	# Exclusion and "no references found" can both hold; the entry says so.
	var unused_evidence := {}
	var excluded_count := 0
	var excluded_but_referenced := 0
	for path in unused_paths:
		var entry := _unused_evidence_for(path)
		unused_evidence[path] = entry
		if entry.has("excluded_by"):
			excluded_count += 1
		if entry["status"] == "excluded_but_referenced":
			excluded_but_referenced += 1

	var ext_json := {}
	var ext_md := {}
	for e in _extensions:
		var ename: String = e.extension_name() if e.has_method("extension_name") else String(e.get_script().resource_path)
		if e.has_method("report"):
			ext_json[ename] = e.report(self)
		if e.has_method("report_markdown"):
			ext_md[ename] = e.report_markdown(self)

	var data := {
		"generated": Time.get_datetime_string_from_system(),
		"project": ProjectSettings.get_setting("application/config/name", ""),
		"used": used_paths,
		"unused": unused_paths,
		"unused_evidence": unused_evidence,
		"excluded_prefixes": _editor_only_sources,
		"warnings": _warnings,
		"engine_classes": engine_classes,
		"extensions": ext_json,
		"referrers": _used,
		"sizes": sizes,
		"totals": {
			"used_count": used_paths.size(),
			"used_size": used_size,
			"unused_count": unused_paths.size(),
			"unused_size": unused_size,
			"excluded_count": excluded_count,
			"excluded_but_referenced_count": excluded_but_referenced,
			"non_resource_count": _non_resource_files.size(),
			"non_resource_size": _sum(_non_resource_files),
		},
	}

	var writer = load("res://addons/export_pipeline/analyzer/report_writer.gd")
	writer.write_all(data, ext_md)

	print("[export_analyzer] used: %d files (%s), unused: %d files (%s, %d excluded on purpose), warnings: %d" % [
		used_paths.size(), String.humanize_size(used_size),
		unused_paths.size(), String.humanize_size(unused_size),
		excluded_count, _warnings.size(),
	])
	if excluded_but_referenced > 0:
		print("[export_analyzer] ATTENTION: %d excluded file(s) are still referenced from reachable code — see the report's 'Excluded but still referenced' section." % excluded_but_referenced)
	print("[export_analyzer] reports: tools/export_report.{md,json,html}")


## Assembles the evidence entry for one unused file.
## status values:
##   excluded_but_referenced  excluded by config/extension, yet reachable
##                            code still references it — pruning breaks those
##   excluded                 excluded on purpose (source named); may also be
##                            unreferenced or referenced from unreachable files
##   gated_by_extension       an extension suppressed its marking and explains
##   unreachable              referenced only from other unreachable files
##   no_references            nothing in any scanned file references it
func _unused_evidence_for(path: String) -> Dictionary:
	var entry := {}
	for prefix in _config.get("editor_only", []):
		if path.begins_with(String(prefix)):
			entry["excluded_by"] = String(prefix)
			entry["excluded_source"] = String(_editor_only_sources.get(String(prefix), "extension"))
			break
	if _excluded_refs.has(path):
		entry["refs_from_reachable"] = _excluded_refs[path]
	if _unused_refs.has(path):
		entry["refs_from_unreachable"] = _unused_refs[path]
	var notes := PackedStringArray()
	for e in _extensions:
		if e.has_method("explain_unused"):
			var note: String = e.explain_unused(self, path)
			if not note.is_empty():
				notes.append(note)
	if not notes.is_empty():
		entry["extension_notes"] = notes

	var unreachable_tail := ""
	if entry.has("refs_from_unreachable"):
		unreachable_tail = "; referenced only from unreachable files: %s" % ", ".join(entry["refs_from_unreachable"])
	if entry.has("excluded_by"):
		var head := "excluded by %s (%s)" % [entry["excluded_source"], entry["excluded_by"]]
		if entry.has("refs_from_reachable"):
			entry["status"] = "excluded_but_referenced"
			entry["evidence"] = "%s BUT still referenced from reachable code: %s — pruning breaks these references" % [head, ", ".join(entry["refs_from_reachable"])]
		elif entry.has("refs_from_unreachable"):
			entry["status"] = "excluded"
			entry["evidence"] = head + unreachable_tail
		else:
			entry["status"] = "excluded"
			entry["evidence"] = "%s; additionally, no reference to it was found in any scanned file" % head
	elif not notes.is_empty():
		entry["status"] = "gated_by_extension"
		entry["evidence"] = "; ".join(notes) + unreachable_tail
	elif entry.has("refs_from_unreachable"):
		entry["status"] = "unreachable"
		entry["evidence"] = "not reachable from any runtime root" + unreachable_tail
	else:
		entry["status"] = "no_references"
		entry["evidence"] = "no reference found in any scanned file (runtime roots, used files and unused files were all scanned)"
	return entry


func _sum(d: Dictionary) -> int:
	var total := 0
	for k in d:
		total += d[k]
	return total
