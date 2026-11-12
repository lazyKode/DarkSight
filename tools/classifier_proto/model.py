"""Prototype of the DarkSight track-dwell radar, feature extraction and classifier."""
import numpy as np, math
LAM = 0.125          # 2.4 GHz
N = 256              # samples per chirp
BINS = 200
MAXR = 10.0
PRF = 256.0
G = 4.0              # system gain in the amplitude radar equation a = G*sqrt(rcs)/r^2
WALL = 0.5           # one-way? two-way amplitude loss per wall
ALPHA = 2*math.pi/(N-1)

def dirichlet(w):
    w = np.asarray(w, float)
    s = np.sin(w/2)
    out = np.where(np.abs(s) < 1e-9, N + 0j,
                   np.exp(1j*w*(N-1)/2) * np.sin(N*w/2) / np.where(np.abs(s)<1e-9,1,s))
    return out

def hann_resp(delta):
    """Response of the Hann-windowed range FFT at bin k to a tone at bin k+delta,
    normalised so an on-bin tone of amplitude 1 gives magnitude 1."""
    w = 2*math.pi*np.asarray(delta, float)/N
    return (0.5*dirichlet(w) - 0.25*dirichlet(w+ALPHA) - 0.25*dirichlet(w-ALPHA)) / (N/2)

NOISE_BIN = lambda noise: 0.01*10**(2*noise) * math.sqrt(3*N/8) / (N/2)

# ---------------- body models ----------------
class Body:
    def __init__(self, kind, rng):
        self.kind = kind
        j = lambda s=0.12: 1 + rng.normal(0, s)
        if kind == 'human':
            self.rcs = 0.8*j(0.35)**2; self.legf0, self.legfk = 0.55*j(), 0.35*j()
            self.legA, self.armA = 0.28*j(), 0.2*j()
            self.breath = rng.uniform(12, 20)/60; self.chest = 0.004*j(0.3)
            self.parts = [('torso',0,0,0.6),('arm',0,0.2,0.18),('arm',math.pi,-0.2,0.18),
                          ('leg',math.pi,0.1,0.22),('leg',0,-0.1,0.22)]
        elif kind == 'dog':
            self.rcs = 0.15*j(0.4)**2; self.legf0, self.legfk = 1.2*j(), 0.9*j()
            self.legA = 0.12*j(); self.breath = rng.uniform(18, 34)/60; self.chest = 0.002*j(0.3)
            self.parts = [('torso',0,0,0.7),('leg',0,0.08,0.13),('leg',math.pi,-0.08,0.13),
                          ('leg',math.pi,0.08,0.13),('leg',0,-0.08,0.13)]
            self.legu = [0, 0.25, 0.25, -0.25, -0.25]
        elif kind == 'cat':
            self.rcs = 0.03*j(0.4)**2; self.legf0, self.legfk = 1.8*j(), 1.0*j()
            self.legA = 0.07*j(); self.breath = rng.uniform(20, 36)/60; self.chest = 0.0012*j(0.3)
            self.parts = [('torso',0,0,0.7),('leg',0,0.05,0.13),('leg',math.pi,-0.05,0.13),
                          ('leg',math.pi,0.05,0.13),('leg',0,-0.05,0.13)]
            self.legu = [0, 0.12, 0.12, -0.12, -0.12]
        elif kind == 'fan':
            self.rcs = 0.3*j(0.4)**2; self.rps = rng.uniform(2.0, 4.5); self.blades = 3; self.R = 0.2*j()
        self.phase0 = rng.uniform(0, 2*math.pi)

    def scatterers(self, t, x, y, heading, speed, gait):
        """World scatterers (x, y, amplitude-before-range-loss). gait = leg phase (rad)."""
        out = []
        a0 = G*math.sqrt(self.rcs)
        if self.kind == 'fan':
            out.append((x, y, a0*0.5))
            for b in range(self.blades):
                th = 2*math.pi*self.rps*t + 2*math.pi*b/self.blades + self.phase0
                out.append((x + self.R*math.cos(th), y + self.R*math.sin(th), a0*0.35))
            return out, 0.0
        ch, sh = math.cos(heading), math.sin(heading)
        v = min(speed, 1.8)
        breathe = self.chest*math.sin(2*math.pi*self.breath*t + self.phase0)
        for i, (name, ph, w, frac) in enumerate(self.parts):
            u = 0.0
            if name == 'arm': u = self.armA*v*math.sin(gait + ph)
            elif name == 'leg':
                u = self.legA*v*math.sin(gait + ph)
                if self.kind != 'human': u += self.legu[i]
            px = x + u*ch - w*sh; py = y + u*sh + w*ch
            out.append((px, py, a0*math.sqrt(frac)))
        return out, breathe

    def legf(self, speed):
        if self.kind == 'fan': return 0.0
        return self.legf0 + self.legfk*min(speed, 1.8)

