@tool
class_name AetheriaAtmosphere
extends Node
## Sky (procedural anime clouds), sun, fog, ambient and day/night cycle. Mobile friendly.

@export_range(0.0, 24.0, 0.01) var time_of_day: float = 15.5:
	set(v):
		time_of_day = fposmod(v, 24.0)
		if env != null:
			_apply()
@export var auto_advance: bool = true
@export var day_length_minutes: float = 16.0
@export_range(0.0, 1.0, 0.01) var cloud_cover: float = 0.55
@export var glow: bool = false

var env: Environment = null
var we: WorldEnvironment = null
var sun: DirectionalLight3D = null
var sky_mat: ShaderMaterial = null
var glass_lit: Material = null
var _clouds: Vector2 = Vector2.ZERO
var _acc: float = 1.0
var night_factor: float = 0.0


func _ready() -> void:
	_build()
	_apply()


func _build() -> void:
	we = WorldEnvironment.new()
	we.name = "WorldEnvironment"
	add_child(we)
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/sky.gdshader")
	sky_mat.set_shader_parameter("noise_tex", load("res://assets/textures/noise_tile.png"))
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_REALTIME
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.fog_enabled = true
	env.fog_density = 0.00085
	env.fog_sky_affect = 0.25
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.12
	env.adjustment_contrast = 1.04
	env.glow_enabled = glow
	env.glow_intensity = 0.5
	env.glow_bloom = 0.05
	we.environment = env
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 140.0
	sun.directional_shadow_split_1 = 0.22
	sun.shadow_blur = 1.4
	sun.light_angular_distance = 0.4
	add_child(sun)
	if ResourceLoader.exists("res://materials/glass_lit.tres"):
		glass_lit = load("res://materials/glass_lit.tres")


func _ramp(a: Color, b: Color, t: float) -> Color:
	return a.lerp(b, clampf(t, 0.0, 1.0))


func _apply() -> void:
	if env == null or sun == null:
		return
	var ang: float = (time_of_day - 6.0) / 24.0 * TAU
	var dir := Vector3(cos(ang), sin(ang) * 0.92, 0.35).normalized()
	var elev: float = dir.y
	var day: float = smoothstep(0.0, 0.5, elev)
	var night: float = 1.0 - smoothstep(-0.25, 0.05, elev)
	var twi: float = clampf(1.0 - day - night, 0.0, 1.0)
	night_factor = night
	var zen: Color = Color(0.22, 0.45, 0.85) * day + Color(0.28, 0.33, 0.62) * twi + Color(0.015, 0.03, 0.10) * night
	var hor: Color = Color(0.72, 0.84, 0.95) * day + Color(1.0, 0.62, 0.40) * twi + Color(0.07, 0.11, 0.22) * night
	var grd: Color = Color(0.35, 0.40, 0.35) * day + Color(0.30, 0.25, 0.25) * twi + Color(0.03, 0.04, 0.07) * night
	var suncol: Color = Color(1.0, 0.96, 0.86) * day + Color(1.0, 0.55, 0.30) * twi + Color(0.55, 0.65, 1.0) * night
	var amb: Color = Color(0.58, 0.68, 0.85) * day + Color(0.55, 0.45, 0.55) * twi + Color(0.10, 0.15, 0.30) * night
	sky_mat.set_shader_parameter("sun_dir", dir if elev > -0.05 else -dir)
	sky_mat.set_shader_parameter("zenith_color", zen)
	sky_mat.set_shader_parameter("horizon_color", hor)
	sky_mat.set_shader_parameter("ground_color", grd)
	sky_mat.set_shader_parameter("sun_color", suncol * (1.0 - night * 0.85))
	sky_mat.set_shader_parameter("cloud_light", Color(1, 1, 1) * day + Color(1.0, 0.75, 0.65) * twi + Color(0.20, 0.25, 0.40) * night)
	sky_mat.set_shader_parameter("cloud_shade", Color(0.58, 0.65, 0.80) * day + Color(0.55, 0.42, 0.55) * twi + Color(0.06, 0.08, 0.16) * night)
	sky_mat.set_shader_parameter("cloud_cover", cloud_cover)
	sky_mat.set_shader_parameter("stars", night)
	env.ambient_light_color = amb
	env.ambient_light_energy = 0.55 + 0.45 * day + 0.2 * twi
	env.fog_light_color = hor.lerp(zen, 0.15)
	var light_dir: Vector3 = -dir if elev > -0.05 else dir
	sun.basis = Basis.looking_at(light_dir, Vector3.UP)
	sun.light_color = suncol
	sun.light_energy = clampf(elev * 1.6, 0.0, 1.25) if elev > 0.0 else 0.12 * night
	sun.shadow_enabled = elev > 0.02
	if glass_lit != null:
		glass_lit.set("emission_energy_multiplier", night * 2.4 + twi * 1.0)


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if auto_advance:
		time_of_day += delta * 24.0 / (day_length_minutes * 60.0)
	_clouds += Vector2(delta * 0.0035, delta * 0.0012)
	if sky_mat != null:
		sky_mat.set_shader_parameter("cloud_offset", _clouds)
	_acc += delta
	if _acc >= 0.12:
		_acc = 0.0
		var t: float = float(Time.get_ticks_msec()) / 1000.0
		for l in get_tree().get_nodes_in_group("night_lights"):
			var base: float = float(l.get_meta("base_energy", 1.0))
			var k: float = 0.12 + 0.88 * night_factor
			if l.is_in_group("flicker"):
				k = 0.9 + 0.1 * night_factor
				k *= 1.0 + 0.10 * sin(t * 11.0 + float(l.get_instance_id() % 17)) + 0.05 * sin(t * 23.0)
			l.light_energy = base * k
