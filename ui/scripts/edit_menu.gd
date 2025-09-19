extends CanvasLayer

# ─────────────────────────────────────────────────────────────────────────────
# Edit Overlay / Inspector
# - Builds a clone tree from the real stick hierarchy (branch_X/segment_Y)
# - Renames clones to base(N)_segment(M) by recursion depth
# - Generates colliders + inverted backface "thick outline" meshes
# - Keeps preview centered in a SubViewport following the player camera
# - Hover detection via ray → AABB slab test, outline toggling on hover
# - UI outliner (ColorRect) draws the post-process screen outline you made
# ─────────────────────────────────────────────────────────────────────────────

var stick: RigidBody3D = null
var stick_clone_root: Node3D = null
var pivot_clone_root: Node3D = null
var in_edit_mode := false

var player_camera: Camera3D = null
var _catcher: ColorRect = null

const LOCAL_HIDE_BIT := 18
const LOCAL_HIDE_MASK := 1 << LOCAL_HIDE_BIT
const CLONE_LAYER_BIT := 19
const CLONE_LAYER_MASK := 1 << CLONE_LAYER_BIT

var _saved_main_cam_mask: int = 0
var _saved_real_layers: Array = []

var pivot_distance: float = 2.0
var _fit_distance_base: float = 2.0
@export var view_up_bias: float = 0.0
var _preview_size: Vector3 = Vector3.ONE

const ORBIT_SENS := 0.01
const ZOOM_STEP := 1.1
const MIN_DIST := 0.15
const MAX_DIST := 50.0
var _orbit_drag := false
var _last_mouse_pos: Vector2

var _clone_pairs: Array = []	# [{original: MeshInstance3D, clone: MeshInstance3D}]

# Optional: keep a flat list of all clone MeshInstance3D for convenience
var _all_clone_meshes: Array = []

# Debug hooks (optional labels inside UI/Debug)
var debug_menu = null

# ─────────────────────────────
# Ready
# ─────────────────────────────
func _ready() -> void:
	var sv: SubViewport = $SubViewportContainer/SubViewport
	var outline_rect: ColorRect = $outliner
	var mat := outline_rect.material as ShaderMaterial
	if mat:
		mat.set_shader_parameter("screen_tex", sv.get_texture())
		mat.set_shader_parameter("screen_size", Vector2(sv.size))
	print("SV Texture: ", sv.get_texture())

	visible = false
	process_priority = 1000000
	process_mode = Node.PROCESS_MODE_ALWAYS

	_configure_subviewport()
	_resize_subviewport()
	get_viewport().size_changed.connect(_resize_subviewport)
	_ensure_dimmer_order()
	_create_input_catcher()

	var player = get_tree().current_scene.get_node_or_null("player")
	if player:
		player_camera = player.get_node("CollisionShape3D/Camera_Control/Camera3D") as Camera3D

	if get_tree().current_scene.has_node("UI/Debug"):
		debug_menu = get_tree().current_scene.get_node("UI/Debug")

# ─────────────────────────────
# SubViewport helpers
# ─────────────────────────────
func _configure_subviewport() -> void:
	var sv := $SubViewportContainer/SubViewport
	sv.disable_3d = false
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	sv.transparent_bg = true

	if not sv.has_node("EditCam3D"):
		var cam := Camera3D.new()
		cam.name = "EditCam3D"
		cam.current = true
		sv.add_child(cam)

	var screen_size := get_viewport().get_visible_rect().size
	sv.size = screen_size * 2

	var svc := $SubViewportContainer
	svc.set_anchors_preset(Control.PRESET_FULL_RECT)
	svc.stretch = true
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE

func _resize_subviewport() -> void:
	var sv := $SubViewportContainer/SubViewport
	var screen_size := get_viewport().get_visible_rect().size
	sv.size = screen_size * 2

func _ensure_dimmer_order() -> void:
	var svc := $SubViewportContainer
	if svc.has_node("ColorRect"):
		var cr := svc.get_node("ColorRect") as ColorRect
		svc.remove_child(cr)
		add_child(cr)
		cr.name = "ColorRect"
		cr.set_anchors_preset(Control.PRESET_FULL_RECT)
		cr.z_index = 0
	if has_node("ColorRect"):
		$ColorRect.z_index = 0
	svc.z_index = 100
	var p := svc.get_parent()
	if p:
		p.move_child(svc, p.get_child_count() - 1)

