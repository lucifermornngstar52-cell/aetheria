#!/usr/bin/env python3
"""Режет world.glb на клетки 256 м: рельеф, постройки, растительность.
Текстуры не дублируются — материалы берутся из materials/*.tres по имени.
Результат: world/cells/*.gltf|bin, world/lib.gltf (геометрия растительности),
world/cells/index.json (что где лежит)."""
import json, struct, os, sys, math
import numpy as np

SRC = sys.argv[1] if len(sys.argv) > 1 else "world/world.glb"
OUT = "world/cells"
CELL = 256.0
HALF = 1024.0

def read_glb(path):
    d = open(path, "rb").read()
    clen, ctype = struct.unpack("<I4s", d[12:20])
    js = json.loads(d[20:20+clen])
    off = 12 + 8 + clen
    blen, btype = struct.unpack("<I4s", d[off:off+8])
    bin_data = d[off+8:off+8+blen]
    return js, bin_data

COMP = {5120: ("<i1", 1), 5121: ("<u1", 1), 5122: ("<i2", 2), 5123: ("<u2", 2), 5125: ("<u4", 4), 5126: ("<f4", 4)}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}

def accessor(js, bin_data, idx):
    a = js["accessors"][idx]
    bv = js["bufferViews"][a["bufferView"]]
    dt, esz = COMP[a["componentType"]]
    nc = NCOMP[a["type"]]
    start = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = bv.get("byteStride") or nc * esz
    if stride == nc * esz:
        arr = np.frombuffer(bin_data, dtype=dt, count=a["count"] * nc, offset=start).reshape(a["count"], nc)
    else:
        arr = np.zeros((a["count"], nc), dtype=dt)
        for i in range(a["count"]):
            arr[i] = np.frombuffer(bin_data, dtype=dt, count=nc, offset=start + i * stride)
    if a.get("normalized"):
        if a["componentType"] == 5121:
            arr = arr.astype(np.float64) / 255.0
        elif a["componentType"] == 5123:
            arr = arr.astype(np.float64) / 65535.0
        elif a["componentType"] == 5120:
            arr = np.maximum(arr.astype(np.float64) / 127.0, -1.0)
        elif a["componentType"] == 5122:
            arr = np.maximum(arr.astype(np.float64) / 32767.0, -1.0)
        return arr
    return arr.astype(np.float64) if a["componentType"] == 5126 else arr

def node_matrix(n):
    if "matrix" in n:
        return np.array(n["matrix"], dtype=np.float64).reshape(4, 4).T
    t = np.array(n.get("translation", [0, 0, 0]), dtype=np.float64)
    r = np.array(n.get("rotation", [0, 0, 0, 1]), dtype=np.float64)  # xyzw
    s = np.array(n.get("scale", [1, 1, 1]), dtype=np.float64)
    x, y, z, w = r
    rot = np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])
    m = np.eye(4)
    m[:3, :3] = rot * s[None, :]
    m[:3, 3] = t
    return m

def collect_meshes(js, indices, parent_mat, out):
    """собирает (mesh_index, world_matrix) для узлов и потомков"""
    for i in indices:
        n = js["nodes"][i]
        m = parent_mat @ node_matrix(n)
        if "mesh" in n:
            out.append((n["mesh"], m))
        collect_meshes(js, n.get("children", []), m, out)

def bake_mesh(js, bin_data, mesh_index, mat, mat_names):
    """возвращает список примитивов с запечёнными в мир координатами"""
    res = []
    m3 = mat[:3, :3]
    nm = np.linalg.inv(m3).T
    for pr in js["meshes"][mesh_index]["primitives"]:
        pos = accessor(js, bin_data, pr["attributes"]["POSITION"])
        pos = pos @ m3.T + mat[:3, 3]
        nrm = accessor(js, bin_data, pr["attributes"]["NORMAL"]) @ nm.T
        ln = np.linalg.norm(nrm, axis=1, keepdims=True)
        nrm = nrm / np.where(ln < 1e-9, 1.0, ln)
        prim = {
            "POSITION": pos.astype(np.float32),
            "NORMAL": nrm.astype(np.float32),
        }
        if "TEXCOORD_0" in pr["attributes"]:
            prim["TEXCOORD_0"] = accessor(js, bin_data, pr["attributes"]["TEXCOORD_0"]).astype(np.float32)
        if "COLOR_0" in pr["attributes"]:
            c = accessor(js, bin_data, pr["attributes"]["COLOR_0"]).astype(np.float32)
            if c.shape[1] == 3:
                c = np.concatenate([c, np.ones((c.shape[0], 1), dtype=np.float32)], axis=1)
            prim["COLOR_0"] = c
        idx = accessor(js, bin_data, pr["indices"]).reshape(-1).astype(np.uint32) if "indices" in pr else None
        if idx is None:
            idx = np.arange(len(pos), dtype=np.uint32)
        mi = pr.get("material", 0)
        prim["INDICES"] = idx
        prim["MATERIAL"] = mat_names[mi] if mi < len(mat_names) else "terrain"
        res.append(prim)
    return res

