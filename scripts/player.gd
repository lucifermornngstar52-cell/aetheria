extends CharacterBody3D
class_name AetheriaPlayer
## Third-person controller: WASD / touch joystick, RMB or touch-drag camera, F = fly mode.

@export var walk_speed: float = 6.0
@export var run_speed: float = 11.5
@export var fly_speed: float = 90.0
@export var jump_velocity: float = 8.5
@export var gravity: float = 24.0
@export var mouse_sens: float = 0.0035
const CHAR_SCENE := "res://assets/char/char_male_base.glb"
const ANIM_LIB := "res://assets/char/aetheria_anims.res"

signal action_changed(text: String)

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
var anim: AnimationPlayer = null
var _anim_state: String = ""
var _idle_anim: String = ""
var _walk_anim: String = ""

# --- система действий ---
var climbing: bool = false
var sitting: bool = false
var emote: String = ""
var _attack_t: float = 0.0
var _emote_t: float = 0.0
var _coyote: float = 0.0
var _jump_buffer: float = 0.0
var _was_on_floor: bool = true
var _land_t: float = 0.0
var _wall_n: Vector3 = Vector3.ZERO
var _sword_mesh: Node3D = null
var _skeleton: Skeleton3D = null


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
	# готовая модель персонажа из assets/char, с анимациями Idle/Walk
	var ps = ResourceLoader.load(CHAR_SCENE)
	if ps is PackedScene:
		var ch: Node = (ps as PackedScene).instantiate()
		model.add_child(ch)
		_fit_character(ch)
		anim = ch.find_child("AnimationPlayer", true, false) as AnimationPlayer
		_skeleton = _find_skel(ch)
		_attach_sword()
		if anim != null:
			var lib = ResourceLoader.load(ANIM_LIB)
			if lib is AnimationLibrary:
				anim.add_animation_library("ual", lib)
				print("AETHERIA ANIM LIB merged=", (lib as AnimationLibrary).get_animation_list().size())
			var names := anim.get_animation_list()
			print("AETHERIA CHAR anims=", names.size())
			_idle_anim = _best(names, ["ual/Idle", "Idle"])
			_walk_anim = _best(names, ["ual/Walk", "Walk"])
			print("AETHERIA CHAR idle=", _idle_anim, " walk=", _walk_anim)
			_play_anim(_idle_anim)
		return


func _best(names: PackedStringArray, want: Array) -> String:
	for w in want:
		if names.has(String(w)):
			return String(w)
	return ""


func _has(a: String) -> bool:
	return anim != null and anim.has_animation(a)


func _pick_anim(names: PackedStringArray, needle: String) -> String:
	var low := needle.to_lower()
	for n in names:
		var s2 := String(n).to_lower()
		if s2.contains(low) and s2.contains("loop"):
			return String(n)
	for n in names:
		if String(n).to_lower().contains(low):
			return String(n)
	return ""
	_build_placeholder_model()


func _fit_character(ch: Node) -> void:
	# подгоняем рост под 1.75 м и ставим ноги на y=0
	var aabb := AABB()
	var first := true
	for mi in _all_meshes(ch):
		var g := mi as MeshInstance3D
		if g.mesh == null:
			continue
		var bb: AABB = g.global_transform * g.get_aabb()
		aabb = bb if first else aabb.merge(bb)
		first = false
	if first:
		return
	var height: float = maxf(aabb.size.y, 0.001)
	var k: float = 1.75 / height
	ch.scale = Vector3(k, k, k)
	# смещение, чтобы ступни стояли на земле; модель смотрит по -Z
	var base := Node3D.new()
	base.name = "FitOffset"
	var y_off: float = -aabb.position.y * k
	ch.position = Vector3(-aabb.get_center().x * k, y_off, -aabb.get_center().z * k)
	ch.rotation.y = PI


func _all_meshes(n: Node, out: Array = []) -> Array:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_all_meshes(c, out)
	return out


func _play_anim(anim_name: String) -> void:
	if anim == null or anim_name == "":
		return
	if _anim_state == anim_name and anim.is_playing():
		return
	_anim_state = anim_name
	anim.play(anim_name)
	if anim.current_animation == anim_name:
		var a: Animation = anim.get_animation(anim_name)
		if a != null:
			a.loop_mode = Animation.LOOP_LINEAR


