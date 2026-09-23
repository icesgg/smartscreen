# rssi-threshold.ps1 - 착석/자리비움 구간에서 임계값을 고른다
#
# docs/PROXIMITY.md "Measurements" 의 절차를 자동화한 것이다. 손으로 8번째 열을
# 세는 대신, 구간 시각만 주면 실제 상태 기계 규칙을 그대로 돌려 본다.
#
# 쓰는 법
#   .\tools\rssi-threshold.ps1 -Timeline
#       구간 시각을 잊었을 때. 30초 단위로 최저/최고를 찍어 주므로 착석과
#       자리비움의 경계가 눈에 보인다.
#
#   .\tools\rssi-threshold.ps1 -Seated "09:00:00-09:02:00","09:30:00-09:32:00" `
#                              -Away   "09:02:00-09:04:00","09:32:00-09:34:00"
#       두 번 잰 결과를 한꺼번에 넣는다. 한 번만 재면 꼬리를 놓친다.
#
# 로그는 %APPDATA%\SmartScreen\ 의 ble_scan_log.csv(광고 경로)와
# gatt_rssi_log.csv(GATT 경로) 둘 다 읽는다. bleDebugLog=1 이어야 쌓인다.
#
# 주의: 두 로그 모두 세션마다 append 된다. 같은 09:00:00 이 어제치에도 있으므로
# 기본적으로 "데이터가 있는 마지막 세션"만 본다. -Session All 로 전체를 볼 수 있다.

[CmdletBinding()]
param(
    [string[]] $Seated = @(),
    [string[]] $Away   = @(),
    # 걸어나가고 걸어오는 구간을 양끝에서 잘라낸다 (docs/PROXIMITY.md).
    [int]      $TrimSec = 30,
    # Last = 데이터가 있는 마지막 세션, All = 전부, 숫자 = 그 세션(1부터)
    [string]   $Session = 'Last',
    [switch]   $Timeline,
    [int]      $TimelineBucketSec = 30,
    [string]   $LogDir = (Join-Path $env:APPDATA 'SmartScreen'),
    # client/common.h 의 BELOW_SAMPLE_CAP_MS 와 같은 값이어야 한다.
    [int]      $BelowSampleCapMs = 6000
)

$ErrorActionPreference = 'Stop'

function ConvertTo-Seconds([string] $hms) {
    # "16:49:06.221" -> 60546.221
    $m = [regex]::Match($hms, '^(\d{1,2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?$')
    if (-not $m.Success) { return $null }
    $s = [double]$m.Groups[1].Value * 3600 + [double]$m.Groups[2].Value * 60 + [double]$m.Groups[3].Value
    if ($m.Groups[4].Success) { $s += [double]("0." + $m.Groups[4].Value) }
    return $s
}

function Format-Clock([double] $sec) {
    $t = [TimeSpan]::FromSeconds($sec)
    return '{0:00}:{1:00}:{2:00}' -f $t.Hours, $t.Minutes, $t.Seconds
}

