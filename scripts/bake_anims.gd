extends SceneTree
## Запекает анимации из UAL1/UAL2 на скелет char_male_base и сохраняет AnimationLibrary.

const SRC_PATHS := ["res://assets/anim/UAL1_Standard.glb", "res://assets/anim/UAL2_Standard.glb"]
const CHAR_PATH := "res://assets/char/char_male_base.glb"
const OUT_PATH := "res://assets/char/aetheria_anims.res"
const FPS := 30.0

const MAP := {
	"pelvis": "Hips", "spine_01": "Spine", "spine_02": "Chest", "spine_03": "UpperChest",
	"neck_01": "Neck", "Head": "Head",
	"clavicle_l": "LeftShoulder", "upperarm_l": "LeftUpperArm", "lowerarm_l": "LeftLowerArm", "hand_l": "LeftHand",
	"clavicle_r": "RightShoulder", "upperarm_r": "RightUpperArm", "lowerarm_r": "RightLowerArm", "hand_r": "RightHand",
	"thigh_l": "LeftUpperLeg", "calf_l": "LeftLowerLeg", "foot_l": "LeftFoot", "ball_l": "LeftToes",
	"thigh_r": "RightUpperLeg", "calf_r": "RightLowerLeg", "foot_r": "RightFoot", "ball_r": "RightToes",
	"index_01_l": "LeftIndexProximal", "index_02_l": "LeftIndexIntermediate", "index_03_l": "LeftIndexDistal",
	"middle_01_l": "LeftMiddleProximal", "middle_02_l": "LeftMiddleIntermediate", "middle_03_l": "LeftMiddleDistal",
	"ring_01_l": "LeftRingProximal", "ring_02_l": "LeftRingIntermediate", "ring_03_l": "LeftRingDistal",
	"pinky_01_l": "LeftLittleProximal", "pinky_02_l": "LeftLittleIntermediate", "pinky_03_l": "LeftLittleDistal",
	"thumb_01_l": "LeftThumbMetacarpal", "thumb_02_l": "LeftThumbProximal", "thumb_03_l": "LeftThumbDistal",
	"index_01_r": "RightIndexProximal", "index_02_r": "RightIndexIntermediate", "index_03_r": "RightIndexDistal",
	"middle_01_r": "RightMiddleProximal", "middle_02_r": "RightMiddleIntermediate", "middle_03_r": "RightMiddleDistal",
	"ring_01_r": "RightRingProximal", "ring_02_r": "RightRingIntermediate", "ring_03_r": "RightRingDistal",
	"pinky_01_r": "RightLittleProximal", "pinky_02_r": "RightLittleIntermediate", "pinky_03_r": "RightLittleDistal",
	"thumb_01_r": "RightThumbMetacarpal", "thumb_02_r": "RightThumbProximal", "thumb_03_r": "RightThumbDistal",
}


func _initialize() -> void:
	var char_scene: Node = (load(CHAR_PATH) as PackedScene).instantiate()
	var tgt := _find_skel(char_scene)
	if tgt == null:
		push_error("нет скелета персонажа")
		quit(1)
		return
	var rest_tgt := _rest_global(tgt)
	var prefix := _skeleton_path(char_scene, tgt)
	var lib := AnimationLibrary.new()
	var total := 0
	for p in SRC_PATHS:
		var inst: Node = (load(p) as PackedScene).instantiate()
		var src := _find_skel(inst)
		var ap := _find_anim(inst)
		if src == null or ap == null:
			continue
		var rest_src := _rest_global(src)
		for an in ap.get_animation_list():
			var a: Animation = ap.get_animation(an)
			if String(an).ends_with("TPose"):
				continue
			var out := _retarget(a, src, tgt, rest_src, rest_tgt, prefix)
			if out == null:
				continue
			lib.add_animation(String(an), out)
			total += 1
		inst.free()
	print("BAKE anims=", total)
	var err := ResourceSaver.save(lib, OUT_PATH)
	print("BAKE saved err=", err, " -> ", OUT_PATH)


func _skeleton_path(root: Node, sk: Skeleton3D) -> String:
	# путь вида "Male_Base/Skeleton3D" — от корня сцены персонажа (root_node AnimationPlayer = "..")
	var ap := _find_anim(root)
	if ap != null:
		for n in ap.get_animation_list():
			var a: Animation = ap.get_animation(String(n))
			for t in a.get_track_count():
				if a.track_get_type(t) != Animation.TYPE_ROTATION_3D:
					continue
				var path: NodePath = a.track_get_path(t)
				if path.get_subname_count() == 0 or path.get_name_count() == 0:
					continue
				var parts := []
				for i in path.get_name_count():
					parts.append(String(path.get_name(i)))
				return "/".join(parts)
	var rel := String(root.get_path_to(sk))
	return rel if rel != "" else "Skeleton3D"


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := _find_skel(c)
		if s != null:
			return s
	return null