func _build_placeholder_model() -> void:
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

	if Input.is_action_just_pressed("aeth_jump"):
		_jump_buffer = 0.16
	_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	_coyote = maxf(_coyote - delta, 0.0)
	if is_on_floor():
		_coyote = 0.14

	if fly:
		var d: Vector3 = pivot.global_transform.basis * Vector3(inp.x, 0.0, inp.y)
		if Input.is_action_pressed("aeth_up"):
			d.y += 1.0
		if Input.is_action_pressed("aeth_down"):
			d.y -= 1.0
		global_position += d * fly_speed * (3.0 if sprint else 1.0) * delta
		_play_anim("ual/NinjaJump_Idle" if _has("ual/NinjaJump_Idle") else _idle_anim)
		return

	_attack_t = maxf(_attack_t - delta, 0.0)
	_emote_t = maxf(_emote_t - delta, 0.0)
	_land_t = maxf(_land_t - delta, 0.0)
	if _emote_t <= 0.0 and emote != "":
		emote = ""

	# ---------------- лазание ----------------
	if climbing:
		_do_climb(delta, inp, sprint)
		return

	var spd: float = run_speed if sprint else walk_speed
	if _attack_t > 0.0:
		spd *= 0.25
	var dir: Vector3 = Basis(Vector3.UP, cam_yaw) * Vector3(inp.x, 0.0, inp.y)
	velocity.x = move_toward(velocity.x, dir.x * spd, 70.0 * delta)
	velocity.z = move_toward(velocity.z, dir.z * spd, 70.0 * delta)

	# ---------------- прыжок ----------------
	if is_on_floor():
		if _jump_buffer > 0.0:
			_jump_buffer = 0.0
			_coyote = 0.0
			velocity.y = jump_velocity
			_play_once("ual/Jump_Start" if _has("ual/Jump_Start") else "")
		else:
			velocity.y = 0.0
	else:
		if _jump_buffer > 0.0 and _coyote > 0.0:
			_jump_buffer = 0.0
			_coyote = 0.0
			velocity.y = jump_velocity
			_play_once("ual/Jump_Start" if _has("ual/Jump_Start") else "")
		var g: float = gravity * (1.3 if velocity.y < 0.0 else 1.0)
		velocity.y -= g * delta
		# короткое нажатие — короткий прыжок
		if not Input.is_action_pressed("aeth_jump") and velocity.y > 2.0:
			velocity.y -= gravity * 1.6 * delta

	var was_floor: bool = _was_on_floor
	move_and_slide()
	_was_on_floor = is_on_floor()
	if is_on_floor() and not was_floor and velocity.y <= 0.5:
		_land_t = 0.3
		_play_once("ual/Jump_Land" if _has("ual/Jump_Land") else "")

	if dir.length() > 0.1:
		model.rotation.y = lerp_angle(model.rotation.y, atan2(-dir.x, -dir.z), 14.0 * delta)

	_update_locomotion_anim(delta)

	if world != null:
		var gh: float = world.height_at(global_position.x, global_position.z)
		if global_position.y < gh - 4.0:
			global_position.y = gh + 2.0
			velocity = Vector3.ZERO


func _update_locomotion_anim(delta: float) -> void:
	if anim == null:
		return
	if sitting:
		_play_anim("ual/Sitting_Idle" if _has("ual/Sitting_Idle") else _idle_anim)
		anim.speed_scale = 1.0
		return
	if emote != "":
		_play_anim(emote)
		anim.speed_scale = 1.0
		return
	if _attack_t > 0.0:
		return
	var horiz: float = Vector2(velocity.x, velocity.z).length()
	if not is_on_floor():
		if _has("ual/Jump"):
			_play_anim("ual/Jump")
		anim.speed_scale = 1.0
		return
	if _land_t > 0.0 and _has("ual/Jump_Land"):
		_play_anim("ual/Jump_Land")
		anim.speed_scale = 1.0
		return
	if horiz > 0.6:
		var run_anim := "ual/Sprint" if (_has("ual/Sprint") and horiz > run_speed * 0.85) else _walk_anim
		_play_anim(run_anim)
		anim.speed_scale = clampf(horiz / walk_speed, 0.75, 1.9)
	else:
		_play_anim(_idle_anim)
		anim.speed_scale = 1.0


func _do_climb(delta: float, inp: Vector2, sprint: bool) -> void:
	var fwd: Vector3 = -pivot.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var from: Vector3 = global_position + Vector3(0.0, 1.0, 0.0)
	var to: Vector3 = from + fwd * 1.05
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		# стены нет — падаем из режима лазания
		_set_climb(false)
		return
	_wall_n = (hit["normal"] as Vector3).normalized()
	var up_speed: float = 3.4 if not sprint else 5.0
	velocity = Vector3.ZERO
	var want_up: float = -inp.y   # стик вперёд = вверх
	if absf(want_up) > 0.15:
		global_position += Vector3.UP * want_up * up_speed * delta
		if _has("ual/ClimbUp_1m"):
			_play_anim("ual/ClimbUp_1m")
			if anim != null:
				anim.speed_scale = clampf(absf(want_up) * 1.2, 0.5, 2.0)
	elif _has("ual/Push"):
		_play_anim("ual/Push")
		if anim != null:
			anim.speed_scale = 0.6
	# латеральное движение по стене
	var side: Vector3 = fwd.cross(Vector3.UP).normalized()
	if absf(inp.x) > 0.15:
		global_position += side * inp.x * 2.2 * delta
	# прижимаемся к стене
	global_position -= _wall_n * 0.02
	# спрыгнуть: прыжок или кнопка «Лазать» выключена
	if _jump_buffer > 0.0:
		_jump_buffer = 0.0
		_set_climb(false)
		velocity = _wall_n * 5.0 + Vector3.UP * jump_velocity * 0.85
		_play_once("ual/Jump_Start" if _has("ual/Jump_Start") else "")
		move_and_slide()
		return
	if world != null:
		var gh: float = world.height_at(global_position.x, global_position.z)
		if global_position.y > gh + 90.0:
			_set_climb(false)


