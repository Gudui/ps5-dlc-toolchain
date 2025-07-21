Add-Type -AssemblyName System.Windows.Forms
$workspace = '.\workspace'
# ── generic Open-File dialog ──────────────────────────────────────────────────
function Invoke-OpenDialog {
    param(
        [string] $Title  = 'Select file(s)',
        [string] $Filter = 'All files (*.*)|*.*',
        [switch] $Multiselect
    )

    $dlg                 = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title           = $Title
    $dlg.Filter          = $Filter
    $dlg.Multiselect     = $Multiselect.IsPresent
    $dlg.CheckFileExists = $true

    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return ,$dlg.FileNames          # always an array
    }
    throw 'Selection cancelled - script aborted.'
}

# ── bundle selector with confirmation loop ───────────────────────────────────
function Select-PkgBundle {
    do {
        # 1. mandatory single-file selections
        $patch = (Invoke-OpenDialog -Title 'Select the *patch* PKG' -Filter 'PKG packages (*.pkg)|*.pkg')[0]
        $base  = (Invoke-OpenDialog -Title 'Select the *base*  PKG' -Filter 'PKG packages (*.pkg)|*.pkg')[0]

        # 2. DLC(s) – allow multi-select
        $dlcs  =  Invoke-OpenDialog -Title 'Select DLC PKG file(s)' -Filter 'PKG packages (*.pkg)|*.pkg' -Multiselect

        # 3. visual feedback in console
        Write-Host "`n================ CURRENT SELECTION ================"
        Write-Host ('PATCH : {0}' -f $patch) -ForegroundColor Yellow
        Write-Host ('BASE  : {0}' -f $base)  -ForegroundColor Green
        Write-Host 'DLCS  :'                    -ForegroundColor Cyan
        $dlcs | ForEach-Object { Write-Host ('  {0}' -f $_) -ForegroundColor Cyan }
        Write-Host '===================================================='

        # 4. summarise in a modal Yes/No dialog
        $msg =  "Patch : $patch`nBase  : $base`n`nDLC:`n" + ($dlcs -join "`n")
        $ans = [System.Windows.Forms.MessageBox]::Show(
                  $msg,
                  'Confirm that these are PATCH / BASE / DLC',
                  [System.Windows.Forms.MessageBoxButtons]::YesNo,
                  [System.Windows.Forms.MessageBoxIcon]::Question)

    } until ($ans -eq [System.Windows.Forms.DialogResult]::Yes)

    [pscustomobject]@{
        Patch = $patch
        Base  = $base
        DLCs  = $dlcs
    }
}


