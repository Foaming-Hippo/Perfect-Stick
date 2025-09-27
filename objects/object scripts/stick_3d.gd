extends Node3D
# Godot 4.4.1

@export var segment_count: int = 6
@export var segment_min_length: float = 0.1
@export var segment_max_length: float = 0.3
@export var base_thickness: float = 0.05
@export var tip_thickness: float = 0.01
@export var angle_variance: float = 0.4
@export var branch_chance: float = 0.3
@export var branch_scale: float = 0.6
@export var max_branch_depth: int = 3

@export var grab_min_distance: float = 1.0
@export var grab_max_distance: float = 6.0
@export var grab_stiffness: float = 10.0

# 🔹 Fat ray inspector settings
@export var ray_spread: int = 6
@export var ray_length: float = 5.0
@export var ray_count: int = 8

# 🔹 Flick throw settings
@export var flick_sensitivity: float = 0.05
@export var flick_max_boost: float = 20.0

@onready var hand: Node3D = get_node("../player/CollisionShape3D/Camera_Control/Camera3D/HandSocket")

var held_stick: RigidBody3D = null
var grabbed_stick: RigidBody3D = null
var highlighted_stick: RigidBody3D = null
var grabbed_distance: float = 2.0
var grabbed_offset: Vector3 = Vector3.ZERO

# For flick detection
var last_mouse_delta: Vector2 = Vector2.ZERO

# 🔹 branch naming
var _branch_counter: int = 0


func _ready() -> void:
	randomize()
	generate_stick()


func _input(event: InputEvent) -> void:
	var edit_menu = get_tree().current_scene.get_node("UI/EditMenu") # adjust path if needed

	# toggle edit first
	if event.is_action_pressed("edit_stick") and held_stick and edit_menu:
		if edit_menu.in_edit_mode:
			edit_menu.exit_edit_mode()
		else:
			edit_menu.enter_edit_mode(held_stick)
		return

	# block gameplay while edit is open
	if edit_menu and edit_menu.in_edit_mode:
		return

	# normal controls
	if event.is_action_pressed("gen"):
		generate_stick()
	elif event.is_action_pressed("interact"):
		if held_stick:
			drop_stick()
		else:
			pickup_nearest_stick()
	elif event.is_action_pressed("mouse_left"):
		grab_stick()
	elif event.is_action_released("mouse_left"):
		release_grabbed_stick()

	if event is InputEventMouseMotion:
		last_mouse_delta = event.relative


# ───────────────
# Sound Handling
# ───────────────
var light_throw_sounds: Array[AudioStream] = [
	preload("res://assets/sounds/lego-yoda-death-sound-made-with-Voicemod.mp3")
]
var medium_throw_sounds: Array[AudioStream] = [
	preload("res://assets/sounds/again-fetty-wap-jbl-made-with-Voicemod.wav")
]
var heavy_throw_sounds: Array[AudioStream] = [
	preload("res://assets/sounds/kirby-falling-meme-scream-made-with-Voicemod.mp3"),
	preload("res://assets/sounds/streamer-scream-meme-made-with-Voicemod.mp3"),
	preload("res://assets/sounds/jbl long.mp3"),
	preload("res://assets/sounds/femur-breaker-(scream-only)-made-with-Voicemod.mp3"),
	preload("res://assets/sounds/raaaaauughh-made-with-Voicemod.mp3"),
	preload("res://assets/sounds/loud-shitpost-fart-made-with-Voicemod.mp3"),
	preload("res://assets/sounds/lobotomy-made-with-Voicemod.mp3"),
	preload("res://assets/sounds/leeroy-jenkins-made-with-Voicemod.mp3"),
]
var super_throw: Array[AudioStream] = [
	preload("res://assets/sounds/tyler-1-scream-and-disappear-made-with-Voicemod.mp3"),
	preload("res://assets/sounds/eas-alarm-made-with-Voicemod.mp3")
]

func play_throw_sound_if_hard(stick: RigidBody3D) -> void:
	if stick == null: return
	var speed := stick.linear_velocity.length()
	var sound: AudioStreamPlayer3D = stick.get_meta("throw_sound")
	if sound == null: return
	if speed > 45.0:
		sound.stream = super_throw[randi() % super_throw.size()]
		sound.volume_db = 50.0
	elif speed > 20.0:
		sound.stream = heavy_throw_sounds[randi() % heavy_throw_sounds.size()]
		sound.volume_db = 35.0
	elif speed > 12.0:
		sound.stream = medium_throw_sounds[randi() % medium_throw_sounds.size()]
		sound.volume_db = 6.0
	elif speed > 6.0:
		sound.stream = light_throw_sounds[randi() % light_throw_sounds.size()]
		sound.volume_db = 2.0
	else:
		return
	sound.play()


