#!/usr/bin/env python3
"""
Portable AI Drive - Linux installer
https://github.com/R00taccess/portable-ai-drive

Same job as installer/setup.ps1 on Windows:
  1. checks this PC (GPU, VRAM, RAM, free disk)
  2. shows chat / image / voice models rated for this PC and lets you pick
  3. downloads the engines (llama.cpp, stable-diffusion.cpp, KoboldCpp) and the
     models, checking every file's SHA-256
  4. measures the biggest context each chat model can use here
  5. writes start-ai.sh and the start/stop scripts

Python 3.8+ standard library only. Usually started through ./setup.sh
A drive set up on Windows can also be set up on Linux: models are shared,
the Linux engines go to runtimes/linux/.
"""
import argparse, fnmatch, hashlib, json, os, platform, random, re, shutil, socket
import string, subprocess, sys, tarfile, time, urllib.request, zipfile

VERSION = "1.0.0"
REPO_RAW = "https://raw.githubusercontent.com/R00taccess/portable-ai-drive/main"
UA = {"User-Agent": "portable-ai-drive-setup"}
HERE = os.path.dirname(os.path.abspath(__file__))
GiB = 1024 ** 3

# ------------------------------------------------------------------ console
C = {"c": "\033[36m", "g": "\033[32m", "y": "\033[33m", "r": "\033[31m", "d": "\033[90m", "w": "\033[97m", "0": "\033[0m"}
if not sys.stdout.isatty():
    C = {k: "" for k in C}
def say(t="", col=""): print(C.get(col, "") + t + C["0"] if col else t, flush=True)
def head(t): say(""); say("== " + t + " " + "=" * max(3, 60 - len(t)), "c")
def warn(t): say("  [!] " + t, "y")
def ok(t): say("  [ok] " + t, "g")
def fail(t): say(""); say("  ERROR: " + t, "r"); sys.exit(1)
def fmt(b):
    b = float(b)
    return "%.1f GB" % (b / GiB) if b >= GiB else "%d MB" % (b / 1024 ** 2)
def safe_name(s): return re.sub(r"[^A-Za-z0-9.\-]+", "-", re.sub(r"[()]", "", s)).strip("-")

ARGS = None
def ask(prompt):
    try:
        return input(C["w"] + prompt + " " + C["0"]).strip()
    except EOFError:
        return ""
def ask_yes(prompt, default=True):
    if ARGS.yes or not INTERACTIVE:
        return default
    a = ask(prompt + (" [Y/n]" if default else " [y/N]"))
    if not a:
        return default
    return a.lower() in ("y", "yes")

def http_json(url, timeout=60):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))

# ------------------------------------------------------------------ hardware
def run(cmd, timeout=30):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout, text=True)
        return p.returncode, p.stdout
    except Exception:
        return 1, ""

def has_libvulkan():
    rc, out = run(["ldconfig", "-p"])
    if rc == 0 and "libvulkan.so.1" in out:
        return True
    for d in ("/usr/lib", "/usr/lib64", "/usr/lib/x86_64-linux-gnu", "/lib/x86_64-linux-gnu"):
        if os.path.exists(os.path.join(d, "libvulkan.so.1")):
            return True
    return False

def get_hardware():
    hw = {"os": "", "cpu": "", "cores": os.cpu_count() or 1, "ram": 0.0, "free_ram": 0.0,
          "gpus": [], "vram": 0.0, "nvidia": False, "nv_driver": "", "vulkan": has_libvulkan(), "backend": "cpu"}
    try:
        with open("/etc/os-release") as f:
            m = re.search(r'PRETTY_NAME="([^"]+)"', f.read())
            hw["os"] = m.group(1) if m else platform.platform()
    except Exception:
        hw["os"] = platform.platform()
    try:
        with open("/proc/cpuinfo") as f:
            m = re.search(r"model name\s*:\s*(.+)", f.read())
            hw["cpu"] = m.group(1).strip() if m else platform.processor()
    except Exception:
        pass
    try:
        with open("/proc/meminfo") as f:
            mi = f.read()
        hw["ram"] = round(int(re.search(r"MemTotal:\s+(\d+)", mi).group(1)) * 1024 / GiB, 1)
        hw["free_ram"] = round(int(re.search(r"MemAvailable:\s+(\d+)", mi).group(1)) * 1024 / GiB, 1)
    except Exception:
        pass
    if shutil.which("nvidia-smi"):
        rc, out = run(["nvidia-smi", "--query-gpu=name,memory.total,driver_version", "--format=csv,noheader,nounits"])
        if rc == 0:
            for line in out.strip().splitlines():
                p = [x.strip() for x in line.split(",")]
                if len(p) >= 3:
                    v = round(float(p[1]) / 1024, 1)
                    hw["gpus"].append("%s (%s GB)" % (p[0], v))
                    hw["vram"] = max(hw["vram"], v)
                    hw["nv_driver"] = p[2]
                    hw["nvidia"] = True
    # AMD dedicated VRAM
    try:
        for card in sorted(os.listdir("/sys/class/drm")):
            f = os.path.join("/sys/class/drm", card, "device", "mem_info_vram_total")
            if re.match(r"card\d+$", card) and os.path.exists(f):
                v = round(int(open(f).read().strip()) / GiB, 1)
                if v >= 2:
                    hw["gpus"].append("AMD GPU %s (%s GB)" % (card, v))
                    hw["vram"] = max(hw["vram"], v)
                    hw["amd"] = True
    except Exception:
        pass
    if not hw["gpus"] and shutil.which("lspci"):
        rc, out = run(["lspci"])
        for line in out.splitlines():
            if re.search(r"VGA|3D controller|Display", line) and not re.search(r"NVIDIA", line):
                hw["gpus"].append(line.split(":", 2)[-1].strip() + " (shared memory)")
    if hw["nvidia"]:
        try:
            major = int(hw["nv_driver"].split(".")[0])
        except Exception:
            major = 0
        hw["backend"] = "cuda" if major >= 525 else ("vulkan" if hw["vulkan"] else "cpu")
        hw["old_driver"] = major < 525
    elif hw["gpus"] and hw["vulkan"]:
        hw["backend"] = "vulkan"
    hw["curl"] = bool(shutil.which("curl"))
    return hw

