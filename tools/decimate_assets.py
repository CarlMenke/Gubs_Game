"""Turn the raw 500k-triangle source art into game-ready meshes.

Every `.glb` the project was handed (Gub, Spear, Lure, Mushroom) is a
photogrammetry-style mesh of roughly half a million triangles. Eight networked
Gubs, their spears, and a scattering of deployed mushrooms would be well over
five million triangles per frame before shadow passes. This script reduces each
one to a sane budget while keeping it visually identical at gameplay distance.

Pipeline, per mesh:

  1. Weld vertices by position. The sources duplicate ~17% of their vertices
     along UV seams; left alone those seams read as hard boundaries the
     decimator refuses to collapse, which wrecks quality at high reduction.
  2. Quadric-error decimation on the welded topology (`fast_simplification`).
  3. Transfer UVs and skin weights back from the source by nearest-vertex
     lookup, disambiguated per-triangle so a triangle never straddles two UV
     islands (which would smear the texture across the seam).
  4. Recompute smooth normals from the new geometry, accumulated by position so
     shading stays continuous across the seams from step 1.
  5. Repack into a fresh single-buffer GLB in `art/generated/`.

Sources in `assets/` are never touched; re-running this is always safe.

Usage:  python tools/decimate_assets.py [name ...]
"""

import io
import os
import sys
import time

import numpy as np
from PIL import Image
from scipy import sparse
from scipy.sparse.csgraph import connected_components
from scipy.spatial import cKDTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fast_simplification  # noqa: E402
from gltf_io import ARRAY_BUFFER, ELEMENT_ARRAY_BUFFER, Gltf, GltfBuilder  # noqa: E402
from rig_math import Rig, quat_from_y_rotation, quat_multiply  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(REPO, "art", "generated")

# name -> (source path, triangle budget, max texture edge)
#
# Budgets are set by how many of each thing can be on screen at once. The Gub
# gets the largest share: up to eight of them, skinned, each also drawn into the
# shadow atlas. The spear is tiny on screen but there is one per Gub plus every
# projectile in flight, so it gets the tightest budget. Every source texture is
# 2048x2048, which is far more than a thrown stick needs.
TARGETS = {
    "gub":      ("assets/source/Gub.glb", 18000, 1024),
    "spear":    ("assets/source/Spear.glb", 3000, 512),
    "lure":     ("assets/source/Lure.glb", 6000, 512),
    "mushroom": ("assets/source/Mushroom/base_basic_pbr.glb", 10000, 1024),
}


def log(msg):
    print(msg, flush=True)


def weld(positions):
    """Merge vertices that share a position.

    Returns (welded_positions, original_index -> welded_index).
    """
    # Quantise very slightly so float noise does not defeat the merge.
    keys = np.round(positions.astype(np.float64), 6)
    _uniq, first, inverse = np.unique(keys, axis=0, return_index=True, return_inverse=True)
    return positions[first].astype(np.float32), inverse.astype(np.int64)


def smooth_normals(positions, faces):
    """Area-weighted vertex normals, accumulated across coincident positions.

    Accumulating by position rather than by index means the two sides of a UV
    seam receive the same normal, so the seam does not show up as a shading
    crease.
    """
    v0, v1, v2 = positions[faces[:, 0]], positions[faces[:, 1]], positions[faces[:, 2]]
    # Un-normalised cross product is already area-weighted.
    face_n = np.cross(v1 - v0, v2 - v0)

    _uniq, inverse = np.unique(np.round(positions.astype(np.float64), 6),
                               axis=0, return_inverse=True)
    inverse = inverse.astype(np.int64)
    slot = inverse[faces]  # (ntri, 3) position-slot per corner

    acc = np.zeros((inverse.max() + 1, 3), dtype=np.float64)
    for k in range(3):
        np.add.at(acc, slot[:, k], face_n)

    normals = acc[inverse]
    length = np.linalg.norm(normals, axis=1, keepdims=True)

    # A vertex touched only by zero-area triangles accumulates nothing. Leaving
    # it at (0,0,0) renders as a black speck, so fall back to pointing it away
    # from the model centre, which is right often enough to be invisible.
    degenerate = (length[:, 0] == 0.0)
    if degenerate.any():
        away = positions[degenerate] - positions.mean(axis=0)
        away_len = np.linalg.norm(away, axis=1, keepdims=True)
        away_len[away_len == 0.0] = 1.0
        normals[degenerate] = away / away_len
        length[degenerate] = 1.0

    return (normals / length).astype(np.float32)