function Get-OrbisPkgInfo {
    <#
        .SYNOPSIS
            Parse the text produced by `orbis-pub-cmd.exe img_info`
            into a *case-insensitive*, nested hashtable.

        .OUTPUTS
            [hashtable] whose keys (both section names and field names)
            are handled by StringComparer::OrdinalIgnoreCase, so
            $info['Params']['title id'] works no matter the capitalisation
            or stray spaces in the original output.

        .NOTES
            • Immune to BOMs, tabs, non-breaking spaces, colour codes.  
            • Works on Windows PowerShell 5.1 (no -LiteralPath, no ArgumentList).  
            • No external dependencies; only core .NET types.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PkgPath,
        [string]$CmdPath = '.\helpers\orbis-pub-cmd.exe'   # may be overridden
    )

    # -- 1 Resolve paths ----------------------------------------------------
    $pkgFile = (Resolve-Path -LiteralPath $PkgPath).ProviderPath   # ← change here
    if (-not (Test-Path $CmdPath)) {
        $alt = Join-Path $PSScriptRoot 'orbis-pub-cmd.exe'
        if (Test-Path $alt) { $CmdPath = $alt }
        else               { throw "Cannot locate orbis-pub-cmd.exe at '$CmdPath'." }
    }

    # -- 2 Run CLI & capture plain text -------------------------------------
    $rawLines = & $CmdPath 'img_info' $pkgFile 2>&1
    if ($LASTEXITCODE) {
        throw "orbis-pub-cmd.exe exited ${LASTEXITCODE}:`n$($rawLines -join "`n")"
    }

    # -- 3 Prepare case-insensitive containers ------------------------------
    $root      = New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
    $sectionHT = $null     # will hold the current subsection

    # -- 4 Normalise & parse -------------------------------------------------
    foreach ($l in $rawLines) {

        # strip UTF-8 BOM, CSI colour codes, tabs → spaces, NBSP → space
        $line = $l -replace '^\uFEFF', ''                 # BOM
        $line = $line -replace '\e\[[0-9;]*m', ''         # ANSI colour
        $line = $line -replace '[\t\u00A0]', ' '          # TAB & NBSP
        $line = $line -replace ' {2,}', ' '               # collapse spaces
        $line = $line.Trim()

        if ($line.Length -eq 0) { continue }

        # -------- section header  [Params] ---------------------------------
        if ($line -match '^\[(.+?)\]$') {
            $secName   = $matches[1]
            $sectionHT = New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
            $root[$secName] = $sectionHT
            continue
        }

        # -------- kv-pair  Title ID: CUSA#####
        if ($sectionHT -and $line -match '^(.+?)\s*:\s*(.+)$') {
            $key = $matches[1].Trim()
            $val = $matches[2].Trim()
            $sectionHT[$key] = $val
            continue
        }

        # -------- unstructured leftovers → _Misc array
        if ($sectionHT) {
            if (-not $sectionHT.ContainsKey('_Misc')) {
                $sectionHT['_Misc'] = New-Object System.Collections.ArrayList
            }
            [void]$sectionHT['_Misc'].Add($line)
        }
    }

    return $root
}


<#
.SYNOPSIS
    Extracts the contents of a PS4 PKG/DLC file to a target directory.

.DESCRIPTION
    • Creates the output directory if it does not exist  
    • Invokes `orbis-pub-cmd.exe img_extract` with a pass-code  
    • Throws when the CLI returns a non-zero exit code

.EXAMPLE
    Extract-OrbisPkg -PkgPath '.\DLC\pets.pkg' -OutputDir '.\out\pets'
#>
function Extract-OrbisPkg {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PkgPath,
        [Parameter(Mandatory)][string]$OutputDir,

        [string]$CmdPath  = '.\helpers\orbis-pub-cmd.exe',
        [string]$Passcode = '00000000000000000000000000000000'
    )

    # 1 ─ resolve paths literally (handles [ ] ? * in names)
    $pkgResolved = (Resolve-Path -LiteralPath $PkgPath -ErrorAction Stop).ProviderPath
    try {
        $outResolved = (Resolve-Path -LiteralPath $OutputDir -ErrorAction Stop).ProviderPath
    } catch {
        $outResolved = Join-Path (Get-Location) $OutputDir
    }
    if (-not (Test-Path $outResolved)) {
        New-Item -ItemType Directory -Path $outResolved -Force | Out-Null
    }

    # 2 ─ build argument **array**
    $args = @(
        'img_extract',
        '--passcode', $Passcode,
        $pkgResolved,
        $outResolved
    )

    # 3 ─ call executable with array, capture exit code & output
    $output = & $CmdPath @args 2>&1
    $exit   = $LASTEXITCODE

    if ($exit -ne 0) {
        throw ("Extraction failed (exit {0}):`n{1}" -f $exit, ($output -join "`n"))
    }

    return $outResolved
}

function Invoke-SelfUtil {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$File,
        [string]$Tool = '.\helpers\selfutil.exe'
    )

    $filePath = (Resolve-Path -LiteralPath $File -ErrorAction Stop).ProviderPath
    if (-not (Test-Path $Tool)) {
        $alt = Join-Path $PSScriptRoot 'selfutil.exe'
        if (-not (Test-Path $alt)) { throw "Cannot locate selfutil.exe." }
        $Tool = $alt
    }

    $out = & $Tool $filePath 2>&1
    $rc  = $LASTEXITCODE
    if ($rc -ne 0) {
        throw ("selfutil.exe exited $rc`n" + ($out -join "`n"))
    }

    # banner check
    if ($out.Count -lt 2 -or
        -not ($out[0] -match '^Input File Name:' -and
              $out[1] -match '^Output File Name:')) {

        throw (
            "Unexpected selfutil.exe output - aborting.`n" +
            ($out -join "`n")
        )
    }

    return $out
}

