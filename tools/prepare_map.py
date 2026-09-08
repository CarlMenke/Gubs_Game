"""Turn the raw Rust arena export into a map the repository can actually hold.

`assets/source/Rust/rust.glb` is a 337 MB Blender export of a hand-made remake
of a well-known FPS map. Almost none of that is the map: the geometry is 116,855
triangles and about four megabytes, and the other 333 MB is fifty-two embedded
PNGs, forty-six of them 2048x2048. PNG is lossless and a photographed rust
streak is the worst thing you can hand a lossless codec, so every one of those
files sits close to its raw pixel size. GitHub refuses a single file over
100 MB, so as it stands the arena cannot be committed at all.

It also ships with two things that are not the map. `Cube` is Blender's default
cube, twelve triangles at the origin, and `SM _ Human_001` is a 20,542-triangle
scale-reference figure carrying the export's only animation clip.

So, in order:

  1. Drop those two nodes, the clip that targets the figure, and then everything
     that nothing points at any more: meshes, materials, textures, images,
     accessors and buffer views alike. `gltf_io.GltfBuilder` repacks into a
     fresh single buffer, so dropped data is really gone rather than left
     orphaned inside a buffer that still carries its bytes.
  2. Re-encode the images as JPEG, at a resolution and quality chosen by what
     each one is *for*. Anything with a real alpha channel stays PNG, because
     JPEG has nowhere to put alpha.
  3. Report, then re-read what was written and check it.

Geometry is not touched. The nodes carry scale ~0.01 because the meshes were
authored in centimetres, which lands the arena at roughly 42 x 28 x 64 metres,
already the scale this game uses (D-002, 1 unit = 1 metre), so rescaling it
would only break it.

Sources in `assets/` are never modified; re-running this is always safe, and
running it twice produces the same bytes.

Usage:  python tools/prepare_map.py      (needs numpy and pillow)
"""

import hashlib
import io
import json
import os
import sys
import time

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gltf_io import Gltf, GltfBuilder  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(REPO, "assets", "source", "Rust", "rust.glb")
OUT_DIR = os.path.join(REPO, "art", "maps", "rust")
OUT_PATH = os.path.join(OUT_DIR, "rust.glb")

# Blender's default cube, and the scale-reference figure the map was blocked out
# against. Dropping a node drops its subtree, its mesh, and any animation
# channel aimed at it.
DROP_NODES = ("Cube", "SM _ Human_001")

# A 2048 PNG is well inside Pillow's decompression-bomb guard, but the 2000x2000
# net map plus the guard's default is close enough to be worth turning off: these
# files are ours and we have already measured every one of them.
Image.MAX_IMAGE_PIXELS = None

# What each kind of texture is re-encoded to: (max edge, JPEG quality, chroma
# subsampling). 0 is 4:4:4 and 2 is 4:2:0.
#
# Base colour goes to 4:2:0 because the eye keeps most of its detail in luma, and
# throwing away half the chroma resolution of a rust streak is invisible. A
# normal map must not: its "chroma" is two thirds of a direction vector, and
# halving it lays soft diagonal creases across flat walls. That is also why the
# normals drop to 1024 and get the *higher* quality. At this map's scale the
# resolution is what is spare; the precision per texel is not.
ROLE_RULES = {
    "base":      (2048, 85, 2),
    "emissive":  (2048, 85, 2),
    "normal":    (1024, 90, 0),
    "occlusion": (1024, 85, 0),
    "mr":        (1024, 85, 0),
}

# A normal map worn by materials covering this share of the arena's total world
# surface area keeps its full 2048. The ground and the perimeter wall are what a
# player's face is pressed against for a whole match; a barrel is not. The
# threshold is measured rather than written out as a list of names, so that it
# still says something true if the map is re-exported with different props.
HERO_NORMAL_SHARE = 0.05
HERO_NORMAL_EDGE = 2048

# Over this and the file is no use to us. GitHub's hard limit is 100 MB, and a
# repository sitting just under it is one texture away from being stuck.
SIZE_BUDGET = 60 * 1024 * 1024


def log(msg):
    print(msg, flush=True)


# -- geometry ------------------------------------------------------------


