"""Rebind the Gub's skin and repair its animation curves.

`assets/source/Gub.glb` was rigged by hand and bound with automatic weights, and
both halves of that came out wrong in ways that only show up once the thing
moves. `tools/rig_report.py` measures it: 19% of the mesh's vertices sit on an
edge that stretches past 1.5x its rest length during a clip, and the worst reach
99x, which is not a deformation, it is a hole. This module is the fix.

WHAT WAS WRONG WITH THE WEIGHTS

Seven of the twenty-nine bones never rotate in any clip: `breast.L/R`,
`pelvis.L/R`, `heel.02.L/R` and `spine.005`. They are Rigify's helper bones,
kept in the rig for posing and never meant to deform anything. Automatic weights
does not know that, so it handed them 19% of the mesh's weight - including a
band of chest either side of the armpit that then stayed welded to the ribcage
while the vertices next to it, bound to `upper_arm.L`, swung through 89 degrees.
That single boundary is the 99x edge, and it is why the Gub tore under its arms.

The same blindness made the two legs deform differently: the right heel ended up
bound to `heel.02.R` and the left to `foot.L`, so one foot bent at the ankle and
the other pivoted around a point behind it.

WHAT REPLACES THEM

A fresh bind, computed rather than painted:

  1. Each vertex is labelled with the deform bone whose *segment* it is nearest.
  2. Those labels are cleaned up by surface connectivity. A label region that is
     not connected across the mesh to the bone it names is a vertex that is near
     a bone through open air rather than through flesh - the chest reaching the
     arm bone across the armpit gap is exactly this - and it gets relabelled to
     the next-nearest bone. This is the step that fixes the tear, and it is why
     plain nearest-bone weighting cannot.
  3. The labels are diffused over the mesh by solving `(A + a L) W = A P`, with
     `L` the cotangent Laplacian and `A` the vertex-area mass matrix. The result
     is the smoothest weight field that still agrees with the labels, `a` sets
     how wide the falloff is, and because `L` annihilates constants the rows sum
     to exactly 1 with no renormalisation.
  4. Left and right are averaged together so the Gub deforms symmetrically.

Clamping the cotangent weights at zero keeps the system an M-matrix, which is
what guarantees the solution stays inside [0, 1] - a skin weight that overshoots
would push a vertex further than the bone it follows.

WHAT WAS WRONG WITH THE CURVES

Of the 87 channels in each clip, 58 are constant: every `scale` track and every
`translation` track except the root's, none of which deviates from the rest pose
by so much as a float's worth. They are what Blender writes when a whole rig is
key-framed regardless of what moved.

The rotation tracks are baked at 60fps, so they are dense enough already - but a
quaternion and its negation are the same rotation, and the exporter emits both.
Wherever the sign flips between neighbouring keys, interpolation takes the long
way around: the bone spins most of a full turn inside 1/60th of a second and
snaps back. `thigh.L` does this six times in `Idle` alone.

Usage:  python tools/rig_clean.py out.glb

That writes a full-resolution cleaned copy, which is only useful for measuring
with `tools/rig_report.py` — it is not the game asset and deliberately has no
default path, so it cannot be dropped into `art/generated/` by accident.
`tools/decimate_assets.py` imports `bind_mesh` and `clean_clips` from here rather
than shelling out, so the shipped asset is still built by one command.
"""

import os
import sys

import numpy as np
from scipy import sparse
from scipy.sparse.csgraph import connected_components
from scipy.sparse.linalg import splu
from scipy.spatial import cKDTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gltf_io import ARRAY_BUFFER, ELEMENT_ARRAY_BUFFER, Gltf, GltfBuilder  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Bones that exist to be posed, not to deform. Every one of these was measured
# at exactly 0.0 degrees of rotation across all seven real clips (see the module
# docstring); they stay in the skeleton, because the ragdoll and the throw
# filter address bones by name and a rig that changes shape is a rig that
# breaks something quietly, but nothing is bound to them any more.
#
# `spine.005` is deliberately *not* in this list. It is also motionless, but it
# is a real link in the neck chain rather than a helper hanging off one, and
# keeping it bound is what gives the neck a graded falloff between `spine.004`
# and the head instead of a step halfway up.
HELPER_BONES = ("breast.L", "breast.R", "pelvis.L", "pelvis.R",
                "heel.02.L", "heel.02.R")

# Width of the weight falloff, in model units, as the standard deviation of the
# smoothing. The Gub is about 7.9 units corner to corner with limbs roughly 0.5
# thick; 0.16 spreads a joint's influence across about a third of a limb's
# width, which is enough to round off an elbow without the shoulder reaching the
# wrist. Tuned against the stretch figure in `tools/rig_report.py`.
FALLOFF = 0.16