function Invoke-PatchDlc {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]]$Exec,

        [Parameter(Mandatory)]
        [string[]]$Dlc,

        [string]$OutputDir = '.',

        [switch]$ForceInEboot,

        [string]$Tool = '.\helpers\ps4-eboot-dlc-patcher.exe'
    )

    # ── locate tool ──────────────────────────────────────────────────────────────
    if (-not (Test-Path $Tool)) {
        $alt = Join-Path $PSScriptRoot 'patcher.exe'
        if (-not (Test-Path $alt)) { throw "Cannot locate patcher.exe." }
        $Tool = $alt
    }

    # ── resolve paths ────────────────────────────────────────────────────────────
    $execPaths = foreach ($e in $Exec) { (Resolve-Path -LiteralPath $e -ErrorAction Stop).ProviderPath }
    $dlcPaths  = foreach ($d in $Dlc)  { (Resolve-Path -LiteralPath $d -ErrorAction Stop).ProviderPath }
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir | Out-Null
    }
    $outDir    = (Resolve-Path -LiteralPath $OutputDir -ErrorAction Stop).ProviderPath

    # ── build argument vector ────────────────────────────────────────────────────
    $args = @('patch')
    foreach ($e in $execPaths) { $args += @('-e', $e) }
    foreach ($d in $dlcPaths)  { $args += @('-d', $d) }
    $args += @('-o', $outDir)
    if ($ForceInEboot) { $args += '-f' }

    # ── invoke tool ──────────────────────────────────────────────────────────────
    $out = & $Tool @args 2>&1
    $rc  = $LASTEXITCODE
    if ($rc -ne 0) {
        throw ("patcher.exe exited $rc`n" + ($out -join "`n"))
    }

    # -- verify completion ----------------------------------------------------
    $successLine = $out | Where-Object { $_ -match '^\[INFO\]\s+All patched\b' }
    if (-not $successLine) {
        throw (
            "patcher.exe did not report successful completion - aborting.`n" +
            ($out -join "`n")
        )
    }

    return $out
}

function Invoke-RearrangeDirs {
    param (
        [Parameter(Mandatory)]
        [string]$RootFolder
    )

    # Resolve full path and validate
    $RootFolder = (Resolve-Path -Path $RootFolder).Path
    if (-not (Test-Path $RootFolder)) {
        throw "Root folder '$RootFolder' does not exist."
    }

    $image0Path = Join-Path $RootFolder 'Image0'
    $sc0Path    = Join-Path $RootFolder 'Sc0'
    $sceSysPath = Join-Path $RootFolder 'sce_sys'

    # 1. Move all contents of 'Image0' to root, then delete 'Image0'
    if (Test-Path $image0Path) {
        Get-ChildItem -LiteralPath $image0Path -Force | ForEach-Object {
            if ($_.PSIsContainer) {
                # it’s a folder
                $destFolder = Join-Path $RootFolder $_.Name
                if (Test-Path $destFolder) {
                    # merge: move contents of this subfolder into existing folder
                    Get-ChildItem $_.FullName -Force | Move-Item -Destination $destFolder -Force
                    # then remove the now-empty source folder
                    Remove-Item $_.FullName -Recurse -Force
                }
                else {
                    # no conflict—move the whole folder
                    Move-Item $_.FullName -Destination $RootFolder -Force
                }
            }
            else {
                # it’s a file—just move it (overwrites with -Force)
                Move-Item $_.FullName -Destination $RootFolder -Force
            }
        }
        #TODO
        Remove-Item -Path $image0Path -Recurse -Force
    }

    # 2. Create 'sce_sys' if not exists
    if (-not (Test-Path $sceSysPath)) {
        New-Item -ItemType Directory -Path $sceSysPath | Out-Null
    }

    # 3. Move all contents of 'Sc0' to 'sce_sys'
    if (Test-Path $sc0Path) {
        Get-ChildItem -LiteralPath $sc0Path -Force | ForEach-Object {
            if ($_.PSIsContainer) {
                # it’s a folder
                $destFolder = Join-Path $sceSysPath $_.Name
                if (Test-Path $destFolder) {
                    # merge: move contents of this subfolder into existing folder
                    Get-ChildItem $_.FullName -Force | Move-Item -Destination $destFolder -Force
                    # then remove the now-empty source folder
                    Remove-Item $_.FullName -Recurse -Force
                }
                else {
                    # no conflict—move the whole folder
                    Move-Item $_.FullName -Destination $sceSysPath -Force
                }
            }
            else {
                # it’s a file—just move it (overwrites with -Force)
                Move-Item $_.FullName -Destination $sceSysPath -Force
            }
        }
        Remove-Item -Path $sc0Path -Recurse -Force
    }
}