# ---------------------------------------------------------------------------
# 로그 읽기. 두 파일은 열이 다르다:
#   ble_scan_log.csv : time,address,addrType,company,name,matched,rawRssi,smoothedRssi,...
#                      matched=1 인 줄만 우리 폰이고, 그 줄에만 smoothedRssi 가 있다
#   gatt_rssi_log.csv: time,seq,rawRssi,smoothedRssi,pollIntervalMs
# ---------------------------------------------------------------------------
function Read-RssiLog([string] $path, [string] $kind, [string] $sessionSel) {
    if (-not (Test-Path $path)) {
        $script:diag = "파일이 없다. bleDebugLog=1 로 바꾸고 앱을 다시 시작해야 생긴다."
        return @()
    }
    $fi = Get-Item $path
    $script:diag = ''
    $script:diagRows = 0        # 주석/헤더가 아닌 줄 전체
    $sessions = New-Object System.Collections.ArrayList
    $cur      = New-Object System.Collections.ArrayList
    # 앱이 로그를 열어 둔 채로 돌고 있는 게 정상이다 (측정 중에 돌려 보게 된다).
    # 공유 읽기로 열지 않으면 "다른 프로세스가 사용 중"으로 매번 실패한다.
    $fs = New-Object System.IO.FileStream($path,
              [System.IO.FileMode]::Open,
              [System.IO.FileAccess]::Read,
              [System.IO.FileShare]::ReadWrite)
    $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
    try {
    while ($null -ne ($line = $sr.ReadLine())) {
        $line = $line.TrimStart([char]0xFEFF)
        if ($line.StartsWith('#')) {
            [void]$sessions.Add($cur)
            $cur = New-Object System.Collections.ArrayList
            continue
        }
        if ($line.StartsWith('time,')) { continue }
        if ($line.Length -eq 0) { continue }
        $script:diagRows++

        $f = $line.Split(',')
        if ($kind -eq 'adv') {
            if ($f.Count -lt 8) { continue }
            if ($f[5] -ne '1')  { continue }      # matched=1 만
            $rssiText = $f[7]                      # smoothedRssi
        } else {
            if ($f.Count -lt 4) { continue }
            $rssiText = $f[3]                      # smoothedRssi
        }
        if ([string]::IsNullOrWhiteSpace($rssiText)) { continue }
        $t = ConvertTo-Seconds $f[0]
        if ($null -eq $t) { continue }
        $r = 0
        if (-not [int]::TryParse($rssiText, [ref]$r)) { continue }
        if ($r -le -100) { continue }              # 신호 없음 표식, 측정값이 아니다
        [void]$cur.Add([pscustomobject]@{ T = $t; Rssi = $r })
    }
    } finally { $sr.Dispose(); $fs.Dispose() }
    [void]$sessions.Add($cur)

    $withData = @($sessions | Where-Object { $_.Count -gt 0 })
    if ($withData.Count -eq 0) {
        # 왜 비었는지가 곧 다음에 할 일이라, 경우를 갈라서 말해 준다.
        $stamp = "({0:N0} B, 마지막 기록 {1:HH:mm:ss})" -f $fi.Length, $fi.LastWriteTime
        if ($script:diagRows -eq 0) {
            $script:diag = "파일은 있는데 기록된 줄이 없다 $stamp. " +
                "bleDebugLog=1 로 바꾼 뒤 앱을 다시 시작했는지 확인."
        } elseif ($kind -eq 'adv') {
            $script:diag = "줄은 {0:N0}개 있는데 matched=1 인 줄이 하나도 없다 $stamp. " -f $script:diagRows
            $script:diag += "폰을 식별하지 못한 상태다 - 상태 표시줄의 ID: 항목을 볼 것."
        } else {
            $script:diag = "줄은 {0:N0}개 있는데 쓸 수 있는 값이 없다 $stamp." -f $script:diagRows
        }
        return @()
    }

    if ($sessionSel -eq 'All') {
        $all = New-Object System.Collections.ArrayList
        foreach ($s in $withData) { foreach ($x in $s) { [void]$all.Add($x) } }
        return $all.ToArray()
    }
    if ($sessionSel -eq 'Last') {
        # 지금 돌고 있는 실행에 데이터가 없는데 예전 실행 것을 조용히 돌려주면,
        # 재지 않은 값으로 임계값을 정하게 된다. 그 경우는 반드시 말해 준다.
        if ($sessions[$sessions.Count - 1].Count -eq 0) {
            $script:diag = "경고: 마지막 실행에는 데이터가 없어 그 이전 실행 것을 쓴다. " +
                "지금 측정한 값이 아니다. bleDebugLog=1 인지 확인할 것."
        }
        return $withData[-1].ToArray()
    }
    $n = 0
    if ([int]::TryParse($sessionSel, [ref]$n) -and $n -ge 1 -and $n -le $withData.Count) {
        return $withData[$n - 1].ToArray()
    }
    throw "-Session 값이 이상하다: $sessionSel (Last / All / 1..$($withData.Count))"
}

function Select-Window($samples, [string] $spec, [int] $trimSec) {
    $parts = $spec.Split('-')
    if ($parts.Count -ne 2) { throw "구간 형식이 이상하다: $spec (예: 09:00:00-09:02:00)" }
    $a = ConvertTo-Seconds $parts[0].Trim()
    $b = ConvertTo-Seconds $parts[1].Trim()
    if ($null -eq $a -or $null -eq $b) { throw "구간 시각을 못 읽었다: $spec" }
    $a += $trimSec; $b -= $trimSec
    if ($b -le $a) { throw "구간이 trim 후 비었다: $spec (-TrimSec $trimSec)" }
    return @($samples | Where-Object { $_.T -ge $a -and $_.T -le $b })
}

