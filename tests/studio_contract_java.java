package ti.synthengine;
import java.util.*;
class StudioContractRegression {
 static Map<String,Object> m(Object... pairs){Map<String,Object> m=new HashMap<>();for(int i=0;i<pairs.length;i+=2)m.put((String)pairs[i],pairs[i+1]);return m;}
 static void check(boolean b){if(!b)throw new AssertionError();}
 static void rejects(Runnable r){try{r.run();throw new AssertionError("accepted invalid config");}catch(IllegalArgumentException expected){}}
 public static void main(String[] args){
  Map<String,Object> source=m("steps",new Object[]{m("notes",new Object[]{60,60,67}),m("rest",true)},"swing",.137);
  SynthStudioContract.Sequence s=SynthStudioContract.sequence(source,null,true,20000);
  check(s.packet[0]==2&&s.packet[SynthStudioContract.HEADER]==3&&s.packet[SynthStudioContract.HEADER+3]==60&&s.packet[SynthStudioContract.HEADER+4]==60);
  source.put("swing",.2);check(((Number)s.options.get("swing")).doubleValue()==.137);
  SynthStudioContract.Sequence edited=SynthStudioContract.sequence(m("swing",.24),s,false,20000);check(edited.packet[2]==.24&&edited.packet[0]==2);
  rejects(()->SynthStudioContract.sequence(m("steps",new Object[]{m("notes",new Object[]{119})},"detune",1200),null,true,8000));
  rejects(()->SynthStudioContract.sequence(m("bpm",true),s,false,20000));
  rejects(()->SynthStudioContract.sequence(m("steps",new Object[]{m("notes",new Object[]{12.5})}),null,true,20000));
  rejects(()->SynthStudioContract.sequence(m("steps",new Object[]{m("rest",true,"notes",new Object[]{60})}),null,true,20000));
  rejects(()->SynthStudioContract.sequence(m("swing",.1),null,false,20000));
  double[] effects=SynthStudioContract.effects(m("chorus",m("enabled",true,"rate",2)),null);
  double[] merged=SynthStudioContract.effects(m("chorus",m("mix",.6)),effects);
  check(merged[1]==1&&merged[2]==2&&merged[4]==.6&&effects[4]==.25);
  rejects(()->SynthStudioContract.effects(m("delay",m("feedback",.86)),effects));
  rejects(()->SynthStudioContract.effects(m("chorus",m("enabled",1)),effects));
  rejects(()->SynthStudioContract.effects(m("delay",m("sync","bad")),effects));
  Object[] fm={m("target","fmDepth","depth",.4,"sync","sixteenthTriplet")};
  double[] mods=SynthStudioContract.modulations(fm,0,0);check(mods[2]==2&&mods[5]==1.0/6);
  rejects(()->SynthStudioContract.modulations(fm,1,0));
  Map<String,Object> note=m("voiceId",1,"fmDepth",0,"fmRatio",2,"modulations",fm);
  check(SynthContract.validateNoteOn(note,20000).accepted);
  Map<String,Object> fmEdit=SynthStudioContract.mergeVoice(m("fmRatio",3.5,"fmDepth",2,"modulations",fm),m("fmDepth",0));
  check(fmEdit.get("fmRatio")!=null&&((Number)fmEdit.get("fmRatio")).doubleValue()==3.5);
  note.put("fmRatio",100);check(!SynthContract.validateNoteOn(note,20000).accepted);
  note.put("fmRatio",2);note.remove("modulations");check(!SynthContract.validateNoteOn(note,20000).accepted);
  check(SynthContract.validateUpdateVoice(m("voiceId",1,"modulations",new Object[0]),20000).accepted);
  System.out.println("studio Java contract: merged sequence/effects, MIDI/tuning, strict types, LFO sources and FM zero-depth PASS");
 }
}
