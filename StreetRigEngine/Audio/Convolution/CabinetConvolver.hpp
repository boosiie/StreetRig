//
//  CabinetConvolver.hpp
//  StreetRig
//
//  Real-time cabinet impulse-response (IR) convolver: uniformly-partitioned
//  overlap-add (UPOLA) FFT convolution built on Accelerate/vDSP. This is the
//  "speaker + mic" voicing of the amp sim — the thing that turns a fizzy raw
//  distortion into a recorded-cab tone.
//
//  WHY partitioned FFT convolution: iOS ships no public convolution-reverb AU;
//  a cab IR (hundreds–thousands of taps) is too long for cheap time-domain FIR
//  at low latency, and a single big FFT would force a huge block. Splitting the
//  IR into fixed B-sample partitions and running a frequency-domain delay line
//  gives LOW, CONSTANT per-hop cost that fits the render deadline, with only B
//  samples of added latency.
//
//  REAL-TIME CONTRACT: the FFT setup, all partition spectra, the FDL, scratch
//  and FIFOs are allocated once in `prepare()` / `setIR()` on the setup thread.
//  `process()` does NO allocation, NO locks, NO I/O — only vDSP calls over
//  preallocated storage. Per-channel state (FDL, accumulator, carry, output
//  FIFO) is independent so a stereo path does not smear across channels. See
//  RealtimeSafety.md.
//

#ifndef STREETRIG_CABINET_CONVOLVER_HPP
#define STREETRIG_CABINET_CONVOLVER_HPP

#include <vector>
#include <Accelerate/Accelerate.h>

namespace streetrig {

class CabinetConvolver {
public:
    static constexpr int kMaxChannels = 2;
    /// Partition / hop size. FFT length is 2*B. B=128 → ~2.7 ms latency @48 kHz,
    /// a good balance of partition count vs. FFT cost for cab-length IRs.
    static constexpr int kPartition = 128;

    CabinetConvolver() = default;
    ~CabinetConvolver();

    CabinetConvolver(const CabinetConvolver &) = delete;
    CabinetConvolver &operator=(const CabinetConvolver &) = delete;

    /// Allocate FFT setup + per-channel state for up to `maxBlock` frames and
    /// `numChannels` channels. Setup thread only (allocates). Safe to call again
    /// to reconfigure. Returns false on allocation failure.
    bool prepare(int maxBlock, int numChannels);

    /// Install an IR (mono, at the render sample rate). Partitions + FFTs it into
    /// the frequency domain and folds the vDSP round-trip scale into the spectra.
    /// Setup thread only (allocates). `len` is clamped to `maxIRSamples()`.
    /// Passing len<=0 installs a unit impulse (transparent cab).
    void setIR(const float *ir, int len);

    /// Longest IR (in samples) the current preparation can hold.
    int maxIRSamples() const noexcept { return kMaxPartitions * kPartition; }

    /// Samples of latency the convolver adds (= partition size once an IR is set).
    int latencySamples() const noexcept { return ready_ ? kPartition : 0; }

    /// True once prepared with a valid IR.
    bool isReady() const noexcept { return ready_; }

    /// Clear all channels' running state (FDL, carry, FIFO). Real-time safe.
    void reset() noexcept;

    /// Convolve `n` samples in place for `channel`. Real-time safe.
    void process(float *buffer, int n, int channel) noexcept;

private:
    static constexpr int kMaxPartitions = 64;   // up to 64*128 = 8192-tap IRs.

    void doHop(int channel) noexcept;           // one B-sample FFT-domain hop.

    // FFT configuration (shared across channels).
    FFTSetup fftSetup_ = nullptr;
    int fftLen_ = 0;        // 2 * kPartition
    int halfLen_ = 0;       // kPartition (unique real-FFT bins)
    int log2n_ = 0;
    int numPartitions_ = 0; // partitions actually used by the current IR
    int numChannels_ = 0;
    int maxBlock_ = 0;
    bool ready_ = false;

    // IR partition spectra (shared): kMaxPartitions × (realp/imagp length halfLen_),
    // pre-scaled by 1/(4*fftLen_) so `process()` needs no output scaling.
    std::vector<float> irReal_;   // [kMaxPartitions * halfLen_]
    std::vector<float> irImag_;

    // Per-channel running state.
    struct ChannelState {
        std::vector<float> fdlReal;     // [kMaxPartitions * halfLen_] frequency delay line
        std::vector<float> fdlImag;
        int fdlWrite = 0;               // ring index of the newest input spectrum
        std::vector<float> inAccum;     // [kPartition] filling input block
        int inFill = 0;
        std::vector<float> carry;       // [kPartition] overlap-add tail
        std::vector<float> fifo;        // output FIFO ring (power-of-two capacity)
        int fifoMask = 0;
        int fifoRead = 0;
        int fifoWrite = 0;
    };
    ChannelState ch_[kMaxChannels];

    // Transient FFT scratch (single-threaded render → shared).
    std::vector<float> timeScratch_;   // [fftLen_]
    std::vector<float> xReal_;         // [halfLen_] current input spectrum
    std::vector<float> xImag_;
    std::vector<float> accReal_;       // [halfLen_] accumulator
    std::vector<float> accImag_;
    std::vector<float> tmpReal_;       // [halfLen_] per-partition product
    std::vector<float> tmpImag_;
};

} // namespace streetrig

#endif /* STREETRIG_CABINET_CONVOLVER_HPP */
