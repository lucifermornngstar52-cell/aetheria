@tool
class_name AetheriaWorld
extends Node3D
## Builds the Aetheria open world at load time from baked GLB chunks + instance data.
## @tool: open scenes/main.tscn in the editor and the whole map appears in the 3D viewport.

signal built

const MANIFEST_PATH := "res://world/world_manifest.json"
const WORLD_GLB := "res://world/world.glb"
const CASTLE_SCENE := "res://assets/models/castle_v2.glb"

## LOD деревьев: вблизи полная модель, дальше дешёвый конус-заглушка, ещё дальше не рисуем
const TREE_NEAR := 190.0
const TREE_MID := 520.0
const TREE_LOD_SCALE := 0.58
const MAT_DIR := "res://materials/"
const MAT_NAMES := ["terrain", "water", "leaf", "plaster", "stone", "wood", "roof", "thatch", "glass", "glass_lit", "metal", "cloth", "cobble", "bark", "rock", "fire", "rune", "cave_dark", "occ"]

@export_enum("Low", "Medium", "High") var quality: int = 2:
	set(v):
		quality = v
		_apply_quality()
@export var build_in_editor: bool = true
@export var build_collision: bool = true
@export var build_markers: bool = true
@export var dynamic_grass: bool = true
@export var glb_world: bool = true   ## новый мир одним GLB (world/world.glb) вместо нарезки на чанки
@export var castle_enabled: bool = true
@export var veg_cell: float = 512.0     ## размер клетки для отсечения растительности
@export var castle_position := Vector3(-560.0, 141.0, -560.0)
@export var castle_scale: float = 0.16

var manifest: Dictionary = {}
var heights: PackedFloat32Array = PackedFloat32Array()
var grass_mask: PackedByteArray = PackedByteArray()
var samples: int = 513
var half: float = 1024.0
var step: float = 4.0
var mats: Dictionary = {}
var lib_meshes: Dictionary = {}
var inst_bytes: PackedByteArray = PackedByteArray()
var cells: Dictionary = {}
var inst_root: Node3D = null
var is_built: bool = false
var _range_scale: float = 1.0
var _density: float = 1.0
var _ranged: Array = []
var _veg_batches: Array = []   # [{node, base_end, group}] — дальность прорисовки под качество
var _acc: float = 0.5


func _ready() -> void:
	add_to_group("world")
	print("AETHERIA BOOT")
	if Engine.is_editor_hint() and not build_in_editor:
		return
	await get_tree().process_frame
	build()
	if not Engine.is_editor_hint() and DisplayServer.get_name() == "headless":
		await get_tree().process_frame
		print("AETHERIA READY chunks=%d structures=%d heights=%d" % [
			manifest.get("chunks", []).size(),
			manifest.get("structures", []).size(),
			heights.size()
		])
		var pl = get_tree().get_first_node_in_group("player")
		if pl:
			print("AETHERIA PLAYER y=%.2f" % pl.global_position.y)


func build() -> void:
	is_built = false
	for c in get_children():
		c.queue_free()
	_ranged.clear()
	cells.clear()
	lib_meshes.clear()
	var txt := FileAccess.get_file_as_string(MANIFEST_PATH)
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Aetheria: cannot read " + MANIFEST_PATH)
		return
	manifest = parsed
	samples = int(manifest.samples)
	half = float(manifest.half)
	step = float(manifest.step)
	heights = FileAccess.get_file_as_bytes(String(manifest.heightmap)).to_float32_array()
	grass_mask = FileAccess.get_file_as_bytes(String(manifest.grass_mask))
	_load_materials()
	_apply_quality_values()
	if glb_world and ResourceLoader.exists(WORLD_GLB):
		_build_from_glb()
	else:
		_build_terrain()
		await get_tree().process_frame
		_build_structures()
		await get_tree().process_frame
		_load_library()
		_load_instances()
	await get_tree().process_frame
	if not Engine.is_editor_hint():
		if build_collision:
			_build_collision()
		if build_markers:
			_build_markers()
		if dynamic_grass:
			_build_grass()
	is_built = true
	_apply_veg_ranges()
	_update_instances(_viewer_pos())
	if DisplayServer.get_name() == "headless":
		print("AETHERIA BUILD DONE nodes=%d" % _count_nodes(self))
	built.emit()


