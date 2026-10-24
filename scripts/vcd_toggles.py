#!/usr/bin/env python3
"""Count bit toggles per signal in a VCD, split into idle/active time using
the tb 'phase_active' marker. Rough activity metric only."""
import sys, collections

def parse(path):
    ids = {}            # id -> (fullname, width)
    scope = []
    vals = {}
    tog = collections.defaultdict(lambda: [0, 0])   # name -> [idle, active]
    phase_id = None
    phase = 0
    t = 0
    with open(path) as f:
        in_defs = True
        for line in f:
            w = line.split()
            if not w:
                continue
            if in_defs:
                if w[0] == '$scope':
                    scope.append(w[2])
                elif w[0] == '$upscope':
                    scope.pop()
                elif w[0] == '$var':
                    width, ident, name = int(w[2]), w[3], w[4]
                    full = '.'.join(scope + [name])
                    if name == 'phase_active':
                        phase_id = ident
                    ids.setdefault(ident, (full, width))
                elif w[0] == '$enddefinitions':
                    in_defs = False
                continue
            c = line[0]
            if c == '#':
                t = int(line[1:])
                continue
            if c in '01xzXZ':
                val, ident = line[0], line[1:].strip()
            elif c in 'bB':
                val, ident = w[0][1:], w[1]
            else:
                continue
            if ident not in ids:
                continue
            name, width = ids[ident]
            old = vals.get(ident)
            vals[ident] = val
            if ident == phase_id:
                phase = 1 if val == '1' else 0
                continue
            if old is None or t == 0:
                continue
            o, n = old.zfill(width), val.zfill(width)
            flips = sum(1 for a, b in zip(o, n) if a != b)
            if name.endswith('.clk'):
                continue          # the clock toggles the same in both cases
            tog[name][phase] += flips
    return tog

if __name__ == '__main__':
    tot = {}
    for p in sys.argv[1:]:
        tg = parse(p)
        idle = sum(v[0] for v in tg.values())
        act = sum(v[1] for v in tg.values())
        tot[p] = (idle, act)
        print(f"{p}: toggles idle={idle} active={act} total={idle+act}")
        top = sorted(tg.items(), key=lambda kv: -(kv[1][0] + kv[1][1]))[:6]
        for n, v in top:
            print(f"    {n:40s} idle={v[0]:8d} active={v[1]:8d}")
