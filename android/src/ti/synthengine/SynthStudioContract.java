package ti.synthengine;

import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;

/** Pure Java preflight. Nothing reaches the callback until the entire edit validates. */
final class SynthStudioContract {
    static final int STEP_WIDTH=204, HEADER=11;
    static final class Sequence {
        final Map<String,Object> options; final double[] packet;
        Sequence(Map<String,Object> options,double[] packet){this.options=options;this.packet=packet;}
        // The native publisher synchronously copies the complete packet. Only
        // detached canonical options are needed for subsequent partial edits.
        Sequence acceptedState(){return packet==null?this:new Sequence(options,null);}
    }
    private SynthStudioContract() {}
    static double number(Map<String,Object> m,String key,double fallback,double min,double max) {
        if(!m.containsKey(key))return fallback;
        Object raw=m.get(key);if(!(raw instanceof Number))throw new IllegalArgumentException(key);
        double v=((Number)raw).doubleValue();
        if(!Double.isFinite(v)||v<min||v>max)throw new IllegalArgumentException(key);return v;
    }
    static void keys(Map<String,Object> m,String... allowed) {
        for(String k:m.keySet())if(!Arrays.asList(allowed).contains(k))throw new IllegalArgumentException(k);
    }
    @SuppressWarnings("unchecked")
    static Map<String,Object> map(Object raw) {
        if(!(raw instanceof Map))throw new IllegalArgumentException("object");
        Map<String,Object> out=new HashMap<>();
        for(Map.Entry<?,?> e:((Map<?,?>)raw).entrySet()) {
            if(!(e.getKey() instanceof String))throw new IllegalArgumentException("key");
            Object v=e.getValue();
            if(v instanceof Map)v=map(v);
            else if(v instanceof Object[]) {
                Object[] a=((Object[])v).clone();
                for(int i=0;i<a.length;i++)if(a[i] instanceof Map)a[i]=map(a[i]);
                v=a;
            }
            out.put((String)e.getKey(),v);
        }
        return out;
    }
    static Map<String,Object> mergeVoice(Map<String,Object> base,Map<String,Object> edit) {
        Map<String,Object> merged=map(base);
        if(edit.get("filterType") instanceof String&&"none".equalsIgnoreCase(((String)edit.get("filterType")).trim()))for(String key:new String[]{"filterHz","filterQ"})merged.remove(key);
        if(edit.get("waveType") instanceof Number&&((Number)edit.get("waveType")).doubleValue()!=0)
            for(String key:new String[]{"fmRatio","fmDepth"})merged.remove(key);
        boolean fmModulation=false;
        Object mods=edit.containsKey("modulations")?edit.get("modulations"):base.get("modulations");
        if(mods instanceof Object[])for(Object item:(Object[])mods)
            if(item instanceof Map&&"fmDepth".equals(((Map<?,?>)item).get("target")))fmModulation=true;
        if(edit.get("fmDepth") instanceof Number&&((Number)edit.get("fmDepth")).doubleValue()==0&&!fmModulation)merged.remove("fmRatio");
        if(edit.containsKey("pan")) {merged.remove("spatialX");merged.remove("spatialY");}
        if(edit.containsKey("spatialX")||edit.containsKey("spatialY"))merged.remove("pan");
        merged.putAll(edit);return merged;
    }
    static Sequence sequence(Map<String,Object> changes,Sequence previous,boolean restart,double maxHz) {
        if(changes==null)throw new IllegalArgumentException("sequence");
        keys(changes,"steps","timeUnit","stepDuration","gate","swing","loop","mode","tuning","detune","voice","bus","effectSend","priority");
        // Accepted options are owned snapshots and are never mutated. Copy the
        // root map while sharing unchanged nested values; incoming edits below
        // are detached before merging, so replaced scores need no old-score copy.
        Map<String,Object> options=previous==null||restart?new HashMap<>():new HashMap<>(previous.options);
        Map<String,Object> edit=map(changes);
        if(edit.containsKey("voice")&&options.containsKey("voice")) {
            edit.put("voice",mergeVoice(map(options.get("voice")),map(edit.get("voice"))));
        }
        options.putAll(edit);
        double swing=number(options,"swing",0,-.75,.75);
        double tuning=number(options,"tuning",440,220,880),detune=number(options,"detune",0,-1200,1200);
        if(options.containsKey("loop")&&!(options.get("loop") instanceof Boolean))throw new IllegalArgumentException("loop");
        boolean loop=Boolean.TRUE.equals(options.get("loop"));
        String unit=options.containsKey("timeUnit")?String.valueOf(options.get("timeUnit")):"beats";
        if(!unit.equals("beats")&&!unit.equals("ms"))throw new IllegalArgumentException("timeUnit");
        if(previous!=null&&!restart&&!unit.equals(previous.options.getOrDefault("timeUnit","beats")))throw new IllegalArgumentException("fixed timeUnit");
        double minimumInterval=(unit.equals("beats")?20:4000)/(maxHz/.45);
        double interval=number(options,"stepDuration",unit.equals("beats")?.25:100,minimumInterval,unit.equals("beats")?300:60000);
        double gate=number(options,"gate",.8,.01,1);
        String mode=options.containsKey("mode")?String.valueOf(options.get("mode")):"normal";
        int modeIndex=Arrays.asList("normal","up","down","updown").indexOf(mode);
        if(modeIndex<0)throw new IllegalArgumentException("mode");
        Object raw=options.get("steps");if(!(raw instanceof Object[]))throw new IllegalArgumentException("steps");
        Object[] steps=(Object[])raw;if(steps.length<1||steps.length>512)throw new IllegalArgumentException("steps");
        Map<String,Object> root=options.containsKey("voice")?map(options.get("voice")):new HashMap<>();
        for(String k:new String[]{"bus","effectSend","priority"})if(options.containsKey(k))root.put(k,options.get(k));
        double[] packet=new double[HEADER+STEP_WIDTH*steps.length];
        double[] rootVariation=SynthContract.variationPacket(root);packet[9]=rootVariation[2];packet[10]=rootVariation[3];
        packet[0]=steps.length;packet[1]=120;packet[2]=swing;packet[3]=loop?1:0;packet[4]=modeIndex;packet[5]=tuning;packet[6]=detune;packet[7]=unit.equals("ms")?1:0;packet[8]=interval;
        for(int i=0;i<steps.length;i++) {
            Map<String,Object> step=map(steps[i]);keys(step,"notes","frequencies","rest","gate","duration","length","overrides","bus","effectSend","priority");
            if(step.containsKey("rest")&&!(step.get("rest") instanceof Boolean))throw new IllegalArgumentException("rest");
            if(step.containsKey("rest")&&!Boolean.TRUE.equals(step.get("rest")))throw new IllegalArgumentException("rest must be true");
            boolean rest=Boolean.TRUE.equals(step.get("rest"));
            int representations=(rest?1:0)+(step.containsKey("notes")?1:0)+(step.containsKey("frequencies")?1:0);
            if(representations!=1)throw new IllegalArgumentException("one pitch representation");
            boolean frequencies=step.containsKey("frequencies");
            String pitchKey=frequencies?"frequencies":"notes";
            Object[] notes;
            if(rest)notes=new Object[0];else {
                if(!(step.get(pitchKey) instanceof Object[]))throw new IllegalArgumentException("notes");
                notes=(Object[])step.get(pitchKey);if(notes.length<1||notes.length>32)throw new IllegalArgumentException("notes");
            }
            int offset=HEADER+i*STEP_WIDTH;packet[offset]=notes.length;packet[offset+1]=rest?1:0;
            packet[offset+2]=number(step,"gate",gate,.01,1);
            for(int n=0;n<notes.length;n++) {
                if(!(notes[n] instanceof Number))throw new IllegalArgumentException("midi");
                double pitch=((Number)notes[n]).doubleValue();
                if(!Double.isFinite(pitch))throw new IllegalArgumentException("pitch");
                double hz;
                if(frequencies)hz=pitch;else {
                    if(pitch!=Math.rint(pitch)||pitch<12||pitch>119)throw new IllegalArgumentException("midi");
                    hz=tuning*Math.pow(2,(pitch-69+detune/100)/12);
                }
                if(hz<SynthContract.MIN_FREQUENCY_HZ||hz>maxHz)throw new IllegalArgumentException("effective frequency");
                if(frequencies)packet[offset+136+n]=hz;else packet[offset+3+n]=pitch;
            }
            packet[offset+134]=number(step,"duration",0,minimumInterval,unit.equals("beats")?300:60000);
            packet[offset+135]=number(step,"length",0,1e-6,unit.equals("beats")?300:60000);
            Map<String,Object> voice=new HashMap<>(root);
            if(step.containsKey("overrides"))voice=mergeVoice(voice,map(step.get("overrides")));
            for(String k:new String[]{"bus","effectSend","priority"})if(step.containsKey(k))voice.put(k,step.get(k));
            for(String forbidden:new String[]{"voiceId","frequency","note","detune"})if(voice.containsKey(forbidden))throw new IllegalArgumentException(forbidden);
            Map<String,Object> probe=new HashMap<>(voice);probe.put("voiceId",1);probe.put("frequency",440);
            for(String k:new String[]{"frequencyEnd","noiseRateEnd","panEnd","pulseWidthEnd","filterHzEnd","fmDepthEnd"})probe.remove(k);
            if(voice.containsKey("fmDepthEnd")&&(!probe.containsKey("fmDepth")||(probe.get("fmDepth") instanceof Number&&((Number)probe.get("fmDepth")).doubleValue()==0)))probe.remove("fmRatio");
            if(!SynthContract.validateNoteOn(probe,maxHz).accepted)throw new IllegalArgumentException("voice");
            Map<String,Object> sweepProbe=new HashMap<>(voice);sweepProbe.remove("modulations");
            sweepProbe.put("frequency",440);sweepProbe.put("duration",SynthContract.MAX_DURATION_MS);
            if(!sweepProbe.containsKey("fmDepthEnd")&&(!sweepProbe.containsKey("fmDepth")||((Number)sweepProbe.get("fmDepth")).doubleValue()==0))sweepProbe.remove("fmRatio");
            if(!SynthContract.validateTone(sweepProbe,maxHz).accepted)throw new IllegalArgumentException("voice sweep");
            for(int n=0;n<notes.length;n++) {
                double hz=frequencies?((Number)notes[n]).doubleValue():tuning*Math.pow(2,(((Number)notes[n]).doubleValue()-69+detune/100)/12);
                if(!SynthContract.validateVariation(voice,hz,number(voice,"frequencyEnd",0,0,maxHz),maxHz).accepted)throw new IllegalArgumentException("variation");
            }
            double[] variation=SynthContract.variationPacket(voice);
            if(step.containsKey("overrides")) {
                Map<String,Object> overrides=map(step.get("overrides"));
                if(overrides.containsKey("variation")&&map(overrides.get("variation")).containsKey("seed"))variation[2]=3;
            }
            System.arraycopy(variation,0,packet,offset+184,20);
            packet[offset+168]=bus(voice.getOrDefault("bus","effects"));
            packet[offset+169]=number(voice,"effectSend",-1,0,1);
            packet[offset+170]=number(voice,"priority",0,0,3);
            packet[offset+171]=number(voice,"noiseRateEnd",0,0,maxHz);
            packet[offset+172]=number(voice,"panEnd",voice.containsKey("pan")?((Number)voice.get("pan")).doubleValue():0,-1,1);
            packet[offset+173]=number(voice,"pulseWidthEnd",0,0,.95);
            packet[offset+174]=number(voice,"filterHzEnd",0,0,maxHz);
            packet[offset+175]=number(voice,"fmDepthEnd",0,0,10);
            packet[offset+176]=voice.containsKey("fmDepthEnd")?1:0;
            String[] scalar={"volume","pan","frequencyEnd","lfoFreq","lfoDepth","noiseRate","lowPassHz","pulseWidth","filterHz","filterQ","fmRatio","fmDepth","spatialX","spatialY","sustain"};
            double[] defaults={SynthContract.DEFAULT_VOLUME,0,0,0,0,0,0,.5,1000,.7071,1,0,0,0,1};
            for(int j=0;j<scalar.length;j++)packet[offset+35+j]=voice.containsKey(scalar[j])?((Number)voice.get(scalar[j])).doubleValue():defaults[j];
            packet[offset+50]=number(voice,"waveType",0,0,5);packet[offset+51]=number(voice,"attack",SynthContract.DEFAULT_ATTACK_MS,0,2000);
            packet[offset+52]=number(voice,"decay",0,0,4000);packet[offset+53]=number(voice,"release",SynthContract.DEFAULT_RELEASE_MS,0,4000);
            packet[offset+54]=SynthContract.filterTypeIndex(voice.containsKey("filterType")?(String)voice.get("filterType"):"none");
            packet[offset+55]=number(voice,"bitDepth",0,0,16);packet[offset+56]=voice.containsKey("spatialX")||voice.containsKey("spatialY")?1:0;
            double[] mods=modulations(voice.containsKey("modulations")?voice.get("modulations"):new Object[0],(int)packet[offset+50],(int)packet[offset+54]);
            System.arraycopy(mods,0,packet,offset+122,12);
            if(voice.containsKey("waveTable")) {
                Object[] table=(Object[])voice.get("waveTable");packet[offset+57]=table.length;
                for(int j=0;j<table.length;j++)packet[offset+58+j]=((Number)table[j]).doubleValue();
            }
        }
        return new Sequence(options,packet);
    }
    static int bus(Object raw) {
        int index=Arrays.asList("music","effects","ui","ambience").indexOf(raw);
        if(index<0)throw new IllegalArgumentException("bus");return index;
    }
    static double sync(Object raw) {
        int i=Arrays.asList("off","quarter","eighth","sixteenth","quarterTriplet","eighthTriplet","sixteenthTriplet").indexOf(raw);
        if(i<0)throw new IllegalArgumentException("sync");return new double[]{0,1,.5,.25,2.0/3,1.0/3,1.0/6}[i];
    }
    static double[] modulations(Object raw,int wave,int filter) {
        if(!(raw instanceof Object[])||((Object[])raw).length>2)throw new IllegalArgumentException("modulations");
        double[] out=new double[12];int i=0;
        for(Object item:(Object[])raw) {
            Map<String,Object> m=map(item);keys(m,"wave","target","rate","depth","sync");
            int w=Arrays.asList("sine","triangle").indexOf(m.containsKey("wave")?m.get("wave"):"sine");
            int t=Arrays.asList("filterHz","pulseWidth","fmDepth").indexOf(m.get("target"));
            if(w<0||t<0||(t==0&&filter==0)||(t==1&&wave>=0&&wave!=1)||(t==2&&wave>=0&&wave!=0))throw new IllegalArgumentException("modulation source");
            out[i++]=1;out[i++]=w;out[i++]=t;out[i++]=number(m,"rate",1,0,20);out[i++]=number(m,"depth",0,0,1);
            out[i++]=sync(m.containsKey("sync")?m.get("sync"):"off");
        }
        return out;
    }
    static double[] effects(Map<String,Object> changes,double[] previous) {
        keys(changes,"inputGain","chorus","delay","reverb","saturation","applyTo");
        double[] out=previous==null?new double[]{1,0,.8,.4,.25,0,250,0,.3,.25,0,1.5,.5,.2,0,1,1,15}:previous.clone();
        if(changes.containsKey("applyTo")) {
            if(!(changes.get("applyTo") instanceof Object[]))throw new IllegalArgumentException("applyTo");
            int mask=0;for(Object item:(Object[])changes.get("applyTo"))mask|=1<<bus(item);out[17]=mask;
        }
        out[0]=number(changes,"inputGain",out[0],0,4);
        String[] names={"chorus","delay","reverb","saturation"};
        String[][] fields={{"enabled","rate","depth","mix"},{"enabled","timeMs","sync","feedback","mix"},{"enabled","decay","damping","mix"},{"enabled","drive","mix"}};
        int[] offsets={1,5,10,14};
        for(int section=0;section<4;section++)if(changes.containsKey(names[section])) {
            Map<String,Object> part=map(changes.get(names[section]));keys(part,fields[section]);
            for(int j=0;j<fields[section].length;j++) {
                String key=fields[section][j];int index=offsets[section]+j;
                if(!part.containsKey(key))continue;
                if(key.equals("enabled")) {if(!(part.get(key) instanceof Boolean))throw new IllegalArgumentException(key);out[index]=Boolean.TRUE.equals(part.get(key))?1:0;}
                else if(key.equals("sync"))out[index]=sync(part.get(key));
                else {
                    double min=0,max=1;
                    if(key.equals("rate")){min=.05;max=5;}if(key.equals("timeMs")){min=20;max=2000;}
                    if(key.equals("feedback"))max=.85;if(key.equals("decay")){min=.2;max=8;}if(key.equals("drive")){min=1;max=4;}
                    out[index]=number(part,key,out[index],min,max);
                }
            }
        }
        return out;
    }

}