func _count_nodes(n: Node, out_acc: Array = [0]) -> int:
	out_acc[0] = int(out_acc[0]) + 1
	for c in n.get_children():
		_count_nodes(c, out_acc)
	return int(out_acc[0])


# ---------------------------------------------------------------- quality
func _apply_quality_values() -> void:
	match quality:
		0:
			_range_scale = 0.6
			_density = 0.5
		1:
			_range_scale = 0.8
			_density = 0.75
		_:
			_range_scale = 1.0
			_density = 1.0


func _apply_quality() -> void:
	_apply_quality_values()
	if is_built:
		_apply_ranges()
		refresh_instances()
		_apply_veg_ranges()


func _apply_veg_ranges() -> void:
	for b in _veg_batches:
		var mi = b["node"]
		if is_instance_valid(mi):
			mi.visibility_range_end = float(b["base_end"]) * _range_scale
			if int(b.get("lod", 0)) == 1:
				mi.visibility_range_begin = TREE_NEAR * _range_scale
	var vp := get_viewport()
	if vp != null:
		vp.msaa_3d = Viewport.MSAA_DISABLED if quality == 0 else Viewport.MSAA_2X
	var shadow_size: int = 1024 if quality == 0 else 2048
	RenderingServer.directional_shadow_atlas_set_size(shadow_size, quality > 0)
	# на минималках здания не бросают тени — самый дорогой проход
	for mi in get_tree().get_nodes_in_group("shadow_casters"):
		if is_instance_valid(mi):
			(mi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if quality == 0 else GeometryInstance3D.SHADOW_CASTING_SETTING_ON


func _set_range(mi: GeometryInstance3D, b: float, e: float) -> void:
	_ranged.append([mi, b, e])
	mi.visibility_range_begin = b * _range_scale
	mi.visibility_range_end = e * _range_scale if e > 0.0 else 0.0


func _apply_ranges() -> void:
	for r in _ranged:
		var mi = r[0]
		if is_instance_valid(mi):
			mi.visibility_range_begin = float(r[1]) * _range_scale
			mi.visibility_range_end = float(r[2]) * _range_scale if float(r[2]) > 0.0 else 0.0


# ---------------------------------------------------------------- materials
func _load_materials() -> void:
	mats.clear()
	for n in MAT_NAMES:
		var path: String = MAT_DIR + String(n) + ".tres"
		if ResourceLoader.exists(path):
			mats[n] = load(path)


func _resolve_material(nm: String) -> String:
	if mats.has(nm):
		return nm
	# leaf_sakura -> leaf, bark_pine -> bark, leaf_fern -> leaf, bark_birch -> bark
	if nm.begins_with("leaf") and mats.has("leaf"):
		return "leaf"
	if nm.begins_with("bark") and mats.has("bark"):
		return "bark"
	if nm.begins_with("rock") and mats.has("rock"):
		return "rock"
	if nm.begins_with("stone") and mats.has("stone"):
		return "stone"
	return ""


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


func _apply_materials(root: Node) -> void:
	for mi in _meshes_of(root):
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var nm := _surface_material_name(mesh, i)
			var key := _resolve_material(nm)
			if key != "":
				(mi as MeshInstance3D).set_surface_override_material(i, mats[key])


# ---------------------------------------------------------------- terrain
func _build_terrain() -> void:
	var root := Node3D.new()
	root.name = "Terrain"
	add_child(root)
	var lods: Array = manifest.terrain_lods
	for ch in manifest.chunks:
		var scn := load(String(ch.path)) as PackedScene
		if scn == null:
			continue
		var inst := scn.instantiate()
		root.add_child(inst)
		_apply_materials(inst)
		for mi in _meshes_of(inst):
			var g := mi as MeshInstance3D
			var nm := String(g.name)
			if nm.begins_with("LOD"):
				var L: Dictionary = lods[int(nm.substr(3))]
				_set_range(g, float(L.begin), float(L.end))
				g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if nm == "LOD0" else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			elif nm == "Water":
				g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				_set_range(g, 0.0, 1500.0)


func _build_from_glb() -> void:
	var root := Node3D.new()
	root.name = "World"
	add_child(root)
	var inst: Node = null
	var ps = ResourceLoader.load(WORLD_GLB)
	if ps is PackedScene:
		inst = (ps as PackedScene).instantiate()
	else:
		# фолбэк: грузим GLB напрямую, без импорта редактором
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		var err := doc.append_from_file(WORLD_GLB, state)
		if err == OK:
			inst = doc.generate_scene(state)
		else:
			push_error("Aetheria: cannot open " + WORLD_GLB + " err=" + str(err))
	if inst == null:
		push_error("Aetheria: GLB world not loaded from " + WORLD_GLB)
		return
	root.add_child(inst)
	# материалы и текстуры берём из самой карты — ничего не перекрашиваем
	_tune_glb_meshes(inst)
	_batch_vegetation(inst)
	if castle_enabled:
		_add_castle(root)
	print("AETHERIA GLB WORLD loaded")


func _add_castle(root: Node3D) -> void:
	if not ResourceLoader.exists(CASTLE_SCENE):
		return
	var ps = ResourceLoader.load(CASTLE_SCENE)
	if not (ps is PackedScene):
		push_warning("Aetheria: castle not loaded")
		return
	var c: Node3D = (ps as PackedScene).instantiate()
	c.name = "SkyCastle"
	c.position = castle_position
	c.scale = Vector3.ONE * castle_scale
	root.add_child(c)
	var m := Marker3D.new()
	m.name = "SkyCastlePOI"
	m.position = castle_position
	m.add_to_group("poi")
	m.add_to_group("poi_landmark")
	m.set_meta("kind", "landmark")
	m.set_meta("poi_name", "Sky Castle")
	root.add_child(m)
	print("AETHERIA CASTLE placed")


func _batch_vegetation(root: Node) -> void:
	const GROUP_RANGE := {"Trees": 520.0, "Rocks": 600.0, "Undergrowth": 220.0, "Water": 2600.0}
	_veg_batches.clear()
	for group_name in GROUP_RANGE.keys():
		var g := root.find_child(String(group_name), true, false)
		if g == null:
			continue
		var is_trees: bool = String(group_name) == "Trees"
		# --- 1. полные модели по клеткам (вблизи)
		var cells := {}
		for c in g.get_children():
			if not (c is MeshInstance3D):
				continue
			var mi := c as MeshInstance3D
			if mi.mesh == null:
				continue
			var p: Vector3 = mi.global_position
			var cx := int(floor((p.x + 1024.0) / veg_cell))
			var cz := int(floor((p.z + 1024.0) / veg_cell))
			var key := "%d_%d_%d" % [mi.mesh.get_instance_id(), cx, cz]
			if not cells.has(key):
				cells[key] = {"mesh": mi.mesh, "xf": [], "mat": mi.material_override, "cx": cx, "cz": cz}
			(cells[key]["xf"] as Array).append(mi.global_transform)
		var made := 0
		var total := 0
		for key in cells.keys():
			var b: Dictionary = cells[key]
			var xfs: Array = b["xf"]
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = b["mesh"]
			mm.instance_count = xfs.size()
			for i in xfs.size():
				mm.set_instance_transform(i, xfs[i])
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "%s_%d_%d" % [String(group_name), int(b["cx"]), int(b["cz"])]
			mmi.multimesh = mm
			mmi.material_override = b["mat"]
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var rng: float = float(GROUP_RANGE[String(group_name)])
			if is_trees:
				mmi.visibility_range_end = TREE_NEAR * _range_scale
				mmi.visibility_range_end_margin = 20.0
			else:
				mmi.visibility_range_end = rng * _range_scale
				mmi.visibility_range_end_margin = 40.0
			mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			g.add_child(mmi)
			_veg_batches.append({"node": mmi, "base_end": TREE_NEAR if is_trees else rng, "group": String(group_name), "lod": 0})
			made += 1
			total += xfs.size()
		# --- 2. прокси-конусы для дерева вдалеке (одна куча на клетку)
		if is_trees:
			var pcell := {}
			for c in g.get_children():
				if not (c is MeshInstance3D):
					continue
				var mi2 := c as MeshInstance3D
				if mi2.mesh == null:
					continue
				var p2: Vector3 = mi2.global_position
				var cx2 := int(floor((p2.x + 1024.0) / 128.0))
				var cz2 := int(floor((p2.z + 1024.0) / 128.0))
				var key2 := "%d_%d" % [cx2, cz2]
				if not pcell.has(key2):
					pcell[key2] = {"cx": cx2, "cz": cz2, "items": []}
				var aabb: AABB = mi2.mesh.get_aabb()
				var h: float = clampf(aabb.size.y, 2.0, 40.0)
				var r: float = clampf(maxf(aabb.size.x, aabb.size.z) * 0.40, 0.4, 8.0)
				var tint := _avg_tint(String((mi2.material_override as StandardMaterial3D).resource_name) if mi2.material_override is StandardMaterial3D else "")
				(pcell[key2]["items"] as Array).append({"p": p2, "h": h, "r": r, "c": tint})
			var proxy_mesh: Mesh = _proxy_mesh()
			var pmat: Material = _proxy_material(null)
			var pmade := 0
			for key2 in pcell.keys():
				var d: Dictionary = pcell[key2]
				var items: Array = d["items"]
				var cnt := 0
				for it in items:
					if not (it["p"] as Vector3).is_zero_approx():
						cnt += 1
				if cnt == 0:
					continue
				var mm2 := MultiMesh.new()
				mm2.transform_format = MultiMesh.TRANSFORM_3D
				mm2.use_colors = true
				mm2.mesh = proxy_mesh
				mm2.instance_count = cnt
				var i2 := 0
				for it in items:
					var pp: Vector3 = it["p"]
					var hh: float = float(it["h"])
					var rr: float = float(it["r"])
					var xf := Transform3D(Basis().scaled(Vector3(rr, hh, rr)), pp + Vector3(0.0, hh * 0.5, 0.0))
					mm2.set_instance_transform(i2, xf)
					mm2.set_instance_color(i2, it["c"])
					i2 += 1
				var mmi2 := MultiMeshInstance3D.new()
				mmi2.name = "Trees_proxy_%d_%d" % [int(d["cx"]), int(d["cz"])]
				mmi2.multimesh = mm2
				mmi2.material_override = pmat
				mmi2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				mmi2.visibility_range_begin = TREE_NEAR * _range_scale
				mmi2.visibility_range_end = TREE_MID * _range_scale
				mmi2.visibility_range_begin_margin = 20.0
				mmi2.visibility_range_end_margin = 40.0
				mmi2.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
				g.add_child(mmi2)
				_veg_batches.append({"node": mmi2, "base_end": TREE_MID, "group": "Trees", "lod": 1})
				pmade += 1
			print("AETHERIA VEG Trees proxies=", pmade)
		for c in g.get_children():
			if c is MeshInstance3D:
				c.queue_free()
		print("AETHERIA VEG ", group_name, " instances=", total, " batches=", made)


func _proxy_mesh() -> Mesh:
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.1
	cyl.bottom_radius = 1.0
	cyl.height = 1.0
	cyl.radial_segments = 4
	cyl.rings = 1
	return cyl


func _avg_tint(name: String) -> Color:
	var n := name.to_lower()
	if n.contains("sakura"):
		return Color(0.88, 0.64, 0.72)
	if n.contains("birch"):
		return Color(0.58, 0.68, 0.44)
	if n.contains("pine"):
		return Color(0.16, 0.30, 0.20)
	if n.contains("autumn"):
		return Color(0.74, 0.50, 0.22)
	if n.contains("oak"):
		return Color(0.28, 0.44, 0.24)
	return Color(0.26, 0.42, 0.22)


func _proxy_material(src: Material) -> Material:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1, 1, 1)
	m.vertex_color_use_as_albedo = true
	m.roughness = 1.0
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return m


