#!/usr/bin/env python3
"""Turn a usdextract skinned USDA into rigid parts parented to the joint Xforms.

SUPERSEDED 2026-10-03: the real cause was joint paths with a "/" in the root token
("n10/n8"), which RealityKit silently refuses; local-3d lib/usdjointfix.py
fixes it in glb_to_usdz and the skinned USDZs play as-is. Kept as the
record of the workaround and as a fallback for hard-weighted rigs.

RealityKit ignores the SkelAnimation in Apple's usdextract output for the m3d lamp
(2026-10-03: a 110° curve moved onto the head joint changed nothing), but it does
play the baked xformOp curves usdextract writes on the joint Xform prims. For a
puppet rig with hard weights the mesh is a set of rigid pieces anyway, so: split the
mesh by each vertex's dominant joint, move every piece into its joint's rest-local
space and parent it under that joint's Xform prim. The SkelRoot is dropped.

usage: split_parts.py in.usda out.usda
"""
import re
import sys


def parse_floats(text):
    return [float(x) for x in re.findall(r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?', text)]


def tuples(text, n):
    f = parse_floats(text)
    return [tuple(f[i:i + n]) for i in range(0, len(f), n)]


def mat_mul(a, b):  # row-major 4x4, row-vector convention (USD)
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def mat_inv(m):
    # Gauss-Jordan on a 4x4.
    a = [row[:] + [1.0 if i == j else 0.0 for j in range(4)] for i, row in enumerate(m)]
    for c in range(4):
        p = max(range(c, 4), key=lambda r: abs(a[r][c]))
        a[c], a[p] = a[p], a[c]
        d = a[c][c]
        a[c] = [x / d for x in a[c]]
        for r in range(4):
            if r != c and a[r][c]:
                f = a[r][c]
                a[r] = [x - f * y for x, y in zip(a[r], a[c])]
    return [row[4:] for row in a]


def xform_point(p, m):
    x, y, z = p
    return tuple(x * m[0][i] + y * m[1][i] + z * m[2][i] + m[3][i] for i in range(3))


def xform_dir(v, m):
    x, y, z = v
    return tuple(x * m[0][i] + y * m[1][i] + z * m[2][i] for i in range(3))


def fmt(t):
    return '(' + ', '.join(repr(float(x)) for x in t) + ')'


def main(src, dst):
    s = open(src).read()
    mesh = re.search(r'\n(\s*)def Mesh "([^"]+)"(?:\s*\([^)]*\))?\s*\{(.*?)\n\1\}', s, re.S)
    body = mesh.group(3)

    def attr(name):
        m = re.search(r'%s = \[(.*?)\]' % re.escape(name), body, re.S)
        return m.group(1) if m else None

    points = tuples(attr('point3f[] points'), 3)
    counts = [int(x) for x in parse_floats(attr('int[] faceVertexCounts'))]
    indices = [int(x) for x in parse_floats(attr('int[] faceVertexIndices'))]
    normals = tuples(attr('normal3f[] normals'), 3) if attr('normal3f[] normals') else None
    st = tuples(attr('texCoord2f[] primvars:st'), 2) if attr('texCoord2f[] primvars:st') else None
    ji = [int(x) for x in parse_floats(attr('int[] primvars:skel:jointIndices'))]
    jw = parse_floats(attr('float[] primvars:skel:jointWeights'))
    es = int(re.search(r'jointIndices.*?elementSize = (\d+)', body, re.S).group(1))
    gbt = re.search(r'matrix4d skel:geomBindTransform = (\(.*?\)\s*\))', body, re.S)
    G = [list(r) for r in tuples(gbt.group(1), 4)] if gbt else [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
    binding = re.search(r'rel material:binding = <[^>]+>', body)
    print(f'mesh {mesh.group(2)}: {len(points)} points, {len(counts)} faces, {es} influences, '
          f'normals={normals is not None} st={st is not None}')
    assert normals is None or len(normals) == len(points), 'normals must be vertex-interpolated'
    assert st is None or len(st) == len(points), 'st must be vertex-interpolated'

    skel = re.search(r'def Skeleton "[^"]+"[^{]*\{(.*?)\n\s*def SkelAnimation', s, re.S).group(1)
    joint_names = re.findall(r'"([^"]+)"', re.search(r'jointNames = \[(.*?)\]', skel).group(1))
    binds = [[list(r) for r in tuples(m, 4)] for m in
             re.findall(r'\(\s*\(.*?\)\s*,\s*\(.*?\)\s*,\s*\(.*?\)\s*,\s*\(.*?\)\s*\)',
                        re.search(r'bindTransforms = \[(.*?)\]\n', skel, re.S).group(1), re.S)]
    assert len(binds) == len(joint_names)

    # Dominant joint per vertex, then per face by vote.
    dom = []
    for v in range(len(points)):
        best, bw = 0, -1.0
        for k in range(es):
            if jw[v * es + k] > bw:
                bw, best = jw[v * es + k], ji[v * es + k]
        dom.append(best)
    faces, off = [], 0
    for c in counts:
        faces.append(indices[off:off + c])
        off += c
    by_joint = {}
    for f in faces:
        votes = {}
        for v in f:
            votes[dom[v]] = votes.get(dom[v], 0) + 1
        j = max(votes, key=votes.get)
        by_joint.setdefault(j, []).append(f)

    # Where each joint's Xform prim lives (usdextract names them after jointNames with '.'→'_').
    def xform_path(name):
        pname = name.replace('.', '_')
        m = re.search(r'\n(\s*)def Xform "%s"' % re.escape(pname), s)
        return pname, m
    parts = []
    for j, fl in sorted(by_joint.items()):
        name = joint_names[j]
        pname, m = xform_path(name)
        if not m:
            print(f'  no Xform prim for joint {name}; skipping {len(fl)} faces')
            continue
        to_local = mat_mul(G, mat_inv(binds[j]))
        used = sorted({v for f in fl for v in f})
        remap = {v: i for i, v in enumerate(used)}
        pts = [xform_point(points[v], to_local) for v in used]
        nrm = [xform_dir(normals[v], to_local) for v in used] if normals else None
        uv = [st[v] for v in used] if st else None
        fvi = [remap[v] for f in fl for v in f]
        fvc = [len(f) for f in fl]
        indent = m.group(1) + '    '
        prim = [f'{indent}def Mesh "Part_{pname}" (', f'{indent}    prepend apiSchemas = ["MaterialBindingAPI"]',
                f'{indent})', f'{indent}{{',
                f'{indent}    int[] faceVertexCounts = [{", ".join(map(str, fvc))}]',
                f'{indent}    int[] faceVertexIndices = [{", ".join(map(str, fvi))}]',
                f'{indent}    point3f[] points = [{", ".join(fmt(p) for p in pts)}]']
        if nrm:
            prim.append(f'{indent}    normal3f[] normals = [{", ".join(fmt(n) for n in nrm)}] (\n{indent}        interpolation = "vertex"\n{indent}    )')
        if uv:
            prim.append(f'{indent}    texCoord2f[] primvars:st = [{", ".join(fmt(t) for t in uv)}] (\n{indent}        interpolation = "vertex"\n{indent}    )')
        if binding:
            prim.append(f'{indent}    {binding.group(0)}')
        prim.append(f'{indent}    uniform token subdivisionScheme = "none"')
        prim.append(f'{indent}}}')
        parts.append((m, '\n'.join(prim)))
        print(f'  {name:9s} -> Part_{pname}: {len(fl)} faces, {len(used)} verts')

    # Insert each part right after its Xform prim's opening brace; later offsets first.
    for m, prim in sorted(parts, key=lambda t: -t[0].start()):
        brace = s.index('{', m.end())
        s = s[:brace + 1] + '\n' + prim + s[brace + 1:]
    # Drop the SkelRoot (skeleton, animation source and the skinned mesh).
    sr = re.search(r'\n(\s*)def SkelRoot "[^"]+"(?:\s*\([^)]*\))?\s*\{.*?\n\1\}', s, re.S)
    s = s[:sr.start()] + s[sr.end():]
    open(dst, 'w').write(s)
    print('wrote', dst)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
