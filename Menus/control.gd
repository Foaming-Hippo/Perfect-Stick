extends CanvasLayer

@onready var stick_container = $StickContainer
@onready var gen_button = $ButtonGen

var stick_instance: Node2D = null

func _ready():
	visible = false
	
	
	
	var stick_scene = preload("res://Menus/stick_display.tscn")
	stick_instance = stick_scene.instantiate()
	stick_container.add_child(stick_instance)
	# Connect button signal properly for Godot 4
	gen_button.pressed.connect(Callable(self, "_on_generate_pressed"))
	
	if stick_instance.has_method("generate_stick"):
		stick_instance.generate_stick()

		


func _on_generate_pressed():
	if stick_instance != null:
		stick_instance.generate_stick()



func _input(event):
	if event.is_action_pressed("menu_stick"):
		visible = !visible

	if visible:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