# ------------------------------------------------------------------ rating
def rate(hw, model, size):
    s = size / GiB
    v, ram = hw["vram"], hw["ram"]
    gpu_free = v - 1.2
    total = gpu_free + (ram - 4) * 0.85
    t = model["type"]
    if t == "chat":
        if v > 0 and s + 0.8 <= gpu_free: return "GPU"
        if s + 1.0 <= total: return "MIX"
    elif t == "image":
        if v > 0 and s + 1.5 <= gpu_free: return "GPU"
        if s + 7 <= ram - 3: return "MIX"
    elif t == "voice":
        if v > 0 and s + 1.0 <= gpu_free: return "GPU"
        if s + 3 <= ram: return "MIX"
    return "NO"

def pick_variant(hw, model):
    vs = model["variants"]
    rated = [(v, rate(hw, model, v["size"])) for v in vs]
    gpu = [v for v, r in rated if r == "GPU"]
    mix = [v for v, r in rated if r == "MIX"]
    if model["type"] == "chat" and model.get("moe") and mix:
        best = [v for v, r in rated if r != "NO"][0]
        return best, rate(hw, model, best["size"])
    if gpu:
        return gpu[0], "GPU"
    if mix:
        cap = max(1.5 * hw["vram"], 4) * GiB
        c = [v for v in mix if v["size"] <= cap]
        return (c[0] if c else mix[-1]), "MIX"
    return vs[-1], "NO"

def pick_component(hw, comp):
    vs = comp["variants"]
    if len(vs) == 1:
        return vs[0]
    return vs[0] if (hw["vram"] >= 12 and hw["ram"] >= 32) else vs[-1]

# ------------------------------------------------------------------ downloads
def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(b)
    return h.hexdigest()

def download(url, out, size=0, sha=""):
    os.makedirs(os.path.dirname(out), exist_ok=True)
    name = os.path.basename(out)
    if os.path.exists(out):
        if size <= 0 or os.path.getsize(out) == size:
            if sha and not ARGS.skip_verify and sha256_of(out) != sha.lower():
                warn(name + " is damaged - downloading again"); os.remove(out)
            else:
                ok(name + " already downloaded"); return
        else:
            os.remove(out)
    part = out + ".part"
    for attempt in range(1, 4):
        say("  downloading %s%s" % (name, " (%s)" % fmt(size) if size else ""), "w")
        good = False
        if url.startswith("file://") or os.path.isfile(url):
            src = url[7:] if url.startswith("file://") else url
            shutil.copyfile(src, part); good = True
        elif HW.get("curl"):
            rc = subprocess.call(["curl", "-L", "--fail", "--retry", "5", "--retry-delay", "3", "--connect-timeout", "30", "-C", "-", "-o", part, url])
            good = rc == 0
        else:
            try:
                have = os.path.getsize(part) if os.path.exists(part) else 0
                req = urllib.request.Request(url, headers=dict(UA, **({"Range": "bytes=%d-" % have} if have else {})))
                with urllib.request.urlopen(req, timeout=60) as r, open(part, "ab" if have and r.status == 206 else "wb") as f:
                    shutil.copyfileobj(r, f, 8 * 1024 * 1024)
                good = True
            except Exception as e:
                warn(str(e))
        if good and os.path.exists(part):
            if size and os.path.getsize(part) != size:
                warn("size mismatch - retrying"); continue
            if sha and not ARGS.skip_verify:
                say("  checking SHA-256...", "d")
                if sha256_of(part) != sha.lower():
                    warn("checksum mismatch - downloading again"); os.remove(part); continue
            os.replace(part, out)
            ok(name)
            return
        warn("download interrupted (try %d of 3)" % attempt)
        time.sleep(3)
    fail("could not download %s. Run setup again later - partial files resume." % url)

# ------------------------------------------------------------------ engines
REL_CACHE = {}
def get_release(repo):
    if repo in REL_CACHE:
        return REL_CACHE[repo]
    try:
        r = http_json("https://api.github.com/repos/%s/releases/latest" % repo)
    except Exception:
        r = http_json("https://api.github.com/repos/%s/releases?per_page=5" % repo)[0]
    REL_CACHE[repo] = r
    return r

def find_exe(root, exe):
    for dp, dn, fn in os.walk(root):
        if exe in fn:
            return os.path.relpath(os.path.join(dp, exe), root)
    return ""

def install_engine(key, flavor):
    eng = CAT["engines"][key]
    pats = eng["assets"].get("linux-" + flavor) or []
    if not pats:
        return False
    dirname = "kobold" if key == "kobold" else key + "-" + flavor
    d = os.path.join(ROOT, "runtimes", "linux", dirname)
    skey = "linux-" + key + "-" + flavor
    have = STATE["engines"].get(skey)
    repo = eng["repo"]
    try:
        rel = get_release(repo)
    except Exception:
        if not eng.get("fallback_repo"):
            raise
        warn(repo + " not reachable, using " + eng["fallback_repo"]); repo = eng["fallback_repo"]; rel = get_release(repo)
    if have and have["version"] == rel["tag_name"] and not ARGS.update_engines and os.path.exists(os.path.join(d, have["exe"])):
        ok("%s %s %s already installed" % (eng["name"], flavor, rel["tag_name"])); return True
    say("  %s (%s) %s from github.com/%s" % (eng["name"], flavor, rel["tag_name"], repo), "w")
    dl = os.path.join(ROOT, "runtimes", "_downloads")
    exe_rel = ""
    for pat in pats:
        asset = next((a for a in rel["assets"] if fnmatch.fnmatch(a["name"], pat)), None)
        if not asset:
            warn("no file matching %s in %s %s" % (pat, repo, rel["tag_name"])); return False
        sha = asset.get("digest", "")[7:] if str(asset.get("digest", "")).startswith("sha256:") else ""
        f = os.path.join(dl, asset["name"])
        download(asset["browser_download_url"], f, asset["size"], sha)
        os.makedirs(d, exist_ok=True)
        if asset["name"].endswith(".zip"):
            with zipfile.ZipFile(f) as z:
                z.extractall(d)
            os.remove(f)
        elif asset["name"].endswith((".tar.gz", ".tgz")):
            with tarfile.open(f) as t:
                t.extractall(d)
            os.remove(f)
        else:
            shutil.move(f, os.path.join(d, asset["name"]))
            exe_rel = asset["name"]
    if not exe_rel:
        exe_rel = find_exe(d, eng["exe"])
        if not exe_rel:
            warn(eng["exe"] + " not found after unpacking"); return False
    # executable bits (zip files do not keep them)
    for dp, dn, fn in os.walk(d):
        for n in fn:
            p = os.path.join(dp, n)
            if n.startswith(("llama-", "sd-", "koboldcpp")) or n.endswith(".so") or ".so." in n or n == "ggml-rpc-server":
                try: os.chmod(p, 0o755)
                except Exception: pass
    STATE["engines"][skey] = {"version": rel["tag_name"], "repo": repo, "exe": exe_rel.replace("\\", "/")}
    ok("%s %s ready" % (eng["name"], flavor))
    return True