# ───────────────
# Fat Ray Utility
# ───────────────
func _get_ray_offsets() -> Array:
	var offsets: Array = [Vector2.ZERO]
	if ray_count >= 4:
		offsets.append(Vector2(ray_spread, 0))
		offsets.append(Vector2(-ray_spread, 0))
		offsets.append(Vector2(0, ray_spread))
		offsets.append(Vector2(0, -ray_spread))
	if ray_count >= 8:
		offsets.append(Vector2(ray_spread, ray_spread))
		offsets.append(Vector2(-ray_spread, ray_spread))
		offsets.append(Vector2(ray_spread, -ray_spread))
		offsets.append(Vector2(-ray_spread, -ray_spread))
	return offsets


# ───────────────
# Anchored Pickup
# ───────────────
func pickup_nearest_stick() -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null: return

	var screen_center: Vector2 = get_viewport().get_visible_rect().size / 2
	var closest: RigidBody3D = null
	var closest_dist := INF

	for offset in _get_ray_offsets():
		var ray_from := cam.project_ray_origin(screen_center + offset)
		var ray_to := ray_from + cam.project_ray_normal(screen_center + offset) * ray_length

		var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to, 1 << 3)
		var result := get_world_3d().direct_space_state.intersect_ray(query)

		if not result.is_empty():
			var body: PhysicsBody3D = result["collider"]
			if body is RigidBody3D:
				var dist := cam.global_position.distance_to(body.global_position)
				if dist < closest_dist:
					closest = body
					closest_dist = dist

	if closest == null: return

	_clear_highlight()
	held_stick = closest
	held_stick.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	held_stick.freeze = true
	held_stick.gravity_scale = 0
	held_stick.linear_velocity = Vector3.ZERO
	held_stick.angular_velocity = Vector3.ZERO

	if held_stick.get_parent():
		held_stick.get_parent().remove_child(held_stick)
	hand.add_child(held_stick)

	var spear_dir = get_stick_direction(held_stick)

	if spear_dir == Vector3.ZERO:
		spear_dir = Vector3.FORWARD  # fallback direction

	var stick_basis = Basis.looking_at(spear_dir, Vector3.UP)
	var hold_offset = Transform3D(stick_basis, Vector3(0.3, -0.3, -0.7))
	held_stick.transform = hold_offset

# ───────────────
# Spear Alignment Helper
# ───────────────
func get_stick_direction(stick: RigidBody3D) -> Vector3:
	var base_pos: Vector3 = stick.global_transform.origin
	var farthest_point: Vector3 = base_pos
	var max_dist: float = -INF

	for child in stick.get_children():
		if child is MeshInstance3D:
			var pos: Vector3 = child.global_transform.origin
			var dist: float = base_pos.distance_to(pos)
			if dist > max_dist:
				max_dist = dist
				farthest_point = pos

	return (farthest_point - base_pos).normalized()


func drop_stick() -> void:
	if held_stick == null: return
	var drop_transform: Transform3D = held_stick.global_transform
	var world_parent: Node = get_tree().current_scene if get_parent() == null else get_parent()

	hand.remove_child(held_stick)
	world_parent.add_child(held_stick)
	held_stick.global_transform = drop_transform
	held_stick.freeze = false
	held_stick.gravity_scale = 1.0

	var player := get_node("../player")
	if player and player.has_method("get_velocity"):
		held_stick.linear_velocity = player.get_velocity()

	play_throw_sound_if_hard(held_stick)
	held_stick = null


# ───────────────
# Physics Grab
# ───────────────
func grab_stick() -> void:
	if grabbed_stick != null: return
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null: return

	var screen_center: Vector2 = get_viewport().get_visible_rect().size / 2
	var closest: RigidBody3D = null
	var closest_hit: Dictionary = {}
	var closest_dist := INF

	for offset in _get_ray_offsets():
		var ray_from := cam.project_ray_origin(screen_center + offset)
		var ray_to := ray_from + cam.project_ray_normal(screen_center + offset) * ray_length

		var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to, 1 << 3)
		var result := get_world_3d().direct_space_state.intersect_ray(query)

		if not result.is_empty():
			var hit_node: Node = result["collider"]
			var body := _find_rigidbody(hit_node)
			if body and body is RigidBody3D:
				var dist := cam.global_position.distance_to(result["position"])
				if dist < closest_dist:
					closest = body
					closest_hit = result
					closest_dist = dist

	if closest == null: return

	_clear_highlight()
	grabbed_stick = closest
	grabbed_stick.freeze = false
	grabbed_stick.gravity_scale = 1.0

	var hit_pos: Vector3 = closest_hit["position"]
	grabbed_distance = cam.global_position.distance_to(hit_pos)
	grabbed_offset = grabbed_stick.global_transform.affine_inverse() * hit_pos


