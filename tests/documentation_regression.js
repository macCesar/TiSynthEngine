const assert = require('assert')
const fs = require('fs')
const path = require('path')
const vm = require('vm')

const root = path.resolve(__dirname, '..')
const publicFiles = [
  'README.md',
  'CHANGELOG.md',
  'android/README.md',
  'android/Resources/README.md',
  'android/platform/README.md',
  'ios/README.md',
  'ios/Resources/README.md',
  'ios/platform/README.md',
  'documentation/index.md',
  'documentation/guide.md',
  'documentation/api.md',
  'documentation/examples.md',
  'documentation/sound-design.md',
  'documentation/audio-engine.md',
  'documentation/recommendations.md',
  'documentation/troubleshooting.md',
  'documentation/third-party-notices.md',
  'documentation/stats-performance.md',
  'example/README.md'
]

function read(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), 'utf8')
}

function githubSlug(heading) {
  return heading
    .trim()
    .toLowerCase()
    .replace(/<[^>]+>/g, '')
    .replace(/[`*_~]/g, '')
    .replace(/[^\p{L}\p{N}\s-]/gu, '')
    .replace(/\s+/g, '-')
}

function headings(source) {
  const counts = new Map()
  const anchors = new Set()
  for (const match of source.matchAll(/^#{1,6}\s+(.+)$/gm)) {
    const base = githubSlug(match[1])
    const count = counts.get(base) || 0
    counts.set(base, count + 1)
    anchors.add(count === 0 ? base : `${base}-${count}`)
  }
  return anchors
}

function checkLinks(relativePath, source) {
  for (const match of source.matchAll(/!?\[[^\]]*\]\(([^)]+)\)/g)) {
    const destination = match[1].trim().replace(/^<|>$/g, '')
    if (/^(?:https?:|mailto:)/.test(destination)) continue

    const split = destination.split('#')
    const targetPart = decodeURIComponent(split[0])
    const fragment = split[1] ? decodeURIComponent(split[1]) : ''
    const baseDirectory = path.dirname(path.join(root, relativePath))
    const target = targetPart ? path.resolve(baseDirectory, targetPart) : path.join(root, relativePath)

    assert(fs.existsSync(target), `${relativePath} links to missing ${destination}`)
    if (fragment && fs.statSync(target).isFile() && path.extname(target).toLowerCase() === '.md') {
      assert(headings(fs.readFileSync(target, 'utf8')).has(fragment.toLowerCase()),
        `${relativePath} links to missing heading ${destination}`)
    }
  }
}

function checkJavaScriptFences(relativePath, source) {
  let index = 0
  for (const match of source.matchAll(/```javascript\s*\n([\s\S]*?)```/g)) {
    index += 1
    const code = match[1]
    try {
      new vm.Script(code, { filename: `${relativePath}#javascript-${index}` })
    } catch (error) {
      const trimmed = code.trim()
      if (!(trimmed.startsWith('{') && trimmed.endsWith('}'))) throw error
      new vm.Script(`(${trimmed})`, { filename: `${relativePath}#javascript-${index}` })
    }
  }
}

