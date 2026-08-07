//
//  NeuralAmpModel.hpp
//  StreetRig
//
//  Self-contained C++ neural amp inference core (RTNeural / GuitarML "SimpleRNN"
//  LSTM architecture — the de-facto real-time amp-capture format used by
//  NeuralPi / Proteus / Automated-GuitarAmpModelling). This is the "amp/preamp"
//  nonlinearity of the sim: a small stacked-LSTM + dense head that maps one input
//  sample (the DI) to one output sample, carrying its own recurrent state.
//
//  WHY roll our own instead of vendoring RTNeural/NAM: the task forbids network
//  downloads, and this architecture is tiny and well understood. The math here is
//  byte-for-byte the PyTorch `nn.LSTM` + `nn.Linear` forward pass with the
//  standard i,f,g,o gate ordering, so a REAL GuitarML/RTNeural capture JSON drops
//  straight in (see NeuralAmpBridge for the JSON schema). Eigen is intentionally
//  NOT required — the matrices are small enough that plain loops are faster than
//  the call overhead and keep us dependency-free.
//
//  REAL-TIME CONTRACT: `process()` performs NO allocation, NO locking, NO I/O. All
//  weight/state storage is allocated once at construction (main/setup thread). The
//  render thread only ever calls `process()` / `reset()`. Recurrent state is kept
//  per "voice" (audio channel) so a stereo path never crosstalks its LSTM memory.
//  See RealtimeSafety.md.
//

#ifndef STREETRIG_NEURAL_AMP_MODEL_HPP
#define STREETRIG_NEURAL_AMP_MODEL_HPP

#include <vector>
#include <cstdint>
#include <cmath>

namespace streetrig {

/// Plain-old-data description of a trained model, as parsed from JSON on the
/// setup thread. All weight arrays are row-major and flattened exactly as
/// PyTorch stores them; gate ordering for the LSTM blocks is i, f, g, o.
struct NeuralAmpWeights {
    int inputSize  = 1;   ///< Samples in per step (guitar DI = 1).
    int hiddenSize = 0;   ///< LSTM hidden units per layer.
    int numLayers  = 1;   ///< Stacked LSTM layers.
    int outputSize = 1;   ///< Dense head outputs (audio out = 1).
    int skip       = 0;   ///< 1 => residual: output += input sample.

    // Per layer (size numLayers). Each weight_ih is [4*hidden x inSize_l],
    // weight_hh is [4*hidden x hidden], bias is [4*hidden] (ih+hh already summed).
    std::vector<std::vector<float>> weightIH;
    std::vector<std::vector<float>> weightHH;
    std::vector<std::vector<float>> bias;

    // Dense head: [outputSize x hiddenSize] and [outputSize].
    std::vector<float> denseWeight;
    std::vector<float> denseBias;

    /// Basic shape sanity — the bridge rejects a model that fails this so the
    /// render thread never sees a malformed capture.
    bool valid() const;
};

/// Real-time LSTM amp. Immutable weights + per-voice recurrent state. Construct
/// off the audio thread; call `process()` on the audio thread.
class NeuralAmpModel {
public:
    static constexpr int kMaxVoices = 2;

    /// Build from parsed weights. Copies the weights in (setup thread). If the
    /// weights are invalid the instance is left `!isValid()` and must be dropped.
    explicit NeuralAmpModel(const NeuralAmpWeights &w);

    bool isValid() const noexcept { return valid_; }
    int  hiddenSize() const noexcept { return hidden_; }
    int  numLayers()  const noexcept { return layers_; }

    /// Clear all recurrent state for one voice (or all voices if voice < 0).
    /// Real-time safe.
    void reset(int voice = -1) noexcept;

    /// One-sample forward pass for `voice` (0..kMaxVoices-1). Real-time safe:
    /// touches only preallocated buffers. `x` is the (already input-gained) DI
    /// sample; returns the modeled amp output sample.
    float process(float x, int voice) noexcept;

private:
    bool valid_ = false;
    int  hidden_ = 0;
    int  layers_ = 0;
    int  inputSize_ = 1;
    int  outputSize_ = 1;
    int  skip_ = 0;

    // Flattened weights, one entry per layer.
    std::vector<std::vector<float>> wih_;   // [4H x inSize_l]
    std::vector<std::vector<float>> whh_;   // [4H x H]
    std::vector<std::vector<float>> b_;     // [4H]
    std::vector<int> inSizeOfLayer_;
    std::vector<float> dw_;                 // [outputSize x H]
    std::vector<float> db_;                 // [outputSize]

    // Per-voice recurrent state: h_[voice][layer*H + n], c_ likewise.
    std::vector<float> h_[kMaxVoices];
    std::vector<float> c_[kMaxVoices];

    // Transient gate scratch (single-threaded render → shared across voices).
    std::vector<float> gates_;              // [4H]
    std::vector<float> layerIn_;            // [max(inputSize,H)]
    std::vector<float> layerOut_;           // [H]

    static inline float sigmoidf(float v) noexcept { return 1.0f / (1.0f + std::exp(-v)); }
};

} // namespace streetrig

#endif /* STREETRIG_NEURAL_AMP_MODEL_HPP */