def write_gltf(path_bin, prims, extra_nodes=None):
    """пишет .gltf + .bin: каждый примитив — отдельный меш и узел"""
    blob = bytearray()
    views, accs, meshes, nodes, materials = [], [], [], [], []
    mat_index = {}

    def add_view(arr, target=None):
        data = arr.tobytes()
        while len(blob) % 4:
            blob.append(0)
        off = len(blob)
        blob.extend(data)
        v = {"buffer": 0, "byteOffset": off, "byteLength": len(data)}
        if target:
            v["target"] = target
        views.append(v)
        return len(views) - 1

    for prim in prims:
        attrs = {}
        pos = prim["POSITION"]
        v = add_view(pos, 34962)
        accs.append({"bufferView": v, "componentType": 5126, "count": len(pos), "type": "VEC3",
                     "min": pos.min(axis=0).tolist(), "max": pos.max(axis=0).tolist()})
        attrs["POSITION"] = len(accs) - 1
        nrm = prim["NORMAL"]
        v = add_view(nrm, 34962)
        accs.append({"bufferView": v, "componentType": 5126, "count": len(nrm), "type": "VEC3"})
        attrs["NORMAL"] = len(accs) - 1
        if "TEXCOORD_0" in prim:
            uv = prim["TEXCOORD_0"]
            v = add_view(uv, 34962)
            accs.append({"bufferView": v, "componentType": 5126, "count": len(uv), "type": "VEC2"})
            attrs["TEXCOORD_0"] = len(accs) - 1
        if "COLOR_0" in prim:
            col = prim["COLOR_0"]
            v = add_view(col, 34962)
            accs.append({"bufferView": v, "componentType": 5126, "count": len(col), "type": "VEC4"})
            attrs["COLOR_0"] = len(accs) - 1
        idx = prim["INDICES"]
        v = add_view(idx.astype(np.uint32), 34963)
        accs.append({"bufferView": v, "componentType": 5125, "count": len(idx), "type": "SCALAR"})
        name = prim["MATERIAL"]
        if name not in mat_index:
            mat_index[name] = len(materials)
            materials.append({"name": name, "pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1],
                                                                     "metallicFactor": 0.0, "roughnessFactor": 0.9}})
        meshes.append({"primitives": [{"attributes": attrs, "indices": len(accs) - 1, "material": mat_index[name]}]})
        nodes.append({"mesh": len(meshes) - 1, "name": name})

    doc = {
        "asset": {"version": "2.0", "generator": "aetheria cell splitter"},
        "scene": 0,
        "scenes": [{"nodes": list(range(len(nodes)))}],
        "nodes": nodes,
        "meshes": meshes,
        "materials": materials,
        "accessors": accs,
        "bufferViews": views,
        "buffers": [{"uri": os.path.basename(path_bin), "byteLength": len(blob)}],
    }
    open(path_bin, "wb").write(bytes(blob))
    open(path_bin.replace(".bin", ".gltf"), "w").write(json.dumps(doc, separators=(",", ":")))
    return len(prims)

