"""Just enough glTF skeleton maths to measure and correct a clip's body facing.

`decimate_assets.py` uses this to answer one question: at the start of this
animation, which way is the Gub actually pointing? The clips in `Gub.glb` were
each authored at a different resting yaw (Idle sits 66 degrees off Crouch), so
blending between them in game would swing the body sideways. Measuring the
facing needs real forward kinematics through the rest pose, which is what lives
here.
"""

import numpy as np


def quat_to_matrix(q):
    """glTF quaternion (x, y, z, w) -> 3x3 rotation matrix."""
    x, y, z, w = q
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ], dtype=np.float64)


def quat_multiply(a, b):
    """Hamilton product of two (x, y, z, w) quaternions: the rotation `b` then `a`."""
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return np.array([
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    ], dtype=np.float64)


def quat_from_y_rotation(radians):
    half = radians * 0.5
    return np.array([0.0, np.sin(half), 0.0, np.cos(half)], dtype=np.float64)


def compose(translation, rotation, scale):
    """TRS -> 4x4 matrix."""
    m = np.eye(4, dtype=np.float64)
    m[:3, :3] = quat_to_matrix(rotation) * np.asarray(scale, dtype=np.float64)
    m[:3, 3] = translation
    return m


class Rig(object):
    """Rest-pose hierarchy of a glTF document, with per-clip pose sampling."""

    def __init__(self, doc):
        self.doc = doc
        self.nodes = doc["nodes"]
        self.parent = {}
        for index, node in enumerate(self.nodes):
            for child in node.get("children", []):
                self.parent[child] = index
        self.by_name = {}
        for index, node in enumerate(self.nodes):
            if "name" in node:
                self.by_name[node["name"]] = index

    def rest_trs(self, index):
        node = self.nodes[index]
        if "matrix" in node:
            # Rare, but legal: decompose just enough to be usable.
            m = np.array(node["matrix"], dtype=np.float64).reshape(4, 4).T
            return m[:3, 3].copy(), np.array([0.0, 0.0, 0.0, 1.0]), np.ones(3)
        return (
            np.array(node.get("translation", [0.0, 0.0, 0.0]), dtype=np.float64),
            np.array(node.get("rotation", [0.0, 0.0, 0.0, 1.0]), dtype=np.float64),
            np.array(node.get("scale", [1.0, 1.0, 1.0]), dtype=np.float64),
        )

    def sample_pose(self, reader, animation, time):
        """node index -> (translation, rotation, scale) at `time`.

        Sampling is nearest-key-at-or-before, which is exact at t=0 and good
        enough anywhere else for a facing measurement.
        """
        pose = {}
        if animation is None:
            return pose
        for channel in animation["channels"]:
            target = channel["target"]
            node_index = target["node"]
            sampler = animation["samplers"][channel["sampler"]]
            times = np.asarray(reader.read_accessor(sampler["input"]), dtype=np.float64)
            values = np.asarray(reader.read_accessor(sampler["output"]), dtype=np.float64)
            key = int(np.searchsorted(times, time, side="right")) - 1
            key = max(0, min(key, len(values) - 1))
            entry = pose.setdefault(node_index, {})
            entry[target["path"]] = values[key]
        return pose

    def world_matrix(self, index, pose):
        chain = []
        cursor = index
        while cursor is not None:
            chain.append(cursor)
            cursor = self.parent.get(cursor)
        out = np.eye(4, dtype=np.float64)
        for node_index in reversed(chain):
            translation, rotation, scale = self.rest_trs(node_index)
            override = pose.get(node_index, {})
            if "translation" in override:
                translation = override["translation"]
            if "rotation" in override:
                rotation = override["rotation"]
            if "scale" in override:
                scale = override["scale"]
            out = out @ compose(translation, rotation, scale)
        return out

    def facing_radians(self, pose, left_joint, right_joint):
        """Yaw of the body, taken from the line between two paired joints.

        Hips are the right pair to use: unlike shoulders or the spine they stay
        put while the arms and torso animate, so the number means "which way is
        the Gub pointing" rather than "what is it doing with its hands".
        Returns None if either joint is missing.
        """
        if left_joint not in self.by_name or right_joint not in self.by_name:
            return None
        left = self.world_matrix(self.by_name[left_joint], pose)[:3, 3]
        right = self.world_matrix(self.by_name[right_joint], pose)[:3, 3]
        across = right - left
        if abs(across[0]) < 1e-9 and abs(across[2]) < 1e-9:
            return None
        return float(np.arctan2(across[0], across[2]))
