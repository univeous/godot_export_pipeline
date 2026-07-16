## Engine build-profile generator (phase 3 of the export pipeline).
##
## Reads tools/export_report.json (run addons/export_pipeline/analyzer/export_analyzer.gd first) and
## computes the set of engine classes the exported game can actually touch:
##   - node/resource types from text scenes (report engine_classes),
##   - classes inside loadable used resources (deep property walk, which
##     covers binary .res internals like TileSetAtlasSource),
##   - engine-class identifiers mentioned in used scripts (static calls
##     such as Marshalls.base64_to_raw or JSON.parse_string),
##   - all their ClassDB ancestors, plus a small essential core set.
## Everything else becomes disabled_classes in an editor-compatible build
## profile (tools/engine.build) usable both in the Engine Compilation
## Configuration editor and directly via scons build_profile=.
##
## Subsystems are decided from positive evidence instead of default-enabled
## flags, each yielding both a module decision and a disable_* build option:
## navigation 2D/3D (unused nav also makes export_pruner disable TileMapLayer
## navigation in exported scenes), physics 2D/3D (collision/raycast nodes,
## query/space-state classes, TileSet physics layers, direct_space_state in
## scripts) and advanced GUI (any class gated by ADVANCED_GUI_DISABLED).
## The class→option rules live in pipeline_defaults.gd, shared with
## export_pruner's stale-profile guard.
##
## Run: godot --headless --path . -s addons/export_pipeline/build_profile_gen.gd
##
## Expected noise: loading scenes pulls in their scripts, and scripts that
## reference autoloads fail to compile in this bare (-s) environment — the
## resulting SCRIPT ERROR spam is harmless; class collection does not
## depend on script compilation.
##
## The profile is an over-approximation-by-construction on the keep side,
## but MUST still be validated by an actual template compile and a full
## playthrough — dynamic ClassDB.instantiate("Name") calls with computed
## strings are invisible here (grep for ClassDB.instantiate before trusting).
extends SceneTree

const PipelineDefaults := preload("pipeline_defaults.gd")

const REPORT_PATH := "res://tools/export_report.json"
const PROFILE_PATH := "res://tools/engine.build"

## Never disabled: core machinery whose absence breaks any build.
const ESSENTIALS := [
	"Object", "RefCounted", "Resource", "Node", "MainLoop", "SceneTree",
	"Script", "GDScript", "PackedScene", "SceneState", "Viewport", "Window",
	"ProjectSettings", "ResourceLoader", "ResourceSaver", "ClassDB", "Engine",
	"OS", "Input", "InputEvent", "InputMap", "Time", "Marshalls", "JSON",
	"FileAccess", "DirAccess", "Mutex", "Semaphore", "Thread", "WorkerThreadPool",
	"CanvasItem", "CanvasLayer", "World2D", "Texture", "Texture2D", "Image",
	"ImageTexture", "CompressedTexture2D", "Shader", "Material", "ShaderMaterial",
	"AudioServer", "AudioStream", "AudioStreamPlayback", "DisplayServer",
	"RenderingServer", "PhysicsServer2D", "NavigationServer2D", "ThemeDB",
	"Theme", "Font", "FontFile", "FontVariation", "SystemFont", "StyleBox",
	"TextServer", "TextServerManager", "TranslationServer", "Translation",
]

## Modules any GDScript game with text needs. The text server is derived:
## RichTextLabel in the kept set forces text_server_adv; otherwise the much
## smaller text_server_fb suffices (no BiDi/complex shaping; CJK
## line-breaking rules degrade slightly). Analyzer-config
## "build_text_server" = "adv"/"fb" overrides; "build_extra_modules"/
## "build_exclude_modules" adjust the final list.
const ALWAYS_MODULES := ["gdscript", "freetype", "msdfgen", "webp"]

