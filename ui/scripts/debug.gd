extends PanelContainer

@onready var property_container: VBoxContainer = %VBoxContainer
@onready var player = get_tree().current_scene.get_node("player")

var fps_label: Label
var branch_label: Label
var count_label: Label

func _ready():
	visible = false
	fps_label = add_debug_property("FPS", "0.00")
	branch_label = add_debug_property("Branch", "None")
	count_label = add_debug_property("Branch Count", "0")

func _process(delta):
	if visible:
		fps_label.text = "FPS: %.2f" % (1.0 / max(delta, 0.000001))
		# Branch + count will be updated externally by edit_menu.gd

func _input(event):
	if event.is_action_pressed("debug"):
		visible = !visible
		_update_mouse_mode()
		get_viewport().set_input_as_handled()

func _update_mouse_mode():
	var ui_locked := false
	if player and player.has_method("is_ui_locked"):
		ui_locked = player.is_ui_locked()

	if visible:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		if not ui_locked:
			if player and player.has_method("ensure_capture"):
				player.ensure_capture()
			else:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func add_debug_property(title: String, value: String) -> Label:
	var label = Label.new()
	property_container.add_child(label)
	label.name = title
	label.text = "%s: %s" % [title, value]
	return label