func _tune_glb_meshes(root: Node) -> void:
	for mi in _meshes_of(root):
		var g := mi as MeshInstance3D
		if g == null:
			continue
		var nm := String(g.name).to_lower()
		var par := String(g.get_parent().name).to_lower() if g.get_parent() != null else ""
		if nm.begins_with("water") or par.begins_with("water"):
			g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		elif par.begins_with("trees") or par.begins_with("undergrowth"):
			g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		elif par.begins_with("rocks"):
			g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		elif par.begins_with("structures"):
			g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			g.add_to_group("shadow_casters")
		else:
			g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _build_structures() -> void:
	var root := Node3D.new()
	root.name = "Structures"
	add_child(root)
	var rr: Dictionary = manifest.structure_ranges
	for s in manifest.structures:
		var scn := load(String(s.path)) as PackedScene
		if scn == null:
			continue
		var inst := scn.instantiate()
		root.add_child(inst)
		_apply_materials(inst)
		for mi in _meshes_of(inst):
			var g := mi as MeshInstance3D
			var nm := String(g.name)
			if nm.begins_with("Occluder"):
				g.visible = false   # fallback if the importer did not convert it to an OccluderInstance3D
				continue
			if rr.has(nm):
				var r: Array = rr[nm]
				_set_range(g, float(r[0]), float(r[1]))
			g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if nm == "HousesFar" else GeometryInstance3D.SHADOW_CASTING_SETTING_ON


