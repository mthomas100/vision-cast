# Diagnostic (2026-10-02): tested the hypothesis that RealityKit drops the lamp wave's arm raise
# because SkelAnimation.joints omits the root joint. Result: the patched USDZ renders the same
# (arms down), so this is NOT the cause. Kept for the record; see README "The character asset".
# Usage: unzip x.usdz; usdcat x.usdc > x.usda; python3 patch_skelanim.py x.usda y.usda;
#        usdcat y.usda -o x.usdc; usdzip --arkitAsset x.usdc y.usdz
# Fix a usdextract SkelAnimation whose `joints` omits the Skeleton's root joint:
# write the full Skeleton joint list and insert the root's REST values into every
# translations/rotations/scales sample at the root's index. Text (usda) in and out.
import re, sys, math
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
skel_joints = re.search(r'def Skeleton .*?uniform token\[\] joints = \[(.*?)\]', s, re.S).group(1)
skel = [j.strip().strip('"') for j in skel_joints.split(',')]
rest = re.search(r'uniform matrix4d\[\] restTransforms = \[(.*?)\]\n', s, re.S).group(1)
mats = re.findall(r'\(\s*\((.*?)\),\s*\((.*?)\),\s*\((.*?)\),\s*\((.*?)\)\s*\)', rest)
anim_joints = re.search(r'def SkelAnimation .*?uniform token\[\] joints = \[(.*?)\]', s, re.S).group(1)
anim = [j.strip().strip('"') for j in anim_joints.split(',')]
missing = [(i, j) for i, j in enumerate(skel) if j not in anim]
print("skeleton joints:", len(skel), "animation joints:", len(anim), "missing:", missing)
def decompose(rows):
    m = [[float(x) for x in r.split(',')] for r in rows]   # row-major, USD: row i = basis i, row 3 = translation
    t = m[3][:3]
    sc = [math.sqrt(sum(c * c for c in m[i][:3])) for i in range(3)]
    r = [[m[i][k] / sc[i] for k in range(3)] for i in range(3)]
    tr = r[0][0] + r[1][1] + r[2][2]
    if tr > 0:
        q = math.sqrt(tr + 1) * 2; w = 0.25 * q
        x = (r[1][2] - r[2][1]) / q; y = (r[2][0] - r[0][2]) / q; z = (r[0][1] - r[1][0]) / q
    else:
        i = max(range(3), key=lambda k: r[k][k]); j = (i + 1) % 3; k = (i + 2) % 3
        q = math.sqrt(1 + r[i][i] - r[j][j] - r[k][k]) * 2
        v = [0, 0, 0]; v[i] = 0.25 * q; v[j] = (r[i][j] + r[j][i]) / q; v[k] = (r[i][k] + r[k][i]) / q
        w = (r[j][k] - r[k][j]) / q; x, y, z = v
    return t, (w, x, y, z), sc
inserts = {}
for i, j in missing:
    t, q, sc = decompose(mats[i])
    inserts[i] = {'translations': '(%g, %g, %g)' % tuple(t), 'rotations': '(%g, %g, %g, %g)' % q, 'scales': '(%g, %g, %g)' % tuple(sc)}
    print("root rest:", inserts[i])
def patch_block(m):
    name = m.group(1); body = m.group(2)
    def fix(sm):
        vals = re.findall(r'\([^()]*\)', sm.group(2))
        for i in sorted(inserts):
            vals.insert(i, inserts[i][name])
        return sm.group(1) + '[' + ', '.join(vals) + ']'
    body = re.sub(r'(\n\s*[\d.]+: )\[(.*?)\]', fix, body)
    return m.group(0)[:m.start(2) - m.start(0)] + body + ']' if False else m.group(0).replace(m.group(2), body)
for name in ('translations', 'rotations', 'scales'):
    s = re.sub(r'\b(%s)\.timeSamples = \{(.*?)\n\s*\}' % name, patch_block, s, count=1, flags=re.S)
s = re.sub(r'(def SkelAnimation .*?uniform token\[\] joints = )\[(.*?)\]',
           lambda m: m.group(1) + '[' + ', '.join('"%s"' % j for j in skel) + ']', s, count=1, flags=re.S)
open(dst, 'w').write(s)