def uv_charts(nverts, faces):
    """Label each source vertex with the UV chart it belongs to.

    An exporter splits the vertex buffer along every UV seam, so the connected
    components of the *unwelded* face graph are exactly the UV charts. That
    gives a cheap, exact island labelling with no UV-space geometry needed.
    """
    edges = np.concatenate([faces[:, [0, 1]], faces[:, [1, 2]], faces[:, [2, 0]]])
    graph = sparse.coo_matrix(
        (np.ones(len(edges), dtype=np.int8), (edges[:, 0], edges[:, 1])),
        shape=(nverts, nverts))
    count, labels = connected_components(graph, directed=False)
    return count, labels


def transfer_attributes(src_pos, src_faces, new_pos, new_faces):
    """Pick, for each new corner, the source vertex its attributes come from.

    A plain nearest-neighbour lookup picks arbitrarily between the two sides of
    a UV seam. Worse, it picks *independently per corner*, so a vertex shared by
    six triangles ends up with six slightly different UVs and the texture shreds.

    Instead each new triangle is assigned one UV chart (from the source triangle
    nearest its centroid), and each corner then takes the nearest source vertex
    *within that chart*. The choice is a pure function of (new vertex, chart), so
    every triangle in a chart agrees on the UV of a shared vertex — the buffer
    dedups back down, and vertices split only where a real seam runs.

    Returns a per-corner (ntri, 3) array of source vertex indices.
    """
    _nchart, chart = uv_charts(len(src_pos), src_faces)

    src_centroids = src_pos[src_faces].mean(axis=1)
    _d, near_tri = cKDTree(src_centroids).query(new_pos[new_faces].mean(axis=1), k=1)
    tri_chart = chart[src_faces[near_tri, 0]]        # (ntri,)

    corner_vert = new_faces.reshape(-1)
    want_chart = np.repeat(tri_chart, 3)

    tree = cKDTree(src_pos)
    k = 48
    _dist, cand = tree.query(new_pos[corner_vert], k=k)   # sorted near -> far
    in_chart = chart[cand] == want_chart[:, None]

    # argmax on a boolean row returns the first True, i.e. the nearest candidate
    # that is in the wanted chart.
    best = np.argmax(in_chart, axis=1)
    chosen = cand[np.arange(len(corner_vert)), best]
    missed = ~in_chart.any(axis=1)
    if missed.any():
        # No vertex of that chart within the 48 nearest: the chart is a tiny
        # scrap far from this corner. Fall back to plain nearest.
        chosen[missed] = cand[missed, 0]
    return chosen.reshape(-1, 3), int(missed.sum())


def dedup_corners(corner_arrays):
    """Collapse identical corners into a shared vertex buffer.

    `corner_arrays` is a list of (ncorner, ...) arrays that must agree for two
    corners to merge. Returns (indices_into_unique, unique_selector).
    """
    flat = [a.reshape(a.shape[0], -1).astype(np.float64) for a in corner_arrays]
    key = np.round(np.concatenate(flat, axis=1), 6)
    _uniq, first, inverse = np.unique(key, axis=0, return_index=True, return_inverse=True)
    return inverse.astype(np.uint32), first


def find_root_joint(doc):
    """Index of the skeleton's root joint node, or None if the mesh is not skinned."""
    skins = doc.get("skins", [])
    if not skins:
        return None
    if "skeleton" in skins[0]:
        return skins[0]["skeleton"]
    joints = set(skins[0]["joints"])
    has_parent = set()
    for index in joints:
        for child in doc["nodes"][index].get("children", []):
            has_parent.add(child)
    roots = sorted(joints - has_parent)
    return roots[0] if roots else None