MAX_INFLUENCES = 4

# A weight this small changes no pixel but still costs a bone lookup, and four
# of them can crowd out an influence that matters.
WEIGHT_FLOOR = 0.005


def log(msg):
    print(msg, flush=True)


# ------------------------------------------------------------------- mesh ---

def weld(positions):
    """Merge vertices that share a position.

    The exporter splits the vertex buffer along every UV seam. Those splits are
    invisible to the eye but opaque to a Laplacian: diffusion would stop dead at
    each one, and the weights either side would drift apart into a visible crack
    down the model. Everything here runs on the welded mesh and is scattered
    back at the end.

    Returns (welded_positions, original_index -> welded_index).
    """
    keys = np.round(positions.astype(np.float64), 6)
    _uniq, first, inverse = np.unique(keys, axis=0, return_index=True, return_inverse=True)
    return positions[first].astype(np.float64), inverse.astype(np.int64)


def cotangent_laplacian(positions, faces):
    """Cotangent Laplacian `L` and lumped area mass matrix `A`.

    The cotangent weight of an edge is the sum of the cotangents of the two
    angles opposite it, which is what makes the operator approximate the real
    Laplace-Beltrami of the surface rather than of the vertex graph: a long thin
    triangle contributes what its shape says it should, not one vote per edge.

    Negative weights (from obtuse triangles) are clamped away. Keeping every
    off-diagonal non-positive makes `A + a L` an M-matrix, whose inverse is
    non-negative - which is precisely the statement that a diffused weight can
    never overshoot the labels it came from, so no vertex is ever thrown further
    than the bones pulling on it.
    """
    v0, v1, v2 = positions[faces[:, 0]], positions[faces[:, 1]], positions[faces[:, 2]]
    edge = [v2 - v1, v0 - v2, v1 - v0]        # edge opposite each corner
    cross = np.cross(edge[0], -edge[2])
    area = 0.5 * np.linalg.norm(cross, axis=1)

    rows, cols, vals = [], [], []
    for k in range(3):
        i, j = (k + 1) % 3, (k + 2) % 3
        # cot of the angle at corner k, from the two edges leaving it.
        a, b = -edge[j], edge[i]
        cot = (a * b).sum(axis=1) / np.maximum(np.linalg.norm(np.cross(a, b), axis=1), 1e-12)
        w = 0.5 * np.maximum(cot, 0.0)
        rows.extend([faces[:, i], faces[:, j]])
        cols.extend([faces[:, j], faces[:, i]])
        vals.extend([w, w])

    n = len(positions)
    off = sparse.coo_matrix((np.concatenate(vals),
                             (np.concatenate(rows), np.concatenate(cols))),
                            shape=(n, n)).tocsr()
    laplacian = sparse.diags(np.asarray(off.sum(axis=1)).ravel()) - off

    mass = np.zeros(n)
    for k in range(3):
        np.add.at(mass, faces[:, k], area / 3.0)
    # A vertex of only degenerate triangles would divide by zero later.
    mass[mass <= 0.0] = float(np.median(mass[mass > 0.0]))
    return laplacian.tocsr(), sparse.diags(mass)


def vertex_adjacency(nvert, faces):
    edges = np.concatenate([faces[:, [0, 1]], faces[:, [1, 2]], faces[:, [2, 0]]])
    return sparse.coo_matrix((np.ones(len(edges), dtype=np.int8),
                              (edges[:, 0], edges[:, 1])), shape=(nvert, nvert)).tocsr()


# ------------------------------------------------------------------ bones ---

