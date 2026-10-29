#!/usr/bin/env python3
"""Archive a baseline, compare exact host samples, and alternate matched trials.
No devices are opened. Build while compilers run, then --run-only after they stop.
Requires macOS, cached Oboe headers, JDK, clang++, and a local baseline git revision.
"""
import argparse
import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import statistics
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(args):
    work = args.work_dir
    work.mkdir(parents=True, exist_ok=True)
    baseline = work / 'baseline'
    baseline.mkdir(exist_ok=True)
    archive = subprocess.check_output(['git', 'archive', args.baseline], cwd=ROOT)
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        source.extractall(baseline, filter='data')
    oboe = next(Path.home().joinpath('.gradle/caches').glob('**/oboe-1.11.0/prefab/modules/oboe/include'))
    java = Path(subprocess.check_output(['/usr/libexec/java_home'], text=True).strip())
    flags = ['clang++', '-std=c++17', '-O3', '-Wall', '-I' + str(oboe),
             '-I' + str(java / 'include'), '-I' + str(java / 'include/darwin'),
             '-DHAS_EXPRESSIVE', '-Wl,-undefined,dynamic_lookup']
    binaries = {}
    for mode, source in [('baseline', baseline), ('current', ROOT)]:
        for kind, harness in [('render', 'engine_render_host.cpp'), ('rates', 'bypass_rates_host.cpp'), ('benchmark', 'stats_benchmark_host.cpp')]:
            binary = work / (mode + '-' + kind)
            command = flags + ['-DENGINE_CPP=' + json.dumps(str(source / 'android/jni/SynthOboeEngine.cpp'))]
            if mode == 'current':
                command += ['-DSYNTH_BENCH_MAX_SEQUENCES=4']
            command += [str(ROOT / 'tests' / harness), '-o', str(binary)]
            subprocess.run(command, cwd=ROOT, check=True)
            binaries[mode + '-' + kind] = sha(binary)
    for kind in ['render', 'rates']:
        outputs = []
        for mode in ['baseline', 'current']:
            output = subprocess.check_output([str(work / (mode + '-' + kind))], text=True)
            (work / (mode + '-' + kind + '.log')).write_text(output)
            outputs.append(output)
        if outputs[0] != outputs[1]:
            raise RuntimeError(kind + ' samples differ; inspect logs before benchmarking')
    metadata = {'baselineRevision': subprocess.check_output(['git', 'rev-parse', args.baseline], cwd=ROOT, text=True).strip(),
                'nativeSourceSha256': sha(ROOT / 'android/jni/SynthOboeEngine.cpp'),
                'sharedSha256': {p.name: sha(p) for p in sorted((ROOT / 'shared').glob('*.h'))},
                'binaries': binaries, 'referenceScenarios': 9, 'rateWaveCases': 30,
                'bitExactReference': True, 'currentMaxSequences': 4}
    (work / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print('Built matched baseline/current; 9 reference scenarios and 30 rate/wave cases bit-exact', flush=True)


def measure(args):
    work = args.work_dir
    metadata = json.loads((work / 'metadata.json').read_text())
    assert metadata['nativeSourceSha256'] == sha(ROOT / 'android/jni/SynthOboeEngine.cpp'), 'Source changed; rebuild'
    assert metadata['sharedSha256'] == {p.name: sha(p) for p in sorted((ROOT / 'shared').glob('*.h'))}, 'Headers changed; rebuild'
    for name, digest in metadata['binaries'].items():
        assert digest == sha(work / name), 'Binary changed'
    report = dict(metadata, generatedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  conditions='Synthetic Android callback on macOS; no physical output. O3, 48kHz, 256 frames/block, diagnostics off, 5Hz snapshots, twenty simulated seconds per trial; one warmup then ten or more alternating trials. Current preallocates 4 sequences, baseline has 1. Host wall timing includes scheduling stalls.',
                  physicalAcceptance=False, runs=args.runs, cases=[])
    env = os.environ.copy()
    env.pop('SYNTH_STATS_FULL', None)
    for spatial in [False, True]:
        for scenario, name in [(1, 'oneVoice'), (2, '32Voices')]:
            trials = {'baseline': [], 'current': []}
            for run in range(args.runs + 1):
                for mode in (['baseline', 'current'] if run % 2 == 0 else ['current', 'baseline']):
                    row = json.loads(subprocess.check_output([str(work / (mode + '-benchmark')), str(scenario), str(int(spatial))], env=env, text=True))
                    if run:
                        trials[mode].append(row)
            assert len({r['hash'] for rows in trials.values() for r in rows}) == 1, 'Benchmark samples changed'
            medians = {m: {k: statistics.median(r[k] for r in rows) for k in ['renderMs', 'p95Ms']} for m, rows in trials.items()}
            change = {k: 100 * (medians['current'][k] / medians['baseline'][k] - 1) for k in ['renderMs', 'p95Ms']}
            case = dict(name=name, spatial=spatial, bitExact=True, median=medians, changePercent=change,
                        requiresInvestigation=change['renderMs'] > 2 or change['p95Ms'] > 5, trials=trials)
            report['cases'].append(case)
            args.output.write_text(json.dumps(report, indent=2) + '\n')
            print(json.dumps({k: case[k] for k in ['name', 'spatial', 'changePercent', 'requiresInvestigation']}), flush=True)
    report['allWithinThreshold'] = all(not r['requiresInvestigation'] for r in report['cases'])
    args.output.write_text(json.dumps(report, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', default='937e774')
    parser.add_argument('--work-dir', type=Path, default=Path('/tmp/tisynth-unified-benchmark'))
    parser.add_argument('--output', type=Path, default=ROOT / 'documentation/unified-bypass-performance.json')
    parser.add_argument('--runs', type=int, default=10)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--build-only', action='store_true')
    modes.add_argument('--run-only', action='store_true')
    args = parser.parse_args()
    if args.runs < 10:
        parser.error('At least ten measured alternating trials are required')
    if not args.run_only:
        build(args)
    if not args.build_only:
        measure(args)


if __name__ == '__main__':
    main()