# ------------------------------------------------------------------ catalog / state
def load_catalog():
    local = os.path.join(HERE, "catalog.json")
    if ARGS.catalog:
        return json.load(open(ARGS.catalog))
    cat = json.load(open(local)) if os.path.exists(local) else None
    if not ARGS.offline:
        try:
            remote = http_json(REPO_RAW + "/installer/catalog.json", timeout=20)
            if remote.get("models") and (not cat or str(remote.get("updated")) >= str(cat.get("updated"))):
                cat = remote
                try: json.dump(remote, open(local, "w"), indent=1)
                except Exception: pass
                say("  model list: online version " + str(remote.get("updated")), "d")
        except Exception:
            say("  model list: using the copy on this drive (offline)", "d")
    if not cat:
        fail("catalog.json not found and the online copy could not be downloaded.")
    return cat

def norm(p): return (p or "").replace("\\", "/")
def load_state():
    p = os.path.join(ROOT, "system", "installed.json")
    if os.path.exists(p):
        try:
            s = json.load(open(p, encoding="utf-8-sig"))
            s.setdefault("engines", {}); s.setdefault("models", []); s.setdefault("components", [])
            if isinstance(s["models"], dict): s["models"] = [s["models"]]
            return s
        except Exception as e:
            warn("could not read system/installed.json: %s" % e)
    return {"version": VERSION, "engines": {}, "models": [], "components": []}

def save_state():
    STATE["version"] = VERSION
    os.makedirs(os.path.join(ROOT, "system"), exist_ok=True)
    json.dump(STATE, open(os.path.join(ROOT, "system", "installed.json"), "w", encoding="utf-8"), indent=1)

def find_model(mid): return next((m for m in ALL_MODELS if m["id"] == mid), None)
def installed(mid): return next((m for m in STATE["models"] if m["id"] == mid), None)
def model_folder(m): return {"chat": "models/text", "image": "models/image", "voice": "models/tts"}.get(m["type"], "models")
def model_path(m, v): return model_folder(m) + "/" + v["file"].split("/")[-1]
def hf_url(v): return v.get("url") or "https://huggingface.co/%s/resolve/main/%s" % (v["repo"], v["file"])
def win_path(p): return p.replace("/", "\\")

# ------------------------------------------------------------------ HF browse / import
def browse_hf():
    head("Trending GGUF models on Hugging Face (not tested by this project)")
    try:
        lst = http_json(CAT["hf_browse"]["url"], 30)
    except Exception:
        warn("Hugging Face is not reachable right now."); return
    lst = [m for m in lst if not re.search(r"mmproj|embed|reranker|tts|whisper|asr|vae|image|diffusion|wan|video", m["id"], re.I)]
    for i, m in enumerate(lst):
        say("  [%2d] %s   (%s downloads)" % (i + 1, m["id"], "{:,}".format(m.get("downloads", 0))))
    a = ask("Number to look inside (Enter = back):")
    if not a.isdigit() or not 1 <= int(a) <= len(lst): return
    repo = lst[int(a) - 1]["id"]
    try:
        tree = http_json("https://huggingface.co/api/models/%s/tree/main?recursive=true" % repo, 30)
    except Exception:
        warn("could not read that repository"); return
    files = [f for f in tree if f.get("type") == "file" and f["path"].endswith(".gguf") and f.get("lfs")
             and not re.search(r"mmproj|mtp|imatrix|-0000\d-of-|BF16|F16|F32|bf16|f16|f32", f["path"])]
    files.sort(key=lambda f: -f["lfs"]["size"])
    if not files:
        warn("no single-file GGUF found there"); return
    fake = {"type": "chat"}
    for i, f in enumerate(files):
        say("  [%2d] %-4s %9s  %s" % (i + 1, rate(HW, fake, f["lfs"]["size"]), fmt(f["lfs"]["size"]), f["path"]))
    a = ask("Pick a file number (Enter = back):")
    if not a.isdigit() or not 1 <= int(a) <= len(files): return
    f = files[int(a) - 1]
    name = os.path.splitext(f["path"].split("/")[-1])[0]
    m = {"id": "hf-" + safe_name(name).lower(), "name": name, "type": "chat", "group": "Chat - added from Hugging Face",
         "about": "from huggingface.co/" + repo, "sampling": {}, "custom": True,
         "variants": [{"label": "custom", "repo": repo, "file": f["path"], "size": f["lfs"]["size"], "sha256": f["lfs"]["oid"]}]}
    ALL_MODELS.append(m); PICKED.add(m["id"]); ok(name + " added to your selection")

def import_local():
    src = ask("Folder with .gguf chat models to add (Enter = back):").strip('"').strip("'")
    if not src: return
    src = os.path.expanduser(src)
    if not os.path.isdir(src):
        warn("folder not found"); return
    files = [f for f in sorted(os.listdir(src)) if f.endswith(".gguf") and not re.search(r"mmproj|mtp", f)]
    if not files:
        warn("no .gguf files there"); return
    for fn in files:
        full = os.path.join(src, fn)
        if not ask_yes("  add %s (%s)?" % (fn, fmt(os.path.getsize(full))), True):
            continue
        target = os.path.join(ROOT, "models", "text", fn)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if os.path.abspath(full) != os.path.abspath(target):
            try:
                os.rename(full, target)
            except OSError:
                say("  copying...", "d"); shutil.copyfile(full, target)
        name = os.path.splitext(fn)[0]
        mid = "local-" + safe_name(name).lower()
        STATE["models"] = [m for m in STATE["models"] if m["id"] != mid]
        STATE["models"].append({"id": mid, "name": name, "type": "chat", "path": "models/text/" + fn,
                                "size": os.path.getsize(target), "label": "local", "custom": True, "sampling": {}})
        ok(name + " added")
    save_state()

