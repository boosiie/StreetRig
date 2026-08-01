//
//  NeuralAmpBridge.h
//  StreetRig
//
//  Obj-C++ bridge that turns a trained amp-capture JSON on disk into a ready
//  NeuralAmpModel and installs it into the C++ kernel. The C entry point
//  (`SRKernelLoadAmpModelJSON`) is declared in the C ABI header StreetRigDSPKernel.h
//  so Swift can call it; the JSON parsing itself is Obj-C++ (NSJSONSerialization)
//  and lives in NeuralAmpBridge.mm. This header exposes the pure-C++ parser for
//  reuse/testing — it is NOT included from Swift (C++ types in the signature).
//
//  SUPPORTED SCHEMA — GuitarML / RTNeural "SimpleRNN" (NeuralPi / Proteus /
//  Automated-GuitarAmpModelling export):
//
//    {
//      "model_data": { "unit_type":"LSTM", "input_size":1, "hidden_size":H,
//                      "num_layers":L, "output_size":1, "skip":0|1 },
//      "state_dict": {
//        "rec.weight_ih_l0":[...4H*inSz], "rec.weight_hh_l0":[...4H*H],
//        "rec.bias_ih_l0":[...4H], "rec.bias_hh_l0":[...4H],   (per layer l)
//        "lin.weight":[...out*H], "lin.bias":[...out]
//      }
//    }
//
//  Gate order is PyTorch i,f,g,o. bias_ih + bias_hh are summed at load. This is
//  the real-time-friendly capture format; NAM WaveNet (.nam with "architecture")
//  is detected and rejected with a clear message (add a WaveNet core to support).
//

#ifndef STREETRIG_NEURAL_AMP_BRIDGE_H
#define STREETRIG_NEURAL_AMP_BRIDGE_H

#include <string>
#include "NeuralAmpModel.hpp"

namespace streetrig {

/// Parse a supported amp-capture JSON at `path` into `out`. Returns false and
/// fills `err` on any problem (missing file, unsupported schema, shape mismatch).
/// Setup thread only (allocates, does file I/O).
bool loadNeuralWeightsFromJSON(const char *path, NeuralAmpWeights &out, std::string &err);

} // namespace streetrig

#endif /* STREETRIG_NEURAL_AMP_BRIDGE_H */