## Kept engine class -> modules implementing it (module names as of 4.7).
## Not exhaustive — unknown needs surface as boot/load failures in the
## template smoke test.
const CLASS_MODULES := {
	"AudioStreamMP3": ["mp3"],
	"AudioStreamOggVorbis": ["vorbis", "ogg"],
	"AudioStreamInteractive": ["interactive_music"],
	"VideoStreamTheora": ["theora", "ogg", "vorbis"],
	"RegEx": ["regex"],
	"FastNoiseLite": ["noise"], "NoiseTexture2D": ["noise"],
	"GridMap": ["gridmap"],
	"ENetMultiplayerPeer": ["enet"],
	"WebSocketPeer": ["websocket"], "WebRTCPeerConnection": ["webrtc"],
	"MultiplayerSpawner": ["multiplayer"], "MultiplayerSynchronizer": ["multiplayer"],
	"GLTFDocument": ["gltf"],
	"NavigationAgent2D": ["navigation_2d"], "NavigationRegion2D": ["navigation_2d"],
	"NavigationLink2D": ["navigation_2d"], "NavigationObstacle2D": ["navigation_2d"],
	"NavigationAgent3D": ["navigation_3d"], "NavigationRegion3D": ["navigation_3d"],
	"NavigationLink3D": ["navigation_3d"], "NavigationObstacle3D": ["navigation_3d"],
	"VisualShader": ["visual_shader"],
	"CSGShape3D": ["csg"],
	"OpenXRInterface": ["openxr"],
	"UPNP": ["upnp"],
}

## Used file extension -> modules needed to load it at runtime.
const EXT_MODULES := {
	"jpg": ["jpg"], "jpeg": ["jpg"],
	"svg": ["svg"],
	"tga": ["tga"],
	"exr": ["tinyexr"],
	"dds": ["dds"],
	"ktx": ["ktx"],
	"bmp": ["bmp"],
	"hdr": ["hdr"],
	"ogv": ["theora", "ogg", "vorbis"],
	"mp3": ["mp3"],
	"ogg": ["vorbis", "ogg"],
}

var _keep := {}
# Classes with positive evidence of use: scene node types, script
# identifiers, resource instances, embedded settings objects. Unlike _keep
# it contains no ESSENTIALS and no API closure — Viewport.get_camera_3d()
# alone drags Camera3D/Node3D into _keep for every project, so build
# options (disable_3d) must be decided from this set, not from _keep.
var _evidence := {}
# Subsystems decided from positive evidence, keyed by profile option name
# minus the "disable_" prefix. Each entry lists human-readable proof of use;
# an empty list at decision time turns the subsystem off (module dropped
# where one exists, disable_* written into the profile). Default-enabled
# flags (TileMapLayer.navigation_enabled) are NOT evidence — see _note
# callers for what counts.
var _subsystem_evidence := {
	"navigation_2d": PackedStringArray(), "navigation_3d": PackedStringArray(),
	"physics_2d": PackedStringArray(), "physics_3d": PackedStringArray(),
	"advanced_gui": PackedStringArray(),
}


func _note(subsystem: String, evidence: String) -> void:
	if not evidence in _subsystem_evidence[subsystem]:
		_subsystem_evidence[subsystem].append(evidence)


func _evidence_class(c: String, source := "") -> void:
	if ClassDB.class_exists(c) and not _evidence.has(c):
		_evidence[c] = true
		# Class evidence doubles as subsystem evidence: nav classes, physics
		# nodes AND the RefCounted query/space-state classes (a raycast-query
		# script uses physics with zero CollisionObject nodes), advanced-GUI
		# classes. disable_3d is decided from _evidence directly.
		for opt in PipelineDefaults.class_disable_conflicts(c):
			if opt != "disable_3d":
				_note(String(opt).trim_prefix("disable_"), "%s %s" % [c, source])
	_keep_class(c)


