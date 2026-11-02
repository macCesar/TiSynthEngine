package ti.synthengine;

import java.util.HashMap;
import java.util.Map;

/** Canonical state owns detached input, but must not retain bridge packets. */
public final class SynthSequenceMemoryRegression {
    static Map<String,Object> m(Object... pairs) {
        Map<String,Object> result=new HashMap<>();
        for(int i=0;i<pairs.length;i+=2)result.put((String)pairs[i],pairs[i+1]);
        return result;
    }
    static void check(boolean value,String message) {if(!value)throw new AssertionError(message);}
    public static void main(String[] args) {
        Object[] notes={60,64,67};
        Object[] steps={m("notes",notes)};
        SynthStudioContract.Sequence publication=SynthStudioContract.sequence(m("steps",steps),null,true,20000);
        SynthStudioContract.Sequence accepted=publication.acceptedState();
        check(publication.packet!=null,"publication must keep its packet until native acceptance");
        check(accepted.packet==null,"accepted state must release the bridge packet");
        check(accepted.options==publication.options,"acceptance must not copy detached canonical data");
        Object[] ownedSteps=(Object[])accepted.options.get("steps");
        notes[0]=12;steps[0]=m("rest",true);
        SynthStudioContract.Sequence scalarEdit=SynthStudioContract.sequence(m("swing",.2),accepted,false,20000);
        check(scalarEdit.packet[SynthStudioContract.HEADER+3]==60,"caller mutation leaked into canonical state");
        check(scalarEdit.options.get("steps")==ownedSteps,"unchanged immutable steps must be shared");
        Object[] replacementNotes={72};
        SynthStudioContract.Sequence replacement=SynthStudioContract.sequence(m("steps",new Object[]{m("notes",replacementNotes)}),accepted,false,20000);
        replacementNotes[0]=12;
        check(replacement.packet[SynthStudioContract.HEADER+3]==72,"replacement pitches were not snapshotted");
        check(SynthStudioContract.sequence(m("swing",.1),replacement.acceptedState(),false,20000).packet[SynthStudioContract.HEADER+3]==72,"retained replacement aliases caller pitches");
        check(((Object[])accepted.options.get("steps"))[0]==ownedSteps[0],"replacement changed prior state");
        try {SynthStudioContract.sequence(m("steps",new Object[]{m("notes",new Object[]{0})}),accepted,false,20000);throw new AssertionError("invalid edit accepted");}
        catch(IllegalArgumentException expected) {}
        check(SynthStudioContract.sequence(m("gate",.5),accepted,false,20000).packet[SynthStudioContract.HEADER+3]==60,"failed edit corrupted canonical state");
        Map<String,Object> modulation=m("target","filterHz","depth",.3,"rate",2);
        Map<String,Object> voice=m("volume",.2,"filterType","lowpass","filterHz",1200,"modulations",new Object[]{modulation});
        SynthStudioContract.Sequence expressive=SynthStudioContract.sequence(m("steps",new Object[]{m("notes",new Object[]{60})},"voice",voice),null,true,20000).acceptedState();
        voice.put("volume",.9);modulation.put("depth",.9);
        SynthStudioContract.Sequence voiceEdit=SynthStudioContract.sequence(m("voice",m("filterHz",1800)),expressive,false,20000);
        check(voiceEdit.packet[SynthStudioContract.HEADER+35]==.2&&voiceEdit.packet[SynthStudioContract.HEADER+122+4]==.3,"nested voice/modulation mutation leaked into retained state");
        check(((Number)((Map<?,?>)expressive.options.get("voice")).get("filterHz")).intValue()==1200,"partial voice edit mutated prior voice");
        Object[] dense=new Object[512];for(int i=0;i<dense.length;i++)dense[i]=m("notes",new Object[]{60});
        SynthStudioContract.Sequence large=SynthStudioContract.sequence(m("steps",dense),null,true,20000).acceptedState();
        for(int i=0;i<20;i++) {
            SynthStudioContract.Sequence next=SynthStudioContract.sequence(m("steps",dense,"swing",i*.01),large,false,20000);
            check(next.packet.length==SynthStudioContract.HEADER+512*SynthStudioContract.STEP_WIDTH,"dense packet truncated");
            large=next.acceptedState();check(large.packet==null,"dense publication packet retained");
        }
        System.out.println("Sequence canonical memory: detached inputs, immutable reuse, failed edits and packet release PASS");
    }
}
