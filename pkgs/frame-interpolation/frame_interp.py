import argparse
import os
import sys
from pathlib import Path

import cv2
import numpy as np
import torch

SHARE = Path(os.environ["FRAME_INTERP_SHARE"])
MODELS = Path(os.environ.get("MODEL_ROOT", "/home/jesse/.local/share/models")) / "by-name"

COMFY = {
    "rife47": "rife47.pth",
    "rife49": "rife49.pth",
    "rife417": "rife417.pth",
    "rife426": "rife426.pth",
    "gmfss-fortuna-union": "GMFSS_fortuna_union",
    "film": "film_net_fp32.pt",
}
EMA = {"ema-vfi": ("ours_t", 32, [2, 2, 2, 4, 4], True), "ema-vfi-small": ("ours_small_t", 16, [2, 2, 2, 2, 2], False)}
MAMBA = {"vfimamba": ("VFIMamba", 32, [2, 2, 2, 3, 3], True), "vfimamba-s": ("VFIMamba_S", None, None, False)}


def read_frames(inputs):
    paths = []
    for item in map(Path, inputs):
        if item.is_dir():
            paths += sorted(p for p in item.iterdir() if p.suffix.lower() in (".png", ".jpg", ".jpeg", ".webp"))
        else:
            paths.append(item)
    if len(paths) < 2:
        raise SystemExit("need at least two frames")
    frames = []
    for path in paths:
        image = cv2.imread(str(path), cv2.IMREAD_COLOR)
        if image is None:
            raise SystemExit(f"cannot read {path}")
        frames.append(image)
    if len({f.shape for f in frames}) != 1:
        raise SystemExit("all frames must have the same size")
    return frames


def comfy(model, frames, multiplier):
    os.environ.setdefault("FRAME_INTERP_CKPTS", str(MODELS / "frame-interpolation"))
    sys.path.insert(0, str(SHARE / "comfyui-frame-interpolation"))
    batch = torch.from_numpy(np.stack([f[:, :, ::-1] for f in frames]).astype(np.float32) / 255.0)
    if model == "film":
        from vfi_models.film import FILM_VFI

        out = FILM_VFI().vfi(COMFY[model], batch, multiplier=multiplier)[0]
    elif model.startswith("gmfss"):
        from vfi_models.gmfss_fortuna import GMFSS_Fortuna_VFI

        out = GMFSS_Fortuna_VFI().vfi(COMFY[model], batch, multiplier=multiplier)[0]
    else:
        from vfi_models.rife import RIFE_VFI

        out = RIFE_VFI().vfi(COMFY[model], batch, multiplier=multiplier, fast_mode=True, ensemble=True)[0]
    return [(f.numpy()[:, :, ::-1] * 255.0).round().clip(0, 255).astype(np.uint8) for f in out]


def timestep_model(model, frames, multiplier):
    if model in EMA:
        name, features, depth, tta = EMA[model]
        repo, trainer = SHARE / "ema-vfi", "Trainer"
        checkpoint = MODELS / "ema-vfi" / f"{name}.safetensors"
    else:
        name, features, depth, tta = MAMBA[model]
        repo, trainer = SHARE / "vfimamba", "Trainer_finetune"
        checkpoint = MODELS / "vfimamba" / f"{name}.pkl"
    sys.path.insert(0, str(repo))
    import config as cfg

    cfg.MODEL_CONFIG["LOGNAME"] = name
    if features:
        cfg.MODEL_CONFIG["MODEL_ARCH"] = cfg.init_model_config(F=features, depth=depth)
    module = __import__(trainer)
    from benchmark.utils.padder import InputPadder

    net = module.Model(-1)
    if checkpoint.suffix == ".safetensors":
        from safetensors.torch import load_file

        state = load_file(str(checkpoint))
    else:
        state = module.convert(torch.load(checkpoint, map_location="cpu"))
    net.net.load_state_dict(state, strict=True)
    net.eval()
    net.device()

    times = [i / multiplier for i in range(1, multiplier)]
    output = []
    with torch.no_grad():
        for first, second in zip(frames, frames[1:]):
            output.append(first)
            i0 = (torch.tensor(first.transpose(2, 0, 1)).cuda() / 255.0).unsqueeze(0)
            i1 = (torch.tensor(second.transpose(2, 0, 1)).cuda() / 255.0).unsqueeze(0)
            padder = InputPadder(i0.shape, divisor=32)
            i0, i1 = padder.pad(i0, i1)
            if model in EMA:
                preds = net.multi_inference(i0, i1, TTA=tta, time_list=times, fast_TTA=tta)
            else:
                preds = [net.inference(i0, i1, True, TTA=tta, timestep=t, fast_TTA=tta)[0] for t in times]
            for pred in preds:
                output.append(
                    (padder.unpad(pred).detach().cpu().numpy().transpose(1, 2, 0) * 255.0).clip(0, 255).astype(np.uint8)
                )
    output.append(frames[-1])
    return output


def main():
    parser = argparse.ArgumentParser(description="Interpolate frames between images")
    parser.add_argument("inputs", nargs="+", help="image files in order, or a directory of frames")
    parser.add_argument("-o", "--output", required=True, help="directory for the PNG sequence")
    parser.add_argument("-m", "--model", default="rife49", choices=[*COMFY, *EMA, *MAMBA])
    parser.add_argument("-x", "--multiplier", type=int, default=2, help="output frames per input interval")
    args = parser.parse_args()
    if args.multiplier < 2:
        raise SystemExit("multiplier must be at least 2")

    frames = read_frames(args.inputs)
    run = comfy if args.model in COMFY else timestep_model
    result = run(args.model, frames, args.multiplier)
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    for index, frame in enumerate(result):
        cv2.imwrite(str(out / f"frame_{index:05d}.png"), frame)
    print(f"{len(result)} frames -> {out}")


if __name__ == "__main__":
    main()
