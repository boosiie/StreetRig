//
//  StreetRigEngine.h
//  StreetRigEngine
//
//  Umbrella header for the StreetRigEngine framework — the Clang-module seam that
//  REPLACES the app's old `StreetRig-Bridging-Header.h`. A framework (and a future
//  AUv3 app extension) cannot use a Swift bridging header, so the C ABI of the
//  real-time DSP kernel is exposed here as a public module header instead: the
//  framework's own Swift (StreetRigDSPUnit, RigGraphCompiler) and any client that
//  does `import StreetRigEngine` see the `SRKernel*` / `SRParam*` symbols through
//  this module.
//
//  ONLY the pure-C kernel ABI (StreetRigDSPKernel.h) is public. The C++/Obj-C++
//  implementation (AmpCabProcessor, AnalogAmp, CabinetConvolver, the neural bridge,
//  the pedal chain) stays private to the framework binary and never reaches Swift —
//  keeping the module trivially Swift-importable, exactly as the bridging header did.
//

#import <StreetRigEngine/StreetRigDSPKernel.h>