function checkUnwrappedProse(relativePath, source) {
  let fenced = false
  let previousWasProse = false

  for (const line of source.split('\n')) {
    if (line.startsWith('```')) {
      fenced = !fenced
      previousWasProse = false
      continue
    }
    if (fenced) continue

    const isProse = line.length > 0
      && !/^(?:#{1,6}\s|[-*+]\s|\d+\.\s|>|<| {4}|\t|\|)/.test(line)
    assert(!(isProse && previousWasProse),
      `${relativePath} hard-wraps a prose paragraph`)
    previousWasProse = isProse
  }
}

for (const relativePath of publicFiles) {
  const source = read(relativePath)
  for (const version of source.match(/(?<![\d.])\d+\.\d+\.\d+/g) || []) {
    assert(version === '1.0.0' || version === '1.11.0' || /^13\.\d+\.\d+$/.test(version)
      || (relativePath === 'documentation/stats-performance.md' && ['21.0.0', '2100.3.34'].includes(version)),
      `${relativePath} mentions version ${version}; unexpected module/toolchain version`)
  }
  assert(!/\b(?:legacy|backwards? compatibility|migration)\b/i.test(source),
    `${relativePath} contains historical compatibility language`)
  assert(!/[—–]/.test(source), `${relativePath} contains editorial dash punctuation`)
  checkLinks(relativePath, source)
  checkJavaScriptFences(relativePath, source)
}

const apiDoc = read('documentation/api.md')
const guideDoc = read('documentation/guide.md')
const nativeContract = read('android/src/ti/synthengine/SynthContract.java')
const nativeModule = read('android/src/ti/synthengine/TiSynthEngineModule.java')
const nativeIosContract = read('ios/Classes/TiSynthengineContract.m')
const exampleApp = read('example/app.js')
new vm.Script(exampleApp, { filename: 'example/app.js' })
function documentedKeys (section) {
  const keys = []
  for (const row of section.split('\n').filter(line => line.startsWith('|'))) {
    for (const match of row.split('|')[1].matchAll(/`([^`]+)`/g)) {
      keys.push(...match[1].split(',').map(key => key.trim()))
    }
  }
  return [...new Set(keys)].sort()
}
function nativeIosKeys (method, target) {
  const source = nativeIosContract.split('+ (NSDictionary *)validate' + method + ':')[1]
  assert(source, 'iOS validator exists: ' + method)
  const list = source.match(new RegExp('RejectUnknownOptions\\(' + target + ',\\s*@\\[([\\s\\S]*?)\\]\\)'))
  assert(list, 'iOS allowlist exists: ' + method + '/' + target)
  return [...new Set([...list[1].matchAll(/@"(\w+)"/g)].map(match => match[1]))].sort()
}
function nativeKeys (method, target) {
  const source = nativeContract.split('static Validation validate' + method + '(')[1]
  assert(source, 'native validator exists: ' + method)
  const list = source.match(new RegExp('rejectUnknownOptions\\(' + target + ',([\\s\\S]*?)\\);'))
  assert(list, 'native allowlist exists: ' + method + '/' + target)
  return [...new Set([...list[1].matchAll(/"(\w+)"/g)].map(match => match[1]))].sort()
}

for (const [method, validator] of [['start', 'Start'], ['playTone', 'Tone'],
  ['playChord', 'Chord'], ['setVolume', 'SetVolume'], ['noteOn', 'NoteOn'],
  ['noteOff', 'NoteOff'], ['updateVoice', 'UpdateVoice']]) {
  const section = apiDoc.split('## `' + method + '(options)`')[1]
  assert(section, method + ' documented')
  const table = section.split('\n## ')[0]
  assert.deepStrictEqual(documentedKeys(table), nativeKeys(validator, 'options'), method + ' Java options')
  assert.deepStrictEqual(documentedKeys(table), nativeIosKeys(validator, 'options'), method + ' iOS options')
}
const defaultsSection = apiDoc.split('## `getDefaults()`')[1].split('\n## ')[0]
const defaultsExample = [...defaultsSection.matchAll(/```javascript\s*\n([\s\S]*?)```/g)]
  .find(match => /^\s*\{/.test(match[1]))
assert(defaultsExample, 'getDefaults documents its returned object')
const defaultObject = defaultsExample[1]
const reported = vm.runInNewContext('(' + defaultObject + ')')
assert.deepStrictEqual(Object.keys(reported.defaults).sort(), [...nativeModule.matchAll(/defaults\.put\("(\w+)"/g)].map(m => m[1]).sort())
const nativeConstants = new Map()
for (const [prefix, source] of [['SynthContract.', nativeContract], ['', nativeModule]]) {
  for (const match of source.matchAll(/static final (?:int|double|String)\s+(\w+)\s*=\s*([^;]+);/g)) {
    nativeConstants.set(prefix + match[1], match[2].trim())
  }
}
function nativeDefaultValue (expression) {
  if (expression === 'true' || expression === 'false') return expression === 'true'
  if (expression === 'new Object[]{}') return []
  if (/^".*"$/.test(expression)) return JSON.parse(expression)
  if (/^-?[\d.]+$/.test(expression)) return Number(expression)
  const key = expression
  assert(nativeConstants.has(key), 'resolve native default ' + key)
  return nativeDefaultValue(nativeConstants.get(key))
}
for (const match of nativeModule.matchAll(/defaults\.put\("(\w+)",\s*([^;]+)\);/g)) {
  assert.deepStrictEqual(JSON.parse(JSON.stringify(reported.defaults[match[1]])), nativeDefaultValue(match[2].trim()),
    'getDefaults example has the native value of ' + match[1])
}

// Execute the integration example; syntax alone cannot catch reversed Y or
// accidentally leaving binaural fields present when the app switch is off.
const integration = guideDoc.split('## Integrate binaural in a 2D app')[1]
assert(integration, 'the app integration guide exists')
const placementExample = [...integration.matchAll(/```javascript\s*\n([\s\S]*?)```/g)]
  .find(match => match[1].includes('function playPositionedTone'))[1]
const requests = []
const sandbox = {
  supportsBinaural: true,
  contract: { waveTypes: { NOISE: 4 } },
  synth: { playTone: options => { requests.push(JSON.parse(JSON.stringify(options))); return true } },
  Ti: { API: { warn: () => {} } }
}
vm.runInNewContext(placementExample, sandbox)
sandbox.audioSettings.horizontalPercent = 100
const originalRecipe = { frequency: 880, duration: 400, pan: 0, panEnd: 0 }
for (const [x, y, expectedX, expectedY] of [[0, 0, -1, 1], [500, 0, 0, 1], [1000, 0, 1, 1],
  [0, 400, -1, 0], [500, 400, 0, 0], [1000, 400, 1, 0],
  [0, 800, -1, -1], [500, 800, 0, -1], [1000, 800, 1, -1]]) {
  sandbox.playPositionedTone(originalRecipe, x, y, 1000, 800)
  const options = requests.at(-1)
  assert.strictEqual(options.spatialX, expectedX)
  assert.strictEqual(options.spatialY, expectedY)
  assert(!('pan' in options) && !('panEnd' in options), 'binaural removes stereo fields')
}
assert.deepStrictEqual(originalRecipe, { frequency: 880, duration: 400, pan: 0, panEnd: 0 },
  'placement preserves the synthesis recipe')
sandbox.audioSettings.heightPercent = 0
sandbox.playPositionedTone(originalRecipe, 1000, 800, 1000, 800)
assert.strictEqual(Math.abs(requests.at(-1).spatialY), 0, 'zero height centers binaural elevation')
assert('spatialX' in requests.at(-1), 'zero height does not disable binaural')
sandbox.audioSettings.horizontalPercent = 50
sandbox.playPositionedTone(originalRecipe, 1000, 400, 1000, 800)
assert.strictEqual(requests.at(-1).spatialX, 0.5, 'horizontal slider scales direction')
sandbox.audioSettings.binaural = false
sandbox.playPositionedTone(originalRecipe, 1000, 0, 1000, 800)
assert.strictEqual(requests.at(-1).pan, 0.5)
assert(!('spatialX' in requests.at(-1)) && !('spatialY' in requests.at(-1)),
  'the off switch omits coordinates')
sandbox.audioSettings.binaural = true
sandbox.supportsBinaural = false
sandbox.playPositionedTone(originalRecipe, 1000, 800, 1000, 800)
assert.strictEqual(requests.at(-1).pan, 0.5, 'a module without spatial support uses stereo')
assert(!('spatialY' in requests.at(-1)))
assert.throws(() => sandbox.playPositionedTone(originalRecipe, 0, 0, 0, 800),
  /positive dimensions/, 'invalid arena dimensions are rejected')


// Execute native score recipes and submit the resulting payloads to both real
// contract implementations. Timing expectations are hand-derived fixtures.
const corpus = []
function score(file, heading) {
  const section = read(file).split(heading + '\n')[1]
  assert(section, heading)
  const fence = section.split(/\n#{1,3} /)[0].match(/```javascript\s*\n([\s\S]*?)```/)[1]
  const requests = []
  vm.runInNewContext(fence, {
    synth: {
      setTempo: options => { assert(options.bpm >= 20 && options.bpm <= 300); return true },
      playSequence: options => { requests.push(JSON.parse(JSON.stringify(options))); return 1 }
    }, WAVE: { SINE: 0, SQUARE: 1, SAWTOOTH: 2, TRIANGLE: 3, NOISE: 4, WAVETABLE: 5 }
  })
  assert.strictEqual(requests.length, 1, heading + ' publishes one native score')
  corpus.push({ api: 'sequence', options: requests[0], accepted: true })
  return requests[0]
}
const tempo = score('documentation/examples.md', '## Tempo, note values and swing')
assert.strictEqual(tempo.stepDuration, .5)
assert.strictEqual(tempo.steps[4].duration, 1)
const milliseconds = score('documentation/examples.md', '## Millisecond pattern')
assert.strictEqual(milliseconds.timeUnit, 'ms')
let position = 0
const starts = []
for (const step of milliseconds.steps) {
  if (!step.rest) starts.push(position)
  position += step.duration ?? milliseconds.stepDuration
}
assert.deepStrictEqual(starts, [0, 110, 220, 330])
for (const [file, heading] of [
  ['documentation/examples.md', '## Wave-shaping pattern overrides'],
  ['documentation/examples.md', '## Step overrides'],
  ['documentation/examples.md', '## Noise percussion'],
  ['documentation/sound-design.md', '### Two-tone alarm'],
  ['documentation/sound-design.md', '### Retro pickup'],
  ['documentation/sound-design.md', '### Noise percussion']
]) score(file, heading)
const os = require('node:os')
const cp = require('node:child_process')
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'synth-doc-contract-'))
try {
  const corpusPath = path.join(work, 'scores.jsonl')
  fs.writeFileSync(corpusPath, corpus.map(row => JSON.stringify(row)).join('\n') + '\n')
  cp.execFileSync('python3', [path.join(root, 'tests/run_studio_java.py'), corpusPath], { cwd: root, stdio: 'inherit' })
  if (process.platform === 'darwin') {
    const binary = path.join(work, 'ios-contracts')
    cp.execFileSync('clang', ['-fobjc-arc', '-Wall', '-Wextra', '-framework', 'Foundation',
      'tests/studio_corpus_ios.m', 'ios/Classes/TiSynthengineContract.m', '-o', binary], { cwd: root, stdio: 'inherit' })
    cp.execFileSync(binary, [corpusPath], { cwd: root, stdio: 'inherit' })
  }
} finally { fs.rmSync(work, { recursive: true, force: true }) }
console.log('documentation: links, JS syntax, API tables/defaults, positioning and native score contracts PASS')