func _find_anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var a := _find_anim(c)
		if a != null:
			return a
	return null


func _rest_global(sk: Skeleton3D) -> Array:
	var out := []
	out.resize(sk.get_bone_count())
	for i in sk.get_bone_count():
		var local: Quaternion = sk.get_bone_rest(i).basis.get_rotation_quaternion()
		var p := sk.get_bone_parent(i)
		out[i] = (out[p] if p >= 0 else Quaternion.IDENTITY) * local
	return out


func _track_samples(a: Animation, src: Skeleton3D) -> Dictionary:
	# bone_name -> {times: PackedFloat32Array, quats: Array[Quaternion]}
	var res := {}
	for ti in a.get_track_count():
		if a.track_get_type(ti) == Animation.TYPE_POSITION_3D:
			var p2: NodePath = a.track_get_path(ti)
			if p2.get_subname_count() == 0:
				continue
			var bn := String(p2.get_subname(0))
			var bi2 := src.find_bone(bn)
			if bi2 < 0:
				continue
			var tms := []
			var vals := []
			for k in a.track_get_key_count(ti):
				tms.append(a.track_get_key_time(ti, k))
				var v = a.track_get_key_value(ti, k)
				if v is Vector3:
					vals.append(v)
				else:
					vals.append(Vector3.ZERO)
			res["pos_" + str(bi2)] = {"t": tms, "v": vals}
			continue
		if a.track_get_type(ti) != Animation.TYPE_ROTATION_3D:
			continue
		var path: NodePath = a.track_get_path(ti)
		if path.get_subname_count() == 0:
			continue
		var bone_name := String(path.get_subname(0))
		var bi := src.find_bone(bone_name)
		if bi < 0:
			continue
		var cnt := a.track_get_key_count(ti)
		var times := []
		var quats := []
		for k in cnt:
			times.append(a.track_get_key_time(ti, k))
			var qv = a.track_get_key_value(ti, k)
			if qv is Quaternion:
				quats.append(qv)
			elif qv is Array and qv.size() == 4:
				quats.append(Quaternion(qv[0], qv[1], qv[2], qv[3]))
			else:
				quats.append(Quaternion.IDENTITY)
		res[bi] = {"t": times, "q": quats}
	return res


func _rest_hip_height(sk: Skeleton3D, bone: int) -> float:
	var acc := Vector3.ZERO
	var b := bone
	while b >= 0:
		acc += sk.get_bone_rest(b).origin
		b = sk.get_bone_parent(b)
	return acc.length()


func _sample_pos(track: Dictionary, time: float) -> Vector3:
	var times: Array = track["t"]
	var vals: Array = track["v"]
	if times.is_empty():
		return Vector3.ZERO
	if time <= float(times[0]):
		return vals[0]
	var last := times.size() - 1
	if time >= float(times[last]):
		return vals[last]
	for i in range(1, last + 1):
		if time <= float(times[i]):
			var t0 := float(times[i - 1])
			var t1 := float(times[i])
			var w: float = 0.0 if t1 - t0 <= 0.0001 else (time - t0) / (t1 - t0)
			return (vals[i - 1] as Vector3).lerp(vals[i], w)
	return vals[last]


func _sample(track: Dictionary, time: float) -> Quaternion:
	var times: Array = track["t"]
	var quats: Array = track["q"]
	if times.is_empty():
		return Quaternion.IDENTITY
	if time <= float(times[0]):
		return quats[0]
	var last := times.size() - 1
	if time >= float(times[last]):
		return quats[last]
	for i in range(1, last + 1):
		if time <= float(times[i]):
			var t0 := float(times[i - 1])
			var t1 := float(times[i])
			var w: float = 0.0 if t1 - t0 <= 0.0001 else (time - t0) / (t1 - t0)
			return (quats[i - 1] as Quaternion).slerp(quats[i], w)
	return quats[last]