# ---------------------------------------------------------------- instanced vegetation (streamed by distance)
func _load_library() -> void:
	var scn := load(String(manifest.library)) as PackedScene
	if scn == null:
		return
	var inst := scn.instantiate()
	for mi in _meshes_of(inst):
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var nm := _surface_material_name(mesh, i)
			if mats.has(nm):
				mesh.surface_set_material(i, mats[nm])
		lib_meshes[String(mi.name)] = mesh
	inst.free()


func _load_instances() -> void:
	inst_bytes = FileAccess.get_file_as_bytes(String(manifest.instances_file))
	cells.clear()
	for e in manifest.instances:
		var key := Vector2i(int(e.ci), int(e.cj))
		var sp: Dictionary = manifest.species[String(e.sp)]
		if not cells.has(key):
			cells[key] = []
		cells[key].append({"sp": String(e.sp), "off": int(e.off), "n": int(e.n), "lods": sp.lods, "shadow": bool(sp.shadow), "cur": -2, "node": null})
	inst_root = Node3D.new()
	inst_root.name = "Instances"
	add_child(inst_root)


func _density_for(sp: String) -> float:
	if sp.begins_with("rock") or sp.begins_with("boulder") or sp == "wheat":
		return 1.0
	return _density


func _make_mmi(e: Dictionary, li: int) -> MultiMeshInstance3D:
	var L: Dictionary = e.lods[li]
	var mesh: Mesh = lib_meshes.get(String(L.node))
	if mesh == null:
		return null
	var n: int = e.n
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = n
	mm.mesh = mesh
	var off: int = e.off
	mm.buffer = inst_bytes.slice(off, off + n * 64).to_float32_array()
	mm.visible_instance_count = maxi(1, int(ceil(float(n) * _density_for(String(e.sp)))))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	var shadows: bool = (li == 0 and bool(e.shadow))
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	inst_root.add_child(mmi)
	return mmi