function Invoke-GenGp4Patch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$PatchDir,

        [string]$Tool = '.\helpers\gengp4_patch.exe'
    )

    # ----- resolve absolute path to the tool -----
    if (-not (Test-Path $Tool -PathType Leaf)) {
        $alt = Join-Path $PSScriptRoot 'gengp4_patch.exe'
        if (-not (Test-Path $alt -PathType Leaf)) {
            throw "Cannot locate gengp4_patch.exe (`"$Tool`" or `"$alt`")."
        }
        $Tool = $alt
    }
    $toolPath = (Resolve-Path -LiteralPath $Tool -ErrorAction Stop).ProviderPath
    $patchAbs = (Resolve-Path -LiteralPath $PatchDir -ErrorAction Stop).ProviderPath

# ----- launch in its own console -----
$psi                  = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName         = $toolPath
$psi.Arguments        = '"' + $patchAbs + '"'       # <— works on all versions
$psi.WorkingDirectory = (Split-Path $toolPath)
$psi.UseShellExecute  = $true
$psi.WindowStyle      = 'Hidden'                    # 'Normal' to watch output

    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $p) { throw "Failed to start $toolPath - check path and permissions." }

    $p.WaitForExit()

    if ($p.ExitCode -ne 0) {
        throw "gengp4_patch.exe exited $($p.ExitCode)"
    }
}

<#
.SYNOPSIS
    Updates a *.gp4* project with a new base-package path, creation date, and
    volume timestamp.

.DESCRIPTION
    Wrapper around **orbis-pub-cmd.exe gp4_proj_update** that

      • Resolves paths literally (wildcards are treated as literals)  
      • Accepts both *date* (`yyyy-MM-dd`) **or** *datetime* values for
        -CDate / -VolumeTs  
      • Automatically falls back to the **current timestamp** when -VolumeTs
        is omitted  
      • Streams tool output and throws on non-zero exit codes

.PARAMETER Gp4Path
    Project file to update.

.PARAMETER BasePkgPath
    Path to the original application package (`--app_path`).

.PARAMETER CDate
    Creation date **or** datetime to forward to `--c_date`.
    ▸ If a *DateTime* is passed it is formatted as `"YYYY-MM-DD HH:mm:ss"`.  
    ▸ If a string matching `yyyy-MM-dd` is passed, it is forwarded unmodified
      (no `00:00:00` is appended).

.PARAMETER VolumeTs
    Volume timestamp for `--volume_ts`.
    ▸ Optional – when omitted the function uses `[DateTime]::Now`.  
    ▸ Always forwarded as a *full* timestamp (`yyyy-MM-dd HH:mm:ss`).

.PARAMETER CmdPath
    Location of **orbis-pub-cmd.exe** (default: `.\orbis-pub-cmd.exe`).

.EXAMPLE
    Update-OrbisGp4 -Gp4Path '.\CUSA15128-patch.gp4' `
                    -BasePkgPath 'X:\Base.pkg' `
                    -CDate '2025-07-17'          # date-only, passed verbatim