func _create_input_catcher() -> void:
	_catcher = ColorRect.new()
	_catcher.name = "InputCatcher"
	_catcher.color = Color(0, 0, 0, 0)
	_catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	_catcher.focus_mode = Control.FOCUS_ALL
	_catcher.set_anchors_preset(Control.PRESET_FULL_RECT)
	_catcher.z_index = 200
	add_child(_catcher)
	_catcher.gui_input.connect(_on_catcher_gui_input)
	_catcher.visible = false

# ─────────────────────────────
# Enter / Exit
# ─────────────────────────────
func enter_edit_mode(target: RigidBody3D) -> void:
	if not target or in_edit_mode:
		return
	in_edit_mode = true
	stick = target

	_saved_real_layers.clear()
	_set_real_meshes_local_hidden(true)

	_ensure_dimmer_order()
	_catcher.visible = true

	var cam: Camera3D = $SubViewportContainer/SubViewport/EditCam3D
	cam.current = true
	cam.visible = true
	if player_camera:
		cam.global_transform = player_camera.global_transform
		cam.fov = player_camera.fov
		cam.near = player_camera.near
		cam.far = player_camera.far
		cam.cull_mask = CLONE_LAYER_MASK

	_saved_main_cam_mask = player_camera.cull_mask
	player_camera.cull_mask = _saved_main_cam_mask & ~LOCAL_HIDE_MASK & ~CLONE_LAYER_MASK

	_build_center_preview(cam)

	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)

	var player := get_tree().current_scene.get_node("player")
	player.set_process_input(false)
	player.set_physics_process(false)
	player.set_process_unhandled_input(false)
	player.set_process(false)
	if player.has_method("set_ui_lock"):
		player.call_deferred("set_ui_lock", true)

func exit_edit_mode() -> void:
	if not in_edit_mode:
		return
	if is_instance_valid(pivot_clone_root):
		pivot_clone_root.queue_free()
	pivot_clone_root = null

	_set_real_meshes_local_hidden(false)
	if player_camera:
		player_camera.cull_mask = _saved_main_cam_mask

	var cam: Camera3D = $SubViewportContainer/SubViewport/EditCam3D
	cam.current = false
	cam.visible = false

	_catcher.visible = false
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)

	in_edit_mode = false
	stick = null
	_orbit_drag = false

	var player := get_tree().current_scene.get_node("player")
	player.set_process_input(true)
	player.set_physics_process(true)
	player.set_process_unhandled_input(true)
	player.set_process(true)
	if player.has_method("set_ui_lock"):
		player.call_deferred("set_ui_lock", false)

# ─────────────────────────────
# Input
# ─────────────────────────────
func _on_catcher_gui_input(event: InputEvent) -> void:
	if not in_edit_mode:
		return

	if event.is_action_pressed("ui_cancel"):
		exit_edit_mode()
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				_orbit_drag = mb.pressed
				_last_mouse_pos = mb.position
				Input.set_default_cursor_shape(Input.CURSOR_DRAG if _orbit_drag else Input.CURSOR_ARROW)
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_RIGHT:
				if mb.pressed:
					_reset_view()
					get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					pivot_distance = clamp(pivot_distance / ZOOM_STEP, MIN_DIST, MAX_DIST)
					get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					pivot_distance = clamp(pivot_distance * ZOOM_STEP, MIN_DIST, MAX_DIST)
					get_viewport().set_input_as_handled()

	if event is InputEventMouseMotion and _orbit_drag and is_instance_valid(pivot_clone_root):
		var mm := event as InputEventMouseMotion
		var yaw := mm.relative.x * ORBIT_SENS
		var pitch := mm.relative.y * ORBIT_SENS
		var b := pivot_clone_root.transform.basis
		b = Basis(Vector3.UP, yaw) * b
		b = Basis(b.x, pitch) * b
		pivot_clone_root.transform.basis = b.orthonormalized()
		get_viewport().set_input_as_handled()

