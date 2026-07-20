## Renders the analyzer's data dictionary to JSON, markdown and HTML.
## Pure presentation — no analysis logic lives here.
##
## The HTML report is res://addons/export_pipeline/analyzer/report_template.html (static, hand-written
## CSS/JS) with the report data injected at the {{REPORT_JSON}} token.
extends RefCounted

const REPORT_MD := "res://tools/export_report.md"
const REPORT_JSON := "res://tools/export_report.json"
const REPORT_HTML := "res://tools/export_report.html"
const HTML_TEMPLATE := "res://addons/export_pipeline/analyzer/report_template.html"


static func write_all(data: Dictionary, ext_md: Dictionary) -> void:
	_write_file(REPORT_JSON, JSON.stringify(data, "\t") + "\n")
	_write_file(REPORT_MD, "\n".join(_markdown(data, ext_md)))

	var template := FileAccess.get_file_as_string(HTML_TEMPLATE)
	if template.is_empty():
		push_warning("[report_writer] missing %s — HTML report skipped." % HTML_TEMPLATE)
	else:
		# "</" inside string data would terminate the inline <script> early.
		var payload := JSON.stringify(data).replace("</", "<\\/")
		_write_file(REPORT_HTML, template.replace("{{REPORT_JSON}}", payload))


static func _write_file(path: String, content: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(content)
	f.close()


static func _markdown(data: Dictionary, ext_md: Dictionary) -> PackedStringArray:
	var totals: Dictionary = data["totals"]
	var sizes: Dictionary = data["sizes"]
	var referrers: Dictionary = data["referrers"]
	var md := PackedStringArray()

	md.append("# Export reachability report")
	md.append("")
	md.append("Project: %s — generated %s" % [data.get("project", "?"), data["generated"]])
	md.append("")
	md.append("| | files | size |")
	md.append("|---|---|---|")
	md.append("| Used (runtime-reachable) | %d | %s |" % [totals["used_count"], String.humanize_size(totals["used_size"])])
	md.append("| Unused resources | %d | %s |" % [totals["unused_count"], String.humanize_size(totals["unused_size"])])
	if totals.has("excluded_count"):
		md.append("| — of which excluded on purpose (config/extension) | %d | |" % totals["excluded_count"])
	if int(totals.get("excluded_but_referenced_count", 0)) > 0:
		md.append("| — **excluded but still referenced (broken by pruning!)** | %d | |" % totals["excluded_but_referenced_count"])
	md.append("| Non-resource files (never exported) | %d | %s |" % [totals["non_resource_count"], String.humanize_size(totals["non_resource_size"])])
	md.append("")

	var warnings: Array = data["warnings"]
	if not warnings.is_empty():
		md.append("## Warnings (%d)" % warnings.size())
		md.append("")
		for w in warnings:
			md.append("- %s" % w)
		md.append("")

	var evidence: Dictionary = data.get("unused_evidence", {})
	var critical := []
	for path in data["unused"]:
		if evidence.has(path) and evidence[path].get("status", "") == "excluded_but_referenced":
			critical.append(path)
	if not critical.is_empty():
		md.append("## Excluded but still referenced (%d)" % critical.size())
		md.append("")
		md.append("These files are excluded by config or an extension, yet reachable code still references them — the exported game will miss them:")
		md.append("")
		for path in critical:
			var ev: Dictionary = evidence[path]
			md.append("- %s  <- %s  (excluded by %s: %s)" % [path, ", ".join(ev.get("refs_from_reachable", [])), ev.get("excluded_source", "?"), ev.get("excluded_by", "?")])
		md.append("")

	md.append("## Used files (%d)" % totals["used_count"])
	md.append("")
	for path in data["used"]:
		md.append("- %s  <- %s" % [path, ", ".join(referrers.get(path, []))])
	md.append("")

	md.append("## Unused resources (%d)" % totals["unused_count"])
	md.append("")
	md.append("Candidates for skip() in the export plugin, grouped by directory. Each entry carries its evidence: excluded on purpose (and by whom), gated by an extension, or genuinely unreferenced.")
	md.append("")
	var excluded_prefixes: Dictionary = data.get("excluded_prefixes", {})
	var by_dir := {}
	for path in data["unused"]:
		var d: String = String(path).get_base_dir()
		if not by_dir.has(d):
			by_dir[d] = {"files": [], "size": 0}
		by_dir[d]["files"].append(path)
		by_dir[d]["size"] += int(sizes.get(path, 0))
	var dirs := by_dir.keys()
	dirs.sort()
	for d in dirs:
		var dir_tag := ""
		for prefix in excluded_prefixes:
			if (String(d) + "/").begins_with(String(prefix)) or String(d) == String(prefix).trim_suffix("/"):
				dir_tag = " — excluded by %s (%s)" % [excluded_prefixes[prefix], prefix]
				break
		md.append("### %s (%d files, %s)%s" % [d, by_dir[d]["files"].size(), String.humanize_size(by_dir[d]["size"]), dir_tag])
		for path in by_dir[d]["files"]:
			var note := ""
			if evidence.has(path):
				note = " — " + String(evidence[path].get("evidence", ""))
			md.append("- %s (%s)%s" % [String(path).get_file(), String.humanize_size(int(sizes.get(path, 0))), note])
		md.append("")

	var ext_json: Dictionary = data["extensions"]
	if not ext_json.is_empty():
		md.append("## Extensions")
		md.append("")
		for ename in ext_json:
			var summary = ext_json[ename].get("summary", "") if ext_json[ename] is Dictionary else ""
			md.append("- **%s**%s" % [ename, ": " + String(summary) if summary else ""])
		md.append("")
		for ename in ext_md:
			var lines: PackedStringArray = ext_md[ename]
			if not lines.is_empty():
				md.append_array(lines)

	var engine_classes: Array = data["engine_classes"]
	md.append("## Engine classes referenced (%d)" % engine_classes.size())
	md.append("")
	md.append("Seed list for the engine build profile (scene node/resource types, script extends and engine-class identifiers in used code; binary .res internals are covered by addons/export_pipeline/build_profile_gen.gd):")
	md.append("")
	for c in engine_classes:
		md.append("- %s" % c)
	md.append("")
	return md
