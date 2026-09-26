"""Node `report` of helm-merge-queue. The work lives in the pack's shared module."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".shared"))
from merge_queue import entry

raise SystemExit(entry("report"))
