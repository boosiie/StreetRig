//
//  CabinetConvolver.cpp
//  StreetRig
//
//  Uniformly-partitioned overlap-add FFT convolution via vDSP. See the header for
//  the real-time contract and the scaling derivation summary below.
//
//  Scaling: vDSP's real FFT (`vDSP_fft_zrip`) forward transform returns 2·DFT and
//  its inverse returns fftLen·(normalized IDFT). For y = IFFT(FFT(x)·H) to equal
//  the true linear convolution x*h, the IR spectra are pre-scaled by 1/(4·fftLen)
//  at `setIR()` time, so `process()` needs no output scaling. This is verified in
//  the offline harness by convolving a unit impulse and confirming the output
//  reproduces the IR.
//

#include "CabinetConvolver.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace streetrig {

namespace {
int nextPow2(int v) {
    int p = 1;
    while (p < v) p <<= 1;
    return p;
}
int ilog2(int v) {
    int l = 0;
    while ((1 << l) < v) ++l;
    return l;
}
} // namespace

CabinetConvolver::~CabinetConvolver() {
    if (fftSetup_) { vDSP_destroy_fftsetup(fftSetup_); fftSetup_ = nullptr; }
}

bool CabinetConvolver::prepare(int maxBlock, int numChannels) {
    if (numChannels < 1) numChannels = 1;
    if (numChannels > kMaxChannels) numChannels = kMaxChannels;
    if (maxBlock < 1) maxBlock = 1;

    numChannels_ = numChannels;
    maxBlock_ = maxBlock;
    fftLen_ = 2 * kPartition;
    halfLen_ = kPartition;
    log2n_ = ilog2(fftLen_);

    if (fftSetup_) { vDSP_destroy_fftsetup(fftSetup_); fftSetup_ = nullptr; }
    fftSetup_ = vDSP_create_fftsetup((vDSP_Length)log2n_, kFFTRadix2);
    if (!fftSetup_) { ready_ = false; return false; }

    irReal_.assign((size_t)kMaxPartitions * halfLen_, 0.0f);
    irImag_.assign((size_t)kMaxPartitions * halfLen_, 0.0f);

    timeScratch_.assign((size_t)fftLen_, 0.0f);
    xReal_.assign((size_t)halfLen_, 0.0f);
    xImag_.assign((size_t)halfLen_, 0.0f);
    accReal_.assign((size_t)halfLen_, 0.0f);
    accImag_.assign((size_t)halfLen_, 0.0f);
    tmpReal_.assign((size_t)halfLen_, 0.0f);
    tmpImag_.assign((size_t)halfLen_, 0.0f);

    const int fifoCap = nextPow2(4 * kPartition + maxBlock_);
    for (int c = 0; c < kMaxChannels; ++c) {
        auto &s = ch_[c];
        s.fdlReal.assign((size_t)kMaxPartitions * halfLen_, 0.0f);
        s.fdlImag.assign((size_t)kMaxPartitions * halfLen_, 0.0f);
        s.inAccum.assign((size_t)kPartition, 0.0f);
        s.carry.assign((size_t)kPartition, 0.0f);
        s.fifo.assign((size_t)fifoCap, 0.0f);
        s.fifoMask = fifoCap - 1;
        s.fdlWrite = 0;
        s.inFill = 0;
        s.fifoRead = 0;
        s.fifoWrite = 0;
    }

    // Default to a transparent (unit-impulse) IR until a real one is installed.
    setIR(nullptr, 0);
    return true;
}

void CabinetConvolver::setIR(const float *ir, int len) {
    if (!fftSetup_) return;

    // Unit impulse fallback keeps the cab transparent when no IR is supplied.
    float unit = 1.0f;
    if (!ir || len <= 0) { ir = &unit; len = 1; }

    int maxLen = maxIRSamples();
    if (len > maxLen) len = maxLen;

    numPartitions_ = (len + kPartition - 1) / kPartition;
    if (numPartitions_ < 1) numPartitions_ = 1;
    if (numPartitions_ > kMaxPartitions) numPartitions_ = kMaxPartitions;

    const float scale = 1.0f / (4.0f * (float)fftLen_);

    for (int p = 0; p < numPartitions_; ++p) {
        // time = [ ir chunk (kPartition) | zeros (kPartition) ]
        std::memset(timeScratch_.data(), 0, sizeof(float) * (size_t)fftLen_);
        const int off = p * kPartition;
        const int take = (off + kPartition <= len) ? kPartition : (len - off);
        for (int i = 0; i < take; ++i) timeScratch_[i] = ir[off + i];

        DSPSplitComplex sc{ &irReal_[(size_t)p * halfLen_], &irImag_[(size_t)p * halfLen_] };
        vDSP_ctoz(reinterpret_cast<const DSPComplex *>(timeScratch_.data()), 2, &sc, 1, (vDSP_Length)halfLen_);
        vDSP_fft_zrip(fftSetup_, &sc, 1, (vDSP_Length)log2n_, FFT_FORWARD);

        // Fold the round-trip scale into the IR spectra.
        vDSP_vsmul(sc.realp, 1, &scale, sc.realp, 1, (vDSP_Length)halfLen_);
        vDSP_vsmul(sc.imagp, 1, &scale, sc.imagp, 1, (vDSP_Length)halfLen_);
    }
    // Zero any stale partitions above the current count.
    for (int p = numPartitions_; p < kMaxPartitions; ++p) {
        std::memset(&irReal_[(size_t)p * halfLen_], 0, sizeof(float) * (size_t)halfLen_);
        std::memset(&irImag_[(size_t)p * halfLen_], 0, sizeof(float) * (size_t)halfLen_);
    }

    reset();
    ready_ = true;
}

