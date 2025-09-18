extends CanvasLayer

# ─────────────────────────────────────────────────────────────────────────────
# Transparent overlay “inspect” view that shows a clone of the held stick.
# Other players still see the real stick (we hide it ONLY from the local camera
# using a visual layer bit). The edit camera renders only the clone layer.
# ─────────────────────────────────────────────────────────────────────────────

var stick: RigidBody3D = null          # real stick (in hand)
var stick_clone_root: Node3D = null    # parent for preview meshes inside SubViewport
var in_edit_mode := false

var player_camera: Camera3D = null

# Clone <-> real mesh mapping for live sync
var _clone_pairs: Array = []	# items: { "orig": MeshInstance3D, "clone": MeshInstance3D }

# Visual layers (bits 0..19). We'll use 18 for "hide from local", 19 for "clone"
const LOCAL_HIDE_BIT := 18
const LOCAL_HIDE_MASK := 1 << LOCAL_HIDE_BIT
const CLONE_LAYER_BIT := 19
const CLONE_LAYER_MASK := 1 << CLONE_LAYER_BIT

# Saved state to restore on exit
var _saved_main_cam_mask: int = 0
var _saved_real_layers: Array = []	# items: { "mesh": MeshInstance3D, "layers": int }

func _ready():
	visible = false
	_configure_subviewport()
	_resize_subviewport()
	get_viewport().size_changed.connect(_resize_subviewport)

	# Resolve the player camera once
	var player = get_tree().current_scene.get_node("player")
	if player:
		player_camera = player.get_node("CollisionShape3D/Camera_Control/Camera3D") as Camera3D


# ─────────────────────────────
# SubViewport: transparent, same world, full-res
# ─────────────────────────────
func _configure_subviewport():
	var sv := $SubViewportContainer/SubViewport
	# Same 3D world as the game (no world_3d assignment) so background shows through.
	sv.disable_3d = false
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	sv.transparent_bg = true

	# Fill screen
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

	# IMPORTANT: We do NOT set stick.visible = false. Other players still need to see it.
	# We also don't touch physics here (your held logic already manages freeze/gravity).

	# Hide ONLY from *local* camera by moving the real meshes to LOCAL_HIDE layer
	_saved_real_layers.clear()
	_set_real_meshes_local_hidden(true)

	# Build clone meshes on a dedicated CLONE layer rendered only by the EditCam
	_build_clone_meshes()

	# Configure the edit camera to mirror player camera and render only clones
	var cam: Camera3D = $SubViewportContainer/SubViewport/EditCam3D
	cam.current = true
	cam.visible = true
	if player_camera:
		cam.global_transform = player_camera.global_transform
		cam.fov = player_camera.fov
		cam.near = player_camera.near
		cam.far = player_camera.far
	cam.cull_mask = CLONE_LAYER_MASK

	# Exclude LOCAL_HIDE + CLONE from the player camera so you only see the overlay clone
	_saved_main_cam_mask = player_camera.cull_mask
	player_camera.cull_mask = _saved_main_cam_mask & ~LOCAL_HIDE_MASK & ~CLONE_LAYER_MASK

	# Show overlay, free mouse
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Disable player controls locally (others still see you with your real stick)
	var player := get_tree().current_scene.get_node("player")
	player.set_process_input(false)
	player.set_physics_process(false)

func exit_edit_mode():
	if not in_edit_mode:
		return

	# Remove clone meshes
	if is_instance_valid(stick_clone_root):
		stick_clone_root.queue_free()
	stick_clone_root = null
	_clone_pairs.clear()

	# Restore real meshes' visual layers
	_set_real_meshes_local_hidden(false)

	# Restore player camera cull mask
	if player_camera:
		player_camera.cull_mask = _saved_main_cam_mask

	# Turn off edit cam
	var cam: Camera3D = $SubViewportContainer/SubViewport/EditCam3D
	cam.current = false
	cam.visible = false

	# Hide overlay, recapture mouse
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	in_edit_mode = false
	stick = null

	# Re-enable player controls
	var player := get_tree().current_scene.get_node("player")
	player.set_process_input(true)
	player.set_physics_process(true)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and in_edit_mode:
		exit_edit_mode()


# ─────────────────────────────
# Live sync (camera + meshes)
# ─────────────────────────────
func _process(_delta: float) -> void:
	if not in_edit_mode:
		return

	# Keep edit cam aligned with player cam
	if player_camera:
		var cam: Camera3D = $SubViewportContainer/SubViewport/EditCam3D
		cam.global_transform = player_camera.global_transform
		cam.fov = player_camera.fov

	# Sync each clone's global transform from its original
	for pair in _clone_pairs:
		var orig := pair["orig"] as MeshInstance3D
		var clone := pair["clone"] as MeshInstance3D
		if is_instance_valid(orig) and is_instance_valid(clone):
			clone.global_transform = orig.global_transform


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
				# save once
				_saved_real_layers.append({ "mesh": m, "layers": m.layers })
				m.layers = m.layers | LOCAL_HIDE_MASK
			else:
				# restore
				for entry in _saved_real_layers:
					if entry["mesh"] == m:
						m.layers = entry["layers"]
						break
	if not state:
		_saved_real_layers.clear()

# Build clone meshes on CLONE layer; skip outline meshes (we only want the base geometry)
func _build_clone_meshes():
	_clone_pairs.clear()

	stick_clone_root = Node3D.new()
	stick_clone_root.name = "StickCloneRoot"
	$SubViewportContainer/SubViewport.add_child(stick_clone_root)

	for child in stick.get_children():
		if child is MeshInstance3D and child.has_meta("outline"):
			var orig_mesh := child as MeshInstance3D
			var clone_mesh := MeshInstance3D.new()
			clone_mesh.mesh = orig_mesh.mesh
			clone_mesh.material_override = orig_mesh.material_override
			clone_mesh.global_transform = orig_mesh.global_transform
			clone_mesh.layers = CLONE_LAYER_MASK
			stick_clone_root.add_child(clone_mesh)
			_clone_pairs.append({ "orig": orig_mesh, "clone": clone_mesh })
