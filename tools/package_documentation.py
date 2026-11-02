#!/usr/bin/env python3
"""Refresh packaged docs/examples while proving native binary bytes unchanged.
Requires existing real Android/iOS module build ZIPs and the build SDK's bundled
markdown package. --check-only validates temporary candidates without replacing
those ZIPs. Native compilation remains a separate required build step.
"""
from pathlib import Path
from posixpath import normpath,join,dirname
import argparse,hashlib,html,json,re,subprocess,zipfile,os,tempfile
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sdk-path',type=Path,required=True,help='Titanium SDK directory containing node_modules/markdown')
parser.add_argument('--check-only',action='store_true')
parser.add_argument('--output-proof',type=Path,help='Optional JSON output after actual archive replacement')
args=parser.parse_args()
CHECK_ONLY=args.check_only
ROOT=Path(__file__).resolve().parents[1]
SDK=args.sdk_path.expanduser().resolve()
NODE=r'''const fs=require('fs');const m=require(require.resolve('markdown',{paths:[process.argv[1]]})).markdown;const s=JSON.parse(fs.readFileSync(0,'utf8'));process.stdout.write(JSON.stringify(s.map(x=>m.toHTML(x,"Maruku"))));'''
def sha(b):return hashlib.sha256(b).hexdigest()
def fenced(source):
 def block(m):return '\n\n<pre><code'+(' class="language-'+html.escape(m[1])+'"' if m[1] else '')+'>'+html.escape(m[2])+'</code></pre>\n\n'
 return re.sub(r'^```([^\n]*)\n([\s\S]*?)^```\s*$',block,source,flags=re.M)
def slug(s):
 s=re.sub(r'<[^>]+>','',s.strip().lower());s=re.sub(r'[`*_~]','',s)
 return re.sub(r'\s+','-', ''.join(c for c in s if c.isalnum() or c.isspace() or c=='-'))
paths=sorted((ROOT/'documentation').glob('*.md'))+[ROOT/p for p in ['README.md','CHANGELOG.md','example/README.md','android/README.md','android/Resources/README.md','android/platform/README.md','ios/README.md','ios/Resources/README.md','ios/platform/README.md']]
sources=[p.read_text() for p in paths]
pages=json.loads(subprocess.check_output(['node','-e',NODE,str(SDK)],input=json.dumps([fenced(s) for s in sources]).encode()))
rendered={}
for p,source,page in zip(paths,sources,pages):
 heads=re.findall(r'^#{1,6}\s+(.+)$',re.sub(r'^```[^\n]*\n[\s\S]*?^```\s*$','',source,flags=re.M),flags=re.M);counts={};anchors=[]
 for head in heads:
  base=slug(head);n=counts.get(base,0);counts[base]=n+1;anchors.append(base+(('-'+str(n)) if n else ''))
 it=iter(anchors)
 page=re.sub(r'<h([1-6])>',lambda m:'<h'+m[1]+' id="'+next(it)+'">',page)
 assert next(it,None) is None, p
 def package_link(match):
  dest=html.unescape(match[1])
  if re.match(r'\w+:',dest):return match[0]
  file,sep,frag=dest.partition('#')
  target=normpath(join(p.relative_to(ROOT).parent.as_posix(),file))
  if target.startswith('docs/validation/'):
   assert (ROOT/target).is_file(),(p,dest)
   dest='https://github.com/macCesar/TiSynthEngine/blob/main/'+target+(sep+frag if sep else '')
  else:dest=re.sub(r'\.md(?=#|$)','.html',dest)
  return 'href="'+html.escape(dest,quote=True)+'"'
 page=re.sub(r'href="([^"]+)"',package_link,page)
 rendered[p.relative_to(ROOT).with_suffix('.html').as_posix()]=page.encode()
proof={}
for folder,plat in [('android','android'),('ios','iphone')]:
 version=re.search(r'^version:\s*(\S+)',(ROOT/folder/'manifest').read_text(),re.M).group(1)
 rel=f'{folder}/dist/ti.synthengine-{plat}-{version}.zip'
 path=ROOT/rel;prefix=f'modules/{plat}/ti.synthengine/{version}/'
 with zipfile.ZipFile(path) as z:
  assert z.testzip() is None
  data={n:z.read(n) for n in z.namelist() if not n.endswith('/')}
 native={n:sha(v) for n,v in data.items() if n.endswith(('.aar','.a','.so'))}
 # Old candidate archives may already contain raw reports. Documentation refresh
 # removes them instead of carrying them into every consuming application.
 data={n:b for n,b in data.items() if not (n.startswith(prefix+'documentation/') and n.endswith(('.json','.zip')))}
 for relname,page in rendered.items():data[prefix+relname]=page
 for p in (ROOT/'example').rglob('*'):
  if p.is_file():data[prefix+p.relative_to(ROOT).as_posix()]=p.read_bytes()
 for p in [ROOT/'README.md',ROOT/'LICENSE',ROOT/'index.d.ts']:
  if p.is_file():data[prefix+p.name]=p.read_bytes()
 tmp=Path(tempfile.gettempdir())/('tisynth-docs-check-'+plat+'-'+str(os.getpid())+'.zip') if CHECK_ONLY else path.with_suffix('.tmp.zip')
 with zipfile.ZipFile(tmp,'w',compression=zipfile.ZIP_DEFLATED) as z:
  for n,b in sorted(data.items()):z.writestr(n,b)
 with zipfile.ZipFile(tmp) as z:
  assert z.testzip() is None
  assert native=={n:sha(z.read(n)) for n in z.namelist() if n.endswith(('.aar','.a','.so'))}
  for relname,page in rendered.items():assert z.read(prefix+relname)==page
  assert z.read(prefix+'index.d.ts')==(ROOT/'index.d.ts').read_bytes()
  assert not any(n.startswith(prefix+'documentation/') and n.endswith(('.json','.zip')) for n in z.namelist())
  anchors={n:set(re.findall(r'id="([^"]+)"',b.decode())) for n,b in data.items() if n.endswith('.html')}
  checked=0
  for n,page in [(prefix+n,b.decode()) for n,b in rendered.items()]:
   for dest in re.findall(r'href="([^"]+)"',page):
    if re.match(r'\w+:',dest):continue
    file,sep,frag=html.unescape(dest).partition('#');target=normpath(join(dirname(n),file)) if file else n
    if target.endswith('.html'):
     assert target in data,(n,dest)
     if frag:assert frag in anchors[target],(n,dest)
     checked+=1
 if not CHECK_ONLY:os.replace(tmp,path)
 artifact=tmp if CHECK_ONLY else path
 proof[plat]={'checkOnly':CHECK_ONLY,'zip':rel,'sha256':sha(artifact.read_bytes()),'zipCRC':True,'binaryMembersUnchanged':True,'binarySha256':native,'htmlPages':len(rendered),'htmlLinksAndAnchorsChecked':checked,'rawValidationArtifactsExcluded':True,'exampleMatchesSource':True,'typeDeclarationsMatchSource':True}
if args.output_proof and not CHECK_ONLY:args.output_proof.write_text(json.dumps(proof,indent=2)+'\n')
print(json.dumps(proof,indent=2))
if CHECK_ONLY:
 for plat in proof:(Path(tempfile.gettempdir())/('tisynth-docs-check-'+plat+'-'+str(os.getpid())+'.zip')).unlink()
