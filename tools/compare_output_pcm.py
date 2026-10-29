#!/usr/bin/env python3
"""Compare pipeline_capture_host/Apple --capture before/after float PCM.

Align only the old final-output delay, not envelopes or spatial/effect latency.
No-overload cases must preserve waveform; overload differences are measured.
"""
import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('evidence',type=Path)
a=p.parse_args();rows=[]
for platform in ['android','ios']:
 for rate in [16000,44100,48000,96000,192000]:
  # Original Android truncated the old lookahead, Apple rounded it.
  delay=int(rate*.01) if platform=='android' else round(rate*.01)
  for kind in range(8):
   paths=[a.evidence/f'pcm-{platform}-{v}'/f'{rate}-{kind}.f32' for v in ['baseline','candidate']]
   old,new=[array('f',path.read_bytes()) for path in paths]
   assert len(old)==len(new)==rate
   old=old[delay*2:];new=new[:-delay*2]
   maximum=max(abs(x-y) for x,y in zip(old,new))
   error=math.sqrt(sum((x-y)**2 for x,y in zip(old,new))/len(old))
   row={'platform':platform,'rate':rate,'kind':kind,'effects':bool(kind&1),'spatial':bool(kind&2),'overload':kind>=4,'alignedOldDelayFrames':delay,'maxDifference':maximum,'rmsDifference':error,'candidatePeak':max(abs(x) for x in new),'sha256':{path.parent.name:hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}}
   assert all(math.isfinite(x) and abs(x)<=.850001 for x in new)
   if kind<4:assert maximum<=1e-7,row
   rows.append(row)
report={'scope':'Matched-source production callbacks, same input per platform. No cross-platform identity requirement. No device output.','quietAbsoluteFloatTolerance':1e-7,'cases':rows}
(a.evidence/'pcm-comparison.json').write_text(json.dumps(report,indent=2)+'\n')
print(f'{len(rows)} cases: {sum(not x["overload"] for x in rows)} no-overload cases preserve PCM within 1e-7; overload deltas retained')
