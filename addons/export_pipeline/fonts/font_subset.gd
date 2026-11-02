class_name FontSubset
extends RefCounted
## Optional: ship a font cut down to the characters the game shows. A CJK face is 10-20 MB; the characters a game
## actually uses, plus the common ones a later text or a content pack is likely to add, are a tenth of that. Nothing
## happens unless the project has a config (CONFIG_PATH); without one, run() says so and exits 0, and a test calling
## missing() skips.
##
## The config (JSON):
##   fonts       [{"source": "<full face>", "out": "<subset>"}, …]   paths relative to the project, or absolute
##   roots       folders whose text is collected (below)
##   skip        folder or file names left out wherever they are (a sample pack)
##   types       the file types read (default TEXT_TYPES); a project whose JSON is provenance, not text, leaves json out
##   keep        named sets kept whatever the text has today: ascii, latin_ext, punct, cjk_punct, kana, gb2312_1, jis_1
##   chars       extra characters always kept
##   chars_out   optional: the kept characters, written as text (an export plugin's fallback check reads it)
##   source_chars_out  optional: the collected characters, written as text
##   meta_out    optional: provenance JSON beside the subset (the source's md5, the tool, the characters); its "meta"
##               object (version, url, licence) is copied in
## What is collected, by file type: a translation CSV's every column but the key (and a "?context" column); a
## .dialogue whole; a script's or a scene's string literals only (comments are never shown); JSON and project.godot
## whole.
##
## Run: godot --headless --path . -s addons/export_pipeline/fonts/font_subset_run.gd [-- --check]
## Cutting needs hb-subset (harfbuzz) or uv (fonttools, fetched on the fly); checking needs neither.
## Traps written down where they bit:
## - the subsetters keep only name IDs 0-6 by default, dropping the licence (13, 14) the OFL wants carried: all kept;
## - layout features (vertical forms, kerning, ligatures) go unless asked for: all kept;
## - a full face inside res:// is imported, and an export that takes its folder ships all of it beside the subset:
##   keep the sources in a .gdignore folder.

const CONFIG_PATH := "res://tools/font_subset.json"
const SETS_DIR := "res://addons/export_pipeline/fonts/sets/"
## Named ranges a config may keep (inclusive code points).
const RANGES := {
	"ascii": [[0x20, 0x7E]],
	"latin_ext": [[0xA0, 0xFF], [0x100, 0x17F]],
	"punct": [[0x2000, 0x206F], [0x2190, 0x21FF], [0x2460, 0x24FF], [0x25A0, 0x25FF], [0x2600, 0x26FF]],
	"cjk_punct": [[0x3000, 0x303F], [0xFF00, 0xFFEF]],
	"kana": [[0x3040, 0x30FF], [0x31F0, 0x31FF]],
}
## Named sets read from SETS_DIR (make_sets.py writes them).
const FILE_SETS := ["gb2312_1", "jis_1"]
const TEXT_TYPES := ["csv", "dialogue", "gd", "tscn", "tres", "json", "godot"]


