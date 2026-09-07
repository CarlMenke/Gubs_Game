"""Measure how badly a skinned glTF actually deforms, clip by clip.

Looking at an animation and saying "that tore" is not a number, and without a
number there is no way to tell a fix from a change. This walks every clip at a
fixed rate, runs the same linear-blend skinning the GPU will run, and reports
four things that each correspond to a specific thing going wrong:

  stretch      Longest any mesh edge gets, as a multiple of its rest length.
               A skin that holds together stays near 1.0. An edge at 3x is a
               vertex being dragged somewhere the rest of its triangle is not,
               which is what "the mesh tore" looks like as a measurement.

  torn         The share of edges that grow by more than 2% of the body's own
               size. Ratio alone is a liar near small triangles - the mesh has
               edges a fifth the median length, where an invisible half-
               millimetre of drift reads as "6x" - so the count that decides
               whether something is actually visible is measured in body widths,
               not in multiples.

  jerk         Per-vertex third difference of position, in body-size units.
               Smooth motion is smooth in the third derivative too; a single
               bad keyframe, a step interpolation, or a quaternion that took
               the long way round all show up here as a spike and nowhere else.

  loop seam    Distance between the pose at t=0 and the pose at t=end, for the
               clips that are supposed to cycle. This is the visible hitch once
               per stride that no amount of blending hides.

               Measured after subtracting the root joint, because a run cycle is
               *supposed* to end several units in front of where it started and
               the pipeline strips that travel out later. Left in, the forward
               motion swamps the seam and every locomotion clip looks broken.

  asymmetry    How differently the left and right halves of the mesh are bound,
               after mirroring one onto the other and swapping .L for .R. The
               Gub's mesh is symmetric; if its weights are not, it limps.

Usage:  python tools/rig_report.py [path/to.glb ...]
"""

import os
import sys

import numpy as np
from scipy.spatial import cKDTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gltf_io import Gltf  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SAMPLE_FPS = 60.0

# Clips whose last frame is meant to flow back into their first.
CYCLIC = ("Idle", "SlowRun", "FastRun", "CrouchWalk", "Crouch")


# ---------------------------------------------------------------- sampling ---

def quat_slerp(a, b, t):
    """Shortest-arc slerp of two quaternions."""
    dot = float(np.dot(a, b))
    if dot < 0.0:
        b, dot = -b, -dot
    dot = min(1.0, max(-1.0, dot))
    theta = np.arccos(dot)
    sin = np.sin(theta)
    if sin < 1e-6:
        # The arc is short enough that lerp and slerp agree to float precision,
        # and dividing by sin(theta) here would only lose digits.
        out = a + (b - a) * t
    else:
        out = a * (np.sin((1.0 - t) * theta) / sin) + b * (np.sin(t * theta) / sin)
    return out / np.linalg.norm(out)


class Channel(object):
    """One animation channel, evaluated at arbitrary times."""

    def __init__(self, gltf, sampler, path):
        self.times = np.asarray(gltf.read_accessor(sampler["input"]), dtype=np.float64).ravel()
        values = np.asarray(gltf.read_accessor(sampler["output"]), dtype=np.float64)
        self.interp = sampler.get("interpolation", "LINEAR")
        if self.interp == "CUBICSPLINE":
            # in-tangent, value, out-tangent per key. Only the value matters
            # for a report, and dropping the tangents keeps the rest uniform.
            values = values.reshape(len(self.times), 3, -1)[:, 1, :]
        self.values = values.reshape(len(self.times), -1)
        self.path = path

    def at(self, t):
        times = self.times
        if len(times) == 1:
            return self.values[0]
        i = int(np.searchsorted(times, t, side="right")) - 1
        i = max(0, min(i, len(times) - 2))
        span = times[i + 1] - times[i]
        u = 0.0 if span <= 0.0 else float(np.clip((t - times[i]) / span, 0.0, 1.0))
        a, b = self.values[i], self.values[i + 1]
        if self.interp == "STEP":
            return a
        if self.path == "rotation":
            return quat_slerp(a, b, u)
        return a + (b - a) * u


def quat_matrix(q):
    x, y, z, w = q
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ], dtype=np.float64)


