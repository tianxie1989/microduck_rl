#!/usr/bin/env python3
"""Rebuild an rsl_rl .pt actor checkpoint from an exported microduck ONNX policy.

The deployed ONNX is `actor(normalizer(obs))` with the observation normalizer
baked in: initializers are `obs_normalizer._mean`, `mlp.{0,2,4,6}.weight/bias`
and one extra divisor tensor (the std the graph divides by). The Gaussian
distribution's `std_param` is state-independent and unused in deterministic
inference, so we fabricate a small constant — distill.py only ever calls the
expert with `stochastic_output=False`.

Usage:
    python scripts/onnx_to_checkpoint.py <input.onnx> <output.pt> [--iter N]
"""
import argparse
import sys

import numpy as np
import onnx
import torch


def convert(input_onnx: str, output_pt: str, iteration: int) -> None:
    model = onnx.load(input_onnx)
    inits = {i.name: i for i in model.graph.initializer}

    mean = inits["obs_normalizer._mean"]
    # The normalizer's divisor is the single initializer that is neither the
    # mean nor an MLP parameter (torch.onnx names it e.g. onnx::Div_24).
    div_names = [n for n in inits if not (n.startswith("mlp.") or n == "obs_normalizer._mean")]
    if len(div_names) != 1:
        raise SystemExit(f"expected exactly 1 normalizer divisor initializer, found {div_names}")
    std_tensor = inits[div_names[0]]

    sd = {}
    sd["obs_normalizer._mean"] = torch.from_numpy(np.array(onnx.numpy_helper.to_array(mean))).float()
    std = torch.from_numpy(np.array(onnx.numpy_helper.to_array(std_tensor))).float()
    sd["obs_normalizer._std"] = std
    sd["obs_normalizer._var"] = std.square()
    sd["obs_normalizer.count"] = torch.tensor(1.0)  # unused in inference; count only matters for update()
    sd["distribution.std_param"] = torch.full((14,), 0.19)  # deterministic-only use (distill); value irrelevant
    for layer in ("0", "2", "4", "6"):
        w = inits[f"mlp.{layer}.weight"]
        b = inits[f"mlp.{layer}.bias"]
        sd[f"mlp.{layer}.weight"] = torch.from_numpy(np.array(onnx.numpy_helper.to_array(w))).float()
        sd[f"mlp.{layer}.bias"] = torch.from_numpy(np.array(onnx.numpy_helper.to_array(b))).float()

    ckpt = {"actor_state_dict": sd, "iter": iteration}
    torch.save(ckpt, output_pt)
    print(f"wrote {output_pt} (iter={iteration})")

    # ── Sanity: reconstructed normalizer+MLP must match the ONNX numerically ──
    import onnxruntime as ort
    torch.manual_seed(0)
    x = torch.randn(1, 61, dtype=torch.float32)  # exported graph has fixed batch dim 1
    sess = ort.InferenceSession(input_onnx, providers=["CPUExecutionProvider"])
    y_onnx = sess.run(None, {"obs": x.numpy()})[0]
    xn = (x - sd["obs_normalizer._mean"]) / sd["obs_normalizer._std"]
    y_torch = xn
    for layer in ("0", "2", "4", "6"):
        y_torch = torch.nn.functional.linear(y_torch, sd[f"mlp.{layer}.weight"], sd[f"mlp.{layer}.bias"])
        if layer != "6":
            y_torch = torch.nn.functional.elu(y_torch)
    diff = float((torch.from_numpy(y_onnx) - y_torch).abs().max())
    print(f"max |onnx - rebuilt| = {diff:.2e}")
    if diff > 1e-4:
        raise SystemExit("SANITY FAILED: rebuilt model diverges from ONNX")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input_onnx")
    ap.add_argument("output_pt")
    ap.add_argument("--iter", type=int, default=0)
    args = ap.parse_args()
    convert(args.input_onnx, args.output_pt, args.iter)


if __name__ == "__main__":
    sys.exit(main())
