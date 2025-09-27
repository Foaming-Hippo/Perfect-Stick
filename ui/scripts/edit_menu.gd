extends CanvasLayer

# ─────────────────────────────────────────────────────────────────────────────
# Transparent overlay “inspect” view.
# - Pivot = chosen branch (default: center).
# - Left-drag = rotate (yaw locked to world UP).
# - Wheel/Q/E = zoom, Right-click = reset.
# - Hover system: raycast against clone colliders.
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

# Debug hooks
var debug_menu = null

# ─────────────────────────────
# Ready
# ─────────────────────────────
func _ready():
	var sv: SubViewport = $SubViewportContainer/SubViewport
	var outline_rect: ColorRect = $outliner
	var mat := outline_rect.material as ShaderMaterial

	if mat:
		mat.set_shader_parameter("screen_tex", sv.get_texture())
		mat.set_shader_parameter("screen_size", Vector2(sv.size))
		mat.set_shader_parameter("enabled", 0.0)

	visible = false
	process_priority = 1000000
	process_mode = Node.PROCESS_MODE_ALWAYS

	_configure_subviewport()
	_resize_subviewport()
	get_viewport().size_changed.connect(_resize_subviewport)
	_ensure_dimmer_order()
	_create_input_catcher()

	var player = get_tree().current_scene.get_node("player")
	if player:
		player_camera = player.get_node("CollisionShape3D/Camera_Control/Camera3D") as Camera3D

	if get_tree().current_scene.has_node("UI/Debug"):
		debug_menu = get_tree().current_scene.get_node("UI/Debug")

# ─────────────────────────────
# SubViewport helpers
# ─────────────────────────────
func _configure_subviewport() -> void:
	var sv = $SubViewportContainer/SubViewport
	sv.disable_3d = false
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	sv.transparent_bg = true

	if not sv.has_node("EditCam3D"):
		var cam = Camera3D.new()
		cam.name = "EditCam3D"
		cam.current = true
		sv.add_child(cam)

	var svc = $SubViewportContainer
	svc.set_anchors_preset(Control.PRESET_FULL_RECT)
	svc.stretch = true   # ✅ let container manage size
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _resize_subviewport() -> void:
	# No need to set sv.size anymore since stretch handles it
	var svc = $SubViewportContainer
	svc.set_anchors_preset(Control.PRESET_FULL_RECT)

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

func _create_input_catcher():
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
func enter_edit_mode(target: RigidBody3D):
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

func exit_edit_mode():
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
		var target_pos := cam.global_transform.origin \
			+ forward * pivot_distance \
			+ up * (_preview_size.y * view_up_bias)
		var xf := pivot_clone_root.transform
		xf.origin = target_pos
		pivot_clone_root.transform = xf

		if Input.is_action_pressed("zoom_in"):
			pivot_distance = clamp(pivot_distance - delta * 2.0, MIN_DIST, MAX_DIST)
		if Input.is_action_pressed("zoom_out"):
			pivot_distance = clamp(pivot_distance + delta * 2.0, MIN_DIST, MAX_DIST)

	var mat := $outliner.material as ShaderMaterial
	if mat:
		if debug_menu and debug_menu.visible:
			# Debug open → outline the whole stick
			mat.set_shader_parameter("enabled", 1.0)
			_show_all_segments()
		else:
			var hovered := _get_hovered_branch()
			if hovered:
				mat.set_shader_parameter("enabled", 1.0)
				_hide_all_segments()
				_highlight_connected_from(hovered)
			else:
				mat.set_shader_parameter("enabled", 0.0)

	# ─────────────────────────────
	# Debug info labels
	# ─────────────────────────────
	if debug_menu and debug_menu.visible:
		var hovered := _get_hovered_branch()
		debug_menu.branch_label.text = str(hovered.name) if hovered else "Not over branch"

		if is_instance_valid(pivot_clone_root):
			var count := pivot_clone_root.get_node("ModelRot").get_child_count()
			debug_menu.count_label.text = "Branch Count: %d" % count

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

	for child in _get_all_meshes(pivot_clone_root.get_node("ModelRot")):
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
			closest = child

	return closest

# ─────────────────────────────
# Helpers
# ─────────────────────────────

func _branch_origin_seg(n: Node) -> int:
	return int(n.get_meta("origin_seg")) if n and n.has_meta("origin_seg") else -1

# Find the nearest Branch_X ancestor and return its numeric id.
func _get_branch_id(node: Node) -> int:
	var p := node
	while p and not p.name.begins_with("Branch_"):
		p = p.get_parent()
	if p:
		var parts := p.name.split("_")
		if parts.size() >= 2:
			return int(parts[1])
	return -1