func _update_instances(cam: Vector3) -> void:
	if inst_root == null:
		return
	var cs: float = float(manifest.cell_size)
	for key in cells:
		var x0: float = -half + float(key.x) * cs
		var z0: float = -half + float(key.y) * cs
		var dx: float = maxf(maxf(x0 - cam.x, 0.0), cam.x - (x0 + cs))
		var dz: float = maxf(maxf(z0 - cam.z, 0.0), cam.z - (z0 + cs))
		var d: float = sqrt(dx * dx + dz * dz)
		for e in cells[key]:
			var want: int = -1
			var lods: Array = e.lods
			for i in lods.size():
				var L: Dictionary = lods[i]
				var b: float = float(L.begin) * _range_scale
				var en: float = float(L.end) * _range_scale
				if d >= b and (en <= 0.0 or d < en):
					want = i
					break
			if want != int(e.cur):
				if e.node != null:
					(e.node as Node).queue_free()
					e.node = null
				if want >= 0:
					e.node = _make_mmi(e, want)
				e.cur = want


func refresh_instances() -> void:
	for key in cells:
		for e in cells[key]:
			if e.node != null:
				(e.node as Node).queue_free()
				e.node = null
			e.cur = -2
	_update_instances(_viewer_pos())


func _viewer_pos() -> Vector3:
	if manifest.is_empty():
		return Vector3.ZERO
	var sp: Array = manifest.spawn
	if Engine.is_editor_hint():
		return Vector3(sp[0], sp[1], sp[2])
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		return cam.global_position
	return Vector3(sp[0], sp[1], sp[2])


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or not is_built:
		return
	_acc += delta
	if _acc >= 0.5:
		_acc = 0.0
		_update_instances(_viewer_pos())


