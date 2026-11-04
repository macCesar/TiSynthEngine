'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const api=require('../assets/ti.synthengine');
const immediate=()=>new Promise(resolve=>setImmediate(resolve));
function rig(){
 let generation=1,running=true,serial=0,publications=0,allocations=0;
 const listeners=new Map();
 const engine=Object.assign({
  _validateSoundOptions:()=>null,
  _soundRuntime:()=>({generation,running}),
  _allocateSoundNote:()=>{allocations++;return ++serial;},
  _soundHeld:()=>{publications++;return true;},
  playTone:()=>{publications++;return true;},
  playSequence:()=>{publications++;return ++serial;},
  stopSequence:()=>true,
  getSequenceState:()=>({playing:true}),
  addEventListener(name,callback){if(!listeners.has(name))listeners.set(name,new Set());listeners.get(name).add(callback);},
  removeEventListener(name,callback){listeners.get(name)?.delete(callback);}
 },api);
 function emit(name,event){for(const callback of listeners.get(name)||[])callback(event);}
 return {engine,emit,last:()=>serial,shutdown(){generation++;running=false;emit('_soundinvalidate',{generation});},restart(){running=true;},
  counts:()=>({publications,allocations,listeners:Array.from(listeners.values()).reduce((sum,set)=>sum+set.size,0)})};
}
function unusedSounds(r,count){const refs=[];for(let i=0;i<count;i++)refs.push(new WeakRef(r.engine.createSound({sound:{volume:.1},playback:{type:'tone'}})));return refs;}
function patterns(r,count,complete){
 const refs=[];
 for(let i=0;i<count;i++){
  const sound=r.engine.createSound({sound:{volume:.1},playback:{type:'pattern',steps:[{notes:[60]}]}});
  const control=sound.play(),marker={hits:0};
  control.addEventListener('end',()=>marker.hits++);
  refs.push(new WeakRef(sound),new WeakRef(control),new WeakRef(marker));
  if(complete)r.emit('sequenceend',{sequenceId:r.last(),reason:'completed'});
 }
 return refs;
}
async function collected(refs){
 for(let round=0;round<20;round++){
  await immediate();global.gc();await immediate();
  if(refs.every(ref=>ref.deref()===undefined))return true;
 }
 return false;
}
test('unreferenced Sound definitions are collectible without voice or playback publication',{skip:!global.gc&&'Run node --expose-gc --test tests/sound_memory.test.js'},async()=>{
 const r=rig(),refs=unusedSounds(r,2000);
 assert.deepEqual(r.counts(),{publications:0,allocations:0,listeners:0});
 assert.equal(await collected(refs),true,'unused definitions remain strongly retained');
});
test('completed and shutdown patterns release controls and listener captures with constant engine subscriptions',{skip:!global.gc&&'Run with --expose-gc'},async()=>{
 const r=rig();
 for(let batch=0;batch<4;batch++){
  const ended=patterns(r,500,true);
  assert.equal(await collected(ended),true,'naturally ended patterns retain controls/listener captures');
  const stopped=patterns(r,500,false);r.shutdown();
  assert.equal(await collected(stopped),true,'shutdown patterns retain controls/listener captures');
  assert.equal(r.counts().listeners,2,'native registry subscriptions grow with pattern count');r.restart();
 }
});
test('the pattern registry does not retain an otherwise unreachable engine',{skip:!global.gc&&'Run with --expose-gc'},async()=>{
 function abandoned(){const r=rig();patterns(r,100,true);return new WeakRef(r.engine);}
 assert.equal(await collected([abandoned()]),true,'WeakMap registry retains its engine key');
});

test('cached patterns preserve caller isolation and independent active revisions',()=>{
 const r=rig(),snapshots=[];
 r.engine.playSequence=options=>{snapshots.push(structuredClone(options));return snapshots.length;};
 r.engine.updateSequence=options=>{snapshots.push(structuredClone(options));return true;};
 const source={sound:{volume:.1,modulations:[{wave:'sine',target:'filterHz',rate:1,depth:.2}],filterType:'lowpass',filterHz:1000},playback:{type:'pattern',steps:[{notes:[60],sound:{volume:.2}}]}};
 const sound=r.engine.createSound(source);source.playback.steps[0].notes[0]=90;source.sound.modulations[0].depth=.9;
 const old=sound.play();
 const detached=sound.getPreset();detached.playback.steps[0].sound.volume=1;
 sound.set({playback:{steps:[{notes:[62],sound:{volume:.3}}]},sound:{modulations:[]}});
 sound.play();old.update({volume:.15});
 assert.deepEqual(snapshots.map(value=>value.steps[0].notes),[[60],[62],[60]]);
 assert.deepEqual(snapshots.map(value=>value.steps[0].overrides.volume),[.2,.3,.2]);
 assert.deepEqual(snapshots.map(value=>value.voice.modulations.length),[1,0,1]);
 assert.equal(snapshots[0].voice.modulations[0].depth,.2);r.shutdown();
});