def bone_segments(doc, joint_nodes, inverse_bind):
    """(head, tail) in model space for every joint, plus the leaf-bone guesses.

    glTF stores joints as points; the bone between two of them is implied by the
    hierarchy. A parent's tail is its child's head, and for the leaves - hands,
    toes, the top of the head, the helper bones - there is no child to ask, so
    the bone is extended along its own local +Y, which is the axis Blender lays
    bones out on and which the exporter preserves in the joint's rotation.

    Leaf length is taken from the parent so the extension is in proportion; a
    hand gets a hand's worth of bone rather than an arbitrary constant.
    """
    bind = np.linalg.inv(inverse_bind)             # joint -> model space
    head = bind[:, :3, 3]

    index_of = dict((node, i) for i, node in enumerate(joint_nodes))
    names = [doc["nodes"][n].get("name", "?") for n in joint_nodes]
    child_of = {}
    for i, node in enumerate(joint_nodes):
        for child in doc["nodes"][node].get("children", []):
            if child in index_of:
                child_of.setdefault(i, []).append(index_of[child])

    # A helper bone is a poor guide to where its parent points. `heel.02.R`
    # hangs off `foot.R` and sticks out sideways behind the ankle, so averaging
    # it into the foot's tail aims the foot bone at the heel instead of at the
    # toe, and the toes end up sharing a boundary with a bone that is pointing
    # the wrong way. Helpers still get their own segment - it is only their
    # vote on a parent's direction that is dropped.
    steering = {}
    for parent, children in child_of.items():
        real = [c for c in children if names[c] not in HELPER_BONES]
        steering[parent] = real or children

    tail = np.zeros_like(head)
    for i in range(len(joint_nodes)):
        children = steering.get(i, [])
        if children:
            # The tail is where the chain continues. Averaging matters at the
            # hips and the collarbones, where one joint fans out into several.
            tail[i] = head[children].mean(axis=0)
        else:
            axis = bind[i, :3, 1]                  # local +Y in model space
            axis = axis / max(np.linalg.norm(axis), 1e-9)
            parents = [p for p, kids in child_of.items() if i in kids]
            length = (np.linalg.norm(head[i] - head[parents[0]])
                      if parents else 0.1)
            tail[i] = head[i] + axis * max(length, 1e-3)
    return head, tail


def distance_to_segments(points, head, tail):
    """(npoint, nbone) distance from each point to each bone segment."""
    out = np.empty((len(points), len(head)))
    for b in range(len(head)):
        d = tail[b] - head[b]
        span = float(np.dot(d, d))
        if span < 1e-12:
            out[:, b] = np.linalg.norm(points - head[b], axis=1)
            continue
        t = np.clip(((points - head[b]) @ d) / span, 0.0, 1.0)[:, None]
        out[:, b] = np.linalg.norm(points - (head[b] + t * d), axis=1)
    return out


def connectivity_labels(distance, adjacency, deform):
    """Nearest-bone labels, with the parts that are only near through air removed.

    Nearest-bone is the obvious way to seed a bind and it fails in exactly one
    place: wherever two body parts are close in space but far apart across the
    surface. The armpit is the textbook case - a patch of chest is nearer to
    `upper_arm.L` than to any spine bone, but you cannot walk from it to the arm
    without leaving the model.

    Those patches are found by taking each bone's label region and splitting it
    into connected pieces. The piece holding the vertex closest to the bone is
    the real one; every other piece is the mistake, and is relabelled to its next
    choice. Relabelling can produce new orphans, so it repeats until nothing
    moves.
    """
    banned = np.zeros_like(distance, dtype=bool)
    for _round in range(12):
        masked = np.where(banned, np.inf, distance)
        label = np.argmin(masked, axis=1)
        orphaned = np.zeros(len(label), dtype=bool)

        for b in range(distance.shape[1]):
            if b not in deform:
                continue
            member = np.where(label == b)[0]
            if len(member) == 0:
                continue
            sub = adjacency[member][:, member]
            count, piece = connected_components(sub, directed=False)
            if count == 1:
                continue
            anchor = piece[np.argmin(distance[member, b])]
            stray = member[piece != anchor]
            banned[stray, b] = True
            orphaned[stray] = True

        if not orphaned.any():
            return label, int(banned.sum())
    return label, int(banned.sum())


# ------------------------------------------------------------- rebinding ---

def mirror_map(positions, tolerance):
    """Barycentric-ish mirror lookup: for each vertex, 3 neighbours of its twin.

    The Gub's silhouette is symmetric but its triangulation is not - mirroring a
    vertex lands it about one edge away from any real vertex - so the mirrored
    weight is interpolated from the three nearest vertices rather than snapped to
    one. Returns (indices, weights, usable) with weights summing to 1 per row.
    """
    mirrored = positions.copy()
    mirrored[:, 0] *= -1.0
    dist, idx = cKDTree(positions).query(mirrored, k=3)
    inv = 1.0 / np.maximum(dist, 1e-6)
    return idx, inv / inv.sum(axis=1, keepdims=True), dist[:, 0] < tolerance


def side_swap(names):
    """joint index -> the index of its left/right counterpart."""
    lookup = dict((n, i) for i, n in enumerate(names))
    out = np.arange(len(names))
    for i, name in enumerate(names):
        twin = None
        if name.endswith(".L"):
            twin = name[:-2] + ".R"
        elif name.endswith(".R"):
            twin = name[:-2] + ".L"
        if twin in lookup:
            out[i] = lookup[twin]
    return out


