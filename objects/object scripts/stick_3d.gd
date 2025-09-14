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

var current_stick: RigidBody3D = null

func _ready() -> void:
	randomize()
	generate_stick()

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("gen"):
		generate_stick()

func generate_stick() -> void:
	# Remove previous stick
	if current_stick and current_stick.is_inside_tree():
		current_stick.queue_free()

	# New rigidbody for this stick
	var stick := RigidBody3D.new()
	stick.freeze = false
	stick.can_sleep = false
	stick.collision_layer = 1 << 3  # Layer 4 = props
	stick.collision_mask  = 1 << 0  # Collide with world (Layer 1)
	add_child(stick)
	current_stick = stick

	# Build meshes + colliders directly under the rigidbody
	_make_stick_segment(Vector3.ZERO, Basis(), 1.0, base_thickness, stick)

	# Drop it above ground
	stick.position = Vector3(0, 2, 0)


func _make_stick_segment(start_pos: Vector3, start_basis: Basis, scale: float, parent_thickness: float, parent_node: Node3D) -> void:
	var segs := int(segment_count * scale)
	if segs <= 0:
		return

	var pos := start_pos
	var basis := start_basis

	for i in range(segs):
		var length: float = randf_range(segment_min_length, segment_max_length) * scale
		var t: float = 0.0 if segs <= 1 else float(i) / float(segs - 1)
		var thickness: float = float(lerp(parent_thickness, tip_thickness, t)) * scale

		# -------- Mesh --------
		var mi := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = thickness * 0.5
		cyl.bottom_radius = thickness * 0.5
		cyl.height = length
		cyl.radial_segments = 6
		mi.mesh = cyl

		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.4, 0.25, 0.1)
		mi.material_override = mat

		var local_offset := Vector3(0, length * 0.5, 0)
		var world_offset := basis * local_offset
		mi.transform = Transform3D(basis, pos + world_offset)
		parent_node.add_child(mi)

		# -------- Collider --------
		var capsule := CapsuleShape3D.new()
		capsule.radius = thickness * 0.5
		capsule.height = length
		var coll := CollisionShape3D.new()
		coll.shape = capsule
		coll.transform = mi.transform
		parent_node.add_child(coll)

		# Advance tip position
		pos += (basis * Vector3.UP) * length

		# Random bend
		var bend := Basis()
		bend = bend.rotated(Vector3.RIGHT, randf_range(-angle_variance, angle_variance))
		bend = bend.rotated(Vector3.FORWARD, randf_range(-angle_variance, angle_variance))
		basis = basis * bend

		# Recursive branch
		if randf() < branch_chance and scale > 0.3:
			var branch_basis := basis.rotated(Vector3.UP, randf_range(-1.0, 1.0))
			_make_stick_segment(pos, branch_basis, scale * branch_scale, thickness, parent_node)
