# Why this instead of "just llama.cpp"?

Short answer: **this project *is* llama.cpp, plus everything around it that people usually get wrong by hand.** It doesn't replace llama.cpp and it isn't faster than llama.cpp. For chat it runs the same `llama-server` binary from the official release, so the tokens per second are identical. What it adds is the setup, choices and glue that take hours to get right by hand, and that break when you move the drive to another computer.

## What plain llama.cpp leaves to you

| Job | Plain llama.cpp | Portable AI Drive |
|---|---|---|
| Which build do I download? CUDA 12 or 13, Vulkan, HIP, CPU, which cudart zip? | You read the release page and guess | Detects the GPU and driver, downloads the matching build plus the right CUDA runtime, and checks GitHub's SHA-256 digest |
| Which model and which quant fits my card? | Trial and error, out-of-memory errors | Rates every model for this PC (`GPU` / `GPU+` / hidden) and picks the best quant that fits |
| Downloading 5-20 GB files reliably | Browser downloads, no integrity check | Resumable downloads, and every file is checked against Hugging Face's SHA-256 |
| `-ngl` and `-c` values | Hand-tuned per model, per PC | Uses llama.cpp's own `--fit` at launch. Setup also runs `llama-fit-params` to find the largest context that fits and writes a fast preset and a max-context preset |
| Switching models | Restart the server with new arguments | Router mode with one preset per model. Pick from the web page or send `"model": "..."` from any OpenAI client |
| Moving the drive to another PC | Paths and GPU builds break | Relative paths everywhere, and the engine (CUDA / Vulkan / CPU) is chosen when you launch, not at install |
| Images and voice | Not part of llama.cpp | stable-diffusion.cpp (Qwen-Image 2.1) and KoboldCpp (Qwen3-TTS) with their helper files, installed the same way |
| Adding or removing a model later | Edit your own scripts | Run setup again. Launchers and presets are regenerated, and your settings are kept |

## The real problems that led to this project

The author's own USB drive had these problems, which is why the project exists:

- The launcher called `llamafile.exe`, but the file on the drive was named `llamafile.exe.exe`, so **nothing started**.
- One model was a **ternary Bonsai (PQ2_0)** file. Neither llamafile nor stock llama.cpp can read that format, and it needs the [PrismML fork](https://github.com/PrismML-Eng/llama.cpp). This project uses that fork for chat because it follows upstream llama.cpp and adds the 1-bit / ternary formats.
- A 9.5 GB model was launched with `-ngl 9999999` on an 8 GB card, which forces everything onto the GPU and fails. llama.cpp's `--fit` handles this automatically when you don't override it.
- One launcher asked for a 131K context on an 8 GB card, which is too much memory.
- The image and voice models on the drive were each **missing required companion files** (VAE, text encoder, audio decoder), and there was no engine on the drive that could run them.

Every one of these is now handled by setup: it checks, downloads and verifies the files, and generates the launchers.

## Compared with other tools

Each of these is a good tool. The table only shows how they differ from this project's goal: *one drive, any PC, nothing installed, picked for the hardware*.

| | Portable, nothing installed | Picks models for your hardware | Chat | Images | Voice | Engine |
|---|---|---|---|---|---|---|
| **Portable AI Drive** | yes | yes | yes | yes (Qwen-Image 2.1) | yes (Qwen3-TTS) | latest llama.cpp (PrismML fork), stable-diffusion.cpp, KoboldCpp |
| llama.cpp release zip | yes (manual) | no | yes | — | — | itself |
| llamafile | yes (single file) | no | yes | — | — | bundled llama.cpp, updated less often. Couldn't read the Bonsai PQ2_0 file |
| KoboldCpp | yes (single exe) | partial (auto layer fit) | yes | yes | yes | its own llama.cpp + sd.cpp. **v1.122.1 couldn't run Qwen-Image 2.1** (checked in its source), so this project uses upstream stable-diffusion.cpp for images and KoboldCpp only for voice |
| Ollama | no (installed per PC, own model store) | partial | yes | — | — | its own llama.cpp-based engine |
| LM Studio | no (installed app) | yes (in-app) | yes | — | — | llama.cpp / MLX |

"—" means it isn't that tool's main focus. Check the project itself, since features change quickly.

## When you should NOT use this

- You want the absolute newest llama.cpp commit the day it lands. Use the upstream release directly (or set the engine repo in `catalog.json` to `ggml-org/llama.cpp`).
- You're on macOS. It isn't supported yet (the engines have macOS builds, and a `setup.sh` path for macOS is a welcome contribution).
- You need multi-user serving at scale. Use llama.cpp's server, vLLM or similar on a real server.

## Honest limitations

- USB drives are slower to load from than an internal SSD. The first load of a big model can take a minute.
- It relies on the release file names of three upstream projects. If those change, update the patterns in `catalog.json` (no code change needed).
- Models that don't fit on the graphics card still run, just slower. The `GPU+` label tells you this before you download.
- The chat, image and voice web pages are the engines' own pages. This project doesn't add a new user interface.
