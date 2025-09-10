extends CharacterBody3D


@export var SPEED : float = 5.0
@export var C_SPEED : float = 3.0
@export var R_SPEED : float = 10.0
@export var JUMP_VELOCITY = 4.5
@export_range(5,10,0.1) var CROUCH_SPEED : float = 7.8
@export var TOGGLE_CROUCH : bool = true


@export var MOUSE_SENS : float = 0.5
@export var TILT_LOWER_LIMIT := deg_to_rad(-90.0)
@export var TILT_UPPER_LIMIT := deg_to_rad(90.0)
@export var CAMERA_CONTROL : Camera3D
@export var ANI_PLAY : AnimationPlayer
@export var  CROUCH_SHAPECAST : Node3D

var _speed : float
var _mouse_input : bool = false
var _mouse_rot : Vector3
var _rot_input : float
var _tilt_input : float
var _player_rot : Vector3
var _cam_rot : Vector3
var _is_crouching : bool = false
var _is_running: bool = false


func _input(event):
	if event.is_action_pressed("esc"):
		get_tree().quit()
		
	if event.is_action_pressed("crouch") and TOGGLE_CROUCH == true:
		toggle_crouch()
		
	if event.is_action_pressed("run"):
		_is_running = true
	if event.is_action_pressed("run") and _is_crouching == false:
		running(true)
	if event.is_action_released("run") and _is_crouching == false:
		running(false)

		
	if event.is_action_pressed("crouch") and _is_crouching == false and TOGGLE_CROUCH == false: # hold to crouch
		crouching(true)
	if event.is_action_released("crouch") and TOGGLE_CROUCH == false: # hold to uncrouch
		if CROUCH_SHAPECAST.is_colliding() == false:
			crouching(false)
		elif CROUCH_SHAPECAST.is_colliding() == true:
			uncrouch_check()
			
			
	
	
		
		
func _unhandled_input(event):
	_mouse_input = event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
	if _mouse_input:
		_rot_input = -event.relative.x * MOUSE_SENS
		_tilt_input = -event.relative.y * MOUSE_SENS
		
		
func _update_camera(delta):
	
	_mouse_rot.x += _tilt_input * delta 
	_mouse_rot.x = clamp(_mouse_rot.x, TILT_LOWER_LIMIT, TILT_UPPER_LIMIT)
	_mouse_rot.y += _rot_input * delta
	
	_player_rot = Vector3(0.0,_mouse_rot.y,0.0)
	_cam_rot = Vector3(_mouse_rot.x,0.0,0.0)
	
	CAMERA_CONTROL.transform.basis = Basis.from_euler(_cam_rot)
	CAMERA_CONTROL.rotation.z = 0.0
	
	global_transform.basis = Basis.from_euler(_player_rot)
	
	_rot_input = 0.0
	_tilt_input = 0.0 
		
func _ready():
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	
	_speed = SPEED
	
	CROUCH_SHAPECAST.add_exception($".")
	
	



func _physics_process(delta):
	# Add the gravity.
	if not is_on_floor():
		velocity += get_gravity() * delta
		
	_update_camera(delta)
	
	
	# Handle jump.
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	var input_dir = Input.get_vector("move_l", "move_r", "move_f", "move_b")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		velocity.x = direction.x * _speed
		velocity.z = direction.z * _speed
	else:
		velocity.x = move_toward(velocity.x, 0, _speed)
		velocity.z = move_toward(velocity.z, 0, _speed)

	move_and_slide()
	
func toggle_crouch():
	if _is_crouching == true and CROUCH_SHAPECAST.is_colliding() == false:
		crouching(false)
		
	elif _is_crouching == false:
		crouching(true)
		
		
func uncrouch_check():
	if CROUCH_SHAPECAST.is_colliding() == false:
		crouching(false)
	if CROUCH_SHAPECAST.is_colliding() == true:
		await get_tree().create_timer(0.1).timeout
		uncrouch_check()
		
func crouching(state : bool):
	match state:
		true:
			ANI_PLAY.play("crouch", 0, CROUCH_SPEED)
			set_movement_speed("crouching")
		false:
			ANI_PLAY.play("crouch", 0, -CROUCH_SPEED, true)
			set_movement_speed("default")
			if _is_running == true:
				set_movement_speed("running")
		
			
func running(state : bool):
	match state:
		true:
			set_movement_speed("running")
		false:
			set_movement_speed("default")
		
			
	


func _on_animation_player_animation_started(anim_name):
	if anim_name == "crouch":
		_is_crouching = !_is_crouching

func set_movement_speed(state : String):
	match state:
		"default":
			_speed = SPEED
		"crouching":
			_speed = C_SPEED
		"running":
			_speed = R_SPEED
	print(state)
