extends SceneTree
## The pipeline's own checks, headless and without a test framework:
##   godot --headless --path . -s tests/run.gd
## Prints each failure and "export_pipeline: N checks, M failed"; exits 1 on any failure.

var _checks := 0
var _failed := 0


func _initialize() -> void:
	_build_profile_lint()
	_font_subset()
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


## FontSubset over the fixtures (tests/fixtures/fonts: a CSV, a dialogue, a script, a JSON, a skipped sample); the cut
## and the check with a system face when one is here (a TTF the machine has: none is committed).
func _font_subset() -> void:
	_check(FontSubset.config("res://tests/fixtures/none.json").is_empty(), "no config: the feature is off")
	_check(FontSubset.missing("res://tests/fixtures/none.json").has("skip"), "no config: a test skips")
	var cfg := {roots = ["tests/fixtures/fonts/game"], skip = ["sample"], keep = ["ascii", "cjk_punct"], chars = "※"}
	var got := FontSubset.collect(cfg)
	for c in "你好两行早上好。字面单引三引号包名Hi\"you\"two":
		_check(got.contains(c), "collected: %s (%s)" % [c, got])
	for c in "注释尾文档采情境":
		_check(not got.contains(c), "not collected (a comment, a sample, a context column): %s" % c)
	_check(not FontSubset.collect({roots = cfg.roots, skip = ["sample"], types = ["csv", "dialogue", "gd"]}).contains("包"),
		"a type not asked for is not read")
	var keep := FontSubset.kept(cfg, got)
	_check(keep.contains("A") and keep.contains("、") and keep.contains("※") and keep.contains("你"), "kept: the sets, the extras, the text")
	_check(not keep.contains("中"), "a set not asked for is not kept")
	var big := FontSubset.kept({keep = ["gb2312_1", "jis_1", "kana"]}, "")
	_check(big.contains("中") and big.contains("あ") and big.length() > 5000, "the common sets: %d characters" % big.length())
	_check(Array(FontSubset.string_literals("var a := \"x # y\"  # z\nvar b := 'q'")) == ["x # y", "q"], "a # in a string is no comment")
	# the cut and the check: from a system face when the machine has one (and a subsetter)
	var face := ""
	for p in ["/System/Library/Fonts/Supplemental/Arial Unicode.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]:
		if FileAccess.file_exists(p):
			face = p
			break
	if face == "":
		print("(font_subset: no system face here, the cut not tried)")
		return
	var out := OS.get_cache_dir().path_join("font_subset_test/sub.ttf")
	var err := FontSubset.cut(face, out, "AB你")
	if err.contains("neither"):
		print("(font_subset: no subsetter here, the cut not tried)")
		return
	_check(err == "", "cut: %s" % err)
	var full := FontFile.new()
	full.load_dynamic_font(face)
	var r: Array = FontSubset.check({fonts = [{source = face, out = out}]}, "AB你C")
	_check(r.size() == 1 and r[0].present, "the subset is there: %s" % [r])
	var want_missing := "C" if full.has_char("C".unicode_at(0)) else ""
	_check(r[0].missing == want_missing, "what the face has and the subset lacks: %s" % [r])
	_check(FileAccess.get_file_as_bytes(out).size() < FileAccess.get_file_as_bytes(face).size() / 4, "the subset is a fraction of the face")