def align_clip_facing(doc, source, root_index, tolerance_degrees=1.5):
    """Rotate each clip so every one starts the Gub pointing the same way.

    The clips were authored at different resting yaws — Idle sits 66 degrees off
    Crouch, CrouchWalk 34 degrees off — which is invisible when you preview one
    clip at a time and very visible the moment an AnimationTree blends between
    two of them: the body swings sideways on every state change.

    Facing is measured by forward kinematics through the hips (see rig_math),
    not by reading Euler angles off the root quaternion, because the root bone
    carries the rig's own rest orientation and its "yaw" is not the body's.

    The correction is a yaw applied to the root joint's rotation keys, taken
    from frame 0 (every clip is authored starting from a neutral stance). Motion
    *within* the clip is untouched, so a throw still winds the body up.
    """
    rig = Rig(doc)
    reference = rig.facing_radians({}, "thigh.L", "thigh.R")
    if reference is None:
        log("  facing: no hip joints found, skipping alignment")
        return

    for anim in doc.get("animations", []):
        pose = rig.sample_pose(source, anim, 0.0)
        facing = rig.facing_radians(pose, "thigh.L", "thigh.R")
        if facing is None:
            continue
        offset = (facing - reference + np.pi) % (2.0 * np.pi) - np.pi
        if abs(np.degrees(offset)) < tolerance_degrees:
            continue

        correction = quat_from_y_rotation(-offset)
        applied = False
        for channel in anim["channels"]:
            target = channel["target"]
            if target["node"] != root_index or target["path"] != "rotation":
                continue
            sampler = anim["samplers"][channel["sampler"]]
            values = np.array(source.read_accessor(sampler["output"]), dtype=np.float64)
            for i in range(len(values)):
                values[i] = quat_multiply(correction, values[i])
            sampler["_override_output"] = values.astype(np.float32)
            applied = True
        if applied:
            log("  facing    %-12s rotated %+6.1f deg to match the rest pose"
                % (anim.get("name", "?"), -np.degrees(offset)))
        else:
            log("  facing    %-12s is %+.1f deg off but has no root rotation track"
                % (anim.get("name", "?"), np.degrees(offset)))


def strip_root_motion(doc, source, root_index, bob_threshold=0.5):
    """Lock the root joint in place so the clips animate on the spot.

    Every locomotion clip carries its travel baked into the root joint: SlowRun
    walks 4.5 units forward over 0.73s, Jump arcs 12.6 units and rises 3.0. If
    that is left in, the mesh slides away from the CharacterBody3D that is
    supposed to be carrying it.

    Horizontal travel is always removed. Vertical travel is kept when it is
    small, because that is the weight-shift bob that gives a run cycle its life,
    and removed when it is large, because that is a real leap the physics body
    is already doing.

    Returns a list of (clip, forward units/sec) — the speed each clip was
    authored to move at, which is what the movement code should be tuned to if
    feet are not to skate.
    """
    speeds = []
    for anim in doc.get("animations", []):
        for channel in anim["channels"]:
            target = channel["target"]
            if target["node"] != root_index or target["path"] != "translation":
                continue
            sampler = anim["samplers"][channel["sampler"]]
            times = np.asarray(source.read_accessor(sampler["input"]), dtype=np.float64)
            values = np.array(source.read_accessor(sampler["output"]), dtype=np.float32)
            if values.ndim != 2 or len(values) == 0:
                continue

            duration = float(times[-1] - times[0]) if len(times) > 1 else 0.0
            travel = float(np.linalg.norm(values[-1, [0, 2]] - values[0, [0, 2]]))
            if duration > 0.0:
                speeds.append((anim.get("name", "?"), travel / duration))

            values[:, 0] = values[0, 0]
            values[:, 2] = values[0, 2]
            vertical = float(values[:, 1].max() - values[:, 1].min())
            if vertical > bob_threshold:
                values[:, 1] = values[0, 1]
                log("  root motion %-12s locked XZ (%.2f u travelled) and Y (%.2f u rise)"
                    % (anim.get("name", "?"), travel, vertical))
            else:
                log("  root motion %-12s locked XZ (%.2f u travelled), kept %.2f u of bob"
                    % (anim.get("name", "?"), travel, vertical))
            sampler["_override_output"] = values
    return speeds


def clean_animations(doc, source_doc):
    """Collapse the exporter's duplicate animation clips down to one per name.

    `Gub.glb` ships each clip twice: `Idle` with two keyframes (just a held
    pose) and `Idle.001` with the 326 keyframes that are the actual animation.
    That is what a Blender NLA export looks like when both the strip and its
    action get written out. Shipping both means gameplay code has to know to ask
    for `Idle_001`, which is the sort of detail that quietly rots.

    So: group by base name, keep whichever variant carries the most keyframes,
    and give it the clean name. `Crouch` only exists in the two-keyframe form —
    it genuinely is a static pose — and is kept as-is.
    """
    def base_name(name):
        head = name.rsplit(".", 1)
        if len(head) == 2 and head[1].isdigit():
            return head[0]
        return name

    def keyframes(anim):
        # Sampler indices still address the *source* accessor table at this
        # point; the builder renumbers them afterwards.
        return sum(source_doc["accessors"][s["input"]]["count"]
                   for s in anim["samplers"])

    groups = {}
    for anim in doc.get("animations", []):
        groups.setdefault(base_name(anim.get("name", "")), []).append(anim)

    kept = []
    for name in sorted(groups):
        variants = groups[name]
        best = max(variants, key=keyframes)
        if len(variants) > 1:
            dropped = sorted(v.get("name") for v in variants if v is not best)
            log("  animation %-12s kept %-14s (%d keys), dropped %s"
                % (name, best.get("name"), keyframes(best), ", ".join(dropped)))
        best["name"] = name
        kept.append(best)
    doc["animations"] = kept
    return kept