func _init() -> void:
	var report_raw = JSON.parse_string(FileAccess.get_file_as_string(REPORT_PATH))
	if report_raw == null:
		push_error("run addons/export_pipeline/analyzer/export_analyzer.gd first — no report at %s" % REPORT_PATH)
		quit(1)
		return
	var report: Dictionary = report_raw

	for c in report.get("engine_classes", []):
		_evidence_class(String(c), "referenced in scenes/scripts")
	for c in ESSENTIALS:
		_keep_class(c)
	# Whole subtrees the engine instantiates at runtime without any trace in
	# project data: input events live serialized inside project.godot's input
	# map, and the built-in default theme creates StyleBox subclasses (e.g.
	# StyleBoxLine for separators). Tiny classes, huge breakage if missing.
	for base in ["InputEvent", "StyleBox"]:
		_keep_class(base)
		for c in ClassDB.get_inheriters_from_class(base):
			_keep_class(c)
	# Objects embedded in project settings: Object(SomeClass, ...)
	var re_obj := RegEx.create_from_string("Object\\((\\w+),")
	for m in re_obj.search_all(FileAccess.get_file_as_string("res://project.godot")):
		_evidence_class(m.get_string(1), "embedded in project.godot")

	var used: Array = report.get("used", [])
	_collect_from_resources(used)
	_collect_from_scripts(used)
	_close_over_api()

	var config := {}
	if FileAccess.file_exists("res://tools/export_analyzer.json"):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://tools/export_analyzer.json"))
		if parsed is Dictionary:
			config = parsed

	# Subsystems are decided from positive evidence only: default-enabled
	# flags prove nothing (TileMapLayer ships with navigation_enabled=true).
	# When no evidence exists the module is dropped (where one exists) AND
	# the scene-side glue is compiled out via the disable_* build option — a
	# nav-enabled TileMapLayer running against the module-less dummy server
	# otherwise spams "navigation_map.is_null()" once per cell. For
	# navigation_2d, export_pruner reads the flag from the written profile
	# and additionally disables TileMapLayer/TileMap navigation in the
	# exported scenes, which also silences templates built before this
	# profile existed.
	var forcing_modules := {
		"navigation_2d": "navigation_2d", "navigation_3d": "navigation_3d",
		"godot_physics_2d": "physics_2d",
		"godot_physics_3d": "physics_3d", "jolt_physics": "physics_3d",
	}
	for mod in config.get("build_extra_modules", []):
		if forcing_modules.has(String(mod)):
			_note(forcing_modules[String(mod)], "forced by config build_extra_modules")
	var sub_used := {}
	for sub in _subsystem_evidence:
		sub_used[sub] = not _subsystem_evidence[sub].is_empty()
		if sub_used[sub]:
			print("[build_profile_gen] %s in use: %s" % [sub, "; ".join(_subsystem_evidence[sub])])
		else:
			var extra := " Export_pruner disables TileMapLayer navigation in exported scenes." if sub == "navigation_2d" else ""
			print("[build_profile_gen] %s unused — disable_%s=yes.%s" % [sub, sub, extra])

	# Ancestor closure runs inside _keep_class; now invert. Only Node and
	# Resource descendants are disableable: core singletons and servers have
	# compile-time couplings (e.g. the ClassDB name "Geometry3D" collides
	# with the engine's global math class of the same name), and the big
	# size wins are in scene/resource classes anyway.
	var disabled: Array[String] = []
	for c in ClassDB.get_class_list():
		if _keep.has(c):
			continue
		if ClassDB.is_parent_class(c, "Node") or ClassDB.is_parent_class(c, "Resource"):
			disabled.append(c)
	disabled.sort()

	var uses_3d := false
	for c in _evidence:
		if ClassDB.is_parent_class(c, "Node3D") or ClassDB.is_parent_class(c, "VisualInstance3D"):
			uses_3d = true
			break

	var profile := {
		"type": "build_profile",
		"disabled_build_options": {
			"disable_3d": not uses_3d,
			"disable_advanced_gui": not sub_used["advanced_gui"],
			"disable_navigation_2d": not sub_used["navigation_2d"],
			"disable_navigation_3d": not sub_used["navigation_3d"],
			"disable_physics_2d": not sub_used["physics_2d"],
			"disable_physics_3d": not sub_used["physics_3d"],
		},
		"disabled_classes": disabled,
	}
	# Write-if-changed: the profile's mtime is the freshness reference for
	# self-built templates (export_pruner / release.ps1 compare against it),
	# so an unchanged regeneration must not bump it.
	var content := JSON.stringify(profile, "\t") + "\n"
	if FileAccess.get_file_as_string(PROFILE_PATH) != content:
		var f := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
		f.store_string(content)
		f.close()
	else:
		print("[build_profile_gen] profile unchanged - %s left untouched." % PROFILE_PATH)

	var modules := {}
	for mod in ALWAYS_MODULES:
		modules[mod] = true
	for dim in ["2d", "3d"]:
		if sub_used["navigation_%s" % dim]:
			modules["navigation_%s" % dim] = true

	# text_server_adv by default; the much smaller text_server_fb only on
	# explicit request (config build_text_server = "fb"). RichTextLabel
	# requires adv, so an explicit fb gets a warning when it is in use.
	var text_server: String = config.get("build_text_server", "adv")
	if text_server == "fallback":
		text_server = "fb"
	if text_server == "fb" and _keep.has("RichTextLabel"):
		print("[build_profile_gen] WARNING: build_text_server=fb requested but RichTextLabel is in use — RichTextLabel requires text_server_adv.")
	modules["text_server_%s" % text_server] = true

	# RenderingDevice-based renderers (mobile / forward_plus) compile GLSL
	# to SPIR-V at runtime via the glslang module; without it the game
	# crashes at startup with "Shader language is not supported".
	# gl_compatibility does not need it.
	var rendering_method := String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "forward_plus"))
	if rendering_method != "gl_compatibility":
		modules["glslang"] = true

	# Physics implementations are modules too: without these, kept physics
	# nodes and space queries get no server implementation at runtime.
	if sub_used["physics_2d"]:
		modules["godot_physics_2d"] = true
	if sub_used["physics_3d"]:
		var engine_3d := String(ProjectSettings.get_setting("physics/3d/physics_engine", "DEFAULT"))
		modules["jolt_physics" if engine_3d.contains("Jolt") else "godot_physics_3d"] = true

	# XR projects need the openxr module regardless of class detection.
	if bool(ProjectSettings.get_setting("xr/openxr/enabled", false)):
		modules["openxr"] = true

	for c in _keep:
		for mod in CLASS_MODULES.get(c, []):
			modules[mod] = true
	for path in used:
		for mod in EXT_MODULES.get(String(path).get_extension().to_lower(), []):
			modules[mod] = true
		# Textures imported as Basis Universal are transcoded at load time by
		# the basis_universal module. The only trace is the importer setting
		# in the .import sidecar — compress/mode=4 is COMPRESS_BASIS_UNIVERSAL
		# (editor/import/resource_importer_texture.h; the layered-texture
		# importer shares the enum) — the imported .ctex itself is opaque here.
		if not modules.has("basis_universal"):
			var import_sidecar := String(path) + ".import"
			if FileAccess.file_exists(import_sidecar) and FileAccess.get_file_as_string(import_sidecar).contains("compress/mode=4"):
				modules["basis_universal"] = true
	for mod in config.get("build_extra_modules", []):
		modules[String(mod)] = true
	for mod in config.get("build_exclude_modules", []):
		modules.erase(String(mod))
	var module_names := modules.keys()
	module_names.sort()
	var module_flags := PackedStringArray()
	for mod in module_names:
		module_flags.append("module_%s_enabled=yes" % mod)

	# Build options are derived from project state, never assumed:
	#  - d3d12 stays when the project's RD driver is d3d12 (needs the D3D12
	#    SDK deps: misc/scripts/install_d3d12_sdk_windows.py);
	#  - minizip stays when ZIPReader/ZIPPacker are in use;
	#  - openxr/winrt/accesskit are governed by the module whitelist and the
	#    environment-workarounds note below, not blanket-disabled.
	var extra_opts := PackedStringArray()
	var rd_driver := String(ProjectSettings.get_setting("rendering/rendering_device/driver.windows",
		ProjectSettings.get_setting("rendering/rendering_device/driver", "vulkan")))
	var needs_d3d12 := rendering_method != "gl_compatibility" and rd_driver == "d3d12"
	if not needs_d3d12:
		extra_opts.append("d3d12=no")
	# A gl_compatibility-only project never touches the RenderingDevice
	# backends, so the whole Vulkan RD can be compiled out — derivable from
	# the renderer setting, same as glslang above.
	if rendering_method == "gl_compatibility":
		extra_opts.append("vulkan=no")
	if not (_keep.has("ZIPReader") or _keep.has("ZIPPacker")):
		extra_opts.append("minizip=no")
	# Architecture of the running editor — the sensible default for a
	# desktop template built on this machine, not a hardcoded x86_64.
	var arch := Engine.get_architecture_name()
	# Prefer `uvx scons` (uv fetches an up-to-date SCons into an ephemeral
	# env — Godot needs >= 4.4, system installs are often older), fall back
	# to a bare scons on PATH, and print plain scons with an install hint
	# when neither is available.
	var scons_runner := "scons"
	var missing_runner := false
	if OS.execute("uv", ["--version"], []) == 0:
		scons_runner = "uvx scons"
	elif OS.execute("scons", ["--version"], []) != 0:
		missing_runner = true

	# WinRT support needs Windows SDK >= 10.0.22621 — a detectable fact of
	# this machine, so probe for it instead of assuming either way.
	var winrt_ok := false
	var sdk_dir := DirAccess.open("C:/Program Files (x86)/Windows Kits/10/Include")
	if sdk_dir:
		for v in sdk_dir.get_directories():
			var parts := v.split(".")
			if parts.size() >= 3 and int(parts[2]) >= 22621:
				winrt_ok = true
				break
	if not winrt_ok:
		extra_opts.append("winrt=no")
	# Environment workarounds this machine needs (e.g. accesskit=no when the
	# AccessKit deps are not installed in the source checkout) — declared
	# explicitly in the config, never assumed.
	for arg in config.get("build_extra_scons_args", []):
		extra_opts.append(String(arg))
	var scons_cmd := ("%s platform=windows target=template_release arch=%s optimize=size_extra lto=full debug_symbols=no" % [scons_runner, arch]
		+ (" " + " ".join(extra_opts) if not extra_opts.is_empty() else "")
		+ " modules_enabled_by_default=no %s" % " ".join(module_flags)
		+ " build_profile=%s" % ProjectSettings.globalize_path(PROFILE_PATH))
	var install_dir := ProjectSettings.globalize_path("res://tools/templates")
	var vinfo := Engine.get_version_info()
	print("[build_profile_gen] kept %d classes, disabled %d -> %s" % [_keep.size(), disabled.size(), PROFILE_PATH])
	print("[build_profile_gen] modules needed: %s" % ", ".join(module_names))
	print("[build_profile_gen] compile from a Godot source checkout matching %s.%s.%s:" % [vinfo["major"], vinfo["minor"], vinfo["status"]])
	print("[build_profile_gen]   %s" % scons_cmd)
	print("[build_profile_gen] then install it so exports and release.ps1 pick it up (the profile sidecar is how freshness is verified — content, not timestamps):")
	print("[build_profile_gen]   copy bin\\godot.windows.template_release.%s.exe \"%s\\windows_release_%s.exe\"" % [arch, install_dir.replace("/", "\\"), arch])
	print("[build_profile_gen]   copy \"%s\" \"%s\\profile_used.build\"" % [ProjectSettings.globalize_path(PROFILE_PATH).replace("/", "\\"), install_dir.replace("/", "\\")])
	print("[build_profile_gen] and verify + ship in one command:")
	print("[build_profile_gen]   pwsh \"%s\" -GodotExe \"%s\"" % [
		ProjectSettings.globalize_path("res://addons/export_pipeline/release.ps1").replace("/", "\\"),
		OS.get_executable_path().replace("/", "\\"),
	])
	if missing_runner:
		print("[build_profile_gen] NOTE: neither `uv` nor `scons` was found on PATH — install uv (https://docs.astral.sh/uv/, e.g. `winget install astral-sh.uv`) and the command becomes `uvx scons ...`, or install SCons >= 4.4 yourself.")
	if needs_d3d12:
		print("[build_profile_gen] NOTE: d3d12 is kept (project renders through the d3d12 driver) — its SDK deps must be installed: misc/scripts/install_d3d12_sdk_windows.py")
	if rendering_method == "gl_compatibility":
		print("[build_profile_gen] NOTE: vulkan=no added — the project renders with gl_compatibility only, so the Vulkan RenderingDevice backend is compiled out.")
	if not winrt_ok:
		print("[build_profile_gen] NOTE: winrt=no added — this machine's Windows SDK is older than 10.0.22621.")
	print("[build_profile_gen] NOTE: if scons then asks for the AccessKit deps, either run misc/scripts/install_accesskit.py in the source checkout, or declare `\"build_extra_scons_args\": [\"accesskit=no\"]` in tools/export_analyzer.json (accesskit=no removes screen-reader support — an accessibility trade-off).")
	quit()


