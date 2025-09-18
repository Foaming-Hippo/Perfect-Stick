extends CanvasLayer

# ─────────────────────────────────────────────────────────────────────────────
# Transparent overlay “inspect” view.
# - Real stick stays visible to other players (hidden only from local camera).
# - A centered preview clone is spawned in front of the edit camera (fits view).
# - Pivot center uses volume-weighted centroid (better than AABB midpoint).
# ─────────────────────────────────────────────────────────────────────────────

var stick: RigidBody3D = null			# real stick (in hand)
var stick_clone_root: Node3D = null		# (reserved for future live overlay)
var pivot_clone_root: Node3D = null		# centered preview clone in SubViewport
var in_edit_mode := false

var player_camera: Camera3D = null
var _clone_pairs: Array = []			# (reserved)

# Visual layers (bits 0..19). 18 = hide-from-local, 19 = overlay/pivot clones
const LOCAL_HIDE_BIT := 18
const LOCAL_HIDE_MASK := 1 << LOCAL_HIDE_BIT
const CLONE_LAYER_BIT := 19
const CLONE_LAYER_MASK := 1 << CLONE_LAYER_BIT

# Saved state
var _saved_main_cam_mask: int = 0
var _saved_real_layers: Array = []		# items: { "mesh": MeshInstance3D, "layers": int }

# CENTER PREVIEW state
var pivot_distance: float = 2.0			# distance from camera to pivot center
var pivot_center_local: Vector3 = Vector3.ZERO

func _ready():
	visible = false
	_configure_subviewport()
	_resize_subviewport()
	get_viewport().size_changed.connect(_resize_subviewport)

	var player = get_tree().current_scene.get_node("player")
	if player:
		player_camera = player.get_node("CollisionShape3D/Camera_Control/Camera3D") as Camera3D


# ─────────────────────────────
# SubViewport: transparent, same world, full-res
# ─────────────────────────────
func _configure_subviewport():
	var sv := $SubViewportContainer/SubViewport
	sv.disable_3d = false
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	sv.transparent_bg = true

	$SubViewportContainer.set_anchors_preset(Control.PRESET_FULL_RECT)
	$SubViewportContainer.stretch = true

func _resize_subviewport():
	var size: Vector2i = get_viewport().size
	$SubViewportContainer/SubViewport.size = size


# ─────────────────────────────
# Enter / Exit Edit Mode
# ─────────────────────────────
func enter_edit_mode(target: RigidBody3D):
	if not target or in_edit_mode:
		return
	in_edit_mode = true
	stick = target

	# Hide ONLY from local camera via layer bit (others still see it)
	_saved_real_layers.clear()
	_set_real_meshes_local_hidden(true)

	# Hide the ColorRect so the clone isn't covered
	if $SubViewportContainer.has_node("ColorRect"):
		$SubViewportContainer/ColorRect.visible = false

	# EDIT CAM mirrors player cam and renders only clones
	var cam: Camera3D = $SubViewportContainer/SubViewport/EditCam3D
	cam.current = true
	cam.visible = true
	if player_camera:
		cam.global_transform = player_camera.global_transform
		cam.fov = player_camera.fov
		cam.near = player_camera.near
		cam.far = player_camera.far
	cam.cull_mask = CLONE_LAYER_MASK

	# Local player camera: hide LOCAL_HIDE + CLONE layers
	_saved_main_cam_mask = player_camera.cull_mask
	player_camera.cull_mask = _saved_main_cam_mask & ~LOCAL_HIDE_MASK & ~CLONE_LAYER_MASK

	# CENTER PREVIEW: build & center a duplicate in front of the edit camera
	_build_center_preview(cam)

	# UI/mouse & pause behavior
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	var player := get_tree().current_scene.get_node("player")
	player.set_process_input(false)
	player.set_physics_process(false)

func exit_edit_mode():
	if not in_edit_mode:
		return

	# Remove center preview
	if is_instance_valid(pivot_clone_root):
		pivot_clone_root.queue_free()
	pivot_clone_root = null

	# Remove (future) overlay clone if present
	if is_instance_valid(stick_clone_root):
		stick_clone_root.queue_free()
	stick_clone_root = null
	_clone_pairs.clear()

	# Restore real meshes and camera masks
	_set_real_meshes_local_hidden(false)
	if player_camera:
		player_camera.cull_mask = _saved_main_cam_mask

	# Turn ColorRect back on (if you use it)
	if $SubViewportContainer.has_node("ColorRect"):
		$SubViewportContainer/ColorRect.visible = true

	# Turn off edit cam
	var cam: Camera3D = $SubViewportContainer/SubViewport/EditCam3D
	cam.current = false
	cam.visible = false

	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	in_edit_mode = false
	stick = null

	var player := get_tree().current_scene.get_node("player")
	player.set_process_input(true)
	player.set_physics_process(true)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and in_edit_mode:
		exit_edit_mode()