def resize_texture(data, max_edge):
    """Downscale an embedded texture to `max_edge`, returning PNG bytes."""
    img = Image.open(io.BytesIO(data))
    if max(img.size) <= max_edge:
        return data, img.size, img.size
    before = img.size
    scale = float(max_edge) / max(img.size)
    img = img.resize((max(1, int(round(img.size[0] * scale))),
                      max(1, int(round(img.size[1] * scale)))), Image.LANCZOS)
    out = io.BytesIO()
    img.save(out, format="PNG", optimize=True)
    return out.getvalue(), before, img.size


def process(name, src_path, target_tris, max_texture):
    started = time.time()
    src_full = os.path.join(REPO, src_path)
    log("\n=== %s  <-  %s" % (name, src_path))

    g = Gltf.load(src_full)
    meshes = g.doc["meshes"]
    if len(meshes) != 1 or len(meshes[0]["primitives"]) != 1:
        raise SystemExit("%s: expected exactly one mesh with one primitive" % name)
    prim = meshes[0]["primitives"][0]
    attrs = prim["attributes"]

    pos = np.ascontiguousarray(g.read_accessor(attrs["POSITION"]), dtype=np.float32)
    uv = np.ascontiguousarray(g.read_accessor(attrs["TEXCOORD_0"]), dtype=np.float32)
    faces = np.ascontiguousarray(g.read_accessor(prim["indices"]).reshape(-1, 3), dtype=np.int64)
    skinned = "JOINTS_0" in attrs
    joints = g.read_accessor(attrs["JOINTS_0"]) if skinned else None
    weights = g.read_accessor(attrs["WEIGHTS_0"]) if skinned else None

    lo, hi = pos.min(axis=0), pos.max(axis=0)
    diagonal = float(np.linalg.norm(hi - lo))
    log("  source: %d verts, %d tris, bbox %s .. %s%s"
        % (len(pos), len(faces),
           np.round(lo, 2).tolist(), np.round(hi, 2).tolist(),
           ", skinned" if skinned else ""))

    # 1. weld -------------------------------------------------------------
    wpos, v2w = weld(pos)
    wfaces = v2w[faces]
    keep = ((wfaces[:, 0] != wfaces[:, 1]) &
            (wfaces[:, 1] != wfaces[:, 2]) &
            (wfaces[:, 0] != wfaces[:, 2]))
    wfaces = wfaces[keep]
    log("  welded: %d verts (%d seam duplicates removed), %d tris"
        % (len(wpos), len(pos) - len(wpos), len(wfaces)))

    # 2. decimate ---------------------------------------------------------
    new_pos, new_faces = fast_simplification.simplify(
        wpos.astype(np.float32),
        wfaces.astype(np.int32),
        target_count=int(target_tris),
    )
    new_pos = np.ascontiguousarray(new_pos, dtype=np.float32)
    new_faces = np.ascontiguousarray(new_faces, dtype=np.int64)
    log("  decimated: %d verts, %d tris (%.1f%% of source)"
        % (len(new_pos), len(new_faces), 100.0 * len(new_faces) / len(faces)))

    # 3. attribute transfer ----------------------------------------------
    corner_src, missed = transfer_attributes(pos, faces, new_pos, new_faces)
    if missed:
        log("  note: %d of %d corners fell back to plain nearest-vertex"
            % (missed, new_faces.size))
    corner_pos = new_pos[new_faces].reshape(-1, 3)
    corner_uv = uv[corner_src].reshape(-1, 2)

    per_corner = [corner_pos, corner_uv]
    if skinned:
        corner_joints = joints[corner_src].reshape(-1, 4)
        corner_weights = weights[corner_src].reshape(-1, 4)
        per_corner += [corner_joints, corner_weights]

    indices, pick = dedup_corners(per_corner)
    out_pos = corner_pos[pick]
    out_uv = corner_uv[pick]
    out_faces = indices.reshape(-1, 3).astype(np.int64)

    # Dedup can fuse two corners of a triangle together; drop the slivers.
    solid = ((out_faces[:, 0] != out_faces[:, 1]) &
             (out_faces[:, 1] != out_faces[:, 2]) &
             (out_faces[:, 0] != out_faces[:, 2]))
    if not solid.all():
        log("  dropped %d degenerate triangles" % int((~solid).sum()))
        out_faces = out_faces[solid]
    log("  rebuilt: %d verts, %d tris after seam-aware dedup"
        % (len(out_pos), len(out_faces)))

    if skinned:
        out_joints = corner_joints[pick].astype(np.uint8)
        w = corner_weights[pick].astype(np.float32)
        total = w.sum(axis=1, keepdims=True)
        total[total == 0.0] = 1.0
        out_weights = w / total  # glTF requires weights to sum to 1

    # 4. normals ----------------------------------------------------------
    out_normal = smooth_normals(out_pos, out_faces)

    # 5. repack -----------------------------------------------------------
    b = GltfBuilder(g.doc)

    new_attrs = {
        "POSITION": b.add_accessor(out_pos, target=ARRAY_BUFFER, bounds=True),
        "NORMAL": b.add_accessor(out_normal, target=ARRAY_BUFFER),
        "TEXCOORD_0": b.add_accessor(out_uv, target=ARRAY_BUFFER),
    }
    if skinned:
        new_attrs["JOINTS_0"] = b.add_accessor(out_joints, target=ARRAY_BUFFER)
        new_attrs["WEIGHTS_0"] = b.add_accessor(out_weights, target=ARRAY_BUFFER)

    idx_dtype = np.uint16 if len(out_pos) < 65536 else np.uint32
    new_prim = dict(prim)
    new_prim["attributes"] = new_attrs
    new_prim["indices"] = b.add_accessor(out_faces.astype(idx_dtype).reshape(-1),
                                         target=ELEMENT_ARRAY_BUFFER)
    b.doc["meshes"][0]["primitives"] = [new_prim]

    # Everything that is not the mesh (skin bind matrices, animation tracks,
    # embedded textures) is copied across verbatim into the new buffer.
    for skin in b.doc.get("skins", []):
        if "inverseBindMatrices" in skin:
            skin["inverseBindMatrices"] = b.add_accessor(
                np.ascontiguousarray(g.read_accessor(skin["inverseBindMatrices"]),
                                     dtype=np.float32))
    clip_speeds = []
    if b.doc.get("animations"):
        clean_animations(b.doc, g.doc)
        root_joint = find_root_joint(b.doc)
        if root_joint is not None:
            align_clip_facing(b.doc, g, root_joint)
            clip_speeds = strip_root_motion(b.doc, g, root_joint)
    for anim in b.doc.get("animations", []):
        for sampler in anim["samplers"]:
            for slot in ("input", "output"):
                override = sampler.pop("_override_output", None) if slot == "output" else None
                src = override if override is not None else g.read_accessor(sampler[slot])
                arr = np.ascontiguousarray(src, dtype=np.float32)
                sampler[slot] = b.add_accessor(arr, bounds=(slot == "input"))
    for image in b.doc.get("images", []):
        if "bufferView" not in image:
            continue
        raw = g.view_bytes(image["bufferView"])
        data, before, after = resize_texture(raw, max_texture)
        if before != after:
            log("  texture %s: %dx%d -> %dx%d (%d KB -> %d KB)"
                % (image.get("name", "?"), before[0], before[1], after[0], after[1],
                   len(raw) // 1024, len(data) // 1024))
            image["mimeType"] = "image/png"
        image["bufferView"] = b.add_view(data)

    if not os.path.isdir(OUT_DIR):
        os.makedirs(OUT_DIR)
    out_path = os.path.join(OUT_DIR, "%s.glb" % name)
    size = b.save(out_path)
    src_size = os.path.getsize(src_full)
    log("  wrote art/generated/%s.glb  %.1f MB (from %.1f MB)  in %.1fs"
        % (name, size / 1e6, src_size / 1e6, time.time() - started))
    if clip_speeds:
        log("  authored ground speeds (source units/s, and metres/s at 0.35 import scale):")
        for clip, speed in sorted(clip_speeds, key=lambda item: item[1]):
            log("    %-12s %6.2f u/s  ->  %5.2f m/s" % (clip, speed, speed * 0.35))


def main(argv):
    wanted = argv[1:] or sorted(TARGETS)
    unknown = [w for w in wanted if w not in TARGETS]
    if unknown:
        raise SystemExit("unknown target(s): %s (have: %s)"
                         % (", ".join(unknown), ", ".join(sorted(TARGETS))))
    for name in wanted:
        src, tris, tex = TARGETS[name]
        process(name, src, tris, tex)
    log("\ndone.")


if __name__ == "__main__":
    main(sys.argv)