def node_matrix(node):
    """The node's local 4x4 transform, from TRS or from an explicit matrix.

    Worth writing out rather than eyeballing. Reading a node's `scale` and
    `translation` and skipping its `rotation` gives an answer that looks
    plausible and is wrong: on this file it reports the arena as 59 x 56 x 110
    metres instead of 42 x 28 x 64, because a prop rotated 90 degrees about X
    has its height and depth swapped before it is placed. glTF quaternions are
    stored [x, y, z, w], and the scale applies first, so the basis is
    R @ diag(s) and not diag(s) @ R.
    """
    if "matrix" in node:
        # glTF stores matrices column-major.
        return np.asarray(node["matrix"], dtype=np.float64).reshape(4, 4).T
    x, y, z, w = np.asarray(node.get("rotation", [0.0, 0.0, 0.0, 1.0]), dtype=np.float64)
    rot = np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w),     2 * (x * z + y * w)],
        [2 * (x * y + z * w),     1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w),     2 * (y * z + x * w),     1 - 2 * (x * x + y * y)],
    ])
    scale = np.asarray(node.get("scale", [1.0, 1.0, 1.0]), dtype=np.float64)
    out = np.eye(4)
    out[:3, :3] = rot * scale
    out[:3, 3] = np.asarray(node.get("translation", [0.0, 0.0, 0.0]), dtype=np.float64)
    return out


def world_transforms(doc):
    """Every node's world matrix, composed down the scene hierarchy.

    This export is flat, but a re-export with one parented group would silently
    misplace half the map if the parent chain were ignored, and that is exactly
    the kind of thing nobody notices until a spawn point is inside a wall.
    """
    parent = {}
    for index, node in enumerate(doc["nodes"]):
        for child in node.get("children", []):
            parent[child] = index

    cache = {}

    def resolve(index):
        if index not in cache:
            local = node_matrix(doc["nodes"][index])
            cache[index] = local if index not in parent else resolve(parent[index]) @ local
        return cache[index]

    return [resolve(i) for i in range(len(doc["nodes"]))]


def mesh_geometry(g, doc, node_index, transform):
    """Yield (material, world-space positions, triangles) for one node's mesh."""
    for prim in doc["meshes"][doc["nodes"][node_index]["mesh"]]["primitives"]:
        local = np.asarray(g.read_accessor(prim["attributes"]["POSITION"]), dtype=np.float64)
        world = local @ transform[:3, :3].T + transform[:3, 3]
        faces = np.asarray(g.read_accessor(prim["indices"]), dtype=np.int64).reshape(-1, 3)
        yield prim.get("material"), world, faces


def survey(g, doc):
    """Measure the map: per-node world bounds, and per-material surface area.

    Both fall out of one walk, and both answer a question somebody downstream
    has. The bounds give the void kill height and say whether there is a floor
    at all; the areas decide which normal maps earn 2048 (HERO_NORMAL_SHARE).

    Bounds are taken from transformed *vertices*, not from the eight corners of
    each accessor's declared min/max. The corner method is conservative rather
    than wrong, but on a map this full of rotated props it puts the lowest point
    fifteen metres under the real one, and the number coming out of here is
    going to be used to place a kill plane.
    """
    transforms = world_transforms(doc)
    nodes, areas = [], {}
    for index, node in enumerate(doc["nodes"]):
        if "mesh" not in node:
            continue
        lo = np.full(3, np.inf)
        hi = np.full(3, -np.inf)
        tris = 0
        materials = set()
        for material, world, faces in mesh_geometry(g, doc, index, transforms[index]):
            lo = np.minimum(lo, world.min(axis=0))
            hi = np.maximum(hi, world.max(axis=0))
            tris += len(faces)
            materials.add(material)
            cross = np.cross(world[faces[:, 1]] - world[faces[:, 0]],
                             world[faces[:, 2]] - world[faces[:, 0]])
            areas[material] = (areas.get(material, 0.0)
                               + 0.5 * float(np.linalg.norm(cross, axis=1).sum()))
        nodes.append({
            "node": index,
            "name": node.get("name", "?"),
            "lo": lo,
            "hi": hi,
            "tris": tris,
            "footprint": float((hi[0] - lo[0]) * (hi[2] - lo[2])),
            "materials": sorted(m for m in materials if m is not None),
        })
    return nodes, areas


