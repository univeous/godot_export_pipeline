extends SceneTree
## The pipeline's own checks, headless and without a test framework:
##   godot --headless --path . -s tests/run.gd
## Prints each failure and "export_pipeline: N checks, M failed"; exits 1 on any failure.

var _checks := 0
var _failed := 0


func _initialize() -> void:
	_build_profile_lint()
	print("export_pipeline: %d checks, %d failed" % [_checks, _failed])
	quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failed += 1
		printerr("FAIL: ", what)


## BuildProfileLint over scripts and a profile written for it into user://.
func _build_profile_lint() -> void:
	var dir := "user://profile_lint"
	_remove(dir)
	DirAccess.make_dir_recursive_absolute(dir + "/game/sub")
	_write(dir + "/engine.build", JSON.stringify({"disabled_classes": ["AtlasTexture", "Curve3D"],
		"disabled_build_options": {"disable_physics_3d": true}}))
	_write(dir + "/game/uses.gd", "extends Node\n\nfunc a() -> void:\n\tvar t := AtlasTexture.new()\n"
		+ "\tvar c: Curve3D = null\n\tvar b := RigidBody3D.new()\n\tvar k := ImageTexture.new()\n"
		+ "\t# var x := AtlasTexture.new()  (a comment)\n\tvar s := \"AtlasTexture.new()\"\n")
	_write(dir + "/game/sub/kind.gd", "extends AtlasTexture\n\nfunc f(x: Object) -> Curve3D:\n\treturn x as Curve3D if x is Curve3D else null\n")
	_write(dir + "/game/plugin.gd", "@tool\nextends EditorPlugin\n\nfunc a() -> void:\n\tvar t := AtlasTexture.new()\n")
	var stats := {}
	var found := BuildProfileLint.left_out_uses([dir + "/game", dir + "/not_there"], dir + "/engine.build", stats)
	var lines := Array(found).map(func(f: String) -> String: return f.trim_prefix(dir + "/game/"))
	_check(lines.has("uses.gd:4 uses AtlasTexture (disabled_classes)") and lines.has("uses.gd:5 uses Curve3D (disabled_classes)"),
		"a class the profile lists, made or typed: %s" % [lines])
	_check(lines.has("uses.gd:6 uses RigidBody3D (disable_physics_3d)"), "a class a build option compiles out: %s" % [lines])
	_check(lines.has("sub/kind.gd:1 uses AtlasTexture (disabled_classes)") and lines.has("sub/kind.gd:3 uses Curve3D (disabled_classes)")
		and lines.has("sub/kind.gd:4 uses Curve3D (disabled_classes)"), "extended, returned, cast and tested: %s" % [lines])
	_check(lines.size() == 6, "nothing else: a kept class, a comment, a string, an editor plugin left alone: %s" % [lines])
	_check(stats.read == 2, "the editor plugin not read, the rest read: %s" % [stats])
	_check(BuildProfileLint.left_out_uses([dir + "/game"], dir + "/none.build").is_empty(), "no profile, nothing to find")
	var why := BuildProfileLint.left_out({"disabled_classes": ["Curve3D"], "disabled_build_options": {"disable_3d": true}},
		["Curve3D", "MeshInstance3D", "Label"])
	_check(why == {"Curve3D": "disabled_classes", "MeshInstance3D": "disable_3d"}, "left_out says why, a kept class absent: %s" % [why])


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _remove(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_remove(dir.path_join(d))
	DirAccess.remove_absolute(dir)
