//
//  StreetRig-Bridging-Header.h
//  StreetRig
//
//  Objective-C / C bridging header. Exposes the C++ DSP core's C ABI
//  (StreetRigDSPKernel.h) to Swift so the custom AUAudioUnit can drive it on
//  the audio thread without any Objective-C/ARC on the render path. Wired up
//  via the SWIFT_OBJC_BRIDGING_HEADER build setting in project.pbxproj.
//

#import "Audio/StreetRigDSPKernel.h"
