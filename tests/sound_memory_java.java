package ti.synthengine;
import org.appcelerator.kroll.KrollDict;
import java.lang.reflect.Field;
import java.util.Map;
import java.util.Set;

// Actual public module methods over the actual inert SynthThread: no audio/JNI.
class SoundMemoryRegression {
 static KrollDict d(Object... pairs) {KrollDict d=new KrollDict();for(int i=0;i<pairs.length;i+=2)d.put((String)pairs[i],pairs[i+1]);return d;}
 static void check(boolean value,String message) {if(!value)throw new AssertionError(message);}
 static Field field(String name) throws Exception {Field f=TiSynthEngineModule.class.getDeclaredField(name);f.setAccessible(true);return f;}
 static int count(TiSynthEngineModule m,String name) throws Exception {Object value=field(name).get(m);return value instanceof Map?((Map<?,?>)value).size():((Set<?>)value).size();}
 static SynthThread inert() throws Exception {
  Class<?> type=Class.forName("sun.misc.Unsafe");Field f=type.getDeclaredField("theUnsafe");f.setAccessible(true);
  return (SynthThread)type.getMethod("allocateInstance",Class.class).invoke(f.get(null),SynthThread.class);
 }
 public static void main(String[] args) throws Exception {
  TiSynthEngineModule modern=new TiSynthEngineModule();Field owner=field("synthThread");
  for(int batch=0;batch<5;batch++) {
   owner.set(modern,inert());
   for(int i=0;i<1000;i++) {
    int id=modern._allocateSoundNote();
    check(!modern._soundHeld(d("operation","on","options",d("voiceId",id,"frequency",440))),"inert bridge must reject");
    check(!modern._soundHeld(d("operation","off","options",d("voiceId",id))),"inert bridge must reject off");
   }
   modern.shutdown();
   System.out.println("modern rejected/shutdown batch="+batch+" maps="+count(modern,"legacyHeldIds")+" claims="+count(modern,"claimedHeldIds"));
  }
  check(count(modern,"legacyHeldIds")==0&&count(modern,"claimedHeldIds")==0,"modern IDs must use bounded bookkeeping");
  TiSynthEngineModule legacy=new TiSynthEngineModule();
  for(int batch=0;batch<5;batch++) {
   owner.set(legacy,inert());
   for(int i=0;i<1000;i++) {
    int id=1+batch*3000+i;
    check(!legacy.noteOn(d("voiceId",id,"frequency",440)),"inert bridge must reject on");
    check(!legacy.noteOff(d("voiceId",id+1000)),"inert bridge must reject off");
    check(!legacy.updateNote(d("voiceId",id+2000,"volume",.1)),"inert bridge must reject update");
   }
   System.out.println("legacy before shutdown batch="+batch+" maps="+count(legacy,"legacyHeldIds")+" claims="+count(legacy,"claimedHeldIds"));
   legacy.shutdown();
   System.out.println("legacy after shutdown batch="+batch+" maps="+count(legacy,"legacyHeldIds")+" claims="+count(legacy,"claimedHeldIds"));
  }
  check(count(legacy,"legacyHeldIds")==0&&count(legacy,"claimedHeldIds")==0,"rejected legacy commands and shutdown retain identifiers indefinitely");
  // A rejected high-ID request must not pin a collision alias. The inert
  // bridge cannot admit voices; admitted/pending collisions run in Apple host.
  TiSynthEngineModule collisions=new TiSynthEngineModule();owner.set(collisions,inert());
  for(int i=0;i<1000;i++) {
   int owned=collisions._allocateSoundNote();
   check(!collisions.noteOn(d("voiceId",owned,"frequency",440)),"inert high-ID publication must reject");
   check(count(collisions,"legacyHeldIds")<=1,"rejected aliases accumulate between allocations");
   collisions._allocateSoundNote();
   check(count(collisions,"legacyHeldIds")==0&&count(collisions,"claimedHeldIds")==0,"inactive collision aliases must retire");
  }
  int rejectedCollision=collisions._allocateSoundNote();
  check(!collisions.noteOn(d("voiceId",rejectedCollision,"frequency",440)),"collision publication rejects");
  check(count(collisions,"legacyHeldIds")==1,"test must retain one unpruned collision alias before shutdown");
  collisions.shutdown();
  check(count(collisions,"legacyHeldIds")==0&&count(collisions,"claimedHeldIds")==0,"shutdown must clear aliases");
  System.out.println("Sound memory Java: bounded held bookkeeping PASS");
 }
}