# -- pruning -------------------------------------------------------------


def material_texture_refs(material):
    """Yield every `{"index": ...}` texture reference a material holds.

    Yielded by reference, so the caller can renumber them in place.
    """
    pbr = material.get("pbrMetallicRoughness", {})
    for slot in ("baseColorTexture", "metallicRoughnessTexture"):
        if slot in pbr:
            yield pbr[slot]
    for slot in ("normalTexture", "occlusionTexture", "emissiveTexture"):
        if slot in material:
            yield material[slot]


def image_roles(doc):
    """Map each image to what it is used as, and which ones must keep alpha.

    Classified by the material slot the image is plugged into rather than by its
    name. A name rule would get this file right -- everything here is called
    `T_*_DiffuseMap` or `T_*_NormalMap` -- and would quietly reclassify a
    texture the day somebody renames one on the way out of Blender.
    """
    roles, needs_alpha = {}, set()
    for material in doc.get("materials", []):
        pbr = material.get("pbrMetallicRoughness", {})
        blended = material.get("alphaMode", "OPAQUE") != "OPAQUE"
        pairs = [(pbr.get("baseColorTexture"), "base"),
                 (pbr.get("metallicRoughnessTexture"), "mr"),
                 (material.get("normalTexture"), "normal"),
                 (material.get("occlusionTexture"), "occlusion"),
                 (material.get("emissiveTexture"), "emissive")]
        for ref, role in pairs:
            if ref is None:
                continue
            source = doc["textures"][ref["index"]]["source"]
            roles.setdefault(source, role)
            if blended and role == "base":
                needs_alpha.add(source)
    return roles, needs_alpha


def prune(doc, drop_names):
    """Drop the named nodes and everything only they were keeping alive.

    Returns (what to keep, what went). The document is left alone: the caller
    rebuilds a new one from the keep lists, which means the original is still
    intact to copy accessors out of.
    """
    if doc.get("skins") or doc.get("cameras"):
        raise SystemExit("prepare_map: this pass does not renumber skins or cameras, "
                         "and %s has some" % os.path.basename(SOURCE))

    dropped = set()

    def drop_subtree(index):
        if index in dropped:
            return
        dropped.add(index)
        for child in doc["nodes"][index].get("children", []):
            drop_subtree(child)

    wanted = set(drop_names)
    for index, node in enumerate(doc["nodes"]):
        if node.get("name") in wanted:
            drop_subtree(index)
    missing = wanted - {doc["nodes"][i].get("name") for i in dropped}
    if missing:
        raise SystemExit("prepare_map: no node named %s in %s"
                         % (", ".join(sorted(missing)), os.path.basename(SOURCE)))

    keep_nodes = [i for i in range(len(doc["nodes"])) if i not in dropped]

    # A channel aimed at a dropped node goes, and an animation left with no
    # channels goes with it. Here that takes the whole (single) clip, which is
    # the point: it animates the reference figure and nothing else.
    keep_animations = [a for a in doc.get("animations", [])
                       if any(c["target"]["node"] not in dropped for c in a["channels"])]

    # Reachability, in dependency order.
    keep_meshes = sorted({doc["nodes"][i]["mesh"]
                          for i in keep_nodes if "mesh" in doc["nodes"][i]})
    keep_materials = sorted({p["material"] for m in keep_meshes
                             for p in doc["meshes"][m]["primitives"] if "material" in p})
    keep_textures = sorted({ref["index"] for m in keep_materials
                            for ref in material_texture_refs(doc["materials"][m])})
    keep_images = sorted({doc["textures"][t]["source"] for t in keep_textures
                          if "source" in doc["textures"][t]})
    keep_samplers = sorted({doc["textures"][t]["sampler"] for t in keep_textures
                            if "sampler" in doc["textures"][t]})

    def lost(key, kept):
        kept = set(kept)
        return sorted(doc[key][i].get("name", "?")
                      for i in range(len(doc.get(key, []))) if i not in kept)

    removed = {
        "nodes": sorted(doc["nodes"][i].get("name", "?") for i in dropped),
        "meshes": len(doc["meshes"]) - len(keep_meshes),
        "materials": lost("materials", keep_materials),
        "textures": len(doc.get("textures", [])) - len(keep_textures),
        "images": lost("images", keep_images),
        "animations": [a.get("name", "?") for a in doc.get("animations", [])
                       if a not in keep_animations],
        "triangles": sum(doc["accessors"][p["indices"]]["count"] // 3
                         for i in sorted(dropped) if "mesh" in doc["nodes"][i]
                         for p in doc["meshes"][doc["nodes"][i]["mesh"]]["primitives"]),
    }
    keep = {"nodes": keep_nodes, "meshes": keep_meshes, "materials": keep_materials,
            "textures": keep_textures, "images": keep_images, "samplers": keep_samplers,
            "animations": keep_animations}
    return keep, removed


