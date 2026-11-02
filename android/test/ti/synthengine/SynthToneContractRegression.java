package ti.synthengine;
import java.util.*;
class SynthToneContractRegression {
 static Map<String,Object> m(Object... a){Map<String,Object> r=new HashMap<>();for(int i=0;i<a.length;i+=2)r.put((String)a[i],a[i+1]);return r;}
 static void check(boolean v){if(!v)throw new AssertionError();}
 static void bad(Map<String,Object> old,Map<String,Object> changes){try{SynthContract.mergeTone(old,changes,20000);throw new AssertionError();}catch(IllegalArgumentException expected){}}
 @SuppressWarnings("unchecked")
 public static void main(String[] args){
  bad(null,m());bad(null,m("volume",.2));
  check(!SynthContract.validateTone(m("intervalMs",120),20000).accepted);
  check(SynthContract.validateTone(m("frequency",440),20000).accepted);
  Map<String,Object> old=m("note","A4","intervalMs",120,"duration",100,"attack",5,"release",20,"variation",m("amount",1,"seed",9,"ranges",m("volume",new Object[]{.1,.3})));
  Map<String,Object> updated=SynthContract.mergeTone(old,m("frequency",220,"volume",.2),20000);
  check(!updated.containsKey("note")&&updated.get("intervalMs").equals(120));
  updated=SynthContract.mergeTone(updated,m("note","C4","variation",m("amount",0)),20000);
  check(!updated.containsKey("frequency")&&((Map<?,?>)updated.get("variation")).size()==1);
  bad(old,m("intervalMs",0));bad(old,m("intervalMs",1.5));bad(old,m("intervalMs",1.0000000001));bad(old,m("intervalMs",60001));bad(old,m("intervalMs",true));
  bad(old,m("note","C4","frequency",220));bad(old,m("unknown",1));bad(old,m("duration",2));
  Map<String,Object> a=SynthContract.mergeTone(old,m("intervalMs",1),20000),b=SynthContract.mergeTone(old,m("intervalMs",60000),20000);
  check(a.get("intervalMs").equals(1)&&b.get("intervalMs").equals(60000));
  // Accepted nested dictionaries and arrays are snapshots, not mutable JS state.
  ((Map<String,Object>)old.get("variation")).put("amount",.4);
  check(((Map<?,?>)a.get("variation")).get("amount").equals(1));
  System.out.println("Tone contract: partial merges, full validation and snapshots passed");
 }
}
