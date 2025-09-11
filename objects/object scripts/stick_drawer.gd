# this code was written by Chat-GPT

# press C to generate stick
# press tab to open stick menu

extends Node2D

@onready var stick_container = $"." # Node2D where the stick will appear


@export var segment_count: int = 6
@export var segment_min_length: float = 20
@export var segment_max_length: float = 50
@export var base_thickness: float = 16
@export var tip_thickness: float = 4
@export var angle_variance: float = 0.3
@export var branch_chance: float = 0.3
@export var branch_scale: float = 0.6

func _ready():
	randomize()
	generate_stick()

func _input(event):
	if event.is_action_pressed("gen"): # default is Space/Enter
		generate_stick()

func generate_stick():
	# Clear old stick parts
	for child in get_children():
		child.queue_free()

	# Build stick
	make_stick(Vector2.ZERO, 0.0, 1.0)

	# 👉 Fit inside viewport
	fit_to_viewport()

func fit_to_viewport():
	if get_child_count() == 0:
		return

	# Get bounds of all children
	var rect = Rect2()
	var first = true
	for child in get_children():
		if child is Control:
			var global_rect = Rect2(child.position, child.size)
			if first:
				rect = global_rect
				first = false
			else:
				rect = rect.merge(global_rect)

	# Compute scale to fit viewport
	var vp = get_viewport_rect().size
	var scale_factor = min(vp.x / rect.size.x, vp.y / rect.size.y) * 0.8 # padding

	# Apply scaling
	scale = Vector2(scale_factor, scale_factor)

	# 👉 Center based on rect origin + size
	var centered_offset = (vp / 2) - ((rect.position + rect.size / 2) * scale)
	position = centered_offset


func make_stick(start_pos: Vector2, start_angle: float, scale: float, parent_thickness: float = base_thickness):
	var segs = int(segment_count * scale)
	if segs <= 0:
		return

	var pos := start_pos
	var angle := start_angle

	for i in range(segs):
		var length = randf_range(segment_min_length, segment_max_length) * scale

		# taper relative to parent thickness
		var t := 0.0 if segs <= 1 else float(i) / float(segs - 1)
		var thickness = lerp(parent_thickness, tip_thickness, t) * scale

		angle += randf_range(-angle_variance, angle_variance)

		var rect = ColorRect.new()
		rect.color = Color(0.4, 0.2, 0.1)
		rect.size = Vector2(length, max(thickness, 1))
		rect.pivot_offset = Vector2(0, thickness / 2.0)
		rect.rotation = angle
		rect.position = pos
		add_child(rect)

		pos += Vector2(length, 0).rotated(angle)

		# 👇 Pass current thickness into the branch
		if randf() < branch_chance and scale > 0.3:
			var branch_angle = angle + randf_range(-1.0, 1.0)
			make_stick(pos, branch_angle, scale * branch_scale, thickness)

	# Only center the root stick
	if scale == 1.0 and start_pos == Vector2.ZERO:
		fit_to_viewport()
