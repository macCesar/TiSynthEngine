'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

function rig() {
  const calls = [], validations = [], bridge = [], listeners = new Map();
  let generation = 1, running = true, next = 1, reject = false;
  function nativeError(kind, options) {
    if (options.volume < 0 || options.volume > 2) return { key: 'volume', reason: 'out_of_range' };
    if (options.fmRatio !== undefined && options.fmDepth === undefined) return { key: 'fmDepth', reason: 'required_with_fm_ratio' };
    if (kind === 'chord' && 'frequencyEnd' in options) return { key: 'frequencyEnd', reason: 'unsupported' };
    if (kind === 'held' && options.fmRatio !== undefined && options.fmDepth === 0) return { key: 'fmRatio', reason: 'fm_depth_required' };
    return null;
  }
  const native = {
    _soundRuntime: () => { bridge.push('_soundRuntime'); return { generation, running }; },
    _allocateSoundNote: () => { bridge.push('_allocateSoundNote'); return next++; },
    _soundNoteToMidi: note => { bridge.push('_soundNoteToMidi'); return ({ C4: 60, E4: 64, G4: 67, D4: 62 })[note]; },
    _validateSoundOptions(request) {
      bridge.push('_validateSoundOptions');
      validations.push(request);
      return nativeError(request.kind, request.options);
    },
    getDefaults: () => ({ version: '2.0.0', capabilities: { variation: true }, defaults: { volume: 1 }, limits: {} }),
    addEventListener(name, fn) { if (!listeners.has(name)) listeners.set(name, new Set()); listeners.get(name).add(fn); },
    removeEventListener(name, fn) { listeners.get(name)?.delete(fn); }
  };
  for (const method of ['playTone', 'playChord', 'repeatTone', 'playSequence', 'updateTone', 'stopTone', 'updateSequence', 'stopSequence', '_soundHeld', 'setMasterProcessing']) {
    native[method] = options => {
      bridge.push(method);
      calls.push([method, JSON.parse(JSON.stringify(options))]);
      if (!running || reject) return false;
      // Production native entry points themselves validate before admission.
      const kind = method === 'playChord' ? 'chord' : method === '_soundHeld' && options.operation === 'on' ? 'held' : 'tone';
      if (nativeError(kind, method === '_soundHeld' ? options.options : options)) return false;
      return method === 'repeatTone' || method === 'playSequence' ? next++ : true;
    };
  }
  native._updateSoundOptions = request => {
    bridge.push('_updateSoundOptions');
    calls.push(['_updateSoundOptions', plain(request)]);
    return !reject && !nativeError(request.kind, request.options);
  };
  native.getSequenceState = () => ({ playing: true, step: 0, sequenceId: 999 });
  const context = { exports: {}, console };
  vm.runInNewContext(fs.readFileSync(require.resolve('../assets/ti.synthengine.js'), 'utf8'), context);
  Object.assign(native, context.exports);
  return { native, calls, validations, bridge, create: preset => native.createSound(preset), reject: () => { reject = true; },
    restart() { generation++; running = true; }, off() { generation++; running = false; },
    emit(name, event) { for (const fn of listeners.get(name) || []) fn(event); } };
}
const plain = value => JSON.parse(JSON.stringify(value));