# ---------------------------------------------------------------- публичные действия для кнопок
func do_attack() -> void:
	if anim == null or _attack_t > 0.0:
		return
	var picks := ["ual/Sword_Regular_A", "ual/Sword_Attack", "ual/Sword_Regular_B", "ual/Punch_Cross"]
	var chosen := ""
	for p in picks:
		if _has(String(p)):
			chosen = String(p)
			break
	if chosen == "":
		return
	_attack_t = 0.55
	sitting = false
	emote = ""
	anim.speed_scale = 1.15
	_play_once(chosen)
	action_changed.emit("Удар мечом")


func request_jump() -> void:
	_jump_buffer = 0.16


func toggle_climb() -> void:
	_set_climb(not climbing)
	if climbing:
		action_changed.emit("Лазание включено — подойди к стене и веди стик вверх")
	else:
		emote = ""
		action_changed.emit("Лазание выключено")


func _set_climb(on: bool) -> void:
	climbing = on
	if on:
		sitting = false
		emote = ""
		velocity = Vector3.ZERO


func toggle_sit() -> void:
	sitting = not sitting
	if sitting:
		emote = ""
		_set_climb(false)
		_play_once("ual/Sitting_Enter" if _has("ual/Sitting_Enter") else "")
		action_changed.emit("Персонаж сел — нажми «Встать», чтобы встать")
	else:
		_play_once("ual/Sitting_Exit" if _has("ual/Sitting_Exit") else "")
		action_changed.emit("Встал")


func play_emote(anim_name: String, label: String = "") -> void:
	if anim == null:
		return
	if not _has(anim_name):
		return
	sitting = false
	_set_climb(false)
	emote = anim_name
	_emote_t = 6.0
	if anim.has_animation(anim_name):
		var a := anim.get_animation(anim_name)
		if a != null:
			_emote_t = maxf(a.length * 2.0, 3.0)
	anim.speed_scale = 1.0
	_play_anim(anim_name)
	action_changed.emit(label if label != "" else "Действие")


func toggle_run() -> void:
	run = not run
	action_changed.emit("Бег включён" if run else "Бег выключен")


func toggle_fly() -> void:
	fly = not fly
	velocity = Vector3.ZERO
	action_changed.emit("Полёт включён" if fly else "Полёт выключен")


func _play_once(anim_name: String) -> void:
	if anim == null or anim_name == "":
		return
	if not anim.has_animation(anim_name):
		return
	anim.speed_scale = 1.0
	anim.play(anim_name, 0.12)
	_anim_state = anim_name


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var sk := _find_skel(c)
		if sk != null:
			return sk
	return null


func _attach_sword() -> void:
	if _skeleton == null:
		return
	var hand := -1
	for cand in ["RightHand", "hand_r", "mixamorig_RightHand"]:
		hand = _skeleton.find_bone(cand)
		if hand >= 0:
			break
	if hand < 0:
		return
	var att := BoneAttachment3D.new()
	att.name = "SwordHold"
	att.bone_name = _skeleton.get_bone_name(hand)
	_skeleton.add_child(att)
	_sword_mesh = Node3D.new()
	att.add_child(_sword_mesh)
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.80, 0.84, 0.90)
	steel.metallic = 0.85
	steel.roughness = 0.25
	var grip := StandardMaterial3D.new()
	grip.albedo_color = Color(0.24, 0.16, 0.10)
	grip.roughness = 0.8
	var blade := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.055, 0.85, 0.012)
	blade.mesh = bm
	blade.material_override = steel
	blade.position = Vector3(0.0, 0.46, 0.0)
	(_sword_mesh as Node3D).add_child(blade)
	var guard := MeshInstance3D.new()
	var gm := BoxMesh.new()
	gm.size = Vector3(0.20, 0.028, 0.03)
	guard.mesh = gm
	guard.material_override = steel
	guard.position = Vector3(0.0, 0.03, 0.0)
	(_sword_mesh as Node3D).add_child(guard)
	var hilt := MeshInstance3D.new()
	var hm2 := BoxMesh.new()
	hm2.size = Vector3(0.035, 0.16, 0.035)
	hilt.mesh = hm2
	hilt.material_override = grip
	hilt.position = Vector3(0.0, -0.06, 0.0)
	(_sword_mesh as Node3D).add_child(hilt)
	(_sword_mesh as Node3D).rotation_degrees = Vector3(-95.0, 0.0, 0.0)
	(_sword_mesh as Node3D).scale = Vector3.ONE * 0.9
	print("AETHERIA SWORD in hand: ", _skeleton.get_bone_name(hand))
