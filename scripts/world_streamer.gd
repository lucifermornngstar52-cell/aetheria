extends Node3D
class_name AetheriaStreamer
## Настоящий стриминг: мир порезан на клетки 256 м и подгружается по мере приближения.
## Дальний рельеф держим всегда (он дешёвый), постройки и растительность грузим/освобождаем.

const CELL := 256.0
const HALF := 1024.0

var index: Dictionary = {}
var mats: Dictionary = {}
var lib_meshes: Dictionary = {}
var cells: Dictionary = {}          # coord -> {terrain, struct, veg, terrain_node, struct_node, veg_root, state, applied}
var queue: Array = []               # координаты клеток на загрузку (ближние первыми)
var loading: Dictionary = {}        # coord -> {"kind": "terrain"/"struct", "req": path}
var budget: int = 1                 # сколько клеток грузим за кадр
var view_terrain: float = 1000.0
var view_struct: float = 700.0
var view_veg: float = 520.0
var _acc: float = 0.0
var _warmup: int = 30
var _cam: Camera3D
var loaded_cells: int = 0


func setup(index_path: String, lib_path: String, materials: Dictionary) -> void:
	mats = materials
	var txt := FileAccess.get_file_as_string(index_path)
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Streamer: нет индекса клеток " + index_path)
		return
	index = parsed
	for key in index.get("cells", {}).keys():
		cells[String(key)] = {"data": index["cells"][key], "terrain_node": null, "struct_node": null,
			"veg_root": null, "state": 0}
	var lib = ResourceLoader.load(lib_path)
	var root: Node = null
	if lib is PackedScene:
		root = (lib as PackedScene).instantiate()
	if root != null:
		_collect_lib(root)
		root.free()
	print("AETHERIA STREAMER cells=", cells.size(), " lib meshes=", lib_meshes.size())


func _collect_lib(root: Node) -> void:
	for mi in _meshes_of(root):
		var g := mi as MeshInstance3D
		if g == null or g.mesh == null:
			continue
		var mesh := g.mesh
		for i in mesh.get_surface_count():
			var nm := _surface_material_name(mesh, i)
			var key := _resolve_material(nm)
			if key != "":
				mesh.surface_set_material(i, mats[key])
		lib_meshes[String(g.name)] = mesh


func _meshes_of(n: Node, out: Array = []) -> Array:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_meshes_of(c, out)
	return out


func _surface_material_name(mesh: Mesh, i: int) -> String:
	var m := mesh.surface_get_material(i)
	var nm := ""
	if m != null:
		nm = m.resource_name
	if nm == "" and mesh is ArrayMesh:
		nm = (mesh as ArrayMesh).surface_get_name(i)
	return nm


func _resolve_material(nm: String) -> String:
	if mats.has(nm):
		return nm
	if nm.begins_with("leaf") and mats.has("leaf"):
		return "leaf"
	if nm.begins_with("bark") and mats.has("bark"):
		return "bark"
	if nm.begins_with("rock") and mats.has("rock"):
		return "rock"
	if nm.begins_with("stone") and mats.has("stone"):
		return "stone"
	return ""


func set_view_distance(v: float) -> void:
	view_veg = v
	view_struct = maxf(v * 1.35, 420.0)


func _process(delta: float) -> void:
	_acc += delta
	if _warmup > 0:
		_warmup -= 1
		_acc = 1.0  # на старте стримим каждый кадр
	if _acc < 0.2:
		return
	_acc = 0.0
	_cam = get_viewport().get_camera_3d()
	if _cam == null:
		return
	_stream()