# ---------------------------------------------------------------------------
# 상태 기계 재현 - client/main.cpp ScanThread 의 FAR 판정과 같은 규칙.
# 새 샘플이 연속 2개 임계값 미만이면 FAR. 단, 첫 미만 샘플로부터
# BELOW_SAMPLE_CAP_MS 가 지나도록 다음 샘플이 없으면 1개로도 FAR.
# 잠긴 시각을 돌려준다. 안 잠기면 $null.
# ---------------------------------------------------------------------------
function Get-LockTime($samples, [int] $thr, [int] $capMs) {
    $capSec = $capMs / 1000.0
    for ($i = 0; $i -lt $samples.Count; $i++) {
        if ($samples[$i].Rssi -ge $thr) { continue }
        # 첫 미만 샘플. 두 번째를 기다리되, 상한까지만 기다린다.
        $belowFirst = $samples[$i].T
        if ($i + 1 -ge $samples.Count) {
            # 구간 안에 다음 샘플이 없다. 실제 앱은 상한이 차면 하나로도 잠근다.
            return $belowFirst + $capSec
        }
        $next = $samples[$i + 1]
        if (($next.T - $belowFirst) -ge $capSec) { return $belowFirst + $capSec }
        if ($next.Rssi -lt $thr) { return $next.T }
        # 두 번째가 임계값 이상이다 = 단발 페이딩. 그 샘플부터 다시 본다.
        $i++
    }
    return $null
}

# 이 구간에서 "안 잠기는" 가장 높은 임계값. 임계값이 높을수록 잠기기 쉽다.
function Get-HighestSafeThreshold($samples, [int] $capMs) {
    $safe = $null
    for ($thr = -30; $thr -ge -95; $thr--) {
        if ($null -eq (Get-LockTime $samples $thr $capMs)) { $safe = $thr; break }
    }
    return $safe
}

function Show-Stats([string] $label, $samples) {
    if ($samples.Count -eq 0) { Write-Host ("  {0,-22} (샘플 없음)" -f $label) -ForegroundColor DarkYellow; return }
    $min = ($samples | Measure-Object Rssi -Minimum).Minimum
    $max = ($samples | Measure-Object Rssi -Maximum).Maximum
    Write-Host ("  {0,-22} n={1,-5} {2} .. {3} dBm" -f $label, $samples.Count, $min, $max)
}

# ---------------------------------------------------------------------------
$paths = @(
    @{ Kind = 'adv';  Name = '광고';  Path = (Join-Path $LogDir 'ble_scan_log.csv')  },
    @{ Kind = 'gatt'; Name = 'GATT'; Path = (Join-Path $LogDir 'gatt_rssi_log.csv') }
)

Write-Host ""
Write-Host "SmartScreen RSSI 임계값 측정" -ForegroundColor Cyan
Write-Host ("로그 폴더: {0}   세션: {1}   trim: {2}초" -f $LogDir, $Session, $TrimSec)
Write-Host ""

$verdicts = @()