class Poser(object):
    """Rest hierarchy plus one clip's channels: joint matrices at any time."""

    def __init__(self, gltf):
        self.gltf = gltf
        self.doc = gltf.doc
        self.nodes = self.doc["nodes"]
        self.parent = {}
        for index, node in enumerate(self.nodes):
            for child in node.get("children", []):
                self.parent[child] = index
        self.rest = {}
        for index, node in enumerate(self.nodes):
            self.rest[index] = (
                np.array(node.get("translation", [0.0, 0.0, 0.0]), dtype=np.float64),
                np.array(node.get("rotation", [0.0, 0.0, 0.0, 1.0]), dtype=np.float64),
                np.array(node.get("scale", [1.0, 1.0, 1.0]), dtype=np.float64),
            )
        # Parents always precede children in this order, so one forward pass
        # composes the whole hierarchy without recursing per frame.
        self.order = self._topological()

    def _topological(self):
        order, seen = [], set()

        def visit(index):
            if index in seen:
                return
            seen.add(index)
            parent = self.parent.get(index)
            if parent is not None:
                visit(parent)
            order.append(index)

        for index in range(len(self.nodes)):
            visit(index)
        return order

    def channels(self, animation):
        out = {}
        for channel in animation["channels"]:
            target = channel["target"]
            if "node" not in target:
                continue
            out.setdefault(target["node"], {})[target["path"]] = Channel(
                self.gltf, animation["samplers"][channel["sampler"]], target["path"])
        return out

    def duration(self, animation):
        end = 0.0
        for sampler in animation["samplers"]:
            accessor = self.doc["accessors"][sampler["input"]]
            if "max" in accessor:
                end = max(end, float(accessor["max"][0]))
        return end

    def world(self, channels, t):
        """node index -> 4x4 world matrix at time `t`."""
        out = {}
        for index in self.order:
            translation, rotation, scale = self.rest[index]
            track = channels.get(index)
            if track is not None:
                if "translation" in track:
                    translation = track["translation"].at(t)
                if "rotation" in track:
                    rotation = track["rotation"].at(t)
                if "scale" in track:
                    scale = track["scale"].at(t)
            local = np.eye(4)
            local[:3, :3] = quat_matrix(rotation) * scale
            local[:3, 3] = translation
            parent = self.parent.get(index)
            out[index] = local if parent is None else out[parent] @ local
        return out


# ----------------------------------------------------------------- metrics ---

def edge_list(faces):
    edges = np.concatenate([faces[:, [0, 1]], faces[:, [1, 2]], faces[:, [2, 0]]])
    return np.unique(np.sort(edges, axis=1), axis=0)


def skin_frames(gltf, animation, positions, joints, weights, ibm, joint_nodes, times):
    """(nframe, nvert, 3) of skinned positions."""
    poser = Poser(gltf)
    channels = poser.channels(animation)
    out = np.empty((len(times), len(positions), 3), dtype=np.float64)
    homogeneous = np.concatenate([positions, np.ones((len(positions), 1))], axis=1)
    for f, t in enumerate(times):
        world = poser.world(channels, t)
        skinning = np.stack([world[n] for n in joint_nodes]) @ ibm
        acc = np.zeros((len(positions), 3))
        for k in range(weights.shape[1]):
            w = weights[:, k:k + 1]
            if not w.any():
                continue
            m = skinning[joints[:, k]]
            acc += w * np.einsum("vij,vj->vi", m[:, :3, :], homogeneous)
        out[f] = acc
    return out


def mirror_pairs(positions, tolerance=1e-3):
    """For each vertex, the index of its mirror across x=0, or -1 if it has none."""
    mirrored = positions.copy()
    mirrored[:, 0] *= -1.0
    dist, idx = cKDTree(positions).query(mirrored, k=1)
    return np.where(dist < tolerance, idx, -1)


def side_swap(names):
    """joint index -> the index of its left/right counterpart."""
    lookup = dict((n, i) for i, n in enumerate(names))
    out = np.arange(len(names))
    for i, name in enumerate(names):
        if name.endswith(".L"):
            twin = name[:-2] + ".R"
        elif name.endswith(".R"):
            twin = name[:-2] + ".L"
        else:
            continue
        if twin in lookup:
            out[i] = lookup[twin]
    return out


def dense_weights(joints, weights, njoint):
    dense = np.zeros((len(joints), njoint))
    rows = np.arange(len(joints))
    for k in range(joints.shape[1]):
        np.add.at(dense, (rows, joints[:, k]), weights[:, k])
    return dense