# For a MeshInstance3D named "Segment_Y" under a Branch_X container,
# return { "branch": X, "segment": Y }. Empty dict if not found.
func _parse_branch_segment(node: Node) -> Dictionary:
	var seg := -1
	if node.name.begins_with("Segment_"):
		var sp := node.name.split("_")
		if sp.size() >= 2:
			seg = int(sp[1])

	var br := _get_branch_id(node)
	if br == -1 or seg == -1:
		return {}
	return { "branch": br, "segment": seg }


# Find the nearest ancestor named "Branch_<n>" and extract its id.
func _find_ancestor_branch(node: Node) -> Node3D:
	while node and node != pivot_clone_root:
		if node is Node3D and node.name.begins_with("Branch_"):
			return node as Node3D
		node = node.get_parent()
	return null

# Parse branch/segment using the new hierarchy:
# - branch id from ancestor "Branch_<n>"
# - segment index from this mesh's own name "Segment_<m>"
func _parse_hinfo(mi: Node) -> Dictionary:
	if not (mi is MeshInstance3D):
		return {}
	var branch_node := _find_ancestor_branch(mi)
	if branch_node == null:
		return {}

	var b_id := -1
	var b_parts := branch_node.name.split("_")
	if b_parts.size() >= 2:
		b_id = int(b_parts[1])

	var s_id := -1
	if mi.name.begins_with("Segment_"):
		var s_parts := mi.name.split("_")
		if s_parts.size() >= 2:
			s_id = int(s_parts[1])

	if b_id < 0 or s_id < 0:
		return {}
	return { "branch": b_id, "segment": s_id }



# Only show:
# ─────────────────────────────
# Highlight hovered branch + children
# ─────────────────────────────
# Kick off highlighting from hovered branch + seg
func _highlight_connected_from(hovered: MeshInstance3D) -> void:
	if not hovered:
		return
	var info := _parse_branch_segment(hovered)
	if info.is_empty():
		return
	_hide_all_segments()
	_highlight_branch_recursive(info["branch"], info["segment"])

# Highlight a branch forward from min_seg, and any children that split at each shown segment
func _highlight_branch_recursive(branch_id: int, min_seg: int) -> void:
	var model := pivot_clone_root.get_node("ModelRot")
	for mi in _get_all_meshes(model):
		var cinfo := _parse_branch_segment(mi)
		if cinfo.is_empty():
			continue
		if cinfo["branch"] == branch_id and cinfo["segment"] >= min_seg:
			mi.visible = true

			# If this is at or after the starting segment, find child branches
		# If this is at or after the starting segment, find child branches
			if cinfo["segment"] >= min_seg:
				var parent_node = mi.get_parent()
				if parent_node:
					for sub in parent_node.get_children():
						if sub is Node3D and sub.name.begins_with("Branch_"):
							var origin_seg = sub.get_meta("origin_seg") if sub.has_meta("origin_seg") else -1
							# Only recurse if this branch was spawned at or after our hovered segment
							if origin_seg >= min_seg:
								var bid = sub.get_meta("branch_id") if sub.has_meta("branch_id") else -1
								if bid != -1:
									_highlight_branch_recursive(bid, 0)
		
func _highlight_whole_branch(branch_id: int) -> void:
	for mi in _get_all_meshes(pivot_clone_root.get_node("ModelRot")):
		var info := _parse_hinfo(mi)
		if info.is_empty():
			mi.visible = false
			continue

		var b: int = int(info["branch"])
		mi.visible = (b == branch_id)
					
func _clear_all_highlights():
	if not is_instance_valid(pivot_clone_root):
		return
	for child in pivot_clone_root.get_node("ModelRot").get_children():
		if child is MeshInstance3D and child.has_meta("outline_mat"):
			var mat := child.get_meta("outline_mat") as ShaderMaterial
			if mat:
				mat.set_shader_parameter("enabled", 0.0)
				
func _hide_all_segments() -> void:
	if not is_instance_valid(pivot_clone_root): return
	for mi in _get_all_meshes(pivot_clone_root.get_node("ModelRot")):
		mi.visible = false

func _show_all_segments() -> void:
	if not is_instance_valid(pivot_clone_root): return
	for mi in _get_all_meshes(pivot_clone_root.get_node("ModelRot")):
		mi.visible = true
			
				
