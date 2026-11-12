import numpy as np, math
from model import PRF, LAM, MAXR, BINS, G, WALL, hann_resp, NOISE_BIN
NFFT = 64; HOP = 8; COLS_PER_S = PRF/HOP
VRES = LAM/2*PRF/NFFT
WIN = np.hanning(NFFT)
GATE = 15
SUM_RESP = float(np.sum(np.abs(hann_resp(np.arange(-7, 8)))**2))

def mti(sig, centers, tau=3.0):
    """Clutter map over absolute range bins (exponential average, time constant tau)."""
    a = 1 - math.exp(-1/(PRF*tau))
    clutter = np.zeros(400, complex); seen = np.zeros(400, bool)
    out = np.zeros_like(sig)
    off = np.arange(GATE) - GATE//2
    for m in range(sig.shape[0]):
        ks = int(centers[m]) + off + 100
        new = ~seen[ks]
        clutter[ks[new]] = sig[m, new]; seen[ks] = True
        c = clutter[ks]
        out[m] = sig[m] - c
        clutter[ks] = c + a*(sig[m] - c)
    return out

def gate_sum(y, centers):
    """Coherent range-gate sum. Alternating sign over absolute bins equals the
    mid-chirp time sample restricted to the gate, so a target keeps a steady
    phase as the gate follows it bin to bin."""
    off = np.arange(GATE) - GATE//2
    k = centers.astype(int)[:, None] + off[None, :]
    return np.sum(y * np.where(k % 2 == 0, 1.0, -1.0), axis=1)

def spectrogram(s):
    cols = []
    for end in range(NFFT, len(s)+1, HOP):
        S = np.fft.fftshift(np.fft.fft(s[end-NFFT:end]*WIN))
        cols.append(np.abs(S)**2)
    return np.array(cols)

def noise_per_doppler_bin(noise):
    sb = NOISE_BIN(noise)
    return 2*sb*sb*np.sum(WIN**2)*GATE   # complex noise, both components

def extract(sim, noise=0.25):
    sig, centers = sim['sig'], sim['centers']
    y = mti(sig, centers)
    g = gate_sum(y, centers)
    S = spectrogram(g)[int(1.5*COLS_PER_S):]
    nf = noise_per_doppler_bin(noise)
    v = (np.arange(NFFT) - NFFT//2)*VRES
    det = (S > nf*10**1.0) & (S > S.max(axis=1, keepdims=True)*10**-2.5)
    f = {}
    excess = S.sum(axis=1)/(NFFT*nf) - 1          # in-band energy over noise
    active = excess > 0.6
    f['detected'] = bool(active.mean() > 0.5)
    if not f['detected']: return f
    pk = np.argmax(S, axis=1)
    vt = v[pk]
    hi = np.array([v[np.nonzero(d)[0]].max() if d.any() else 0 for d in det])
    lo = np.array([v[np.nonzero(d)[0]].min() if d.any() else 0 for d in det])
    det[~active] = False
    span = (hi - lo)[active]
    f['span'] = float(np.percentile(span, 80))
    f['vt'] = float(np.median(np.abs(vt[active])))
    # symmetry: rotating machinery spreads evenly either side of zero
    f['sym'] = float(np.median(np.minimum(hi, -lo)[active] / np.maximum(np.maximum(hi, -lo)[active], VRES)))
    # cadence-velocity diagram: periodicity of each Doppler bin's power
    L = np.log(S + nf)
    L = L - np.apply_along_axis(lambda c: np.convolve(c, np.ones(16)/16, 'same'), 0, L)  # high-pass ~2 Hz
    n = L.shape[0]
    C = np.abs(np.fft.rfft(L*np.hanning(n)[:, None], 512, axis=0))
    fr = np.fft.rfftfreq(512, 1/COLS_PER_S)
    weight = (S.mean(axis=0) > nf*10**0.8).astype(float)   # bins with signal
    cvd = (C*weight[None, :]).sum(axis=1)
    band = (fr >= 1.0) & (fr <= 15)
    k = int(np.argmax(np.where(band, cvd, 0)))
    f['cadence'] = float(fr[k]); f['cad_snr'] = float(cvd[k]/(np.median(cvd[band])+1e-12))
    start = int(1.5*PRF)
    p = np.mean(np.sum(np.abs(y[start:])**2, axis=1)) - 2*NOISE_BIN(noise)**2*GATE
    a2 = max(p, 1e-12)/SUM_RESP
    r = float(np.median(sim['r']))
    f['rcs_db'] = 10*math.log10(a2*r**4/G**2/(WALL**(2*sim['nwalls'])) + 1e-12)
    yb = g[start:]
    dec = yb[:len(yb)//16*16].reshape(-1, 16).mean(axis=1)
    z = np.vstack([dec.real - dec.real.mean(), dec.imag - dec.imag.mean()])
    w, V = np.linalg.eigh(z @ z.T)
    s1 = V[:, -1] @ z
    B = np.abs(np.fft.rfft(s1*np.hanning(len(s1)), 2048))
    fb = np.fft.rfftfreq(2048, 1/16)
    bb = (fb > 0.12) & (fb < 0.9)
    kb = int(np.argmax(np.where(bb, B, 0)))
    f['breath_bpm'] = float(fb[kb]*60); f['breath_snr'] = float(B[kb]/(np.median(B[(fb>0.1)&(fb<3)])+1e-12))
    return f
