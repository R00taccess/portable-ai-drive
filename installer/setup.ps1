<#
  Portable AI Drive - Windows installer
  https://github.com/R00taccess/portable-ai-drive

  Turns a USB drive (or any folder) into a portable local-AI kit:
    1. checks this PC's hardware (GPU, VRAM, RAM, free disk)
    2. shows chat / image / voice models rated for this PC and lets you pick
    3. downloads the matching engines (llama.cpp, stable-diffusion.cpp, KoboldCpp)
       and the models, checking every file's SHA-256
    4. measures the biggest context each chat model can use on this PC
    5. writes START-AI.bat and the start/stop scripts

  Run it again any time to add or remove models or update the engines.
  Usually started through Setup.bat. Plain ASCII on purpose (PowerShell 5.1).
#>
[CmdletBinding()]
param(
    [string]$Dest = "",           # install folder (default: the folder Setup.bat is in)
    [string]$Models = "",         # non-interactive: comma list of model ids, or "recommended"
    [string]$Remove = "",         # non-interactive: comma list of installed ids to remove
    [switch]$Yes,                 # do not ask for confirmation
    [switch]$AllEngines,          # also install NVIDIA (CUDA) engines on non-NVIDIA PCs
    [switch]$UpdateEngines,       # re-download engines even if installed
    [switch]$NoTune,              # skip the context-size measurement
    [switch]$Offline,             # do not fetch the online catalog
    [switch]$SkipVerify,          # skip SHA-256 checks (not recommended)
    [switch]$SelfTest,            # after install, load the first chat model and ask it a question
    [string]$Catalog = "",        # use this catalog file instead
    [string]$Lan = ""             # "yes" / "no" - let other devices use the chat server
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Script:Version   = '1.0.0'
$Script:RepoRaw   = 'https://raw.githubusercontent.com/R00taccess/portable-ai-drive/main'
$Script:UA        = @{ 'User-Agent' = 'portable-ai-drive-setup' }
$Script:Here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:Interactive = [string]::IsNullOrEmpty($Models) -and [string]::IsNullOrEmpty($Remove)

# ---------------------------------------------------------------- helpers
function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Head([string]$t) { Write-Host ''; Write-Host ('== ' + $t + ' ' + ('=' * [Math]::Max(3, 60 - $t.Length))) -ForegroundColor Cyan }
function Warn([string]$t) { Write-Host ('  [!] ' + $t) -ForegroundColor Yellow }
function Ok([string]$t) { Write-Host ('  [ok] ' + $t) -ForegroundColor Green }
function Fail([string]$t) { Write-Host ''; Write-Host ('  ERROR: ' + $t) -ForegroundColor Red; exit 1 }
function Ask([string]$prompt) { Write-Host -NoNewline ($prompt + ' ') -ForegroundColor White; $l = [Console]::In.ReadLine(); if ($null -eq $l) { return '' }; return $l.Trim() }
function AskYes([string]$prompt, [bool]$default = $true) {
    if ($Yes -or -not $Script:Interactive) { return $default }
    $d = 'Y/n'; if (-not $default) { $d = 'y/N' }
    $a = Ask ($prompt + ' [' + $d + ']')
    if ($a -eq '') { return $default }
    return ($a -match '^(y|yes)$')
}
function GB([double]$bytes) { return [Math]::Round($bytes / 1GB, 1) }
function Fmt([double]$bytes) { if ($bytes -ge 1GB) { return ('{0:N1} GB' -f ($bytes / 1GB)) } return ('{0:N0} MB' -f ($bytes / 1MB)) }
function SafeName([string]$s) { return (($s -replace '[\(\)]', '') -replace '[^A-Za-z0-9\.\-]+', '-').Trim('-') }
function WriteText([string]$path, [string]$text) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $t = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
    [IO.File]::WriteAllText($path, $t, [Text.Encoding]::ASCII)
}
function ReadJson([string]$path) { return (Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json) }
function SaveJson($obj, [string]$path) { $j = $obj | ConvertTo-Json -Depth 12; [IO.File]::WriteAllText($path, $j, (New-Object Text.UTF8Encoding($false))) }

# ---------------------------------------------------------------- hardware
function Get-Hardware {
    $hw = [ordered]@{}
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $hw.OS = $os.Caption
    $hw.CPU = ($cpu.Name -replace '\s+', ' ').Trim()
    $hw.Cores = [int]$cpu.NumberOfLogicalProcessors
    $hw.RamGB = [Math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    $hw.FreeRamGB = [Math]::Round(($os.FreePhysicalMemory * 1KB) / 1GB, 1)
    $hw.Gpus = @()
    $hw.VramGB = 0.0
    $hw.Nvidia = $false
    $hw.NvDriver = ''
    $hw.Backend = 'cpu'

    $ErrorActionPreference = 'Continue'
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($smi) {
        try {
            $lines = & $smi.Source --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits 2>$null
            foreach ($l in @($lines)) {
                $p = $l -split ','
                if ($p.Count -ge 3) {
                    $hw.Gpus += ($p[0].Trim() + ' (' + [Math]::Round([double]$p[1] / 1024, 1) + ' GB)')
                    $v = [Math]::Round([double]$p[1] / 1024, 1)
                    if ($v -gt $hw.VramGB) { $hw.VramGB = $v }
                    $hw.NvDriver = $p[2].Trim()
                    $hw.Nvidia = $true
                }
            }
        } catch {}
    }
    # other GPUs (AMD / Intel): name from WMI, dedicated memory from the display driver registry key
    $vc = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    $regMem = @{}
    try {
        Get-ChildItem 'HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.DriverDesc -and $p.'HardwareInformation.qwMemorySize') { $regMem[$p.DriverDesc] = [double]$p.'HardwareInformation.qwMemorySize' }
        }
    } catch {}
    foreach ($g in $vc) {
        $n = [string]$g.Name
        if ($n -match 'NVIDIA' -and $hw.Nvidia) { continue }
        if ($n -match 'Microsoft Basic|Remote Display|Virtual|Parsec|Meta Virtual') { continue }
        $mem = 0.0
        if ($regMem.ContainsKey($n)) { $mem = $regMem[$n] } elseif ($g.AdapterRAM) { $mem = [double]$g.AdapterRAM }
        $gb = [Math]::Round($mem / 1GB, 1)
        $hw.Gpus += ($n + ' (' + $gb + ' GB)')
        if ($hw.Backend -eq 'cpu') { $hw.Backend = 'vulkan' }
        # integrated graphics share system RAM - only count real dedicated memory
        if ($gb -ge 2 -and $n -notmatch 'UHD|Iris|Radeon\(TM\) Graphics|Radeon Graphics|Vega \d+ Graphics' -and $gb -gt $hw.VramGB) { $hw.VramGB = $gb }
    }
    if ($hw.Nvidia) {
        $maj = 0; [void][int]::TryParse(($hw.NvDriver -split '\.')[0], [ref]$maj)
        if ($maj -ge 528) { $hw.Backend = 'cuda' } else { $hw.Backend = 'vulkan'; $hw.OldDriver = $true }
    }
    $hw.HasCurl = [bool](Get-Command curl.exe -ErrorAction SilentlyContinue)
    $hw.HasTar = [bool](Get-Command tar.exe -ErrorAction SilentlyContinue)
    return $hw
}

# ---------------------------------------------------------------- rating
# Budget rules (GB). Kept simple on purpose; llama.cpp's own "fit" does the exact work at launch.
function Rate-Variant($hw, $model, [double]$sizeBytes) {
    $s = $sizeBytes / 1GB
    $v = [double]$hw.VramGB
    $ram = [double]$hw.RamGB
    $gpuFree = $v - 1.2
    $total = $gpuFree + ($ram - 4) * 0.85
    switch ($model.type) {
        'chat' {
            if ($v -gt 0 -and $s + 0.8 -le $gpuFree) { return 'GPU' }
            if ($s + 1.0 -le $total) { return 'MIX' }
            return 'NO'
        }
        'image' {
            if ($v -gt 0 -and $s + 1.5 -le $gpuFree) { return 'GPU' }
            if ($s + 7 -le ($ram - 3)) { return 'MIX' }
            return 'NO'
        }
        'voice' {
            if ($v -gt 0 -and $s + 1.0 -le $gpuFree) { return 'GPU' }
            if ($s + 3 -le $ram) { return 'MIX' }
            return 'NO'
        }
    }
    return 'NO'
}

