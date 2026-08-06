#!/usr/bin/env python3
"""Print covered/total LCOV points for each Verilator coverage mode."""
import sys
from pathlib import Path

for name in sys.argv[1:]:
    points = [line.split(",", 1)[1] for line in Path(name).read_text().splitlines()
              if line.startswith("DA:")]
    covered = sum(int(count) > 0 for count in points)
    total = len(points)
    print(f"{name.removeprefix('coverage-').removesuffix('.info')}: "
          f"{covered}/{total} ({100 * covered / total:.1f}%)")
