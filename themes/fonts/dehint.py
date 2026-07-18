import sys
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables import ttProgram

def dehint(path):
    f = TTFont(path)
    n_instr = 0
    if 'glyf' in f:
        glyf = f['glyf']
        for name in glyf.keys():
            g = glyf[name]
            if hasattr(g, 'program'):
                bc = g.program.getBytecode()
                if bc:
                    n_instr += 1
                g.program = ttProgram.Program()
                g.program.fromBytecode(b'')
    removed = []
    for t in ('fpgm', 'prep', 'cvt ', 'gasp'):
        if t in f:
            del f[t]; removed.append(t.strip())
    mp = f['maxp']
    for attr in ('maxSizeOfInstructions','maxStorage','maxFunctionDefs',
                 'maxInstructionDefs','maxStackElements','maxTwilightPoints','maxZones'):
        if hasattr(mp, attr):
            setattr(mp, attr, 0)
    f.save(path)
    print(f"  {path.split('/')[-1]:26} glyphs_hinted={n_instr:5} removed={removed}")

for p in sys.argv[1:]:
    dehint(p)
