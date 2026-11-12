import json, math, numpy as np
CLS = ['human', 'dog', 'cat', 'machine']
def label(r): return 'machine' if r['kind'] == 'fan' else r['kind']
def state(r): return 'still' if (r['still'] or r['kind'] == 'fan') else 'moving'
def feats(r):
    """Features as the app would have them."""
    f = {}
    f['rcs'] = r.get('rcs_db')
    f['span'] = math.log(max(r['span'], 0.25))
    f['sym'] = r['sym']
    if r['cad_snr'] > 4: f['cad'] = math.log(r['cadence'])
    if state(r) == 'still' and r['breath_snr'] > 4: f['bpm'] = r['breath_bpm']
    return f
def fit(rows):
    P = {}
    for st in ['moving', 'still']:
        for c in CLS:
            sub = [feats(r) for r in rows if r['detected'] and state(r) == st and label(r) == c]
            if not sub: continue
            P[(st, c)] = {}
            for k in ['rcs', 'span', 'sym', 'cad', 'bpm']:
                vals = [f[k] for f in sub if k in f and f[k] is not None]
                if len(vals) >= 4:
                    P[(st, c)][k] = (float(np.mean(vals)), max(float(np.std(vals)), 0.15), len(vals)/len(sub))
    return P
def classify(P, st, f):
    lp = {}
    for c in CLS:
        if (st, c) not in P: continue
        s = 0.0
        for k, (m, sd, avail) in P[(st, c)].items():
            if k in f and f[k] is not None:
                z = (f[k]-m)/sd; s += -0.5*min(z*z, 16) - math.log(sd)
        lp[c] = s
    mx = max(lp.values()); Z = sum(math.exp(v-mx) for v in lp.values())
    return {c: math.exp(v-mx)/Z for c, v in lp.items()}
if __name__ == '__main__':
    tr = json.load(open('train.json')); te = json.load(open('test.json'))
    # still targets carry the RCS their track measured while moving
    rng = np.random.default_rng(0)
    for rows in (tr, te):
        mv = {c: [r['rcs_db'] for r in rows if r['detected'] and state(r)=='moving' and label(r)==c] for c in CLS}
        for r in rows:
            if r['detected'] and r['still'] and r['kind'] != 'fan': r['rcs_db'] = float(rng.choice(mv[label(r)]))
    P = fit(tr)
    for k, v in P.items(): print(k, {a: tuple(round(x, 2) for x in b) for a, b in v.items()})
    conf = {(a, b): 0 for a in CLS for b in CLS}; miss = {c: 0 for c in CLS}; tot = {c: 0 for c in CLS}
    for r in te:
        c = label(r); tot[c] += 1
        if not r['detected']: miss[c] += 1; continue
        p = classify(P, state(r), feats(r))
        conf[(c, max(p, key=p.get))] += 1
    print('\ntrue \\ pred ', CLS, ' missed')
    for a in CLS:
        print(f'{a:8s}', [conf[(a, b)] for b in CLS], miss[a], f'acc {conf[(a,a)]/max(1,tot[a]-miss[a]):.0%} of detected')
