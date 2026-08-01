//
//  NeuralAmpBridge.mm
//  StreetRig
//
//  Obj-C++ implementation of the amp-capture JSON loader + the C entry point that
//  builds and installs the model into the kernel. All work here is on the SETUP
//  thread (file I/O + allocation); the built model is handed to the render thread
//  through the processor's atomic swap. See NeuralAmpBridge.h for the schema.
//

#import <Foundation/Foundation.h>

#include <string>
#include <vector>
#include <cstring>
#include <new>

#include "NeuralAmpBridge.h"
#include "NeuralAmpModel.hpp"
#include "../StreetRigDSPKernel.h"
#include "../StreetRigDSPKernelInternal.hpp"

namespace {

/// Recursively flatten an NSArray of numbers (possibly nested) into `out`.
void flattenNumbers(id node, std::vector<float> &out) {
    if ([node isKindOfClass:[NSArray class]]) {
        for (id child in (NSArray *)node) flattenNumbers(child, out);
    } else if ([node isKindOfClass:[NSNumber class]]) {
        out.push_back(((NSNumber *)node).floatValue);
    }
}

std::vector<float> flatArray(NSDictionary *dict, NSString *key) {
    std::vector<float> v;
    flattenNumbers(dict[key], v);
    return v;
}

int intValue(NSDictionary *dict, NSString *key, int fallback) {
    id v = dict[key];
    if ([v isKindOfClass:[NSNumber class]]) return ((NSNumber *)v).intValue;
    return fallback;
}

} // namespace

namespace streetrig {

bool loadNeuralWeightsFromJSON(const char *path, NeuralAmpWeights &out, std::string &err) {
    @autoreleasepool {
        if (!path) { err = "null path"; return false; }
        NSString *p = [NSString stringWithUTF8String:path];
        NSData *data = [NSData dataWithContentsOfFile:p];
        if (!data) { err = "file not found / unreadable"; return false; }

        NSError *jerr = nil;
        id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jerr];
        if (!root || ![root isKindOfClass:[NSDictionary class]]) {
            err = "not a JSON object";
            return false;
        }
        NSDictionary *dict = (NSDictionary *)root;

        // NAM native (.nam) captures use an "architecture" key + flat "weights".
        if (dict[@"architecture"] != nil && dict[@"model_data"] == nil) {
            err = "NAM native format (WaveNet) not supported by the built-in LSTM "
                  "core — export an RTNeural/GuitarML 'SimpleRNN' LSTM JSON instead";
            return false;
        }

        NSDictionary *md = dict[@"model_data"];
        NSDictionary *sd = dict[@"state_dict"];
        if (![md isKindOfClass:[NSDictionary class]] || ![sd isKindOfClass:[NSDictionary class]]) {
            err = "missing 'model_data' or 'state_dict' (unsupported schema)";
            return false;
        }

        NSString *unit = md[@"unit_type"];
        if ([unit isKindOfClass:[NSString class]] &&
            [unit caseInsensitiveCompare:@"LSTM"] != NSOrderedSame) {
            err = std::string("unit_type '") + unit.UTF8String +
                  "' unsupported (only LSTM)";
            return false;
        }

        out.inputSize  = intValue(md, @"input_size", 1);
        out.hiddenSize = intValue(md, @"hidden_size", 0);
        out.numLayers  = intValue(md, @"num_layers", 1);
        out.outputSize = intValue(md, @"output_size", 1);
        out.skip       = intValue(md, @"skip", 0);

        if (out.hiddenSize <= 0 || out.numLayers <= 0) {
            err = "invalid hidden_size / num_layers";
            return false;
        }

        out.weightIH.clear(); out.weightHH.clear(); out.bias.clear();
        out.weightIH.reserve(out.numLayers);
        out.weightHH.reserve(out.numLayers);
        out.bias.reserve(out.numLayers);

        for (int l = 0; l < out.numLayers; ++l) {
            NSString *ih = [NSString stringWithFormat:@"rec.weight_ih_l%d", l];
            NSString *hh = [NSString stringWithFormat:@"rec.weight_hh_l%d", l];
            NSString *bih = [NSString stringWithFormat:@"rec.bias_ih_l%d", l];
            NSString *bhh = [NSString stringWithFormat:@"rec.bias_hh_l%d", l];

            std::vector<float> wih = flatArray(sd, ih);
            std::vector<float> whh = flatArray(sd, hh);
            std::vector<float> b0 = flatArray(sd, bih);
            std::vector<float> b1 = flatArray(sd, bhh);

            if (wih.empty() || whh.empty()) {
                err = std::string("missing weights for layer ") + std::to_string(l);
                return false;
            }
            // bias = bias_ih + bias_hh (PyTorch keeps them separate).
            std::vector<float> bias = b0;
            if (bias.empty()) bias.assign(4 * out.hiddenSize, 0.0f);
            if (b1.size() == bias.size())
                for (size_t i = 0; i < bias.size(); ++i) bias[i] += b1[i];

            out.weightIH.push_back(std::move(wih));
            out.weightHH.push_back(std::move(whh));
            out.bias.push_back(std::move(bias));
        }

        out.denseWeight = flatArray(sd, @"lin.weight");
        out.denseBias   = flatArray(sd, @"lin.bias");
        if (out.denseBias.empty()) out.denseBias.assign(out.outputSize, 0.0f);

        if (!out.valid()) {
            err = "shape mismatch after parse (weights don't match declared sizes)";
            return false;
        }
        return true;
    }
}

} // namespace streetrig

// MARK: - C entry point (declared in StreetRigDSPKernel.h)

bool SRKernelLoadAmpModelJSON(SRKernelRef kernel, const char *path, char *errBuf, int errBufLen) {
    auto writeErr = [&](const std::string &m) {
        if (errBuf && errBufLen > 0) {
            std::strncpy(errBuf, m.c_str(), (size_t)errBufLen - 1);
            errBuf[errBufLen - 1] = '\0';
        }
    };
    if (errBuf && errBufLen > 0) errBuf[0] = '\0';

    auto *k = static_cast<streetrig::DSPKernel *>(kernel);
    if (!k) { writeErr("null kernel"); return false; }

    streetrig::NeuralAmpWeights w;
    std::string err;
    if (!streetrig::loadNeuralWeightsFromJSON(path, w, err)) {
        writeErr(err);
        return false;
    }

    auto *model = new (std::nothrow) streetrig::NeuralAmpModel(w);
    if (!model || !model->isValid()) {
        delete model;
        writeErr("model construction failed");
        return false;
    }

    // Atomic hand-off to the render thread (one-generation retire inside).
    k->processor.installNeuralModel(model);
    return true;
}
