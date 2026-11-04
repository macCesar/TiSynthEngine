// Native bridge acceptance probe. Use as Resources/app.js in a temporary
// Titanium app with the candidate module on an emulator or simulator only.
// Results: applicationDataDirectory/sound-api-result.json; master stays muted.
'use strict';
var synth = require('ti.synthengine');
var win = Ti.UI.createWindow({ backgroundColor: '#ffffff' });
var label = Ti.UI.createLabel({ text: 'Checking Sound API…', color: '#202020', width: '90%' });
win.add(label); win.open();
var result = { platform: Ti.Platform.osname, checks: [], events: [], complete: false, success: false };
function save() { Ti.Filesystem.getFile(Ti.Filesystem.applicationDataDirectory, 'sound-api-result.json').write(JSON.stringify(result, null, 2)); }
function check(name, condition) { if (!condition) throw new Error(name); result.checks.push(name); save(); }
function finish(error) { result.complete = true; result.success = !error; if (error) { result.error = String(error.stack || error); result.errorMessage = String(error.message || error); result.errorName = error.name; } try { synth.shutdown(); } catch (_) {} label.text = JSON.stringify(result, null, 2); save(); Ti.API.info('SOUND_API_RESULT ' + JSON.stringify(result)); }
function guarded(fn) { return function () { try { fn(); } catch (error) { finish(error); } }; }
setTimeout(guarded(function () {
  check('modern merged native/CommonJS exports', synth.getContract().version === '2.0.0');
  check('single module version in both metadata views', synth.getDefaults().version === synth.getContract().version && !('apiVersion' in synth.getDefaults()) && !('apiVersion' in synth.getContract()));
  result.hooks = { validate: typeof synth._validateSoundOptions, runtime: typeof synth._soundRuntime }; save();
  var bell = synth.createSound({ name: 'Bell', sound: { volume: 0.04, attack: 2, release: 10 }, playback: { notes: ['C4'], duration: 80 } });
  check('cold playback rejects operationally', bell.play() === false);
  check('cold processing rejects operationally', synth.setProcessing({}) === false);
  check('startup', synth.start({ maxVoices: 32, maxSequences: 4, mixingProfile: 'conservative', audioSession: 'ambient' }));
  check('silent master scalar', synth.setVolume(0));
  check('historical master dictionary', synth.setVolume({ volume: 0 }));
  check('scalar tempo', synth.setTempo(120));
  check('historical tempo dictionary', synth.setTempo({ bpm: 120 }));
  check('modern processing units', synth.setProcessing({ delay: { time: 250 }, reverb: { decay: 1500 } }));
  check('finite tone', bell.play() === true);
  check('finite chord override', bell.play({ type: 'chord', notes: ['C4', 'E4', 'G4'] }) === true);
  check('single-note chord route', bell.play({ type: 'chord', notes: ['C4'] }) === true);
  check('legacy finite tone', synth.playTone({ note: 'C4', duration: 80, attack: 2, release: 10, volume: 0.04 }));
  var invalid = false; try { bell.set({ sound: { volume: 99 } }); } catch (error) { invalid = /^TiSynth:/.test(error.message); }
  check('atomic invalid configuration', invalid && bell.getPreset().sound.volume === 0.04);
  var held = synth.createSound({ sound: { volume: 0.02, attack: 2, release: 15, fmRatio: 2, fmDepth: 1 }, playback: { type: 'held', notes: ['C4'] } });
  var note = held.play(); check('held default yields a Note', !!note && typeof note.noteOff === 'function');
  check('held live FM reaches zero', note.update({ fmDepth: 0, fmRatio: 1 }));
  check('legacy overlapping ID is isolated', synth.noteOn({ voiceId: 2147483647, note: 'D4', volume: 0.02, attack: 2, release: 15 }));
  check('legacy release preserved', synth.noteOff({ voiceId: 2147483647 }));
  check('owned held update survives legacy release', note.update({ frequencies: [330] }));
  check('owned release', note.noteOff());
  var repeat = synth.createSound({ sound: { attack: 2, release: 10, volume: 0.02 }, playback: { type: 'repeat', notes: ['C4'], duration: 80, interval: 60 } });
  var oldRepeat = repeat.play(); check('native repetition control', !!oldRepeat && oldRepeat.update({ interval: 90 }));
  var pattern = synth.createSound({ sound: { attack: 2, release: 10, volume: 0.02 }, playback: { type: 'pattern', timeUnit: 'ms', interval: 40, steps: [{ notes: ['C4'], length: 20 }, { notes: [64, 67], length: 20 }] } });
  var score = pattern.play(); check('native pattern control', !!score && typeof score.getState === 'function');
  score.addEventListener('end', function (event) { result.events.push(event.reason); save(); });
  setTimeout(guarded(function () {
    check('native completion delivered once', result.events.length === 1 && result.events[0] === 'completed');
    check('completed pattern retired', score.getState() === null && score.stop() === false);
    synth.shutdown();
    check('old repetition invalid after shutdown', oldRepeat.stop() === false);
    check('restart', synth.start({ maxVoices: 32, maxSequences: 4, mixingProfile: 'conservative', audioSession: 'ambient' })); synth.setVolume(0);
    var fresh = repeat.play(); check('definition reused after restart', !!fresh);
    check('stale update cannot affect fresh execution', oldRepeat.update({ interval: 100 }) === false);
    setTimeout(guarded(function () {
      check('fresh control survives delayed invalidation', fresh.update({ interval: 100 }));
      var livePattern = pattern.play({ loop: true });
      check('live pattern for optional reset', !!livePattern);
      setTimeout(guarded(function () {
        check('repetition optional reset reaches native full revision', fresh.update({ volume: null }));
        check('pattern optional reset reaches native full revision', livePattern.update({ volume: null }));
        check('live pattern scoped stop', livePattern.stop());
        check('fresh scoped stop', fresh.stop()); finish();
      }), 100);
    }), 300);
  }), 1200);
}), 300);
