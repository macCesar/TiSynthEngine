#!/usr/bin/env python3
"""Reuse the actual-module host plumbing; validate the new native entry layer."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
source = (root / 'tests/run_stats_java.py').read_text()
source = source.replace(' for name,text in sources.items():',
    " sources['ti/synthengine/SoundBoundaryRegression.java']=(root/'tests/sound_boundary_java.java').read_text()\n for name,text in sources.items():")
source = source.replace("'ti.synthengine.StatsApiRegression'", "'ti.synthengine.SoundBoundaryRegression'")
exec(compile(source, str(root / 'tests/run_stats_java.py'), 'exec'))
