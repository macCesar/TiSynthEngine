#!/usr/bin/env python3
"""Replay compiled app Sound requests through actual Java entry validators.

The Apple companion uses ios_sound_corpus.m with build_ios_render_host.py.
No audio is started and no native validation code is copied into a mock.
"""
from pathlib import Path
import json
import sys
root = Path(__file__).resolve().parents[1]
requests = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines() if line]

def literal(value):
    if value is None: return 'null'
    if isinstance(value, bool): return 'Boolean.TRUE' if value else 'Boolean.FALSE'
    if isinstance(value, str): return json.dumps(value, ensure_ascii=True)
    if isinstance(value, (int, float)): return str(value) + ('d' if abs(value) > 2147483647 else '')
    if isinstance(value, list): return 'new Object[]{' + ','.join(map(literal, value)) + '}'
    return 'd(' + ','.join(item for key, val in value.items() for item in (json.dumps(key), literal(val))) + ')'

chunks = []
for start in range(0, len(requests), 1):
    lines = []
    for index, request in enumerate(requests[start:start + 1], start + 1):
        expected = request.get('expected') != 'rejected'
        lines.append('check(m,' + str(index) + ',' + literal({'kind': request['kind'], 'options': request['options']}) + ',' + str(expected).lower() + ');')
    chunks.append('static void chunk' + str(start) + '(TiSynthEngineModule m){' + '\n'.join(lines) + '}')
java = '''package ti.synthengine;
import org.appcelerator.kroll.KrollDict;
class SoundCorpusRegression {
 static int failures=0;
 static KrollDict d(Object... pairs){KrollDict d=new KrollDict();for(int i=0;i<pairs.length;i+=2)d.put((String)pairs[i],pairs[i+1]);return d;}
 static void check(TiSynthEngineModule m,int line,KrollDict request,boolean expected){KrollDict error=m._validateSoundOptions(request);if((error==null)!=expected){System.err.println("line "+line+" "+request.get("kind")+": "+error);failures++;}}
''' + '\n'.join(chunks) + '''
 public static void main(String[] args){TiSynthEngineModule m=new TiSynthEngineModule();
''' + '\n'.join('chunk' + str(i) + '(m);' for i in range(len(chunks))) + '''
 System.out.println("Java compiled Sound requests: ''' + str(len(requests)) + ''' cases, "+failures+" failures");if(failures>0)throw new AssertionError();}
}
'''
source = (root / 'tests/run_stats_java.py').read_text()
source = source.replace(' for name,text in sources.items():', " sources['ti/synthengine/SoundCorpusRegression.java']=corpus_java\n for name,text in sources.items():")
source = source.replace("'ti.synthengine.StatsApiRegression'", "'ti.synthengine.SoundCorpusRegression'")
corpus_java = java
exec(compile(source, str(root / 'tests/run_stats_java.py'), 'exec'))
