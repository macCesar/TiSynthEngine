#!/usr/bin/env python3
"""Capture the actual module's full-revision packets at its JNI boundary.

Production module and contract sources compile unchanged. The temporary copy of
SynthThread accepts/captures enqueueNote/publishSequence and reports a live slot;
no renderer or audio stream is substituted as a synthesis oracle. Actual Apple
callback tests separately verify deadlines, clocks and generated sample paths.
"""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
bridge=(root/'android/src/ti/synthengine/SynthThread.java').read_text()
bridge=bridge.replace('private long nativeHandle;','private long nativeHandle; public static double[] lastSequence,lastExtras; public static boolean lastRestart;')
bridge,count=re.subn(r'return handle == 0 \|\| nativeEnqueueNote\(.*?extras\);','lastExtras=extras.clone(); return false;',bridge,count=1,flags=re.S)
assert count==1
old='return nativeHandle!=0 && nativePublishSequence(nativeHandle,id,packet,restart);';assert bridge.count(old)==1
bridge=bridge.replace(old,'lastSequence=packet.clone(); lastRestart=restart; return true;')
old='return nativeHandle==0?null:nativeSequenceState(nativeHandle,id);';assert bridge.count(old)==1
bridge=bridge.replace(old,'return new double[8];')
source=(root/'tests/run_stats_java.py').read_text()
source=source.replace(' for name,text in sources.items():'," sources['ti/synthengine/SoundRevisionRegression.java']=(root/'tests/sound_revisions_java.java').read_text()\n sources['ti/synthengine/SynthThread.java']=bridge\n for name,text in sources.items():")
source=source.replace("'SynthThread.java',",'')
source=source.replace("'ti.synthengine.StatsApiRegression'","'ti.synthengine.SoundRevisionRegression'")
exec(compile(source,str(root/'tests/run_stats_java.py'),'exec'))