# ------------------------------------------------------------------ selection UI
def show_menu(show_all):
    global MENU
    MENU = {}
    i = 0
    groups = []
    for m in ALL_MODELS:
        if m["group"] not in groups: groups.append(m["group"])
    for g in groups:
        say(""); say("  " + g, "c")
        for m in [x for x in ALL_MODELS if x["group"] == g]:
            v, r = pick_variant(HW, m)
            inst = installed(m["id"])
            if r == "NO" and not show_all and not inst:
                continue
            i += 1; MENU[i] = m["id"]
            tag = {"GPU": "GPU ", "MIX": "GPU+", "NO": "BIG "}[r]
            if HW["vram"] <= 0 and r == "MIX": tag = "CPU "
            size = v["size"] + sum(pick_component(HW, CAT["components"][d])["size"] for d in m.get("deps", []))
            state = ""
            if inst:
                state = " [installed %s]" % inst.get("label", "")
                if m["id"] in REMOVING: state = " [will be REMOVED]"
            col = "g" if r == "GPU" else ("d" if r == "NO" else "")
            say(" %s[%2d] %s %-40s %-8s %8s%s" % ("*" if m["id"] in PICKED else " ", i, tag, m["name"], v["label"], fmt(size), state), col)
            say("               " + m.get("about", ""), "d")
    for m in [x for x in STATE["models"] if x.get("custom")]:
        i += 1; MENU[i] = m["id"]
        state = " [will be REMOVED]" if m["id"] in REMOVING else " [installed]"
        say("   [%2d] YOURS %-40s %8s%s" % (i, m["name"], fmt(m.get("size", 0)), state))
    say("")
    say("  GPU  = runs fully on your graphics card (fast)", "g")
    say("  GPU+ = runs, part of it in system RAM (slower).  CPU = no usable GPU, runs on the processor.")
    if not show_all:
        say("  Models too big for this PC are hidden - type A to show them.", "d")

def parse_numbers(tok):
    m = re.match(r"^(\d+)-(\d+)$", tok)
    if m: return list(range(int(m.group(1)), int(m.group(2)) + 1))
    return [int(tok)] if tok.isdigit() else []

def select_interactive():
    show_all = False
    rec = CAT["recommended"]["gpu"] if HW["vram"] >= 4 else CAT["recommended"]["cpu"]
    while True:
        head("Pick your models")
        show_menu(show_all)
        say("")
        say("  Type numbers to pick/unpick (e.g. 1,4,9 or 2-5).  R = recommended for this PC", "w")
        say("  -N removes an installed model (e.g. -3).  A = show all   H = browse Hugging Face", "w")
        say("  I = add .gguf files you already have     D = done, start downloading     Q = quit", "w")
        a = ask(">")
        low = a.lower()
        if low == "q": sys.exit(0)
        if low == "d": return
        if low == "": continue
        if low == "a": show_all = not show_all; continue
        if low == "h": browse_hf(); continue
        if low == "i": import_local(); continue
        if low == "r":
            for mid in rec:
                m = find_model(mid)
                if m and pick_variant(HW, m)[1] != "NO" and not installed(mid): PICKED.add(mid)
            continue
        for tok in re.split(r"[,\s]+", a):
            if re.match(r"^-\d+$", tok):
                mid = MENU.get(int(tok[1:]))
                if mid and installed(mid):
                    REMOVING.symmetric_difference_update({mid})
                continue
            for n in parse_numbers(tok):
                mid = MENU.get(n)
                if not mid or installed(mid): continue
                PICKED.symmetric_difference_update({mid})

# ------------------------------------------------------------------ context tuning
def llama_flavor():
    for f in (["cuda"] if HW["backend"] == "cuda" else []) + (["vulkan"] if HW["vulkan"] else []) + ["cpu"]:
        if STATE["engines"].get("linux-llama-" + f):
            return f
    return None

def fit(exe, model, extra):
    env = dict(os.environ, LD_LIBRARY_PATH=os.path.dirname(exe) + ":" + os.environ.get("LD_LIBRARY_PATH", ""))
    try:
        p = subprocess.run([exe, "-m", model, "-np", "1", "-ctk", "q8_0", "-ctv", "q8_0", "--fit-ctx", "8192"] + extra,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=300, env=env)
    except Exception:
        return None
    if p.returncode != 0: return None
    m = None
    for line in p.stdout.splitlines():
        mm = re.match(r"^-c (\d+) -ngl (-?\d+)", line)
        if mm: m = mm
    return {"ctx": int(m.group(1)), "ngl": int(m.group(2))} if m else None

def tune_chat(entry):
    fl = llama_flavor()
    if not fl: return
    e = STATE["engines"]["linux-llama-" + fl]
    exe = os.path.join(ROOT, "runtimes", "linux", "llama-" + fl, os.path.dirname(e["exe"]), "llama-fit-params")
    if not os.path.exists(exe): return
    model = os.path.join(ROOT, norm(entry["path"]))
    extra = ["--device", "none"] if fl == "cpu" else []
    auto = fit(exe, model, extra)
    a = auto["ctx"] if auto else 0
    mx = None
    for c in (0, 229376, 196608, 163840, 131072, 98304, 65536, 49152, 32768):
        if c and c <= a: break
        mx = fit(exe, model, ["-c", str(c)] + extra)
        if mx: break
    t = {"pc": socket.gethostname(), "auto_ctx": auto["ctx"] if auto else 0, "auto_ngl": auto["ngl"] if auto else 0,
         "max_ctx": mx["ctx"] if mx else 0, "max_ngl": mx["ngl"] if mx else 0}
    entry["tuned"] = t
    ok("%s: fast = %s tokens%s" % (entry["name"], t["auto_ctx"] or "auto", ("  |  max context = %d tokens" % t["max_ctx"]) if mx else ""))

# ------------------------------------------------------------------ launchers (Linux)
def write_text(path, text, exe=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="\n") as f:
        f.write(text)
    if exe:
        try: os.chmod(path, 0o755)
        except Exception: pass

