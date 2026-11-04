#!/usr/bin/env python3
"""Inject one callback transition into the actual production lookup host.

The shared DSP and production module methods remain verbatim. Only the final
identity read is wrapped so a real one-frame callback consumes the pending held
attack exactly between the old identities-first and queue-second scans.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HOOK = r'''
static void render(RenderRig *r,int frames,float *output,int layout);
static RenderRig *aliasRaceRig;
static int32_t aliasRaceTarget;
static BOOL aliasRaceArmed,aliasRaceFired;
static int alias_race_identity_mask(const SynthLiveIdentity *identity,int32_t identifier) {
 int result=synth_identity_mask(identity,identifier);
 if(aliasRaceArmed&&identifier==aliasRaceTarget&&identity==&aliasRaceRig->identities[aliasRaceRig->engineMaxVoices-1]) {
  aliasRaceArmed=NO;aliasRaceFired=YES;
  float frame[2];render(aliasRaceRig,1,frame,1);
 }
 return result;
}
#define synth_identity_mask alias_race_identity_mask
'''

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    with tempfile.TemporaryDirectory() as temporary:
        output=args.output or Path(temporary)/'sound-alias-race'
        spec=importlib.util.spec_from_file_location('alias_race_host',ROOT/'tools/build_ios_render_host.py')
        host=importlib.util.module_from_spec(spec)
        spec.loader.exec_module(host)
        original_run=host.subprocess.run
        def instrument(command,*positional,**keywords):
            if command[0]=='clang':
                generated=output.with_suffix('.m')
                source=generated.read_text()
                anchor='@implementation RenderRig\n'
                assert source.count(anchor)==1
                source=source.replace(anchor,HOOK+'\n'+anchor)
                generated.write_text(source)
            return original_run(command,*positional,**keywords)
        host.subprocess.run=instrument
        original_argv=sys.argv
        try:
            sys.argv=[str(ROOT/'tools/build_ios_render_host.py'),'--driver',str(ROOT/'tests/ios_sound_alias_race.m'),'--output',str(output)]
            host.main()
        finally:
            sys.argv=original_argv
            host.subprocess.run=original_run
        manifest=output.with_suffix('.json')
        metadata=json.loads(manifest.read_text())
        metadata['generatedSourceSha256']=hashlib.sha256(output.with_suffix('.m').read_bytes()).hexdigest()
        metadata['testInstrumentation']='Final identity read invokes actual one-frame callback; shared DSP and module source unchanged.'
        metadata['raceRunnerSha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        manifest.write_text(json.dumps(metadata,indent=2)+'\n')
        subprocess.run([str(output)],check=True)

if __name__=='__main__':
    main()
