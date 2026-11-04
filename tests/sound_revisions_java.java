package ti.synthengine;
import org.appcelerator.kroll.KrollDict;
import java.lang.reflect.Field;
import java.util.Arrays;
import java.util.Map;
// Production module/contracts; only the JNI publication boundary is captured.
class SoundRevisionRegression {
 static KrollDict d(Object... pairs){KrollDict result=new KrollDict();for(int i=0;i<pairs.length;i+=2)result.put((String)pairs[i],pairs[i+1]);return result;}
 static void check(boolean value){if(!value)throw new AssertionError();}
 static Field field(String name)throws Exception{Field f=TiSynthEngineModule.class.getDeclaredField(name);f.setAccessible(true);return f;}
 @SuppressWarnings("unchecked") public static void main(String[] args)throws Exception{
  TiSynthEngineModule m=new TiSynthEngineModule();Class<?> type=Class.forName("sun.misc.Unsafe");Field singleton=type.getDeclaredField("theUnsafe");singleton.setAccessible(true);
  SynthThread bridge=(SynthThread)type.getMethod("allocateInstance",Class.class).invoke(singleton.get(null),SynthThread.class);field("synthThread").set(m,bridge);
  Map<Integer,KrollDict> tones=(Map<Integer,KrollDict>)field("acceptedTones").get(m);
  int tone=m.repeatTone(d("frequency",440,"waveType",4,"noiseRate",1200,"lowPassHz",3000,"duration",100,"intervalMs",100));check(tone>0);
  check(m._updateSoundOptions(d("kind","repeat","options",d("toneId",tone,"frequency",660,"waveType",4,"duration",100,"intervalMs",200))));
  check(!tones.get(tone).containsKey("noiseRate")&&!tones.get(tone).containsKey("lowPassHz"));
  check(SynthThread.lastExtras[48]==tone&&SynthThread.lastExtras[49]==200&&SynthThread.lastExtras[50]==0);
  KrollDict beforeTone=tones.get(tone);double[] beforeExtras=SynthThread.lastExtras;
  check(!m._updateSoundOptions(d("kind","repeat","options",d("toneId",tone,"intervalMs",200,"volume",-1))));check(tones.get(tone)==beforeTone&&SynthThread.lastExtras==beforeExtras);
  check(m.updateTone(d("toneId",tone,"noiseRate",900)));check(m.updateTone(d("toneId",tone,"volume",.2)));check(tones.get(tone).get("noiseRate").equals(900));
  Object[] steps={d("notes",new Object[]{60}),d("notes",new Object[]{62})};
  int pattern=m.playSequence(d("timeUnit","ms","stepDuration",100,"loop",true,"voice",d("waveType",0,"fmRatio",2,"fmDepth",1,"filterType","lowpass","filterHz",1200,"modulations",new Object[]{d("wave","sine","target","filterHz","rate",1,"depth",.1)}),"steps",steps));check(pattern>0);
  KrollDict full=d("timeUnit","ms","stepDuration",100,"loop",true,"voice",d("waveType",0,"volume",.03),"steps",steps);
  KrollDict publication=d("sequenceId",pattern);publication.putAll(full);
  check(m._updateSoundOptions(d("kind","pattern","options",publication)));check(!SynthThread.lastRestart);
  check(Arrays.equals(SynthThread.lastSequence,SynthStudioContract.sequence(full,null,true,19845).packet));
  Map<Integer,SynthStudioContract.Sequence> sequences=(Map<Integer,SynthStudioContract.Sequence>)field("acceptedSequences").get(m);
  Map<String,Object> voice=(Map<String,Object>)sequences.get(pattern).options.get("voice");check(!voice.containsKey("fmRatio")&&!voice.containsKey("filterHz")&&!voice.containsKey("modulations"));
  SynthStudioContract.Sequence before=sequences.get(pattern);double[] packet=SynthThread.lastSequence;
  KrollDict wrong=new KrollDict(publication);wrong.remove("timeUnit");check(!m._updateSoundOptions(d("kind","pattern","options",wrong)));check(sequences.get(pattern)==before&&SynthThread.lastSequence==packet);
  wrong=new KrollDict(publication);wrong.put("steps",new Object[]{d("notes",new Object[]{0})});check(!m._updateSoundOptions(d("kind","pattern","options",wrong)));check(sequences.get(pattern)==before&&SynthThread.lastSequence==packet);
  check(m.updateSequence(d("sequenceId",pattern,"voice",d("filterType","lowpass","filterHz",1500))));check(m.updateSequence(d("sequenceId",pattern,"voice",d("volume",.04))));
  check(((Map<?,?>)sequences.get(pattern).options.get("voice")).get("filterHz").equals(1500));
  field("synthThread").set(m,null);
  System.out.println("Sound revisions Java: full packet omission, atomic invalid edits, fixed units, restartfalse, legacy merges PASS");
 }
}
