extends CharacterBody3D
class_name AetheriaPlayer
## Third-person controller: WASD / touch joystick, RMB or touch-drag camera, F = fly mode.

@export var walk_speed: float = 6.0
@export var run_speed: float = 11.5
@export var fly_speed: float = 90.0
@export var jump_velocity: float = 8.5
@export var gravity: float = 24.0
@export var mouse_sens: float = 0.0035

var move_input: Vector2 = Vector2.ZERO   # set by the HUD joystick (y > 0 = backwards)
var look_delta: Vector2 = Vector2.ZERO   # radians, set by the HUD touch-look
var run: bool = false
var fly: bool = false
var want_jump: bool = false
var cam_yaw: float = 0.0
var cam_pitch: float = -0.28
var pivot: Node3D
var arm: SpringArm3D
var cam: Camera3D
var model: Node3D
var world: Node = null
var _rmb: bool = false


func _ready() -> void:
	_ensure_actions()
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	cs.shape = cap
	cs.position.y = 0.9
	add_child(cs)
	_build_model()
	pivot = Node3D.new()
	pivot.position = Vector3(0.0, 1.55, 0.0)
	add_child(pivot)
	arm = SpringArm3D.new()
	arm.spring_length = 5.5
	arm.margin = 0.35
	arm.add_excluded_object(get_rid())
	pivot.add_child(arm)
	cam = Camera3D.new()
	cam.fov = 68.0
	cam.near = 0.15
	cam.far = 3000.0
	arm.add_child(cam)
	cam.current = true
	floor_snap_length = 0.7
	floor_max_angle = deg_to_rad(56.0)
	floor_stop_on_slope = true
	set_physics_process(false)
	world = get_tree().get_first_node_in_group("world")
	if world != null:
		if bool(world.get("is_built")):
			_on_world_built()
		else:
			world.connect("built", _on_world_built)


func _on_world_built() -> void:
	var sp: Array = world.manifest.spawn
	global_position = Vector3(float(sp[0]), float(sp[1]), float(sp[2]))
	velocity = Vector3.ZERO
	set_physics_process(true)


func _ensure_actions() -> void:
	var map := {
		"aeth_left": [KEY_A, KEY_LEFT], "aeth_right": [KEY_D, KEY_RIGHT],
		"aeth_forward": [KEY_W, KEY_UP], "aeth_back": [KEY_S, KEY_DOWN],
		"aeth_jump": [KEY_SPACE], "aeth_run": [KEY_SHIFT],
		"aeth_up": [KEY_SPACE, KEY_E], "aeth_down": [KEY_C, KEY_Q],
	}
	for a in map:
		if not InputMap.has_action(a):
			InputMap.add_action(a)
			for k in map[a]:
				var ev := InputEventKey.new()
				ev.physical_keycode = k
				InputMap.action_add_event(a, ev)


func _build_model() -> void:
	model = Node3D.new()
	add_child(model)
	var tunic := StandardMaterial3D.new()
	tunic.albedo_color = Color(0.20, 0.32, 0.62)
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(1.0, 0.86, 0.76)
	var hair := StandardMaterial3D.new()
	hair.albedo_color = Color(0.95, 0.55, 0.70)
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.82, 0.86, 0.92)
	steel.metallic = 0.6
	steel.roughness = 0.35
	var body := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.3
	cm.height = 1.15
	body.mesh = cm
	body.material_override = tunic
	body.position.y = 0.72
	model.add_child(body)
	var head := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.21
	sm.height = 0.42
	head.mesh = sm
	head.material_override = skin
	head.position.y = 1.52
	model.add_child(head)
	var hr := MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = 0.24
	hm.height = 0.40
	hr.mesh = hm
	hr.material_override = hair
	hr.position = Vector3(0.0, 1.60, 0.04)
	model.add_child(hr)
	var sword := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.07, 1.05, 0.03)
	sword.mesh = bm
	sword.material_override = steel
	sword.position = Vector3(0.0, 1.0, 0.27)
	sword.rotation.z = 0.5
	model.add_child(sword)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_rmb = mb.pressed
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _rmb else Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and _rmb:
		var mm := event as InputEventMouseMotion
		look_delta += mm.relative * mouse_sens
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and k.physical_keycode == KEY_F:
			fly = not fly
			velocity = Vector3.ZERO


func _physics_process(delta: float) -> void:
	cam_yaw -= look_delta.x
	cam_pitch = clampf(cam_pitch - look_delta.y, -1.35, 0.9)
	look_delta = Vector2.ZERO
	pivot.rotation = Vector3(cam_pitch, cam_yaw, 0.0)
	var inp: Vector2 = move_input
	var kb := Input.get_vector("aeth_left", "aeth_right", "aeth_forward", "aeth_back")
	if kb.length() > 0.01:
		inp = kb
	var sprint: bool = run or Input.is_action_pressed("aeth_run")
	if fly:
		var d: Vector3 = pivot.global_transform.basis * Vector3(inp.x, 0.0, inp.y)
		if Input.is_action_pressed("aeth_up"):
			d.y += 1.0
		if Input.is_action_pressed("aeth_down"):
			d.y -= 1.0
		global_position += d * fly_speed * (3.0 if sprint else 1.0) * delta
		return
	var spd: float = run_speed if sprint else walk_speed
	var dir: Vector3 = Basis(Vector3.UP, cam_yaw) * Vector3(inp.x, 0.0, inp.y)
	velocity.x = move_toward(velocity.x, dir.x * spd, 70.0 * delta)
	velocity.z = move_toward(velocity.z, dir.z * spd, 70.0 * delta)
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif want_jump or Input.is_action_just_pressed("aeth_jump"):
		velocity.y = jump_velocity
	want_jump = false
	move_and_slide()
	if dir.length() > 0.1:
		model.rotation.y = lerp_angle(model.rotation.y, atan2(-dir.x, -dir.z), 12.0 * delta)
	if world != null:
		var gh: float = world.height_at(global_position.x, global_position.z)
		if global_position.y < gh - 4.0:
			global_position.y = gh + 2.0
			velocity = Vector3.ZERO