func _physics_process(delta: float) -> void:
	if grabbed_stick:
		var cam := get_viewport().get_camera_3d()
		var target_point: Vector3 = cam.global_position + -cam.global_basis.z * grabbed_distance
		var desired_origin: Vector3 = target_point - (grabbed_stick.global_transform.basis * grabbed_offset)
		var diff: Vector3 = desired_origin - grabbed_stick.global_position
		grabbed_stick.linear_velocity = diff * grab_stiffness

		if Input.is_action_pressed("grab_push"):
			grabbed_distance = clamp(grabbed_distance - delta * 2.0, grab_min_distance, grab_max_distance)
		elif Input.is_action_pressed("grab_pull"):
			grabbed_distance = clamp(grabbed_distance + delta * 2.0, grab_min_distance, grab_max_distance)


func release_grabbed_stick() -> void:
	if grabbed_stick == null: return
	var player := get_node("../player")
	if player and player.has_method("get_velocity"):
		grabbed_stick.linear_velocity += player.get_velocity()

	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam:
		var flick_force = -cam.global_basis.z * min(last_mouse_delta.length() * flick_sensitivity, flick_max_boost)
		grabbed_stick.linear_velocity += flick_force

	play_throw_sound_if_hard(grabbed_stick)
	grabbed_stick = null


# ───────────────
# Highlight System
# ───────────────
func _process(_delta: float) -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null: return

	var screen_center: Vector2 = get_viewport().get_visible_rect().size / 2
	var closest: RigidBody3D = null
	var closest_dist := INF

	for offset in _get_ray_offsets():
		var ray_from := cam.project_ray_origin(screen_center + offset)
		var ray_to := ray_from + cam.project_ray_normal(screen_center + offset) * ray_length

		var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to, 1 << 3)
		var result := get_world_3d().direct_space_state.intersect_ray(query)

		if not result.is_empty():
			var body: PhysicsBody3D = result["collider"]
			if body is RigidBody3D and body != held_stick and body != grabbed_stick:
				var dist := cam.global_position.distance_to(body.global_position)
				if dist < closest_dist:
					closest = body
					closest_dist = dist

	if closest == null:
		_clear_highlight()
	else:
		if closest != highlighted_stick:
			_clear_highlight()
			highlighted_stick = closest
			_set_highlight(highlighted_stick)

func _get_all_segments(root: Node) -> Array:
	var segs: Array = []
	for child in root.get_children():
		if child is MeshInstance3D and child.has_meta("outline"):
			segs.append(child)
		segs += _get_all_segments(child) # recurse into branches
	return segs
	
func _get_all_colliders(root: Node) -> Array:
	var cols: Array = []
	for child in root.get_children():
		if child is CollisionShape3D:
			cols.append(child)
		cols += _get_all_colliders(child) # recurse
	return cols

func _set_highlight(stick: RigidBody3D) -> void:
	for seg in _get_all_segments(stick):
		var outline: MeshInstance3D = seg.get_meta("outline")
		if outline:
			outline.visible = true

func _clear_highlight() -> void:
	if highlighted_stick == null: return
	for seg in _get_all_segments(highlighted_stick):
		var outline: MeshInstance3D = seg.get_meta("outline")
		if outline:
			outline.visible = false
	highlighted_stick = null

func _find_rigidbody(node: Node) -> RigidBody3D:
	var cur = node
	while cur:
		if cur is RigidBody3D:
			return cur
		cur = cur.get_parent()
	return null

