# Shared local model storage

The `home` Home Manager profile declares the catalog in
`pkgs/local-models/catalog.json`, plus Real-ESRGAN files supplied by Nix.
Large weights live in `services.local-models.root`, outside the Nix store. It
defaults to `~/.local/share/models`; `home` puts it on the external USB SSD at
`/mnt/ext-ssd/models` (`hosts/home/external-ssd.nix`). Activation links the
catalog and this README into the root, and skips synchronization while the
drive is absent.

This change does not deploy itself, download the bulk catalog during a build,
install model runtimes, or claim that available files have passed inference tests.

After an authorized `nh os switch`, activation queues a background oneshot:

```sh
local-models status
systemctl --user start local-models-sync.service
journalctl --user -u local-models-sync.service -f
```

## Stores

Weights can live in several stores, each a directory holding its own
`huggingface/` cache and `files/` blobs. `services.local-models.stores` names
them and `defaultStore` picks the one for entries without a `store` field; Nix
writes both into the deployed catalog. `home` has two:

| Store | Path | Holds |
| --- | --- | --- |
| `external` (default) | `/mnt/ext-ssd/models`, the root itself | every entry without `store` |
| `install` | `~/.local/share/model-stores/install` on the NVMe system drive | entries with `"store": "install"` |

Consumers still see one root: `catalog.json`, `readiness.json`, `views/` and
`by-name/` stay in `services.local-models.root`, and each view's absolute links
point into its entry's store. Sync downloads, imports and repairs each entry in
its own store, and readiness verifies that store's files and records it as the
entry's `store`. Moving an entry to another store copies its verified files
there, offline, and leaves the old copy in place. An entry whose store can't be
created or written reports `missing` without affecting other stores.
Activation creates every store directory. `HF_HUB_CACHE` points only at the
root's cache, so reach entries in other stores through `by-name`.
The root stays on the external drive, so while it is unplugged the aliases
for `install` entries are unreachable too, though their weights remain.

`catalog.json` is the deployed source of truth. `readiness.json` reports each
entry as ready, missing, blocked, unresolved, or historical-disabled.
`compatibility` and `consumerReady` describe a separate runtime validation state;
`consumer-evidenced` records an existing loader, not validation after migration.
An unresolved or missing dependency prevents its pipeline/adapter becoming ready.
Sync logs every entry that is not ready with its reason. It exits 1 only when
an entry is missing or blocked; entries the catalog marks unresolved, and those
waiting on them, are reported but don't fail it.
The historical TikTok group is disabled by default; enable
`services.local-models.historical = true` after reviewing its catalog.
Heretical Qwen remains excluded; its old safetensors consumers need migration.

## Synchronization and integrity

Each file has an immutable Hub revision and exact size plus SHA-256 (LFS) or Git
blob SHA-1 (small Git files). Downloads use the Nix-pinned Hugging Face library
and standard `huggingface/blobs` and revision snapshot layout. Standalone files
require HTTPS URLs and SHA-256. No wildcard or floating revision is used at run
time. `runtimeSources` records implementation commits; it does not install code.

Complete files are verified locally before any network request. Verification
stamps are keyed by content identity and filesystem identity, size, mtime and
ctime; changed files are hashed again. Alias, formatting and executable changes
do not invalidate weights. Missing/damaged files are repaired individually.
Existing complete revisions and damaged files are retained; nothing prunes models.
New aliases publish only after all required files and dependencies are ready;
a failed update retains the previous working alias but reports the new entry's
failure. Views contain links, not duplicated checkpoints.

Before downloading, the synchronizer verifies declared existing project files,
the host/sandbox HF caches and reusable shared blobs. Project imports use a
reflink where supported, otherwise a copy. They never hardlink mutable project
weights or alter existing consumers. Budget for a copy on filesystems without
reflinks. H3's flat `.models` layout is imported this way; its manifests stay
intact. Existing consumers continue to work until explicitly migrated. At least
the next file's full size plus 2 GiB must be free before a transfer; interrupted
Hub files remain resumable. Check disk headroom before enabling the full catalog.

