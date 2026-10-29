#!/usr/bin/env python3
"""Inject a deterministic control change at the actual master's atomic read.

The production callback placement of that read is preserved. If it snapshots
only once per block this probe fails. No device audio or production hook exists.
"""
from pathlib import Path
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='synth-master-sample-') as tmp:
 work=Path(tmp);classes=work/'ios/Classes';classes.mkdir(parents=True)
 (work/'shared').symlink_to(ROOT/'shared',target_is_directory=True)
 for name in ['TiSynthengineContract.h','TiSynthengineContract.m']:
  (classes/name).symlink_to(ROOT/'ios/Classes'/name)
 source=(ROOT/'ios/Classes/TiSynthengineModule.m').read_text()
 hook='''
static int hostMasterReads;
static double hostMasterLoad(_Atomic(double) *volume) {
 if(++hostMasterReads==6)atomic_store_explicit(volume,0,memory_order_relaxed);
 return atomic_load_explicit(volume,memory_order_relaxed);
}
'''
 anchor='#define DEFAULT_SAMPLE_RATE   44100.0'
 assert anchor in source
 source=source.replace(anchor,anchor+'\n'+hook)
 read='atomic_load_explicit(&module->masterVolume, memory_order_relaxed)'
 assert source.count(read)==1
 source=source.replace(read,'hostMasterLoad(&module->masterVolume)')
 (classes/'TiSynthengineModule.m').write_text(source)
 driver=work/'driver.m';driver.write_text('''
int main(void){@autoreleasepool{
 RenderRig *r=rig(48000);float pcm[64];render(r,32,pcm,1);
 assert(hostMasterReads==32);
 assert(r->output.masterRemaining==480-27);
 assert(fabs(r->output.masterGain-(1-27./480))<1e-12);
 destroyRig(r);puts("Apple master change during callback starts on next processed sample PASS");
}return 0;}
''')
 exe=work/'master'
 subprocess.run(['python3',str(ROOT/'tools/build_ios_render_host.py'),'--source',str(work),'--driver',str(driver),'--output',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