# ─────────────────────────────
# Process
# ─────────────────────────────
func _process(delta: float) -> void:
	if not in_edit_mode:
		return

	if player_camera and is_instance_valid(pivot_clone_root):
		var cam: Camera3D = $SubViewportContainer/SubViewport/EditCam3D
		cam.global_transform = player_camera.global_transform
		cam.fov = player_camera.fov
		var forward := -cam.global_transform.basis.z
		var up := cam.global_transform.basis.y
		var target_pos := cam.global_transform.origin + forward * pivot_distance + up * (_preview_size.y * view_up_bias)
		var xf := pivot_clone_root.transform
		xf.origin = target_pos
		pivot_clone_root.transform = xf

		if Input.is_action_pressed("zoom_in"):
			pivot_distance = clamp(pivot_distance - delta * 2.0, MIN_DIST, MAX_DIST)
		if Input.is_action_pressed("zoom_out"):
			pivot_distance = clamp(pivot_distance + delta * 2.0, MIN_DIST, MAX_DIST)

	# Debug hover/highlight
	if debug_menu and debug_menu.visible:
		var hovered := _get_hovered_branch()
		_clear_all_highlights()
		if hovered:
			_set_highlight(hovered, true)
			debug_menu.branch_label.text = "Hovering over: %s" % hovered.name
		else:
			debug_menu.branch_label.text = "Not over branch"

		if is_instance_valid(pivot_clone_root):
			var count := 0
			for child in pivot_clone_root.get_node("ModelRot").get_children():
				if child is MeshInstance3D and child.has_meta("outline"):
					count += 1
			debug_menu.count_label.text = "Branch Count: %d" % count

# ─────────────────────────────
# Clone Tree (branch_X / segment_Y -> base(N)_segment(M))
# ─────────────────────────────

# Recursively clone one branch node. base_id increases with depth.
# seg_counter is a small dictionary used as a mutable integer: { "val": 0 }
func _clone_branch(branch_node: Node3D, base_id: int, clone_root: Node3D, seg_counter: Dictionary) -> void:
	if branch_node == null:
		return

	var local_segment_index := 0

	for child in branch_node.get_children():
		if typeof(child) != TYPE_OBJECT:
			continue

		# Match both Branch_X_Segment_Y and plain Segment_Y meshes
		if child is MeshInstance3D and (
			"segment" in child.name.to_lower() or "branch" in child.name.to_lower()
		):
			var orig := child as MeshInstance3D

			# Main visible clone
			var clone := MeshInstance3D.new()
			clone.mesh = orig.mesh
			clone.transform = orig.transform
			clone.layers = CLONE_LAYER_MASK
			var vis_mat := StandardMaterial3D.new()
			vis_mat.albedo_color = Color(1, 0, 0) # bright red for debug
			clone.material_override = vis_mat
			clone.name = "Base(%d)_Segment(%d)" % [base_id, local_segment_index]
			clone.set_meta("branch_name", orig.name)
			clone_root.add_child(clone)
			_all_clone_meshes.append(clone)
			_clone_pairs.append({ "original": orig, "clone": clone })

			print("CLONED:", clone.name, "from", orig.name)

			# Collider
			var collider := StaticBody3D.new()
			var shape := CollisionShape3D.new()
			shape.shape = orig.mesh.create_trimesh_shape()
			collider.add_child(shape)
			collider.name = "Collider_%d" % int(seg_counter.get("val", 0))
			collider.set_meta("branch_clone", clone)
			collider.collision_layer = CLONE_LAYER_MASK
			clone_root.add_child(collider)

			# Backface outline shell
			var outline := MeshInstance3D.new()
			outline.mesh = orig.mesh
			outline.visible = false
			outline.transform = orig.transform
			outline.scale = Vector3(1.15, 1.15, 1.15)
			var outline_mat := StandardMaterial3D.new()
			outline_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			outline_mat.albedo_color = Color(1, 1, 0)
			outline_mat.emission_enabled = true
			outline_mat.emission = Color(1, 1, 0)
			outline_mat.cull_mode = BaseMaterial3D.CULL_FRONT
			outline.material_override = outline_mat
			outline.name = "%s_outline" % clone.name
			clone_root.add_child(outline)
			clone.set_meta("outline", outline)

			local_segment_index += 1
			seg_counter["val"] = int(seg_counter.get("val", 0)) + 1





func _find_root_branch(real_stick: Node3D) -> Node3D:
	for child in real_stick.get_children():
		var n := child.name.to_lower()
		if n.begins_with("branch_0"):
			return child
	return null
	
# Build clone meshes by scanning ALL children of the stick
func _generate_clone_tree(real_stick: Node3D, clone_root: Node3D) -> void:
	_all_clone_meshes.clear()
	_clone_pairs.clear()

	if real_stick == null or clone_root == null:
		return

	var seg_counter := { "val": 0 }

	for child in real_stick.get_children():
		if child is MeshInstance3D:
			var n := child.name.to_lower()
			if "segment" in n and "branch" in n:
				_clone_segment(child, clone_root, seg_counter)


