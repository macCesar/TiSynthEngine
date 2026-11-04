const test = require('node:test')
const assert = require('node:assert/strict')
const soundApi = require('../assets/ti.synthengine')
const create = require('../example/lib/sequenceOwner')
function fixture() {
  let current = 0, serial = 0, retired = false
  const listeners = new Set(), publications = [], stops = [], updates = []
  const synth = {
    addEventListener: (name, fn) => { if (name === 'sequenceend') listeners.add(fn) }, removeEventListener: (name, fn) => { if (name === 'sequenceend') listeners.delete(fn) },
    playSequence(payload) { if (current) return 0; publications.push(payload); current = ++serial; return current },
    stopSequence({ sequenceId }) { stops.push(sequenceId); return !retired && current === sequenceId },
    updateSequence: payload => { updates.push(payload); return true },
    getSequenceState: () => retired ? null : { playing: true },
  }
  synth._validateSoundOptions = () => null
  synth._soundRuntime = () => ({ running: true, generation: 1 })
  Object.assign(synth, soundApi)
  return { owner: create(synth), synth, publications, stops, updates, listeners,
    retire() { retired = true },
    drain(reason = 'stopped') { const sequenceId = current; current = 0; retired = false; for (const fn of [...listeners]) fn({ sequenceId, reason }) },
  }
}
test('latest complete replacement waits for native retirement and merges pending voice edits', () => {
  const f = fixture()
  assert.equal(f.owner.submit({voice:{waveType:1},steps:[{notes:[60]}]}),true)
  f.owner.submit({voice:{waveType:2},steps:[{notes:[62]}]})
  f.owner.submit({voice:{waveType:3,filterType:'lowpass',filterHz:900},steps:[{notes:[64]}]})
  f.owner.update({voice:{volume:.2}})
  assert.equal(f.publications.length,1); assert.deepEqual(f.stops,[1])
  f.drain()
  assert.equal(typeof f.owner.id().stop, 'function'); assert.equal(f.publications.length,2)
  const acceptedControl = f.owner.id()
  assert.deepEqual(f.publications[1].voice,{waveType:3,filterType:'lowpass',filterHz:900,volume:.2})
  assert.deepEqual(f.publications[1].steps,[{notes:[64]}])
  for (const fn of f.listeners) fn({sequenceId:1,reason:'completed'})
  assert.equal(f.owner.id(),acceptedControl)
})
test('stop and reset cancel pending whole publications without restarting a retired owner', () => {
  const f=fixture();f.owner.submit({steps:[{notes:[60]}]});f.owner.submit({steps:[{notes:[62]}]})
  f.owner.stop();f.drain();assert.equal(f.publications.length,1)
  f.owner.submit({steps:[{notes:[64]}]});f.owner.submit({steps:[{notes:[65]}]})
  const late=[...f.listeners][0];f.owner.reset();late({sequenceId:2,reason:'stopped'})
  assert.equal(f.publications.length,2);assert.equal(f.owner.id(),null)
})
test('an already retired native ID still waits for its queued completion to release capacity', () => {
  const f=fixture();f.owner.submit({steps:[{notes:[60]}]});f.retire()
  assert.equal(f.owner.submit({steps:[{notes:[67]}]}),true)
  assert.equal(f.publications.length,1)
  f.drain('completed');assert.equal(f.publications.length,2)
})
test('a rejected complete publication reports failure instead of pretending it has an ID', () => {
  let reported=0
  const synth = { _validateSoundOptions: () => null, _soundRuntime: () => ({ running: true, generation: 1 }), playSequence: () => 0 }
  Object.assign(synth, soundApi)
  const owner=create(synth,{rejected(){reported++}})
  assert.equal(owner.submit({steps:[{notes:[60]}]}),false);assert.equal(owner.id(),null);assert.equal(reported,1)
})

test('a complete pending score replaces obsolete source and filter fields', () => {
  const f=fixture();f.owner.submit({steps:[{notes:[60]}]})
  f.owner.submit({voice:{waveType:0,filterType:'lowpass',filterHz:900,fmRatio:2,fmDepth:2},steps:[{notes:[62]}]})
  const next={timeUnit:'beats',voice:{waveType:3,filterType:'none',volume:.2},steps:[{notes:[64]}]}
  f.owner.update(next);f.drain()
  assert.deepEqual(f.publications[1],next)
  assert.equal('filterHz' in f.publications[1].voice,false)
  assert.equal('fmRatio' in f.publications[1].voice,false)
  if(process.env.SYNTH_DEFERRED_SCORE) require('node:fs').writeFileSync(process.env.SYNTH_DEFERRED_SCORE,JSON.stringify(f.publications[1]))
})


test('active updates keep the owned native route and all existing pattern parameters', () => {
  const f = fixture()
  f.owner.submit({ timeUnit: 'ms', stepDuration: 160, loop: true, voice: { waveType: 1, volume: .4 },
    steps: [{ notes: [60], duration: 180, length: 120, overrides: { release: 60 } }] })
  const control = f.owner.id()
  assert.equal(f.owner.update({ voice: { volume: .2 }, swing: .1 }), true)
  assert.equal(f.owner.id(), control)
  assert.deepEqual(f.updates, [{ sequenceId: 1, timeUnit: 'ms', stepDuration: 160, loop: true, swing: .1,
    voice: { waveType: 1, volume: .2 }, steps: [{ notes: [60], duration: 180, length: 120, overrides: { release: 60 } }] }])
})
