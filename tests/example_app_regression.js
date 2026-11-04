// Exercise the actual example callbacks without a Titanium runtime. Native
// audio acceptance is checked separately against the platform contracts.
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const { test } = require('node:test')
const source = fs.readFileSync(path.join(__dirname, '../example/app.js'), 'utf8')
const recorded = []
const validationRequests = []
const soundApi = require('../assets/ti.synthengine')

function playground(metadata = {}) {
  const widgets = [], timers = new Map(), intervals = new Map(), calls = []
  let serial = 0, accepted = true
  function widget(options = {}) {
    const events = new Map()
    const value = Object.assign({}, options, {
      children: [], add(child) { this.children.push(child) },
      applyProperties(props) { Object.assign(this, props) },
      addEventListener(name, fn) { if (!events.has(name)) events.set(name, new Set()); events.get(name).add(fn) },
      removeEventListener(name, fn) { events.get(name)?.delete(fn) },
      fire(name, event = {}) { for (const fn of [...(events.get(name) || [])]) fn(event) },
      open() {}, events
    })
    widgets.push(value)
    return value
  }
  const synth = widget()
  synth.getDefaults = () => ({ ...metadata, version: '2.0.0', limits: { spatialX: {}, spatialY: {} },
    waveTypes: { SINE: 0, SQUARE: 1, SAWTOOTH: 2, TRIANGLE: 3, NOISE: 4, WAVETABLE: 5 } })
  for (const method of ['start', 'playTone', 'repeatTone', 'updateTone', 'stopTone', 'playChord', 'playSequence', 'setVolume', 'enableStats', 'disableStats', 'stopSequence']) {
    synth[method] = options => {
      const call = { method, options: options === undefined ? null : JSON.parse(JSON.stringify(options)) }
      calls.push(call)
      if (accepted) recorded.push(call)
      return ['playSequence', 'repeatTone'].includes(method) ? (accepted ? 1 : 0) : accepted
    }
  }
  synth.getSequenceState = () => ({playing:true})
  synth.shutdown = () => calls.push({ method: 'shutdown' })
  synth.stopAll = () => calls.push({ method: 'stopAll' })
  synth.resetStats = () => calls.push({ method: 'resetStats' })
  synth.getStats = () => { calls.push({ method: 'getStats' }); return {
    activeVoices: 0, maxVoices: 16, peakActiveVoices: 3, spatialVoices: 0, tailVoices: 0,
    pendingCommands: 0, voiceStealCount: 0, rejectedRequestCount: 0, rejectedPublicationCount: 7, priorityDropCount: 4,
    renderLoad: null, outputPeakDbFS: null, underrunCount: null
  } }
  synth._validateSoundOptions = request => { validationRequests.push(JSON.parse(JSON.stringify(request))); return null }
  synth._soundRuntime = () => ({ running: true, generation: 1 })
  Object.assign(synth, soundApi)
  const app = widget()
  vm.runInNewContext(source, {
    require: id => id === 'lib/sequenceScore' ? require('../example/lib/sequenceScore') : id === 'lib/sequenceOwner' ? require('../example/lib/sequenceOwner') : id === 'lib/soundPreset' ? require('../example/lib/soundPreset') : synth,
    Ti: { UI: new Proxy({}, { get: (_, key) => key.startsWith('create') ? widget : key }),
      Platform: { osname: 'iphone' }, App: app, API: { info() {}, warn() {} } },
    setTimeout(fn) { timers.set(++serial, fn); return serial }, clearTimeout(id) { timers.delete(id) },
    setInterval(fn) { intervals.set(++serial, fn); return serial }, clearInterval(id) { intervals.delete(id) }
  })
  const win = widgets.find(w => w.navBarHidden)
  const actions = () => widgets.filter(w => w.accessibilityLabel && w.events.has('click'))
  const button = prefix => { const b = actions().find(w => w.children[0].text.startsWith(prefix)); assert(b, 'missing demo: ' + prefix); return b }
  function click(prefix) { const b = button(prefix); assert(b.touchEnabled, prefix + ' is enabled'); b.fire('click') }
  function settle() { for (const [id, fn] of [...timers]) { timers.delete(id); fn() } }
  function start() { win.fire('postlayout'); settle() }
  return { widgets, calls, win, synth, intervals, actions, click, start, settle,
    reject() { accepted = false }, text: () => widgets.map(w => w.text || '').join('\n') }
}

