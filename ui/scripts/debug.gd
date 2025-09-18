extends PanelContainer

@onready var property_container: VBoxContainer = %VBoxContainer
@onready var player = get_tree().current_scene.get_node("player")	# adjust if needed

var property: Label
var fps: String = "0.00"	# initialize so it has a concrete type

func _ready():
	visible = false
	add_debug_property("FPS", fps)

func _process(delta):
	if visible:
		fps = "%.2f" % (1.0 / max(delta, 0.000001))
		property.text = "%s: %s" % [property.name, fps]

func _input(event):
	# toggle debug
	if event.is_action_pressed("debug"):
		visible = !visible
		_update_mouse_mode()
		get_viewport().set_input_as_handled()

func _update_mouse_mode():
	# don't fight the edit menu; ask the player if UI is locked
	var ui_locked := false
	if player and player.has_method("is_ui_locked"):
		ui_locked = player.is_ui_locked()

	if visible:
		# showing debug → free the mouse
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		# hiding debug → only recapture if no other UI owns the cursor
		if not ui_locked:
			if player and player.has_method("ensure_capture"):
				player.ensure_capture()
			else:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func add_debug_property(title: String, value: String):
	property = Label.new()
	property_container.add_child(property)
	property.name = title
	property.text = "%s: %s" % [title, value]
