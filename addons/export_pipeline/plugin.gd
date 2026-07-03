@tool
extends EditorPlugin

const MENU_ITEM := "Run Export Analysis"
const MENU_ITEM_PROFILE := "Generate Build Profile (prints scons command)"

var _pruner: EditorExportPlugin


func _enter_tree() -> void:
	_pruner = preload("export_pruner.gd").new()
	add_export_plugin(_pruner)
	add_tool_menu_item(MENU_ITEM, _run_analysis)
	add_tool_menu_item(MENU_ITEM_PROFILE, _generate_build_profile)


func _exit_tree() -> void:
	remove_export_plugin(_pruner)
	remove_tool_menu_item(MENU_ITEM)
	remove_tool_menu_item(MENU_ITEM_PROFILE)
	_pruner = null


## Runs the reachability analyzer headless, prints its summary and opens
## the HTML report in the default browser.
func _run_analysis() -> void:
	var output := []
	var exit_code := OS.execute(OS.get_executable_path(), [
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"-s", "addons/export_pipeline/analyzer/export_analyzer.gd",
	], output, true)
	for chunk in output:
		for line in String(chunk).split("\n"):
			if "[export_analyzer]" in line:
				print(line.strip_edges())
	if exit_code != 0:
		push_error("Export analysis failed (exit %d); see output above." % exit_code)
		return
	EditorInterface.get_resource_filesystem().scan()
	var report := ProjectSettings.globalize_path("res://tools/export_report.html")
	if FileAccess.file_exists(report):
		OS.shell_open(report)


## Regenerates tools/engine.build from the current analysis and prints the
## full scons command for the trimmed export template.
func _generate_build_profile() -> void:
	var output := []
	var exit_code := OS.execute(OS.get_executable_path(), [
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"-s", "addons/export_pipeline/build_profile_gen.gd",
	], output, true)
	var show := RegEx.create_from_string("\\[build_profile_gen\\]|scons |module_|build_profile=|=no|=yes")
	for chunk in output:
		for line in String(chunk).split("\n"):
			if show.search(line):
				print(line)
	if exit_code != 0:
		push_error("Build profile generation failed (exit %d); see output above." % exit_code)
	else:
		print("[build_profile_gen] after compiling, copy the template exe into res://tools/templates/ — exports will report whether it is up to date, and release.ps1 will pick it up automatically.")
