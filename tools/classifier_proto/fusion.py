import json, math, numpy as np
from multiprocessing import Pool
from model import simulate
from features import extract
import nb
def one(args):
    kind, still, seed = args
    rng = np.random.default_rng(seed)
    s = simulate(kind, rng, secs=31.5, still=still)
    out = []
    n = len(s['sig']); w = int(10.5*256)
    for i in range(3):
        sub = dict(s); sl = slice(i*w//1, i*w+w)
        sub['sig'] = s['sig'][sl]; sub['centers'] = s['centers'][sl]; sub['r'] = s['r'][sl]
        f = extract(sub); f.update(kind=kind, still=still, v=float(s['speed']), walls=int(s['nwalls'])); out.append(f)
    return out
if __name__ == '__main__':
    jobs = []
    for i in range(10):
        for k in ['human','dog','cat']:
            jobs.append((k, False, 50000+len(jobs)))
        jobs.append(('fan', False, 50000+len(jobs)))
    with Pool(2) as p: res = p.map(one, jobs)
    P = nb.fit(json.load(open('train.json')))
    ok1 = ok3 = n = 0
    for wins in res:
        c = nb.label(wins[0]); 
        det = [w for w in wins if w['detected']]
        if not det: continue
        n += 1
        st = nb.state(wins[0])
        p1 = nb.classify(P, st, nb.feats(det[0])); ok1 += max(p1, key=p1.get) == c
        L = {k: 0.0 for k in nb.classify(P, st, nb.feats(det[0]))}
        for w in det:
            p = nb.classify(P, st, nb.feats(w))
            for k in p: L[k] += 0.7*math.log(max(p[k], 1e-6))
        ok3 += max(L, key=L.get) == c
    print(f'single window {ok1}/{n}, fused 30 s {ok3}/{n}')
