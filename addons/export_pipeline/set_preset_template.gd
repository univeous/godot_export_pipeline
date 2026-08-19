## Patches one export preset's custom_template/{debug,release} field in
## export_presets.cfg, via Godot's own ConfigFile parser so the file's other
## sections (including multi-line ssh_remote_deploy script values) round-trip
## byte-for-byte correct. Release automation can use it to point a preset at
## a self-built template for one --export-debug/--export-release run. This
## script never backs up or restores the preset; the caller owns that lifecycle.
##
## Usage:
##   godot --headless --path . -s addons/export_pipeline/set_preset_template.gd -- <preset name> <true|false is_debug> <absolute template path>
extends SceneTree

const PRESETS_PATH := "res://export_presets.cfg"


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 3:
		push_error("usage: set_preset_template.gd -- <preset name> <is_debug> <template path>")
		quit(1)
		return
	var preset_name := args[0]
	var is_debug := args[1] == "true"
	var template_path := args[2]

	var config := ConfigFile.new()
	var err := config.load(PRESETS_PATH)
	if err != OK:
		push_error("failed to load %s: %d" % [PRESETS_PATH, err])
		quit(1)
		return

	var target_section := ""
	for section in config.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options") \
				and String(config.get_value(section, "name", "")) == preset_name:
			target_section = section
			break
	if target_section.is_empty():
		push_error("no preset named '%s' in %s" % [preset_name, PRESETS_PATH])
		quit(1)
		return

	var key := "custom_template/%s" % ("debug" if is_debug else "release")
	config.set_value("%s.options" % target_section, key, template_path)

	err = config.save(PRESETS_PATH)
	if err != OK:
		push_error("failed to save %s: %d" % [PRESETS_PATH, err])
		quit(1)
		return
	print("[set_preset_template] %s.options %s = %s" % [target_section, key, template_path])
	quit()
