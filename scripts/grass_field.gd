extends Node3D
## Dynamic 3D grass: a ring of grass clumps (real geometry, MultiMesh) that follows the camera.
## Keeps the near field lush without storing millions of instances.

@export var radius: float = 44.0
@export var cell: float = 1.5
@export var min_grass: float = 0.55

var world: Node = null
var mm: MultiMesh = null
var mmi: MultiMeshInstance3D = null
var _last := Vector2(1.0e9, 1.0e9)
var _acc := 0.0
var _count := 0


func setup(w: Node) -> void:
	world = w
	var mesh: Mesh = w.lib_meshes.get("grass_LOD0")
	if mesh == null:
		return
	var n := int(ceil(radius * 2.0 / cell)) + 1
	_count = n * n
	mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = _count
	mm.mesh = mesh
	mmi = MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = AABB(Vector3(-4000, -500, -4000), Vector3(8000, 1500, 8000))
	add_child(mmi)
	set_process(true)


func _process(delta: float) -> void:
	if mm == null or world == null:
		return
	_acc += delta
	if _acc < 0.25:
		return
	_acc = 0.0
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var c := Vector2(cam.global_position.x, cam.global_position.z)
	if c.distance_to(_last) > 7.0:
		_last = c
		_rebuild(c)


func _hash(ix: int, iz: int, k: float) -> float:
	return fposmod(sin(float(ix) * 12.9898 + float(iz) * 78.233 + k) * 43758.5453, 1.0)


func _rebuild(c: Vector2) -> void:
	var n := int(ceil(radius * 2.0 / cell)) + 1
	var ix0 := int(floor((c.x - radius) / cell))
	var iz0 := int(floor((c.y - radius) / cell))
	var buf := PackedFloat32Array()
	buf.resize(_count * 16)
	var o := 0
	for j in n:
		for i in n:
			var ix := ix0 + i
			var iz := iz0 + j
			var x: float = (float(ix) + _hash(ix, iz, 1.7)) * cell
			var z: float = (float(iz) + _hash(ix, iz, 5.3)) * cell
			var dist: float = Vector2(x, z).distance_to(c)
			var g: float = world.grass_at(x, z)
			var s: float = 0.0
			if g >= min_grass and dist < radius:
				var fade: float = 1.0 - smoothstep(radius * 0.62, radius, dist)
				var dens: float = 0.55 + 0.45 * _hash(ix, iz, 9.1)
				if dens < 0.82:
					s = (0.75 + 0.6 * _hash(ix, iz, 3.3)) * fade * clampf((g - min_grass) * 4.0 + 0.4, 0.0, 1.0)
			var y: float = world.height_at(x, z) - 0.03
			var yaw: float = _hash(ix, iz, 7.7) * TAU
			var cy: float = cos(yaw) * s
			var sy: float = sin(yaw) * s
			buf[o + 0] = cy
			buf[o + 1] = 0.0
			buf[o + 2] = sy
			buf[o + 3] = x
			buf[o + 4] = 0.0
			buf[o + 5] = s
			buf[o + 6] = 0.0
			buf[o + 7] = y
			buf[o + 8] = -sy
			buf[o + 9] = 0.0
			buf[o + 10] = cy
			buf[o + 11] = z
			var t: float = 0.85 + 0.3 * _hash(ix, iz, 2.2)
			buf[o + 12] = t
			buf[o + 13] = t
			buf[o + 14] = 0.9 + 0.1 * t
			buf[o + 15] = 1.0
			o += 16
	while o < buf.size():
		buf[o] = 0.0
		o += 1
	mm.buffer = buf