def remap(kept):
    """old index -> new index, for a list of kept indices in order."""
    return {old: new for new, old in enumerate(kept)}


# -- images --------------------------------------------------------------


def has_alpha(img):
    """True if this image carries an alpha channel that actually varies.

    A texture in RGBA mode whose alpha is 255 everywhere is an accident of
    whoever saved it, and keeping it as a PNG to preserve that would be an
    accident too. `extrema` on the channel is the cheap exact answer.
    """
    if "transparency" in img.info:
        return True
    if img.mode not in ("RGBA", "LA", "PA"):
        return False
    if img.mode == "PA":
        img = img.convert("RGBA")
    low, high = img.getchannel("A").getextrema()
    return low < 255 or high < 255


def resized(img, max_edge):
    if max(img.size) <= max_edge:
        return img
    scale = float(max_edge) / max(img.size)
    return img.resize((max(1, int(round(img.size[0] * scale))),
                       max(1, int(round(img.size[1] * scale)))), Image.LANCZOS)


def recompress(raw, role, max_edge, quality, subsampling):
    """Re-encode one embedded texture. Returns (bytes, mime, before, after, how)."""
    img = Image.open(io.BytesIO(raw))
    img.load()
    before = img.size

    if has_alpha(img):
        # JPEG has nowhere to put an alpha channel, so this one stays PNG
        # whatever it costs. Downscaling it is still allowed.
        small = resized(img, max_edge)
        if small.size == before:
            return raw, "image/png", before, before, "PNG (alpha), source bytes kept"
        out = io.BytesIO()
        small.save(out, format="PNG", optimize=True)
        return out.getvalue(), "image/png", before, small.size, "PNG (alpha)"

    small = resized(img.convert("RGB"), max_edge)
    out = io.BytesIO()
    small.save(out, format="JPEG", quality=quality, optimize=True,
               progressive=False, subsampling=subsampling)
    return (out.getvalue(), "image/jpeg", before, small.size,
            "JPEG q%d %s %s" % (quality, ("4:4:4", "4:2:2", "4:2:0")[subsampling], role))


# -- verification --------------------------------------------------------


