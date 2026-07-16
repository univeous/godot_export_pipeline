## Analyzer extension: tileset tree-shaking.
##
## TileSet resources under the configured prefixes (analyzer config key
## "tileset_tree_shake_dirs") are claimed: instead of exporting every atlas
## texture the TileSet references, only the textures of atlas sources
## actually painted in used scenes (TileMapLayer tile_map_data) are kept.
##
## The dead-source list lands in the report under extensions.tileset_tree_shake
## and drives this extension's own pruner-side hooks (bottom of this file),
## which strip those sources from the exported TileSet via resource
## customization so it never references pruned textures.
##
## Fail-open rules:
##  - a claimed tileset referenced by used files but with NO painted cells
##    anywhere keeps all its sources (it may be driven from code);
##  - unrecognized source types (not atlas / scenes-collection) keep the
##    tileset unshaken.
extends RefCounted

const CONFIG_KEY := "tileset_tree_shake_dirs"
## Optional safety valve: {"res://path.res": [source ids to keep]} or
## {"res://path.res": "all"} for sources used from code at runtime.
const KEEP_KEY := "tileset_tree_shake_keep"

var _dirs: Array = []
var _keep := {}
var _claimed := {}        # tileset path -> true
var _used_sources := {}   # tileset path -> {source_id: evidence string}
var _scanned_scenes := {}
var _marked := {}         # asset paths this extension already marked
var _source_assets := {}  # tileset path -> {source_id: Array[String] asset paths}
var _unshakeable := {}    # tileset path -> reason

var _re_ts_ext := RegEx.create_from_string("\\[ext_resource type=\"TileSet\"[^\\]]*?path=\"([^\"]+)\"[^\\]]*?id=\"([^\"]+)\"")
var _re_cell_data := RegEx.create_from_string("tile_map_data = PackedByteArray\\(\"([^\"]*)\"\\)")
var _re_tile_set := RegEx.create_from_string("tile_set = ExtResource\\(\"([^\"]+)\"\\)")


func extension_name() -> String:
	return "tileset_tree_shake"


func setup(analyzer) -> void:
	_dirs = analyzer.get_config(CONFIG_KEY, [])
	_keep = analyzer.get_config(KEEP_KEY, {})


func claim_file(path: String) -> bool:
	if not path.get_extension().to_lower() in ["res", "tres"]:
		return false
	for d in _dirs:
		if path.begins_with(String(d)):
			_claimed[path] = true
			return true
	return false


func finalize(analyzer) -> bool:
	if _claimed.is_empty():
		return false
	var changed := false
	for file in analyzer.used_files():
		if file.ends_with(".tscn") and not _scanned_scenes.has(file):
			_scanned_scenes[file] = true
			if _scan_scene(file):
				changed = true
	for ts_path in _claimed:
		if analyzer.is_used(ts_path):
			if _mark_used_sources(analyzer, ts_path):
				changed = true
	return changed


## Collects painted source ids per claimed tileset from a scene's
## TileMapLayer nodes. Returns true if new source ids were recorded.
func _scan_scene(scene_path: String) -> bool:
	var text := FileAccess.get_file_as_string(scene_path)
	var ext_ids := {}  # ExtResource id -> claimed tileset path
	for m in _re_ts_ext.search_all(text):
		if _claimed.has(m.get_string(1)):
			ext_ids[m.get_string(2)] = m.get_string(1)
	if ext_ids.is_empty():
		return false

	var changed := false
	# Node blocks: everything between [node ...] headers.
	for block in text.split("\n[node"):
		var tsm := _re_tile_set.search(block)
		if tsm == null or not ext_ids.has(tsm.get_string(1)):
			continue
		var ts_path: String = ext_ids[tsm.get_string(1)]
		var cdm := _re_cell_data.search(block)
		if cdm == null:
			continue
		if not _used_sources.has(ts_path):
			_used_sources[ts_path] = {}
		for sid in _parse_cell_sources(cdm.get_string(1)):
			if not _used_sources[ts_path].has(sid):
				_used_sources[ts_path][sid] = scene_path
				changed = true
	return changed


## tile_map_data format: 2-byte header, then 12 bytes per cell
## (x:s16, y:s16, source_id:u16, atlas_x:u16, atlas_y:u16, alternative:u16).
func _parse_cell_sources(b64: String) -> Array[int]:
	var out: Array[int] = []
	var bytes := Marshalls.base64_to_raw(b64)
	var i := 2
	while i + 12 <= bytes.size():
		var sid := bytes[i + 4] | (bytes[i + 5] << 8)
		if not sid in out:
			out.append(sid)
		i += 12
	return out


