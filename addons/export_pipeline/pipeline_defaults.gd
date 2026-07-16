## Shared constants for the analyzer and the pruner — one definition, no
## drift between the two sides.
extends RefCounted

## Extension scripts loaded when the config has no "extensions" key.
const DEFAULT_EXTENSIONS := [
	"res://addons/export_pipeline/analyzer/ext/asset_registry.gd",
	"res://addons/export_pipeline/analyzer/ext/colored_folders.gd",
]

## Genuine navigation references by dimension ("2d"/"3d"). Deliberately NOT
## keyed off the servers: NavigationServer2D/3D sit in build_profile_gen's
## ESSENTIALS, and its API closure drags in classes like NavigationPolygon
## through mere method signatures (TileData.get_navigation_polygon), so the
## kept set cannot distinguish real use. These classes only appear when a
## project actually does navigation.
const NAV_CLASSES := {
	"NavigationAgent2D": "2d", "NavigationRegion2D": "2d", "NavigationLink2D": "2d",
	"NavigationObstacle2D": "2d", "NavigationPolygon": "2d",
	"NavigationPathQueryParameters2D": "2d", "NavigationPathQueryResult2D": "2d",
	"NavigationMeshSourceGeometryData2D": "2d",
	"NavigationAgent3D": "3d", "NavigationRegion3D": "3d", "NavigationLink3D": "3d",
	"NavigationObstacle3D": "3d", "NavigationMesh": "3d",
	"NavigationPathQueryParameters3D": "3d", "NavigationPathQueryResult3D": "3d",
	"NavigationMeshSourceGeometryData3D": "3d",
}

## Classes that exist only when advanced GUI is compiled in
## (scene/register_scene_types.cpp, #ifndef ADVANCED_GUI_DISABLED, as of 4.7).
const ADVANCED_GUI_CLASSES := [
	"AcceptDialog", "ConfirmationDialog", "FileDialog", "PopupMenu",
	"Tree", "TreeItem", "TextEdit", "CodeEdit", "SyntaxHighlighter",
	"CodeHighlighter", "MenuBar", "MenuButton", "OptionButton", "SpinBox",
	"ColorPicker", "ColorPickerButton", "RichTextLabel", "RichTextEffect",
	"CharFXTransform", "SubViewportContainer", "SplitContainer",
	"HSplitContainer", "VSplitContainer", "GraphElement", "GraphNode",
	"GraphFrame", "GraphEdit", "FoldableGroup", "FoldableContainer",
	"VirtualJoystick",
]

## Scene-side physics users that are not CollisionObject descendants but
## still talk to the physics servers (raycast/shapecast nodes cast queries,
## SoftBody3D is a MeshInstance3D, SpringArm3D shape-casts every frame).
const PHYSICS_2D_NODE_ROOTS := ["CollisionObject2D", "Joint2D", "RayCast2D", "ShapeCast2D"]
const PHYSICS_3D_NODE_ROOTS := ["CollisionObject3D", "Joint3D", "RayCast3D", "ShapeCast3D",
	"SpringArm3D", "SoftBody3D", "VehicleWheel3D"]


## "disabled_build_options" entries that would compile class c out of the
## engine — used by build_profile_gen to turn class evidence into subsystem
## evidence, and by export_pruner's stale-profile guard to catch content
## that started using a subsystem after the profile was generated.
static func class_disable_conflicts(c: String) -> PackedStringArray:
	var opts := PackedStringArray()
	if NAV_CLASSES.has(c):
		opts.append("disable_navigation_%s" % NAV_CLASSES[c])
	for adv in ADVANCED_GUI_CLASSES:
		if ClassDB.is_parent_class(c, adv):
			opts.append("disable_advanced_gui")
			break
	# Query/space-state classes (Physics*QueryParameters*, PhysicsDirectSpaceState*,
	# plus textual PhysicsServer references) are RefCounted, not CollisionObject
	# descendants — a raycast-query-only project uses physics with zero
	# collision nodes, so the name pattern must count as evidence too.
	var phys_2d := c.begins_with("Physics") and c.ends_with("2D")
	var phys_3d := c.begins_with("Physics") and c.ends_with("3D")
	for root in PHYSICS_2D_NODE_ROOTS:
		phys_2d = phys_2d or ClassDB.is_parent_class(c, root)
	for root in PHYSICS_3D_NODE_ROOTS:
		phys_3d = phys_3d or ClassDB.is_parent_class(c, root)
	if phys_2d:
		opts.append("disable_physics_2d")
	if phys_3d:
		opts.append("disable_physics_3d")
	if ClassDB.is_parent_class(c, "Node3D") or ClassDB.is_parent_class(c, "VisualInstance3D"):
		opts.append("disable_3d")
	return opts