func _collect_connected(start: MeshInstance3D) -> Array:
	var visited: Array = []
	if not start:
		return visited

	# Parse branch and segment
	var info = _parse_branch_segment(start)
	if info.is_empty():
		return [start]

	var branch_id = info["branch"]
	var seg_id = info["segment"]

	# Find parent "Branch_X" node
	var branch_node: Node = start.get_parent()
	while branch_node and not branch_node.name.begins_with("Branch_"):
		branch_node = branch_node.get_parent()

	if not branch_node:
		return [start]

	# Collect all segments in this branch with segment >= hovered segment
	for child in branch_node.get_children():
		if child is MeshInstance3D:
			var ci = _parse_branch_segment(child)
			if not ci.is_empty() and ci["branch"] == branch_id and ci["segment"] >= seg_id:
				visited.append(child)

	# 🔹 Also traverse into sub-branches (children nodes of Branch_X)
	for sub in branch_node.get_children():
		if sub.name.begins_with("Branch_"):
			visited.append_array(_get_all_meshes(sub))

	return visited

func _reset_view():
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
	var target_pos := cam.global_transform.origin \
		+ (-cam.global_transform.basis.z) * pivot_distance \
		+ up * (_preview_size.y * view_up_bias)
	pivot_clone_root.transform = Transform3D(flat, target_pos)
	pivot_distance = clamp(_fit_distance_base, MIN_DIST, MAX_DIST)
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)

# ─────────────────────────────
# Recursive helper
# ─────────────────────────────
func _hide_recursive(node: Node, state: bool) -> void:
	for child in node.get_children():
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
		elif child.get_child_count() > 0:
			_hide_recursive(child, state)


# ─────────────────────────────
# Hide/restore meshes in stick
# ─────────────────────────────
func _set_real_meshes_local_hidden(state: bool) -> void:
	if not is_instance_valid(stick):
		return

	_hide_recursive(stick, state)

	if not state:
		_saved_real_layers.clear()
		
# Recursively gather all MeshInstance3D nodes under a root
func _get_all_meshes(root: Node) -> Array[MeshInstance3D]:
	var meshes: Array[MeshInstance3D] = []
	for child in root.get_children():
		if child is MeshInstance3D:
			meshes.append(child)
		elif child.get_child_count() > 0:
			meshes.append_array(_get_all_meshes(child))
	return meshes
	
	

func _build_center_preview(cam: Camera3D):
	pivot_clone_root = Node3D.new()
	pivot_clone_root.name = "PivotCloneRoot"
	$SubViewportContainer/SubViewport.add_child(pivot_clone_root)

	var model_rot := Node3D.new()
	model_rot.name = "ModelRot"
	pivot_clone_root.add_child(model_rot)

	# 🔹 Recursively copy hierarchy from stick → clones
	_clone_hierarchy(stick, model_rot)

	# 🔹 Center + rotate preview
	model_rot.rotate_object_local(Vector3.FORWARD, -PI * 0.5)
	var center := _centroid_local(model_rot)
	model_rot.translate_object_local(-center)

	var forward := -cam.global_transform.basis.z
	if forward.length_squared() < 1e-6:
		forward = Vector3.FORWARD
	var right := Vector3.UP.cross(forward).normalized()
	pivot_clone_root.basis = Basis(right, Vector3.UP, -forward)

	# 🔹 Fit distance
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
	var target_pos := cam.global_transform.origin \
		+ (-cam.global_transform.basis.z) * pivot_distance \
		+ up * (_preview_size.y * view_up_bias)
	pivot_clone_root.transform = Transform3D(pivot_clone_root.basis, target_pos)
	
func _clone_hierarchy(src: Node, dst_parent: Node):
	for child in src.get_children():
		if child is MeshInstance3D:
			var clone := MeshInstance3D.new()
			clone.mesh = child.mesh
			clone.transform = child.transform
			clone.layers = CLONE_LAYER_MASK
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.45, 0.28, 0.15, 1.0)
			clone.set_surface_override_material(0, mat)
			clone.name = child.name
			dst_parent.add_child(clone)

		elif child is Node3D:
			var sub := Node3D.new()
			sub.name = child.name
			# carry over the split-segment metadata if present
			if child.has_meta("origin_seg"):
				sub.set_meta("origin_seg", int(child.get_meta("origin_seg")))
			if child.has_meta("branch_id"):
				sub.set_meta("branch_id", int(child.get_meta("branch_id")))
			dst_parent.add_child(sub)
			_clone_hierarchy(child, sub)


func _centroid_local(root: Node3D) -> Vector3:
	var total_vol: float = 0.0
	var acc: Vector3 = Vector3.ZERO
	for mi in _get_all_meshes(root):
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
	for mi in _get_all_meshes(root):
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

	var a := AABB(xform * p[0], Vector3.ZERO)
	for i in range(1, p.size()):
		a = a.expand(xform * p[i])

	return a