.EXAMPLE
    # Full control – explicit datetimes
    Update-OrbisGp4 -Gp4Path '.\patch.gp4' `
                    -BasePkgPath '.\Base.pkg' `
                    -CDate    (Get-Date '2025-07-17 14:00') `
                    -VolumeTs (Get-Date '2025-07-17 14:00')
#>
function Update-OrbisGp4 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Gp4Path,
        [Parameter(Mandatory)][string]$BasePkgPath,

        # Creation date (date-only string *or* full DateTime)
        [Alias('CDate')][object]$CreationDate = (Get-Date -Format 'yyyy-MM-dd'),

        # Volume timestamp – defaults to now
        [Alias('VolumeTs')][object]$VolumeTimestamp,

        [string]$CmdPath = '.\helpers\orbis-pub-cmd.exe'
    )

    # ── 1. Resolve paths ────────────────────────────────────────────────────────
    $gp4Resolved = (Resolve-Path -Literal $Gp4Path  -ErrorAction Stop).ProviderPath
    $pkgResolved = (Resolve-Path -Literal $BasePkgPath -ErrorAction Stop).ProviderPath
    $exeResolved = (Resolve-Path -Literal $CmdPath   -ErrorAction Stop).ProviderPath

    # ── 2. Prepare --c_date argument ────────────────────────────────────────────
    $cDateArg = if (-not $PSBoundParameters.ContainsKey('CreationDate')) {
        $null     # omit entirely
    }
    elseif ($CreationDate -is [DateTime]) {
        $CreationDate.ToString('yyyy-MM-dd HH:mm:ss')
    }
    else {
        # assume user supplied the exact string they want forwarded
        [string]$CreationDate
    }

    # ── 3. Prepare --volume_ts argument ─────────────────────────────────────────
    if (-not $PSBoundParameters.ContainsKey('VolumeTimestamp')) {
        $VolumeTimestamp = Get-Date  # default
    }
    $volumeTsArg = if ($VolumeTimestamp -is [DateTime]) {
        $VolumeTimestamp.ToString('yyyy-MM-dd HH:mm:ss')
    } else {
        [string]$VolumeTimestamp  # assume user knows the exact format
    }

    # ── 4. Build argument array ────────────────────────────────────────────────
    $args = @(
        'gp4_proj_update',
        '--app_path',  $pkgResolved,
        '--volume_ts', $volumeTsArg
    )
    if ($cDateArg) { $args += @('--c_date', $cDateArg) }
    $args += $gp4Resolved            # final positional argument

    Write-Verbose ('[CMD] {0} {1}' -f $exeResolved, ($args -join ' '))

    # ── 5. Invoke ──────────────────────────────────────────────────────────────
    $output = & $exeResolved @args 2>&1
    $exit   = $LASTEXITCODE
    if ($exit -ne 0) {
        throw ('gp4_proj_update failed (exit {0}):{1}{2}' -f `
               $exit, [Environment]::NewLine, ($output -join [Environment]::NewLine))
    }

    return $gp4Resolved
}
function New-OrbisPkg {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Gp4Path,
        [Parameter(Mandatory)][string]$OutPkg,     # may be file or dir
        [switch]$SkipDigest,
        [string]$CmdPath = '.\helpers\orbis-pub-cmd.exe'
    )

    # ── 1. Resolve input paths (PS-5-compatible) ────────────────────────────────
    $gp4Resolved = (Resolve-Path -LiteralPath $Gp4Path -EA Stop).ProviderPath
    $exeResolved = (Resolve-Path -LiteralPath $CmdPath -EA Stop).ProviderPath

    # Normalise $outResolved  → absolute file path
    try {
        $outResolved = (Resolve-Path -LiteralPath $OutPkg -EA Stop).ProviderPath
    } catch {
        $parentDir = Split-Path $OutPkg -Parent
        $leaf      = Split-Path $OutPkg -Leaf
        $baseDir   = if ($parentDir) {
                        (Resolve-Path -LiteralPath $parentDir -EA Stop).ProviderPath
                     } else {
                        (Get-Location).ProviderPath
                     }
        $outResolved = Join-Path $baseDir $leaf
    }

    # Directory that img_create must receive
    $workDir = Split-Path $outResolved -Parent
    if (-not (Test-Path -LiteralPath $workDir)) {
        New-Item -ItemType Directory -Path $workDir | Out-Null
    }

    # ── 2. Build argument array ─────────────────────────────────────────────────
    $args = @('img_create', '--oformat', 'pkg')
    if ($SkipDigest) { $args += '--skip_digest' }
    $args += @($gp4Resolved, $workDir)

    Write-Verbose "[CMD] $exeResolved $($args -join ' ')"

    # ── 3. Invoke tool ──────────────────────────────────────────────────────────