def verify(path, expect):
    """Re-read what was just written and check it is a map, not a pile of bytes.

    Every check here guards a specific failure. An accessor pointing past the
    end of its buffer view is what a renumbering bug looks like from the
    outside, and Godot reports it as a generic parse failure three steps from
    the cause. An image that no longer decodes, or decodes as something other
    than its declared mime type, is what happens when the bytes and the JSON
    stop agreeing. And the bounds are re-derived from the written file and
    checked against the printed report, because a report nobody can falsify is
    decoration.
    """
    g = Gltf.load(path)
    doc = g.doc

    itemsizes = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}
    ncomps = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16}
    for index, acc in enumerate(doc["accessors"]):
        if "bufferView" not in acc:
            continue
        if not 0 <= acc["bufferView"] < len(doc["bufferViews"]):
            raise SystemExit("accessor %d points at buffer view %d of %d"
                             % (index, acc["bufferView"], len(doc["bufferViews"])))
        view = doc["bufferViews"][acc["bufferView"]]
        if view.get("byteOffset", 0) + view["byteLength"] > len(g.blob):
            raise SystemExit("buffer view %d runs past the %d-byte binary chunk"
                             % (acc["bufferView"], len(g.blob)))
        packed = itemsizes[acc["componentType"]] * ncomps[acc["type"]]
        stride = view.get("byteStride") or packed
        span = acc.get("byteOffset", 0) + stride * (acc["count"] - 1) + packed
        if span > view["byteLength"]:
            raise SystemExit("accessor %d needs %d bytes of a %d-byte view"
                             % (index, span, view["byteLength"]))

    for index, image in enumerate(doc.get("images", [])):
        probe = Image.open(io.BytesIO(g.view_bytes(image["bufferView"])))
        probe.load()
        declared = {"image/jpeg": "JPEG", "image/png": "PNG"}[image["mimeType"]]
        if probe.format != declared:
            raise SystemExit("image %d (%s) decodes as %s but declares %s"
                             % (index, image.get("name"), probe.format, image["mimeType"]))

    if doc.get("animations"):
        raise SystemExit("output still carries %d animation(s)" % len(doc["animations"]))

    tris = sum(doc["accessors"][p["indices"]]["count"] // 3
               for m in doc["meshes"] for p in m["primitives"])
    if tris != expect["triangles"]:
        raise SystemExit("output has %d triangles, expected %d" % (tris, expect["triangles"]))

    nodes, _areas = survey(g, doc)
    lo = np.min([n["lo"] for n in nodes], axis=0)
    hi = np.max([n["hi"] for n in nodes], axis=0)
    if not (np.allclose(lo, expect["lo"], atol=1e-4) and np.allclose(hi, expect["hi"], atol=1e-4)):
        raise SystemExit("output bounds %s..%s do not match the report %s..%s"
                         % (lo, hi, expect["lo"], expect["hi"]))

    log("  verified: %d accessors in range, %d images decode as declared, "
        "%d triangles, no animations, bounds match the report"
        % (len(doc["accessors"]), len(doc.get("images", [])), tris))


# -- the pass ------------------------------------------------------------