function Pick-Variant($hw, $model) {
    $vars = @($model.variants)
    $gpu = @($vars | Where-Object { (Rate-Variant $hw $model $_.size) -eq 'GPU' })
    $mix = @($vars | Where-Object { (Rate-Variant $hw $model $_.size) -eq 'MIX' })
    if ($model.type -eq 'chat' -and $model.moe -and $mix.Count -gt 0) {
        # MoE models stay fast when part of them sits in system RAM: take the best that fits overall
        $best = $vars | Where-Object { (Rate-Variant $hw $model $_.size) -ne 'NO' } | Select-Object -First 1
        return @{ v = $best; r = (Rate-Variant $hw $model $best.size) }
    }
    if ($gpu.Count -gt 0) { return @{ v = $gpu[0]; r = 'GPU' } }
    if ($mix.Count -gt 0) {
        # dense model bigger than the graphics card: keep the part that spills to RAM small
        $cap = [Math]::Max(1.5 * [double]$hw.VramGB, 4) * 1GB
        $c = @($mix | Where-Object { $_.size -le $cap })
        if ($c.Count -gt 0) { return @{ v = $c[0]; r = 'MIX' } }
        return @{ v = $mix[-1]; r = 'MIX' }
    }
    return @{ v = $vars[-1]; r = 'NO' }
}

function Pick-Component($hw, $comp) {
    $vars = @($comp.variants)
    if ($vars.Count -eq 1) { return $vars[0] }
    # text encoder: big version only when the card has room for it
    if ([double]$hw.VramGB -ge 12 -and [double]$hw.RamGB -ge 32) { return $vars[0] }
    return $vars[-1]
}

# ---------------------------------------------------------------- downloads
function Download([string]$url, [string]$out, [double]$expectSize = 0, [string]$sha = '') {
    $ErrorActionPreference = 'Continue'
    $dir = Split-Path -Parent $out
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (Test-Path -LiteralPath $out) {
        $len = (Get-Item -LiteralPath $out).Length
        if ($expectSize -le 0 -or $len -eq $expectSize) {
            if ($sha -and -not $SkipVerify) {
                if (Check-Sha $out $sha) { Ok ((Split-Path -Leaf $out) + ' already downloaded'); return }
                Warn ((Split-Path -Leaf $out) + ' is damaged - downloading again'); Remove-Item -LiteralPath $out -Force
            } else { Ok ((Split-Path -Leaf $out) + ' already downloaded'); return }
        } else { Remove-Item -LiteralPath $out -Force }
    }
    $part = $out + '.part'
    for ($try = 1; $try -le 3; $try++) {
        Say ('  downloading ' + (Split-Path -Leaf $out) + $(if ($expectSize -gt 0) { ' (' + (Fmt $expectSize) + ')' } else { '' })) 'White'
        if ($Script:HW.HasCurl) {
            & curl.exe -L --fail --retry 5 --retry-delay 3 --connect-timeout 30 -C - -o $part $url
            $okDl = ($LASTEXITCODE -eq 0)
        } else {
            try { Start-BitsTransfer -Source $url -Destination $part -ErrorAction Stop; $okDl = $true } catch {
                try { Invoke-WebRequest -Uri $url -OutFile $part -UseBasicParsing -Headers $Script:UA; $okDl = $true } catch { $okDl = $false }
            }
        }
        if ($okDl -and (Test-Path -LiteralPath $part)) {
            $len = (Get-Item -LiteralPath $part).Length
            if ($expectSize -gt 0 -and $len -ne $expectSize) { Warn ('size mismatch (' + $len + ' bytes) - retrying'); continue }
            if ($sha -and -not $SkipVerify) {
                Say '  checking SHA-256...' 'DarkGray'
                if (-not (Check-Sha $part $sha)) { Warn 'checksum mismatch - downloading again'; Remove-Item -LiteralPath $part -Force; continue }
            }
            Move-Item -LiteralPath $part -Destination $out -Force
            Ok (Split-Path -Leaf $out)
            return
        }
        Warn ('download interrupted (try ' + $try + ' of 3)')
        Start-Sleep -Seconds 3
    }
    Fail ('could not download ' + $url + '. Run Setup again later - finished files are kept and partial ones resume.')
}
function Check-Sha([string]$path, [string]$sha) {
    $h = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
    return ($h -eq $sha.ToLower())
}
function Extract([string]$zip, [string]$to) {
    $ErrorActionPreference = 'Continue'
    if (-not (Test-Path $to)) { New-Item -ItemType Directory -Force -Path $to | Out-Null }
    if ($Script:HW.HasTar) {
        & tar.exe -xmf $zip -C $to
        if ($LASTEXITCODE -eq 0) { return }
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        foreach ($e in $z.Entries) {
            if ($e.FullName.EndsWith('/')) { continue }
            $target = Join-Path $to $e.FullName
            $d = Split-Path -Parent $target
            if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
        }
    } finally { $z.Dispose() }
}

