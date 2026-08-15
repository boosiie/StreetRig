//
//  NeuralAmpModel.cpp
//  StreetRig
//
//  Implementation of the real-time LSTM amp forward pass. See NeuralAmpModel.hpp
//  for the contract. The per-sample cost is O(numLayers * 4 * H * (inSize + H))
//  MACs + O(4H) transcendentals; for a typical capture (1 layer, H=20) that is a
//  few thousand ops/sample — trivially inside the render budget (measured in the
//  offline harness / render-load read-out).
//

#include "NeuralAmpModel.hpp"

#include <algorithm>

namespace streetrig {

bool NeuralAmpWeights::valid() const {
    if (hiddenSize <= 0 || numLayers <= 0 || inputSize <= 0 || outputSize <= 0)
        return false;
    if ((int)weightIH.size() != numLayers ||
        (int)weightHH.size() != numLayers ||
        (int)bias.size() != numLayers)
        return false;
    for (int l = 0; l < numLayers; ++l) {
        const int inSz = (l == 0) ? inputSize : hiddenSize;
        if ((int)weightIH[l].size() != 4 * hiddenSize * inSz) return false;
        if ((int)weightHH[l].size() != 4 * hiddenSize * hiddenSize) return false;
        if ((int)bias[l].size()     != 4 * hiddenSize) return false;
    }
    if ((int)denseWeight.size() != outputSize * hiddenSize) return false;
    if ((int)denseBias.size()   != outputSize) return false;
    return true;
}

NeuralAmpModel::NeuralAmpModel(const NeuralAmpWeights &w) {
    if (!w.valid()) { valid_ = false; return; }

    hidden_     = w.hiddenSize;
    layers_     = w.numLayers;
    inputSize_  = w.inputSize;
    outputSize_ = w.outputSize;
    skip_       = w.skip;

    wih_ = w.weightIH;
    whh_ = w.weightHH;
    b_   = w.bias;
    dw_  = w.denseWeight;
    db_  = w.denseBias;

    inSizeOfLayer_.resize(layers_);
    for (int l = 0; l < layers_; ++l)
        inSizeOfLayer_[l] = (l == 0) ? inputSize_ : hidden_;

    for (int v = 0; v < kMaxVoices; ++v) {
        h_[v].assign((size_t)layers_ * hidden_, 0.0f);
        c_[v].assign((size_t)layers_ * hidden_, 0.0f);
    }

    // Transient scratch (never grows on the audio thread).
    gates_.assign((size_t)4 * hidden_, 0.0f);
    int maxIn = inputSize_ > hidden_ ? inputSize_ : hidden_;
    layerIn_.assign((size_t)maxIn, 0.0f);
    layerOut_.assign((size_t)hidden_, 0.0f);

    valid_ = true;
}

void NeuralAmpModel::reset(int voice) noexcept {
    if (!valid_) return;
    if (voice < 0) {
        for (int v = 0; v < kMaxVoices; ++v) {
            std::fill(h_[v].begin(), h_[v].end(), 0.0f);
            std::fill(c_[v].begin(), c_[v].end(), 0.0f);
        }
    } else if (voice < kMaxVoices) {
        std::fill(h_[voice].begin(), h_[voice].end(), 0.0f);
        std::fill(c_[voice].begin(), c_[voice].end(), 0.0f);
    }
}

float NeuralAmpModel::process(float x, int voice) noexcept {
    if (!valid_) return x;
    if (voice < 0 || voice >= kMaxVoices) voice = 0;

    const int H = hidden_;
    float *hAll = h_[voice].data();
    float *cAll = c_[voice].data();
    float *gates = gates_.data();
    float *in = layerIn_.data();
    float *out = layerOut_.data();

    // Seed layer-0 input with the (single) DI sample.
    in[0] = x;

    for (int l = 0; l < layers_; ++l) {
        const int inSz = inSizeOfLayer_[l];
        const float *Wih = wih_[l].data();   // [4H x inSz]
        const float *Whh = whh_[l].data();   // [4H x H]
        const float *bl  = b_[l].data();     // [4H]
        float *hl = hAll + (size_t)l * H;
        float *cl = cAll + (size_t)l * H;

        // gates[k] = bias + Wih[k,:] . in + Whh[k,:] . h_prev
        const int G = 4 * H;
        for (int k = 0; k < G; ++k) {
            float acc = bl[k];
            const float *wi = Wih + (size_t)k * inSz;
            for (int j = 0; j < inSz; ++j) acc += wi[j] * in[j];
            const float *wh = Whh + (size_t)k * H;
            for (int j = 0; j < H; ++j) acc += wh[j] * hl[j];
            gates[k] = acc;
        }

        // Gate slices (PyTorch order): i=[0,H) f=[H,2H) g=[2H,3H) o=[3H,4H)
        const float *gi = gates;
        const float *gf = gates + H;
        const float *gg = gates + 2 * H;
        const float *go = gates + 3 * H;
        for (int n = 0; n < H; ++n) {
            const float i = sigmoidf(gi[n]);
            const float f = sigmoidf(gf[n]);
            const float g = std::tanh(gg[n]);
            const float o = sigmoidf(go[n]);
            const float cn = f * cl[n] + i * g;
            cl[n] = cn;
            const float hn = o * std::tanh(cn);
            hl[n] = hn;
            out[n] = hn;
        }

        // Output of this layer becomes the input of the next.
        for (int n = 0; n < H; ++n) in[n] = out[n];
    }

    // Dense head: y = denseBias + denseWeight . h_lastLayer  (use out[]).
    float y = db_[0];
    const float *dw = dw_.data();   // first output row [0 x H]
    for (int n = 0; n < H; ++n) y += dw[n] * out[n];

    if (skip_) y += x;
    return y;
}

} // namespace streetrig