func _clone_segment(orig: MeshInstance3D, clone_root: Node3D, seg_counter: Dictionary) -> void:
	# Parse base/seg numbers from the name
	var base_id := 0
	var seg_id: int = int(seg_counter["val"])
	var parts := orig.name.split("_")
	if parts.size() >= 4 and parts[0].to_lower() == "branch" and parts[2].to_lower() == "segment":
		base_id = int(parts[1])
		seg_id = int(parts[3])

	# Visible clone
	var clone := MeshInstance3D.new()
	clone.mesh = orig.mesh
	clone.transform = orig.transform
	clone.layers = CLONE_LAYER_MASK
	var vis_mat := StandardMaterial3D.new()
	vis_mat.albedo_color = Color(1, 0, 0) # bright red debug
	clone.material_override = vis_mat
	clone.name = "Base(%d)_Segment(%d)" % [base_id, seg_id]
	clone.set_meta("branch_name", orig.name)
	clone_root.add_child(clone)
	_all_clone_meshes.append(clone)
	_clone_pairs.append({ "original": orig, "clone": clone })

	print("CLONED:", clone.name, "from", orig.name)

	# Collider
	if orig.mesh:
		var collider := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		shape.shape = orig.mesh.create_trimesh_shape()
		collider.add_child(shape)
		collider.name = "Collider_%d" % int(seg_counter["val"])
		collider.set_meta("branch_clone", clone)
		collider.collision_layer = CLONE_LAYER_MASK
		clone_root.add_child(collider)

	# Outline shell
	var outline := MeshInstance3D.new()
	outline.mesh = orig.mesh
	outline.visible = false
	outline.transform = orig.transform
	outline.scale = Vector3(1.15, 1.15, 1.15)
	var outline_mat := StandardMaterial3D.new()
	outline_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	outline_mat.albedo_color = Color(1, 1, 0)
	outline_mat.emission_enabled = true
	outline_mat.emission = Color(1, 1, 0)
	outline_mat.cull_mode = BaseMaterial3D.CULL_FRONT
	outline.material_override = outline_mat
	outline.name = "%s_outline" % clone.name
	clone_root.add_child(outline)
	clone.set_meta("outline", outline)

	seg_counter["val"] = int(seg_counter["val"]) + 1



# ─────────────────────────────
# Build / Center preview
# ─────────────────────────────
func _build_center_preview(cam: Camera3D) -> void:
	# Create pivot + container where all clones live
	pivot_clone_root = Node3D.new()
	pivot_clone_root.name = "PivotCloneRoot"
	$SubViewportContainer/SubViewport.add_child(pivot_clone_root)

	var model_rot := Node3D.new()
	model_rot.name = "ModelRot"
	pivot_clone_root.add_child(model_rot)

	# Fill it with clones
	_generate_clone_tree(stick, model_rot)

	# Center to origin and face camera
	model_rot.rotate_object_local(Vector3.FORWARD, -PI * 0.5)
	var center := _centroid_local(model_rot)
	model_rot.translate_object_local(-center)

	var forward := -cam.global_transform.basis.z
	if forward.length_squared() < 1e-6:
		forward = Vector3.FORWARD
	var right := Vector3.UP.cross(forward).normalized()
	pivot_clone_root.basis = Basis(right, Vector3.UP, -forward)

	# Fit distance
	var merged := _merged_local_aabb(model_rot)
	if merged.size == Vector3.ZERO:
		merged.size = Vector3.ONE
	_preview_size = merged.size
	var max_dim: float = max(merged.size.x, max(merged.size.y, merged.size.z))
	var fov_rad: float = deg_to_rad(cam.fov)
	var fit_dist: float = (max_dim * 0.5) / tan(fov_rad * 0.5)
	_fit_distance_base = fit_dist * 1.2
	pivot_distance = clamp(_fit_distance_base, MIN_DIST, MAX_DIST)

	var up := cam.global_transform.basis.y
	var target_pos := cam.global_transform.origin + (-cam.global_transform.basis.z) * pivot_distance + up * (_preview_size.y * view_up_bias)
	pivot_clone_root.transform = Transform3D(pivot_clone_root.basis, target_pos)

