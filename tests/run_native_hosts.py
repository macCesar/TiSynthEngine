#!/usr/bin/env python3
"""Compile unchanged Android renderer into host checks; no device output.

Requires a JDK and Oboe headers, from Gradle or --oboe-include. Linux ignores uncalled Oboe device symbols; no output device is opened.
"""
import argparse
from pathlib import Path
import platform
import os
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--oboe-include',type=Path)
p.add_argument('--source',type=Path,default=ROOT)
p.add_argument('--output',type=Path)
p.add_argument('--build-only',action='store_true')
p.add_argument('hosts',nargs='*',default=['output_engine','engine_render','held_engine','studio_engine','spatial_engine','stats_engine','sequence_ends','sequence_publication','retrigger_phase','bypass_rates','startup_processing'])
a=p.parse_args()
oboe=a.oboe_include or next(Path.home().joinpath('.gradle/caches').glob('**/oboe-1.11.0/prefab/modules/oboe/include'),None)
if not oboe:raise SystemExit('Pass --oboe-include (Oboe 1.11.0 prefab include directory)')
apple=platform.system()=='Darwin'
jdk=Path(subprocess.check_output(['/usr/libexec/java_home'],text=True).strip()) if apple else Path(os.environ['JAVA_HOME'])
with tempfile.TemporaryDirectory(prefix='synth-native-') as tmp:
 out=a.output or Path(tmp);out.mkdir(parents=True,exist_ok=True)
 for host in a.hosts:
  exe=out/host
  cmd=['clang++','-std=c++17','-O2','-Wall','-Wextra','-I'+str(oboe),'-I'+str(jdk/'include'),'-I'+str(jdk/'include'/('darwin' if apple else 'linux')),'-DHAS_EXPRESSIVE','-DENGINE_CPP="'+str(a.source.resolve()/'android/jni/SynthOboeEngine.cpp')+'"',str(ROOT/'tests'/(host+'_host.cpp')),'-o',str(exe)]
  cmd+=['-Wl,-undefined,dynamic_lookup'] if apple else ['-include','cstring','-no-pie','-Wl,--unresolved-symbols=ignore-all','-pthread']
  subprocess.run(cmd,check=True)
  if not a.build_only:
   print('RUN',host,flush=True);subprocess.run([str(exe)],check=True)