test('exports a reusable sound API', () => {
  const r = rig(); assert.equal(typeof r.native.createSound, 'function');
  const input = { sound: { volume: 0.25 }, playback: { notes: ['C4'], duration: 700 } };
  const sound = r.create(input); input.sound.volume = 1;
  assert.equal(sound.play(), true);
  assert.deepEqual(r.calls[0], ['playTone', { volume: 0.25, note: 'C4', duration: 700 }]);
  sound.play({ notes: ['D4'], volume: 0.1 });
  assert.equal(r.calls[1][1].note, 'D4'); assert.equal(sound.getPreset().sound.volume, 0.25);
});
test('explicit type wins; inference never becomes an authored declaration', () => {
  const r = rig(), sound = r.create({ playback: { notes: ['C4'] } });
  assert.equal(sound.getPreset().playback.type, undefined);
  sound.play({ notes: ['C4', 'E4', 'G4'] }); assert.equal(r.calls.at(-1)[0], 'playChord');
  sound.set({ playback: { type: 'tone' } });
  assert.throws(() => sound.play({ notes: ['C4', 'E4'] }), /one|single/i);
  sound.play({ type: 'chord', notes: ['C4'] }); assert.equal(r.calls.at(-1)[0], 'playChord');
});
test('set merges objects, replaces arrays, validates atomically and returns detached copies', () => {
  const r = rig(), sound = r.create({ sound: { volume: 0.2, variation: { amount: 1, ranges: { volume: [0.1, 0.2] } } }, playback: { notes: ['C4'] } });
  sound.set({ sound: { variation: { amount: 0.5 } }, playback: { type: 'chord', notes: ['C4', 'E4'] } });
  assert.deepEqual(plain(sound.getPreset().sound.variation.ranges.volume), [0.1, 0.2]);
  assert.throws(() => sound.set({ sound: { volume: -1 }, playback: { notes: ['G4'] } }), /volume/);
  const copy = sound.getPreset(); copy.playback.notes.push('G4');
  assert.deepEqual(plain(sound.getPreset().playback.notes), ['C4', 'E4']);
  sound.play(); assert.equal(r.calls.at(-1)[0], 'playChord');
});
test('repetitions retain finite timing and independent controls; edits do not mutate Sound', () => {
  const r = rig(), sound = r.create({ sound: { release: 80 }, playback: { type: 'repeat', notes: ['C4'], duration: 150, interval: 200 } });
  const a = sound.play(), b = sound.play();
  assert.equal(r.calls[0][1].intervalMs, 200); assert.equal(r.calls[0][1].duration, 150);
  assert.equal(a.update({ interval: 180 }), true); assert.equal(r.calls.at(-1)[1].toneId, 1);
  assert.equal(sound.getPreset().playback.interval, 200);
  b.stop(); assert.equal(r.calls.at(-1)[1].toneId, 2);
  const count = r.calls.length; assert.equal(b.update({ volume: 0.1 }), false); assert.equal(r.calls.length, count);
});
test('held notes are single and use independent owned identities', () => {
  const r = rig(), sound = r.create({ sound: { volume: 0.2 }, playback: { notes: ['C4'], duration: 700 } });
  const a = sound.noteOn(), b = sound.noteOn();
  assert.notEqual(r.calls[0][1].options.voiceId, r.calls[1][1].options.voiceId);
  assert.equal('duration' in r.calls[0][1].options, false);
  assert.throws(() => sound.noteOn({ notes: ['C4', 'E4'] }), /one|single/i);
  assert.throws(() => a.update({ variation: { amount: 0 } }), /variation/);
  a.update({ notes: ['D4'] }); assert.equal(r.calls.at(-1)[1].options.note, 'D4');
  assert.equal(a.noteOff(), true); assert.equal(b.noteOff(), true);
});
test('shutdown generations invalidate all old controls while definitions survive restart', () => {
  const r = rig(), sound = r.create({ playback: { type: 'repeat', interval: 100 } });
  const old = sound.play(); r.off(); assert.equal(sound.play(), false); r.restart();
  const fresh = sound.play(), count = r.calls.length;
  assert.equal(old.stop(), false); assert.equal(old.update({ interval: 90 }), false);
  assert.equal(r.calls.length, count); assert.equal(fresh.stop(), true);
});
test('patterns translate intervals and pitch names without changing units or step overrides', () => {
  const r = rig(), sound = r.create({ sound: { volume: 0.3, detune: 2 }, playback: { type: 'pattern', timeUnit: 'beats', interval: 0.25, steps: [{ notes: ['C4', 'E4'], interval: 0.5, length: 0.3, sound: { pan: 0.2 } }, { rest: true }] } });
  const p = sound.play(), options = r.calls.at(-1)[1];
  assert.equal(options.stepDuration, 0.25); assert.equal(options.timeUnit, 'beats'); assert.equal(options.detune, 2);
  assert.deepEqual(options.steps[0], { notes: [60, 64], duration: 0.5, length: 0.3, overrides: { pan: 0.2 } });
  assert.equal(p.getState().sequenceId, undefined);
  let ends = 0; p.addEventListener('end', () => ends++);
  r.emit('sequenceend', { sequenceId: 1, reason: 'completed' });
  r.emit('sequenceend', { sequenceId: 1, reason: 'completed' });
  assert.equal(ends, 1); assert.equal(p.stop(), false);
});
test('configuration errors throw before publication; operational failure remains false', () => {
  const r = rig(); assert.throws(() => r.create({ sound: { typo: 1 } }), /typo/);
  assert.throws(() => r.create({ playback: { type: 'repeat', interval: 100, timeUnit: 'beats' } }), /timeUnit/);
  assert.throws(() => r.create({ sound: { frequencyEnd: 500 } }), /frequencyEnd/);
  const sound = r.create({ playback: { frequencyEnd: 100 } });
  assert.throws(() => sound.play({ type: 'chord', notes: ['C4'] }), /frequencyEnd/);
  r.reject(); assert.equal(sound.play(), false);
});
test('metadata reports one installed module version and processing preserves native units', () => {
  const r = rig(); assert.equal(r.native.getDefaults().version, '2.0.0');
  assert.equal(r.native.getContract().version, '2.0.0');
  r.native.setProcessing({ delay: { time: 250 }, reverb: { decay: 1500 } });
  assert.deepEqual(r.calls.at(-1), ['setMasterProcessing', { delay: { timeMs: 250 }, reverb: { decay: 1.5 } }]);
});
test('pattern pitch sweeps preserve native root and step endpoints', () => {
  const r = rig();
  const sound = r.create({ playback: { type: 'pattern', frequencyEnd: 800, steps: [{ notes: [60], sound: { frequencyEnd: 1200 } }] } });
  sound.play(); const options = r.calls.at(-1)[1];
  assert.equal(options.voice.frequencyEnd, 800);
  assert.equal(options.steps[0].overrides.frequencyEnd, 1200);
});
test('a delayed invalidation event cannot retire a pattern created after restart', () => {
  const r = rig(), sound = r.create({ playback: { steps: [{ notes: [60] }] } });
  const old = sound.play(); r.restart(); const fresh = sound.play();
  let ends = 0; fresh.addEventListener('end', () => ends++);
  r.emit('_soundinvalidate', { generation: r.native._soundRuntime().generation });
  assert.equal(old.stop(), false); assert.equal(fresh.stop(), true);
  r.emit('sequenceend', { sequenceId: 2, reason: 'completed' });
  assert.equal(ends, 1);
});
test('held defaults support native modulators and live FM can reach zero without revalidating an attack', () => {
  const r = rig(), sound = r.create({ sound: { waveType: 0, fmRatio: 2, fmDepth: 1, modulations: [{ target: 'fmDepth', depth: 0.2 }] }, playback: { type: 'held', notes: ['C4'] } });
  const note = sound.play(); assert.equal(typeof note.noteOff, 'function');
  assert.equal(note.update({ fmDepth: 0, fmRatio: 1 }), true);
  assert.throws(() => note.update({ pulseWidth: 0.3 }), /pulseWidth/);
  assert.throws(() => note.update({ modulations: [{ target: 'filterHz', depth: 0.2 }] }), /filterHz/);
});
test('publication identities never mutate dictionaries already passed to validation', () => {
  const r = rig(), sound = r.create({ playback: { type: 'repeat', interval: 100 } });
  const handle = sound.play(); handle.update({ interval: 80 });
  r.validations.filter(request => request.kind === 'repeat').forEach(request => assert.equal('toneId' in request.options, false));
  const held = r.create({ playback: { type: 'held' } }); held.noteOn(); held.noteOn();
  r.validations.filter(request => request.kind === 'held').forEach(request => assert.equal(request.options.voiceId, 1));
});
test('reusable finite playback uses one bridge call and preserves diagnostic errors', () => {
  const r = rig(), sound = r.create({ sound: { volume: 0.2 }, playback: { notes: ['C4'] } });
  r.bridge.length = 0; sound.play(); sound.play();
  assert.deepEqual(r.bridge, ['playTone', 'playTone']);
  assert.equal(sound.getPreset().sound.volume, 0.2);
});
test('unchanged pattern steps are translated once even when playback volume changes', () => {
  const r = rig(), steps = Array.from({ length: 512 }, () => ({ notes: ['C4'], sound: { volume: 0.2 } }));
  const sound = r.create({ playback: { type: 'pattern', steps } });
  r.bridge.length = 0;
  sound.play(); sound.play({ volume: 0.1 });
  assert.equal(r.bridge.filter(name => name === '_soundNoteToMidi').length, 0);
  assert.equal(sound.getPreset().playback.steps.length, 512);
  assert.equal(sound.getPreset().playback.steps[0].sound.volume, 0.2);
});