# ─────────────────────────────
# Hover detection (ray → AABB)
# ─────────────────────────────
func _get_hovered_branch() -> MeshInstance3D:
	if not is_instance_valid(pivot_clone_root):
		return null
	var cam: Camera3D = $SubViewportContainer/SubViewport/EditCam3D
	var sv: SubViewport = $SubViewportContainer/SubViewport
	var container: Control = $SubViewportContainer
	if not cam or not in_edit_mode:
		return null

	var mouse_pos: Vector2 = container.get_local_mouse_position()
	mouse_pos.x = clamp(mouse_pos.x, 0.0, float(sv.size.x - 1))
	mouse_pos.y = clamp(mouse_pos.y, 0.0, float(sv.size.y - 1))

	var from: Vector3 = cam.project_ray_origin(mouse_pos)
	var dir: Vector3 = cam.project_ray_normal(mouse_pos).normalized()

	var closest: MeshInstance3D = null
	var closest_dist := INF

	var model_rot := pivot_clone_root.get_node("ModelRot") as Node3D
	for child in model_rot.get_children():
		if child is MeshInstance3D and child.has_meta("outline"):
			var aabb := _aabb_transformed(child.get_aabb(), child.global_transform)

			var tmin := -INF
			var tmax := INF
			for i in 3:
				var o := from[i]
				var d := dir[i]
				var mn := aabb.position[i]
				var mx := aabb.position[i] + aabb.size[i]
				if abs(d) < 1e-6:
					if o < mn or o > mx:
						tmin = INF
						break
				else:
					var invd := 1.0 / d
					var t1 := (mn - o) * invd
					var t2 := (mx - o) * invd
					if t1 > t2:
						var tmp = t1; t1 = t2; t2 = tmp
					tmin = max(tmin, t1)
					tmax = min(tmax, t2)
					if tmin > tmax:
						tmin = INF
						break

			if tmin < INF and tmin > 0.0 and tmin < closest_dist:
				closest_dist = tmin
				closest = child as MeshInstance3D

	return closest

# ─────────────────────────────
# Highlight helpers
# ─────────────────────────────
func _set_highlight(mesh: MeshInstance3D, state: bool) -> void:
	if mesh and mesh.has_meta("outline"):
		var outline: MeshInstance3D = mesh.get_meta("outline")
		if outline:
			outline.visible = state

func _clear_all_highlights() -> void:
	if not is_instance_valid(pivot_clone_root):
		return
	var model_rot := pivot_clone_root.get_node("ModelRot") as Node3D
	for child in model_rot.get_children():
		if child is MeshInstance3D and child.has_meta("outline"):
			var outline: MeshInstance3D = child.get_meta("outline")
			if outline:
				outline.visible = false

# ─────────────────────────────
# Real mesh visibility (local hide)
# ─────────────────────────────
func _set_real_meshes_local_hidden(state: bool) -> void:
	if not is_instance_valid(stick):
		return
	for child in stick.get_children():
		if child is MeshInstance3D:
			var m := child as MeshInstance3D
			if state:
				_saved_real_layers.append({ "mesh": m, "layers": m.layers })
				m.layers = LOCAL_HIDE_MASK
			else:
				for entry in _saved_real_layers:
					if entry["mesh"] == m:
						m.layers = entry["layers"]
						break
	if not state:
		_saved_real_layers.clear()

# ─────────────────────────────
# View helpers
# ─────────────────────────────
func _reset_view() -> void:
	if not is_instance_valid(pivot_clone_root):
		return
	var cam: Camera3D = $SubViewportContainer/SubViewport/EditCam3D
	var forward := -cam.global_transform.basis.z
	if forward.length_squared() < 1e-6:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	var right := Vector3.UP.cross(forward).normalized()
	var flat := Basis(right, Vector3.UP, -forward)
	var up := cam.global_transform.basis.y
	var target_pos := cam.global_transform.origin + (-cam.global_transform.basis.z) * pivot_distance + up * (_preview_size.y * view_up_bias)
	pivot_clone_root.transform = Transform3D(flat, target_pos)
	pivot_distance = clamp(_fit_distance_base, MIN_DIST, MAX_DIST)
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)

# ─────────────────────────────
# Geometry
# ─────────────────────────────
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
	return acc / total_vol if total_vol > 0.0 else Vector3.ZERO

func _merged_local_aabb(root: Node3D) -> AABB:
	var first := true
	var acc := AABB()
	for child in root.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			var local_aabb := mi.get_aabb()
			var world_aabb := _aabb_transformed(local_aabb, mi.transform)
			if first:
				acc = world_aabb
				first = false
			else:
				acc = acc.merge(world_aabb)
	return acc

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

	var out := AABB(xform * p[0], Vector3.ZERO)
	for i in range(1, p.size()):
		out = out.expand(xform * p[i])
	return out
