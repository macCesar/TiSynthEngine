'use strict';

// Shared public entry layer. Native validators and renderers remain authoritative.
const SOUND_KEYS = 'attack decay sustain release volume waveType pan lfoFreq lfoDepth noiseRate lowPassHz pulseWidth waveTable bitDepth filterType filterHz filterQ fmRatio fmDepth spatialX spatialY bus effectSend priority variation detune panEnd noiseRateEnd pulseWidthEnd filterHzEnd fmDepthEnd detunes pans panSpread modulations'.split(' ');
const PLAY_KEYS = 'type notes frequencies frequencyEnd duration interval timeUnit steps gate loop swing mode tuning'.split(' ');
const PATTERN_KEYS = 'type interval timeUnit steps gate loop swing mode tuning frequencyEnd'.split(' ');
const LIVE_KEYS = 'notes frequencies volume pan lfoFreq lfoDepth noiseRate lowPassHz pulseWidth filterHz filterQ fmRatio fmDepth spatialX spatialY effectSend modulations'.split(' ');
const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
function fail(key, reason) { throw new TypeError('TiSynth: ' + key + ': ' + reason); }
function dictionary(value, path) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(path, 'expected an object');
}
function copy(value, path) {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (Array.isArray(value)) return value.map((item, index) => copy(item, path + '[' + index + ']'));
  dictionary(value, path);
  const result = {};
  Object.keys(value).forEach(key => {
    if (key === '__proto__' || key === 'constructor' || key === 'prototype') fail(path + '.' + key, 'reserved key');
    result[key] = copy(value[key], path + '.' + key);
  });
  return result;
}
function keys(value, allowed, path) {
  dictionary(value, path);
  Object.keys(value).forEach(key => { if (allowed.indexOf(key) < 0) fail(path + '.' + key, 'unsupported property'); });
}
// Explicit null resets an optional setting; arrays always replace, never merge.
function merge(previous, changes) {
  // Both inputs are private snapshots. Share untouched branches; never mutate
  // an earlier definition or execution when constructing the next revision.
  const result = Object.assign({}, previous);
  Object.keys(changes).forEach(key => {
    const value = changes[key];
    if (value === null) delete result[key];
    else if (value && typeof value === 'object' && !Array.isArray(value)) result[key] = merge(result[key] || {}, value);
    else result[key] = value;
  });
  return result;
}
function shape(preset) {
  keys(preset, ['name', 'sound', 'playback'], 'preset');
  if (own(preset, 'name') && typeof preset.name !== 'string') fail('name', 'expected a string');
  if (own(preset, 'sound')) keys(preset.sound, SOUND_KEYS, 'sound');
  if (own(preset, 'playback')) keys(preset.playback, PLAY_KEYS, 'playback');
}
function overrides(changes) {
  changes = changes === undefined ? {} : copy(changes, 'changes');
  keys(changes, SOUND_KEYS.concat(PLAY_KEYS), 'changes');
  const patch = { sound: {}, playback: {} };
  Object.keys(changes).forEach(key => { patch[SOUND_KEYS.indexOf(key) >= 0 ? 'sound' : 'playback'][key] = changes[key]; });
  return patch;
}
function effective(previous, patch) {
  const result = merge(previous, patch);
  if (patch.playback && own(patch.playback, 'notes')) delete result.playback.frequencies;
  if (patch.playback && own(patch.playback, 'frequencies')) delete result.playback.notes;
  if (patch.playback && own(patch.playback, 'notes') && own(patch.playback, 'frequencies')) fail('notes', 'cannot combine notes and frequencies');
  return result;
}
function noteName(note) {
  if (typeof note === 'string') return note;
  if (!Number.isInteger(note) || note < 12 || note > 119) fail('notes', 'expected note names or integer MIDI notes 12..119');
  return ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'][note % 12] + (Math.floor(note / 12) - 1);
}
function pitches(playback, single) {
  if (own(playback, 'notes') && own(playback, 'frequencies')) fail('notes', 'cannot combine notes and frequencies');
  const field = own(playback, 'notes') ? 'notes' : own(playback, 'frequencies') ? 'frequencies' : null;
  if (!field) return {};
  const values = playback[field];
  if (!Array.isArray(values) || !values.length || (single && values.length !== 1)) fail(field, single ? 'expected exactly one note' : 'expected a nonempty array');
  const converted = field === 'notes' ? values.map(noteName) : values.slice();
  const result = {}; result[single ? field === 'notes' ? 'note' : 'frequency' : field] = single ? converted[0] : converted;
  return result;
}
function interpretation(preset) {
  const playback = preset.playback || {};
  if (own(playback, 'type')) {
    if (['tone', 'chord', 'repeat', 'pattern', 'held'].indexOf(playback.type) < 0) fail('type', 'unknown interpretation');
    return playback.type;
  }
  if (own(playback, 'steps')) return 'pattern';
  return (playback.notes || playback.frequencies || []).length > 1 ? 'chord' : 'tone';
}
function validate(engine, kind, options) {
  const error = engine._validateSoundOptions({ kind, options });
  if (error) fail(error.key || kind, error.reason || 'invalid configuration');
}
function compile(engine, preset, held, previous, deferValidation) {
  shape(preset);
  const sound = Object.assign({}, preset.sound || {}), playback = preset.playback || {};
  const kind = held ? 'held' : interpretation(preset);
  if (kind === 'held') {
    if (!held) keys(playback, ['type', 'notes', 'frequencies'], 'playback');
    held = true;
  }
  let options;
  if (kind === 'pattern') {
    keys(playback, PATTERN_KEYS, 'playback');
    options = { voice: sound };
    if (own(playback, 'frequencyEnd')) sound.frequencyEnd = playback.frequencyEnd;
    ['timeUnit', 'gate', 'loop', 'swing', 'mode', 'tuning'].forEach(key => { if (own(playback, key)) options[key] = playback[key]; });
    if (own(playback, 'interval')) options.stepDuration = playback.interval;
    if (own(sound, 'detune')) { options.detune = sound.detune; delete sound.detune; }
    if (!Array.isArray(playback.steps)) fail('steps', 'expected an array');
    options.steps = previous && previous.sourceSteps === playback.steps ? previous.options.steps : playback.steps.map((step, index) => {
      keys(step, ['notes', 'frequencies', 'rest', 'interval', 'length', 'gate', 'sound'], 'steps[' + index + ']');
      const converted = {};
      ['frequencies', 'rest', 'length', 'gate'].forEach(key => { if (own(step, key)) converted[key] = step[key]; });
      if (own(step, 'notes')) {
        if (!Array.isArray(step.notes)) fail('steps.notes', 'expected an array');
        converted.notes = step.notes.map(note => {
          const midi = typeof note === 'number' ? note : engine._soundNoteToMidi(note);
          if (!Number.isInteger(midi) || midi < 12 || midi > 119) fail('steps.notes', 'invalid MIDI note or note name');
          return midi;
        });
      }
      if (own(step, 'interval')) converted.duration = step.interval;
      if (own(step, 'sound')) { keys(step.sound, SOUND_KEYS.concat('frequencyEnd'), 'steps.sound'); converted.overrides = step.sound; }
      return converted;
    });
  } else {
    if (!held) keys(playback, kind === 'repeat' ? ['type', 'notes', 'frequencies', 'duration', 'frequencyEnd', 'interval'] : ['type', 'notes', 'frequencies', 'duration', 'frequencyEnd'], 'playback');
    options = Object.assign(sound, pitches(playback, kind !== 'chord'));
    if (!held) {
      ['duration', 'frequencyEnd'].forEach(key => { if (own(playback, key)) options[key] = playback[key]; });
      if (kind === 'repeat') {
        if (!Number.isInteger(playback.interval) || playback.interval < 1 || playback.interval > 60000) fail('interval', 'expected integer milliseconds 1..60000');
        options.intervalMs = playback.interval;
      }
    } else options.voiceId = 1; // Validation only. Publication receives a module-owned ID.
  }
  if (!deferValidation) validate(engine, kind, options);
  return { kind, options, sourceSteps: playback.steps };
}
const registries = new WeakMap();
function validateLiveSource(source, changes) {
  const wave = own(source, 'waveType') ? source.waveType : 0;
  const filtered = source.filterType && source.filterType !== 'none';
  const spatial = own(source, 'spatialX') || own(source, 'spatialY');
  const compatible = key => {
    if ((key === 'filterHz' || key === 'filterQ') && !filtered) fail(key, 'requires an active filter on the original voice');
    if (key === 'pulseWidth' && wave !== 1) fail(key, 'requires a square voice');
    if ((key === 'fmDepth' || key === 'fmRatio') && wave !== 0) fail(key, 'requires a sine voice');
    if ((key === 'spatialX' || key === 'spatialY') && !spatial) fail(key, 'requires a spatial voice');
    if (key === 'pan' && spatial) fail(key, 'requires a stereo voice');
  };
  Object.keys(changes).forEach(compatible);
  if (Array.isArray(changes.modulations)) changes.modulations.forEach(modulation => compatible(modulation.target));
}
function registerPattern(engine, id, generation, finish) {
  let registry = registries.get(engine);
  if (!registry) {
    const entries = new Map();
    const end = event => { const entry = entries.get(event.sequenceId); if (entry) { entries.delete(event.sequenceId); entry.finish(event); } };
    const invalidate = event => {
      entries.forEach((entry, key) => {
        if (entry.generation < event.generation) { entries.delete(key); entry.finish(null); }
      });
    };
    registry = { entries, end, invalidate }; registries.set(engine, registry);
    engine.addEventListener('sequenceend', end);
    engine.addEventListener('_soundinvalidate', invalidate);
  }
  registry.entries.set(id, { generation, finish });
}
function control(engine, preset, kind, id, initialCompiled) {
  const generation = engine._soundRuntime().generation, listeners = new Set();
  let active = true, accepted = preset, lastCompiled = initialCompiled;
  const valid = () => {
    if (!active) return false;
    const runtime = engine._soundRuntime();
    return runtime.generation === generation && runtime.running;
  };
  if (kind === 'pattern') registerPattern(engine, id, generation, event => {
    const emit = active && event && engine._soundRuntime().generation === generation;
    active = false;
    const callbacks = Array.from(listeners); listeners.clear();
    if (emit) callbacks.forEach(listener => listener({ reason: event.reason }));
  });
  const result = {
    update(changes) {
      if (!valid()) return false;
      const patch = overrides(changes);
      if (!Object.keys(changes).length) fail('changes', 'expected at least one property');
      const resets = Object.keys(changes).some(key => changes[key] === null);
      if (resets && kind === 'held') fail('changes', 'held updates require concrete live values');
      if (kind === 'held') keys(changes, LIVE_KEYS, 'update');
      if (own(patch.playback, 'type') && patch.playback.type !== kind) fail('type', 'cannot change an active interpretation');
      const next = effective(accepted, patch);
      let ok;
      if (kind === 'held') {
        validateLiveSource(accepted.sound || {}, patch.sound);
        const options = Object.assign({}, patch.sound, pitches(patch.playback, true), { voiceId: id });
        validate(engine, 'heldUpdate', options);
        ok = engine._soundHeld({ operation: 'update', options });
      } else {
        const compiled = compile(engine, next, false, lastCompiled, true);
        if (compiled.kind !== kind) fail('type', 'cannot change an active interpretation');
        if (kind === 'pattern' && next.playback.timeUnit !== accepted.playback.timeUnit) fail('timeUnit', 'fixed during playback');
        const publication = Object.assign({}, compiled.options);
        publication[kind === 'repeat' ? 'toneId' : 'sequenceId'] = id;
        // Legacy updates merge omitted native leaves. A reset must publish
        // the complete revision without inheriting those removed settings.
        ok = resets ? engine._updateSoundOptions({ kind, options: publication })
          : engine[kind === 'repeat' ? 'updateTone' : 'updateSequence'](publication);
        // Legacy entry points validate before admitting a command. Diagnose a
        // rejected request without adding another bridge call on success.
        if (!ok) validate(engine, kind, compiled.options);
        if (ok) lastCompiled = compiled;
      }
      if (ok) accepted = next;
      return !!ok;
    }
  };
  if (kind === 'held') result.noteOff = () => {
    if (!valid()) return false;
    const ok = engine._soundHeld({ operation: 'off', options: { voiceId: id } });
    if (ok) active = false;
    return !!ok;
  };
  else result.stop = () => {
    if (!valid()) return false;
    const options = {}; options[kind === 'repeat' ? 'toneId' : 'sequenceId'] = id;
    const ok = engine[kind === 'repeat' ? 'stopTone' : 'stopSequence'](options);
    if (ok && kind === 'repeat') active = false;
    return !!ok;
  };
  if (kind === 'pattern') {
    result.getState = () => {
      if (!valid()) return null;
      const state = engine.getSequenceState({ sequenceId: id });
      if (!state) return null;
      const copyState = copy(state, 'state'); delete copyState.sequenceId; return copyState;
    };
    result.addEventListener = (name, listener) => {
      if (name !== 'end' || typeof listener !== 'function') fail('listener', 'expected end event and function');
      if (valid()) listeners.add(listener);
    };
    result.removeEventListener = (name, listener) => { if (name === 'end') listeners.delete(listener); };
  }
  return Object.freeze(result);
}
exports.createSound = function createSound(definition) {
  const engine = this;
  let preset = copy(definition, 'preset'), compiledPreset = compile(engine, preset, false);
  function startHeld(next, prepared) {
    const compiled = prepared || compile(engine, next, true, null, true);
    const id = engine._allocateSoundNote(); if (!id) return false;
    const publication = Object.assign({}, compiled.options, { voiceId: id });
    if (!engine._soundHeld({ operation: 'on', options: publication })) { validate(engine, 'held', compiled.options); return false; }
    return control(engine, next, 'held', id, compiled);
  }
  return Object.freeze({
    getPreset() { return copy(preset, 'preset'); },
    set(changes) {
      changes = copy(changes, 'changes'); shape(changes);
      const next = effective(preset, changes), compiled = compile(engine, next, false, compiledPreset);
      preset = next; compiledPreset = compiled;
    },
    play(changes) {
      const next = changes === undefined ? preset : effective(preset, overrides(changes));
      const compiled = next === preset ? compiledPreset : compile(engine, next, false, compiledPreset, true);
      if (compiled.kind === 'held') return startHeld(next, compiled);
      const methods = { tone: 'playTone', chord: 'playChord', repeat: 'repeatTone', pattern: 'playSequence' };
      const accepted = engine[methods[compiled.kind]](compiled.options);
      if (!accepted) { validate(engine, compiled.kind, compiled.options); return false; }
      return compiled.kind === 'tone' || compiled.kind === 'chord' ? true : control(engine, next, compiled.kind, accepted, compiled);
    },
    noteOn(changes) {
      if (changes !== undefined) keys(changes, LIVE_KEYS.concat(SOUND_KEYS), 'noteOn');
      const next = changes === undefined ? preset : effective(preset, overrides(changes));
      return startHeld(next, next === preset && compiledPreset.kind === 'held' ? compiledPreset : null);
    }
  });
};
exports.getContract = function getContract() {
  const contract = copy(this.getDefaults(), 'contract');
  contract.capabilities = Object.assign({}, contract.capabilities, { soundObjects: true });
  contract.interpretations = ['tone', 'chord', 'repeat', 'pattern', 'held'];
  contract.units = { envelope: 'ms', duration: 'msIncludingRelease', repetitionInterval: 'ms', pattern: ['beats', 'ms'] };
  contract.soundProperties = SOUND_KEYS.slice(); contract.playbackProperties = PLAY_KEYS.slice();
  return contract;
};
exports.setProcessing = function setProcessing(changes) {
  const options = copy(changes, 'processing');
  if (options.delay && own(options.delay, 'time')) {
    if (own(options.delay, 'timeMs')) fail('delay.timeMs', 'use time');
    options.delay.timeMs = options.delay.time; delete options.delay.time;
  }
  if (options.reverb && own(options.reverb, 'decay')) {
    if (typeof options.reverb.decay !== 'number') fail('reverb.decay', 'expected milliseconds');
    options.reverb.decay /= 1000;
  }
  validate(this, 'processing', options);
  return this.setMasterProcessing(options);
};