## Marks assets behind used sources of one tileset. Returns true if new
## assets were marked.
func _mark_used_sources(analyzer, ts_path: String) -> bool:
	if not _source_assets.has(ts_path):
		_load_source_assets(analyzer, ts_path)
		var keep = _keep.get(ts_path)
		if keep is String and keep == "all":
			_unshakeable[ts_path] = "kept by config"
		elif keep is Array:
			if not _used_sources.has(ts_path):
				_used_sources[ts_path] = {}
			for sid in keep:
				_used_sources[ts_path][int(sid)] = "<config keep>"
	if _unshakeable.has(ts_path):
		var all_changed := false
		for sid in _source_assets[ts_path]:
			if _mark_assets(analyzer, _source_assets[ts_path][sid], "%s (unshaken)" % ts_path):
				all_changed = true
		return all_changed

	var used: Dictionary = _used_sources.get(ts_path, {})
	if used.is_empty():
		# Referenced but never painted — likely driven from code; keep whole.
		analyzer.warn("tileset_tree_shake: %s is referenced but no painted cells were found in any used scene — keeping all %d sources (fail-open)." % [ts_path, _source_assets[ts_path].size()])
		_unshakeable[ts_path] = "no painted cells"
		var changed := false
		for sid in _source_assets[ts_path]:
			if _mark_assets(analyzer, _source_assets[ts_path][sid], "%s (unshaken)" % ts_path):
				changed = true
		return changed

	var changed := false
	for sid in used:
		if _source_assets[ts_path].has(sid):
			if _mark_assets(analyzer, _source_assets[ts_path][sid], "%s source %d (painted in %s)" % [ts_path, sid, used[sid]]):
				changed = true
	return changed


func _mark_assets(analyzer, assets: Array, referrer: String) -> bool:
	var changed := false
	for asset in assets:
		if not _marked.has(asset):
			_marked[asset] = true
			analyzer.mark_used(asset, "<tileset_tree_shake %s>" % referrer)
			changed = true
	return changed


func _load_source_assets(analyzer, ts_path: String) -> void:
	_source_assets[ts_path] = {}
	var ts := ResourceLoader.load(ts_path) as TileSet
	if ts == null:
		analyzer.warn("tileset_tree_shake: %s is not a TileSet — left unshaken." % ts_path)
		_unshakeable[ts_path] = "not a TileSet"
		return
	for i in ts.get_source_count():
		var sid := ts.get_source_id(i)
		var source := ts.get_source(sid)
		var assets: Array[String] = []
		if source is TileSetAtlasSource:
			var tex: Texture2D = source.texture
			if tex and tex.resource_path.begins_with("res://") and not "::" in tex.resource_path:
				assets.append(tex.resource_path)
		elif source is TileSetScenesCollectionSource:
			for j in source.get_scene_tiles_count():
				var scene: PackedScene = source.get_scene_tile_scene(source.get_scene_tile_id(j))
				if scene and scene.resource_path.begins_with("res://"):
					assets.append(scene.resource_path)
		else:
			analyzer.warn("tileset_tree_shake: %s has unrecognized source type %s (id %d) — left unshaken." % [ts_path, source.get_class() if source else "<null>", sid])
			_unshakeable[ts_path] = "unrecognized source type"
		_source_assets[ts_path][sid] = assets


func report(analyzer) -> Dictionary:
	var tilesets := {}
	var total_dead := 0
	for ts_path in _claimed:
		if not analyzer.is_used(ts_path) or not _source_assets.has(ts_path):
			continue
		if _unshakeable.has(ts_path):
			tilesets[ts_path] = {"unshaken": _unshakeable[ts_path], "total_sources": _source_assets[ts_path].size()}
			continue
		var used: Dictionary = _used_sources.get(ts_path, {})
		var dead: Array[int] = []
		for sid in _source_assets[ts_path]:
			if not used.has(sid):
				dead.append(sid)
		dead.sort()
		total_dead += dead.size()
		tilesets[ts_path] = {
			"total_sources": _source_assets[ts_path].size(),
			"used_sources": used.keys(),
			"dead_sources": dead,
		}
	return {
		"summary": "%d tileset(s) analyzed, %d dead source(s) total" % [tilesets.size(), total_dead],
		"tilesets": tilesets,
	}


# ── pruner-side hooks: strip dead sources from exported TileSets ───────────

var _shake := {}  # tileset path -> Array of dead source ids


func export_begin(_pruner, report: Dictionary, _config: Dictionary, _is_debug: bool) -> void:
	_shake.clear()
	var tilesets: Dictionary = report.get("extensions", {}).get("tileset_tree_shake", {}).get("tilesets", {})
	for ts_path in tilesets:
		var entry: Dictionary = tilesets[ts_path]
		if entry.has("unshaken"):
			continue
		var dead: Array = entry.get("dead_sources", [])
		if not dead.is_empty():
			_shake[ts_path] = dead


func wants_customization() -> bool:
	return not _shake.is_empty()


func customization_hash() -> int:
	return hash(JSON.stringify(_shake))


func customize_resource(resource: Resource, path: String) -> Resource:
	if not _shake.has(path) or not resource is TileSet:
		return null
	# Work on a copy: the passed-in resource may be the editor's cached
	# instance when exporting from a running editor.
	var shaken: TileSet = resource.duplicate()
	var removed := 0
	for sid in _shake[path]:
		if shaken.has_source(int(sid)):
			shaken.remove_source(int(sid))
			removed += 1
	print("[tileset_tree_shake] %s: removed %d dead sources (%d kept)." % [path, removed, shaken.get_source_count()])
	return shaken