# ───────────────
# Stick Generation
# ───────────────
func generate_stick() -> void:
	var stick := RigidBody3D.new()
	stick.freeze = false
	stick.can_sleep = false
	stick.collision_layer = 1 << 3
	stick.collision_mask  = 1 << 0
	stick.contact_monitor = true
	stick.max_contacts_reported = 1
	add_child(stick)

	_branch_counter = 0
	_make_stick_segment(Vector3.ZERO, Basis(), 1.0, base_thickness, stick, 0, stick)

	stick.position = Vector3(randf_range(-2, 2), 2, randf_range(-2, 2))
	stick.angular_velocity = Vector3(randf_range(-3, 3), randf_range(-3, 3), randf_range(-3, 3))

	var sound := AudioStreamPlayer3D.new()
	sound.stream = preload("res://assets/sounds/kirby-falling-meme-scream-made-with-Voicemod.mp3")
	sound.autoplay = false
	sound.unit_size = 1.0
	sound.max_distance = 50.0
	sound.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	stick.add_child(sound)
	stick.set_meta("throw_sound", sound)
	stick.body_entered.connect(func(_body): if sound.playing: sound.stop())


# Add a defaulted parameter so top-level calls don’t change
func _make_stick_segment(
	start_pos: Vector3,
	start_basis: Basis,
	branch_scale: float,
	parent_thickness: float,
	parent_node: Node3D,
	branch_id: int,
	root_stick: RigidBody3D,
	origin_seg: int = -1,	# where this branch split from its parent
	depth: int = 0			# recursion guard
) -> void:
	# stop if scale is too small or depth exceeded
	if branch_scale <= 0.0 or depth >= max_branch_depth:
		return

	var segs: int = int(roundi(max(1.0, segment_count * branch_scale)))
	if segs <= 0:
		return

	# Create this branch container
	var branch_node := Node3D.new()
	branch_node.name = "Branch_%d" % branch_id
	branch_node.set_meta("branch_id", branch_id)
	branch_node.set_meta("origin_seg", origin_seg)	# used by editor highlight
	parent_node.add_child(branch_node)

	var pos := start_pos
	var seg_basis := start_basis

	for i in range(segs):
		var length = randf_range(segment_min_length, segment_max_length) * branch_scale
		var t: float = 0.0 if segs <= 1 else float(i) / float(segs - 1)
		var thickness = lerp(parent_thickness, tip_thickness, t) * branch_scale

		var mi = MeshInstance3D.new()
		var cyl = CylinderMesh.new()
		cyl.top_radius = thickness * 0.5
		cyl.bottom_radius = thickness * 0.5
		cyl.height = length
		cyl.radial_segments = 6
		mi.mesh = cyl

		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.4, 0.25, 0.1)
		mi.material_override = mat

		var local_offset := Vector3(0, length * 0.5, 0)
		var world_offset := seg_basis * local_offset
		mi.transform = Transform3D(seg_basis, pos + world_offset)
		branch_node.add_child(mi)

		# 🔹 Assign name/metadata
		mi.name = "Segment_%d" % i
		mi.set_meta("branch_id", branch_id)
		mi.set_meta("seg_index", i)

		# Outline mesh
		var outline := MeshInstance3D.new()
		outline.mesh = cyl
		outline.visible = false
		outline.scale = Vector3(1.05, 1.05, 1.05)
		var outline_mat := StandardMaterial3D.new()
		outline_mat.albedo_color = Color(1, 1, 0)
		outline_mat.emission_enabled = true
		outline_mat.emission = Color(1, 1, 0)
		outline_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		outline.material_override = outline_mat
		outline.transform = mi.transform
		branch_node.add_child(outline)
		mi.set_meta("outline", outline)

		# Collision (always under root stick for physics)
		var capsule := CapsuleShape3D.new()
		capsule.radius = thickness * 0.5
		capsule.height = length
		var coll := CollisionShape3D.new()
		coll.shape = capsule
		coll.transform = mi.transform
		root_stick.add_child(coll)

		# Advance along axis
		pos += (seg_basis * Vector3.UP) * length

		# Random bend
		var bend := Basis()
		bend = bend.rotated(Vector3.RIGHT, randf_range(-angle_variance, angle_variance))
		bend = bend.rotated(Vector3.FORWARD, randf_range(-angle_variance, angle_variance))
		seg_basis = seg_basis * bend

		# possible child branch
		if randf() < branch_chance and branch_scale > 0.3:
			_branch_counter += 1
			var branch_basis := seg_basis.rotated(Vector3.UP, randf_range(-1.0, 1.0))

			_make_stick_segment(
				pos,
				branch_basis,
				branch_scale * 0.75,	# decay scale quickly → natural depth limit
				thickness,
				branch_node,
				_branch_counter,
				root_stick,
				i,								# origin segment on parent
				depth + 1						# recursion guard
			)