func _keep_class(c: String) -> void:
	var cur := c
	while cur != "" and ClassDB.class_exists(cur) and not _keep.has(cur):
		_keep[cur] = true
		cur = ClassDB.get_parent_class(cur)


## GDScript type inference can make a script depend on a class whose name
## never appears in any source ("Native class ViewportTexture doesn't
## exist" from `var tex := viewport.get_texture()`). Inference only springs
## from method return types and property types of classes already in use,
## so keeping that closure makes inferred types safe.
func _close_over_api() -> void:
	var changed := true
	while changed:
		changed = false
		for c in _keep.keys():
			for m in ClassDB.class_get_method_list(c, true):
				changed = _keep_hinted(m["return"]) or changed
			for p in ClassDB.class_get_property_list(c, true):
				changed = _keep_hinted(p) or changed


## Keeps the class named by a method-return/property info dict.
## Returns true if anything new was kept.
func _keep_hinted(info: Dictionary) -> bool:
	if info["type"] != TYPE_OBJECT:
		return false
	var changed := false
	# class_name can be a single class or a comma-separated hint list.
	for c in String(info["class_name"]).split(","):
		c = c.strip_edges()
		if not c.is_empty() and not _keep.has(c) and ClassDB.class_exists(c):
			_keep_class(c)
			changed = true
	return changed


