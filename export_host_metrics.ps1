param(
  [string]$HwinfoCsvPath = "$PSScriptRoot\out\hwinfo_log.CSV",
  [string]$OutFile       = "$PSScriptRoot\out\host_metrics.json",
  [int]$IntervalSec      = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-HwinfoCpuTemp {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) { return $null }

  # Read header + last non-empty line
  $lines = Get-Content -LiteralPath $Path -Encoding UTF8
  if ($lines.Count -lt 2) { return $null }

  $header = $lines[0]
  $last = ($lines | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -Last 1)
  if (-not $last) { return $null }

  Add-Type -AssemblyName Microsoft.VisualBasic | Out-Null

  $p1 = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser([System.IO.StringReader]::new($header))
  $p1.SetDelimiters(",")
  $p1.HasFieldsEnclosedInQuotes = $true
  $cols = $p1.ReadFields()
  $p1.Close()

  $p2 = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser([System.IO.StringReader]::new($last))
  $p2.SetDelimiters(",")
  $p2.HasFieldsEnclosedInQuotes = $true
  $vals = $p2.ReadFields()
  $p2.Close()

  if (-not $cols -or -not $vals) { return $null }

  # Prefer exact column name you showed:
  $target = 'CPU (Tctl/Tdie) [°C]'
  $idx = [Array]::IndexOf($cols, $target)

  # Fallback: first column containing "Tctl/Tdie"
  if ($idx -lt 0) {
    for ($i = 0; $i -lt $cols.Count; $i++) {
      if ($cols[$i] -like '*Tctl/Tdie*') { $idx = $i; break }
    }
  }

  if ($idx -lt 0) { return $null }
  if ($idx -ge $vals.Count) { return $null }

  $raw = $vals[$idx]
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

  $raw = $raw.Trim() -replace ",", "."
  $num = 0.0
  if ([double]::TryParse(
        $raw,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$num)) {
    if ($num -le 0) { return $null }   # avoid bogus 0
    return [Math]::Round($num, 1)
  }

  return $null
}

function Get-WmiCpuTemp {
  try {
    $t = Get-CimInstance MSAcpi_ThermalZoneTemperature -Namespace "root/wmi" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($t) {
        return "{0:N1}" -f (($t.CurrentTemperature - 2732) / 10.0)
    }
  } catch { }
  return $null
}

function Get-DiskHealth {
  try {
    $disks = Get-PhysicalDisk | Select-Object FriendlyName, HealthStatus
    if ($disks) { return $disks }
  } catch { }
  return $null
}

# ✅ NEW: GPU name from Windows (works even if HWiNFO export doesn't include GPU name)
function Get-GpuName {
  try {
    $gpus = Get-CimInstance Win32_VideoController | Where-Object { $_.Name }
    if ($gpus) {
      # Prefer NVIDIA/AMD/Intel if multiple
      $preferred = $gpus | Where-Object { $_.Name -match 'NVIDIA|AMD|Intel' } | Select-Object -First 1
      if ($preferred) { return $preferred.Name }

      return ($gpus | Select-Object -First 1).Name
    }
  } catch { }
  return $null
}

function Get-NvidiaGpu {
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        $csv = nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,power.draw,fan.speed,pstate,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.sw_power_cap,clocks_throttle_reasons.hw_slowdown --format=csv,noheader,nounits
        if ($csv) {
            $parts = $csv -split ","
            return @{
                "utilization.gpu" = $parts[0].Trim()
                "temperature.gpu" = $parts[1].Trim()
                "power.draw"      = $parts[2].Trim()
                "fan.speed"       = $parts[3].Trim()
                "pstate"          = $parts[4].Trim()
                "thermal"         = $parts[5].Trim()
                "powercap"        = $parts[6].Trim()
                "hwslow"          = $parts[7].Trim()
            }
        }
    }
    return $null
}

function Write-JsonAtomic {
  param([string]$Path, [string]$Content)

  $dir = Split-Path -Parent $Path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

  $tmp = "$Path.tmp"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($tmp, $Content, $utf8NoBom)

  if (Test-Path $Path) {
    try {
      [System.IO.File]::Replace($tmp, $Path, $null, $true)
      return
    } catch {
      Remove-Item -Force -ErrorAction SilentlyContinue $Path
      Move-Item -Force $tmp $Path
      return
    }
  } else {
    Move-Item -Force $tmp $Path
  }
}

while ($true) {
  $cpuTemp = Get-HwinfoCpuTemp -Path $HwinfoCsvPath
  if (-not $cpuTemp) { $cpuTemp = Get-WmiCpuTemp }
  $disk    = Get-DiskHealth
  $gpuName = Get-GpuName
  $gpuMetrics = Get-NvidiaGpu

  $obj = [ordered]@{
    timestamp_host  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    cpu_temp_c_host = $cpuTemp
    gpu_name_host   = $gpuName      # ✅ added
    gpu_host        = $gpuMetrics   # ✅ added
    disks_host      = $disk
  }

  $json = ($obj | ConvertTo-Json -Depth 6)

  try {
    Write-JsonAtomic -Path $OutFile -Content $json
  } catch { }

  Start-Sleep -Seconds $IntervalSec
}
