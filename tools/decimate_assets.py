"""Turn the raw 500k-triangle source props into game-ready meshes.

Every prop `.glb` the project was handed (Spear, Lure, Mushroom) is a
photogrammetry-style mesh of roughly half a million triangles. One spear per
Gub, every projectile in flight, and a scattering of deployed mushrooms would be
millions of triangles per frame before shadow passes. This script reduces each
one to a sane budget while keeping it visually identical at gameplay distance.

Static, unskinned meshes only. The Gub came through here too until D-029: a
skinned photogrammetry mesh whose hand-made rig had to be repaired on the way
past, which is what the skin binding, the animation-curve cleanup, the clip
facing alignment and the root-motion stripping in this script existed for. It is
now built from Mixamo FBX by `tools/build_gub.py`, which does all of that at the
source instead, so all of it is gone from here and each remaining target is one
unskinned mesh with one material and no animation.

Pipeline, per mesh:

  1. Weld vertices by position. The sources duplicate ~17% of their vertices
     along UV seams; left alone those seams read as hard boundaries the
     decimator refuses to collapse, which wrecks quality at high reduction.
  2. Quadric-error decimation on the welded topology (`fast_simplification`).
  3. Transfer UVs back from the source by nearest-vertex lookup, disambiguated
     per-triangle so a triangle never straddles two UV islands (which would
     smear the texture across the seam).
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

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(REPO, "art", "generated")

# name -> (source path, triangle budget, max texture edge)
#
# Budgets are set by how many of each thing can be on screen at once. The spear
# is tiny on screen but there is one per Gub plus every projectile in flight, so
# it gets the tightest budget; the mushroom is a placed object you walk right up
# to and gets the loosest. Every source texture is 2048x2048, which is far more
# than a thrown stick needs.
TARGETS = {
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

    # Everything this script knows how to do assumes a static prop. Skin
    # weights and animation curves survive neither the weld nor the decimation
    # without the machinery that went to `tools/build_gub.py` with the Gub, so
    # say so rather than quietly writing an asset with its rig thrown away.
    if "JOINTS_0" in attrs or g.doc.get("skins") or g.doc.get("animations"):
        raise SystemExit("%s: skinned or animated source; this script only "
                         "handles static props (the Gub is built by "
                         "tools/build_gub.py)" % name)

    lo, hi = pos.min(axis=0), pos.max(axis=0)
    # Rounded as float64: rounding a float32 to two places and printing it
    # still spells 0.13 as 0.12999999523162842, which buries the number the
    # line exists to show.
    log("  source: %d verts, %d tris, bbox %s .. %s"
        % (len(pos), len(faces),
           np.round(lo.astype(np.float64), 2).tolist(),
           np.round(hi.astype(np.float64), 2).tolist()))

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

    # Only the UVs ride along; normals are recomputed from the new geometry
    # below rather than transferred, so a corner is (position, UV) and nothing
    # else has to agree for two of them to merge.
    indices, pick = dedup_corners([corner_pos, corner_uv])
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

    # 4. normals ----------------------------------------------------------
    out_normal = smooth_normals(out_pos, out_faces)

    # 5. repack -----------------------------------------------------------
    b = GltfBuilder(g.doc)

    new_attrs = {
        "POSITION": b.add_accessor(out_pos, target=ARRAY_BUFFER, bounds=True),
        "NORMAL": b.add_accessor(out_normal, target=ARRAY_BUFFER),
        "TEXCOORD_0": b.add_accessor(out_uv, target=ARRAY_BUFFER),
    }

    idx_dtype = np.uint16 if len(out_pos) < 65536 else np.uint32
    new_prim = dict(prim)
    new_prim["attributes"] = new_attrs
    new_prim["indices"] = b.add_accessor(out_faces.astype(idx_dtype).reshape(-1),
                                         target=ELEMENT_ARRAY_BUFFER)
    b.doc["meshes"][0]["primitives"] = [new_prim]

    # The only thing in the file that is not the mesh is the embedded texture,
    # which is copied across (downscaled) into the new buffer.
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