def write_settings():
    p = os.path.join(ROOT, "system", "settings.conf")
    if os.path.exists(p): return
    host, key = "127.0.0.1", ""
    lan = ARGS.lan
    if not lan and INTERACTIVE:
        lan = "yes" if ask_yes("Let phones / other PCs on your network use the chat server (needs an API key)?", False) else "no"
    if lan == "yes":
        host = "0.0.0.0"
        key = "sk-local-" + "".join(random.choice(string.ascii_lowercase + string.digits) for _ in range(24))
    write_text(p, """# Portable AI settings (Linux). Setup never overwrites this file.
# AI_HOST=127.0.0.1 -> only this PC; 0.0.0.0 -> other devices too (use an API key)
AI_HOST="%s"
AI_PORT=8080
AI_API_KEY="%s"
AI_IMAGE_PORT=7860
AI_VOICE_PORT=5001
# auto | cuda | vulkan | cpu
AI_BACKEND=auto
""" % (host, key))

def eng_path(skey, dirname):
    e = STATE["engines"].get(skey)
    return ("runtimes/linux/%s/%s" % (dirname, e["exe"])) if e else ""

def write_launchers():
    sysd = os.path.join(ROOT, "system")
    chat = [m for m in STATE["models"] if m["type"] == "chat"]
    img = [m for m in STATE["models"] if m["type"] == "image"]
    voi = [m for m in STATE["models"] if m["type"] == "voice"]
    P = {k: eng_path("linux-" + k, k if not k.startswith("kobold") else "kobold") for k in
         ("llama-cuda", "llama-vulkan", "llama-cpu", "sd-vulkan", "sd-cpu", "kobold-cuda", "kobold-cpu", "kobold-vulkan")}
    env = r'''# Generated by Portable AI Drive setup - edit settings.conf instead.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
. "$ROOT/system/settings.conf"
have_vk() { ldconfig -p 2>/dev/null | grep -q libvulkan.so.1; }
AI_GPU="$AI_BACKEND"
if [ "$AI_GPU" = "auto" ]; then
  AI_GPU=cpu
  have_vk && AI_GPU=vulkan
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1 && AI_GPU=cuda
fi
pick() { for f in "$@"; do [ -n "$f" ] && [ -f "$ROOT/$f" ] && { echo "$ROOT/$f"; return; }; done; echo ""; }
LLAMA_EXTRA=""; SD_EXTRA=""; KCPP_GPU="--usecpu"; KCPP_TTSGPU=""
case "$AI_GPU" in
  cuda)   LLAMA_EXE=$(pick "{{llama-cuda}}" "{{llama-vulkan}}" "{{llama-cpu}}")
          SD_EXE=$(pick "{{sd-vulkan}}" "{{sd-cpu}}")
          KCPP_EXE=$(pick "{{kobold-cuda}}" "{{kobold-cpu}}")
          [ "$KCPP_EXE" = "$ROOT/{{kobold-cuda}}" ] && KCPP_GPU="--usecuda" || KCPP_GPU="--usevulkan"
          KCPP_TTSGPU="--ttsgpu" ;;
  vulkan) LLAMA_EXE=$(pick "{{llama-vulkan}}" "{{llama-cpu}}")
          SD_EXE=$(pick "{{sd-vulkan}}" "{{sd-cpu}}")
          KCPP_EXE=$(pick "{{kobold-cpu}}"); KCPP_GPU="--usevulkan"; KCPP_TTSGPU="--ttsgpu" ;;
  *)      LLAMA_EXE=$(pick "{{llama-cpu}}" "{{llama-vulkan}}"); LLAMA_EXTRA="--device none"
          SD_EXE=$(pick "{{sd-cpu}}" "{{sd-vulkan}}"); SD_EXTRA="--backend cpu"
          KCPP_EXE=$(pick "{{kobold-cpu}}") ;;
esac
libdir() { [ -n "$1" ] && export LD_LIBRARY_PATH="$(dirname "$1"):${LD_LIBRARY_PATH:-}"; }
wait_open() {  # port health-path open-path [chat-model]
  local i
  for i in $(seq 1 600); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1$2" 2>/dev/null)" = "200" ] && break
    sleep 1
  done
  if [ -n "$4" ]; then
    local auth=(); [ -n "$AI_API_KEY" ] && auth=(-H "Authorization: Bearer $AI_API_KEY")
    curl -s -o /dev/null "${auth[@]}" -H "Content-Type: application/json" -d "{\"model\":\"$4\"}" "http://127.0.0.1:$1/models/load"
  fi
  (xdg-open "http://localhost:$1$3" || sensible-browser "http://localhost:$1$3") >/dev/null 2>&1 &
}
'''
    for k, v in P.items():
        env = env.replace("{{%s}}" % k, v)
    write_text(os.path.join(sysd, "env.sh"), env)
    write_text(os.path.join(sysd, "chat.sh"), r'''#!/usr/bin/env bash
# Usage: chat.sh [model-name]   (names are the [sections] in system/models.ini)
. "$(dirname "$0")/env.sh"
[ -z "$LLAMA_EXE" ] && { echo "[!] Chat engine missing - run ./setup.sh again."; exit 1; }
libdir "$LLAMA_EXE"
KEYARG=(); [ -n "$AI_API_KEY" ] && KEYARG=(--api-key "$AI_API_KEY")
echo
echo " Chat server starting   engine: $AI_GPU"
echo " Web page : http://localhost:$AI_PORT"
echo " API      : http://THIS-PC-IP:$AI_PORT/v1   (OpenAI-compatible)"
[ -n "$AI_API_KEY" ] && echo " API key  : $AI_API_KEY"
echo " Press Ctrl+C to stop."
echo
wait_open "$AI_PORT" /health / "$1" &
exec "$LLAMA_EXE" --models-preset system/models.ini --models-max 1 --host "$AI_HOST" --port "$AI_PORT" "${KEYARG[@]}" $LLAMA_EXTRA
''', True)
    write_text(os.path.join(sysd, "stop-all.sh"), r'''#!/usr/bin/env bash
# Stops every chat, image and voice server started from this drive.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pkill -f "$ROOT/runtimes/" && echo "stopped" || echo "nothing was running"
''', True)
    # models.ini
    ini = ["; Generated by Portable AI Drive setup. Re-run setup to regenerate.",
           "; <name> = context sized to stay on the graphics card (fast)",
           "; <name>-MaxContext = largest context that fit on the PC setup ran on (slower)",
           "version = 1", "", "[*]", "parallel = 1", "cache-type-k = q8_0", "cache-type-v = q8_0", "fit-ctx = 8192"]
    for m in chat:
        sec = safe_name(m["name"])
        body = ["model = " + norm(m["path"])] + ["%s = %s" % (k, v) for k, v in (m.get("sampling") or {}).items()]
        ini += ["", "[%s]" % sec] + body
        t = m.get("tuned") or {}
        if t.get("max_ctx", 0) > t.get("auto_ctx", 0):
            ini += ["", "[%s-MaxContext]" % sec] + body + ["c = %d" % t["max_ctx"]]
    write_text(os.path.join(sysd, "models.ini"), "\n".join(ini) + "\n")
    for m in img:
        d = m.get("deps") or {}
        write_text(os.path.join(sysd, "image-%s.sh" % m["id"]), r'''#!/usr/bin/env bash
. "$(dirname "$0")/env.sh"
for f in "{{DM}}" "{{VAE}}" "{{TE}}"; do [ -f "$f" ] || { echo "[!] Missing $f - run ./setup.sh again."; exit 1; }; done
[ -z "$SD_EXE" ] && { echo "[!] Image engine missing - run ./setup.sh again."; exit 1; }
libdir "$SD_EXE"
echo " {{NAME}} starting (first load from the drive can take a few minutes)"
echo " Web page : http://localhost:$AI_IMAGE_PORT     Ctrl+C to stop."
wait_open "$AI_IMAGE_PORT" / / &
exec "$SD_EXE" --diffusion-model "{{DM}}" --vae "{{VAE}}" --llm "{{TE}}" --offload-to-cpu --fa --vae-tiling {{ARGS}} -W 1024 -H 1024 --listen-ip 127.0.0.1 --listen-port "$AI_IMAGE_PORT" $SD_EXTRA
'''.replace("{{DM}}", norm(m["path"])).replace("{{VAE}}", norm(d.get("vae"))).replace("{{TE}}", norm(d.get("te")))
           .replace("{{ARGS}}", m.get("sd_args") or "").replace("{{NAME}}", m["name"]), True)
    for m in voi:
        d = m.get("deps") or {}
        hint = {"custom": "Pick a voice (Aiden, Serena, Ryan, Vivian...) in the TTS tab.",
                "design": "Describe the voice in square brackets first, e.g. [A calm older man] Hello there."}.get(
                    m.get("voice_mode"), "Type your text in the TTS tab and press Generate.")
        write_text(os.path.join(sysd, "voice-%s.sh" % m["id"]), r'''#!/usr/bin/env bash
. "$(dirname "$0")/env.sh"
for f in "{{TTS}}" "{{TOK}}"; do [ -f "$f" ] || { echo "[!] Missing $f - run ./setup.sh again."; exit 1; }; done
[ -z "$KCPP_EXE" ] && { echo "[!] Voice engine missing - run ./setup.sh again."; exit 1; }
echo " {{NAME}} starting"
echo " Web page : http://localhost:$AI_VOICE_PORT/musicui/  (TTS tab)"
echo " {{HINT}}"
echo " Ctrl+C to stop."
wait_open "$AI_VOICE_PORT" /api/extra/version /musicui/ &
exec "$KCPP_EXE" --ttsmodel "{{TTS}}" --ttswavtokenizer "{{TOK}}" $KCPP_TTSGPU $KCPP_GPU --host 127.0.0.1 --port "$AI_VOICE_PORT" --skiplauncher
'''.replace("{{TTS}}", norm(m["path"])).replace("{{TOK}}", norm(d.get("tokenizer"))).replace("{{NAME}}", m["name"]).replace("{{HINT}}", hint), True)
    # start-ai.sh menu
    L = ['#!/usr/bin/env bash', '# Portable AI - Linux menu (generated by setup)', 'cd "$(dirname "$0")"', '. system/env.sh', "trap 'echo' INT   # Ctrl+C stops a server and comes back here", 'while true; do', 'echo', 'echo " =============================================================="', 'echo "   PORTABLE AI                               engine: $AI_GPU"', 'echo " =============================================================="']
    acts = []
    n = 0
    if chat:
        L.append('echo; echo "   CHAT  (opens in your browser at http://localhost:$AI_PORT)"')
        for m in chat:
            n += 1
            ctx = (m.get("tuned") or {}).get("auto_ctx", 0)
            L.append('echo "    %2d  %s%s"' % (n, m["name"].replace('"', ''), ("  %dK ctx" % (ctx // 1024)) if ctx else ""))
            acts.append('  %d) bash system/chat.sh "%s" ;;' % (n, safe_name(m["name"])))
        L.append('echo "     A  All chat models - pick and switch inside the web page"')
        acts.append('  a|A) bash system/chat.sh ;;')
    if img:
        L.append('echo; echo "   IMAGES  (http://localhost:$AI_IMAGE_PORT)"')
        for m in img:
            n += 1; L.append('echo "    %2d  %s"' % (n, m["name"])); acts.append('  %d) bash system/image-%s.sh ;;' % (n, m["id"]))
    if voi:
        L.append('echo; echo "   VOICE  (http://localhost:$AI_VOICE_PORT/musicui/)"')
        for m in voi:
            n += 1; L.append('echo "    %2d  %s"' % (n, m["name"])); acts.append('  %d) bash system/voice-%s.sh ;;' % (n, m["id"]))
    L += ['echo', 'echo "     S  Stop all AI servers     U  Add / remove models     0  Exit"', 'echo',
          'read -r -p "   Type a choice and press Enter: " PICK', 'case "$PICK" in'] + acts + [
          '  s|S) bash system/stop-all.sh ;;', '  u|U) bash ./setup.sh; exec bash "$0" ;;', '  0) exit 0 ;;', '  *) ;;', 'esac', 'done']
    write_text(os.path.join(ROOT, "start-ai.sh"), "\n".join(L) + "\n", True)
    R = ["PORTABLE AI DRIVE", "=================",
         "Windows: double-click START-AI.bat.   Linux: bash start-ai.sh",
         "Run Setup.bat / setup.sh again to add or remove models or update engines.",
         "Made with https://github.com/R00taccess/portable-ai-drive", "", "Installed models:"]
    R += ["  %-6s %s  (%s, %s)" % (m["type"], m["name"], m.get("label", ""), fmt(m.get("size", 0))) for m in STATE["models"]]
    R += ["", "Chat API for other apps: http://<this PC IP>:8080/v1 (OpenAI-compatible)."]
    write_text(os.path.join(ROOT, "README-DRIVE.txt"), "\n".join(R) + "\n")

# ------------------------------------------------------------------ self test
def self_test():
    first = next((m for m in STATE["models"] if m["type"] == "chat"), None)
    fl = llama_flavor()
    if not first or not fl: return
    head("Self-test")
    exe = os.path.join(ROOT, eng_path("linux-llama-" + fl, "llama-" + fl))
    env = dict(os.environ, LD_LIBRARY_PATH=os.path.dirname(exe))
    extra = ["--device", "none"] if fl == "cpu" else []
    log = open(os.path.join(ROOT, "system", "selftest.log"), "w")
    p = subprocess.Popen([exe, "--models-preset", "system/models.ini", "--models-max", "1", "--host", "127.0.0.1", "--port", "8099"] + extra,
                         cwd=ROOT, env=env, stdout=log, stderr=log)
    try:
        for _ in range(60):
            try:
                urllib.request.urlopen("http://127.0.0.1:8099/health", timeout=2); break
            except Exception:
                time.sleep(1)
        body = json.dumps({"model": safe_name(first["name"]), "max_tokens": 40,
                           "messages": [{"role": "user", "content": "In one short sentence: what is the capital of France?"}],
                           "chat_template_kwargs": {"enable_thinking": False}}).encode()
        req = urllib.request.Request("http://127.0.0.1:8099/v1/chat/completions", data=body, headers={"Content-Type": "application/json"})
        r = json.loads(urllib.request.urlopen(req, timeout=900).read())
        ok("%s answered: %s  (%.1f tokens/s)" % (first["name"], r["choices"][0]["message"]["content"].strip(), r.get("timings", {}).get("predicted_per_second", 0)))
    except Exception as e:
        warn("self-test failed: %s - see system/selftest.log" % e)
    finally:
        p.terminate()
        try: p.wait(10)
        except Exception: p.kill()
        subprocess.call(["pkill", "-f", os.path.join(ROOT, "runtimes") + "/"], stderr=subprocess.DEVNULL)

# ================================================================== main
def main():
    global ARGS, INTERACTIVE, ROOT, HW, CAT, ALL_MODELS, STATE, PICKED, REMOVING, MENU
    ap = argparse.ArgumentParser(description="Portable AI Drive setup (Linux)")
    ap.add_argument("--dest", default="", help="install folder (default: the folder setup.sh is in)")
    ap.add_argument("--models", default="", help='non-interactive: comma list of model ids, or "recommended"')
    ap.add_argument("--remove", default="", help="non-interactive: comma list of installed ids to remove")
    ap.add_argument("--yes", action="store_true", help="do not ask for confirmation")
    ap.add_argument("--all-engines", action="store_true", help="also install CUDA builds on non-NVIDIA PCs")
    ap.add_argument("--update-engines", action="store_true")
    ap.add_argument("--no-tune", action="store_true", help="skip the context-size measurement")
    ap.add_argument("--offline", action="store_true", help="do not fetch the online model list")
    ap.add_argument("--skip-verify", action="store_true", help="skip SHA-256 checks")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--catalog", default="")
    ap.add_argument("--lan", default="", choices=["", "yes", "no"])
    ARGS = ap.parse_args()
    INTERACTIVE = not ARGS.models and not ARGS.remove
    PICKED, REMOVING, MENU = set(), set(), {}

    say(""); say("  PORTABLE AI DRIVE - setup (Linux)", "c")
    say("  version %s   https://github.com/R00taccess/portable-ai-drive" % VERSION, "d")
    ROOT = os.path.abspath(ARGS.dest or os.path.dirname(HERE))
    for d in ("system", "models/text", "models/image", "models/tts", "runtimes/linux", "output"):
        os.makedirs(os.path.join(ROOT, d), exist_ok=True)

    head("This PC")
    HW = get_hardware()
    say("  System   : " + HW["os"])
    say("  CPU      : %s  (%d threads)" % (HW["cpu"], HW["cores"]))
    say("  RAM      : %s GB  (%s GB free now)" % (HW["ram"], HW["free_ram"]))
    for g in HW["gpus"] or ["none found - models will run on the processor"]:
        say("  GPU      : " + g)
    if HW.get("old_driver"): warn("NVIDIA driver too old for the CUDA engine - using Vulkan/CPU.")
    if not HW["vulkan"]: say("  Vulkan   : not installed (sudo apt install libvulkan1 mesa-vulkan-drivers for AMD/Intel GPUs)", "d")
    say("  Engine   : " + {"cuda": "CUDA (NVIDIA)", "vulkan": "Vulkan", "cpu": "CPU only"}[HW["backend"]], "g")
    free = shutil.disk_usage(ROOT).free
    say("  Install  : %s   (%s free)" % (ROOT, fmt(free)))

    head("Model list")
    CAT = load_catalog()
    ALL_MODELS = list(CAT["models"])
    STATE = load_state()
    say("  %d models in the list, %d already on this drive." % (len(ALL_MODELS), len(STATE["models"])))

    if INTERACTIVE:
        select_interactive()
    else:
        if ARGS.models == "recommended":
            rec = CAT["recommended"]["gpu"] if HW["vram"] >= 4 else CAT["recommended"]["cpu"]
            for mid in rec:
                m = find_model(mid)
                if m and pick_variant(HW, m)[1] != "NO": PICKED.add(mid)
        elif ARGS.models:
            for mid in [x.strip() for x in ARGS.models.split(",") if x.strip()]:
                if find_model(mid): PICKED.add(mid)
                else: warn("unknown model id: " + mid)
        REMOVING.update(x.strip() for x in ARGS.remove.split(",") if x.strip() and installed(x.strip()))

    # ---- plan
    plan, comps = [], {}
    for mid in PICKED:
        m = find_model(mid)
        v, r = pick_variant(HW, m)
        deps = {}
        for d in m.get("deps", []):
            c = CAT["components"][d]
            cv = pick_component(HW, c)
            cp = c["folder"] + "/" + cv["file"].split("/")[-1]
            comps[cp] = {"v": cv, "name": c["name"]}
            key = "vae" if "vae" in d else ("te" if "text-encoder" in d else ("tokenizer" if "tokenizer" in d else d))
            deps[key] = cp
        plan.append({"m": m, "v": v, "r": r, "path": model_path(m, v), "deps": deps})
    total = sum(x["v"]["size"] for x in plan if not os.path.exists(os.path.join(ROOT, x["path"])))
    total += sum(c["v"]["size"] for k, c in comps.items() if not os.path.exists(os.path.join(ROOT, k)))
    types = {m["type"] for m in STATE["models"] if m["id"] not in REMOVING} | {x["m"]["type"] for x in plan}
    llama_fl = ["cpu"] + (["vulkan"] if HW["vulkan"] else []) + (["cuda"] if HW["backend"] == "cuda" or ARGS.all_engines else [])
    sd_fl = ["cpu"] + (["vulkan"] if HW["vulkan"] else [])
    kb_fl = ["cpu"] + (["cuda"] if HW["backend"] == "cuda" or ARGS.all_engines else [])

    head("Plan")
    if not plan and not REMOVING: say("  No new models picked - checking engines and rebuilding the launchers.")
    for x in plan: say("  + %-42s %-8s %9s  -> %s" % (x["m"]["name"], x["v"]["label"], fmt(x["v"]["size"]), x["path"]))
    for k, c in comps.items(): say("  + %-42s %-8s %9s  -> %s" % (c["name"], c["v"]["label"], fmt(c["v"]["size"]), k), "d")
    for mid in REMOVING: say("  - remove " + installed(mid)["name"], "y")
    say("  Model downloads: %s  (+ engines, about 0.1-2 GB)" % fmt(total))
    margin = (3.0 if "cuda" in llama_fl + kb_fl else 0.5) * GiB   # room for the engines
    if total + margin > free: fail("not enough free space: need about %s, have %s. Pick fewer or smaller models." % (fmt(total + margin), fmt(free)))
    if not ask_yes("Start?", True): sys.exit(0)

    # ---- removals
    for mid in list(REMOVING):
        e = installed(mid)
        if e.get("path"):
            f = os.path.join(ROOT, norm(e["path"]))
            if os.path.exists(f): os.remove(f)
        STATE["models"] = [m for m in STATE["models"] if m["id"] != mid]
        for pre, ext in (("image-", ".sh"), ("voice-", ".sh"), ("image-", ".bat"), ("voice-", ".bat")):
            bf = os.path.join(ROOT, "system", pre + mid + ext)
            if os.path.exists(bf): os.remove(bf)
        ok("removed " + e["name"])
    if REMOVING:
        used = {norm(v) for m in STATE["models"] for v in (m.get("deps") or {}).values()} | set(comps)
        for c in STATE.get("components", []):
            if norm(c) not in used:
                f = os.path.join(ROOT, norm(c))
                if os.path.exists(f): os.remove(f); ok("removed helper " + c)
        STATE["components"] = sorted(used)
    save_state()

    # ---- engines
    head("Engines")
    need = (["llama"] if "chat" in types else []) + (["sd"] if "image" in types else []) + (["kobold"] if "voice" in types else [])
    for k in need:
        for f in {"llama": llama_fl, "sd": sd_fl, "kobold": kb_fl}[k]:
            try: install_engine(k, f)
            except Exception as e: warn("%s %s: %s" % (k, f, e))
            save_state()
    dl = os.path.join(ROOT, "runtimes", "_downloads")
    if os.path.isdir(dl) and not any(n.endswith(".part") for n in os.listdir(dl)): shutil.rmtree(dl, ignore_errors=True)

    # ---- models
    if plan: head("Models")
    for k, c in comps.items():
        download(hf_url(c["v"]), os.path.join(ROOT, k), c["v"]["size"], c["v"].get("sha256", ""))
        STATE["components"] = sorted(set(STATE.get("components", [])) | {k})
    for x in plan:
        m, v = x["m"], x["v"]
        download(hf_url(v), os.path.join(ROOT, x["path"]), v["size"], v.get("sha256", ""))
        entry = {"id": m["id"], "name": m["name"], "type": m["type"], "label": v["label"], "path": x["path"], "size": v["size"],
                 "repo": v["repo"], "file": v["file"], "sha256": v.get("sha256", ""), "sampling": m.get("sampling", {}),
                 "sd_args": m.get("sd_args", ""), "voice_mode": m.get("voice_mode", ""), "deps": x["deps"], "custom": bool(m.get("custom"))}
        STATE["models"] = [e for e in STATE["models"] if e["id"] != m["id"]] + [entry]
        save_state()

    # ---- context tuning
    chat = [e for e in STATE["models"] if e["type"] == "chat"]
    if chat and not ARGS.no_tune:
        head("Measuring the best context size for each chat model on this PC")
        new_ids = {x["m"]["id"] for x in plan}
        for e in chat:
            if (e.get("tuned") or {}).get("pc") == socket.gethostname() and e["id"] not in new_ids:
                ok(e["name"] + ": already measured"); continue
            try: tune_chat(e)
            except Exception as ex: warn("%s: %s" % (e["name"], ex))
        save_state()

    missing = [k for k in need if not any(STATE["engines"].get("linux-%s-%s" % (k, f)) for f in ("cpu", "vulkan", "cuda"))]
    for k in missing:
        warn("the %s engine could not be installed - run setup again when GitHub is reachable." % CAT["engines"][k]["name"])
    head("Writing launchers")
    write_settings()
    write_launchers()
    save_state()
    ok("start-ai.sh, system/*.sh, system/models.ini")
    if ARGS.self_test: self_test()
    head("Done")
    say("  Start with:  bash %s" % os.path.join(ROOT, "start-ai.sh"), "g")
    say("  Run ./setup.sh again any time to add or remove models or update the engines.")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        say(""); warn("stopped - run setup again to continue (finished downloads are kept).")
        sys.exit(130)
