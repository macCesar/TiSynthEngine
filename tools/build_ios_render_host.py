#!/usr/bin/env python3
"""Build a host harness from the actual ObjC callback, without AVAudioEngine.

Only the hardware/Titanium lifecycle is replaced. DSP helpers, voice methods,
queue consumption and the render block body are copied verbatim from --source.
The callback's mach clock is fixed for repeatable noise seeds and disabled stats;
external CLOCK_THREAD_CPUTIME_ID / MONOTONIC clocks measure its work instead.
This is the Apple renderer on macOS, not physical iPad real-time acceptance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
METHODS = ["clearVoices", "updatePanGainsForVoice", "findTailSlot",
           "snapshotTailFromVoice", "fadeOutAllVoices", "canAdmitCount",
           "findVoiceSlotForCommand", "startVoiceFromCommand", "enqueueCommand",
           "applyHeldCommand", "sequenceGateEnded", "renderSequenceFrame",
           "pruneVoiceMetadata", "publishSequence", "maxFrequencyHz",
           "acceptValidation", "warnOnceMethod", "voiceMaskForId", "updateVoice"]
EVENT_METHODS = ["scheduleSequencePoll", "cancelSequencePoll", "drainSequenceEvents"]


def extract(source):
    prefix = source[source.index("#define DEFAULT_SAMPLE_RATE"):source.index("@interface TiSynthengineModule ()")]
    ivars = source.split("@interface TiSynthengineModule () {", 1)[1].split("\n}\n@end", 1)[0]
    methods = []
    for name in METHODS + EVENT_METHODS:
        match = re.search(r"^- \([^\n]+\)" + name + r"(?=[:\s])", source, re.M)
        if not match:
            if name in EVENT_METHODS:
                continue
            raise ValueError("Missing production method: " + name)
        opening = source.index("{", match.start())
        # Selected methods contain balanced braces, no braces in string literals.
        depth = 1
        end = opening + 1
        while depth:
            depth += (source[end] == "{") - (source[end] == "}")
            end += 1
        methods.append(source[match.start():end])
    anchor = "#pragma unused(isSilence, timestamp)"
    block = source[source.index(anchor):source.index("\n    };", source.index(anchor))]
    return prefix, ivars, methods, block


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--source", type=Path, default=ROOT)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--optimization", choices=["-Os", "-O3", "-O0"], default="-Os")
    args = p.parse_args()
    source_root = args.source.resolve()
    source_path = source_root / "ios/Classes/TiSynthengineModule.m"
    prefix, ivars, methods, block = extract(source_path.read_text())
    has_event_poll = any("scheduleSequencePoll" in m.split("{", 1)[0] for m in methods)
    imports = '''#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <dispatch/dispatch.h>
#include <limits.h>
#include <stdint.h>
#include <stdbool.h>
#include <assert.h>
#include <stddef.h>
#include <time.h>
#include <sys/resource.h>
#include <malloc/malloc.h>
#include <pthread/qos.h>
#define DebugLog(...) ((void)0)
@class AVAudioEngine, AVAudioSourceNode;
typedef NSString *AVAudioSessionCategory;
typedef uint32_t AVAudioFrameCount;
static uint64_t synth_host_seed_clock(void) { return 1; }
#define mach_absolute_time synth_host_seed_clock
'''
    for header in ["synth_core", "synth_effects", "synth_held", "synth_retrigger", "synth_modulation", "synth_spatial", "synth_stats", "synth_transport"]:
        imports += '#include "' + str(source_root / "shared" / (header + ".h")) + '"\n'
    imports += '#import "' + str(source_root / "ios/Classes/TiSynthengineContract.h") + '"\n'
    declarations = "\n".join(m[:m.index("{")].strip() + ";" for m in methods)
    if has_event_poll:
        imports += "#define SYNTH_HOST_HAS_EVENT_POLL 1\n"
        declarations += "\n- (void)fireEvent:(NSString *)name withObject:(NSDictionary *)event;"
        methods.append("- (void)fireEvent:(NSString *)name withObject:(NSDictionary *)event { (void)name; (void)event; }")
    generated = (imports + prefix + "\n@interface RenderRig : NSObject { @public\n" + ivars +
                 "\n}\n" + declarations + "\n- (OSStatus)render:(AVAudioFrameCount)frameCount output:(AudioBufferList *)outputData;\n@end\n" +
                 "@implementation RenderRig\n" + "\n".join(methods) +
                 "\n- (OSStatus)render:(AVAudioFrameCount)frameCount output:(AudioBufferList *)outputData {\n" +
                 "__unsafe_unretained RenderRig *module=self; BOOL *isSilence=NULL; const AudioTimeStamp *timestamp=NULL;\n" + block +
                 "\n}\n@end\n" + (ROOT / "tests/ios_render_host.m").read_text())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    generated_path = args.output.with_suffix(".m")
    generated_path.write_text(generated)
    command = ["clang", "-std=c99", "-fobjc-arc", args.optimization, "-Wall", "-Wextra", "-Wno-unused-function",
               "-framework", "Foundation", "-framework", "AudioToolbox", str(generated_path),
               str(source_root / "ios/Classes/TiSynthengineContract.m"), "-o", str(args.output)]
    subprocess.run(command, check=True)
    args.output.with_suffix(".json").write_text(json.dumps({
        "source": str(source_path), "sourceSha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
        "contractSha256": hashlib.sha256((source_root / "ios/Classes/TiSynthengineContract.m").read_bytes()).hexdigest(),
        "generatedSourceSha256": hashlib.sha256(generated_path.read_bytes()).hexdigest(),
        "driverSha256": hashlib.sha256((ROOT / "tests/ios_render_host.m").read_bytes()).hexdigest(),
        "sharedSha256": {h.name: hashlib.sha256(h.read_bytes()).hexdigest() for h in sorted((source_root / "shared").glob("*.h"))},
        "command": command, "binarySha256": hashlib.sha256(args.output.read_bytes()).hexdigest(),
        "scope": "Actual Apple ObjC render body/helpers on macOS. No AVAudioEngine, session, Titanium bridge or device output.",
        "deterministicNoiseSeedClock": True}, indent=2) + "\n")


if __name__ == "__main__":
    main()