test('every sound and volume button surfaces native rejection', () => {
  const inventory = playground()
  for (const action of inventory.actions()) {
    const p = playground(); p.start(); p.reject()
    const b = p.actions().find(button => button.children[0].text === action.children[0].text)
    const before = p.calls.length
    b.fire('click')
    if (p.calls.slice(before).some(c => ['playTone', 'repeatTone', 'updateTone', 'stopTone', 'playChord', 'playSequence', 'setVolume'].includes(c.method))) {
      assert.match(p.text(), /Request rejected/, b.children[0].text)
    }
  }
})

test('nine headphone directions omit stereo keys; stereo bypass omits coordinates', () => {
  const p = playground(); p.start()
  for (const [name, x, y] of [['TOP LEFT', -1, 1], ['TOP', 0, 1], ['TOP RIGHT', 1, 1],
    ['LEFT', -1, 0], ['CENTER', 0, 0], ['RIGHT', 1, 0],
    ['BOTTOM LEFT', -1, -1], ['BOTTOM', 0, -1], ['BOTTOM RIGHT', 1, -1]]) {
    p.click(name + '\n')
    const { options } = p.calls.at(-1)
    assert.equal(options.spatialX, x); assert.equal(options.spatialY, y)
    for (const key of ['pan', 'panEnd', 'pans', 'panSpread']) assert(!(key in options))
  }
  p.click('STEREO MODE'); p.click('TOP LEFT\n')
  const { options } = p.calls.at(-1)
  assert.equal(options.pan, -1)
  assert(!('spatialX' in options) && !('spatialY' in options))
  p.click('BINAURAL MODE'); p.click('SPATIAL CHORD'); p.click('SPATIAL PATTERN')
})

test('changing iOS session restarts the engine and restores master gain', () => {
  const p = playground(); p.start(); p.click('50%')
  const before = p.calls.length
  p.click('AMBIENT SESSION')
  const calls = p.calls.slice(before)
  assert(calls.findIndex(c => c.method === 'shutdown') < calls.findIndex(c => c.method === 'start'))
  assert.equal(calls.find(c => c.method === 'start').options.audioSession, 'ambient')
  assert.equal(calls.find(c => c.method === 'setVolume').options, 0.5)
  p.click('PLAYBACK SESSION')
  assert.equal(p.calls.filter(c => c.method === 'start').at(-1).options.audioSession, 'playback')
})

test('diagnostic polling is opt-in, preserves null and cleans up the owner', () => {
  const p = playground(); p.start()
  assert.equal(p.intervals.size, 0)
  p.click('READ STATS')
  assert(!p.calls.some(c => c.method === 'resetStats'))
  assert.match(p.text(), /n\/a/)
  assert.match(p.text(), /Publications rejected: 7 \| priority drops: 4/)
  assert.doesNotMatch(p.text(), /undefined|dropped steps/)
  p.click('TOGGLE DIAGNOSTICS'); p.click('TOGGLE DIAGNOSTICS'); p.click('TOGGLE DIAGNOSTICS')
  assert.equal(p.intervals.size, 1)
  p.click('RESET STATS')
  assert.equal(p.calls.filter(c => c.method === 'resetStats').length, 1)
  p.click('PATTERN END')
  p.synth.fire('sequenceend', {sequenceId:1, reason:'stopped'}); assert.match(p.text(), /stopped/)
  p.click('PATTERN END')
  p.synth.fire('sequenceend', {sequenceId:1, reason:'completed'}); assert.match(p.text(), /end: completed/)
  p.win.fire('close')
  assert.equal(p.intervals.size, 0)
  const afterClose = p.text()
  p.synth.fire('sequenceend', {sequenceId:1, reason:'completed'})
  assert.equal(p.text(), afterClose, 'retired application controls cannot update the closed screen')
  assert.equal(p.calls.filter(c => c.method === 'disableStats').at(-1).method, 'disableStats')
  assert.equal(p.calls.at(-1).method, 'shutdown')
})

test('closing before layout settles cancels delayed startup', () => {
  const p = playground(); p.win.fire('postlayout'); p.win.fire('close'); p.settle()
  assert(!p.calls.some(c => c.method === 'start'))
})

