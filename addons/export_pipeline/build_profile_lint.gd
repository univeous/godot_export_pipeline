class_name BuildProfileLint
extends RefCounted
## The engine build profile (tools/engine.build) against the code, for a project's tests: a class the profile leaves
## out — listed in disabled_classes, or compiled out by a disable_* build option — that a script uses still runs in the
## editor and on stock templates, and closes the game built from the trimmed template. The export warns about it too
## (export_pruner), but only from a full analysis at export time; this reads the scripts themselves, so a test fails
## the day the code starts using such a class.
##
## The profile follows the code, never the reverse: when a finding is a class the code now means to use, regenerate the
## profile (build_profile_gen.gd) and rebuild the template — don't work around the class.
##   var found := BuildProfileLint.left_out_uses(["res://game", "res://addons/my_runtime_addon"])
##   assert(found.is_empty())   # each "path:line uses Class (why)"

const PipelineDefaults := preload("pipeline_defaults.gd")
const PROFILE_PATH := "res://tools/engine.build"
## The ways a script uses a class by name: makes one, extends it, tests or casts to it, types a value as it.
const USE := "\\b([A-Z]\\w*)\\.new\\(|^\\s*extends\\s+([A-Z]\\w*)|\\bis\\s+([A-Z]\\w*)|\\bas\\s+([A-Z]\\w*)|:\\s*([A-Z]\\w*)|->\\s*([A-Z]\\w*)"


## The classes a build profile leaves out, and why ({class: "disabled_classes" | "<disable_* option>"}), judged for
## `classes`: listed, or compiled out by an option the profile turns on (the generator's class→option rules).
static func left_out(profile: Dictionary, classes: Array) -> Dictionary:
	var disabled := {}
	for c in profile.get("disabled_classes", []):
		disabled[String(c)] = true
	var opts: Dictionary = profile.get("disabled_build_options", {})
	var out := {}
	for c in classes:
		var name := String(c)
		if disabled.has(name):
			out[name] = "disabled_classes"
			continue
		for opt in PipelineDefaults.class_disable_conflicts(name):
			if bool(opts.get(opt, false)):
				out[name] = opt
				break
	return out


## Where the scripts under `roots` use an engine class the profile at `profile_path` leaves out: "path:line uses Class
## (why)". An editor plugin's scripts (extends EditorPlugin) never ship and are skipped, as are comments and strings. Empty when
## there is no profile (the project builds no trimmed template). `stats` gets "read": the scripts read.
static func left_out_uses(roots: Array, profile_path := PROFILE_PATH, stats: Dictionary = {}) -> PackedStringArray:
	var out := PackedStringArray()
	if not FileAccess.file_exists(profile_path):
		return out
	var profile: Variant = JSON.parse_string(FileAccess.get_file_as_string(profile_path))
	if not profile is Dictionary:
		out.append("%s: not a build profile" % profile_path)
		return out
	var rx := RegEx.create_from_string(USE)
	var judged := {}  # class -> why ("" when kept)
	for path in _scripts(roots):
		var text := FileAccess.get_file_as_string(path)
		if text.contains("extends EditorPlugin"):
			continue
		stats["read"] = int(stats.get("read", 0)) + 1
		var lines := text.split("\n")
		for i in lines.size():
			var line := code_only(lines[i])
			var named := {}
			for m in rx.search_all(line):
				for g in range(1, 7):
					var c := m.get_string(g)
					if c != "" and ClassDB.class_exists(c):
						named[c] = true
			for c: String in named:
				if not judged.has(c):
					judged[c] = left_out(profile, [c]).get(c, "")
				if judged[c] != "":
					out.append("%s:%d uses %s (%s)" % [path, i + 1, c, judged[c]])
	return out


static func _scripts(roots: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for r: String in roots:
		if DirAccess.dir_exists_absolute(r):
			_walk(r, out)
	return out


static func _walk(dir: String, out: PackedStringArray) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with("."):
			_walk(dir.path_join(d), out)


## `line`'s code only: its strings blanked and its comment (a `#` outside a string to the end) cut — a class named in
## words is no use of it.
static func code_only(line: String) -> String:
	var out := ""
	var quote := ""
	for i in line.length():
		var ch := line[i]
		if quote != "":
			if ch == quote and line[i - 1] != "\\":
				quote = ""
			out += ch if quote == "" else " "
		elif ch == "\"" or ch == "'":
			quote = ch
			out += ch
		elif ch == "#":
			return out
		else:
			out += ch
	return out
