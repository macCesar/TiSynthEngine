package ti.synthengine;
import java.util.*;
public class SynthSpatialContractRegression {
 static Map<String,Object> options(Object... values){Map<String,Object> m=new HashMap<>();for(int i=0;i<values.length;i+=2)m.put((String)values[i],values[i+1]);return m;}
 static void check(boolean value,String label){if(!value)throw new AssertionError(label);}
 public static void main(String[] args){
  check(SynthContract.validateTone(options("spatialX",-1.0,"spatialY",1.0),19845).accepted,"accept 2D coordinates");
  for(Object bad:new Object[]{1.01,-1.01,Double.NaN,Double.POSITIVE_INFINITY,true,"0"})
   check(!SynthContract.validateTone(options("spatialX",bad),19845).accepted,"reject invalid coordinate "+bad);
  check(SynthContract.validateChord(options("frequencies",new Object[]{440.0,660.0},"spatialY",-.5),19845).accepted,"spatial chord");
  check(SynthStudioContract.sequence(options("voice",options("spatialX",.5),"steps",new Object[]{options("notes",new Object[]{69},"overrides",options("spatialY",-.5))}),null,true,19845).packet[SynthStudioContract.HEADER+56]==1,"inherit spatial sequence");
  check(!SynthContract.validateTone(options("spatialY",.2,"pan",.4),19845).accepted,"reject conflicting pan");
  check(!SynthContract.validateChord(options("frequencies",new Object[]{440.0},"spatialX",.5,"pans",new Object[]{0.0}),19845).accepted,"reject conflicting chord pan");
  System.out.println("SynthSpatialContractRegression: passed");
 }
}
