#!/usr/bin/env python3
"""
Generates StreetRig/DemoRiff/demo-riff.wav — the dry DI loop the app plays
when there is no interface plugged in.

WHY SYNTHESISED. A demo riff has to ship inside the binary, which makes it a
licensing question the moment it is a recording of anybody playing anything.
Karplus-Strong is a plucked string from first principles: a noise burst in a
delay line the length of one period, low-pass filtered each time round. It is
original by construction, it is genuinely a struck string rather than an
oscillator, and — the part that matters here — it produces a DRY DI, which is
exactly what an amp sim wants at its input.

It is a PLACEHOLDER by intent. Swap in a real DI recording when there is one;
nothing in the app knows the difference as long as the file keeps its name,
stays mono, and stays 48 kHz.
"""
import math, random, struct, wave, os

FS = 48000
BPM = 120
EIGHTH = 60.0 / BPM / 2          # 0.25 s

def pluck(freq, seconds, decay=0.9965, seed=0):
    """One Karplus-Strong voice."""
    n = max(2, int(round(FS / freq)))
    rnd = random.Random(seed)
    buf = [rnd.uniform(-1.0, 1.0) for _ in range(n)]
    # Soften the initial burst: a real pick is not white noise.
    for _ in range(2):
        buf = [(buf[i] + buf[i - 1]) * 0.5 for i in range(n)]
    out = []
    idx = 0
    for _ in range(int(FS * seconds)):
        cur, nxt = buf[idx], buf[(idx + 1) % n]
        out.append(cur)
        buf[idx] = (cur + nxt) * 0.5 * decay
        idx = (idx + 1) % n
    return out

def note(freq, seconds, seed, damped):
    """A pick with an amplitude envelope. Damped = palm-muted chug."""
    d = 0.988 if damped else 0.9968
    v = pluck(freq, seconds, decay=d, seed=seed)
    a = int(FS * 0.002)                      # 2 ms attack, so it never clicks
    r = int(FS * (0.035 if damped else 0.12))
    for i in range(min(a, len(v))):
        v[i] *= i / a
    for i in range(min(r, len(v))):
        v[len(v) - 1 - i] *= i / r
    return v

# E standard power chords: root + fifth.
E5 = (82.41, 123.47)
G5 = (98.00, 146.83)
A5 = (110.00, 164.81)
D5 = (146.83, 220.00)

# 16 eighths. Chugs on the low E, then the three chords that make it a riff.
# (chord, eighths, damped)
RIFF = [
    (E5, 1, True), (E5, 1, True), (E5, 1, True), (E5, 1, True),
    (G5, 2, False),
    (A5, 2, False),
    (E5, 1, True), (E5, 1, True), (E5, 2, True),
    (D5, 2, False),
    (A5, 2, False),
]

total = int(FS * sum(n for _, n, _ in RIFF) * EIGHTH)
mix = [0.0] * total

pos, seed = 0, 1
for chord, eighths, damped in RIFF:
    dur = eighths * EIGHTH
    # Ring past the slot so chords overlap the way a real one does, except on a
    # chug, which is stopped by the palm and must not bleed into the next hit.
    tail = 0.04 if damped else 0.45
    for k, f in enumerate(chord):
        # Strum, not a block chord: the fifth lands ~9 ms after the root.
        offset = int(FS * 0.009 * k)
        v = note(f, dur + tail, seed, damped)
        seed += 1
        base = pos + offset
        for i, s in enumerate(v):
            j = base + i
            if j < total:
                mix[j] += s * (0.62 if k else 1.0)
    pos += int(FS * dur)

# Loop seam: fade the last 60 ms so the wrap is inaudible.
fade = int(FS * 0.06)
for i in range(fade):
    mix[total - 1 - i] *= i / fade

peak = max(abs(s) for s in mix) or 1.0
# -6 dBFS. A DI that arrives near full scale leaves the amp's input trim
# nothing to do, and the rig is voiced around a real pickup's level.
gain = (10 ** (-6 / 20.0)) / peak
pcm = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s * gain)) * 32767)) for s in mix)

out = os.path.join(os.path.dirname(__file__), "..", "StreetRig", "DemoRiff")
os.makedirs(out, exist_ok=True)
path = os.path.join(out, "demo-riff.wav")
with wave.open(path, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(FS)
    w.writeframes(pcm)

rms = math.sqrt(sum(s * s for s in mix) / len(mix)) * gain
print(f"wrote {path}")
print(f"  {total/FS:.2f}s  {FS} Hz mono  peak {20*math.log10(max(abs(s) for s in mix)*gain):.1f} dBFS  rms {20*math.log10(rms):.1f} dBFS")
