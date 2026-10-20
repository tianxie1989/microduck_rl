#!/usr/bin/env python3
"""Windows wrapper: run mjlab training with warp mempool / CUDA-graph capture OFF.

CUDA graph capture (used by mjlab's Simulation when warp mempool is enabled)
requires every captured buffer to stay resident in dedicated VRAM and cannot
spill into WDDM shared GPU memory — that is what caps velstand at ~1024 envs
on the 8 GB 4060. With mempool disabled:
  - mjlab falls back to direct kernel launches (slightly higher per-step CPU
    overhead, typically ~10-20% on collection),
  - allocations go through cudaMalloc, which CAN overflow into shared GPU
    memory instead of hard-failing, so more environments fit.

Usage (identical to `train`):
  python scripts/train_nograph.py <TASK_ID> [--env.scene.num-envs N ...]
"""
import sys

import warp as wp

wp.config.enable_mempools_at_init = False  # must be set before wp.init()

from mjlab.scripts.train import main as _train_main  # noqa: E402

if __name__ == "__main__":
    sys.exit(_train_main())