## Loads each used resource and walks nested resources, collecting concrete
## classes. This covers binary formats the text scan cannot see AND assets
## only reachable from code (e.g. a registry-loaded .ogv whose runtime class
## is VideoStreamTheora). Scripts are skipped: autoload-dependent ones fail
## to compile in this bare environment, and their identifiers are already
## scanned textually.
func _collect_from_resources(used: Array) -> void:
	var visited := {}
	for path in used:
		var ext := String(path).get_extension().to_lower()
		if ext in ["gd", "gdshader", "gdshaderinc"] or not ResourceLoader.exists(path):
			continue
		var res = ResourceLoader.load(path)
		if res == null:
			continue
		if res is PackedScene:
			var state: SceneState = res.get_state()
			for i in state.get_node_count():
				_evidence_class(state.get_node_type(i), "node in %s" % path)
				for j in state.get_node_property_count(i):
					# GridMap's nav path is off by default, so an explicit
					# bake_navigation=true (the only reason it's serialized)
					# is genuine 3D-navigation use.
					if state.get_node_property_name(i, j) == &"bake_navigation" and bool(state.get_node_property_value(i, j)):
						_note("navigation_3d", "bake_navigation enabled in %s" % path)
					_walk_value(state.get_node_property_value(i, j), visited)
		else:
			_walk_value(res, visited)