void CabinetConvolver::reset() noexcept {
    for (int c = 0; c < kMaxChannels; ++c) {
        auto &s = ch_[c];
        if (!s.fdlReal.empty()) std::fill(s.fdlReal.begin(), s.fdlReal.end(), 0.0f);
        if (!s.fdlImag.empty()) std::fill(s.fdlImag.begin(), s.fdlImag.end(), 0.0f);
        if (!s.carry.empty())   std::fill(s.carry.begin(), s.carry.end(), 0.0f);
        std::fill(s.inAccum.begin(), s.inAccum.end(), 0.0f);
        s.fdlWrite = 0;
        s.inFill = 0;
        // Seed the output FIFO with kPartition zeros = the convolver's latency.
        std::fill(s.fifo.begin(), s.fifo.end(), 0.0f);
        s.fifoRead = 0;
        s.fifoWrite = kPartition & s.fifoMask;
    }
}

void CabinetConvolver::doHop(int channel) noexcept {
    auto &s = ch_[channel];

    // Forward FFT of [inAccum | zeros].
    std::memset(timeScratch_.data(), 0, sizeof(float) * (size_t)fftLen_);
    std::memcpy(timeScratch_.data(), s.inAccum.data(), sizeof(float) * (size_t)kPartition);

    DSPSplitComplex xs{ xReal_.data(), xImag_.data() };
    vDSP_ctoz(reinterpret_cast<const DSPComplex *>(timeScratch_.data()), 2, &xs, 1, (vDSP_Length)halfLen_);
    vDSP_fft_zrip(fftSetup_, &xs, 1, (vDSP_Length)log2n_, FFT_FORWARD);

    // Store this hop's spectrum at the newest FDL slot.
    const int w = s.fdlWrite;
    std::memcpy(&s.fdlReal[(size_t)w * halfLen_], xReal_.data(), sizeof(float) * (size_t)halfLen_);
    std::memcpy(&s.fdlImag[(size_t)w * halfLen_], xImag_.data(), sizeof(float) * (size_t)halfLen_);

    // Accumulator = Σ_p H_p · X_{n-p} (complex). Bin 0 is packed (DC in realp[0],
    // Nyquist in imagp[0]) → handle it as two real products; bins 1..halfLen-1
    // are ordinary complex multiplies via vDSP.
    std::memset(accReal_.data(), 0, sizeof(float) * (size_t)halfLen_);
    std::memset(accImag_.data(), 0, sizeof(float) * (size_t)halfLen_);
    const vDSP_Length nComplex = (vDSP_Length)(halfLen_ - 1);

    for (int p = 0; p < numPartitions_; ++p) {
        int slot = w - p;
        if (slot < 0) slot += numPartitions_;
        float *Xr = &s.fdlReal[(size_t)slot * halfLen_];
        float *Xi = &s.fdlImag[(size_t)slot * halfLen_];
        float *Hr = &irReal_[(size_t)p * halfLen_];
        float *Hi = &irImag_[(size_t)p * halfLen_];

        // Packed bin 0: DC and Nyquist are real.
        accReal_[0] += Xr[0] * Hr[0];
        accImag_[0] += Xi[0] * Hi[0];

        if (nComplex > 0) {
            DSPSplitComplex Xs{ Xr + 1, Xi + 1 };
            DSPSplitComplex Hs{ Hr + 1, Hi + 1 };
            DSPSplitComplex Ts{ tmpReal_.data() + 1, tmpImag_.data() + 1 };
            vDSP_zvmul(&Xs, 1, &Hs, 1, &Ts, 1, nComplex, 1);   // T = X·H (flag 1 = no conjugate)
            vDSP_vadd(accReal_.data() + 1, 1, tmpReal_.data() + 1, 1, accReal_.data() + 1, 1, nComplex);
            vDSP_vadd(accImag_.data() + 1, 1, tmpImag_.data() + 1, 1, accImag_.data() + 1, 1, nComplex);
        }
    }

    // Inverse FFT → time domain (length fftLen_).
    DSPSplitComplex accs{ accReal_.data(), accImag_.data() };
    vDSP_fft_zrip(fftSetup_, &accs, 1, (vDSP_Length)log2n_, FFT_INVERSE);
    vDSP_ztoc(&accs, 1, reinterpret_cast<DSPComplex *>(timeScratch_.data()), 2, (vDSP_Length)halfLen_);

    // Overlap-add: out = time[0..B-1] + carry; new carry = time[B..2B-1].
    for (int i = 0; i < kPartition; ++i) {
        float y = timeScratch_[i] + s.carry[i];
        s.fifo[s.fifoWrite] = y;
        s.fifoWrite = (s.fifoWrite + 1) & s.fifoMask;
    }
    std::memcpy(s.carry.data(), timeScratch_.data() + kPartition, sizeof(float) * (size_t)kPartition);

    s.fdlWrite = (w + 1) % numPartitions_;
}

void CabinetConvolver::process(float *buffer, int n, int channel) noexcept {
    if (!ready_ || channel < 0 || channel >= numChannels_ || !buffer || n <= 0) return;
    auto &s = ch_[channel];

    for (int i = 0; i < n; ++i) {
        s.inAccum[s.inFill++] = buffer[i];
        if (s.inFill == kPartition) {
            doHop(channel);
            s.inFill = 0;
        }
        buffer[i] = s.fifo[s.fifoRead];
        s.fifoRead = (s.fifoRead + 1) & s.fifoMask;
    }
}

} // namespace streetrig
