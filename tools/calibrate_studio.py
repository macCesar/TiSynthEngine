#!/usr/bin/env python3
"""Measure fixed preset gains against production Android or Apple render callbacks.

Requires macOS/clang and Node; Android also needs a JDK and cached Oboe headers. No app files are
modified. Effects and the two new modulators are disabled for calibration;
existing vibrato, ADSR, oscillator and filter settings are preserved.
"""
import argparse
import hashlib
import json
import math
import pathlib
import subprocess
import tempfile

TOOL_ROOT = pathlib.Path(__file__).resolve().parents[1]


def generated_presets(presets):
    fields = {
        'volume': 'volume', 'waveType': 'waveType', 'attack': 'attack',
        'decay': 'decay', 'sustain': 'sustain', 'release': 'release',
        'lfoFreq': 'lfoFreq', 'lfoDepth': 'lfoDepth', 'bitDepth': 'bitDepth',
        'pulseWidth': 'pulseWidth', 'noiseRate': 'noiseRate', 'lowPassHz': 'lowPassHz',
        'filterHz': 'filterHz', 'filterQ': 'filterQ', 'fmRatio': 'fmRatio',
        'fmDepth': 'fmDepth', 'pan': 'pan',
        'spatialX': 'spatialX', 'spatialY': 'spatialY',
    }
    code = ['static std::vector<CalibrationPreset> calibrationPresets() {',
            'std::vector<CalibrationPreset> result;']
    for preset in presets:
        voice = preset['voice']
        code.append('{ Command c; c.duration=48000*5;')
        for key, field in fields.items():
            if key not in voice:
                continue
            value = voice[key]
            if not isinstance(value, (int, float)) or not math.isfinite(value):
                raise ValueError(f'{preset["id"]}: invalid {key}')
            if key in ('attack', 'decay', 'release'):
                value = round(value * 48)
            code.append(f'c.{field}={value!r};')
        filters = {'none': 0, 'lowpass': 1, 'highpass': 2, 'bandpass': 3}
        code.append(f'c.filterType={filters[voice.get("filterType", "none")]};')
        if 'spatialX' in voice or 'spatialY' in voice:
            code.append('c.spatial=true;')
        table = voice.get('waveTable', [])
        if table:
            code.append(f'c.wavetableSize={len(table)};')
            for i, value in enumerate(table):
                code.append(f'c.wavetable[{i}]={value!r};')
        code.append(f'result.push_back({{{json.dumps(preset["id"])},c}}); }}')
    code.append('return result; }')
    return '\n'.join(code)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--module-root', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    parser.add_argument('--studio-root', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, default=pathlib.Path('/tmp/studio-calibration.json'))
    parser.add_argument('--oboe-include', type=pathlib.Path)
    parser.add_argument('--platform',choices=['android','ios'],default='android')
    parser.add_argument('--benchmark', action='store_true', help='Measure 32 binaural voices, two LFOs and every effect instead of preset calibration')
    parser.add_argument('--bypass-report', type=pathlib.Path, help='Attach a matched-source bypass comparison to the benchmark report')
    parser.add_argument('--preset', action='append', help='Measure only named preset IDs; may be repeated')
    args = parser.parse_args()
    root = args.module_root.resolve()
    oboe = args.oboe_include
    if oboe is None:
        oboe = next(pathlib.Path.home().joinpath('.gradle/caches').glob('**/oboe-*/prefab/modules/oboe/include'), None)
    if oboe is None and args.platform=='android':
        raise SystemExit('Oboe headers not found; pass --oboe-include')
    java_home = pathlib.Path(subprocess.check_output(['/usr/libexec/java_home'], text=True).strip()) if args.platform=='android' else None
    javascript = '''const s=require(process.argv[1]);
const W={SINE:0,SQUARE:1,SAWTOOTH:2,TRIANGLE:3,NOISE:4,WAVETABLE:5};
console.log(JSON.stringify(s.bank(W).concat(s.demos(W),s.showcase(W)).map(p=>{const state=Object.assign({},p.state,{presetGain:1,modulations:[]});return {id:p.id,voice:s.voiceOptions(state,60,W)};})));'''
    studio = args.studio_root.resolve() / 'app/lib/studio.js'
    presets = json.loads(subprocess.check_output(['node', '-e', javascript, str(studio)], text=True))
    if args.preset:
        presets = [preset for preset in presets if preset['id'] in args.preset]
        if not presets:
            raise SystemExit('No requested preset IDs found')
    with tempfile.TemporaryDirectory(prefix='tisynth-calibration-') as folder:
        work = pathlib.Path(folder)
        header = work / 'presets.h'
        header.write_text(generated_presets(presets))
        binary = work / 'calibration'
        if args.platform=='ios':
            if args.benchmark:raise SystemExit('Use the Apple render host benchmark for matched Apple timing')
            fields={'duration':'durationSamples','attack':'attackSamples','decay':'decaySamples','release':'releaseSamples','wavetableSize':'wavetableSize'}
            table=generated_presets(presets).split('std::vector<CalibrationPreset> result;',1)[1].split('return result;',1)[0]
            entries=[]
            import re
            for item in re.findall(r'\{ Command c;(.*?)result.push_back\(\{(.*?),c\}\); \}',table,re.S):
                body,name=item;body=body.replace('48000*5','240000')
                init={"pulseWidth":".5","fmRatio":"1","filterHz":"1000","filterQ":".7071","sustain":"1"};waves={}
                for key,value in re.findall(r'c\.([\w\[\]]+)=(.*?);',body):
                    if key.startswith('wavetable['):waves[int(key[10:-1])]=value
                    else:init[fields.get(key,key)]=value
                if waves:init['wavetable']='{'+','.join(waves[i] for i in range(len(waves)))+'}'
                entries.append('{'+name+',{'+','.join('.'+key+'='+value for key,value in init.items())+'}}')
            assert len(entries)==len(presets)
            header.write_text('typedef struct {const char *id;SynthCommand command;} CalibrationPreset;\nstatic CalibrationPreset calibrationPresets[]={'+','.join(entries)+'};\n')
            driver=work/'driver.m';driver.write_text('#include "'+str(header)+'"\n'+(TOOL_ROOT/'tests/studio_calibration_ios.m').read_text())
            subprocess.run(['python3',str(TOOL_ROOT/'tools/build_ios_render_host.py'),'--source',str(root),'--output',str(binary),'--driver',str(driver)],check=True)
        else:
            command = ['clang++', '-std=c++17', '-O2', '-Wall', '-Wextra',
                       '-I' + str(oboe), '-I' + str(java_home / 'include'),
                       '-I' + str(java_home / 'include/darwin'), '-DHAS_EXPRESSIVE',
                       '-DENGINE_CPP=' + json.dumps(str(root/'android/jni/SynthOboeEngine.cpp')),
                       '-DCALIBRATION_PRESETS_HEADER=' + json.dumps(str(header)),
                       '-Wl,-undefined,dynamic_lookup', str(TOOL_ROOT / 'tests/studio_calibration_host.cpp'),
                       '-o', str(binary)]
            subprocess.run(command, cwd=root, check=True)
        run = subprocess.run([str(binary)] + (['--benchmark'] if args.benchmark else []), cwd=root, text=True, stdout=subprocess.PIPE)
        results = [json.loads(line) for line in run.stdout.splitlines() if line.startswith('{')]
        artifacts=args.output.with_suffix('.sources');artifacts.mkdir(parents=True,exist_ok=True)
        import shutil
        for source in work.iterdir():
            if source.suffix in ('.h','.m','.json'):shutil.copy2(source,artifacts/source.name)
        build_command=command if args.platform=='android' else json.loads(binary.with_suffix('.json').read_text())['command']
    if args.benchmark:
        if not results:
            raise SystemExit(f'Native benchmark failed without results ({run.returncode})')
        report = dict(results[0], workloadVerified=True,
                      workloadVerification='Native type8 command, active processing gates and nonzero wet tail after dry signal ends',
                      bypassPerformanceDeltaVerified=False,
                      bypassPerformanceLimitation='No equivalent predecessor-source timing baseline available',
                      hardwareRealtimeAcceptanceVerified=False)
        if args.bypass_report:
            bypass = json.loads(args.bypass_report.read_text())
            current_digest = hashlib.sha256((root / 'android/jni/SynthOboeEngine.cpp').read_bytes()).hexdigest()
            if not (bypass.get('legacyHashesMatch') and bypass.get('expressiveChecksPass')
                    and bypass.get('runs', 0) >= 10 and 1 <= len(bypass.get('cases', [])) <= 4
                    and all(case.get('identicalOutput') for case in bypass['cases'])
                    and bypass.get('currentSourceSha256') == current_digest):
                raise SystemExit('Bypass report does not verify the current native source')
            complete = len(bypass['cases']) == 4
            report.update(bypassPerformanceDeltaVerified=True,
                          bypassPerformanceComparisonComplete=complete,
                          bypassPerformanceMeasuredCaseCount=len(bypass['cases']),
                          bypassPerformanceWithinInvestigationThreshold=bypass['withinInvestigationThreshold'] if complete else None,
                          bypassMeasuredCasesWithinInvestigationThreshold=bypass['withinInvestigationThreshold'],
                          bypassPerformanceMeasuredCases=[{key: case[key] for key in ['name', 'spatial', 'changePercent']} for case in bypass['cases']],
                          bypassPerformanceReport=str(args.bypass_report.resolve()),
                          bypassPerformanceLimitation=bypass['baselineFidelity'])
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2))
        if run.returncode:
            raise SystemExit('Native benchmark did not meet acceptance thresholds; measurements retained')
        return
    if run.returncode:
        print(run.stdout)
        raise SystemExit(f'Native calibration failed ({run.returncode})')
    if len(results) != len(presets):
        raise SystemExit('Incomplete native calibration results')
    report = {'sampleRate': 48000, 'masterVolume': 2, 'masterSettledBeforeMeasurement': True, 'effectsEnabled': False,
              'buildCommand': build_command, 'hostDriverSha256': hashlib.sha256((TOOL_ROOT/'tests'/('studio_calibration_ios.m' if args.platform=='ios' else 'studio_calibration_host.cpp')).read_bytes()).hexdigest(),
              'newModulationsEnabled': False, 'voiceCounts': [1,2,4,8,16,32], 'targetPeakDb': -6,
              'recommendationScope': 'Maximum measured pre-protection peak over 1/2/4/8 voices; 16/32 retained as stress diagnostics, not used to lower every preset',
              'recommendationPolicy': 'Fixed scalar min(2/voiceVolume, 10**((-6.01-peakDb)/20)); no automatic app edits',
              'scenarios': ['independentLow','independentMid','independentHigh','groupedChord','unison','overlappingReleases'],
              'holdMsByScenario': {name: 50 if name=='overlappingReleases' else 2500 for name in ['independentLow','independentMid','independentHigh','groupedChord','unison','overlappingReleases']}, 'presets': results, 'platform': args.platform, 'studioSourceSha256': hashlib.sha256(studio.read_bytes()).hexdigest(), 'rendererSha256': hashlib.sha256((root/('ios/Classes/TiSynthengineModule.m' if args.platform=='ios' else 'android/jni/SynthOboeEngine.cpp')).read_bytes()).hexdigest()}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({row['id']: row['gain'] for row in results}, indent=2))
    print(f'Report: {args.output}')


if __name__ == '__main__':
    main()
