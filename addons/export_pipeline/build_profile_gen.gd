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
	"NavigationAgent3D": ["navigation_3d"], "NavigationRegion3D": ["navigation_3d"],
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


func _init() -> void:
	var report_raw = JSON.parse_string(FileAccess.get_file_as_string(REPORT_PATH))
	if report_raw == null:
		push_error("run addons/export_pipeline/analyzer/export_analyzer.gd first — no report at %s" % REPORT_PATH)
		quit(1)
		return
	var report: Dictionary = report_raw

	for c in report.get("engine_classes", []):
		_keep_class(String(c))
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
		_keep_class(m.get_string(1))

	var used: Array = report.get("used", [])
	_collect_from_resources(used)
	_collect_from_scripts(used)
	_close_over_api()

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
	for c in _keep:
		if ClassDB.is_parent_class(c, "Node3D") or ClassDB.is_parent_class(c, "VisualInstance3D"):
			uses_3d = true
			break

	var profile := {
		"type": "build_profile",
		"disabled_build_options": {"disable_3d": not uses_3d},
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

	var config := {}
	if FileAccess.file_exists("res://tools/export_analyzer.json"):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://tools/export_analyzer.json"))
		if parsed is Dictionary:
			config = parsed

	var modules := {}
	for mod in ALWAYS_MODULES:
		modules[mod] = true

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
	# nodes get no server implementation at runtime.
	var has_2d_physics := false
	var has_3d_physics := false
	for c in _keep:
		has_2d_physics = has_2d_physics or ClassDB.is_parent_class(c, "CollisionObject2D") or ClassDB.is_parent_class(c, "Joint2D")
		has_3d_physics = has_3d_physics or ClassDB.is_parent_class(c, "CollisionObject3D") or ClassDB.is_parent_class(c, "Joint3D")
	if has_2d_physics:
		modules["godot_physics_2d"] = true
	if has_3d_physics:
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
	if not (_keep.has("ZIPReader") or _keep.has("ZIPPacker")):
		extra_opts.append("minizip=no")
	# Architecture of the running editor — the sensible default for a
	# desktop template built on this machine, not a hardcoded x86_64.
	var arch := Engine.get_architecture_name()
	var scons_cmd := ("scons platform=windows target=template_release arch=%s optimize=size_extra lto=full debug_symbols=no" % arch
		+ (" " + " ".join(extra_opts) if not extra_opts.is_empty() else "")
		+ " modules_enabled_by_default=no %s" % " ".join(module_flags)
		+ " build_profile=%s" % ProjectSettings.globalize_path(PROFILE_PATH))
	var install_dir := ProjectSettings.globalize_path("res://tools/templates")
	var vinfo := Engine.get_version_info()
	print("[build_profile_gen] kept %d classes, disabled %d -> %s" % [_keep.size(), disabled.size(), PROFILE_PATH])
	print("[build_profile_gen] modules needed: %s" % ", ".join(module_names))
	print("[build_profile_gen] compile from a Godot source checkout matching %s.%s.%s:" % [vinfo["major"], vinfo["minor"], vinfo["status"]])
	print("[build_profile_gen]   %s" % scons_cmd)
	print("[build_profile_gen] then install it so exports and release.ps1 pick it up:")
	print("[build_profile_gen]   copy bin\\godot.windows.template_release.%s.exe \"%s\\windows_release_%s.exe\"" % [arch, install_dir.replace("/", "\\"), arch])
	if needs_d3d12:
		print("[build_profile_gen] NOTE: d3d12 is kept (project renders through the d3d12 driver) — its SDK deps must be installed: misc/scripts/install_d3d12_sdk_windows.py")
	if rendering_method == "gl_compatibility":
		print("[build_profile_gen] NOTE: vulkan=no is additionally possible for gl_compatibility-only projects.")
	print("[build_profile_gen] NOTE: append `winrt=no accesskit=no` only if your build machine lacks those SDKs (accesskit=no removes screen-reader support — an accessibility trade-off, not a free win).")
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
				_keep_class(state.get_node_type(i))
				for j in state.get_node_property_count(i):
					_walk_value(state.get_node_property_value(i, j), visited)
		else:
			_walk_value(res, visited)


func _walk_value(value, visited: Dictionary) -> void:
	if value is Resource:
		if visited.has(value):
			return
		visited[value] = true
		_keep_class(value.get_class())
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
					_keep_class(ident)
