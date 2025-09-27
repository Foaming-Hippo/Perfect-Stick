extends Control

@export var base_scale := 0.05   # size relative to screen height (5%)
@export var color := Color.WHITE
@export var shape := "dot"       # "dot", "cross", or "circle"

func _ready() -> void:
	anchor_left = 0
	anchor_top = 0
	anchor_right = 1
	anchor_bottom = 1
	queue_redraw()
	get_viewport().size_changed.connect(_on_resize)

func _on_resize() -> void:
	queue_redraw()

func _draw() -> void:
	var vp_size: Vector2 = get_viewport_rect().size
	var center: Vector2 = vp_size / 2
	var size_px: float = vp_size.y * base_scale

	match shape:
		"dot":
			draw_circle(center, size_px * 0.1, color)
		"cross":
			var cross_len := size_px * 0.4
			var thick := 2.0
			draw_line(center - Vector2(cross_len, 0), center + Vector2(cross_len, 0), color, thick)
			draw_line(center - Vector2(0, cross_len), center + Vector2(0, cross_len), color, thick)
		"circle":
			draw_arc(center, size_px * 0.4, 0, TAU, 64, color, 2.0)
