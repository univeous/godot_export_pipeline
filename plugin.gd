@tool
extends EditorPlugin

const MENU_ITEM := "Run Export Analysis"
const MENU_ITEM_PROFILE := "Generate Build Profile (prints scons command)"
const ANALYZER := "addons/export_pipeline/analyzer/export_analyzer.gd"
const PROFILE_GEN := "addons/export_pipeline/build_profile_gen.gd"

var _pruner: EditorExportPlugin
var _job: Thread


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
	if _job:
		_job.wait_to_finish()
		_job = null


## Runs the reachability analyzer, refreshes the build profile when the
## project uses one (same linkage as the pruner), then opens the HTML report.
func _run_analysis() -> void:
	_run_headless(ANALYZER, func(exit_code: int) -> void:
		if exit_code != 0:
			push_error("Export analysis failed (exit %d); see output above." % exit_code)
			return
		if FileAccess.file_exists("res://tools/engine.build"):
			_run_headless(PROFILE_GEN, func(_profile_exit: int) -> void: _open_report())
		else:
			_open_report()
	)


## Regenerates tools/engine.build and prints the full scons command.
func _generate_build_profile() -> void:
	_run_headless(PROFILE_GEN, func(exit_code: int) -> void:
		if exit_code != 0:
			push_error("Build profile generation failed (exit %d); see output above." % exit_code)
	)


func _open_report() -> void:
	EditorInterface.get_resource_filesystem().scan()
	var report := ProjectSettings.globalize_path("res://tools/export_report.html")
	if FileAccess.file_exists(report):
		print_rich("[color=web_gray][export_pipeline][/color] report: [url=file:///%s]%s[/url]" % [report.replace("\\", "/"), report])
		OS.shell_open(report)


## Runs a pipeline script headless on a worker thread — the editor stays
## responsive — and echoes tagged output to the Output panel when done.
func _run_headless(script_path: String, on_done: Callable) -> void:
	if _job and _job.is_alive():
		push_warning("[export_pipeline] a pipeline task is already running — try again when it finishes.")
		return
	if _job:
		_job.wait_to_finish()
	print_rich("[color=web_gray][export_pipeline] running %s in the background...[/color]" % script_path)
	var godot := OS.get_executable_path()
	var project := ProjectSettings.globalize_path("res://")
	_job = Thread.new()
	_job.start(func() -> void:
		var output := []
		var exit_code := OS.execute(godot, ["--headless", "--path", project, "-s", script_path], output, true)
		_finish_job.call_deferred(output, exit_code, on_done)
	)


func _finish_job(output: Array, exit_code: int, on_done: Callable) -> void:
	if _job:
		_job.wait_to_finish()
		_job = null
	for chunk in output:
		for line in String(chunk).split("\n"):
			if "[export_analyzer]" in line or "[build_profile_gen]" in line:
				_echo(line.strip_edges())
	on_done.call(exit_code)


## Prints one pipeline line with Output-panel styling. Literal brackets in
## the content must be escaped or BBCode would eat them as tags.
func _echo(line: String) -> void:
	var safe := line.replace("[", "[lb]")
	if "WARNING" in line:
		print_rich("[color=yellow]%s[/color]" % safe)
	elif "]   " in line:
		# Command lines (scons / copy / release invocation) — the generator
		# marks them with a three-space indent after the tag.
		print_rich("[color=cyan][code]%s[/code][/color]" % safe)
	elif line.begins_with("[export_analyzer] used:") or line.begins_with("[build_profile_gen] kept"):
		print_rich("[b]%s[/b]" % safe)
	else:
		print_rich(safe)