def bind_mesh(doc, joint_nodes, inverse_bind, positions, faces,
              falloff=FALLOFF, quiet=False):
    """Compute `JOINTS_0` and `WEIGHTS_0` for one mesh against one skeleton.

    Takes the geometry rather than reading it from the document, because the
    mesh that ships is not the mesh that was authored: `decimate_assets` halves
    the triangle count first, and the weights it wants are the ones that belong
    to *that* surface. Solving on the final geometry is strictly better than
    solving on the original and resampling - a nearest-vertex transfer of a
    smooth field is not smooth, and it put back a tenth of the tearing this is
    here to remove.
    """
    names = [doc["nodes"][n].get("name", "?") for n in joint_nodes]

    welded, to_welded = weld(positions)
    wfaces = to_welded[faces]
    solid = ((wfaces[:, 0] != wfaces[:, 1]) & (wfaces[:, 1] != wfaces[:, 2]) &
             (wfaces[:, 0] != wfaces[:, 2]))
    wfaces = wfaces[solid]

    deform = set(i for i, n in enumerate(names) if n not in HELPER_BONES)
    head, tail = bone_segments(doc, joint_nodes, inverse_bind)

    distance = distance_to_segments(welded, head, tail)
    distance[:, [i for i in range(len(names)) if i not in deform]] = np.inf

    adjacency = vertex_adjacency(len(welded), wfaces)
    label, banned = connectivity_labels(distance, adjacency, deform)
    if not quiet:
        log("  rebind: %d deform bones (%d helpers unbound), %d verts relabelled "
            "off a bone they only reached through open air"
            % (len(deform), len(names) - len(deform), banned))

    seeds = np.zeros((len(welded), len(names)))
    seeds[np.arange(len(welded)), label] = 1.0

    laplacian, mass = cotangent_laplacian(welded, wfaces)
    # `falloff` is a length; the operator wants an area, and this is the scaling
    # that makes the solution's spatial decay match it.
    solve = splu((mass + (falloff ** 2) * laplacian).tocsc())
    weights = solve.solve(mass @ seeds)

    # `A + a L` is an M-matrix so this only trims float noise, but a negative
    # weight would be catastrophic and the check is free.
    np.clip(weights, 0.0, None, out=weights)

    # -- symmetry --------------------------------------------------------
    idx, blend, usable = mirror_map(welded, tolerance=0.08)
    twin = side_swap(names)
    mirrored = np.einsum("vk,vkj->vj", blend, weights[idx])[:, twin]
    before = float(np.abs(weights[usable] - mirrored[usable]).sum(axis=1).mean() * 0.5)
    weights[usable] = 0.5 * (weights[usable] + mirrored[usable])
    if not quiet:
        log("  rebind: symmetrised %d of %d verts (left/right disagreed by %.3f)"
            % (int(usable.sum()), len(welded), before))

    # -- trim to what a vertex shader can carry --------------------------
    weights[weights < WEIGHT_FLOOR] = 0.0
    keep = np.argsort(-weights, axis=1)[:, :MAX_INFLUENCES]
    rows = np.arange(len(welded))[:, None]
    out_joints = keep.astype(np.uint8)
    out_weights = weights[rows, keep]
    total = out_weights.sum(axis=1, keepdims=True)
    total[total <= 0.0] = 1.0
    out_weights = (out_weights / total).astype(np.float32)

    if not quiet:
        influences = (out_weights > 0).sum(axis=1)
        mass_per = np.zeros(len(names))
        for k in range(MAX_INFLUENCES):
            np.add.at(mass_per, out_joints[:, k], out_weights[:, k])
        heavy = np.argsort(-mass_per)[:3]
        log("  rebind: influences/vertex %s; heaviest bones %s"
            % (np.bincount(influences, minlength=5)[1:5].tolist(),
               ", ".join("%s %.0f" % (names[i], mass_per[i]) for i in heavy)))

    return out_joints[to_welded], out_weights[to_welded]


def rebind(gltf, falloff=FALLOFF, quiet=False):
    """`bind_mesh` against the mesh the document already carries."""
    doc = gltf.doc
    prim = doc["meshes"][0]["primitives"][0]
    skin = doc["skins"][0]
    return bind_mesh(
        doc, skin["joints"],
        np.asarray(gltf.read_accessor(skin["inverseBindMatrices"]),
                   dtype=np.float64).reshape(-1, 4, 4).transpose(0, 2, 1),
        np.asarray(gltf.read_accessor(prim["attributes"]["POSITION"]), dtype=np.float64),
        np.asarray(gltf.read_accessor(prim["indices"]), dtype=np.int64).reshape(-1, 3),
        falloff=falloff, quiet=quiet)


