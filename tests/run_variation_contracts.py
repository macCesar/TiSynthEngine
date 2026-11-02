#!/usr/bin/env python3
"""Run the same per-attack variation cases against both production validators."""
from pathlib import Path
import json,subprocess,tempfile,sys
root=Path(__file__).resolve().parents[1]
def literal(v):
 if v is None:return 'null'
 if isinstance(v,bool):return 'Boolean.TRUE' if v else 'Boolean.FALSE'
 if isinstance(v,str):return json.dumps(v)
 if isinstance(v,(int,float)):return str(v)+'d'
 if isinstance(v,list):return 'new Object[]{'+','.join(map(literal,v))+'}'
 return 'm('+','.join(x for k,w in v.items() for x in (json.dumps(k),literal(w)))+')'
corpus=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else root/'tests/variation_contract_corpus.jsonl'
rows=[json.loads(s) for s in corpus.read_text().splitlines()]
with tempfile.TemporaryDirectory(prefix='synth-variation-') as work:
 p=Path(work)
 calls='\n'.join('check('+str(i+1)+','+literal(r['api'])+','+literal(r['options'])+','+str(r['accepted']).lower()+');' for i,r in enumerate(rows))
 calls+='\ncheck(0,"tone",m("variation",m("amount",Double.NaN)),false);'
 calls+='\ncheck(0,"tone",m("variation",m("seed",Double.POSITIVE_INFINITY)),false);'
 calls+='\ncheck(0,"tone",m("variation",m("ranges",m("volume",new Object[]{0,Double.POSITIVE_INFINITY}))),false);'
 parts=[calls.splitlines()[i:i+4] for i in range(0,len(calls.splitlines()),4)]
 main_calls=''.join('part'+str(i)+'();' for i in range(len(parts)))
 methods=''.join('static void part'+str(i)+'(){'+'\n'.join(part)+'}' for i,part in enumerate(parts))
 code='''package ti.synthengine;
import java.util.*;
class VariationContracts {
 static Map<String,Object> m(Object... a){Map<String,Object> m=new HashMap<>();for(int i=0;i<a.length;i+=2)m.put((String)a[i],a[i+1]);return m;}
 static void check(int line,String api,Map<String,Object> o,boolean expected){
 boolean got=false;
 try {switch(api){
 case "tone":got=SynthContract.validateTone(o,20000).accepted;break;
 case "chord":got=SynthContract.validateChord(o,20000).accepted;break;
 case "noteOn":got=SynthContract.validateNoteOn(o,20000).accepted;break;
 case "updateVoice":got=SynthContract.validateUpdateVoice(o,20000).accepted;break;
 case "sequence":SynthStudioContract.sequence(o,null,true,20000);got=true;break;
 }}catch(IllegalArgumentException e){}
 if(got!=expected)throw new AssertionError("line "+line+" "+api+" expected "+expected+" actual "+got);
 }
 public static void main(String[] args){
'''+main_calls+'\nSystem.out.println("Java variation contracts PASS '+str(len(rows)+3)+'");}'+methods+'}'
 (p/'VariationContracts.java').write_text(code)
 base=root/'android/src/ti/synthengine'
 subprocess.run(['javac','-d',work,str(p/'VariationContracts.java'),str(base/'SynthContract.java'),str(base/'SynthStudioContract.java')],check=True)
 java=subprocess.run(['java','-cp',work,'ti.synthengine.VariationContracts'])
 subprocess.run(['clang','-fobjc-arc','-Wall','-Wextra','-framework','Foundation',str(root/'tests/variation_contract_ios.m'),str(root/'ios/Classes/TiSynthengineContract.m'),'-o',str(p/'variation-ios')],check=True)
 apple=subprocess.run([str(p/'variation-ios'),str(corpus)],cwd=root)
 if java.returncode or apple.returncode:raise SystemExit(1)
