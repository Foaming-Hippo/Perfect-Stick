extends CanvasLayer

var stick: RigidBody3D = null          # real stick (in hand)
var stick_clone: Node3D = null         # preview clone (in SubViewport)
var in_edit_mode := false

var player_camera: Camera3D = null

func _ready():
	visible = false
	_resize_subviewport()
	get_viewport().size_changed.connect(_resize_subviewport)

	# auto-resolve the camera at runtime
	var player = get_tree().current_scene.get_node("player")
	if player:
		player_camera = player.get_node("CollisionShape3D/Camera_Control/Camera3D") as Camera3D

# ─────────────────────────────
# Keep SubViewport resolution in sync with window
# ─────────────────────────────
func _resize_subviewport():
	var screen_size: Vector2i = get_viewport().size
	$SubViewportContainer/SubViewport.size = screen_size
	$SubViewportContainer.set_anchors_preset(Control.PRESET_FULL_RECT)

# ─────────────────────────────
# Enter / Exit Edit Mode
# ─────────────────────────────
func enter_edit_mode(target: RigidBody3D):
	if not target or in_edit_mode:
		return
	in_edit_mode = true
	stick = target

	# Hide + freeze real stick
	stick.visible = false
	stick.freeze = true
	stick.gravity_scale = 0
	stick.linear_velocity = Vector3.ZERO
	stick.angular_velocity = Vector3.ZERO

	# Find HandSocket (adjust path if needed)
	var hand_socket: Node3D = get_tree().current_scene.get_node("player/CollisionShape3D/Camera_Control/Camera3D/HandSocket")

	# Clone stick using its local offset
	stick_clone = _clone_stick(stick, hand_socket)
	$SubViewportContainer/SubViewport.add_child(stick_clone)

	# Show overlay, free mouse
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Disable player controls
	var player := get_tree().current_scene.get_node("player")
	player.set_process_input(false)
	player.set_physics_process(false)

func exit_edit_mode():
	if not in_edit_mode:
		return

	# Remove clone
	if stick_clone and stick_clone.get_parent():
		stick_clone.queue_free()
	stick_clone = null

	# Show real stick again
	if stick:
		stick.visible = true

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
# Update Edit Camera (sync with player cam)
# ─────────────────────────────
func _process(_delta: float) -> void:
	if in_edit_mode and player_camera and stick_clone:
		var cam: Camera3D = $SubViewportContainer/SubViewport/EditCam3D
		cam.global_transform = player_camera.global_transform
		cam.fov = player_camera.fov

# ─────────────────────────────
# Clone Stick (Mesh-only preview)
# ─────────────────────────────
func _clone_stick(original: RigidBody3D, hand_socket: Node3D) -> Node3D:
	var clone_root := Node3D.new()

	# Convert global transform of stick into local space of the hand socket
	clone_root.transform = hand_socket.global_transform.affine_inverse() * original.global_transform

	for child in original.get_children():
		if child is MeshInstance3D:
			var clone_mesh := MeshInstance3D.new()
			clone_mesh.mesh = child.mesh
			clone_mesh.material_override = child.material_override
			clone_mesh.transform = child.transform
			clone_root.add_child(clone_mesh)

	return clone_root