# ------------------------------------------------------------ animations ---

def is_constant(values, tolerance=1e-6):
    return len(values) < 2 or bool(np.all(np.abs(values - values[0]) <= tolerance))


def unroll_quaternions(values):
    """Put every key in the same hemisphere as the one before it.

    q and -q name the same orientation, so an exporter is free to write either,
    and Blender's writes both. Nothing is wrong with the poses - but between two
    keys that straddle the sign, the shortest arc between the *numbers* is the
    long way round the sphere, and the bone takes an almost complete revolution
    inside one frame. Flipping the signs to agree costs nothing and leaves every
    pose in the clip exactly as authored.
    """
    out = np.array(values, dtype=np.float64, copy=True)
    flipped = 0
    for i in range(1, len(out)):
        if float(np.dot(out[i - 1], out[i])) < 0.0:
            out[i] = -out[i]
            flipped += 1
    return out, flipped


def slerp(a, b, t):
    """Shortest-arc interpolation between two quaternions."""
    dot = float(np.dot(a, b))
    if dot < 0.0:
        b, dot = -b, -dot
    dot = min(1.0, max(-1.0, dot))
    theta = np.arccos(dot)
    sin = np.sin(theta)
    if sin < 1e-7:
        out = a + (b - a) * t
    else:
        out = a * (np.sin((1.0 - t) * theta) / sin) + b * (np.sin(t * theta) / sin)
    return out / np.linalg.norm(out)


def angle_between(a, b):
    return float(np.degrees(2.0 * np.arccos(min(1.0, abs(float(np.dot(a, b)))))))


def repair_rotations(values, floor_degrees=3.0, robust=8.0, passes=16):
    """Pull single-frame corruption out of a rotation track, leaving the rest alone.

    Two different things are wrong with these curves and this fixes both, because
    both are the same thing measured: an angular *acceleration* no animator put
    there.

    `toe.L` in `SlowRun` turns 155 degrees in one 60th of a second and comes back
    - an axis flip in whatever produced the bake, not a pose. `forearm.L` in
    `Jump` holds still to within half a degree for five frames and then leaves at
    51 degrees per frame, which is a pose snapped into place with no ease at all.

    The measure of both is how far a key sits from the midpoint of its
    neighbours. That number is the second difference, so it is near zero for
    motion at any constant speed however fast - a sprinting thigh at 16 degrees
    per frame scores under two - and it is enormous for a spike. Keys scoring
    below the threshold are left untouched *exactly*, so nothing the animator did
    on purpose is smoothed away; keys above it are eased back toward the local
    trend, and repeating that lets a correction spread across the few frames
    either side, which is what turns a snap into an ease rather than just moving
    the snap.

    The threshold is per-track and taken from the track's own median deviation,
    because 2 degrees of acceleration is ordinary in a sprint and impossible in
    an idle.
    """
    out = np.array(values, dtype=np.float64, copy=True)
    if len(out) < 5:
        return out, 0

    def deviations(q):
        dev = np.zeros(len(q))
        for i in range(1, len(q) - 1):
            dev[i] = angle_between(slerp(q[i - 1], q[i + 1], 0.5), q[i])
        return dev

    baseline = deviations(out)
    interior = baseline[1:-1]
    threshold = max(floor_degrees, robust * float(np.median(interior)))
    touched = int((interior > threshold).sum())
    if touched == 0:
        return out, 0

    for _ in range(passes):
        dev = deviations(out)
        moved = False
        for i in range(1, len(out) - 1):
            if dev[i] <= threshold:
                continue
            # Ease back only by the share of the deviation that is over the
            # threshold, so a key just past it barely moves and a 155-degree
            # spike is taken almost all the way to the trend.
            blend = min(1.0, (dev[i] - threshold) / dev[i])
            out[i] = slerp(out[i], slerp(out[i - 1], out[i + 1], 0.5), blend)
            moved = True
        if not moved:
            break
    return out, touched


def close_loop(times, values, path):
    """Make the last key equal the first, for a clip that has to cycle.

    A baked cycle usually ends one frame *before* it repeats, so its last key is
    not its first and the seam shows as a hitch once per stride. Averaging the
    two ends and writing the result to both is the smallest change that removes
    it, and it moves each end by half of an already-small gap.
    """
    if len(values) < 2:
        return values, 0.0
    first, last = values[0].copy(), values[-1].copy()
    if path == "rotation" and float(np.dot(first, last)) < 0.0:
        last = -last
    gap = float(np.linalg.norm(first - last))
    mean = 0.5 * (first + last)
    if path == "rotation":
        norm = np.linalg.norm(mean)
        if norm < 1e-9:
            return values, 0.0
        mean = mean / norm
    values = np.array(values, dtype=np.float64, copy=True)
    values[0] = mean
    values[-1] = mean
    return values, gap