# ---------------------------------------------------------------- collision, markers, grass (runtime only)
func _build_collision() -> void:
	var body := StaticBody3D.new()
	body.name = "StructureColliders"
	for c in manifest.colliders:
		var cs := CollisionShape3D.new()
		if String(c[0]) == "box":
			var sh := BoxShape3D.new()
			sh.size = Vector3(float(c[4]), float(c[5]), float(c[6]))
			cs.shape = sh
			cs.transform = Transform3D(Basis(Vector3.UP, float(c[7])), Vector3(float(c[1]), float(c[2]), float(c[3])))
		else:
			var sh2 := CylinderShape3D.new()
			sh2.radius = float(c[4])
			sh2.height = float(c[5])
			cs.shape = sh2
			cs.position = Vector3(float(c[1]), float(c[2]) + float(c[5]) * 0.5, float(c[3]))
		body.add_child(cs)
	add_child(body)
	var per := 64
	var cps := int(manifest.chunks_per_side)
	var csz := float(manifest.chunk_size)
	var tb := StaticBody3D.new()
	tb.name = "TerrainCollision"
	for cz in cps:
		for cx in cps:
			var data := PackedFloat32Array()
			data.resize((per + 1) * (per + 1))
			for j in per + 1:
				var row := (cz * per + j) * samples + cx * per
				for i in per + 1:
					data[j * (per + 1) + i] = heights[row + i]
			var shape := HeightMapShape3D.new()
			shape.map_width = per + 1
			shape.map_depth = per + 1
			shape.map_data = data
			var cs2 := CollisionShape3D.new()
			cs2.shape = shape
			cs2.scale = Vector3(step, 1.0, step)
			cs2.position = Vector3(-half + (cx + 0.5) * csz, 0.0, -half + (cz + 0.5) * csz)
			tb.add_child(cs2)
	add_child(tb)


func _build_markers() -> void:
	var root := Node3D.new()
	root.name = "POI"
	add_child(root)
	for p in manifest.pois:
		var m := Marker3D.new()
		m.name = String(p.name).replace(" ", "_").replace("'", "").replace(":", "_").replace(".", "_")
		m.position = Vector3(float(p.x), float(p.y), float(p.z))
		m.rotation.y = float(p.get("ry", 0.0))
		m.add_to_group("poi")
		m.add_to_group("poi_" + String(p.kind))
		m.set_meta("kind", String(p.kind))
		m.set_meta("poi_name", String(p.name))
		root.add_child(m)
	var sp := Marker3D.new()
	sp.name = "PlayerSpawn"
	sp.position = Vector3(float(manifest.spawn[0]), float(manifest.spawn[1]), float(manifest.spawn[2]))
	sp.add_to_group("spawn")
	root.add_child(sp)
	var lroot := Node3D.new()
	lroot.name = "Lights"
	add_child(lroot)
	for l in manifest.lights:
		var o := OmniLight3D.new()
		o.position = Vector3(float(l.x), float(l.y), float(l.z))
		o.light_color = Color(float(l.color[0]), float(l.color[1]), float(l.color[2]))
		o.light_energy = float(l.energy)
		o.omni_range = float(l.range)
		o.shadow_enabled = false
		o.distance_fade_enabled = true
		o.distance_fade_begin = 90.0
		o.distance_fade_length = 40.0
		o.set_meta("base_energy", float(l.energy))
		o.add_to_group("night_lights")
		if bool(l.get("flicker", false)):
			o.add_to_group("flicker")
		lroot.add_child(o)


func _build_grass() -> void:
	var scr = load("res://scripts/grass_field.gd")
	if scr == null:
		return
	var g := Node3D.new()
	g.set_script(scr)
	g.name = "GrassField"
	add_child(g)
	g.call("setup", self)


# ---------------------------------------------------------------- queries for gameplay code
func height_at(x: float, z: float) -> float:
	if heights.is_empty():
		return 0.0
	var fi: float = (x + half) / step
	var fj: float = (z + half) / step
	var i: int = clampi(int(floor(fi)), 0, samples - 2)
	var j: int = clampi(int(floor(fj)), 0, samples - 2)
	var u: float = clampf(fi - float(i), 0.0, 1.0)
	var v: float = clampf(fj - float(j), 0.0, 1.0)
	var h00: float = heights[j * samples + i]
	var h10: float = heights[j * samples + i + 1]
	var h01: float = heights[(j + 1) * samples + i]
	var h11: float = heights[(j + 1) * samples + i + 1]
	if u >= v:
		return h00 + u * (h10 - h00) + v * (h11 - h10)
	return h00 + u * (h11 - h01) + v * (h01 - h00)


func grass_at(x: float, z: float) -> float:
	if grass_mask.is_empty():
		return 0.0
	var i: int = clampi(int(round((x + half) / step)), 0, samples - 1)
	var j: int = clampi(int(round((z + half) / step)), 0, samples - 1)
	return float(grass_mask[j * samples + i]) / 255.0
