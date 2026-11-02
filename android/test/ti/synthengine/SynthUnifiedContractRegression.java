package ti.synthengine;
import java.util.*;
public class SynthUnifiedContractRegression {
 static Map<String,Object> m(Object... a){Map<String,Object> m=new HashMap<>();for(int i=0;i<a.length;i+=2)m.put((String)a[i],a[i+1]);return m;}
 static void check(boolean v){if(!v)throw new AssertionError();}
 static void rejects(Runnable r){try{r.run();throw new AssertionError("invalid accepted");}catch(IllegalArgumentException expected){}}
 public static void main(String[] args){
  check(SynthContract.validateStart(m("maxSequences",4)).accepted);
  check(!SynthContract.validateStart(m("maxSequences",0)).accepted);
  SynthStudioContract.Sequence s=SynthStudioContract.sequence(m("steps",new Object[]{m("frequencies",new Object[]{440,440},"duration",150,"length",250)},"timeUnit","ms","bus","music","priority",3),null,true,20000);
  check(s.packet[3]==0&&s.packet[7]==1&&s.packet[8]==100&&s.packet[SynthStudioContract.HEADER]==2&&s.packet[SynthStudioContract.HEADER+134]==150&&s.packet[SynthStudioContract.HEADER+135]==250&&s.packet[SynthStudioContract.HEADER+136]==440&&s.packet[SynthStudioContract.HEADER+168]==0&&s.packet[SynthStudioContract.HEADER+170]==3);
  check(SynthStudioContract.sequence(m("steps",new Object[]{m("rest",true)}),null,true,20000).packet[8]==.25);
  rejects(()->SynthStudioContract.sequence(m("bpm",120),s,false,20000));
  rejects(()->SynthStudioContract.sequence(m("timeUnit","beats"),s,false,20000));
  rejects(()->SynthStudioContract.sequence(m("steps",new Object[]{m("notes",new Object[]{60},"frequencies",new Object[]{440})}),null,true,20000));
  check(SynthContract.validateNoteOn(m("voiceId",1,"bus","ambience","effectSend",.5,"priority",3),20000).accepted);
  check(!SynthContract.validateNoteOn(m("voiceId",1,"priority",1.5),20000).accepted);
  check(SynthContract.validateUpdateVoice(m("voiceId",1,"noiseRate",0,"lowPassHz",0,"spatialX",.5),20000).accepted);
  check(SynthStudioContract.effects(m("applyTo",new Object[]{"music","ui"}),null)[17]==5);
  rejects(()->SynthStudioContract.effects(m("applyTo",new Object[]{"invalid"}),null));
  for(Map<String,Object> bad:Arrays.asList(m("priority",1.5),m("frequencyEnd","bad"),m("frequencyEnd",Double.NaN),m("pulseWidthEnd",.01),m("panEnd",.5,"spatialX",.2),m("filterHzEnd",500),m("waveType",1,"fmDepthEnd",2))) {
   rejects(()->SynthStudioContract.sequence(m("steps",new Object[]{m("notes",new Object[]{60})},"voice",bad),null,true,20000));
  }
  check(SynthStudioContract.sequence(m("steps",new Object[]{m("notes",new Object[]{60})},"voice",m("fmDepth",0,"fmRatio",2,"fmDepthEnd",2)),null,true,20000).packet[SynthStudioContract.HEADER+176]==1);
  rejects(()->SynthStudioContract.sequence(m("stepDuration",.000001,"steps",new Object[]{m("notes",new Object[]{60})}),null,true,20000));
  rejects(()->SynthStudioContract.sequence(m("timeUnit","ms","steps",new Object[]{m("notes",new Object[]{60},"duration",.000001)}),null,true,20000));
  System.out.println("Unified Java contract PASS");
 }
}
