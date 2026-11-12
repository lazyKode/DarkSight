import numpy as np, sys, json
from multiprocessing import Pool
from model import simulate
from features import extract
def one(args):
    kind, still, seed = args
    rng = np.random.default_rng(seed)
    s = simulate(kind, rng, secs=10, still=still)
    f = extract(s); f.update(kind=kind, still=still, v=float(s['speed']), walls=int(s['nwalls']))
    return f
if __name__ == '__main__':
    base = int(sys.argv[1]); n = int(sys.argv[2])
    jobs = []
    for i in range(n):
        for k in ['human', 'dog', 'cat']:
            jobs.append((k, False, base+len(jobs)))
            if i % 2 == 0: jobs.append((k, True, base+len(jobs)))
        jobs.append(('fan', False, base+len(jobs)))
    with Pool(2) as p: rows = p.map(one, jobs)
    json.dump(rows, open(sys.argv[3], 'w'))
    print(len(rows), 'rows')
