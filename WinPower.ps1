<#
.SYNOPSIS
    Live power monitor: CPU package, GPU, chip total, rest-of-system, running min/avg/max.
.DESCRIPTION
    - CPU  : Intel RAPL via the Energy Meter performance counter.
    - GPU  : NVIDIA via nvidia-smi.
    - Batt : WMI BatteryStatus (mW -> W). "Rest of System" = discharge - CPU - GPU.
    - Stats: min / avg / max of Chip Total (CPU+GPU) over all samples.
    - Keys : R = reset stats   Q = quit
.NOTES
    May need Administrator rights for the RAPL counter.
#>

# ── Configuration ────────────────────────────────────────────────────────────
$sampleInterval = 2          # seconds between samples
$keyPollMs      = 50         # key-check granularity inside the sleep

# ── State ────────────────────────────────────────────────────────────────────
$sampleCount   = 0
$chipTotalSum  = 0.0
$chipTotalMin  = [double]::PositiveInfinity
$chipTotalMax  = [double]::NegativeInfinity
$chipTotalAvg  = 0.0
$startTime     = [DateTime]::UtcNow

# ── Helpers ──────────────────────────────────────────────────────────────────
function Reset-Stats {
    $script:sampleCount  = 0
    $script:chipTotalSum = 0.0
    $script:chipTotalMin = [double]::PositiveInfinity
    $script:chipTotalMax = [double]::NegativeInfinity
    $script:chipTotalAvg = 0.0
    $script:startTime    = [DateTime]::UtcNow
}

# Sleeps for $Seconds while polling keys every $keyPollMs ms.
# Returns $false when the user presses Q (caller should exit), $true otherwise.
function Start-SleepPollKeys ([int]$Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'R' { Reset-Stats }
                'Q' { return $false }
            }
        }
        Start-Sleep -Milliseconds $script:keyPollMs
    }
    return $true
}

# ── Main loop ────────────────────────────────────────────────────────────────
while ($true) {

    $cpuPower        = $null
    $gpuPower        = $null
    $batteryPower    = $null
    $restSystemPower = $null

    # --- CPU: Intel RAPL --------------------------------------------------
    try {
        $cpuCounter = Get-Counter '\Energy Meter(rapl_package0_pkg)\power' -ErrorAction Stop
        $cpuPower   = [double]$cpuCounter.CounterSamples[0].CookedValue / 1000.0
    } catch {}

    # --- GPU: NVIDIA -------------------------------------------------------
    try {
        if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
            $gpuRaw   = nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>$null
            # Split on CRLF or LF, trim each token — handles single and multi-GPU output cleanly.
            $gpuPower = [double](($gpuRaw -split '\r?\n')[0].Trim())
        }
    } catch {}

    # --- Battery: WMI BatteryStatus ----------------------------------------
    try {
        $bat = Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus -ErrorAction Stop
        if ($bat.DischargeRate -gt 0) {
            $batteryPower = $bat.DischargeRate / 1000.0
        } elseif ($bat.ChargeRate -gt 0) {
            $batteryPower = -($bat.ChargeRate / 1000.0)
        }
    } catch {}

    # --- Rest of System (discharge only) -----------------------------------
    if ($batteryPower -gt 0) {
        $knownPower = 0.0
        if ($null -ne $cpuPower) { $knownPower += $cpuPower }
        if ($null -ne $gpuPower) { $knownPower += $gpuPower }
        $restSystemPower = [Math]::Max(0.0, $batteryPower - $knownPower)
    }

    # --- Chip Total (CPU + GPU) --------------------------------------------
    $chipTotal     = 0.0
    $haveChipPower = $false
    if ($null -ne $cpuPower) { $chipTotal += $cpuPower; $haveChipPower = $true }
    if ($null -ne $gpuPower) { $chipTotal += $gpuPower; $haveChipPower = $true }

    # --- Running stats -----------------------------------------------------
    if ($haveChipPower) {
        $sampleCount++
        $chipTotalSum += $chipTotal
        if ($chipTotal -lt $chipTotalMin) { $chipTotalMin = $chipTotal }
        if ($chipTotal -gt $chipTotalMax) { $chipTotalMax = $chipTotal }
        $chipTotalAvg = $chipTotalSum / $sampleCount
    }

    # --- Display -----------------------------------------------------------
    $elapsed    = [DateTime]::UtcNow - $startTime
    $elapsedStr = '{0:D2}:{1:D2}:{2:D2}' -f [int]$elapsed.TotalHours, $elapsed.Minutes, $elapsed.Seconds

    Clear-Host
    Write-Host '=== Live Power Monitor ===' -ForegroundColor Cyan
    Write-Host ('  {0}   samples: {1,5}   elapsed: {2}' -f (Get-Date -Format 'HH:mm:ss'), $sampleCount, $elapsedStr)
    Write-Host

    if ($null -ne $cpuPower) {
        Write-Host ('CPU Package    : {0,8:N2} W' -f $cpuPower)
    } else {
        Write-Host 'CPU Package    : N/A  (RAPL unavailable – try running as Admin)'
    }

    if ($null -ne $gpuPower) {
        Write-Host ('NVIDIA GPU     : {0,8:N2} W' -f $gpuPower)
    } else {
        Write-Host 'NVIDIA GPU     : N/A'
    }

    Write-Host
    if ($haveChipPower) {
        Write-Host ('Chip Total     : {0,8:N2} W' -f $chipTotal)     -ForegroundColor Yellow
        Write-Host ('  Avg          : {0,8:N2} W' -f $chipTotalAvg)  -ForegroundColor DarkYellow
        Write-Host ('  Min          : {0,8:N2} W' -f $chipTotalMin)
        Write-Host ('  Max          : {0,8:N2} W' -f $chipTotalMax)
    } else {
        Write-Host 'Chip Total     : N/A'                              -ForegroundColor Yellow
    }

    Write-Host
    if ($null -ne $restSystemPower) {
        Write-Host ('Rest of System : {0,8:N2} W' -f $restSystemPower) -ForegroundColor Magenta
    } else {
        Write-Host 'Rest of System : N/A  (battery not discharging)'   -ForegroundColor Magenta
    }

    if ($null -ne $batteryPower) {
        if ($batteryPower -ge 0) {
            Write-Host ('Battery Flow   : {0,8:N2} W  (discharging)' -f $batteryPower)             -ForegroundColor Green
        } else {
            Write-Host ('Battery Flow   : {0,8:N2} W  (charging)'    -f [Math]::Abs($batteryPower)) -ForegroundColor Green
        }
    } else {
        Write-Host 'Battery Flow   : N/A  (AC powered / idle battery)' -ForegroundColor Green
    }

    Write-Host
    Write-Host '  R = reset stats   Q = quit' -ForegroundColor DarkGray

    # --- Sleep (with responsive key polling) -------------------------------
    if (-not (Start-SleepPollKeys $sampleInterval)) { break }
}