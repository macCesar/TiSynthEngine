package ti.synthengine;
import org.appcelerator.kroll.KrollDict;
import java.lang.reflect.Method;
class SoundBoundaryRegression {
 static KrollDict d(Object... pairs) {KrollDict d=new KrollDict();for(int i=0;i<pairs.length;i+=2)d.put((String)pairs[i],pairs[i+1]);return d;}
 static void check(boolean condition) {if(!condition)throw new AssertionError();}
 public static void main(String[] args) throws Exception {
  TiSynthEngineModule m=new TiSynthEngineModule();
  check(m._validateSoundOptions(d("kind","tone","options",d("volume",.2)))==null);
  check(m._validateSoundOptions(d("kind","tone","options",d("volume",-1)))!=null);
  check(m._validateSoundOptions(d("kind","repeat","options",d("intervalMs",120)))==null);
  check(m._validateSoundOptions(d("kind","held","options",d("voiceId",1,"note","C4")))==null);
  check(m._validateSoundOptions(d("kind","pattern","options",d("steps",new Object[]{d("notes",new Object[]{60})})))==null);
  check(((Number)m.getStats().get("rejectedRequestCount")).doubleValue()==0);
  check(m.getDefaults().get("version").equals("2.0.0"));
  check(!m.setVolume(.5));check(!m.setVolume(d("volume",.5)));check(!m.setTempo(120));check(!m.setTempo(d("bpm",120)));
  double generation=((Number)m._soundRuntime().get("generation")).doubleValue();
  m.shutdown();check(((Number)m._soundRuntime().get("generation")).doubleValue()>generation);
  int owned=m._allocateSoundNote();check(owned>0);
  Method held=TiSynthEngineModule.class.getDeclaredMethod("heldIdentifier",int.class);held.setAccessible(true);
  int legacy=(Integer)held.invoke(m,owned);check(legacy!=owned);
  // No published voice exists in this cold fixture; its alias may be retired.
  check((Integer)held.invoke(m,owned)!=owned);
  int another=m._allocateSoundNote();check(another!=owned&&another!=legacy);
  java.lang.reflect.Field claims=TiSynthEngineModule.class.getDeclaredField("claimedHeldIds");claims.setAccessible(true);
  int before=((java.util.Set<?>)claims.get(m)).size();
  for(int i=0;i<1000;i++)check(m._allocateSoundNote()>0);
  check(((java.util.Set<?>)claims.get(m)).size()==before);
  check(m._soundNoteToMidi("C4")==60);check(m._soundNoteToMidi("Bb3")==58);
  check(m._soundNoteToMidi("not a note")==-1);
  Class<?> unsafeClass=Class.forName("sun.misc.Unsafe");
  java.lang.reflect.Field singleton=unsafeClass.getDeclaredField("theUnsafe");singleton.setAccessible(true);
  Object unsafe=singleton.get(null);
  SynthThread inert=(SynthThread)unsafeClass.getMethod("allocateInstance",Class.class).invoke(unsafe,SynthThread.class);
  java.lang.reflect.Field owner=TiSynthEngineModule.class.getDeclaredField("synthThread");owner.setAccessible(true);owner.set(m,inert);
  check(!m.setVolume(Boolean.TRUE));check(!m.setVolume("0.5"));
  check(m.setVolume(.5));check(m.setVolume(d("volume",.5)));
  owner.set(m,null);
  System.out.println("Sound boundary Java: pure validation, legacy signatures, generations and ID isolation PASS");
 }
}