func _retarget(a: Animation, src: Skeleton3D, tgt: Skeleton3D, rest_src: Array, rest_tgt: Array, prefix: String) -> Animation:
	var tracks := _track_samples(a, src)
	if tracks.is_empty():
		return null
	var length: float = maxf(a.length, 0.05)
	var steps: int = clampi(int(length * FPS) + 1, 2, 240)
	var dt: float = length / float(steps - 1)
	var out := Animation.new()
	out.length = length

	var src_order := []
	for i in src.get_bone_count():
		src_order.append(i)

	var anim_src := {}
	for key in tracks.keys():
		if typeof(key) == TYPE_STRING and String(key).begins_with("pos_"):
			continue
		anim_src[int(key)] = true

	# соответствие: целевая кость -> кость источника
	var tgt_to_src := {}
	for k in MAP.keys():
		var sb := src.find_bone(String(k))
		var tb := tgt.find_bone(String(MAP[k]))
		if sb >= 0 and tb >= 0:
			tgt_to_src[tb] = sb

	var out_rot := {}
	var hips_frames: Array = []      # мировое смещение таза источника по кадрам
	var hips_parent_rot: Array = []  # мировой поворот родителя таза цели по кадрам
	var pelvis := src.find_bone("pelvis")
	var hips := tgt.find_bone("Hips")
	var hips_parent := tgt.get_bone_parent(hips) if hips >= 0 else -1
	var rest_pelvis_world := _world_pos_rest(src, pelvis)

	for s in steps:
		var t: float = float(s) * dt
		var w_src := {}
		var p_src := {}
		for bi in src_order:
			var parent := src.get_bone_parent(bi)
			var pw: Quaternion = w_src[parent] if w_src.has(parent) else Quaternion.IDENTITY
			var pp: Vector3 = p_src[parent] if p_src.has(parent) else Vector3.ZERO
			var local: Quaternion = src.get_bone_rest(bi).basis.get_rotation_quaternion()
			var tr: Vector3 = src.get_bone_rest(bi).origin
			if anim_src.has(bi):
				local = _sample(tracks[bi], t)
			var pk := "pos_" + str(bi)
			if tracks.has(pk):
				tr = _sample_pos(tracks[pk], t)
			w_src[bi] = pw * local
			p_src[bi] = pp + pw * tr

		var w_tgt := {}
		for ti in tgt.get_bone_count():
			var parent_t := tgt.get_bone_parent(ti)
			var pw_t: Quaternion = w_tgt[parent_t] if w_tgt.has(parent_t) else Quaternion.IDENTITY
			var world: Quaternion = rest_tgt[ti]
			if tgt_to_src.has(ti):
				var sb2: int = tgt_to_src[ti]
				var delta: Quaternion = w_src[sb2] * (rest_src[sb2] as Quaternion).inverse()
				world = delta * (rest_tgt[ti] as Quaternion)
				if not out_rot.has(ti):
					out_rot[ti] = []
				(out_rot[ti] as Array).append(pw_t.inverse() * world)
			w_tgt[ti] = world

		if pelvis >= 0 and hips >= 0:
			hips_frames.append((p_src[pelvis] as Vector3) - rest_pelvis_world)
			hips_parent_rot.append(w_tgt[hips_parent] if (hips_parent >= 0 and w_tgt.has(hips_parent)) else Quaternion.IDENTITY)

	for ti in out_rot.keys():
		var quats: Array = out_rot[ti]
		if quats.size() < 2:
			continue
		var track_idx := out.add_track(Animation.TYPE_ROTATION_3D)
		out.track_set_path(track_idx, NodePath(prefix + ":" + tgt.get_bone_name(ti)))
		out.track_set_interpolation_type(track_idx, Animation.INTERPOLATION_LINEAR)
		for s in quats.size():
			out.rotation_track_insert_key(track_idx, float(s) * dt, quats[s])

	# --- смещение таза: тело должно качаться, иначе ноги ходят под стоящим туловищем
	if pelvis >= 0 and hips >= 0 and hips_frames.size() == steps:
		var hs: float = _rest_hip_height(src, pelvis)
		var ht: float = _rest_hip_height(tgt, hips)
		var k2: float = (ht / hs) if hs > 0.001 else 1.0
		var rest_tgt_p: Vector3 = tgt.get_bone_rest(hips).origin
		var pidx := out.add_track(Animation.TYPE_POSITION_3D)
		out.track_set_path(pidx, NodePath(prefix + ":" + tgt.get_bone_name(hips)))
		out.track_set_interpolation_type(pidx, Animation.INTERPOLATION_LINEAR)
		for s in steps:
			var delta_w: Vector3 = hips_frames[s] * k2
			var prot: Quaternion = hips_parent_rot[s]
			out.position_track_insert_key(pidx, float(s) * dt, rest_tgt_p + prot.inverse() * delta_w)

	out.loop_mode = Animation.LOOP_LINEAR
	return out


func _world_pos_rest(sk: Skeleton3D, bone: int) -> Vector3:
	var pos := Vector3.ZERO
	var q := Quaternion.IDENTITY
	var chain := []
	var b := bone
	while b >= 0:
		chain.push_front(b)
		b = sk.get_bone_parent(b)
	for i in chain:
		pos += q * sk.get_bone_rest(i).origin
		q = q * sk.get_bone_rest(i).basis.get_rotation_quaternion()
	return pos
