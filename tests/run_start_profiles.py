#!/usr/bin/env python3
"""Execute Android's actual start profile selector with its actual validator.

Only KrollDict and the warning sink are substituted. SynthDsp supplies enum
constants; its historical DSP implementation is never used as a render oracle.
"""
from pathlib import Path
import re
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'android/src/ti/synthengine/TiSynthEngineModule.java').read_text()
a=source.index('    private int readMixingProfile(')
b=source.index('    private void warnOnce(',a)
selector=source[a:b]
text='''package ti.synthengine;
import java.util.*;
class KrollDict extends HashMap<String,Object> {}
class StartProfileRegression {
static boolean containsKey(KrollDict d,String k){return d.containsKey(k);}
static void warnOnce(String m,String k,String r,Object v,String a){}
'''+selector+'''
public static void main(String[] args){
 StartProfileRegression r=new StartProfileRegression();KrollDict d=new KrollDict();
 if(r.readMixingProfile(d)!=1)throw new AssertionError("default");
 String[] names={" RaW "," CONSERVATIVE\\n"," Balanced ","speakerSAFE"};
 for(int i=0;i<4;i++){
  d.put("mixingProfile",names[i]);
  if(!SynthContract.validateStart(d).accepted || r.readMixingProfile(d)!=i)throw new AssertionError(names[i]);
 }
 for(Object bad:new Object[]{"invalid",42}){
  d.put("mixingProfile",bad);
  if(SynthContract.validateStart(d).accepted || r.readMixingProfile(d)!=-1)throw new AssertionError("invalid accepted");
 }
 System.out.println("Android production start profiles/default/whitespace/case/rejections PASS");
}}
'''
with tempfile.TemporaryDirectory(prefix='synth-start-') as tmp:
 path=Path(tmp)/'StartProfileRegression.java';path.write_text(text)
 subprocess.run(['javac','-d',tmp,str(path),str(ROOT/'android/src/ti/synthengine/SynthContract.java'),str(ROOT/'android/src/ti/synthengine/SynthDsp.java'),str(ROOT/'android/src/ti/synthengine/SynthStudioContract.java')],check=True)
 subprocess.run(['java','-cp',tmp,'ti.synthengine.StartProfileRegression'],check=True)