# --------------------------------------------------------- clip rewriting ---

# Clips the animator built to cycle. `Crouch` is in the list because the pose
# this module synthesises for it has to hold, not because it moves.
CYCLIC_CLIPS = ("Idle", "SlowRun", "FastRun", "CrouchWalk", "Crouch")


def load_samplers(gltf, animation):
    """Pull a clip's curves out of the buffer and into plain arrays.

    Everything downstream - here, and the facing and root-motion passes in
    `decimate_assets` - edits curves rather than reading them once, and juggling
    accessor indices through that is how a track ends up pointing at the wrong
    buffer view. Once loaded, `_input` and `_output` are the truth and the
    accessor indices are ignored until the file is written back out.
    """
    for sampler in animation["samplers"]:
        if "_output" in sampler:
            continue
        times = np.asarray(gltf.read_accessor(sampler["input"]), dtype=np.float64).ravel()
        values = np.asarray(gltf.read_accessor(sampler["output"]), dtype=np.float64)
        sampler["_input"] = times
        sampler["_output"] = values.reshape(len(times), -1)


def rest_value(doc, node, path):
    default = {"translation": [0.0, 0.0, 0.0],
               "rotation": [0.0, 0.0, 0.0, 1.0],
               "scale": [1.0, 1.0, 1.0]}[path]
    return np.array(doc["nodes"][node].get(path, default), dtype=np.float64)


def sample_track(sampler, t):
    times, values = sampler["_input"], sampler["_output"]
    if len(times) == 1:
        return values[0]
    i = int(np.searchsorted(times, t, side="right")) - 1
    i = max(0, min(i, len(times) - 2))
    span = times[i + 1] - times[i]
    u = 0.0 if span <= 0.0 else float(np.clip((t - times[i]) / span, 0.0, 1.0))
    if sampler.get("interpolation", "LINEAR") == "STEP":
        return values[i]
    if len(values[i]) == 4:
        return slerp(values[i], values[i + 1], u)
    return values[i] + (values[i + 1] - values[i]) * u


def joint_positions(doc, animation, joint_nodes, t):
    """World positions of every joint at time `t`, relative to the root joint."""
    tracks = {}
    for channel in animation["channels"]:
        target = channel["target"]
        tracks.setdefault(target["node"], {})[target["path"]] = \
            animation["samplers"][channel["sampler"]]

    parent = {}
    for index, node in enumerate(doc["nodes"]):
        for child in node.get("children", []):
            parent[child] = index

    world = {}

    def resolve(index):
        if index in world:
            return world[index]
        track = tracks.get(index, {})
        trs = []
        for path in ("translation", "rotation", "scale"):
            trs.append(sample_track(track[path], t) if path in track
                       else rest_value(doc, index, path))
        translation, rotation, scale = trs
        x, y, z, w = rotation / max(np.linalg.norm(rotation), 1e-12)
        local = np.eye(4)
        local[:3, :3] = np.array([
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ]) * scale
        local[:3, 3] = translation
        up = parent.get(index)
        world[index] = local if up is None else resolve(up) @ local
        return world[index]

    out = np.stack([resolve(n)[:3, 3] for n in joint_nodes])
    return out - out[0]


def most_symmetric_time(doc, animation, joint_nodes, names):
    """When in this clip does the body come closest to standing square.

    `Crouch` shipped as two keyframes of the bind pose - the Gub's crouch, in
    game, was it standing in its T-pose - so the pose has to come from somewhere,
    and the only crouched motion in the file is `CrouchWalk`.

    Any single frame of a walk is mid-stride and looks like it. The one worth
    freezing is the frame where the two halves of the body agree most closely,
    which is where the feet pass each other: legs together, weight centred. That
    is found by mirroring the skeleton and asking how far it is from itself, at
    every frame, and keeping the best - no guess about which frame of a cycle is
    the contact pose, just the measurement.
    """
    twin = side_swap(names)
    duration = max(float(s["_input"][-1]) for s in animation["samplers"])
    start = min(float(s["_input"][0]) for s in animation["samplers"])
    opening = joint_positions(doc, animation, joint_nodes, start)
    span = float(np.linalg.norm(opening.max(axis=0) - opening.min(axis=0)))

    best, best_score = start, np.inf
    for t in np.linspace(start, duration, 120):
        p = joint_positions(doc, animation, joint_nodes, t)
        mirrored = p[twin] * np.array([-1.0, 1.0, 1.0])
        score = float(np.linalg.norm(p - mirrored, axis=1).mean())
        if score < best_score:
            best, best_score = t, score
    return best, best_score / max(span, 1e-9)