func _walk_value(value, visited: Dictionary) -> void:
	if value is Resource:
		if visited.has(value):
			return
		visited[value] = true
		_evidence_class(value.get_class(), "resource instance in used data")
		if value is TileSet:
			var label: String = value.resource_path if not value.resource_path.is_empty() else "an embedded TileSet"
			if value.get_navigation_layers_count() > 0:
				_note("navigation_2d", "%s defines navigation layers" % label)
			# TileMapLayer bodies talk straight to PhysicsServer2D — a project
			# can have working tile collision with zero CollisionObject2D
			# nodes of its own, so TileSet physics layers count as 2D physics.
			if value.get_physics_layers_count() > 0:
				_note("physics_2d", "%s defines physics layers" % label)
		for prop in value.get_property_list():
			if prop["type"] == TYPE_OBJECT or prop["type"] == TYPE_ARRAY or prop["type"] == TYPE_DICTIONARY:
				_walk_value(value.get(prop["name"]), visited)
	elif value is Array:
		for v in value:
			_walk_value(v, visited)
	elif value is Dictionary:
		for k in value:
			_walk_value(value[k], visited)


## Engine-class identifiers mentioned in used scripts (static access,
## .new(), type hints) keep those classes. Comments are stripped so
## commented-out code doesn't keep classes alive.
func _collect_from_scripts(used: Array) -> void:
	var re_ident := RegEx.create_from_string("\\b[A-Z][A-Za-z0-9]+\\b")
	var re_comment := RegEx.create_from_string("(?m)#.*$")
	for path in used:
		if not String(path).ends_with(".gd"):
			continue
		var code := re_comment.sub(FileAccess.get_file_as_string(path), "", true)
		var seen := {}
		for m in re_ident.search_all(code):
			var ident := m.get_string(0)
			if not seen.has(ident):
				seen[ident] = true
				if ClassDB.class_exists(ident):
					_evidence_class(ident, "identifier in %s" % path)
		# The nav servers are in ESSENTIALS, so _keep can't tell whether a
		# script actually talks to them — check the source text directly.
		if code.contains("NavigationServer2D"):
			_note("navigation_2d", "%s calls NavigationServer2D" % path)
		if code.contains("NavigationServer3D"):
			_note("navigation_3d", "%s calls NavigationServer3D" % path)
		if code.contains("get_navigation_map") or code.contains("navigation_map_override"):
			# World2D and World3D share these names — count both dimensions.
			_note("navigation_2d", "%s touches the world navigation map" % path)
			_note("navigation_3d", "%s touches the world navigation map" % path)
		# Space queries need no physics class names at all
		# (get_world_2d().direct_space_state.intersect_ray(...) with untyped
		# params built elsewhere), so probe the property name textually. The
		# dimension comes from world_2d/world_3d hints in the same script;
		# with no hint at all, 2D is assumed — a 3D script that stores the
		# state or the query params in a typed way names a Physics*3D class
		# and is caught by the identifier scan above.
		if code.contains("direct_space_state"):
			var hint_3d := code.contains("world_3d") or code.contains("World3D")
			if code.contains("world_2d") or code.contains("World2D") or not hint_3d:
				_note("physics_2d", "%s queries direct_space_state" % path)
			if hint_3d:
				_note("physics_3d", "%s queries direct_space_state" % path)
