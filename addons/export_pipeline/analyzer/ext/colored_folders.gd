## Analyzer extension: editor folder colors as editor-only declarations.
##
## Integrates with the exclude_colored_folders addon
## (https://github.com/...): folders whose color is mapped to
## "Don't Export (Always)" or "Don't Export (Release)" are fed into the
## analyzer's editor_only blacklist, so reachability, runtime-reference
## warnings, autoload dropping and the unused report all agree with what
## that addon skips at export time. Coloring a folder in the editor IS the
## declaration — no analyzer config needed.
##
## "Don't Export (Debug)" folders still ship in release builds, so they are
## NOT blacklisted here (the analysis models the release export); they are
## listed in the report for visibility.
##
## No-ops on projects without folder colors or the operation settings.
extends RefCounted

## Matches exclude_colored_folders' FolderColorOperation enum.
const OP_NO_OPERATION := 0
const OP_SKIP_ALWAYS := 1
const OP_SKIP_ON_RELEASE := 2
const OP_SKIP_ON_DEBUG := 3

var _editor_only: Array[String] = []
var _debug_only_skips: Array[String] = []


func extension_name() -> String:
	return "colored_folders"


## Folders excluded for the given build mode, per the addon's conventions.
static func excluded_folders(is_debug: bool) -> Array[String]:
	var out: Array[String] = []
	var colors: Dictionary = ProjectSettings.get_setting("file_customization/folder_colors", {})
	for folder in colors:
		var op := int(ProjectSettings.get_setting(
			"addons/exclude_colored_folders/folder_color_operation/%s" % colors[folder],
			OP_NO_OPERATION))
		if op == OP_SKIP_ALWAYS or (op == OP_SKIP_ON_RELEASE and not is_debug) or (op == OP_SKIP_ON_DEBUG and is_debug):
			out.append(String(folder))
	out.sort()
	return out


# ── analyzer-side: the analysis models the release export ──────────────────

func setup(analyzer) -> void:
	_editor_only = excluded_folders(false)
	for folder in _editor_only:
		analyzer.add_editor_only(folder, "colored_folders (folder color)")
	var colors: Dictionary = ProjectSettings.get_setting("file_customization/folder_colors", {})
	for folder in colors:
		if int(ProjectSettings.get_setting(
				"addons/exclude_colored_folders/folder_color_operation/%s" % colors[folder],
				OP_NO_OPERATION)) == OP_SKIP_ON_DEBUG:
			_debug_only_skips.append(String(folder))
	_debug_only_skips.sort()


# ── pruner-side: mode-aware via the actual export's is_debug ────────────────

func export_begin(pruner, _report: Dictionary, _config: Dictionary, is_debug: bool) -> void:
	for folder in excluded_folders(is_debug):
		pruner.add_editor_only(folder)


func report(analyzer) -> Dictionary:
	if _editor_only.is_empty() and _debug_only_skips.is_empty():
		return {"summary": "no excluded folder colors configured"}
	return {
		"summary": "%d colored folder(s) treated as editor-only" % _editor_only.size(),
		"editor_only": _editor_only,
		"debug_only_skips": _debug_only_skips,
	}