$argStr = ($args -join ' ')                             # quoted earlier
$proc   = Start-Process -FilePath $exeResolved `
                        -ArgumentList $argStr `
                        -WorkingDirectory $workDir `
                        -NoNewWindow `
                        -Wait `
                        -PassThru          # gives us the exit code

$exit = $proc.ExitCode
if ($exit -ne 0) {
    throw "img_create failed (exit $exit)"
}

    # ── 4. Move the newly-built PKG to the requested file name ──────────────────
    $builtPkg = Get-ChildItem -LiteralPath $workDir -Filter *.pkg |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1

    if (-not $builtPkg) {
        throw "img_create succeeded but no *.pkg* appeared in '$workDir'."
    }

    # Avoid needless copy if names already match
    if ($builtPkg.FullName -ne $outResolved) {
        Move-Item -LiteralPath $builtPkg.FullName -Destination $outResolved -Force
    }

    return $outResolved
}




# ── execution ────────────────────────────────────────────────────────────────
$selection = Select-PkgBundle


# from here on use:
#   $selection.Patch
#   $selection.Base
#   $selection.DLCs

$info  = Get-OrbisPkgInfo -PkgPath $selection.Patch


$titleId = $info['Params']['Title Id']
# Optional: act when missing
if (-not $titleId) {
    Write-Warning 'Title ID not found in package metadata. - Making a tmp'
    $titleId = 'CUSATMP'
}



if (-not (Test-Path $workspace)) {
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null
}

$selectionUnpacked = [pscustomobject]@{
    Patch = $workspace + '\' + $titleId +'-patch'
    DLCs  = $dlcs = [System.Collections.Generic.List[string]]::new()
}

Write-Host "▶ Extracting path: $selection.Patch"
$image0 = $selectionUnpacked.Patch + '\Image0'
$sc0 = $selectionUnpacked.Patch + '\Sc0'
Extract-OrbisPkg -PkgPath $selection.Patch -OutputDir $workspace'\'$titleId'-patch'
for ($i = 0; $i -lt $selection.DLCs.Count; $i++) {
    $dlc = $selection.DLCs[$i]
    Write-Host "▶ Processing DLC file: $dlc"
    $outDlcPath = $workspace + '\' + $titleId + '-dlc0' + $i
    $selectionUnpacked.DLCs.add($outDlcPath)
    Extract-OrbisPkg -PkgPath $dlc -OutputDir $outDlcPath
    Invoke-RearrangeDirs -RootFolder $outDlcPath
}


#Patch eboot.bin (Does not support multiple executables rn, but should be zero effort to get it extended)
$ebootBinPath = $image0 + '\eboot.bin'
Invoke-SelfUtil -File $ebootBinPath
$ebootElfPath = $image0 + '\eboot.elf'

#Remove bin
rm $ebootBinPath
#Start dlc-patcher..
$dlcPatcherOutput = $workspace + '\PatchDlcOut'
Invoke-PatchDlc -Exec $ebootElfPath -Dlc $selection.DLCs -OutputDir $dlcPatcherOutput


Write-Output "Moving patched executables.."
#copy files into Image0
Move-Item -Path (Join-Path $dlcPatcherOutput '*') -Destination $image0 -Force
#Rename back to .bin..
Rename-Item -Path $ebootElfPath -NewName "eboot.bin"

Write-Output "Copying extract dlcs.."
#Copy DLCs into Image0
foreach ($dlc in $selectionUnpacked.DLCs) {
    Write-Output "Copying $dlc..."
    Move-Item -Path $dlc -Destination $image0
}

#Rearrange patch folder
Write-Output "Preparing patch for repacking.."
Invoke-RearrangeDirs -RootFolder $selectionUnpacked.Patch
Write-Output "Generating project file.."


Invoke-GenGp4Patch -PatchDir $selectionUnpacked.Patch
$gp4FilePath = $workspace +'\' + $titleId+'-patch.gp4' 
Write-Output "Updating project file with basePKG path... $gp4FilePath"
Update-OrbisGp4 -Gp4Path $gp4FilePath  -BasePkgPath $selection.Base -CDate $info['Params']['Creation Date']
$OutpkgPath = $workspace + '\' + $titleId + 'DLCMERGED.pkg'
New-OrbisPkg -Gp4Path $gp4FilePath -OutPkg $OutpkgPath
