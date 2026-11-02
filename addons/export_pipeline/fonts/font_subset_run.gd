extends SceneTree
## Makes the project's font subsets (FontSubset; its config says which), or checks them:
##   godot --headless --path . -s addons/export_pipeline/fonts/font_subset_run.gd             cut, then check
##   godot --headless --path . -s addons/export_pipeline/fonts/font_subset_run.gd -- --check  check the subsets there
##   … -- --config=<path>   another config than res://tools/font_subset.json (a trial into other outputs)
## Exit: 0 done (or the project has no config: nothing to do); 1 a subset lacks a character the game shows; 2 the
## config, a face or the subsetter is missing or failed. Self-check: fewer than 50 characters collected means a root was
## not read (2).

const Subset := preload("font_subset.gd")  # (by path: a -s run may come before the class cache knows FontSubset)


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var path := Subset.CONFIG_PATH
	for a in args:
		if a.begins_with("--config="):
			path = a.trim_prefix("--config=")
	quit(_run(args.has("--check"), path))


func _run(check_only: bool, path: String) -> int:
	var t0 := Time.get_ticks_msec()
	var cfg := Subset.config(path)
	if cfg.is_empty():
		print("font_subset: no %s -- this project ships no font subset" % path)
		return 0
	if cfg.has("error"):
		printerr("font_subset: " + str(cfg.error))
		return 2
	var collected := Subset.collect(cfg)
	if collected.length() < 50:
		printerr("font_subset: only %d characters collected -- a root was not read (%s)" % [collected.length(), cfg.get("roots")])
		return 2
	var keep := Subset.kept(cfg, collected)
	_write(cfg.get("chars_out"), keep)
	_write(cfg.get("source_chars_out"), collected)
	if not check_only:
		for f: Dictionary in cfg.get("fonts", []):
			var src := ProjectSettings.globalize_path(Subset.path_of(str(f.get("source", ""))))
			if not FileAccess.file_exists(src):
				printerr("font_subset: no face at %s" % src)
				return 2
			var err := Subset.cut(src, ProjectSettings.globalize_path(Subset.path_of(str(f.get("out", "")))), keep)
			if err != "":
				printerr("font_subset: %s: %s" % [f.get("source"), err])
				return 2
	var rc := 0
	for r: Dictionary in Subset.check(cfg, collected):
		if not r.present:
			printerr("font_subset: no subset at %s" % r.font)
			rc = maxi(rc, 2)
			continue
		var bytes := FileAccess.get_file_as_bytes(Subset.path_of(str(r.font))).size()
		print("font_subset: %s, %d KB, %d characters collected" % [r.font, bytes / 1024, collected.length()])
		if r.lacking != "":
			print("  not in the full face either (a fallback font draws them): %s" % r.lacking.left(80))
		if r.missing != "":
			printerr("  MISSING from the subset: %s" % r.missing)
			rc = maxi(rc, 1)
	if rc == 0 and not check_only:
		_meta(cfg, collected)
	print("font_subset: %s in %.1f s" % ["ok" if rc == 0 else "failed", (Time.get_ticks_msec() - t0) / 1000.0])
	return rc


func _write(rel: Variant, text: String) -> void:
	if rel == null or str(rel) == "":
		return
	var path := Subset.path_of(str(rel))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## The provenance beside the subsets (meta_out): each face's source md5 and its subset's, the tool, the characters
## collected, and the config's own "meta" (version, url, licence) — a diff shows what text changed.
func _meta(cfg: Dictionary, collected: String) -> void:
	if cfg.get("meta_out") == null or str(cfg.get("meta_out")) == "":
		return
	var fonts := []
	for f: Dictionary in cfg.get("fonts", []):
		var src := Subset.path_of(str(f.get("source", "")))
		var out := Subset.path_of(str(f.get("out", "")))
		fonts.append({source = str(f.get("source")).get_file(), source_md5 = FileAccess.get_md5(src), out = f.get("out"),
			bytes = FileAccess.get_file_as_bytes(out).size(), md5 = FileAccess.get_md5(out)})
	var meta := {fonts = fonts, keep = cfg.get("keep", []), tool = "export_pipeline FontSubset",
		made = Time.get_datetime_string_from_system(true) + "Z", characters = collected.length(), text = collected}
	meta.merge(cfg.get("meta", {}))
	_write(cfg.meta_out, JSON.stringify(meta, " ", false))
