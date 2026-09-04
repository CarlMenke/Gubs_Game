"""Minimal glTF 2.0 / GLB reader and writer.

Only the subset this project needs: reading accessors into numpy arrays, reading
image bytes, and repacking a whole document into a fresh single-buffer GLB with
every buffer view rebuilt from scratch. Repacking (rather than appending) is what
lets `decimate_assets.py` drop a 500k-triangle mesh and have the file actually
shrink instead of carrying the dead original around.
"""

import json
import struct
from copy import deepcopy

import numpy as np

# glTF componentType -> numpy dtype
COMPONENT_DTYPE = {
    5120: np.int8,
    5121: np.uint8,
    5122: np.int16,
    5123: np.uint16,
    5125: np.uint32,
    5126: np.float32,
}
DTYPE_COMPONENT = {np.dtype(v): k for k, v in COMPONENT_DTYPE.items()}

# glTF accessor type -> component count
TYPE_COUNT = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4,
              "MAT2": 4, "MAT3": 9, "MAT4": 16}
COUNT_TYPE = {1: "SCALAR", 2: "VEC2", 3: "VEC3", 4: "VEC4", 16: "MAT4"}

ARRAY_BUFFER = 34962
ELEMENT_ARRAY_BUFFER = 34963


class Gltf(object):
    """A parsed GLB: the JSON document plus its binary chunk."""

    def __init__(self, doc, blob):
        self.doc = doc
        self.blob = blob

    # -- loading ---------------------------------------------------------

    @classmethod
    def load(cls, path):
        raw = open(path, "rb").read()
        magic, version, _total = struct.unpack("<III", raw[:12])
        if magic != 0x46546C67:
            raise ValueError("%s is not a GLB (bad magic)" % path)
        if version != 2:
            raise ValueError("%s is glTF version %d, expected 2" % (path, version))

        doc, blob, off = None, b"", 12
        while off < len(raw):
            length, kind = struct.unpack("<II", raw[off:off + 8])
            payload = raw[off + 8:off + 8 + length]
            if kind == 0x4E4F534A:      # JSON
                doc = json.loads(payload)
            elif kind == 0x004E4942:    # BIN
                blob = payload
            off += 8 + length + (-length % 4)
        if doc is None:
            raise ValueError("%s has no JSON chunk" % path)
        return cls(doc, blob)

    # -- reading ---------------------------------------------------------

    def view_bytes(self, view_index):
        view = self.doc["bufferViews"][view_index]
        start = view.get("byteOffset", 0)
        return self.blob[start:start + view["byteLength"]]

    def read_accessor(self, index):
        """Return accessor `index` as a de-interleaved (count, ncomp) array.

        SCALAR accessors come back one-dimensional. Sparse substitution is
        applied. An accessor with no buffer view reads as zeros, per spec.
        """
        acc = self.doc["accessors"][index]
        dtype = np.dtype(COMPONENT_DTYPE[acc["componentType"]])
        ncomp = TYPE_COUNT[acc["type"]]
        count = acc["count"]

        if "bufferView" not in acc:
            out = np.zeros((count, ncomp), dtype=dtype)
        else:
            view = self.doc["bufferViews"][acc["bufferView"]]
            base = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
            packed = dtype.itemsize * ncomp
            stride = view.get("byteStride") or packed
            if stride == packed:
                flat = np.frombuffer(self.blob, dtype=dtype,
                                     count=count * ncomp, offset=base)
                out = flat.reshape(count, ncomp).copy()
            else:
                # Interleaved: pull each element out of its stride slot.
                span = stride * (count - 1) + packed
                rows = np.frombuffer(self.blob, dtype=np.uint8, count=span, offset=base)
                rows = rows.reshape(-1)
                out = np.empty((count, ncomp), dtype=dtype)
                for i in range(count):
                    chunk = rows[i * stride:i * stride + packed].tobytes()
                    out[i] = np.frombuffer(chunk, dtype=dtype)

        if "sparse" in acc:
            sp = acc["sparse"]
            idx_dt = np.dtype(COMPONENT_DTYPE[sp["indices"]["componentType"]])
            iv = self.doc["bufferViews"][sp["indices"]["bufferView"]]
            ibase = iv.get("byteOffset", 0) + sp["indices"].get("byteOffset", 0)
            indices = np.frombuffer(self.blob, dtype=idx_dt, count=sp["count"], offset=ibase)
            vv = self.doc["bufferViews"][sp["values"]["bufferView"]]
            vbase = vv.get("byteOffset", 0) + sp["values"].get("byteOffset", 0)
            values = np.frombuffer(self.blob, dtype=dtype, count=sp["count"] * ncomp,
                                   offset=vbase).reshape(sp["count"], ncomp)
            out[np.asarray(indices, dtype=np.int64)] = values

        return out.reshape(count) if ncomp == 1 else out


class GltfBuilder(object):
    """Accumulates buffer views/accessors into one fresh binary chunk."""

    def __init__(self, doc):
        self.doc = deepcopy(doc)
        self.doc["bufferViews"] = []
        self.doc["accessors"] = []
        self.blob = bytearray()

    def _align(self, n=4):
        pad = (-len(self.blob)) % n
        if pad:
            self.blob.extend(b"\0" * pad)

    def add_view(self, data, target=None, stride=None):
        self._align(4)
        view = {"buffer": 0, "byteOffset": len(self.blob), "byteLength": len(data)}
        if target is not None:
            view["target"] = target
        if stride is not None:
            view["byteStride"] = stride
        self.blob.extend(data)
        self.doc["bufferViews"].append(view)
        return len(self.doc["bufferViews"]) - 1

    def add_accessor(self, array, target=None, normalized=False, bounds=False):
        """Append `array` as a tightly packed buffer view plus accessor."""
        arr = np.ascontiguousarray(array)
        ncomp = 1 if arr.ndim == 1 else arr.shape[1]
        view = self.add_view(arr.tobytes(), target=target)
        acc = {
            "bufferView": view,
            "componentType": DTYPE_COMPONENT[arr.dtype],
            "count": int(arr.shape[0]),
            "type": COUNT_TYPE[ncomp],
        }
        if normalized:
            acc["normalized"] = True
        if bounds:
            a2 = arr.reshape(arr.shape[0], ncomp)
            acc["min"] = [float(v) for v in a2.min(axis=0)]
            acc["max"] = [float(v) for v in a2.max(axis=0)]
        self.doc["accessors"].append(acc)
        return len(self.doc["accessors"]) - 1

    def save(self, path):
        self.doc["buffers"] = [{"byteLength": len(self.blob)}]
        js = json.dumps(self.doc, separators=(",", ":")).encode("utf-8")
        js += b" " * ((-len(js)) % 4)
        bin_chunk = bytes(self.blob)
        bin_chunk += b"\0" * ((-len(bin_chunk)) % 4)
        total = 12 + 8 + len(js) + 8 + len(bin_chunk)
        with open(path, "wb") as fh:
            fh.write(struct.pack("<III", 0x46546C67, 2, total))
            fh.write(struct.pack("<II", len(js), 0x4E4F534A))
            fh.write(js)
            fh.write(struct.pack("<II", len(bin_chunk), 0x004E4942))
            fh.write(bin_chunk)
        return total
