extends CanvasLayer
class_name AetheriaHUD
## Mobile HUD: floating touch joystick (left), touch-look (right), action buttons, minimap, debug info.

var player: Node = null
var world: Node = null
var atmos: Node = null
var ui: Control
var info: Label
var joy_base: Panel
var joy_knob: Panel
var joy_touch: int = -1
var look_touch: int = -1
var joy_origin: Vector2 = Vector2.ZERO
var buttons: Array = []
var map_rect: TextureRect
var map_marker: ColorRect
var map_big: bool = false
var _acc: float = 0.0
const JOY_R := 70.0


func _ready() -> void:
	layer = 10
	player = get_tree().get_first_node_in_group("player")
	world = get_tree().get_first_node_in_group("world")
	atmos = get_tree().get_first_node_in_group("atmosphere")
	ui = Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ui)
	info = Label.new()
	info.position = Vector2(12, 8)
	info.add_theme_font_size_override("font_size", 16)
	info.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	info.add_theme_constant_override("outline_size", 5)
	ui.add_child(info)
	joy_base = _circle(Vector2(JOY_R * 2.2, JOY_R * 2.2), Color(1, 1, 1, 0.16))
	joy_knob = _circle(Vector2(JOY_R * 1.0, JOY_R * 1.0), Color(1, 1, 1, 0.35))
	joy_base.visible = false
	joy_knob.visible = false
	ui.add_child(joy_base)
	ui.add_child(joy_knob)
	_button("Jump", Vector2(-150, -150), Vector2(120, 120), _on_jump)
	_button("Run", Vector2(-290, -110), Vector2(110, 80), _on_run)
	_button("Fly", Vector2(-290, -200), Vector2(110, 70), _on_fly)
	_button("Map", Vector2(-120, 20), Vector2(100, 60), _on_map)
	_button("Quality", Vector2(-240, 20), Vector2(110, 60), _on_quality)
	_button("+2h", Vector2(-350, 20), Vector2(90, 60), _on_time)
	map_rect = TextureRect.new()
	map_rect.texture = load("res://ui/minimap.png")
	map_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	map_rect.stretch_mode = TextureRect.STRETCH_SCALE
	map_rect.modulate = Color(1, 1, 1, 0.92)
	map_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(map_rect)
	map_marker = ColorRect.new()
	map_marker.color = Color(1, 0.1, 0.1)
	map_marker.size = Vector2(9, 9)
	map_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(map_marker)
	_layout_map()


func _circle(sz: Vector2, col: Color) -> Panel:
	var p := Panel.new()
	p.size = sz
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	var r := int(sz.x * 0.5)
	sb.corner_radius_top_left = r
	sb.corner_radius_top_right = r
	sb.corner_radius_bottom_left = r
	sb.corner_radius_bottom_right = r
	p.add_theme_stylebox_override("panel", sb)
	return p


func _button(text: String, off: Vector2, sz: Vector2, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.anchor_left = 1.0
	b.anchor_right = 1.0
	if off.y < -50:
		b.anchor_top = 1.0
		b.anchor_bottom = 1.0
	b.offset_left = off.x
	b.offset_top = off.y
	b.offset_right = off.x + sz.x
	b.offset_bottom = off.y + sz.y
	b.modulate = Color(1, 1, 1, 0.85)
	b.pressed.connect(cb)
	ui.add_child(b)
	buttons.append(b)


func _layout_map() -> void:
	var vs := get_viewport().get_visible_rect().size
	if map_big:
		var s: float = minf(vs.x, vs.y) * 0.86
		map_rect.size = Vector2(s, s)
		map_rect.position = (vs - map_rect.size) * 0.5
	else:
		map_rect.size = Vector2(230, 230)
		map_rect.position = Vector2(vs.x - 240 - 0, 90)


func _on_jump() -> void:
	if player != null:
		player.set("want_jump", true)


func _on_run() -> void:
	if player != null:
		player.set("run", not bool(player.get("run")))


func _on_fly() -> void:
	if player != null:
		player.set("fly", not bool(player.get("fly")))


func _on_map() -> void:
	map_big = not map_big
	_layout_map()


func _on_quality() -> void:
	if world == null:
		return
	var q: int = (int(world.get("quality")) + 1) % 3
	world.set("quality", q)
	get_viewport().scaling_3d_scale = [0.67, 0.85, 1.0][q]


func _on_time() -> void:
	if atmos != null:
		atmos.set("time_of_day", float(atmos.get("time_of_day")) + 2.0)


func _over_button(pos: Vector2) -> bool:
	for b in buttons:
		if (b as Control).get_global_rect().has_point(pos):
			return true
	return false


func _input(event: InputEvent) -> void:
	if player == null:
		return
	var w: float = get_viewport().get_visible_rect().size.x
	if event is InputEventScreenTouch:
		var e := event as InputEventScreenTouch
		if e.pressed:
			if _over_button(e.position):
				return
			if e.position.x < w * 0.45 and joy_touch == -1:
				joy_touch = e.index
				joy_origin = e.position
				joy_base.position = e.position - joy_base.size * 0.5
				joy_knob.position = e.position - joy_knob.size * 0.5
				joy_base.visible = true
				joy_knob.visible = true
			elif e.position.x >= w * 0.45 and look_touch == -1:
				look_touch = e.index
		else:
			if e.index == joy_touch:
				joy_touch = -1
				joy_base.visible = false
				joy_knob.visible = false
				player.set("move_input", Vector2.ZERO)
			elif e.index == look_touch:
				look_touch = -1
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		if d.index == joy_touch:
			var v: Vector2 = d.position - joy_origin
			var l: float = minf(v.length(), JOY_R)
			var dv: Vector2 = v.normalized() * l
			joy_knob.position = joy_origin + dv - joy_knob.size * 0.5
			player.set("move_input", dv / JOY_R)
		elif d.index == look_touch:
			var cur: Vector2 = player.get("look_delta")
			player.set("look_delta", cur + d.relative * 0.0055)


func _process(delta: float) -> void:
	_acc += delta
	if player != null and world != null and map_marker != null:
		var p: Vector3 = (player as Node3D).global_position
		var u: float = (p.x + 1024.0) / 2048.0
		var v: float = (p.z + 1024.0) / 2048.0
		map_marker.position = map_rect.position + Vector2(u, v) * map_rect.size - map_marker.size * 0.5
	if _acc < 0.25 or player == null:
		return
	_acc = 0.0
	var p3: Vector3 = (player as Node3D).global_position
	var t: float = float(atmos.get("time_of_day")) if atmos != null else 0.0
	var q: Array = ["Low", "Medium", "High"]
	info.text = "FPS %d   draw calls %d   tris %dk\nX %.0f  Y %.0f  Z %.0f   time %02d:%02d   quality: %s%s" % [
		Engine.get_frames_per_second(),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000.0),
		p3.x, p3.y, p3.z, int(t), int((t - floor(t)) * 60.0), q[int(world.get("quality"))] if world != null else "-",
		"   [FLY]" if bool(player.get("fly")) else ""]