def report(path):
    gltf = Gltf.load(path)
    doc = gltf.doc
    print("")
    print("=" * 78)
    print(os.path.relpath(path, REPO))
    print("=" * 78)

    prim = doc["meshes"][0]["primitives"][0]
    attrs = prim["attributes"]
    positions = np.asarray(gltf.read_accessor(attrs["POSITION"]), dtype=np.float64)
    faces = np.asarray(gltf.read_accessor(prim["indices"]), dtype=np.int64).reshape(-1, 3)
    joints = np.asarray(gltf.read_accessor(attrs["JOINTS_0"]), dtype=np.int64)
    weights = np.asarray(gltf.read_accessor(attrs["WEIGHTS_0"]), dtype=np.float64)

    skin = doc["skins"][0]
    joint_nodes = skin["joints"]
    names = [doc["nodes"][n].get("name", "?") for n in joint_nodes]
    ibm = np.asarray(gltf.read_accessor(skin["inverseBindMatrices"]),
                     dtype=np.float64).reshape(-1, 4, 4).transpose(0, 2, 1)

    size = float(np.linalg.norm(positions.max(axis=0) - positions.min(axis=0)))
    edges = edge_list(faces)
    rest_len = np.linalg.norm(positions[edges[:, 0]] - positions[edges[:, 1]], axis=1)
    live = rest_len > 1e-9
    edges, rest_len = edges[live], rest_len[live]

    # -- binding ---------------------------------------------------------
    dense = dense_weights(joints, weights, len(joint_nodes))
    twin_vert = mirror_pairs(positions)
    twin_joint = side_swap(names)
    paired = twin_vert >= 0
    mirrored = dense[twin_vert[paired]][:, twin_joint]
    asym = np.abs(dense[paired] - mirrored).sum(axis=1) * 0.5   # 0..1 per vertex
    print("")
    print("  binding")
    print("    %d verts, %d tris, %d joints; %d have a mirror twin (%.0f%%)"
          % (len(positions), len(faces), len(joint_nodes), int(paired.sum()),
             100.0 * paired.mean()))
    print("    left/right asymmetry:  mean %.3f  p95 %.3f  max %.3f   (0 = mirrored exactly)"
          % (asym.mean(), np.percentile(asym, 95), asym.max()))
    influences = (weights > 1e-6).sum(axis=1)
    print("    influences/vertex: %s   weights under 0.02: %d"
          % (np.bincount(influences, minlength=5)[:5].tolist(),
             int(((weights > 0) & (weights < 0.02)).sum())))

    # -- clips -----------------------------------------------------------
    poser = Poser(gltf)
    print("")
    print("  clips   (stretch is a multiple of rest edge length; jerk is per frame,")
    print("           as a fraction of body size)")
    print("    %-14s %6s %6s %8s %8s %8s %9s %9s %9s"
          % ("clip", "frames", "dur", "stretch", "p99.9", "torn%", "jerk avg",
             "jerk max", "loop seam"))
    worst = []
    for animation in doc.get("animations", []):
        duration = poser.duration(animation)
        if duration <= 0.0:
            continue
        nframe = max(4, int(round(duration * SAMPLE_FPS)) + 1)
        times = np.linspace(0.0, duration, nframe)
        frames = skin_frames(gltf, animation, positions, joints, weights,
                             ibm, joint_nodes, times)

        length = np.linalg.norm(frames[:, edges[:, 0]] - frames[:, edges[:, 1]], axis=2)
        stretch = length / rest_len
        worst_edge = int(np.unravel_index(np.argmax(stretch), stretch.shape)[1])

        # Third difference: smooth motion is smooth in the third derivative
        # too, and a single bad key shows up here and almost nowhere else.
        jerk = np.linalg.norm(np.diff(frames, n=3, axis=0), axis=2) / size
        # Re-centre each frame on its own centroid so the clip's forward travel
        # does not count as a seam; what is left is the change in *pose*.
        onspot = frames - frames.mean(axis=1, keepdims=True)
        seam = float(np.linalg.norm(onspot[-1] - onspot[0], axis=1).mean() / size)

        name = animation.get("name", "?")
        cyclic = name.split(".")[0] in CYCLIC
        # Growth in model units, not as a multiple: see the note on `torn` at
        # the top. A max is one vertex; this is how much of the skin is in
        # trouble at a size anyone could see.
        torn = 100.0 * float(((length - rest_len).max(axis=0) > 0.02 * size).mean())
        print("    %-14s %6d %6.2f %8.2f %8.2f %7.3f%% %9.5f %9.5f %9s"
              % (name, nframe, duration, stretch.max(), np.percentile(stretch, 99.9),
                 torn, jerk.mean(), jerk.max(), ("%.4f" % seam) if cyclic else "-"))
        worst.append((stretch.max(), name, worst_edge))

    worst.sort(reverse=True)
    if worst:
        print("")
        print("    worst-stretching edges:")
        for value, name, edge in worst[:6]:
            a, b = edges[edge]
            ja = names[joints[a][np.argmax(weights[a])]]
            jb = names[joints[b][np.argmax(weights[b])]]
            print("      %-14s %6.2fx  between a vert on %-12s and one on %s"
                  % (name, value, ja, jb))


def main(argv):
    paths = argv[1:] or [os.path.join(REPO, "assets", "source", "Gub.glb")]
    for path in paths:
        report(path)


if __name__ == "__main__":
    main(sys.argv)