# ─────────────────────────────
# Live sync camera & keep pivot centered
# ─────────────────────────────
func _process(_delta: float) -> void:
	if not in_edit_mode:
		return

	# Keep edit cam matched to player cam (so background matches perfectly)
	if player_camera:
		var cam: Camera3D = $SubViewportContainer/SubViewport/EditCam3D
		cam.global_transform = player_camera.global_transform
		cam.fov = player_camera.fov
		# Keep pivot clone centered in front of the camera at pivot_distance
		if is_instance_valid(pivot_clone_root):
			var forward := -cam.global_transform.basis.z
			var target_pos := cam.global_transform.origin + forward * pivot_distance
			var xf := pivot_clone_root.global_transform
			xf.origin = target_pos
			pivot_clone_root.global_transform = xf


# ─────────────────────────────
# Helpers
# ─────────────────────────────

# Move real stick meshes to LOCAL_HIDE layer (so only your camera ignores them)
func _set_real_meshes_local_hidden(state: bool) -> void:
	if not is_instance_valid(stick):
		return
	for child in stick.get_children():
		if child is MeshInstance3D:
			var m := child as MeshInstance3D
			if state:
				# save current layers then move mesh to LOCAL_HIDE only
				_saved_real_layers.append({ "mesh": m, "layers": m.layers })
				m.layers = LOCAL_HIDE_MASK
			else:
				# restore original layers
				for entry in _saved_real_layers:
					if entry["mesh"] == m:
						m.layers = entry["layers"]
						break
	if not state:
		_saved_real_layers.clear()

# ───── CENTER PREVIEW: build a centered, camera-space clone ─────
func _build_center_preview(cam: Camera3D):
	# Build root under SubViewport
	pivot_clone_root = Node3D.new()
	pivot_clone_root.name = "PivotCloneRoot"
	$SubViewportContainer/SubViewport.add_child(pivot_clone_root)

	# Clone only base meshes (skip yellow outlines)
	var clones: Array[MeshInstance3D] = []
	for child in stick.get_children():
		if child is MeshInstance3D and child.has_meta("outline"):
			var orig := child as MeshInstance3D
			var clone := MeshInstance3D.new()
			clone.mesh = orig.mesh
			clone.material_override = orig.material_override
			clone.transform = orig.transform	# start with same local
			clone.layers = CLONE_LAYER_MASK
			pivot_clone_root.add_child(clone)
			clones.append(clone)

	# Compute merged AABB in pivot_root local space (for sizing)
	var merged: AABB = _merged_local_aabb(pivot_clone_root)
	if merged.size == Vector3.ZERO:
		merged.size = Vector3.ONE

	# Use volume-weighted centroid as pivot center (more natural than midpoint)
	var center: Vector3 = _centroid_local(pivot_clone_root)
	pivot_center_local = center
	pivot_clone_root.translate_object_local(-center)

	# Compute a comfy camera distance to fit it in view (vertical FOV)
	var max_dim: float = max(merged.size.x, max(merged.size.y, merged.size.z))
	var fov_rad: float = deg_to_rad(cam.fov)
	var fit_dist: float = (max_dim * 0.5) / tan(fov_rad * 0.5)
	pivot_distance = fit_dist * 1.2	# margin

	# Place root in front of the camera by pivot_distance
	var forward := -cam.global_transform.basis.z
	var target_pos := cam.global_transform.origin + forward * pivot_distance
	var xf := Transform3D(Basis(), target_pos)
	pivot_clone_root.global_transform = xf

# Merge all MeshInstance3D AABBs in the given node's local space
func _merged_local_aabb(root: Node3D) -> AABB:
	var first := true
	var acc := AABB()
	for child in root.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			var local_aabb := mi.get_aabb()
			var world_aabb := _aabb_transformed(local_aabb, mi.transform) # child local -> root local
			if first:
				acc = world_aabb
				first = false
			else:
				acc = acc.merge(world_aabb)
	return acc

# Volume-weighted centroid of all child mesh AABBs in root local space
func _centroid_local(root: Node3D) -> Vector3:
	var total_vol: float = 0.0
	var acc: Vector3 = Vector3.ZERO
	for child in root.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			var aabb_local: AABB = _aabb_transformed(mi.get_aabb(), mi.transform)
			var vol: float = aabb_local.size.x * aabb_local.size.y * aabb_local.size.z
			if vol <= 0.0:
				continue
			var c: Vector3 = aabb_local.position + aabb_local.size * 0.5
			acc += c * vol
			total_vol += vol
	if total_vol <= 0.0:
		return Vector3.ZERO
	return acc / total_vol

# Transform an AABB by a Transform3D (approx via 8 points)
func _aabb_transformed(aabb: AABB, xform: Transform3D) -> AABB:
	var p := [
		aabb.position,
		aabb.position + Vector3(aabb.size.x, 0, 0),
		aabb.position + Vector3(0, aabb.size.y, 0),
		aabb.position + Vector3(0, 0, aabb.size.z),
		aabb.position + Vector3(aabb.size.x, aabb.size.y, 0),
		aabb.position + Vector3(aabb.size.x, 0, aabb.size.z),
		aabb.position + Vector3(0, aabb.size.y, aabb.size.z),
		aabb.position + aabb.size
	]
	var a := AABB(xform * p[0], Vector3.ZERO)
	for i in range(1, p.size()):
		a = a.expand(xform * p[i])
	return a
