#!/usr/bin/env python3
"""Run held-lifecycle bookkeeping checks using the actual module/inert bridge."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
source = (root / 'tests/run_stats_java.py').read_text()
source = source.replace(' for name,text in sources.items():',
    " sources['ti/synthengine/SoundMemoryRegression.java']=(root/'tests/sound_memory_java.java').read_text()\n for name,text in sources.items():")
source = source.replace("'ti.synthengine.StatsApiRegression'", "'ti.synthengine.SoundMemoryRegression'")
exec(compile(source, str(root / 'tests/run_stats_java.py'), 'exec'))
