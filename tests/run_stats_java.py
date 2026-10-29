#!/usr/bin/env python3
"""Exercise the real public Java statistics API without an Android runtime.
Only Titanium annotations/event/log plumbing is stubbed; no native renderer is
started. Native queue/voice/meter behavior is covered by stats_engine_host.cpp.
"""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as folder:
 p=Path(folder)
 sources={
 'android/os/Looper.java':'package android.os; public class Looper { public static Looper getMainLooper(){return new Looper();} }',
 'android/os/Handler.java':'package android.os; public class Handler { public Handler(Looper l){} public boolean post(Runnable r){return true;} public boolean postDelayed(Runnable r,long t){return true;} public void removeCallbacks(Runnable r){} }',
 'android/app/Activity.java':'package android.app; public class Activity {}',
 'android/util/Log.java':'package android.util; public class Log { public static int w(String t,String m){return 0;} }',
 'org/appcelerator/kroll/KrollDict.java':'package org.appcelerator.kroll; public class KrollDict extends java.util.HashMap<String,Object> { public KrollDict(){} public KrollDict(java.util.HashMap<String,Object> m){super(m);} }',
 'org/appcelerator/kroll/KrollModule.java':'package org.appcelerator.kroll; public class KrollModule { public void fireEvent(String n,KrollDict d){} public void onDestroy(android.app.Activity a){} }',
 'org/appcelerator/kroll/annotations/Kroll.java':'package org.appcelerator.kroll.annotations; public class Kroll { public @interface module { String name(); String id(); } public @interface method {} }',
 'ti/synthengine/StatsApiRegression.java':'''package ti.synthengine;
import org.appcelerator.kroll.KrollDict;
public class StatsApiRegression {
 static void check(boolean value) { if(!value) throw new AssertionError(); }
 static double n(KrollDict d,String key) { return ((Number)d.get(key)).doubleValue(); }
 public static void main(String[] args) {
  TiSynthEngineModule m=new TiSynthEngineModule();
  check(n(m.getStats(),"activeVoices")==0);
  check(m.getStats().containsKey("estimatedOutputLatencyMs") && m.getStats().get("estimatedOutputLatencyMs")==null);
  check(m.getStats().containsKey("renderLoad") && m.getStats().get("renderLoad")==null);
  check(m.setStatsEnabled(Boolean.TRUE)); check(!m.setStatsEnabled("true"));
  check(!m.playTone(new KrollDict())); check(!m.playChord(new KrollDict()));
  check(m.playSequence(new KrollDict())==0); check(!m.setVolume(new KrollDict()));
  KrollDict s=m.getStats(), r=(KrollDict)s.get("rejectedRequestsByReason");
  check(n(s,"rejectedRequestCount")==5 && n(r,"engineStopped")==4 && n(r,"validation")==1 && n(r,"queueFull")==0);
  check(n(m.getStats(),"rejectedRequestCount")==5); // reads never reset
  m.resetStats(); check(n(m.getStats(),"rejectedRequestCount")==0);
  check(m.getStats().get("renderLoad")==null);
  check(!m.start(new KrollDict(){{put("maxVoices",100);}}));
  check(n(m.getStats(),"rejectedRequestCount")==1);
  m.shutdown(); check(n(m.getStats(),"rejectedRequestCount")==1);
  m.onDestroy(null); m.onDestroy(null); check(n(m.getStats(),"rejectedRequestCount")==1); // root-activity teardown is idempotent
  System.out.println("StatsApiRegression: passed");
 }
}'''}
 for name,text in sources.items():
  f=p/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_text(text)
 native=root/'android/src/ti/synthengine'
 subprocess.run(['javac','-d',folder,*map(str,p.rglob('*.java')),*map(str,[native/n for n in ['SynthContract.java','SynthStudioContract.java','SynthDsp.java','SynthThread.java','TiSynthEngineModule.java']])],check=True)
 subprocess.run(['java','-cp',folder,'ti.synthengine.StatsApiRegression'],check=True)