test('all example playback requests can be exported for native contract validation', () => {
  const p = playground(); p.start()
  for (const b of p.actions()) b.fire('click')
  p.win.fire('close')
  if (process.env.SYNTH_EXAMPLE_REQUESTS) fs.writeFileSync(process.env.SYNTH_EXAMPLE_REQUESTS, JSON.stringify(recorded))
  if (process.env.SYNTH_EXAMPLE_VALIDATION_REQUESTS) {
    const unique = new Set(validationRequests.map(request => JSON.stringify(request)))
    fs.writeFileSync(process.env.SYNTH_EXAMPLE_VALIDATION_REQUESTS, [...unique].join('\n') + '\n')
  }
})

test('score compilation preserves millisecond onsets, release onset and mutually exclusive pitches', () => {
  const compile = require('../example/lib/sequenceScore')
  const seq = compile({ stepDuration: 210, attack: 2, release: 80, waveType: 4, steps: [
    { frequency: 120, duration: 180, release: 150 }, { rest: true, duration: 100 },
    { note: 'A3', duration: 300, release: 120, waveType: 1 }
  ] })
  assert.equal(seq.timeUnit, 'ms'); assert.equal(seq.loop, false)
  assert.deepEqual(seq.steps.map(step => step.duration), [180, 100, 300])
  assert.deepEqual(seq.steps.filter(step => !step.rest).map(step => step.length), [30, 180])
  assert.equal(seq.steps[2].frequencies[0], 220); assert.equal(seq.steps[2].overrides.waveType, 1)
  assert.equal(seq.voice.steps, undefined); assert.equal(seq.voice.stepDuration, undefined)
  for (const step of seq.steps) assert.equal(['notes', 'frequencies', 'rest'].filter(key => key in step).length, 1)
})

test('repeated scores coalesce until their stopped native owner retires', () => {
  const p = playground(); p.start()
  let active = 0, serial = 0, stopRequests = 0
  const publications = []
  p.synth.playSequence = options => {
    if (active) return 0
    publications.push(options); active = ++serial; return active
  }
  p.synth.stopSequence = () => { stopRequests++; return true }
  p.click('SHAPING PATTERN'); p.click('SPATIAL PATTERN'); p.click('PATTERN END')
  assert.equal(publications.length, 1); assert.equal(stopRequests, 1)
  active = 0; p.synth.fire('sequenceend', {sequenceId:1, reason:'stopped'})
  assert.equal(publications.length, 2); assert.equal(publications[1].voice.waveType, 1)
  p.synth.fire('sequenceend', {sequenceId:1, reason:'completed'})
  assert.equal(publications.length, 2)
  p.win.fire('close')
})


test('native variation example requires both announcements and leaves old modules on their original recipe', () => {
 for(const metadata of [{},{capabilities:{variation:true}},{variationSchemaVersion:1},{capabilities:{variation:true},variationSchemaVersion:1}]) {
  const p=playground(metadata);p.start();p.click('ATTACK VARIATION')
  const o=p.calls.at(-1).options
  assert.equal(!!o.variation,metadata.capabilities?.variation===true&&metadata.variationSchemaVersion===1)
  assert.equal(o.frequency,620);p.win.fire('close')
 }
})


test('native tone repeat keeps one owner, edits it and stops on close', () => {
  const p = playground(); p.start()
  p.click('START REPEATING')
  const request = p.calls.at(-1)
  assert.equal(request.method, 'repeatTone')
  assert.equal(request.options.intervalMs, 200)
  assert.equal(request.options.duration, 105)
  p.click('START REPEATING')
  assert.equal(p.calls.filter(c => c.method === 'repeatTone').length, 1)
  p.click('EDIT REPEATING')
  assert.deepEqual(p.calls.at(-1), {method:'updateTone', options:{...request.options,toneId:1,intervalMs:150,volume:0.08}})
  p.click('STOP REPEATING')
  assert.deepEqual(p.calls.at(-1), {method:'stopTone', options:{toneId:1}})
  p.click('START REPEATING'); p.win.fire('close')
  assert.equal(p.calls.filter(c => c.method === 'stopTone').length, 2)
  assert.equal(p.calls.at(-1).method, 'shutdown')
})

test('interactive callbacks use Sound objects and scalar master volume', () => {
  assert.doesNotMatch(source, /Synth\.(?:playTone|playChord|repeatTone|updateTone|stopTone|playSequence|noteOn|noteOff|setMasterProcessing)\(/)
  assert.match(source, /Synth\.getContract\(/)
  const p = playground(); p.start(); p.click('50%')
  assert.equal(p.calls.at(-1).method, 'setVolume')
  assert.equal(p.calls.at(-1).options, 0.5)
})