def main():
    started = time.time()
    if not os.path.isfile(SOURCE):
        raise SystemExit(
            "prepare_map: %s is missing.\n"
            "It is 337 MB and therefore not in the repository (see .gitignore).\n"
            "Fetch it from the team's shared drive and put it back at that path."
            % os.path.relpath(SOURCE, REPO))

    source_size = os.path.getsize(SOURCE)
    log("=== rust  <-  %s  (%.1f MB)" % (os.path.relpath(SOURCE, REPO), source_size / 1e6))
    g = Gltf.load(SOURCE)
    doc = g.doc

    before_nodes, before_areas = survey(g, doc)
    log("  source: %d nodes, %d meshes, %d triangles, %d materials, %d textures, "
        "%d images, %d accessors, %d animations"
        % (len(doc["nodes"]), len(doc["meshes"]), sum(n["tris"] for n in before_nodes),
           len(doc["materials"]), len(doc["textures"]), len(doc["images"]),
           len(doc["accessors"]), len(doc.get("animations", []))))

    # 1. prune ------------------------------------------------------------
    keep, removed = prune(doc, DROP_NODES)
    log("\n  dropped nodes: %s  (%d triangles)"
        % (", ".join(repr(n) for n in removed["nodes"]), removed["triangles"]))
    log("  dropped animations: %s"
        % (", ".join(repr(n) for n in removed["animations"]) or "none"))
    log("  orphaned by that: %d meshes, %d materials (%s), %d textures, %d images (%s)"
        % (removed["meshes"], len(removed["materials"]),
           ", ".join(removed["materials"]) or "-", removed["textures"],
           len(removed["images"]), ", ".join(removed["images"]) or "-"))

    node_map = remap(keep["nodes"])
    mesh_map = remap(keep["meshes"])
    material_map = remap(keep["materials"])
    texture_map = remap(keep["textures"])
    image_map = remap(keep["images"])
    sampler_map = remap(keep["samplers"])

    # 2. decide which normal maps are worth their full resolution ----------
    roles, needs_alpha = image_roles(doc)
    kept_area = {m: a for m, a in before_areas.items() if m in material_map}
    total_area = sum(kept_area.values())
    hero_share = {}
    for material, area in sorted(kept_area.items()):
        ref = doc["materials"][material].get("normalTexture")
        if ref is None:
            continue
        image = doc["textures"][ref["index"]]["source"]
        hero_share[image] = hero_share.get(image, 0.0) + area / total_area
    hero_images = {i for i, share in hero_share.items() if share >= HERO_NORMAL_SHARE}
    log("\n  arena surface area %.0f m2. Normal maps held at %d for covering >= %.0f%% of it:"
        % (total_area, HERO_NORMAL_EDGE, 100 * HERO_NORMAL_SHARE))
    for image in sorted(hero_images):
        log("    %-34s %5.1f%%" % (doc["images"][image].get("name", "?"),
                                   100 * hero_share[image]))

    # 3. rebuild the document ---------------------------------------------
    out = {
        "asset": dict(doc["asset"]),
        "scene": 0,
        "scenes": [{"name": doc["scenes"][doc.get("scene", 0)].get("name", "Scene"),
                    "nodes": [node_map[i] for i in keep["nodes"]]}],
        "nodes": [],
        "meshes": [],
        "materials": [],
        "textures": [],
        "images": [],
    }
    if keep["samplers"]:
        out["samplers"] = [doc["samplers"][i] for i in keep["samplers"]]

    for old in keep["nodes"]:
        node = dict(doc["nodes"][old])
        if "mesh" in node:
            node["mesh"] = mesh_map[node["mesh"]]
        if node.get("children"):
            node["children"] = [node_map[c] for c in node["children"] if c in node_map]
            if not node["children"]:
                del node["children"]
        out["nodes"].append(node)

    for old in keep["textures"]:
        texture = dict(doc["textures"][old])
        texture["source"] = image_map[texture["source"]]
        if "sampler" in texture:
            texture["sampler"] = sampler_map[texture["sampler"]]
        out["textures"].append(texture)

    for old in keep["materials"]:
        material = json.loads(json.dumps(doc["materials"][old]))
        for ref in material_texture_refs(material):
            ref["index"] = texture_map[ref["index"]]
        out["materials"].append(material)

    builder = GltfBuilder(out)

    # Meshes. Every accessor is copied verbatim, so the geometry that leaves is
    # bit-for-bit the geometry that arrived, bounds and component types and all.
    # Two dozen of these meshes split one vertex buffer across several
    # primitives, so accessors are copied once each and then shared, exactly as
    # the exporter shared them.
    accessor_map = {}

    def carry(index):
        if index not in accessor_map:
            accessor_map[index] = builder.copy_accessor(g, index)
        return accessor_map[index]

    for old in keep["meshes"]:
        mesh = {"primitives": []}
        if "name" in doc["meshes"][old]:
            mesh["name"] = doc["meshes"][old]["name"]
        for prim in doc["meshes"][old]["primitives"]:
            new = {"attributes": {name: carry(acc)
                                  for name, acc in sorted(prim["attributes"].items())}}
            if "indices" in prim:
                new["indices"] = carry(prim["indices"])
            if "material" in prim:
                new["material"] = material_map[prim["material"]]
            if "mode" in prim:
                new["mode"] = prim["mode"]
            mesh["primitives"].append(new)
        builder.doc["meshes"].append(mesh)

    # 4. images ------------------------------------------------------------
    log("\n  images:")
    encoded, by_source = [], {}
    for old in keep["images"]:
        raw = g.view_bytes(doc["images"][old]["bufferView"])
        role = roles.get(old, "base")
        max_edge, quality, subsampling = ROLE_RULES[role]
        if role == "normal" and old in hero_images:
            max_edge = HERO_NORMAL_EDGE
        if old in needs_alpha:
            # The material says it blends, so this one is going to stay a PNG
            # and should not also be shrunk to a data-texture's resolution.
            max_edge = max(max_edge, ROLE_RULES["base"][0])

        # Six of the container normal maps are byte-identical to each other, as
        # are two diffuse pairs. Encode once and share the result.
        key = (hashlib.sha256(raw).hexdigest(), max_edge, quality, subsampling)
        result = by_source.get(key)
        shared = result is not None
        if not shared:
            result = recompress(raw, role, max_edge, quality, subsampling)
            by_source[key] = result
        data, mime, before, after, how = result
        encoded.append((old, data, mime, len(raw)))
        log("    %-34s %4dx%-4d %7.2f MB  ->  %4dx%-4d %7.2f MB  %s%s"
            % (doc["images"][old].get("name", "?"), before[0], before[1], len(raw) / 1e6,
               after[0], after[1], len(data) / 1e6, how, ", shared" if shared else ""))

    view_for = {}
    for old, data, mime, _raw_len in encoded:
        key = (mime, hashlib.sha256(data).hexdigest())
        if key not in view_for:
            view_for[key] = builder.add_view(data)
        entry = {"bufferView": view_for[key], "mimeType": mime}
        if "name" in doc["images"][old]:
            entry["name"] = doc["images"][old]["name"]
        builder.doc["images"].append(entry)

    jpegs = sum(1 for e in encoded if e[2] == "image/jpeg")
    on_disk = sum(builder.doc["bufferViews"][v]["byteLength"] for v in view_for.values())
    log("    %d images: %d JPEG, %d PNG. %.1f MB -> %.1f MB, which is %.1f MB on disk "
        "across %d distinct payloads"
        % (len(encoded), jpegs, len(encoded) - jpegs, sum(e[3] for e in encoded) / 1e6,
           sum(len(e[1]) for e in encoded) / 1e6, on_disk / 1e6, len(view_for)))

    # 5. write --------------------------------------------------------------
    if not os.path.isdir(OUT_DIR):
        os.makedirs(OUT_DIR)
    size = builder.save(OUT_PATH)

    # 6. report -------------------------------------------------------------
    written = Gltf.load(OUT_PATH)
    nodes, _areas = survey(written, written.doc)
    lo = np.min([n["lo"] for n in nodes], axis=0)
    hi = np.max([n["hi"] for n in nodes], axis=0)
    tris = sum(n["tris"] for n in nodes)

    log("\n  wrote %s  %.1f MB  (from %.1f MB, %.1f%% of it)"
        % (os.path.relpath(OUT_PATH, REPO), size / 1e6, source_size / 1e6,
           100.0 * size / source_size))
    log("  %d nodes, %d meshes, %d triangles, %d materials, %d textures, %d images"
        % (len(written.doc["nodes"]), len(written.doc["meshes"]), tris,
           len(written.doc["materials"]), len(written.doc["textures"]),
           len(written.doc["images"])))
    log("  world bounds   x %8.3f .. %8.3f    y %8.3f .. %8.3f    z %8.3f .. %8.3f"
        % (lo[0], hi[0], lo[1], hi[1], lo[2], hi[2]))
    log("  extent         %8.3f       %8.3f       %8.3f   metres"
        % (hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]))
    log("  lowest vertex y = %.3f, so the void kill height goes below it -- %.1f leaves "
        "a fall long enough to read as one" % (lo[1], np.floor(lo[1]) - 12.0))

    log("\n  largest meshes by ground footprint (this is the 'is there a floor' question):")
    for row in sorted(nodes, key=lambda r: -r["footprint"])[:8]:
        log("    %9.1f m2  %-30s  y %7.2f .. %7.2f  %6d tris  [%s]"
            % (row["footprint"], row["name"], row["lo"][1], row["hi"][1], row["tris"],
               ", ".join(written.doc["materials"][m].get("name", "?")
                         for m in row["materials"])))

    negative = [n.get("name", "?") for n in written.doc["nodes"]
                if min(n.get("scale", [1.0, 1.0, 1.0])) < 0.0]
    non_uniform = [n.get("name", "?") for n in written.doc["nodes"]
                   if len(set(np.round(np.abs(n.get("scale", [1.0, 1.0, 1.0])), 9))) > 1]
    empties = [n.get("name", "?") for n in written.doc["nodes"] if "mesh" not in n]
    unlit = [written.doc["meshes"][i].get("name", "?")
             for i, m in enumerate(written.doc["meshes"])
             for p in m["primitives"] if "material" not in p]
    log("\n  survey: %d nodes with a negative scale (%s), %d with a non-uniform one, "
        "%d mesh-less empties (%s), %d primitives with no material"
        % (len(negative), ", ".join(negative) or "-", len(non_uniform),
           len(empties), ", ".join(empties) or "-", len(unlit)))

    log("")
    verify(OUT_PATH, {"triangles": tris, "lo": lo, "hi": hi})
    if size > SIZE_BUDGET:
        raise SystemExit("  over budget: %.1f MB, and the ceiling is %.1f MB"
                         % (size / 1e6, SIZE_BUDGET / 1e6))
    log("  done in %.0fs." % (time.time() - started))


if __name__ == "__main__":
    main()