foreach ($p in $paths) {
    $samples = Read-RssiLog $p.Path $p.Kind $Session
    Write-Host ("[{0} 경로]  {1}" -f $p.Name, (Split-Path $p.Path -Leaf)) -ForegroundColor Cyan
    if ($samples.Count -eq 0) {
        Write-Host ("  " + $script:diag) -ForegroundColor DarkYellow
        Write-Host ("  경로: {0}" -f $p.Path) -ForegroundColor DarkGray
        if ($p.Kind -eq 'gatt') {
            Write-Host "  (GATT 경로는 폰 앱이 PC에 연결될 때만 쌓인다. 광고 경로만으로도 측정은 된다)" -ForegroundColor DarkGray
        }
        Write-Host ""
        continue
    }
    if ($script:diag) { Write-Host ("  " + $script:diag) -ForegroundColor Yellow }
    Write-Host ("  세션 전체 n={0}  {1} ~ {2}" -f $samples.Count, (Format-Clock $samples[0].T), (Format-Clock $samples[-1].T))

    if ($Timeline) {
        Write-Host ""
        Write-Host ("  {0}초 단위 (최저 .. 최고 / n)" -f $TimelineBucketSec)
        $groups = $samples | Group-Object { [math]::Floor($_.T / $TimelineBucketSec) }
        foreach ($g in $groups) {
            $lo = ($g.Group | Measure-Object Rssi -Minimum).Minimum
            $hi = ($g.Group | Measure-Object Rssi -Maximum).Maximum
            $t0 = [double]$g.Name * $TimelineBucketSec
            $bar = '#' * [math]::Max(1, [math]::Min(40, 95 + $hi))
            Write-Host ("    {0}  {1,4} .. {2,4}  n={3,-4} {4}" -f (Format-Clock $t0), $lo, $hi, $g.Group.Count, $bar)
        }
        Write-Host ""
    }

    if ($Seated.Count -eq 0 -and $Away.Count -eq 0) { Write-Host ""; continue }

    $seatedAll = @(); $awayAll = @()
    $safePerRun = @()

    foreach ($w in $Seated) {
        $sel = Select-Window $samples $w $TrimSec
        Show-Stats ("착석 " + $w) $sel
        if ($sel.Count -gt 0) {
            $seatedAll += $sel
            $safe = Get-HighestSafeThreshold $sel $BelowSampleCapMs
            $safePerRun += $safe
            $min = ($sel | Measure-Object Rssi -Minimum).Minimum
            Write-Host ("      최저 {0} dBm / 2샘플 규칙으로 안전한 최고 임계값 {1} dBm" -f $min, $safe)
        }
    }
    foreach ($w in $Away) {
        $sel = Select-Window $samples $w $TrimSec
        Show-Stats ("자리비움 " + $w) $sel
        if ($sel.Count -gt 0) { $awayAll += $sel }
    }

    if ($seatedAll.Count -eq 0) { Write-Host ""; continue }

    $seatedMin = ($seatedAll | Measure-Object Rssi -Minimum).Minimum
    $safeThr   = ($safePerRun | Measure-Object -Minimum).Minimum

    Write-Host ""
    Write-Host ("  착석 최저값        {0} dBm  (예전 규칙이라면 임계값은 이보다 낮아야 했다)" -f $seatedMin)
    Write-Host ("  2샘플 안전 임계값  {0} dBm  <- 모든 착석 구간에서 안 잠기는 최고값" -f $safeThr) -ForegroundColor Green

    if ($awayAll.Count -gt 0) {
        $awayMax = ($awayAll | Measure-Object Rssi -Maximum).Maximum
        Write-Host ("  자리비움 최고값    {0} dBm" -f $awayMax)
        Write-Host ""
        Write-Host "  임계값 후보별 자리비움 감지까지 걸리는 시간:"
        foreach ($cand in @($safeThr, ($safeThr - 1), ($safeThr - 2), ($safeThr - 4))) {
            $line = "    {0} dBm :" -f $cand
            foreach ($w in $Away) {
                $sel = Select-Window $samples $w $TrimSec
                if ($sel.Count -eq 0) { continue }
                $lock = Get-LockTime $sel $cand $BelowSampleCapMs
                if ($null -eq $lock) { $line += "  못 잠금!" }
                else { $line += ("  {0:N1}초" -f ($lock - $sel[0].T)) }
            }
            Write-Host $line
        }
    }
    $verdicts += [pscustomobject]@{ Path = $p.Name; Safe = $safeThr; SeatedMin = $seatedMin }
    Write-Host ""
}

if ($verdicts.Count -gt 0) {
    Write-Host "결론" -ForegroundColor Cyan
    foreach ($v in $verdicts) {
        $key = 'nearRssiThreshold'
        if ($v.Path -eq 'GATT') { $key = 'gattRssiThreshold' }
        Write-Host ("  {0} = {1}   ({2} 경로, 착석 최저 {3})" -f $key, $v.Safe, $v.Path, $v.SeatedMin)
    }
    Write-Host ""
    Write-Host "  config.ini 는 앱을 트레이에서 완전히 종료한 뒤에 고칠 것 (안 그러면 덮어쓴다)."
    Write-Host "  한 번만 재고 끝내지 말 것. 두 번째 측정에서 꼬리가 더 내려간 적이 있다."
}
Write-Host ""