Every successful deployment creates `.state/pending` and starts the path watcher
and service without waiting for transfers. Neither unit is attached to a boot
target or timer. `X-SwitchMethod=keep-old` preserves running transfers. A filesystem
lock serializes syncs; a separate short lock protects request consumption. The
oneshot removes pending before reading the latest deployed catalog. Requests
during a run leave pending behind: systemd.path rechecks it after service exit,
including requests arriving as the process exits. No RemainAfterExit or restart
loop is used. A failure is visible in readiness and journal; retry is manual or
at the next switch. A later run reads rotated credentials. Activation failures
to reach the user manager do not fail deployment; pending is retained.

See [systemd.path](https://www.freedesktop.org/software/systemd/man/latest/systemd.path.html)
for its post-exit check and
[Hub downloads](https://huggingface.co/docs/huggingface_hub/en/guides/download)
for pinned caching and resumable file transfers.

## Host credentials

On the host, create `/home/jesse/.config/local-models` at mode `0700`, and put only
the raw HF read token in `hf-token` at mode `0600`, owned by Jesse. No quotes,
JSON, `HF_TOKEN=`, `export` or `Bearer` prefix. Never put the token in chat, Git,
the Nix store or model storage. Accept access to:

- [LTX-2.5](https://huggingface.co/Lightricks/LTX-2.5)
- [Pixel upscaler LoRA](https://huggingface.co/Lightricks/LTX-2.5-22b-IC-LoRA-Pixel-Spatial-Upscaler)
- [SAM 3](https://huggingface.co/facebook/sam3)
- [SAM 3.1](https://huggingface.co/facebook/sam3.1)
- [Qwen3.8-27B Uncensored GGUF](https://huggingface.co/orcarouter/Qwen3.8-27B-Uncensored-GGUF)

The user unit uses `LoadCredential` with a non-secret `SetCredential=hf-token:unconfigured` fallback. This
makes an absent source nonfatal, as documented by
[systemd.exec](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#Credentials).
The process uses the supplied credential only, removes inherited `HF_TOKEN`, and
passes `token=False` without a valid supplied token. Public entries continue if
gated entries fail. Credential bodies and Hub error bodies are never logged.
Rotate by replacing the host file and starting a new sync invocation.

## Consumer integration

New agent sandboxes get the complete root and every other store
(`~/.config/local-models/stores`) read-only at the same absolute paths,
with `MODEL_ROOT`, `HF_HUB_CACHE`, `IMG2VIDEO_MODELS` and `SAM` explicitly set.
Recreate existing containers after deployment. Compilation and runtime caches
must stay elsewhere. View and snapshot links resolve inside the mounted root and stores; packaged
Real-ESRGAN links resolve through the existing `/nix/store` mount. The HF token
source and systemd credentials are outside sandbox mounts. Host and sandbox
Claude rules and Codex context share the same discovery/readiness policy.

| Consumer | Configured path / next step |
| --- | --- |
| img2video | `IMG2VIDEO_MODELS=$MODEL_ROOT/by-name/img2video`; Qwen directory and exact LTX/LoRA filenames are assembled there. Existing Python environments remain required. |
| Site SAM 2.1 scripts | `SAM=$MODEL_ROOT/by-name/sam2.1`; Transformers offline local directory. No automatic replacement by SAM 3. |
| H3 | Run `scripts/run-h3.py --models "$MODEL_ROOT/by-name/h3"`; flat selected Ref2VA NVFP4/AWQ/VAE/upscaler layout. The separate `h3-fl2va` alias supplies the pinned FL2VA NVFP4 checkpoint with shared encoder/VAEs for native ComfyUI first/last-frame conditioning. NVFP4 requires Blackwell; runners and the ComfyUI environment remain in their projects. |
| Speech research | `WhisperModel("$MODEL_ROOT/by-name/whisper-tiny.en", local_files_only=True)` using an expanded environment path. |
| Voice service | Add `-f ~/.config/local-models/voice-compose.yaml` to local voice Compose commands. It mounts `/models`, the complete root and every other store at their same absolute paths so snapshot/view links resolve. Existing remote `deploy.sh` exports its own model store; production deployment remains unchanged. |
| ComfyUI | Pass `--extra-model-paths-config ~/.config/local-models/comfyui.yaml`; shared H3 and LTX adapter paths are declared. Runtime/plugins are separate. |
| Qwen3.8 coding/chat | `by-name/qwen3.8-27b/Qwen3.8-27B-Q5_K_M.gguf`; llama.cpp from the locked nixpkgs is the candidate runtime. `qwen-prompt` runs it one-shot at 16k; `qwen-opencode` serves it on demand at 64k and unloads it when idle ([GPU reservations](gpu-scheduler.md#interactive-qwen-in-opencode)). |
| Qwen3.8 uncensored | `by-name/qwen3.8-27b-uncensored/Qwen3.8-27B-Uncensored-Q5_K_M.gguf`; the same alias includes `mmproj-Qwen3.8-27B-Uncensored-f16.gguf` for vision. Gated Hub access is required; llama.cpp loading, tools and peak VRAM remain unverified. |
| SAM 3 / SAM 3.1 | Pass the selected `.pt` file explicitly to the separately pinned Meta implementation; preserve its bundled BPE. Do not use a Transformers safetensors loader on these files. Video/object-count memory checks remain required. |
| BiRefNet | Snapshot includes pinned custom code/configuration. Review that code in a separate runtime; verify offline loading does not fetch a pretrained backbone. No automatic requirements installation. |
| SkinTokens / UniRig / Diff3F | Catalog files are available through aliases; configure upstream local paths and validate separate Python/CUDA/Blender environments. SkinTokens preserves `models/Qwen3-0.6B/`; UniRig includes OPT-350m configuration only, with `llm.pretrained_model_name_or_path` pointing at its `opt-350m/` view. Diff3F remains unresolved until DINOv2's published artifact is verified. |
| Hunyuan3D-2 | The sandbox's `hy3dgen` loads `$MODEL_ROOT/by-name/hunyuan3d-2` by expanded absolute path: `Hunyuan3DDiTFlowMatchingPipeline.from_pretrained(path, subfolder="hunyuan3d-dit-v2-0")` for shape and `Hunyuan3DPaintPipeline.from_pretrained(path, subfolder="hunyuan3d-paint-v2-0-turbo")` for texture, which also reads `hunyuan3d-delight-v2-0`. Tencent Hunyuan Community License: not licensed in the EU, UK or South Korea. Shape needs about 6 GiB VRAM and fits an 8 GiB reservation; shape plus texture needs about 16 GiB, or the paint pipeline's `enable_model_cpu_offload()` with an unmeasured peak. Pass RGBA images: `hy3dgen.rembg` otherwise downloads u2net. |
| Hunyuan3D-2mv | `hy3dgen` loads `$MODEL_ROOT/by-name/hunyuan3d-2mv` by expanded absolute path with `Hunyuan3DDiTFlowMatchingPipeline.from_pretrained(path, subfolder="hunyuan3d-dit-v2-mv")`, then takes `image={"front": ..., "left": ..., "back": ...}`. Only the base multi-view model is included, not the fast or turbo distillations. Same licence as Hunyuan3D-2. Shape alone should fit an 8 GiB reservation like Hunyuan3D-2's shape model, but its peak is unmeasured; texture uses `hunyuan3d-2`'s paint pipeline on the front view. Pass RGBA images. |
| Frame interpolation | Sandbox `frame-interp -m rife49\|rife426\|gmfss-fortuna-union\|film\|ema-vfi\|ema-vfi-small\|vfimamba\|vfimamba-s -x N FRAMES... -o OUT` reads `frame-interpolation`, `ema-vfi` and `vfimamba`. RIFE, GMFSS and FILM run through ComfyUI-Frame-Interpolation's model code with a stub for ComfyUI's device helpers; kernels and Mamba target sm_120 only. GMFSS union comes from a third-party mirror and EMA-VFI from a safetensors conversion. |
| ToonCrafter | Sandbox `tooncrafter --prompt_dir DIR --savedir OUT`, with DIR holding `<name>_frame1.png`, `<name>_frame3.png` and a `.txt` of one prompt per pair. It reads `tooncrafter` and `openclip-vit-h-14`; runs without xformers. Each pair writes `OUT/samples_separate/<name>_frame1_sample0.mp4` and its 16 frames as `000.png`… in `OUT/samples_separate/<name>_frame1_sample0/`. Budget about 22 GiB VRAM and 16 GiB RAM. |
| Wan 2.1 FLF2V | `frame-interp-python` has diffusers and ftfy. The snapshot is fp32 (about 90 GB: a 62 GB transformer and a 22 GB UMT5 encoder), and Wan-AI publishes no bf16 or fp8 export. A plain `WanImageToVideoPipeline.from_pretrained(..., torch_dtype=torch.bfloat16)` doesn't fit the sandbox: the 28 GB bf16 transformer exceeds its 20 GB RAM limit and, beside the encoder, a 32 GB GPU; CPU offload needs the same host copy. Instead encode the prompts with `UMT5EncoderModel` in bf16 on the GPU and free it; build `WanTransformer3DModel` under accelerate's `init_empty_weights` and stream each safetensors tensor to the GPU with `set_module_tensor_to_device`, casting `blocks.*` 2-D Linear weights to `float8_e4m3fn` and the rest to bf16; call `.to("cuda")` for the rotary buffers and `diffusers.hooks.apply_layerwise_casting(storage_dtype=float8_e4m3fn, compute_dtype=bfloat16)`, skipping norms and the embedding and output layers; then build the pipeline with `text_encoder=None` and pass `prompt_embeds` and `negative_prompt_embeds`. That loads in 17 GiB VRAM and peaks at about 26 GiB at 832x480 with 33 frames. |

Ellen and Jane are merged checkpoints, with deterministic reference WAV/text
extracted from their pinned parquet assets into the view. The source parquet
and canonical snapshot remain intact. Nefer's composed view includes its exact
root checkpoint and `adapter/`; its loader applies PEFT and merges in memory.
Elaina is a checkpoint, not a separately applied adapter. Never overwrite shared
bases with merges or infer compatibility from a model name. The H3 comparison
checkpoint and Taomate adapter remain disabled/unresolved pending provenance
and compatibility verification. They do not replace the selected H3 pipeline.

Sharing files does not share dependencies or loaded GPU memory. Acquire a GPU
reservation before any model load or inference, and retain it through cleanup.
SAM/BiRefNet masks do not reconstruct hidden content; they do not replace
Qwen's generative parallax extraction or establish production alpha matting.

## Validation and rollout

`nix build .#checks.x86_64-linux.local-models .#checks.x86_64-linux.local-models-activation`
runs small fixture tests without
fetching weights. They cover offline repetition, repairs, imports, partial
failures, adapters, layouts, request retention and process serialization.
`nix fmt` formats/lints the code. Evaluate/build the affected host before an
authorized switch. No evaluation/build/test should request the bulk catalog.

Live deployment, systemd execution on the host, fresh sandbox mount checks,
consumer migration and GPU inference are separate rollout checks. Do not label
all models installed or runtime-validated based on configuration evaluation.

Implementation verification in the development sandbox: the `home` system and
Home Manager activation derivations evaluated, the downloader package built,
and 22 Nix fixture tests passed, including real Hub-library HTTP resume, offline
reuse with zero requests, selective repair, reference preparation and process
serialization. The generated units passed systemd 260.5 verification; a rendered
activation fixture verified dry runs, first/unchanged switches and nonblocking
requests. Changed-file formatting/lint passed. Repository-wide `nix fmt`
also found a pre-existing missing-shell-directive error in
`users/jesse/claude/merge-settings.sh`. No live system switch, bulk synchronization,
fresh-container mount test or GPU inference was performed. The published DINOv2
URL returned HTTP 403 during provenance verification; it and its Diff3F pipeline
remain unresolved, while H3 comparisons remain disabled pending provenance.
