//
//  TimeBlockSupport.hpp
//  StreetRig
//
//  The small shared vocabulary the two TIME-BASED blocks (DelayPedal,
//  ReverbPedal) both need, and which nothing else in the engine does. It is a
//  header of inline primitives — there is no .cpp and no state — so both engines
//  keep their own `voiceFor()` table as the single auditable home for their
//  numbers.
//
//  THREE PROBLEMS LIVE HERE, and all three are specific to a RECIRCULATING
//  buffer. Every block before these two was feed-forward: a bad sample left on
//  the next buffer. A delay line and a reverb tank feed their own output back in,
//  so anything that gets in STAYS in.
//
//  1. NaN / Inf NEVER LEAVE A FEEDBACK LOOP. One NaN written into a delay line
//     is read back, multiplied by the feedback coefficient, and written again —
//     forever, and it spreads to every sample that touches it. The output does
//     not just glitch, it goes permanently silent-but-poisoned, and only a
//     `reset()` clears it. `sanitize()` is therefore applied to every value on
//     its way INTO a recirculating buffer, not merely on the way out.
//
//  2. DENORMALS STALL THE CPU MINUTES AFTER THE LAST NOTE. A reverb tail decays
//     exponentially and never mathematically reaches zero, so its state values
//     eventually fall into the denormal range (< ~1.18e-38). Denormal arithmetic
//     traps to microcode on several cores and can cost 100× a normal multiply —
//     which shows up as a render-load spike on a SILENT rig, long after the
//     player stopped playing, and is one of the classic ways an amp sim starts
//     dropping out for "no reason". `flushDenormal()` zeroes a recursive state
//     value once it is far below audibility (1e-20 ≈ −400 dBFS) and therefore
//     long before it can become denormal.
//
//  3. FRACTIONAL READS. The read pointer of a delay line is almost never an
//     integer, and rounding it is what makes a swept delay sound gritty.
//     `interpLinear` is enough for a static or slowly-moving pointer;
//     `interpHermite` (4-point, 3rd-order) is what the tape and BBD voicings
//     need, because their pointers move fast enough for linear interpolation's
//     low-pass error and aliasing to be audible ON the repeats.
//
//  REAL-TIME CONTRACT: every function here is a handful of arithmetic ops, no
//  allocation, no branching on anything unbounded. See RealtimeSafety.md.
//

#ifndef STREETRIG_TIME_BLOCK_SUPPORT_HPP
#define STREETRIG_TIME_BLOCK_SUPPORT_HPP

#include <cmath>

namespace streetrig {

/// The magnitude below which a recursive state value is treated as zero. Far
/// above the float denormal threshold (1.18e-38) so denormals can never form,
/// and far below audibility (−400 dBFS) so nothing musical is lost.
inline constexpr float kDenormalFloor = 1.0e-20f;

/// Hard ceiling on any sample stored in a recirculating buffer. Well above any
/// musical level (a hot amp output peaks near 1.0), so it never colours the
/// sound — it exists purely so a runaway loop is BOUNDED rather than exponential
/// while the feedback clamp and the sanitizer bring it back down.
inline constexpr float kLineCeiling = 8.0f;

/// Flush a decayed recursive state to zero. Call on filter / envelope memory
/// that decays exponentially; skip it on straight-through sample paths, where it
/// would cost a compare for nothing.
inline float flushDenormal(float x) noexcept {
    return (x > -kDenormalFloor && x < kDenormalFloor) ? 0.0f : x;
}

/// Make a value SAFE TO STORE in a recirculating buffer: NaN and Inf become
/// silence, everything else is clamped to a bounded range, and decayed values
/// are flushed. This is the one gate every write into a delay line or reverb
/// tank passes through.
inline float sanitize(float x) noexcept {
    if (!std::isfinite(x)) return 0.0f;
    if (x > kLineCeiling)  return kLineCeiling;
    if (x < -kLineCeiling) return -kLineCeiling;
    return flushDenormal(x);
}

/// Linear interpolation between two adjacent buffer samples. Cheap, and its
/// error is a gentle low-pass that only matters when the read pointer MOVES.
inline float interpLinear(const float *buf, int mask, float readPos) noexcept {
    const int i0 = (int)readPos;
    const float frac = readPos - (float)i0;
    const float a = buf[i0 & mask];
    const float b = buf[(i0 + 1) & mask];
    return a + frac * (b - a);
}

/// 4-point, 3rd-order Hermite interpolation (the Laurent de Soras form). About
/// eight more multiplies than linear, and worth every one on a pointer that is
/// being swept: it is what keeps the tape and BBD repeats from acquiring a
/// gritty, aliased edge as the wow/flutter LFOs move the read position.
inline float interpHermite(const float *buf, int mask, float readPos) noexcept {
    const int i1 = (int)readPos;
    const float frac = readPos - (float)i1;
    const float xm1 = buf[(i1 - 1) & mask];
    const float x0  = buf[i1 & mask];
    const float x1  = buf[(i1 + 1) & mask];
    const float x2  = buf[(i1 + 2) & mask];

    const float c = (x1 - xm1) * 0.5f;
    const float v = x0 - x1;
    const float w = c + v;
    const float a = w + v + (x2 - x0) * 0.5f;
    const float bNeg = w + a;
    return ((a * frac - bNeg) * frac + c) * frac + x0;
}

/// A one-pole smoothing coefficient for a given time constant, evaluated on the
/// SETUP thread (it calls `exp`). `y += coeff * (target - y)` per sample.
inline float onePoleCoeff(double sampleRate, double tauSeconds) noexcept {
    if (sampleRate <= 0.0 || tauSeconds <= 0.0) return 1.0f;
    return (float)(1.0 - std::exp(-1.0 / (tauSeconds * sampleRate)));
}

/// Smallest power of two >= n (n >= 1). Used to size every ring buffer so the
/// read/write pointers can wrap with a mask instead of a modulo.
inline int nextPowerOfTwo(int n) noexcept {
    int p = 1;
    while (p < n && p < (1 << 30)) p <<= 1;
    return p;
}

/// A DETERMINISTIC noise source. Deterministic matters: the offline harness
/// renders the same rig twice and compares, so a `rand()` would make the BBD
/// voicing untestable. 32-bit xorshift, one shift-xor triple per sample, output
/// in [-1, 1).
struct LcgNoise {
    unsigned int state = 0x9E3779B9u;
    inline float next() noexcept {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return (float)((int)(state >> 8) - 8388608) * (1.0f / 8388608.0f);
    }
    inline void reset(unsigned int seed) noexcept { state = seed ? seed : 0x9E3779B9u; }
};

} // namespace streetrig

#endif /* STREETRIG_TIME_BLOCK_SUPPORT_HPP */
