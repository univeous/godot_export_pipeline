## Shared constants for the analyzer and the pruner — one definition, no
## drift between the two sides.
extends RefCounted

## Extension scripts loaded when the config has no "extensions" key.
const DEFAULT_EXTENSIONS := [
	"res://addons/export_pipeline/analyzer/ext/asset_registry.gd",
	"res://addons/export_pipeline/analyzer/ext/colored_folders.gd",
]
