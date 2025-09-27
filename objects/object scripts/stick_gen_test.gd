extends Node


var item_data = {}


# Called when the node enters the scene tree for the first time.
func _ready():
	
	var itemdata_file = FileAccess.open("res://objects/Object_Data/Sheet1.json", FileAccess.READ)
	var item_data_json = JSON.parse_string(itemdata_file.get_as_text())
	print(item_data_json)
	itemdata_file.close()
	
	