func _stream() -> void:
	var p: Vector3 = _cam.global_position
	var cxc := int(floor((p.x + HALF) / CELL))
	var czc := int(floor((p.z + HALF) / CELL))
	var wanted: Array = []
	for key in cells.keys():
		var parts = String(key).split("_")
		if parts.size() != 2:
			continue
		var cx := int(parts[0]); var cz := int(parts[1])
		var wx: float = -HALF + (float(cx) + 0.5) * CELL
		var wz: float = -HALF + (float(cz) + 0.5) * CELL
		var d: float = Vector2(wx - p.x, wz - p.z).length()
		var c: Dictionary = cells[key]
		# рельеф держим далеко, постройки и растительность — по дистанции
		var want_terrain: bool = d < view_terrain
		var want_detail: bool = d < view_struct
		var want_veg: bool = d < view_veg
		if want_terrain and int(c["state"]) == 0:
			wanted.append({"key": key, "d": d, "terrain": true, "struct": want_detail, "veg": want_veg})
		if int(c["state"]) > 0:
			if want_detail and c["struct_node"] == null and c["data"].has("struct"):
				_load_struct(key)
			if want_veg and c["veg_root"] == null and c["data"].has("veg"):
				_build_veg(key)
			if not want_veg and c["veg_root"] != null:
				(c["veg_root"] as Node).queue_free()
				c["veg_root"] = null
			if not want_detail and c["struct_node"] != null:
				(c["struct_node"] as Node).queue_free()
				c["struct_node"] = null
	wanted.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
	var lim := budget
	if not wanted.is_empty() and float(wanted[0]["d"]) < 320.0:
		lim = 4          # вплотную к игроку — грузим быстрее
	elif wanted.size() > 12:
		lim = 2
	var done := 0
	for w in wanted:
		if done >= lim:
			break
		if _load_terrain(String(w["key"])):
			done += 1


func _load_terrain(key: String) -> bool:
	var c: Dictionary = cells[key]
	var data: Dictionary = c["data"]
	if not data.has("terrain"):
		c["state"] = 1
		return true
	var ps = ResourceLoader.load(String(data["terrain"]))
	if not (ps is PackedScene):
		c["state"] = 1
		return true
	var node := (ps as PackedScene).instantiate()
	node.name = "cell_" + key
	_apply_materials(node)
	add_child(node)
	c["terrain_node"] = node
	c["state"] = 1
	loaded_cells += 1
	return true


func _load_struct(key: String) -> void:
	var c: Dictionary = cells[key]
	var data: Dictionary = c["data"]
	if not data.has("struct"):
		return
	var ps = ResourceLoader.load(String(data["struct"]))
	if not (ps is PackedScene):
		return
	var node := (ps as PackedScene).instantiate()
	node.name = "struct_" + key
	_apply_materials(node)
	add_child(node)
	c["struct_node"] = node


func _build_veg(key: String) -> void:
	var c: Dictionary = cells[key]
	var data: Dictionary = c["data"]
	if not data.has("veg"):
		return
	var txt := FileAccess.get_file_as_string(String(data["veg"]))
	var rows = JSON.parse_string(txt)
	if typeof(rows) != TYPE_ARRAY:
		return
	var grouped := {}
	for r in rows:
		var slot: int = int(r["m"])
		var name := "veg_" + str(slot)
		if not lib_meshes.has(name):
			continue
		if not grouped.has(name):
			grouped[name] = []
		var tr: Array = r["t"]; var rot: Array = r["r"]; var sc: Array = r["s"]
		var xf := Transform3D(
			Basis(Quaternion(float(rot[0]), float(rot[1]), float(rot[2]), float(rot[3]))).scaled(Vector3(float(sc[0]), float(sc[1]), float(sc[2]))),
			Vector3(float(tr[0]), float(tr[1]), float(tr[2])))
		(grouped[name] as Array).append(xf)
	var root := Node3D.new()
	root.name = "veg_" + key
	for name in grouped.keys():
		var xfs: Array = grouped[name]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = lib_meshes[name]
		mm.instance_count = xfs.size()
		for i in xfs.size():
			mm.set_instance_transform(i, xfs[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mmi)
	add_child(root)
	c["veg_root"] = root


func _apply_materials(node: Node) -> void:
	for mi in _meshes_of(node):
		var g := mi as MeshInstance3D
		var mesh: Mesh = g.mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var key := _resolve_material(_surface_material_name(mesh, i))
			if key != "":
				g.set_surface_override_material(i, mats[key])
