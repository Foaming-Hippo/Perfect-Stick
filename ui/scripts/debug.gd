extends PanelContainer

@onready var property_container = %VBoxContainer

var property
var fps : String

# Called when the node enters the scene tree for the first time.
func _ready():
	visible = false
	
	add_debug_property("FPS",fps)
	
func _process(delta):
	if visible:
		fps = "%.2f" % (1.0/delta)
	
		property.text = property.name + ": " + fps
	
func _input(event):
	#open debug
	if event.is_action_pressed("debug"):
		visible = !visible
	if visible:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func add_debug_property(title: String,value):
	property = Label.new()
	property_container.add_child(property)
	property.name = title
	property.text = property.name + value