test('active optional resets replace full recipes and invalid resets are atomic', () => {
  const r = rig();
  const sound = r.create({ sound: { fmRatio: 2, fmDepth: 1 }, playback: { type: 'repeat', interval: 100 } });
  const repeat = sound.play();
  assert.throws(() => repeat.update({ fmDepth: null }), /fmDepth/);
  repeat.update({ interval: 120 });
  assert.equal(r.calls.at(-1)[1].fmDepth, 1, 'failed reset changed accepted execution');
  assert.equal(repeat.update({ fmDepth: null, fmRatio: null }), true);
  assert.equal(r.calls.at(-1)[0], '_updateSoundOptions');
  assert.deepEqual(r.calls.at(-1)[1], { kind: 'repeat', options: { intervalMs: 120, toneId: 1 } });
  repeat.update({ interval: 130 });
  assert.equal('fmDepth' in r.calls.at(-1)[1], false);
  assert.equal(sound.getPreset().sound.fmDepth, 1);
  const pattern = r.create({ sound: { pan: 0.2 }, playback: { steps: [{ notes: [60] }] } }).play();
  assert.equal(pattern.update({ pan: null }), true);
  assert.equal(r.calls.at(-1)[1].kind, 'pattern');
  assert.equal('pan' in r.calls.at(-1)[1].options.voice, false);
});
test('nested variation edits publish a complete replacement without mutating prior executions', () => {
  const r = rig(), definition = { sound: { variation: { amount: 1, ranges: { volume: [0.1, 0.2], pitchCents: [-5, 5] } } }, playback: { type: 'repeat', interval: 100 } };
  const sound = r.create(definition), first = sound.play(), second = sound.play();
  assert.equal(first.update({ variation: { ranges: { pitchCents: null } } }), true);
  assert.deepEqual(r.calls.at(-1)[1].variation, { amount: 1, ranges: { volume: [0.1, 0.2] } });
  second.update({ interval: 120 });
  assert.deepEqual(r.calls.at(-1)[1].variation.ranges.pitchCents, [-5, 5]);
  assert.deepEqual(plain(sound.getPreset()), definition);
});

test('contract inherits the native module version instead of keeping a second counter', () => {
  const r = rig();
  r.native.getDefaults = () => ({ version: '2.0.1', defaults: {}, capabilities: {}, limits: {} });
  assert.equal(r.native.getContract().version, '2.0.1');
  assert.equal('apiVersion' in r.native.getContract(), false);
  const manifest = platform => fs.readFileSync(require.resolve('../' + platform + '/manifest'), 'utf8').match(/^version:\s*(\S+)/m)[1];
  assert.equal(manifest('android'), manifest('ios'));
  const android = fs.readFileSync(require.resolve('../android/src/ti/synthengine/SynthContract.java'), 'utf8');
  const ios = fs.readFileSync(require.resolve('../ios/Classes/TiSynthengineContract.m'), 'utf8');
  assert.equal(android.match(/MODULE_VERSION = "([^"]+)"/)[1], manifest('android'));
  assert.equal(ios.match(/@"version": @"([^"]+)"/)[1], manifest('ios'));
});