def freeze(doc, animation, joint_nodes, t, name, root_node=None):
    """Replace a clip with a single held pose sampled from another clip."""
    tracks = {}
    for channel in animation["channels"]:
        target = channel["target"]
        tracks.setdefault(target["node"], {})[target["path"]] = \
            animation["samplers"][channel["sampler"]]

    start = min(float(s["_input"][0]) for s in animation["samplers"])

    channels, samplers = [], []
    for node in joint_nodes:
        for path in ("translation", "rotation", "scale"):
            track = tracks.get(node, {}).get(path)
            if track is None:
                continue
            value = np.asarray(sample_track(track, t), dtype=np.float64)
            if node == root_node and path == "translation":
                # A frame taken from the middle of a walk carries the metres
                # that walk had already covered, and a still pose frozen at
                # that value stands a stride and a half to one side. The
                # sideways travel comes from where the clip started; only the
                # height is worth keeping, because that is how low the crouch
                # actually is.
                value = np.array([sample_track(track, start)[0], value[1],
                                  sample_track(track, start)[2]])
            samplers.append({
                "interpolation": "LINEAR",
                "_input": np.array([0.0, 0.5]),
                "_output": np.stack([value, value]),
            })
            channels.append({"sampler": len(samplers) - 1,
                             "target": {"node": node, "path": path}})
    return {"name": name, "channels": channels, "samplers": samplers}


def clean_clips(doc, gltf, root_node, quiet=False):
    """Rewrite every clip in `doc` into something worth playing.

    Runs after `decimate_assets` has picked one variant per clip name, and
    before the facing and root-motion passes, which expect `_input`/`_output`.
    """
    skin = doc["skins"][0]
    joint_nodes = skin["joints"]
    names = [doc["nodes"][n].get("name", "?") for n in joint_nodes]
    by_name = dict((a.get("name", ""), a) for a in doc.get("animations", []))

    # -- Crouch is not a crouch ------------------------------------------
    if "Crouch" in by_name and "CrouchWalk" in by_name:
        walk = by_name["CrouchWalk"]
        load_samplers(gltf, walk)
        crouch = by_name["Crouch"]
        load_samplers(gltf, crouch)
        held = all(is_constant(s["_output"]) for s in crouch["samplers"])
        if held:
            t, residual = most_symmetric_time(doc, walk, joint_nodes, names)
            rebuilt = freeze(doc, walk, joint_nodes, t, "Crouch", root_node)
            doc["animations"][doc["animations"].index(crouch)] = rebuilt
            by_name["Crouch"] = rebuilt
            if not quiet:
                log("  clips: Crouch held the bind pose, not a crouch - rebuilt "
                    "from CrouchWalk at t=%.3fs, its squarest frame (%.1f%% off "
                    "mirror-symmetric)" % (t, 100.0 * residual))

    totals = dict(dropped=0, unrolled=0, repaired=0, tracks=0)
    for animation in doc.get("animations", []):
        load_samplers(gltf, animation)
        name = animation.get("name", "?")
        cyclic = name in CYCLIC_CLIPS

        keep = []
        for channel in animation["channels"]:
            target = channel["target"]
            node, path = target.get("node"), target["path"]
            sampler = animation["samplers"][channel["sampler"]]
            values = sampler["_output"]

            if path == "rotation":
                values, flipped = unroll_quaternions(values)
                totals["unrolled"] += flipped
                values, touched = repair_rotations(values)
                totals["repaired"] += touched
                sampler["_output"] = values

            # A track that never leaves the rest pose is describing nothing. The
            # root's translation is exempt: it is constant only until the
            # root-motion pass has had its say, and it carries the clip's bob.
            constant = is_constant(sampler["_output"])
            at_rest = constant and np.allclose(sampler["_output"][0],
                                               rest_value(doc, node, path), atol=1e-5)
            if at_rest and not (path == "translation" and node == root_node):
                totals["dropped"] += 1
                continue

            if cyclic and path == "rotation":
                sampler["_output"], _gap = close_loop(
                    sampler["_input"], sampler["_output"], path)
            keep.append(channel)

        # -- renumber, keeping only the samplers still spoken for ---------
        samplers, remap = [], {}
        for channel in keep:
            old = channel["sampler"]
            if old not in remap:
                remap[old] = len(samplers)
                samplers.append(animation["samplers"][old])
            channel["sampler"] = remap[old]
        animation["channels"] = keep
        animation["samplers"] = samplers
        totals["tracks"] += len(keep)

        # -- start at zero -----------------------------------------------
        # Blender bakes from frame 1, so every clip's first key sits one frame
        # in and nothing at all is defined before it. A looping clip therefore
        # holds its opening pose for an extra 60th of a second every time it
        # comes round, which at a 32-frame sprint is a visible hitch once per
        # stride. Sliding the whole clip back to zero costs nothing and removes
        # it.
        if samplers:
            start = min(float(s["_input"][0]) for s in samplers)
            if start > 0.0:
                for sampler in samplers:
                    sampler["_input"] = sampler["_input"] - start

    if not quiet:
        log("  clips: dropped %d channels that never left the rest pose, kept %d; "
            "unrolled %d quaternion sign flips; eased %d corrupted keys"
            % (totals["dropped"], totals["tracks"], totals["unrolled"],
               totals["repaired"]))