# ---------------------------------------------------------------- engines
$Script:RelCache = @{}
function Get-Release([string]$repo) {
    if ($Script:RelCache.ContainsKey($repo)) { return $Script:RelCache[$repo] }
    $r = Get-ReleaseRaw $repo
    $Script:RelCache[$repo] = $r
    return $r
}
function Get-ReleaseRaw([string]$repo) {
    try { return Invoke-RestMethod -Uri ('https://api.github.com/repos/' + $repo + '/releases/latest') -Headers $Script:UA -TimeoutSec 60 }
    catch {
        $all = Invoke-RestMethod -Uri ('https://api.github.com/repos/' + $repo + '/releases?per_page=5') -Headers $Script:UA -TimeoutSec 60
        return @($all)[0]
    }
}
function Install-Engine([string]$key, [string]$flavor) {
    $eng = $Script:Cat.engines.$key
    $plat = 'windows-' + $flavor
    $patterns = @($eng.assets.$plat)
    if (-not $patterns -or $patterns.Count -eq 0 -or -not $patterns[0]) { return $false }
    $dirName = $key + '-' + $flavor
    if ($key -eq 'kobold') { $dirName = 'kobold' }
    $dir = Join-Path $Script:Root ('runtimes\' + $dirName)
    $stateKey = $key + '-' + $flavor
    $have = $Script:State.engines.$stateKey
    $repo = $eng.repo
    try { $rel = Get-Release $repo } catch {
        if ($eng.fallback_repo) { Warn ($repo + ' not reachable, using ' + $eng.fallback_repo); $repo = $eng.fallback_repo; $rel = Get-Release $repo } else { throw }
    }
    if ($have -and $have.version -eq $rel.tag_name -and -not $UpdateEngines) {
        $exe = Join-Path $dir ($have.exe)
        if (Test-Path -LiteralPath $exe) { Ok ($eng.name + ' ' + $flavor + ' ' + $rel.tag_name + ' already installed'); return $true }
    }
    Say ('  ' + $eng.name + ' (' + $flavor + ') ' + $rel.tag_name + ' from github.com/' + $repo) 'White'
    $dl = Join-Path $Script:Root 'runtimes\_downloads'
    $exeName = ''
    foreach ($pat in $patterns) {
        $asset = @($rel.assets | Where-Object { $_.name -like $pat }) | Select-Object -First 1
        if (-not $asset) { Warn ('no file matching ' + $pat + ' in ' + $repo + ' ' + $rel.tag_name); return $false }
        $sha = ''
        if ($asset.PSObject.Properties.Name -contains 'digest' -and $asset.digest -like 'sha256:*') { $sha = $asset.digest.Substring(7) }
        $file = Join-Path $dl $asset.name
        Download $asset.browser_download_url $file ([double]$asset.size) $sha
        if ($asset.name -like '*.zip') { Extract $file $dir; Remove-Item -LiteralPath $file -Force }
        else {
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            Move-Item -LiteralPath $file -Destination (Join-Path $dir $asset.name) -Force
            $exeName = $asset.name
        }
    }
    if (-not $exeName) {
        $found = Get-ChildItem -LiteralPath $dir -Recurse -Filter ($eng.exe + '.exe') | Select-Object -First 1
        if (-not $found) { Warn ($eng.exe + '.exe not found after unpacking'); return $false }
        $exeName = $found.FullName.Substring($dir.Length).TrimStart('\')
    }
    $Script:State.engines | Add-Member -NotePropertyName $stateKey -NotePropertyValue ([pscustomobject]@{ version = $rel.tag_name; repo = $repo; exe = $exeName }) -Force
    Ok ($eng.name + ' ' + $flavor + ' ready')
    return $true
}

# ---------------------------------------------------------------- catalog / state
function Load-Catalog {
    $local = Join-Path $Script:Here 'catalog.json'
    if ($Catalog) { return ReadJson $Catalog }
    $cat = $null
    if (Test-Path -LiteralPath $local) { $cat = ReadJson $local }
    if (-not $Offline) {
        try {
            $remote = Invoke-RestMethod -Uri ($Script:RepoRaw + '/installer/catalog.json') -Headers $Script:UA -TimeoutSec 20
            if ($remote.models -and (-not $cat -or [string]$remote.updated -ge [string]$cat.updated)) {
                $cat = $remote
                try { SaveJson $remote $local } catch {}
                Say ('  model list: online version ' + $remote.updated) 'DarkGray'
            }
        } catch { Say '  model list: using the copy on this drive (offline)' 'DarkGray' }
    }
    if (-not $cat) { Fail 'catalog.json not found and the online copy could not be downloaded.' }
    return $cat
}
function Load-State {
    $p = Join-Path $Script:Root 'system\installed.json'
    if (Test-Path -LiteralPath $p) {
        $s = ReadJson $p
        if (-not $s.engines) { $s | Add-Member -NotePropertyName engines -NotePropertyValue ([pscustomobject]@{}) -Force }
        if (-not $s.models) { $s | Add-Member -NotePropertyName models -NotePropertyValue @() -Force }
        $s.models = @($s.models)
        return $s
    }
    return [pscustomobject]@{ version = $Script:Version; engines = [pscustomobject]@{}; models = @() }
}
function Save-State { $Script:State.version = $Script:Version; SaveJson $Script:State (Join-Path $Script:Root 'system\installed.json') }
function Find-Model([string]$id) { return @($Script:AllModels | Where-Object { $_.id -eq $id }) | Select-Object -First 1 }
function Installed([string]$id) { return @($Script:State.models | Where-Object { $_.id -eq $id }) | Select-Object -First 1 }
function Model-Folder($m) { switch ($m.type) { 'chat' { 'models\text' } 'image' { 'models\image' } 'voice' { 'models\tts' } default { 'models' } } }
function Model-Path($m, $v) { return (Join-Path (Model-Folder $m) (Split-Path -Leaf ($v.file -replace '/', '\'))) }
function HF-Url($v) { if ($v.url) { return [string]$v.url }; return ('https://huggingface.co/' + $v.repo + '/resolve/main/' + $v.file) }

# ---------------------------------------------------------------- Hugging Face browse / import
function Browse-HF {
    Head 'Trending GGUF models on Hugging Face (not tested by this project)'
    try { $list = @(Invoke-RestMethod -Uri $Script:Cat.hf_browse.url -Headers $Script:UA -TimeoutSec 30) } catch { Warn 'Hugging Face is not reachable right now.'; return }
    $list = @($list | Where-Object { $_.id -notmatch 'mmproj|embed|reranker|tts|whisper|asr|vae|image|diffusion|wan|video' })
    for ($i = 0; $i -lt $list.Count; $i++) { Say ('  [{0,2}] {1}   ({2:N0} downloads)' -f ($i + 1), $list[$i].id, [double]$list[$i].downloads) }
    $a = Ask 'Number to look inside (Enter = back):'
    $n = 0; if (-not [int]::TryParse($a, [ref]$n) -or $n -lt 1 -or $n -gt $list.Count) { return }
    $repo = $list[$n - 1].id
    try { $tree = @(Invoke-RestMethod -Uri ('https://huggingface.co/api/models/' + $repo + '/tree/main?recursive=true') -Headers $Script:UA -TimeoutSec 30) } catch { Warn 'could not read that repository'; return }
    $files = @($tree | Where-Object { $_.type -eq 'file' -and $_.path -like '*.gguf' -and $_.path -notmatch 'mmproj|mtp|MTP|imatrix|-0000[2-9]-of-|BF16|F16|F32|bf16|f16|f32' -and $_.lfs } | Sort-Object { $_.lfs.size } -Descending)
    $files = @($files | Where-Object { $_.path -notmatch '-00001-of-' })
    if ($files.Count -eq 0) { Warn 'no single-file GGUF found there'; return }
    $fake = [pscustomobject]@{ type = 'chat'; moe = $false }
    for ($i = 0; $i -lt $files.Count; $i++) {
        $r = Rate-Variant $Script:HW $fake ([double]$files[$i].lfs.size)
        Say ('  [{0,2}] {1,-4} {2,9}  {3}' -f ($i + 1), $r, (Fmt $files[$i].lfs.size), $files[$i].path)
    }
    $a = Ask 'Pick a file number (Enter = back):'
    if (-not [int]::TryParse($a, [ref]$n) -or $n -lt 1 -or $n -gt $files.Count) { return }
    $f = $files[$n - 1]
    $name = [IO.Path]::GetFileNameWithoutExtension(($f.path -split '/')[-1])
    $m = [pscustomobject]@{
        id = ('hf-' + (SafeName $name).ToLower()); name = $name; type = 'chat'; group = 'Chat - added from Hugging Face'
        about = ('from huggingface.co/' + $repo); sampling = [pscustomobject]@{}; custom = $true
        variants = @([pscustomobject]@{ label = 'custom'; repo = $repo; file = $f.path; size = [double]$f.lfs.size; sha256 = $f.lfs.oid })
    }
    $Script:AllModels += $m
    $Script:Picked[$m.id] = $true
    Ok ($name + ' added to your selection')
}
function Import-Local {
    $src = Ask 'Folder with .gguf chat models to add (Enter = back):'
    if (-not $src) { return }
    $src = $src.Trim('"')
    if (-not (Test-Path -LiteralPath $src)) { Warn 'folder not found'; return }
    $files = @(Get-ChildItem -LiteralPath $src -Filter *.gguf -File | Where-Object { $_.Name -notmatch 'mmproj|mtp' })
    if ($files.Count -eq 0) { Warn 'no .gguf files there'; return }
    foreach ($f in $files) {
        if (-not (AskYes ('  add ' + $f.Name + ' (' + (Fmt $f.Length) + ')?') $true)) { continue }
        $target = Join-Path $Script:Root ('models\text\' + $f.Name)
        if ($f.FullName -ne $target) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            if ((Split-Path -Qualifier $f.FullName) -eq (Split-Path -Qualifier $target)) { Move-Item -LiteralPath $f.FullName -Destination $target -Force }
            else { Say '  copying...' 'DarkGray'; Copy-Item -LiteralPath $f.FullName -Destination $target -Force }
        }
        $name = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $id = 'local-' + (SafeName $name).ToLower()
        $Script:State.models = @($Script:State.models | Where-Object { $_.id -ne $id })
        $Script:State.models += [pscustomobject]@{ id = $id; name = $name; type = 'chat'; path = ('models\text\' + $f.Name); size = [double]$f.Length; label = 'local'; custom = $true; sampling = [pscustomobject]@{} }
        Ok ($name + ' added')
    }
    Save-State
}

# ---------------------------------------------------------------- selection UI
function Show-Menu([bool]$showAll) {
    $Script:MenuMap = @{}
    $i = 0
    $groups = @($Script:AllModels | ForEach-Object { $_.group } | Select-Object -Unique)
    foreach ($g in $groups) {
        Say ''; Say ('  ' + $g) 'Cyan'
        foreach ($m in @($Script:AllModels | Where-Object { $_.group -eq $g })) {
            $p = Pick-Variant $Script:HW $m
            $inst = Installed $m.id
            if ($p.r -eq 'NO' -and -not $showAll -and -not $inst) { continue }
            $i++
            $Script:MenuMap[$i] = $m.id
            $mark = ' '
            if ($Script:Picked.ContainsKey($m.id)) { $mark = '*' }
            $tag = switch ($p.r) { 'GPU' { 'GPU ' } 'MIX' { 'GPU+' } default { 'BIG ' } }
            if ($Script:HW.VramGB -le 0 -and $p.r -eq 'MIX') { $tag = 'CPU ' }
            $size = [double]$p.v.size
            if ($m.deps) { foreach ($d in @($m.deps)) { $size += [double](Pick-Component $Script:HW $Script:Cat.components.$d).size } }
            $state = ''
            if ($inst) { $state = ' [installed ' + $inst.label + ']'; if ($Script:Removing.ContainsKey($m.id)) { $state = ' [will be REMOVED]' } }
            $color = 'Gray'; if ($p.r -eq 'GPU') { $color = 'Green' } elseif ($p.r -eq 'NO') { $color = 'DarkGray' }
            Say ('  {0}[{1,2}] {2} {3,-40} {4,-8} {5,8}{6}' -f $mark, $i, $tag, $m.name, $p.v.label, (Fmt $size), $state) $color
            Say ('               ' + $m.about) 'DarkGray'
        }
    }
    foreach ($m in @($Script:State.models | Where-Object { $_.custom })) {
        $i++; $Script:MenuMap[$i] = $m.id
        $state = ' [installed]'; if ($Script:Removing.ContainsKey($m.id)) { $state = ' [will be REMOVED]' }
        Say ('   [{0,2}] YOURS {1,-40} {2,8}{3}' -f $i, $m.name, (Fmt $m.size), $state)
    }
    Say ''
    Say '  GPU  = runs fully on your graphics card (fast)' 'Green'
    Say '  GPU+ = runs, part of it in system RAM (slower).  CPU = no usable GPU, runs on the processor.' 'Gray'
    if (-not $showAll) { Say '  Models too big for this PC are hidden - type A to show them.' 'DarkGray' }
}
function Parse-Numbers([string]$s) {
    $out = @()
    foreach ($tok in ($s -split '[,\s]+')) {
        if ($tok -match '^(\d+)-(\d+)$') { $out += ([int]$matches[1]..[int]$matches[2]) }
        elseif ($tok -match '^\d+$') { $out += [int]$tok }
    }
    return $out
}
function Select-Interactive {
    $showAll = $false
    $rec = @($Script:Cat.recommended.gpu); if ($Script:HW.VramGB -lt 4) { $rec = @($Script:Cat.recommended.cpu) }
    while ($true) {
        Head 'Pick your models'
        Show-Menu $showAll
        Say ''
        Say '  Type numbers to pick/unpick (e.g. 1,4,9 or 2-5).  R = recommended for this PC' 'White'
        Say '  -N removes an installed model (e.g. -3).  A = show all   H = browse Hugging Face' 'White'
        Say '  I = add .gguf files you already have     D = done, start downloading     Q = quit' 'White'
        $a = Ask '>'
        switch -Regex ($a) {
            '^[qQ]$' { exit 0 }
            '^[dD]$' { return }
            '^$' { continue }
            '^[aA]$' { $showAll = -not $showAll; continue }
            '^[hH]$' { Browse-HF; continue }
            '^[iI]$' { Import-Local; continue }
            '^[rR]$' {
                foreach ($id in $rec) { $m = Find-Model $id; if ($m -and (Pick-Variant $Script:HW $m).r -ne 'NO' -and -not (Installed $id)) { $Script:Picked[$id] = $true } }
                continue
            }
            default {
                foreach ($tok in ($a -split '[,\s]+')) {
                    if ($tok -match '^-(\d+)$') {
                        $id = $Script:MenuMap[[int]$matches[1]]
                        if ($id -and (Installed $id)) { if ($Script:Removing.ContainsKey($id)) { $Script:Removing.Remove($id) } else { $Script:Removing[$id] = $true } }
                        continue
                    }
                    foreach ($n in (Parse-Numbers $tok)) {
                        $id = $Script:MenuMap[$n]
                        if (-not $id) { continue }
                        if (Installed $id) { continue }
                        if ($Script:Picked.ContainsKey($id)) { $Script:Picked.Remove($id) } else { $Script:Picked[$id] = $true }
                    }
                }
            }
        }
    }
}

# ---------------------------------------------------------------- context tuning
function Invoke-Fit([string]$exe, [string]$model, [string[]]$extra) {
    $ErrorActionPreference = 'Continue'
    $args2 = @('-m', $model, '-np', '1', '-ctk', 'q8_0', '-ctv', 'q8_0', '--fit-ctx', '8192') + $extra
    $out = & $exe @args2 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $line = @($out | Where-Object { $_ -match '^-c \d+' }) | Select-Object -Last 1
    if ($line -match '^-c (\d+) -ngl (-?\d+)') { return @{ ctx = [int]$matches[1]; ngl = [int]$matches[2] } }
    return $null
}
function Tune-Chat($entry) {
    $flavor = 'vulkan'; if ($Script:HW.Backend -eq 'cuda' -and $Script:State.engines.'llama-cuda') { $flavor = 'cuda' }
    $e = $Script:State.engines.('llama-' + $flavor)
    if (-not $e) { return }
    $dir = Join-Path $Script:Root ('runtimes\llama-' + $flavor)
    $exe = Join-Path (Split-Path -Parent (Join-Path $dir $e.exe)) 'llama-fit-params.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return }
    $model = Join-Path $Script:Root (WinP $entry.path)
    $cpuArgs = @(); if ($Script:HW.Backend -eq 'cpu') { $cpuArgs = @('--device', 'none') }
    $auto = Invoke-Fit $exe $model $cpuArgs
    $a = 0; if ($auto) { $a = $auto.ctx }
    $max = $null
    foreach ($c in @(0, 229376, 196608, 163840, 131072, 98304, 65536, 49152, 32768)) {
        if ($c -gt 0 -and $c -le $a) { break }
        $max = Invoke-Fit $exe $model (@('-c', "$c") + $cpuArgs)
        if ($max) { break }
    }
    $t = [pscustomobject]@{ pc = $env:COMPUTERNAME; auto_ctx = 0; auto_ngl = 0; max_ctx = 0; max_ngl = 0 }
    if ($auto) { $t.auto_ctx = $auto.ctx; $t.auto_ngl = $auto.ngl }
    if ($max) { $t.max_ctx = $max.ctx; $t.max_ngl = $max.ngl }
    $entry | Add-Member -NotePropertyName tuned -NotePropertyValue $t -Force
    $msg = $entry.name + ': '
    if ($auto) { $msg += ('fast = ' + $auto.ctx + ' tokens') } else { $msg += 'fast = auto' }
    if ($max) { $msg += ('  |  max context = ' + $max.ctx + ' tokens') }
    Ok $msg
}

# ---------------------------------------------------------------- launcher generation (Windows)
function WinP([string]$p) { return ($p -replace '/', '\') }
function BatSafe([string]$s) { return (($s -replace '&', 'and') -replace '[%!<>|^"]', '') }

function Write-Settings {
    $p = Join-Path $Script:Root 'system\settings.bat'
    if (Test-Path -LiteralPath $p) { return }   # keep the user's own edits
    $hostv = '127.0.0.1'; $key = ''
    $lanAns = $Lan
    if (-not $lanAns -and $Script:Interactive) {
        if (AskYes 'Let phones / other PCs on your network use the chat server (needs an API key)?' $false) { $lanAns = 'yes' } else { $lanAns = 'no' }
    }
    if ($lanAns -eq 'yes') {
        $hostv = '0.0.0.0'
        $key = 'sk-local-' + (-join ((48..57) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ }))
    }
    $t = @'
@rem ================================================================
@rem  Portable AI settings - open with Notepad to change them.
@rem  (Setup never overwrites this file.)
@rem ================================================================

@rem --- Chat server -------------------------------------------------
@rem  AI_HOST=127.0.0.1  only this PC can connect
@rem  AI_HOST=0.0.0.0    other devices on your network can connect too
set "AI_HOST={{HOST}}"
set "AI_PORT=8080"

@rem  API key for the chat server. Empty = no key (fine for 127.0.0.1).
@rem  Use a key whenever AI_HOST is 0.0.0.0.
set "AI_API_KEY={{KEY}}"

@rem --- Image and voice servers (this PC only) ----------------------
set "AI_IMAGE_PORT=7860"
set "AI_VOICE_PORT=5001"

@rem --- Engine ------------------------------------------------------
@rem  auto   = NVIDIA GPU -> CUDA build (if installed), otherwise Vulkan
@rem  cuda / vulkan / cpu = force one
set "AI_BACKEND=auto"
'@
    WriteText $p (($t.Replace('{{HOST}}', $hostv)).Replace('{{KEY}}', $key))
}

function Engine-Exe([string]$stateKey, [string]$dirName) {
    $e = $Script:State.engines.$stateKey
    if (-not $e) { return '' }
    return ('runtimes\' + $dirName + '\' + $e.exe)
}

function Write-Launchers {
    $sys = Join-Path $Script:Root 'system'
    $chat = @($Script:State.models | Where-Object { $_.type -eq 'chat' })
    $img = @($Script:State.models | Where-Object { $_.type -eq 'image' })
    $voi = @($Script:State.models | Where-Object { $_.type -eq 'voice' })

    # ---- env.bat: picks the engine build at launch time (the drive moves between PCs)
    $lc = Engine-Exe 'llama-cuda' 'llama-cuda'; $lv = Engine-Exe 'llama-vulkan' 'llama-vulkan'
    $sc = Engine-Exe 'sd-cuda' 'sd-cuda'; $sv = Engine-Exe 'sd-vulkan' 'sd-vulkan'
    $kc = Engine-Exe 'kobold-cuda' 'kobold'; $kv = Engine-Exe 'kobold-vulkan' 'kobold'
    $env = @'
@rem Generated by Portable AI Drive setup - edit settings.bat instead of this file.
@rem Expects the current folder to be the drive root.
call "%~dp0settings.bat"
set "AI_GPU=%AI_BACKEND%"
if /i "%AI_GPU%"=="auto" (
    set "AI_GPU=vulkan"
    where nvidia-smi >nul 2>&1 && set "AI_GPU=cuda"
)
set "LLAMA_EXE={{LV}}"
set "SD_EXE={{SV}}"
set "KCPP_EXE={{KV}}"
set "KCPP_GPU=--usevulkan"
set "KCPP_TTSGPU=--ttsgpu"
set "LLAMA_EXTRA="
set "SD_EXTRA="
if /i "%AI_GPU%"=="cuda" (
    if not "{{LC}}"=="" if exist "{{LC}}" set "LLAMA_EXE={{LC}}"
    if not "{{SC}}"=="" if exist "{{SC}}" set "SD_EXE={{SC}}"
    if not "{{KC}}"=="" if exist "{{KC}}" set "KCPP_EXE={{KC}}"
    if not "{{KC}}"=="" if exist "{{KC}}" set "KCPP_GPU=--usecuda"
)
if /i "%AI_GPU%"=="cpu" (
    set "LLAMA_EXTRA=--device none"
    set "SD_EXTRA=--backend cpu"
    set "KCPP_GPU=--usecpu"
    set "KCPP_TTSGPU="
)
'@
    $env = $env.Replace('{{LV}}', $lv).Replace('{{LC}}', $lc).Replace('{{SV}}', $sv).Replace('{{SC}}', $sc).Replace('{{KV}}', $kv).Replace('{{KC}}', $kc)
    WriteText (Join-Path $sys 'env.bat') $env

    # ---- wait-open.bat
    WriteText (Join-Path $sys 'wait-open.bat') @'
@echo off
rem Usage: wait-open.bat PORT HEALTH-PATH OPEN-PATH [CHAT-MODEL]
rem Waits (up to ~10 min) for a local server, optionally loads a chat model, opens the browser.
set "P=%~1"
set "HP=%~2"
set "OP=%~3"
set "M=%~4"
for /l %%i in (1,1,600) do (
    curl -s -o nul -w "%%{http_code}" "http://127.0.0.1:%P%%HP%" 2>nul | findstr /b "200" >nul && goto ready
    ping -n 2 127.0.0.1 >nul
)
exit /b 1
:ready
if "%M%"=="" goto open
set "AUTH="
if defined AI_API_KEY set "AUTH=--oauth2-bearer %AI_API_KEY%"
curl -s -o nul %AUTH% -H "Content-Type: application/json" -d "{\"model\":\"%M%\"}" "http://127.0.0.1:%P%/models/load"
:open
start "" "http://localhost:%P%%OP%"
exit /b 0
'@

    # ---- chat.bat (llama.cpp router: every chat model in models.ini, one loaded at a time)
    WriteText (Join-Path $sys 'chat.bat') @'
@echo off
setlocal EnableExtensions
rem Usage: chat.bat [model-name]   (names are the [sections] in system\models.ini)
pushd "%~dp0.."
call system\env.bat
title Portable AI - Chat server   (close this window to stop it)
if not exist "%LLAMA_EXE%" (
    echo [!] Chat engine missing: %LLAMA_EXE%  - run Setup.bat again.
    pause
    exit /b 1
)
set "KEYARG="
if defined AI_API_KEY set "KEYARG=--api-key %AI_API_KEY%"
echo.
echo  Chat server starting   engine: %AI_GPU%
echo  Web page : http://localhost:%AI_PORT%
echo  API      : http://THIS-PC-IP:%AI_PORT%/v1   (OpenAI-compatible)
if defined AI_API_KEY echo  API key  : %AI_API_KEY%   (the web page asks for it once)
if not "%~1"=="" echo  Loading  : %~1   (big models take a minute from a USB drive)
echo  Close this window to stop the server.
echo.
start "" /b cmd /c call system\wait-open.bat %AI_PORT% /health / %1
"%LLAMA_EXE%" --models-preset system\models.ini --models-max 1 --host %AI_HOST% --port %AI_PORT% %KEYARG% %LLAMA_EXTRA%
echo.
echo  Chat server stopped. If that was not you, read the messages above.
pause
'@

    # ---- stop-all.bat
    WriteText (Join-Path $sys 'stop-all.bat') @'
@echo off
rem Stops every chat, image and voice server started from this drive.
taskkill /f /im llama-server.exe >nul 2>&1
taskkill /f /im sd-server.exe >nul 2>&1
taskkill /f /im koboldcpp.exe >nul 2>&1
taskkill /f /im koboldcpp-nocuda.exe >nul 2>&1
'@

    # ---- models.ini for the chat router
    $ini = @()
    $ini += '; Generated by Portable AI Drive setup. Re-run Setup.bat to regenerate.'
    $ini += '; Each [section] is one chat model; the name is what you pick in the web page'
    $ini += '; or send as "model" from apps. Paths are relative to the drive root.'
    $ini += ';   <name>             context sized so the model stays on the graphics card (fast)'
    $ini += ';   <name>-MaxContext  the largest context that fit on the PC setup ran on (slower)'
    $ini += 'version = 1'
    $ini += ''
    $ini += '[*]'
    $ini += 'parallel = 1'
    $ini += 'cache-type-k = q8_0'
    $ini += 'cache-type-v = q8_0'
    $ini += 'fit-ctx = 8192'
    foreach ($m in $chat) {
        $sec = SafeName $m.name
        $body = @('model = ' + ($m.path -replace '\\', '/'))
        if ($m.sampling) { foreach ($pr in $m.sampling.PSObject.Properties) { $body += ($pr.Name + ' = ' + $pr.Value) } }
        $ini += ''; $ini += ('[' + $sec + ']'); $ini += $body
        if ($m.tuned -and [int]$m.tuned.max_ctx -gt 0 -and [int]$m.tuned.max_ctx -gt [int]$m.tuned.auto_ctx) {
            $ini += ''; $ini += ('[' + $sec + '-MaxContext]'); $ini += $body; $ini += ('c = ' + $m.tuned.max_ctx)
        }
    }
    WriteText (Join-Path $sys 'models.ini') (($ini -join "`n") + "`n")

    # ---- one launcher per image / voice model
    foreach ($m in $img) {
        $t = @'
@echo off
setlocal EnableExtensions
pushd "%~dp0.."
call system\env.bat
title Portable AI - {{NAME}}   (close this window to stop it)
set "MISSING="
for %%F in ("{{DM}}" "{{VAE}}" "{{TE}}" "%SD_EXE%") do if not exist "%%~F" (
    echo [!] Missing: %%~F
    set "MISSING=1"
)
if defined MISSING (
    echo  Run Setup.bat again to repair the drive.
    pause
    exit /b 1
)
echo.
echo  {{NAME}} starting   engine: %AI_GPU%
echo  First load from the drive can take a few minutes.
echo  Web page : http://localhost:%AI_IMAGE_PORT%
echo  Close this window to stop the server.
echo.
start "" /b cmd /c call system\wait-open.bat %AI_IMAGE_PORT% / /
"%SD_EXE%" --diffusion-model "{{DM}}" --vae "{{VAE}}" --llm "{{TE}}" --offload-to-cpu --fa --vae-tiling {{ARGS}} -W 1024 -H 1024 --listen-ip 127.0.0.1 --listen-port %AI_IMAGE_PORT% %SD_EXTRA%
echo.
echo  Image server stopped. If that was not you, read the messages above.
pause
'@
        $t = $t.Replace('{{NAME}}', (BatSafe $m.name)).Replace('{{DM}}', (WinP $m.path)).Replace('{{VAE}}', (WinP $m.deps.vae)).Replace('{{TE}}', (WinP $m.deps.te)).Replace('{{ARGS}}', [string]$m.sd_args)
        WriteText (Join-Path $sys ('image-' + $m.id + '.bat')) $t
    }
    foreach ($m in $voi) {
        $hint = 'Type your text in the TTS tab and press Generate.'
        if ($m.voice_mode -eq 'design') { $hint = 'Describe the voice in square brackets first, e.g. [A calm older man] Hello there.' }
        if ($m.voice_mode -eq 'custom') { $hint = 'Pick a voice (Aiden, Serena, Ryan, Vivian...) in the TTS tab.' }
        $t = @'
@echo off
setlocal EnableExtensions
pushd "%~dp0.."
call system\env.bat
title Portable AI - {{NAME}}   (close this window to stop it)
set "MISSING="
for %%F in ("{{TTS}}" "{{TOK}}" "%KCPP_EXE%") do if not exist "%%~F" (
    echo [!] Missing: %%~F
    set "MISSING=1"
)
if defined MISSING (
    echo  Run Setup.bat again to repair the drive.
    pause
    exit /b 1
)
echo.
echo  {{NAME}} starting   engine: %AI_GPU%
echo  Web page : http://localhost:%AI_VOICE_PORT%/musicui/   (TTS tab)
echo  {{HINT}}
echo  Close this window to stop the server.
echo.
start "" /b cmd /c call system\wait-open.bat %AI_VOICE_PORT% /api/extra/version /musicui/
"%KCPP_EXE%" --ttsmodel "{{TTS}}" --ttswavtokenizer "{{TOK}}" %KCPP_TTSGPU% %KCPP_GPU% --host 127.0.0.1 --port %AI_VOICE_PORT% --skiplauncher
echo.
echo  Voice server stopped. If that was not you, read the messages above.
pause
'@
        $t = $t.Replace('{{NAME}}', (BatSafe $m.name)).Replace('{{TTS}}', (WinP $m.path)).Replace('{{TOK}}', (WinP $m.deps.tokenizer)).Replace('{{HINT}}', $hint)
        WriteText (Join-Path $sys ('voice-' + $m.id + '.bat')) $t
    }

    # ---- START-AI.bat (menu)
    $L = @()
    $L += '@echo off'
    $L += 'setlocal EnableExtensions'
    $L += 'title Portable AI'
    $L += 'pushd "%~dp0"'
    $L += 'call system\env.bat'
    $L += ':menu'
    $L += 'cls'
    $L += 'echo.'
    $L += 'echo  =============================================================='
    $L += 'echo    PORTABLE AI                   drive %~d0    engine: %AI_GPU%'
    $L += 'echo  =============================================================='
    $act = @()
    $n = 0
    if ($chat.Count -gt 0) {
        $L += 'echo.'
        $L += 'echo    CHAT  (opens in your browser at http://localhost:%AI_PORT%)'
        foreach ($m in $chat) {
            $n++
            $nm = BatSafe $m.name
            $extra = ''
            if ($m.tuned -and [int]$m.tuned.auto_ctx -gt 0) { $extra = ('  ' + [int]([int]$m.tuned.auto_ctx / 1024) + 'K ctx') }
            $L += ('echo     {0,2}  {1}{2}' -f $n, $nm, $extra)
            $act += ('if "%PICK%"=="' + $n + '" start "Chat - ' + $nm + '" cmd /c system\chat.bat ' + (SafeName $m.name))
        }
        $L += 'echo      A  All chat models - pick and switch inside the web page'
        $act += 'if /i "%PICK%"=="A" start "Chat - all models" cmd /c system\chat.bat'
    }
    if ($img.Count -gt 0) {
        $L += 'echo.'
        $L += 'echo    IMAGES  (http://localhost:%AI_IMAGE_PORT%)'
        foreach ($m in $img) {
            $n++; $nm = BatSafe $m.name
            $L += ('echo     {0,2}  {1}' -f $n, $nm)
            $act += ('if "%PICK%"=="' + $n + '" start "Images - ' + $nm + '" cmd /c system\image-' + $m.id + '.bat')
        }
    }
    if ($voi.Count -gt 0) {
        $L += 'echo.'
        $L += 'echo    VOICE  (http://localhost:%AI_VOICE_PORT%/musicui/)'
        foreach ($m in $voi) {
            $n++; $nm = BatSafe $m.name
            $L += ('echo     {0,2}  {1}' -f $n, $nm)
            $act += ('if "%PICK%"=="' + $n + '" start "Voice - ' + $nm + '" cmd /c system\voice-' + $m.id + '.bat')
        }
    }
    $L += 'echo.'
    $L += 'echo      S  Stop all AI servers     U  Add / remove models     0  Exit'
    $L += 'echo.'
    $L += 'echo    Run one model at a time unless your graphics card is large.'
    $L += 'echo.'
    $L += 'set "PICK="'
    $L += 'set /p "PICK=   Type a choice and press Enter: "'
    $L += $act
    $L += 'if /i "%PICK%"=="S" call system\stop-all.bat'
    $L += 'if /i "%PICK%"=="U" (start "" "%~dp0Setup.bat" & exit /b 0)'
    $L += 'if "%PICK%"=="0" goto end'
    $L += 'goto menu'
    $L += ':end'
    $L += 'popd'
    WriteText (Join-Path $Script:Root 'START-AI.bat') (($L -join "`n") + "`n")

    # ---- a short note on the drive
    $R = @()
    $R += 'PORTABLE AI DRIVE'
    $R += '================='
    $R += 'Double-click START-AI.bat. Run Setup.bat to add or remove models or update engines.'
    $R += 'Made with https://github.com/R00taccess/portable-ai-drive'
    $R += ''
    $R += 'Installed models:'
    foreach ($m in $Script:State.models) { $R += ('  ' + $m.type.PadRight(6) + ' ' + $m.name + '  (' + $m.label + ', ' + (Fmt $m.size) + ')') }
    $R += ''
    $R += 'Chat API for other apps: http://<this PC IP>:8080/v1 (OpenAI-compatible).'
    $R += 'Settings (port, API key, network access): system\settings.bat'
    $R += 'Per-model context and sampling: system\models.ini'
    WriteText (Join-Path $Script:Root 'README-DRIVE.txt') (($R -join "`n") + "`n")
}

# ---------------------------------------------------------------- self test
function Run-SelfTest {
    $first = @($Script:State.models | Where-Object { $_.type -eq 'chat' }) | Select-Object -First 1
    if (-not $first) { return }
    Head 'Self-test'
    $flavor = 'vulkan'; if ($Script:HW.Backend -eq 'cuda' -and $Script:State.engines.'llama-cuda') { $flavor = 'cuda' }
    $exe = Join-Path $Script:Root (Engine-Exe ('llama-' + $flavor) ('llama-' + $flavor))
    $ini = Join-Path $Script:Root 'system\models.ini'
    $log = Join-Path $Script:Root 'system\selftest.log'
    $extra = @(); if ($Script:HW.Backend -eq 'cpu') { $extra = @('--device', 'none') }
    Push-Location $Script:Root
    $p = Start-Process -FilePath $exe -ArgumentList (@('--models-preset', $ini, '--models-max', '1', '--host', '127.0.0.1', '--port', '8099') + $extra) -RedirectStandardError $log -RedirectStandardOutput ($log + '.out') -PassThru -WindowStyle Hidden
    Pop-Location
    try {
        $up = $false
        for ($i = 0; $i -lt 60; $i++) { try { Invoke-RestMethod -Uri 'http://127.0.0.1:8099/health' -TimeoutSec 2 | Out-Null; $up = $true; break } catch { Start-Sleep 1 } }
        if (-not $up) { Warn 'chat server did not start - see system\selftest.log'; return }
        $body = @{ model = (SafeName $first.name); max_tokens = 40; messages = @(@{ role = 'user'; content = 'In one short sentence: what is the capital of France?' }); chat_template_kwargs = @{ enable_thinking = $false } } | ConvertTo-Json -Depth 5
        $r = Invoke-RestMethod -Uri 'http://127.0.0.1:8099/v1/chat/completions' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 900
        Ok ($first.name + ' answered: ' + $r.choices[0].message.content.Trim() + '  (' + [Math]::Round($r.timings.predicted_per_second, 1) + ' tokens/s)')
    } catch { Warn ('self-test failed: ' + $_.Exception.Message + ' - see system\selftest.log') }
    finally { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Get-Process llama-server -ErrorAction SilentlyContinue | Where-Object { $_.Path -like ($Script:Root + '*') } | Stop-Process -Force -ErrorAction SilentlyContinue } catch {} }
}

# ================================================================= main
try { if ($Script:Interactive) { Clear-Host } } catch {}
Say ''
Say '  PORTABLE AI DRIVE - setup' 'Cyan'
Say ('  version ' + $Script:Version + '   https://github.com/R00taccess/portable-ai-drive') 'DarkGray'

# ---- where to install
if ($Dest) { $Script:Root = $Dest } else { $Script:Root = Split-Path -Parent $Script:Here }
if (-not (Test-Path -LiteralPath $Script:Root)) { New-Item -ItemType Directory -Force -Path $Script:Root | Out-Null }
$Script:Root = (Resolve-Path -LiteralPath $Script:Root).Path.TrimEnd('\')
if ($Script:Root.Length -eq 2) { $Script:Root += '\' }
foreach ($d in @('system', 'models\text', 'models\image', 'models\tts', 'runtimes', 'output')) { New-Item -ItemType Directory -Force -Path (Join-Path $Script:Root $d) | Out-Null }
try { Get-ChildItem -LiteralPath $Script:Here -File | Unblock-File -ErrorAction SilentlyContinue } catch {}

# ---- hardware
Head 'This PC'
$Script:HW = Get-Hardware
Say ('  System   : ' + $Script:HW.OS)
Say ('  CPU      : ' + $Script:HW.CPU + '  (' + $Script:HW.Cores + ' threads)')
Say ('  RAM      : ' + $Script:HW.RamGB + ' GB  (' + $Script:HW.FreeRamGB + ' GB free now)')
if ($Script:HW.Gpus.Count -gt 0) { foreach ($g in $Script:HW.Gpus) { Say ('  GPU      : ' + $g) } } else { Say '  GPU      : none found - models will run on the processor' }
if ($Script:HW.Nvidia) { Say ('  NVIDIA driver ' + $Script:HW.NvDriver) }
if ($Script:HW.OldDriver) { Warn 'NVIDIA driver is too old for the CUDA engine - using Vulkan. Update the driver for more speed.' }
$engName = switch ($Script:HW.Backend) { 'cuda' { 'CUDA (NVIDIA)' } 'vulkan' { 'Vulkan (AMD / Intel / NVIDIA)' } default { 'CPU only' } }
Say ('  Engine   : ' + $engName) 'Green'
$freeBytes = 0
try { $freeBytes = (New-Object IO.DriveInfo((Split-Path -Qualifier $Script:Root))).AvailableFreeSpace } catch {}
Say ('  Install  : ' + $Script:Root + $(if ($freeBytes) { '   (' + (Fmt $freeBytes) + ' free)' } else { '' }))
if (-not $Script:HW.HasCurl) { Warn 'curl.exe not found (Windows 10 1803 or newer has it) - using slower built-in downloads.' }

# ---- catalog + state
Head 'Model list'
$Script:Cat = Load-Catalog
$Script:AllModels = @($Script:Cat.models)
$Script:State = Load-State
$Script:Picked = @{}
$Script:Removing = @{}
Say ('  ' + $Script:AllModels.Count + ' models in the list, ' + @($Script:State.models).Count + ' already on this drive.')

if ($Script:Interactive) {
    Select-Interactive
} else {
    if ($Models -eq 'recommended') {
        $rec = @($Script:Cat.recommended.gpu); if ($Script:HW.VramGB -lt 4) { $rec = @($Script:Cat.recommended.cpu) }
        foreach ($id in $rec) { $m = Find-Model $id; if ($m -and (Pick-Variant $Script:HW $m).r -ne 'NO') { $Script:Picked[$id] = $true } }
    } elseif ($Models) {
        foreach ($id in ($Models -split ',')) { $id = $id.Trim(); if (-not $id) { continue }; if (Find-Model $id) { $Script:Picked[$id] = $true } else { Warn ('unknown model id: ' + $id) } }
    }
    foreach ($id in ($Remove -split ',')) { $id = $id.Trim(); if ($id -and (Installed $id)) { $Script:Removing[$id] = $true } }
}

# ---- plan
$plan = @()        # models to download
$compPlan = @{}    # components (shared helper files) to download
foreach ($id in @($Script:Picked.Keys)) {
    $m = Find-Model $id
    $p = Pick-Variant $Script:HW $m
    $deps = [ordered]@{}
    if ($m.deps) {
        foreach ($d in @($m.deps)) {
            $c = $Script:Cat.components.$d
            $cv = Pick-Component $Script:HW $c
            $cpath = Join-Path $c.folder ($cv.file -split '/')[-1]
            $cpath = $cpath -replace '/', '\'
            $compPlan[$cpath] = @{ v = $cv; name = $c.name; id = $d }
            switch -Wildcard ($d) { '*vae*' { $deps.vae = $cpath } '*text-encoder*' { $deps.te = $cpath } '*tokenizer*' { $deps.tokenizer = $cpath } }
        }
    }
    $plan += [pscustomobject]@{ m = $m; v = $p.v; r = $p.r; path = (Model-Path $m $p.v); deps = [pscustomobject]$deps }
}
$total = 0.0
foreach ($x in $plan) { if (-not (Test-Path -LiteralPath (Join-Path $Script:Root $x.path))) { $total += [double]$x.v.size } }
foreach ($k in $compPlan.Keys) { if (-not (Test-Path -LiteralPath (Join-Path $Script:Root $k))) { $total += [double]$compPlan[$k].v.size } }

$types = @{}
foreach ($x in @($Script:State.models) + @($plan | ForEach-Object { $_.m })) { if ($x -and -not $Script:Removing.ContainsKey($x.id)) { $types[$x.type] = $true } }
$flavors = @('vulkan'); if ($Script:HW.Backend -eq 'cuda' -or $AllEngines) { $flavors = @('cuda', 'vulkan') }

Head 'Plan'
if ($plan.Count -eq 0 -and $Script:Removing.Count -eq 0) { Say '  No new models picked - checking engines and rebuilding the launchers.' }
foreach ($x in $plan) { Say ('  + {0,-42} {1,-8} {2,9}  -> {3}' -f $x.m.name, $x.v.label, (Fmt $x.v.size), $x.path) }
foreach ($k in $compPlan.Keys) { Say ('  + {0,-42} {1,-8} {2,9}  -> {3}' -f $compPlan[$k].name, $compPlan[$k].v.label, (Fmt $compPlan[$k].v.size), $k) 'DarkGray' }
foreach ($id in $Script:Removing.Keys) { Say ('  - remove ' + (Installed $id).name) 'Yellow' }
$eList = @(); if ($types.chat) { $eList += 'chat (llama.cpp)' }; if ($types.image) { $eList += 'image (stable-diffusion.cpp)' }; if ($types.voice) { $eList += 'voice (KoboldCpp)' }
if ($eList.Count) { Say ('  Engines: ' + ($eList -join ', ') + '  [' + ($flavors -join ' + ') + ' builds]') }
Say ('  Model downloads: ' + (Fmt $total) + '  (+ engines, about 0.1-2 GB)')
$margin = 0.6GB; if ($flavors -contains 'cuda') { $margin = 3.5GB }   # room for the engines
if ($freeBytes -and $total + $margin -gt $freeBytes) { Fail ('not enough free space: need about ' + (Fmt ($total + $margin)) + ', have ' + (Fmt $freeBytes) + '. Pick fewer or smaller models.') }
if (-not (AskYes 'Start?' $true)) { exit 0 }

# ---- removals
foreach ($id in @($Script:Removing.Keys)) {
    $e = Installed $id
    if ($e.path) { $f = Join-Path $Script:Root $e.path; if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
    $Script:State.models = @($Script:State.models | Where-Object { $_.id -ne $id })
    foreach ($b in @('image-', 'voice-')) { $bf = Join-Path $Script:Root ('system\' + $b + $id + '.bat'); if (Test-Path -LiteralPath $bf) { Remove-Item -LiteralPath $bf -Force } }
    Ok ('removed ' + $e.name)
}
# helper files no installed model uses any more
if ($Script:Removing.Count -gt 0) {
    $used = @{}
    foreach ($m in @($Script:State.models)) { if ($m.deps) { foreach ($pr in $m.deps.PSObject.Properties) { $used[$pr.Value] = $true } } }
    foreach ($k in $compPlan.Keys) { $used[$k] = $true }
    foreach ($c in @($Script:State.components)) { if ($c -and -not $used[$c]) { $f = Join-Path $Script:Root $c; if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force; Ok ('removed helper ' + $c) } } }
    $Script:State | Add-Member -NotePropertyName components -NotePropertyValue @($used.Keys) -Force
}
Save-State

# ---- engines
Head 'Engines'
$needEng = @()
if ($types.chat) { $needEng += 'llama' }; if ($types.image) { $needEng += 'sd' }; if ($types.voice) { $needEng += 'kobold' }
foreach ($k in $needEng) {
    foreach ($f in $flavors) {
        try { [void](Install-Engine $k $f) } catch { Warn ($k + ' ' + $f + ': ' + $_.Exception.Message) }
        Save-State
    }
}
$dlDir = Join-Path $Script:Root 'runtimes\_downloads'
if ((Test-Path $dlDir) -and -not (Get-ChildItem -LiteralPath $dlDir -Filter *.part -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $dlDir -Recurse -Force -ErrorAction SilentlyContinue }

# ---- models
if ($plan.Count -gt 0) { Head 'Models' }
foreach ($k in $compPlan.Keys) {
    $c = $compPlan[$k]
    Download (HF-Url $c.v) (Join-Path $Script:Root $k) ([double]$c.v.size) ([string]$c.v.sha256)
    $comps = @($Script:State.components) + @($k) | Where-Object { $_ } | Select-Object -Unique
    $Script:State | Add-Member -NotePropertyName components -NotePropertyValue @($comps) -Force
}
foreach ($x in $plan) {
    Download (HF-Url $x.v) (Join-Path $Script:Root $x.path) ([double]$x.v.size) ([string]$x.v.sha256)
    $entry = [pscustomobject]@{
        id = $x.m.id; name = $x.m.name; type = $x.m.type; label = $x.v.label; path = $x.path; size = [double]$x.v.size
        repo = $x.v.repo; file = $x.v.file; sha256 = $x.v.sha256; sampling = $x.m.sampling; sd_args = $x.m.sd_args
        voice_mode = $x.m.voice_mode; deps = $x.deps; custom = [bool]$x.m.custom
    }
    $Script:State.models = @($Script:State.models | Where-Object { $_.id -ne $x.m.id }) + @($entry)
    Save-State
}

# ---- context tuning
$chatEntries = @($Script:State.models | Where-Object { $_.type -eq 'chat' })
if ($chatEntries.Count -gt 0 -and -not $NoTune) {
    Head 'Measuring the best context size for each chat model on this PC'
    foreach ($e in $chatEntries) {
        if ($e.tuned -and $e.tuned.pc -eq $env:COMPUTERNAME -and -not ($plan | Where-Object { $_.m.id -eq $e.id })) { Ok ($e.name + ': already measured'); continue }
        try { Tune-Chat $e } catch { Warn ($e.name + ': ' + $_.Exception.Message) }
    }
    Save-State
}

foreach ($k in $needEng) {
    $any = $false
    foreach ($f in @('cuda', 'vulkan')) { if ($Script:State.engines.($k + '-' + $f)) { $any = $true } }
    if (-not $any) { Warn ('the ' + $Script:Cat.engines.$k.name + ' engine could not be installed - run Setup again when GitHub is reachable.') }
}

# ---- launchers
Head 'Writing launchers'
Write-Settings
Write-Launchers
Save-State
Ok 'START-AI.bat, system\*.bat, system\models.ini'

if ($SelfTest) { Run-SelfTest }

Head 'Done'
Say ('  Open ' + (Join-Path $Script:Root 'START-AI.bat') + ' to start chatting.') 'Green'
Say '  Run Setup.bat again any time to add or remove models or update the engines.'