## The project's config, or {} when it has none (the feature is off).
static func config(path := CONFIG_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var c: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return c if c is Dictionary else {"error": "%s is not a JSON object" % path}


## Every character the game's text holds (the config's roots), each once, in code-point order; control characters out.
static func collect(cfg: Dictionary) -> String:
	var seen := {}
	for root: String in cfg.get("roots", []):
		for path in _files(path_of(root), cfg.get("skip", []), cfg.get("types", TEXT_TYPES)):
			var text := FileAccess.get_file_as_string(path)
			match path.get_extension():
				"csv":
					_take_csv(seen, path)
				"gd", "tscn", "tres":
					for s in string_literals(text):
						_take(seen, s)
				_:
					_take(seen, text)
	return _sorted(seen)


## What the subset keeps: `collected` with the config's named sets and extra characters.
static func kept(cfg: Dictionary, collected: String) -> String:
	var seen := {}
	_take(seen, collected)
	_take(seen, str(cfg.get("chars", "")))
	for name: String in cfg.get("keep", []):
		if RANGES.has(name):
			for r: Array in RANGES[name]:
				for c in range(r[0], r[1] + 1):
					seen[c] = true
		elif name in FILE_SETS:
			_take(seen, FileAccess.get_file_as_string(SETS_DIR + name + ".txt"))
	return _sorted(seen)


## The check, for each of the config's fonts: {font: the subset's path, present: whether it is there (a fresh clone has
## none: the faces stay out of git), missing: collected characters the full face has and the subset lacks, lacking:
## collected characters the full face itself lacks (drawn by a fallback font, if any)}. A face whose source is not
## here either is judged by its subset alone. [] when the feature is off.
static func check(cfg: Dictionary, collected := "") -> Array:
	if cfg.is_empty():
		return []
	if collected == "":
		collected = collect(cfg)
	var out := []
	for f: Dictionary in cfg.get("fonts", []):
		var sub := _font(path_of(str(f.get("out", ""))))
		var src := _font(path_of(str(f.get("source", ""))))
		var missing := ""
		var lacking := ""
		if sub != null:
			for i in collected.length():
				var c := collected.unicode_at(i)
				if c <= 0x20 or c == 0x3000:
					continue  # (spaces: no glyph needed)
				if src != null and not src.has_char(c):
					lacking += collected[i]
				elif not sub.has_char(c):
					missing += collected[i]
		out.append({font = f.get("out", ""), present = sub != null, missing = missing, lacking = lacking})
	return out


## For a test: the characters the game shows that a shipped subset lacks, "font: chars" for each; {skip: why} when the
## feature is off or no subset is here to check.
static func missing(cfg_path := CONFIG_PATH) -> Dictionary:
	var cfg := config(cfg_path)
	if cfg.is_empty():
		return {skip = "no %s: the project ships no font subset" % cfg_path}
	if cfg.has("error"):
		return {problems = [cfg.error]}
	var collected := collect(cfg)
	var problems := []
	var present := 0
	for r: Dictionary in check(cfg, collected):
		if r.present:
			present += 1
		if r.missing != "":
			problems.append("%s lacks %d: %s (run font_subset_run.gd)" % [r.font, r.missing.length(), r.missing])
	if present == 0:
		return {skip = "no subset made here (font_subset_run.gd makes them from the full faces)"}
	return {problems = problems, collected = collected.length()}


## Cuts each config font to `keep` (a string of characters): hb-subset, else fonttools through uv. Returns "" or what
## failed.
static func cut(source_abs: String, out_abs: String, keep: String) -> String:
	var tmp := OS.get_cache_dir().path_join("font_subset_%d.txt" % Time.get_ticks_usec())
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return "cannot write %s" % tmp
	f.store_string(keep)
	f.close()
	DirAccess.make_dir_recursive_absolute(out_abs.get_base_dir())
	var log := []
	var rc := OS.execute("hb-subset", ["--font-file=" + source_abs, "--text-file=" + tmp, "--output-file=" + out_abs,
		"--name-IDs=*", "--name-languages=*", "--layout-features=*", "--notdef-outline"], log, true)
	if rc == -1:  # (no hb-subset here)
		log.clear()
		rc = OS.execute("uv", ["run", "-q", "--with", "fonttools", "pyftsubset", source_abs, "--text-file=" + tmp,
			"--output-file=" + out_abs, "--name-IDs=*", "--name-languages=*", "--layout-features=*", "--notdef-outline",
			"--no-glyph-names"], log, true)
		if rc == -1:
			DirAccess.remove_absolute(tmp)
			return "neither hb-subset (harfbuzz) nor uv (fonttools) is installed"
	DirAccess.remove_absolute(tmp)
	return "" if rc == 0 else "the subsetter failed (%d): %s" % [rc, "".join(log).strip_edges().left(400)]


## The quoted strings of GDScript or a scene, comments skipped ("a # in a string" stays a string).
static func string_literals(text: String) -> Array[String]:
	var out: Array[String] = []
	var quote := ""
	var cur := ""
	var i := 0
	var n := text.length()
	while i < n:
		var ch := text[i]
		if quote == "":
			if ch == "#":
				while i < n and text[i] != "\n":
					i += 1
				continue
			if text.substr(i, 3) == "\"\"\"":
				quote = "\"\"\""
				i += 3
				continue
			if ch == "\"" or ch == "'":
				quote = ch
		else:
			if ch == "\\" and i + 1 < n:
				cur += text[i + 1]
				i += 2
				continue
			if text.substr(i, quote.length()) == quote:
				out.append(cur)
				cur = ""
				i += quote.length()
				quote = ""
				continue
			if ch == "\n" and quote.length() == 1:  # (an unterminated quote: a stray apostrophe)
				quote = ""
				cur = ""
			else:
				cur += ch
		i += 1
	return out


## A config's path: as given when absolute (res://, user://, a file system path), else under res://.
static func path_of(p: String) -> String:
	return p if p.is_absolute_path() else "res://" + p


static func _font(path: String) -> FontFile:
	if not FileAccess.file_exists(path):
		return null
	var font := FontFile.new()
	return font if font.load_dynamic_font(ProjectSettings.globalize_path(path)) == OK else null


static func _take(seen: Dictionary, s: String) -> void:
	for i in s.length():
		var c := s.unicode_at(i)
		if c >= 0x20 and c != 0x7F:
			seen[c] = true


## A translation CSV: every column but the key and a "?context" one, cells as the import reads them (quoted, multi-line).
static func _take_csv(seen: Dictionary, path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var head := f.get_csv_line()
	while not f.eof_reached():
		var row := f.get_csv_line()
		for c in range(1, row.size()):
			if c < head.size() and head[c].begins_with("?"):
				continue
			_take(seen, row[c])


static func _sorted(seen: Dictionary) -> String:
	var codes := seen.keys()
	codes.sort()
	var out := ""
	for c: int in codes:
		out += String.chr(c)
	return out


static func _files(path: String, skip: Array, types: Array = TEXT_TYPES) -> PackedStringArray:
	var out := PackedStringArray()
	if FileAccess.file_exists(path):
		out.append(path)  # (a file named as a root: project.godot)
	elif DirAccess.dir_exists_absolute(path):
		_walk(path, skip, types, out)
	return out


## The text files under `dir`, a folder or a file named in `skip` left out.
static func _walk(dir: String, skip: Array, types: Array, out: PackedStringArray) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.get_extension() in types and not f in skip:
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with(".") and not d in skip:
			_walk(dir.path_join(d), skip, types, out)