def write_animations(builder, doc):
    """Turn the in-memory curves back into accessors on a fresh buffer."""
    for animation in doc.get("animations", []):
        for sampler in animation["samplers"]:
            times = np.ascontiguousarray(sampler.pop("_input"), dtype=np.float32)
            values = np.ascontiguousarray(sampler.pop("_output"), dtype=np.float32)
            if values.shape[1] == 4:
                # Four components means a rotation; translation and scale are
                # both three. Repairing and averaging leave quaternions a hair
                # off unit length, and a renderer that skips the normalise would
                # scale the bone by the error.
                values = values / np.linalg.norm(values, axis=1, keepdims=True)
            sampler["input"] = builder.add_accessor(times, bounds=True)
            sampler["output"] = builder.add_accessor(
                np.ascontiguousarray(values, dtype=np.float32))


# ------------------------------------------------------------- standalone ---

def main(argv):
    if len(argv) < 2:
        raise SystemExit("usage: python tools/rig_clean.py out.glb")
    out = argv[1]
    source = os.path.join(REPO, "assets", "source", "Gub.glb")
    log("=== rig_clean  <-  %s" % os.path.relpath(source, REPO))

    gltf = Gltf.load(source)
    joints, weights = rebind(gltf)

    builder = GltfBuilder(gltf.doc)
    prim = builder.doc["meshes"][0]["primitives"][0]
    attributes = {}
    for name, accessor in prim["attributes"].items():
        if name == "JOINTS_0":
            attributes[name] = builder.add_accessor(joints, target=ARRAY_BUFFER)
        elif name == "WEIGHTS_0":
            attributes[name] = builder.add_accessor(weights, target=ARRAY_BUFFER)
        else:
            attributes[name] = builder.add_accessor(
                np.ascontiguousarray(gltf.read_accessor(accessor), dtype=np.float32),
                target=ARRAY_BUFFER, bounds=(name == "POSITION"))
    prim["attributes"] = attributes
    prim["indices"] = builder.add_accessor(
        np.ascontiguousarray(gltf.read_accessor(prim["indices"])),
        target=ELEMENT_ARRAY_BUFFER)

    for skin in builder.doc.get("skins", []):
        if "inverseBindMatrices" in skin:
            skin["inverseBindMatrices"] = builder.add_accessor(
                np.ascontiguousarray(gltf.read_accessor(skin["inverseBindMatrices"]),
                                     dtype=np.float32))

    # Standalone, the duplicate-clip cull that `decimate_assets` normally does
    # first has not happened, so drop the two-keyframe stubs here.
    # Sampler indices still address the *source* accessor table here; the
    # builder has already rebuilt its own for the mesh.
    def keyframes(animation):
        return sum(gltf.doc["accessors"][s["input"]]["count"]
                   for s in animation["samplers"])

    groups = {}
    for animation in builder.doc.get("animations", []):
        head = animation["name"].rsplit(".", 1)
        stem = head[0] if len(head) == 2 and head[1].isdigit() else animation["name"]
        groups.setdefault(stem, []).append(animation)

    keep = []
    for stem in sorted(groups):
        best = max(groups[stem], key=keyframes)
        best["name"] = stem
        keep.append(best)
    builder.doc["animations"] = keep

    root = builder.doc["skins"][0]["joints"][0]
    clean_clips(builder.doc, gltf, root)
    write_animations(builder, builder.doc)

    for image in builder.doc.get("images", []):
        if "bufferView" in image:
            image["bufferView"] = builder.add_view(gltf.view_bytes(image["bufferView"]))

    size = builder.save(out)
    log("  wrote %s  %.1f MB" % (out, size / 1e6))


if __name__ == "__main__":
    main(sys.argv)