def main():
    js, bin_data = read_glb(SRC)
    mat_names = [m.get("name", "terrain") for m in js["materials"]]
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        if f.endswith((".gltf", ".bin", ".json")):
            os.remove(os.path.join(OUT, f))

    roots = {js["nodes"][i]["name"]: i for i in js["scenes"][0]["nodes"]}

    # ---------- рельеф ----------
    terr_buckets = {}
    for c in js["nodes"][roots["Terrain"]].get("children", []):
        n = js["nodes"][c]
        parts = bake_mesh(js, bin_data, n["mesh"], node_matrix(n), mat_names)
        tr = n.get("translation", [0, 0, 0])
        cx = int(math.floor((tr[0] + HALF) / CELL)); cz = int(math.floor((tr[2] + HALF) / CELL))
        key = f"t_{cx}_{cz}"
        terr_buckets.setdefault(key, []).extend(parts)
    terr_info = {}
    for key, parts in terr_buckets.items():
        cnt = write_gltf(os.path.join(OUT, key + ".bin"), parts)
        terr_info[key] = cnt
    print("рельеф: клеток", len(terr_info))

    # ---------- постройки ----------
    st_buckets = {}
    for c in js["nodes"][roots["Structures"]].get("children", []):
        n = js["nodes"][c]
        tr = n.get("translation", [0, 0, 0])
        cx = int(math.floor((tr[0] + HALF) / CELL)); cz = int(math.floor((tr[2] + HALF) / CELL))
        collected = []
        collect_meshes(js, [c], np.eye(4), collected)
        parts = []
        for mi, mtx in collected:
            parts.extend(bake_mesh(js, bin_data, mi, mtx, mat_names))
        st_buckets.setdefault(f"s_{cx}_{cz}", []).extend(parts)
    st_info = {}
    for key, parts in st_buckets.items():
        cnt = write_gltf(os.path.join(OUT, key + ".bin"), parts)
        st_info[key] = cnt
    print("постройки: клеток", len(st_info))

    # ---------- растительность: библиотека мешей + инстансы по клеткам ----------
    veg_lib = {}
    veg_cells = {}
    for group in ["Trees", "Rocks", "Undergrowth", "Water"]:
        gi = roots.get(group)
        if gi is None:
            continue
        for c in js["nodes"][gi].get("children", []):
            n = js["nodes"][c]
            if "mesh" not in n:
                continue
            mi = n["mesh"]
            if mi not in veg_lib:
                veg_lib[mi] = len(veg_lib)
            tr = n.get("translation", [0, 0, 0])
            rot = n.get("rotation", [0, 0, 0, 1])
            scl = n.get("scale", [1, 1, 1])
            cx = int(math.floor((tr[0] + HALF) / CELL)); cz = int(math.floor((tr[2] + HALF) / CELL))
            key = f"v_{cx}_{cz}"
            veg_cells.setdefault(key, []).append((group, veg_lib[mi], tr, rot, scl, mi))

    # библиотека: геометрия каждого меша без трансформа
    lib_parts = []
    lib_order = sorted(veg_lib.items(), key=lambda kv: kv[1])
    lib_names = []
    for mi, slot in lib_order:
        parts = bake_mesh(js, bin_data, mi, np.eye(4), mat_names)
        lib_names.append(f"veg_{slot}")
        lib_parts.extend(parts)
    # пишем библиотеку как один gltf, назначая имена узлам
    write_gltf(os.path.join("world", "lib.bin"), lib_parts)
    # переименуем узлы в библиотеке под слоты
    lib_path = os.path.join("world", "lib.gltf")
    doc = json.load(open(lib_path))
    for i, nd in enumerate(doc["nodes"]):
        if i < len(lib_names):
            nd["name"] = lib_names[i]
    open(lib_path, "w").write(json.dumps(doc, separators=(",", ":")))
    print("библиотека растительности: мешей", len(lib_names))

    # инстансы по клеткам
    index = {"cell": CELL, "half": HALF, "cells": {}, "lib": "res://world/lib.gltf"}
    for key in sorted(set(terr_info) | set(st_info) | set(veg_cells)):
        entry = {}
        if key.replace("t_", "t_") in terr_info:
            entry["terrain"] = f"res://world/cells/{key}.gltf" if key.startswith("t_") else None
        index["cells"].setdefault(key[2:], {})  # ключ клетки cx_cz
    # аккуратно: ключи видов разные (t_/s_/v_), соберём по координатам
    cells = {}
    for key in terr_info:
        coord = key[2:]
        cells.setdefault(coord, {})["terrain"] = f"res://world/cells/{key}.gltf"
    for key in st_info:
        coord = key[2:]
        cells.setdefault(coord, {})["struct"] = f"res://world/cells/{key}.gltf"
    for key, items in veg_cells.items():
        coord = key[2:]
        path = f"res://world/cells/{key}.bin"
        buf = bytearray()
        rows = []
        for group, slot, tr, rot, scl, mi in items:
            rows.append({"g": group, "m": slot, "t": [round(float(v), 3) for v in tr],
                         "r": [round(float(v), 4) for v in rot], "s": [round(float(v), 4) for v in scl]})
        open(os.path.join(OUT, key + ".json"), "w").write(json.dumps(rows, separators=(",", ":")))
        cells.setdefault(coord, {})["veg"] = f"res://world/cells/{key}.json"
    index["cells"] = cells
    index["lib_names"] = lib_names
    open(os.path.join(OUT, "index.json"), "w").write(json.dumps(index, separators=(",", ":")))
    print("клеток всего:", len(cells))
    total_files = len([f for f in os.listdir(OUT) if f.endswith(('.gltf', '.bin', '.json'))])
    print("файлов нарезано:", total_files)

if __name__ == "__main__":
    main()
