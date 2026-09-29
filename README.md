# Portable AI Drive

Turn a USB drive into a local AI kit you can plug into any PC: **chat models, image generation and text-to-speech**, all running offline on that PC's own hardware. Nothing is installed on the computer; everything lives on the drive.

One setup program does the whole job:

1. **Checks the PC:** graphics card, VRAM, RAM, NVIDIA driver and free space on the drive.
2. **Shows a model list rated for this PC:** `GPU` = runs fully on the graphics card, `GPU+` = runs with part of it in system RAM, and models that won't fit are hidden. You pick the ones you want, or type `R` for a recommended set.
3. **Downloads the right engines** straight from their official GitHub releases: [llama.cpp](https://github.com/PrismML-Eng/llama.cpp) for chat, [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp) for images and [KoboldCpp](https://github.com/LostRuins/koboldcpp) for voice. You get the CUDA build on NVIDIA cards and the Vulkan build everywhere else, so the same drive works on other PCs.
4. **Downloads the models** from Hugging Face and checks every file's SHA-256. It picks the best quantization for this PC automatically. Downloads resume if the connection drops.
5. **Measures the biggest context each chat model can use** on this PC. It runs `llama-fit-params` and writes a fast preset and a max-context preset for each model.
6. **Writes the launchers:** a `START-AI.bat` / `start-ai.sh` menu, start and stop scripts, and an OpenAI-compatible API on port 8080.

Run setup again at any time to add or remove models, or to update the engines.

## Why this instead of a portable llama.cpp folder?

This project runs **the same llama.cpp** under the hood, so chat speed is identical. The difference is everything a bare portable llama.cpp folder leaves for you to do by hand:

| | Portable llama.cpp folder | Portable AI Drive |
|---|---|---|
| Which build do I need? | You guess between CUDA 12/13, Vulkan, HIP and CPU, plus the matching cudart zip | Detected from your GPU and driver. A Vulkan fallback is installed too, so the drive works on other PCs |
| Which model and size fits my PC? | Trial and error until something runs out of memory | Every model is rated for this PC, and the best quant that fits is picked automatically |
| Are my 10 GB downloads intact? | Unknown | Every file is checked against its SHA-256. Interrupted downloads resume |
| GPU layers and context size | Hand-tuned per model, per PC | llama.cpp's `--fit` at launch, plus a measured max-context preset for each model |
| Switching models | Restart the server with new arguments | One server with a model picker in the web page, or `"model": "..."` from any app |
| Images and voice | Not included | Qwen-Image 2.1 (stable-diffusion.cpp) and Qwen3-TTS (KoboldCpp), set up the same way |
| Newer formats | Stock builds can't read 1-bit / ternary Bonsai files | Uses the PrismML build of llama.cpp, which can |
| Launching | Write your own .bat files | `START-AI.bat` / `start-ai.sh` menus, generated for the models you installed |

More detail, and when you *shouldn't* use this, is in [docs/WHY.md](docs/WHY.md), which also compares llamafile, KoboldCpp, Ollama and LM Studio.

---

## Quick start

### Windows 10 / 11

1. Download this repository (**Code → Download ZIP**) and unzip it to the root of your USB drive (or any folder).
   *Or copy only `Setup.bat` there; it downloads the rest itself.*
2. Double-click **`Setup.bat`**.
3. Pick your models, type `D`, and wait for the downloads.
4. Double-click **`START-AI.bat`** and choose a model. Your browser opens the chat page.

No admin rights are needed. Windows 10 1803 or newer includes the `curl` and `tar` tools setup uses.

### Linux (x86-64)

```bash
git clone https://github.com/R00taccess/portable-ai-drive /media/$USER/MYDRIVE/portable-ai
cd /media/$USER/MYDRIVE/portable-ai
./setup.sh          # needs python3 and curl
bash start-ai.sh
```

For AMD or Intel GPUs on Linux, install Vulkan first: `sudo apt install libvulkan1 mesa-vulkan-drivers`.
A drive can be set up from **both** Windows and Linux. The models are shared, and each system gets its own engines (Linux ones go in `runtimes/linux/`).

---

## The model list

The list lives in [`installer/catalog.json`](installer/catalog.json). Setup downloads the latest version from this repo each time it runs, so new models show up without updating the program. Each model has several sizes, and setup picks the largest one that runs well on the PC.

| Group | Model | Sizes offered | Download | Source |
|---|---|---|---|---|
| Chat · small & fast | Qwen3.5 0.8B | Q8_0, Q4_K_M | 0.5 – 0.8 GB | [unsloth/Qwen3.5-0.8B-GGUF](https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF) |
| Chat · small & fast | LFM2.5 1.2B Instruct | Q8_0, Q4_K_M | 0.7 – 1.2 GB | [unsloth/LFM2.5-1.2B-Instruct-GGUF](https://huggingface.co/unsloth/LFM2.5-1.2B-Instruct-GGUF) |
| Chat · small & fast | Bonsai 8B (1-bit) | Q1_0 | 1.2 GB | [prism-ml/Bonsai-8B-gguf](https://huggingface.co/prism-ml/Bonsai-8B-gguf) |
| Chat · small & fast | Qwen3.5 2B | Q8_0, Q6_K, Q4_K_M | 1.3 – 2.0 GB | [unsloth/Qwen3.5-2B-GGUF](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF) |
| Chat · small & fast | Qwen3.5 4B | Q8_0, Q6_K, Q4_K_M | 2.7 – 4.5 GB | [unsloth/Qwen3.5-4B-GGUF](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF) |
| Chat · small & fast | Gemma 4 E4B | Q8_0, Q6_K, Q4_K_M | 5.0 – 8.2 GB | [unsloth/gemma-4-E4B-it-GGUF](https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF) |
| Chat · medium | Qwen3.5 9B | Q8_0, Q6_K, Q4_K_M, IQ3_XXS | 4.0 – 9.5 GB | [unsloth/Qwen3.5-9B-GGUF](https://huggingface.co/unsloth/Qwen3.5-9B-GGUF) |
| Chat · medium | NeoHorse-1 9B | Q8_0, Q5_K_M, Q4_K_M | 5.6 – 9.5 GB | [TokenRhythm/NeoHorse-1-9B-GGUF](https://huggingface.co/TokenRhythm/NeoHorse-1-9B-GGUF) |
| Chat · medium | Gemma 4 12B | Q8_0, Q6_K, Q4_K_M, Q3_K_M | 5.7 – 12.7 GB | [unsloth/gemma-4-12b-it-GGUF](https://huggingface.co/unsloth/gemma-4-12b-it-GGUF) |
| Chat · medium | Ternary Bonsai 2 27B | PQ2_0, PTQ1_0 | 5.9 – 7.2 GB | [prism-ml/Ternary-Bonsai-2-27B-gguf](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf) |
| Chat · medium | gpt-oss 20B | MXFP4 | 12.1 GB | [ggml-org/gpt-oss-20b-GGUF](https://huggingface.co/ggml-org/gpt-oss-20b-GGUF) |
| Chat · large | Gemma 4 26B-A4B (MoE) | MXFP4, Q3_K_XL, IQ2_M | 10.0 – 16.6 GB | [unsloth/gemma-4-26B-A4B-it-GGUF](https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF) |
| Chat · large | Qwen3.6 35B-A3B (MoE) | Q4_K_XL, Q3_K_XL, IQ2_M | 11.5 – 22.4 GB | [unsloth/Qwen3.6-35B-A3B-GGUF](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF) |
| Chat · large | Qwen3.8 27B | Q4_K_XL, Q3_K_XL, IQ3_XXS, Q2_K_XL | 9.8 – 17.6 GB | [unsloth/Qwen3.8-27B-GGUF](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF) |
| Chat · large | Gemma 4 31B | Q4_K_XL, Q3_K_XL, IQ2_M | 10.8 – 18.8 GB | [unsloth/gemma-4-31B-it-GGUF](https://huggingface.co/unsloth/gemma-4-31B-it-GGUF) |
| Chat · uncensored | Qwen3.8 9B Distill Heretic | Q6_K, Q4_K_M, IQ3_M | 4.5 – 7.6 GB | [mradermacher/…-heretic-i1-GGUF](https://huggingface.co/mradermacher/Qwen3.8-9B-Distill-uncensored-heretic-i1-GGUF) |
| Chat · uncensored | Huihui Qwen3.8 27B Abliterated (Bonsai) | PQ2_0, PTQ1_0 | 6.6 – 7.7 GB | [huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF](https://huggingface.co/huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF) |
| Chat · uncensored | Huihui Qwen3.8 27B Abliterated | Q4_K_XL, IQ3_XXS, IQ2_S | 8.4 – 17.4 GB | [huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF](https://huggingface.co/huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF) |
| Images | Qwen-Image 2.1 | Q8_0, Q6_K, Q4_K, Q3_K, Q2_K | 2.6 – 7.7 GB (+ 5.7 GB helpers) | [leejet/Qwen-Image-2.1-GGUF](https://huggingface.co/leejet/Qwen-Image-2.1-GGUF) |
| Images | Qwen-Image 2.1 Uncensored | Q8_0, Q6_K, Q4_K_M, Q4_0 | 4.2 – 7.6 GB (+ 5.7 GB helpers) | [abenzerps/Qwen-Image-2.1-Uncensored-GGUF](https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF) |
| Voice | Qwen3-TTS 1.7B VoiceDesign | Q8_0 | 2.4 GB | [koboldcpp/tts](https://huggingface.co/koboldcpp/tts) |
| Voice | Qwen3-TTS 1.7B CustomVoice | Q8_0 | 2.4 GB | [koboldcpp/tts](https://huggingface.co/koboldcpp/tts) |
| Voice | Qwen3-TTS 0.6B (light) | Q8_0 | 1.3 GB | [koboldcpp/tts](https://huggingface.co/koboldcpp/tts) |

The image models also need a VAE ([Comfy-Org/Qwen-Image-2.1](https://huggingface.co/Comfy-Org/Qwen-Image-2.1)) and a Qwen3-VL-8B text encoder ([Qwen/Qwen3-VL-8B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen3-VL-8B-Instruct-GGUF)). The voice models need the Qwen3-TTS audio decoder. Setup downloads these helpers automatically, once, shared by every model that needs them.

**Beyond the list:**
- `H` in the picker browses the **currently trending GGUF models on Hugging Face**. Pick one and setup chooses a file size that fits this PC. These haven't been tested by this project and may need a newer engine.
- `I` adds **.gguf files you already have** (for example from another folder or drive).

---

## Using the drive

`START-AI.bat` (Windows) or `bash start-ai.sh` (Linux) shows a menu:

- **Chat:** starts llama.cpp's server in *router mode* with every chat model you installed, one loaded at a time, and opens the chat page at <http://localhost:8080>. You can switch models from the page. Each model has two entries:
  - `Model-Name`: the context is sized so the whole model stays on the graphics card. This is the fast one.
  - `Model-Name-MaxContext`: the largest context that fit in this PC's VRAM plus RAM, up to the model's full 256K. It's slower because part of the model runs from system RAM.
- **Images:** starts stable-diffusion.cpp's server with its web page at <http://localhost:7860>. A 1024×1024 picture takes about 3 minutes on an RTX 3060 Ti.
- **Voice:** starts KoboldCpp with Qwen3-TTS. Use the **TTS tab** at <http://localhost:5001/musicui/>. With VoiceDesign, you describe the voice first:
  `[A calm older man with a deep, warm voice] Welcome back.`
- **S** stops everything, and **U** runs setup again.

### Using it from other apps (OpenAI-compatible API)

```
Base URL:  http://<PC-IP>:8080/v1
Model:     the preset name, e.g. Qwen3.5-9B   (GET /v1/models lists them)
API key:   see system/settings.bat (or settings.conf on Linux)
```

By default the server only listens on this PC (`127.0.0.1`). Setup asks whether other devices on your network should be allowed. If you say yes, it switches to `0.0.0.0` and generates an API key. You can change this later in `system/settings.bat`.

### Speeds measured on the author's PC (RTX 3060 Ti 8 GB, 32 GB RAM)

| Model | File | Speed |
|---|---|---|
| Qwen3.5 0.8B | Q8_0 | ~79 tokens/s |
| Qwen3.8 2B | Q6_K | ~94 tokens/s |
| Qwen3.8 9B Heretic | NVFP4 | ~43 tokens/s |
| NeoHorse-1 9B | Q8_0 (9.5 GB, part in RAM) | ~6 tokens/s |
| Huihui Qwen3.8 27B Bonsai | PQ2_0 (7.7 GB, part in RAM) | ~5 tokens/s |
| Qwen-Image 2.1 Uncensored | Q4_K_M, 1024×1024, 20 steps | ~3 min / image |
| Qwen3-TTS 1.7B VoiceDesign | Q8_0 | ~6 s of work per 1 s of speech |

---

## Command-line options

Everything the picker does can be scripted:

```bat
Setup.bat -Dest E:\ -Models qwen3.5-9b,qwen3-tts-voicedesign -Yes -SelfTest
Setup.bat -Models recommended -Yes
Setup.bat -Remove gemma-4-12b -Yes
Setup.bat -UpdateEngines -Yes         :: newest engine releases
Setup.bat -AllEngines                 :: also CUDA builds on a non-NVIDIA PC (for a drive you carry around)
```
```bash
./setup.sh --dest /media/me/USB --models qwen3.5-4b --yes --self-test
./setup.sh --models recommended --yes
./setup.sh --remove gemma-4-12b --yes
```
Other switches: `-NoTune` / `--no-tune`, `-Offline` / `--offline` (use the model list on the drive), `-SkipVerify` / `--skip-verify`, `-Catalog file.json` / `--catalog`, `-Lan yes|no` / `--lan yes|no`.

## What ends up on the drive

```
START-AI.bat / start-ai.sh      menu
Setup.bat / setup.sh            add / remove models, update engines
installer/                      setup.ps1 (Windows), setup.py (Linux), catalog.json
models/text  models/image  models/tts
runtimes/llama-cuda  llama-vulkan  sd-cuda  sd-vulkan  kobold      (Windows engines)
runtimes/linux/...                                                  (Linux engines)
system/settings.bat|conf        your settings - never overwritten
system/models.ini               chat presets (context, sampling) - regenerated by setup
system/installed.json           what is installed
```

## Updating the model list

`installer/catalog.json` holds each model's Hugging Face repo, the files to offer, their sizes and their SHA-256 checksums. To add a model, add an entry with its variants (largest first), then run `python3 tools/update_catalog.py` to fill in sizes and checksums from Hugging Face. Pull requests are welcome.

## Licenses and notes

- This project's scripts are MIT licensed (see [LICENSE](LICENSE)).
- The engines are downloaded from their official releases and keep their own licenses: llama.cpp (MIT), the PrismML fork (MIT), stable-diffusion.cpp (MIT) and KoboldCpp (AGPL-3.0).
- **Every model has its own license** (Apache-2.0, Gemma terms, and so on). Check the model's Hugging Face page before any commercial use.
- The *uncensored / abliterated* models have had their refusals removed by third parties. You are responsible for how you use them.
- Engines are not built or modified by this project. Setup only downloads official release files and checks GitHub's SHA-256 digests.