# --------------- dwell simulation ----------------
def simulate(kind, rng, secs=8.0, still=False, walls=None, noise=0.25):
    body = Body(kind, rng)
    r0 = rng.uniform(2.5, 8.0); th0 = rng.uniform(-0.6, 0.6)
    x, y = r0*math.sin(th0), r0*math.cos(th0)
    x0, y0 = x, y
    speed = 0.0 if (still or kind=='fan') else (rng.uniform(0.5,1.6) if kind=='human' else rng.uniform(0.6,2.0) if kind=='dog' else rng.uniform(0.4,1.4))
    heading = rng.uniform(0, 2*math.pi)
    nwalls = rng.integers(0, 3) if walls is None else walls
    att = WALL**nwalls
    # clutter: a few static scatterers near the target range (walls, furniture)
    clutter = [(r0 + rng.uniform(-1, 1), rng.uniform(0.05, 0.4)*G/ r0**2, rng.uniform(0,2*math.pi)) for _ in range(4)]
    nb = int(secs*PRF); dt = 1/PRF
    GATE = 15
    sig = np.zeros((nb, GATE), complex); centers = np.zeros(nb); truth_r = np.zeros(nb)
    gait = rng.uniform(0, 2*math.pi); t = 0.0
    sb = NOISE_BIN(noise)
    turn = rng.normal(0, 0.3)
    for m in range(nb):
        t = m*dt
        heading += turn*dt
        nx = x + speed*math.cos(heading)*dt; ny = y + speed*math.sin(heading)*dt
        if math.hypot(nx - x0, ny - y0) > 1.8:          # stay in the room: turn back
            heading = math.atan2(y0 - y, x0 - x) + rng.normal(0, 0.4)
            nx = x + speed*math.cos(heading)*dt; ny = y + speed*math.sin(heading)*dt
        x, y = nx, ny
        gait += 2*math.pi*body.legf(speed)*dt
        sc, br = body.scatterers(t, x, y, heading, speed, gait)
        r_track = math.hypot(x, y) + 0.05*math.sin(0.9*t + body.phase0)     # smooth track-filter error
        kc = int(round(r_track/MAXR*BINS)); centers[m] = kc; truth_r[m] = math.hypot(x,y)
        ks = kc + np.arange(GATE) - GATE//2
        acc = np.zeros(GATE, complex)
        for (px, py, a) in sc:
            r = math.hypot(px, py) + br
            amp = a*att/(r*r)
            b = r/MAXR*BINS
            acc += amp*np.exp(1j*4*math.pi*r/LAM)*hann_resp(b - ks)
        for (rc, a, ph) in clutter:
            b = rc/MAXR*BINS
            drift = 0.15*math.sin(0.23*t + ph)
            acc += a*(1+0.08*math.sin(0.5*t+ph))*np.exp(1j*(ph+4*math.pi*rc/LAM+drift))*hann_resp(b - ks)
        acc += sb*(rng.standard_normal(GATE)+1j*rng.standard_normal(GATE))/math.sqrt(2)*math.sqrt(2)
        sig[m] = acc
    return dict(sig=sig, centers=centers, r=truth_r, speed=speed, kind=kind, nwalls=nwalls, body=body)
