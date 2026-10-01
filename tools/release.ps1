# release.ps1 - 새 버전을 한 번에 내놓는다. release.bat 이 이 파일을 띄운다.
#
#   release.bat              패치 번호를 하나 올리고 (1.1.1 -> 1.1.2) 메모를 묻는다
#   release.bat 1.2.0        이 번호로
#   release.bat -NoGit       커밋·푸시는 하지 않는다 (그러면 Mac 판도 못 한다 - 아래)
#   release.bat -DryRun      게시·커밋 없이 빌드까지만 돌려 본다 (번호는 되돌린다)
#   release-mac.bat 1.2.0    Mac 판만 (-MacOnly). Mac 단계가 실패했을 때 다시 하는 명령이다.
#                            -DryRun 을 붙이면 CI 결과물을 받아 확인까지만 한다
#
# 순서: .env 읽기 -> version.h 올리기 -> 메모 -> 앱 정상 종료 -> do_build.bat ->
#       Publish.exe -> make_dist + zip -> git commit/push -> 닫았던 앱 다시 띄우기 ->
#       Mac: 방금 푸시한 커밋의 CI(mac.yml) 를 기다려 zip 을 받고 -> Publish.exe --platform mac
#
# 왜 이 순서인가: 앱이 떠 있으면 링크가 실패하고(exe 를 못 연다), 그러면 Publish.exe
# 가 낡은 빌드라고 거절한다 - 그래서 종료가 빌드보다 먼저다. 빌드가 실패하면
# version.h 를 되돌린다 - 안 그러면 다음 시도가 번호를 두 번 올린다. 어디서 멈추든
# 닫았던 앱은 다시 띄운다 - 화면을 지키는 프로그램이 배포 스크립트 때문에 꺼져 있으면
# 안 된다.
#
# Mac 단계: 이 PC 에서는 Mac 판을 빌드하지 못한다 (Mac 이 없다). 푸시하면 GitHub Actions 의
# macOS 러너가 그 커밋을 빌드하고 (.github/workflows/mac.yml - client/version.h 가 바뀌면
# 돈다), 이 스크립트는 gh(GitHub CLI) 로 그 실행을 찾아 끝나기를 기다린 뒤 artifact
# (SmartScreen-mac.zip + VERSION) 를 받는다. 번호는 보고(VERSION 파일)만 믿지 않고 zip 안의
# Info.plist 를 직접 본다 (Publish.exe 도 한 번 더 본다). 저장소 맨 위에 SmartScreen-mac.zip 으로
# 복사하고 (새로 까는 Mac 용, SmartScreen-desktop.zip 과 같은 자리) Publish.exe --platform mac
# 으로 올린다 - 브라우저 로그인을 한 번 더 한다. 표는 mac_releases 다 (supabase/mac_releases.sql).
# Mac 단계는 앱을 다시 띄운 **뒤에** 한다 - CI 는 10분 넘게 걸린다. Mac 단계가 실패해도
# Windows 릴리스는 그대로 둔다 - 이미 서버에 있고 PC 들이 받아 가고 있다. 되돌릴 까닭이 없다.
# 대신 다시 할 명령(release-mac.bat x.y.z)을 그대로 찍는다. 필요한 것: gh + 'gh auth login' 한 번.
#
# PowerShell 5.1 함정 넷: (1) $null 을 string 매개변수에 넘기면 "" 가 된다 - FindWindow
# 의 제목 인자는 IntPtr 로 받는다. (2) 네이티브 명령의 stderr 는 오류 레코드가 되고,
# ErrorActionPreference=Stop 이면 vcvarsall 의 잡음 한 줄("vswhere 없음")에도 스크립트가
# 죽는다 - 그래서 Continue 로 두고 종료 코드를 직접 본다. (3) 인자 안의 따옴표는 \" 로
# 바뀌어 cmd 에 간다 - `cmd /c "call ""x.bat"" > ""log""` 는 아무것도 못 하고 끝난다.
# 실제로 그랬고, 스크립트는 지난번 로그를 읽어 "빌드 성공" 이라고 했다. 그래서 빌드는
# PowerShell 이 직접 실행해 출력을 받고, 옛 로그는 먼저 지우고, 끝난 뒤 exe 가 정말
# 새로 생겼는지와 Publish.exe --version 이 새 번호인지를 따로 본다. 보고를 믿지 않는다.
# (4) 거꾸로, 네이티브 명령에 넘기는 인자 **안의** " 는 escape 하지 않는다 (따옴표 상태를
# 제멋대로 센다). 메모에 "..." 가 있으면 Publish.exe 의 인자가 갈라져 "모르는 인자" 로 게시가
# 멈췄다. 그래서 Publish.exe 는 명령줄을 직접 만들어 띄운다 (Invoke-Native).
#
# 한글이 있으므로 이 파일은 UTF-8 BOM 으로 저장돼 있어야 한다 (NEXT_SESSION.md 함정).
param(
    [string]$Version = "",
    [string]$Notes = "",
    [switch]$NoGit,
    [switch]$DryRun,
    [switch]$MacOnly
)
$ErrorActionPreference = 'Continue'
# 콘솔을 UTF-8 로 쓴다. Publish.exe 가 자기 출력을 위해 콘솔 코드페이지를 UTF-8 로 바꾸는데
# 그건 콘솔 전체의 설정이라, 그 뒤에 이 스크립트가 CP949 로 쓰면 한글이 깨진다. cl.exe 의
# 출력은 do_build.bat 의 VSLANG=1033 으로 영어라 인코딩과 무관하다. gh 의 출력도 UTF-8 이다.
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root
$utf8 = New-Object Text.UTF8Encoding $false
$vhPath = Join-Path $root 'client\version.h'

function Step($m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "   [OK] $m" -ForegroundColor Green }
function Note($m) { Write-Host "   $m" }
function Fail($m) { throw "RELEASE_FAIL: $m" }

Add-Type @"
using System; using System.Runtime.InteropServices;
public class SSWin {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c, IntPtr n);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
"@

function Read-DotEnv {
    if (!(Test-Path '.env')) { Fail ".env 가 없다. .env.example 을 복사해 채워라" }
    $cfg = @{}
    Get-Content '.env' | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim() }
    }
    if (!$cfg['SUPABASE_URL'] -or !$cfg['SUPABASE_ANON_KEY']) { Fail ".env 에 SUPABASE_URL / SUPABASE_ANON_KEY 가 없다" }
    return $cfg
}

# version.h 의 세 숫자 (Publish.exe, mac/build_app.sh 도 같은 모양을 읽는다).
function Read-VersionNums([string]$text) {
    $nums = @{}
    foreach ($n in 'MAJOR', 'MINOR', 'PATCH') {
        if ($text -match "#define SS_VERSION_$n (\d+)") { $nums[$n] = [int]$Matches[1] }
        else { Fail "version.h 에서 SS_VERSION_$n 을 못 읽었다" }
    }
    return $nums
}

# 함정 (4): 명령줄을 C 런타임 규칙대로 직접 만든다 (따옴표 앞의 \ 는 두 배, " 는 \", 끝의 \ 도
# 두 배). 출력은 이 콘솔에 그대로 나온다 (& 로 부를 때와 같다). 종료 코드를 돌려준다.
function ConvertTo-ArgText([string]$a) {
    if ($a -ne '' -and $a -notmatch '[\s"]') { return $a }
    $a = $a -replace '(\\*)"', '$1$1\"'
    $a = $a -replace '(\\+)$', '$1$1'
    return '"' + $a + '"'
}
function Invoke-Native([string]$exe, [string[]]$argv) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = (($argv | ForEach-Object { ConvertTo-ArgText $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $p = [Diagnostics.Process]::Start($psi)
    $p.WaitForExit()
    return $p.ExitCode
}

# ---------------------------------------------------------------- Mac 단계 (함수)

# 이 커밋의 mac.yml 실행들 (새것부터). PowerShell 5.1 의 ConvertFrom-Json 은 배열을 한
# 덩어리로 내보내서 @(...) 로 감싸면 원소 하나짜리가 된다 - foreach 로 풀어 담는다.
# pull_request 로 돈 실행은 그 커밋이 아니라 main 과 합친 것을 빌드한다 - 쓰지 않는다.
function Get-MacRuns([string]$sha) {
    $text = (& gh run list --workflow mac.yml --commit $sha --limit 30 --json 'databaseId,headSha,status,conclusion,event,url' | Out-String)
    if ($LASTEXITCODE -ne 0) { Fail "gh run list 가 실패했다 (위의 gh 메시지를 보라)" }
    $runs = @()
    if ($text.Trim()) {
        foreach ($r in ($text | ConvertFrom-Json)) {
            if ($r.headSha -eq $sha -and ($r.event -eq 'push' -or $r.event -eq 'workflow_dispatch')) { $runs += $r }
        }
    }
    return ,$runs
}

# 쓸 실행을 고른다: 가장 새로운 "성공했거나 돌고 있는" 것. 없으면 새로 돌린다. (새것부터 보는
# 까닭: 손으로 다시 돌린 실행이 돌고 있으면, artifact 가 만료됐을 수 있는 옛 성공보다 그게 맞다.)
#   $waitForPush  방금 푸시했다. push 로 시작된 실행이 보이기까지 몇 초 걸리므로 2분까지 찾는다.
#   $retryFailed  release-mac.bat (다시 하기). 실패로 끝난 것뿐이면 새로 돌린다 - 러너나 네트워크
#                 탓이었을 수 있다. 아니면 그 실패를 돌려준다 (같은 코드를 다시 빌드해 봐야 같다).
#   $dry          새로 돌리지 않는다 (DryRun 은 아무것도 시작하지 않는다).
function Find-MacRun([string]$sha, [string]$branch, [bool]$waitForPush, [bool]$retryFailed, [bool]$dry) {
    $short = $sha.Substring(0, 7)
    $deadline = (Get-Date).AddSeconds($(if ($waitForPush) { 120 } else { 0 }))
    if ($waitForPush) { Note "푸시로 시작된 실행을 찾는다 (최대 2분)" }
    $seen = @{}
    $failed = $null
    while ($true) {
        $runs = Get-MacRuns $sha
        foreach ($r in $runs) { $seen["$($r.databaseId)"] = $true }
        foreach ($r in $runs) { if ($r.status -ne 'completed' -or $r.conclusion -eq 'success') { return $r } }
        if ($runs.Count -gt 0) { $failed = $runs[0] }
        if ($failed -or (Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds 10
    }
    if ($failed -and -not $retryFailed) { return $failed }
    if ($dry) { Fail "$short 의 성공한(또는 돌고 있는) CI 실행이 없다. DryRun 은 새로 돌리지 않는다" }

    # 실행이 없다 (push 로는 안 도는 브랜치, 커밋 없이 같은 번호로 다시 하는 경우) 또는 실패한
    # 것뿐이다 -> 새로 돌린다. workflow_dispatch 는 브랜치의 **머리**를 빌드하므로, GitHub 의 그
    # 머리가 이 커밋이어야 한다 (뒤에 다른 커밋이 있으면 다른 것을 빌드한다).
    $up = (& git rev-parse '@{u}' 2>$null | Out-String).Trim()
    if ($up -and $up -ne $sha) { Fail "새로 돌리려면 GitHub 의 $branch 머리가 $short 이어야 한다 (지금 $($up.Substring(0, [Math]::Min(7, $up.Length))))" }
    if ($failed) { Note "이 커밋의 실행이 실패로 끝나 있다 ($($failed.url)) - 새로 돌린다" }
    else { Note "이 커밋의 실행이 없다 - 새로 돌린다 (gh workflow run mac.yml --ref $branch)" }
    # & 로 부르면 gh 의 출력이 이 함수의 반환값에 섞인다 (PowerShell 함수는 잡히지 않은 출력을
    # 전부 돌려준다) - 콘솔에 바로 쓰게 띄운다.
    $rc = Invoke-Native $script:ghExe @('workflow', 'run', 'mac.yml', '--ref', $branch)
    if ($rc -ne 0) { Fail "gh workflow run 이 실패했다 (위의 gh 메시지를 보라)" }
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        foreach ($r in (Get-MacRuns $sha)) { if (-not $seen.ContainsKey("$($r.databaseId)")) { return $r } }
    }
    Fail "새로 돌린 실행이 2분 안에 보이지 않는다 (GitHub 의 $branch 머리가 $short 가 아닐 수 있다)"
}

# zip 안의 SmartScreen.app 의 CFBundleShortVersionString ("" = 없거나 못 읽음, "bplist" = 이진
# plist 라 여기서는 못 읽음 - Publish.exe 는 이진도 읽어 한 번 더 본다). 풀지 않고 그 항목만
# 읽는다 - zip 의 다른 이름(설치 안내.txt)이 이 PC 의 코드페이지로 깨져도 상관없다.
function Get-ZipAppVersion([string]$zipPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $bytes = $null
    $z = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $exeEntry = $z.GetEntry('SmartScreen.app/Contents/MacOS/SmartScreen')
        $plEntry = $z.GetEntry('SmartScreen.app/Contents/Info.plist')
        if (-not $exeEntry -or -not $plEntry) { return "" }
        $ms = New-Object IO.MemoryStream
        $st = $plEntry.Open()
        try { $st.CopyTo($ms) } finally { $st.Dispose() }
        $bytes = $ms.ToArray()
    } finally { $z.Dispose() }
    if ($bytes.Length -ge 6 -and [Text.Encoding]::ASCII.GetString($bytes, 0, 6) -eq 'bplist') { return "bplist" }
    if ($utf8.GetString($bytes) -match '<key>CFBundleShortVersionString</key>\s*<string>([^<]*)</string>') { return $Matches[1] }
    return ""
}

# release-mac.bat 의 메모 = 같은 번호의 Windows 행에 적힌 것 (같은 릴리스다). 못 읽으면 "".
function Get-WindowsNotes([string]$url, [string]$key, [string]$ver) {
    try {
        $req = @{ Method = 'Get'; TimeoutSec = 15
                  Uri = "$url/rest/v1/releases?version=eq.$ver&select=notes"
                  Headers = @{ apikey = $key; Authorization = "Bearer $key" } }
        $rows = Invoke-RestMethod @req
        foreach ($r in $rows) { if ($r.notes) { return [string]$r.notes } }
    } catch { }
    return ""
}

# Mac 판 하나를 끝까지: CI 실행 찾기 -> 기다리기 -> artifact 받기 -> 번호 확인 -> 복사 -> 게시.
# 실패는 Fail (throw) - 부르는 쪽이 "Windows 는 그대로" 와 다시 할 명령을 찍는다.
function Invoke-MacRelease([string]$ver, [string]$notes, [string]$url, [string]$key,
                           [bool]$justPushed, [bool]$retryFailed, [bool]$dry) {
    Step "Mac: CI 빌드 찾기 (.github/workflows/mac.yml)"
    $gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $gh) {
        Fail "gh (GitHub CLI) 가 없다. https://cli.github.com 에서 깔고 'gh auth login' 을 한 번 한 뒤 다시"
    }
    $script:ghExe = $gh.Path
    & gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "gh 가 GitHub 에 로그인돼 있지 않다 (또는 닿지 않는다). 'gh auth login' 을 한 번 한 뒤 다시" }

    $sha = (& git rev-parse HEAD | Out-String).Trim()
    if ($sha -notmatch '^[0-9a-f]{40}$') { Fail "git rev-parse HEAD 가 실패했다" }
    $short = $sha.Substring(0, 7)
    $branch = (& git rev-parse --abbrev-ref HEAD | Out-String).Trim()
    if (-not $branch -or $branch -eq 'HEAD') { Fail "브랜치 위가 아니다 (detached HEAD) - CI 를 돌릴 브랜치가 없다" }

    # CI 는 작업 트리가 아니라 커밋을 빌드한다. 그 커밋의 version.h 가 이 번호여야 한다.
    $hv = Read-VersionNums (& git show "HEAD:client/version.h" | Out-String)
    $headVer = "$($hv.MAJOR).$($hv.MINOR).$($hv.PATCH)"
    if ($headVer -ne $ver) { Fail "HEAD($short) 의 client/version.h 는 $headVer 다 ($ver 이어야 한다). 커밋·푸시부터" }

    # 푸시된 커밋이어야 CI 가 본다.
    $remoteHas = @(& git branch -r --contains $sha 2>$null)
    if ($remoteHas.Count -eq 0) {
        & git fetch -q 2>&1 | Out-Null
        $remoteHas = @(& git branch -r --contains $sha 2>$null)
    }
    if ($remoteHas.Count -eq 0) { Fail "HEAD($short) 가 GitHub 에 없다 - CI 는 푸시된 커밋만 빌드한다. 'git push' 한 뒤 다시" }
    Ok "$branch @ $short ($ver)"

    $run = Find-MacRun $sha $branch $justPushed $retryFailed $dry
    Ok "실행 $($run.databaseId) ($($run.event))"

    Step "Mac: CI 기다리기 (보통 10~20분, 길어야 40분)"
    Note "$($run.url)"
    # 콘솔에 바로 붙여 띄운다 (gh 가 터미널로 알아보고 진행을 제자리에서 그린다).
    [void](Invoke-Native $script:ghExe @('run', 'watch', "$($run.databaseId)", '--exit-status', '--compact', '--interval', '10'))
    # watch 의 종료 코드만 믿지 않는다 (연결이 끊겨도 0 이 아니다) - 실행의 결론을 직접 본다.
    $view = (& gh run view $run.databaseId --json 'status,conclusion,url' | Out-String)
    if ($LASTEXITCODE -ne 0 -or -not $view.Trim()) { Fail "gh run view 가 실패했다 (위의 gh 메시지를 보라)" }
    $v = $view | ConvertFrom-Json
    if ($v.status -ne 'completed') { Fail "CI 가 아직 끝나지 않았다 ($($v.status)) - 기다리기가 끊겼다. 끝난 뒤 다시. $($v.url)" }
    if ($v.conclusion -ne 'success') { Fail "Mac 빌드가 실패했다 (CI: $($v.conclusion)). 로그: $($v.url)" }
    Ok "CI 성공"

    Step "Mac: 결과물 받기 (artifact SmartScreen-mac)"
    $tmp = Join-Path $env:TEMP ("smartscreen-mac-$ver-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $rc = Invoke-Native $script:ghExe @('run', 'download', "$($run.databaseId)", '-n', 'SmartScreen-mac', '-D', $tmp)
    if ($rc -ne 0) {
        Fail "artifact 를 받지 못했다 (보관은 30일이다 - 지났으면 'gh workflow run mac.yml --ref $branch' 로 다시 빌드한 뒤 다시)"
    }
    $zipItem = Get-ChildItem -LiteralPath $tmp -Recurse -File | Where-Object { $_.Name -eq 'SmartScreen-mac.zip' } | Select-Object -First 1
    $verItem = Get-ChildItem -LiteralPath $tmp -Recurse -File | Where-Object { $_.Name -eq 'VERSION' } | Select-Object -First 1
    if (-not $zipItem -or -not $verItem) { Fail "artifact 안에 SmartScreen-mac.zip / VERSION 이 없다 ($tmp)" }
    $ciVer = ([IO.File]::ReadAllText($verItem.FullName)).Trim()
    if ($ciVer -ne $ver) { Fail "CI 가 만든 것은 '$ciVer' 이다 ($ver 이어야 한다). $tmp" }
    # VERSION 은 build_app.sh 가 적은 보고다. zip 안의 앱을 직접 본다.
    $appVer = Get-ZipAppVersion $zipItem.FullName
    if ($appVer -eq 'bplist') { Note "zip 안의 Info.plist 가 이진 형식이라 번호는 Publish.exe 가 본다" }
    elseif ($appVer -ne $ver) { Fail "zip 안의 SmartScreen.app 은 '$appVer' 이다 ($ver 이어야 한다). $tmp" }
    Ok ("SmartScreen-mac.zip {0} ({1:N1} MB)" -f $ver, ($zipItem.Length / 1MB))

    if ($dry) {
        Step "DryRun - Mac 은 여기까지. 복사·게시는 하지 않는다"
        Note "받은 것: $($zipItem.FullName)"
        return
    }

    Step "Mac: 게시 (Publish.exe --platform mac - 브라우저에서 한 번 더 로그인)"
    $rootZip = Join-Path $root 'SmartScreen-mac.zip'
    Copy-Item -LiteralPath $zipItem.FullName -Destination $rootZip -Force
    Note "SmartScreen-mac.zip 을 저장소 맨 위에 두었다 (새로 까는 Mac 용)"
    $rc = Invoke-Native "$root\build\Publish.exe" @($url, $key, '--platform', 'mac', '--file', $rootZip, '--notes', $notes)
    if ($rc -ne 0) { Fail "Mac 게시 실패 (exit $rc) - 위의 [FAIL] 줄을 보라" }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- release-mac.bat: Mac 만
if ($MacOnly) {
    $exitCode = 0
    $macVer = $Version
    try {
        Step ".env"
        $cfg = Read-DotEnv
        $url = $cfg['SUPABASE_URL']; $key = $cfg['SUPABASE_ANON_KEY']
        Ok $url

        Step "버전 (Mac 만)"
        $cur = Read-VersionNums ([IO.File]::ReadAllText($vhPath, $utf8))
        $curVer = "$($cur.MAJOR).$($cur.MINOR).$($cur.PATCH)"
        if (-not $macVer) { $macVer = $curVer }
        if ($macVer -notmatch '^\d+\.\d+\.\d+$') { Fail "버전은 a.b.c 꼴이어야 한다: $macVer" }
        # Publish.exe 는 자기가 빌드된 번호(= version.h)로만 올린다.
        if ($macVer -ne $curVer) { Fail "client/version.h 는 $curVer 이다. Publish.exe 는 version.h 의 번호로만 올린다 - $macVer 은 그 번호의 커밋에서 빌드해야 올릴 수 있다" }
        if (-not (Test-Path "$root\build\Publish.exe")) { Fail "build\Publish.exe 가 없다 - do_build.bat 를 먼저" }
        $built = (& "$root\build\Publish.exe" --version 2>&1 | Out-String).Trim()
        if ($built -ne $macVer) { Fail "build\Publish.exe 가 '$built' 이라고 한다 ($macVer 이어야 한다). 앱을 끄고 do_build.bat 를 다시" }
        & "$root\build\Publish.exe" --selftest | Out-Null
        if ($LASTEXITCODE -ne 0) { & "$root\build\Publish.exe" --selftest; Fail "Publish.exe --selftest 실패" }
        Ok $macVer

        if (-not $Notes) {
            $Notes = Get-WindowsNotes $url $key $macVer
            if ($Notes) { Note ("메모: Windows $macVer 과 같은 것 - " + ($Notes -split "`n")[0]) }
        }
        if (-not $Notes -and -not $DryRun) {
            Write-Host ""
            $Notes = Read-Host "배포 메모 (무엇이 바뀌었나. 비워 두면 '버전 $macVer')"
        }
        if (-not $Notes) { $Notes = "버전 $macVer" }

        Invoke-MacRelease $macVer $Notes $url $key $false $true ([bool]$DryRun)
    }
    catch {
        $msg = "$_"
        if ($msg -like 'RELEASE_FAIL: *') { $msg = $msg.Substring(14) }
        Write-Host ""
        Write-Host "[X] Mac: $msg" -ForegroundColor Red
        Write-Host ("    원인을 고친 뒤 다시:  release-mac.bat " + $(if ($macVer) { $macVer } else { '<버전>' }))
        $exitCode = 1
    }
    if ($exitCode -eq 0 -and -not $DryRun) {
        Write-Host ""
        Write-Host "끝. Mac $macVer 이 서버에 있다." -ForegroundColor Green
        Write-Host "개인 Mac 은 한 시간 안에 띠가 뜬다 (버전 단추를 누르면 바로)."
        Write-Host "기업 Mac 은 대시보드 > 프로그램 업데이트 > Mac > $macVer [승인] 을 눌러야 받는다."
        Write-Host "새로 까는 Mac 은 저장소 맨 위의 SmartScreen-mac.zip 을 쓴다."
    }
    exit $exitCode
}

# finally 에서 쓰는 상태
$script:origVersionText = $null   # 되돌릴 version.h 내용 (올렸으면)
$script:oldVer = ""; $script:newVer = ""
$script:published = $false        # 게시가 됐으면 번호를 두지, 되돌리지 않는다
$script:winPublished = $false     # Windows 판이 정말 서버에 올라갔다
$script:pushed = $false           # 이번에 커밋을 만들어 푸시했다 (Mac CI 가 그걸로 돈다)
$script:closedPath = $null        # 우리가 닫은 앱의 경로
$script:relaunched = $false
$exitCode = 0

try {
    # ------------------------------------------------------------ .env
    Step ".env"
    $cfg = Read-DotEnv
    $url = $cfg['SUPABASE_URL']; $key = $cfg['SUPABASE_ANON_KEY']
    Ok $url

    # ------------------------------------------------------------ version.h
    Step "버전"
    $vhText = [IO.File]::ReadAllText($vhPath, $utf8)
    $nums = Read-VersionNums $vhText
    $script:oldVer = "$($nums.MAJOR).$($nums.MINOR).$($nums.PATCH)"
    if ($Version) {
        if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)$') { Fail "버전은 a.b.c 꼴이어야 한다: $Version" }
        $nums.MAJOR = [int]$Matches[1]; $nums.MINOR = [int]$Matches[2]; $nums.PATCH = [int]$Matches[3]
    } else {
        $nums.PATCH += 1
    }
    $script:newVer = "$($nums.MAJOR).$($nums.MINOR).$($nums.PATCH)"
    if ($script:newVer -eq $script:oldVer) {
        # 번호를 명시했는데 지금과 같다 = 게시가 실패한 뒤 같은 번호로 다시 올리는 경우.
        # 파일은 손대지 않는다 (되돌릴 것도 없다).
        if (-not $Version) { Fail "지금 버전과 같다: $script:oldVer" }
        Ok "$script:newVer (version.h 그대로)"
    } else {
        $script:origVersionText = $vhText
        $vhText = $vhText -replace '#define SS_VERSION_MAJOR \d+', "#define SS_VERSION_MAJOR $($nums.MAJOR)"
        $vhText = $vhText -replace '#define SS_VERSION_MINOR \d+', "#define SS_VERSION_MINOR $($nums.MINOR)"
        $vhText = $vhText -replace '#define SS_VERSION_PATCH \d+', "#define SS_VERSION_PATCH $($nums.PATCH)"
        [IO.File]::WriteAllText($vhPath, $vhText, $utf8)
        Ok "$script:oldVer -> $script:newVer"
    }

    # ------------------------------------------------------------ 메모
    if (!$DryRun -and !$Notes) {
        Write-Host ""
        $Notes = Read-Host "배포 메모 (무엇이 바뀌었나. 비워 두면 '버전 $script:newVer')"
    }
    if (!$Notes) { $Notes = "버전 $script:newVer" }

    # ------------------------------------------------------------ 앱 정상 종료
    Step "앱 종료"
    # Windows 자체의 System32\smartscreen.exe(Defender) 와 이름이 같다. 경로로 가른다.
    $sys = Join-Path $env:SystemRoot 'System32\smartscreen.exe'
    $procs = @(Get-Process SmartScreen -ErrorAction SilentlyContinue | Where-Object { $_.Path -and ($_.Path -ne $sys) })
    if ($procs.Count -gt 0) {
        $script:closedPath = $procs[0].Path
        Write-Host "   떠 있음: $script:closedPath"
        # 오버레이의 [종료] 와 같은 길 (WM_COMMAND / ID_OVL_EXIT = 401). 강제 종료보다 이쪽이 낫다.
        $ovl = [SSWin]::FindWindow("SmartScreenOverlay", [IntPtr]::Zero)
        if ($ovl -ne [IntPtr]::Zero) {
            [void][SSWin]::SendMessage($ovl, 0x111, [IntPtr]401, [IntPtr]0)
            Write-Host "   오버레이에 [종료] 를 보냈다"
        } else {
            $main = [SSWin]::FindWindow("SmartScreenBT", [IntPtr]::Zero)
            if ($main -ne [IntPtr]::Zero) { [void][SSWin]::SendMessage($main, 0x10, [IntPtr]0, [IntPtr]0); Write-Host "   설정 창에 닫기를 보냈다 (오버레이 없음)" }
            else { Fail "SmartScreen 창을 못 찾았다 (프로세스는 있다: $script:closedPath). 오버레이의 [종료] 로 끄고 다시 해라" }
        }
        # 정상 종료는 BLE 스레드(최대 15초)와 클립보드·업데이트 일꾼을 기다린다. 넉넉히 준다.
        $gone = $false
        Write-Host -NoNewline "   끝나기를 기다린다 "
        for ($i = 0; $i -lt 120; $i++) {
            Start-Sleep -Milliseconds 500
            if (-not (Get-Process -Id $procs[0].Id -ErrorAction SilentlyContinue)) { $gone = $true; break }
            if ($i % 4 -eq 3) { Write-Host -NoNewline "." }
        }
        Write-Host ""
        if (-not $gone) { Fail "앱이 60초 안에 끝나지 않았다. 오버레이의 [종료] 로 끄고 다시 해라" }
        Ok ("끝남 ({0:N1}초)" -f (($i + 1) * 0.5))
    } else {
        Ok "떠 있지 않다"
    }

    # ------------------------------------------------------------ 빌드
    Step "빌드 (do_build.bat)"
    $buildLog = Join-Path $env:TEMP 'smartscreen-release-build.log'
    if (Test-Path $buildLog) { Remove-Item $buildLog -Force }      # 지난번 로그를 증거로 삼지 않는다
    # PowerShell 이 직접 실행한다 (머리말 함정 3). stderr 줄은 오류 레코드로 섞여 들어오지만
    # Continue 라 멈추지 않고, 로그에 같이 남는다.
    $log = (& "$root\do_build.bat" 2>&1 | Out-String)
    $buildRc = $LASTEXITCODE
    [IO.File]::WriteAllText($buildLog, $log, $utf8)
    if ($buildRc -ne 0 -or $log -notmatch 'BUILD_SUCCESS') {
        Write-Host (($log -split "`n") | Select-Object -Last 25) -Separator "`n"
        Fail "빌드 실패 (exit $buildRc). 위가 로그의 끝이다 (전체: $buildLog)"
    }
    # 보고가 아니라 결과를 본다: exe 두 개가 version.h 보다 낡지 않았나 (낡았다 = 링크가
    # 안 된 것), 그리고 그 안의 번호가 맞나. "이번 실행에 새로 생겼나" 로 보면 안 된다 -
    # 같은 번호로 다시 돌릴 때 nmake 는 이미 맞는 exe 를 다시 링크하지 않는다.
    $vhTime = (Get-Item $vhPath).LastWriteTime
    foreach ($exe in 'SmartScreen.exe', 'Publish.exe') {
        $f = Get-Item "$root\build\$exe" -ErrorAction SilentlyContinue
        if (-not $f) { Fail "build\$exe 가 없다 (로그: $buildLog)" }
        if ($f.LastWriteTime -lt $vhTime) { Fail "build\$exe 가 version.h 보다 낡았다 - 링크가 안 됐다 (로그: $buildLog)" }
    }
    $built = (& "$root\build\Publish.exe" --version 2>&1 | Out-String).Trim()
    if ($built -ne $script:newVer) { Fail "새 Publish.exe 가 '$built' 이라고 한다 ($script:newVer 이어야 한다)" }
    Ok "SmartScreen.exe / Publish.exe $built (새로 생김)"
    & "$root\build\Publish.exe" --selftest | Out-Null
    if ($LASTEXITCODE -ne 0) { & "$root\build\Publish.exe" --selftest; Fail "Publish.exe --selftest 실패" }

    if ($DryRun) {
        Step "DryRun - 여기까지. 게시·커밋·Mac 은 하지 않고 번호를 되돌린다"
    } else {
        # -------------------------------------------------------- 게시
        Step "게시 (Publish.exe - 브라우저에서 로그인)"
        $rc = Invoke-Native "$root\build\Publish.exe" @($url, $key, "$root\build\SmartScreen.exe", '--notes', $Notes)
        if ($rc -ne 0) {
            # 빌드는 새 번호로 됐으니 번호는 둔다. 같은 번호로 다시 올리면 된다.
            $script:published = $true
            Fail "게시 실패. 버전은 $script:newVer 그대로다 - 원인을 고친 뒤 'release.bat $script:newVer' 으로 같은 번호를 다시 올려라"
        }
        $script:published = $true
        $script:winPublished = $true

        # -------------------------------------------------------- dist + zip (새로 까는 PC 용)
        Step "dist\ 와 SmartScreen-desktop.zip"
        & "$root\make_dist.bat" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "make_dist.bat 실패" }
        if (Test-Path "$root\SmartScreen-desktop.zip") { Remove-Item "$root\SmartScreen-desktop.zip" -Force }
        Compress-Archive -Path "$root\dist\*" -DestinationPath "$root\SmartScreen-desktop.zip" -Force
        Ok "갱신됨"

        # -------------------------------------------------------- git
        if (-not $NoGit) {
            Step "git commit + push"
            $status = git status --porcelain
            if ($status) {
                Write-Host ($status -join "`n")
                git add -A
                git commit -q -m "Release $script:newVer" -m $Notes
                if ($LASTEXITCODE -ne 0) { Fail "커밋 실패" }
                git push
                if ($LASTEXITCODE -ne 0) { Fail "푸시 실패 (커밋은 됐다). 네트워크를 보고 'git push' 를 다시" }
                $script:pushed = $true
                Ok "Release $script:newVer 푸시됨"
            } else {
                Ok "바뀐 것이 없다"
            }
        }
    }
}
catch {
    $msg = "$_"
    if ($msg -like 'RELEASE_FAIL: *') { $msg = $msg.Substring(14) }
    Write-Host ""
    Write-Host "[X] $msg" -ForegroundColor Red
    $exitCode = 1
}
finally {
    # 게시 전에 멈췄으면(빌드 실패, DryRun, 종료 실패) 번호를 되돌린다.
    if ($script:origVersionText -ne $null -and -not $script:published) {
        [IO.File]::WriteAllText($vhPath, $script:origVersionText, $utf8)
        Write-Host "   version.h 를 $script:oldVer 으로 되돌렸다"
    }
    # 닫았던 앱은 무슨 일이 있어도 다시 띄운다.
    if ($script:closedPath -and -not $script:relaunched) {
        Step "앱 다시 띄우기"
        Start-Process -FilePath $script:closedPath -WorkingDirectory (Split-Path $script:closedPath)
        $script:relaunched = $true
        Ok $script:closedPath
    }
}

# ---------------------------------------------------------------- Mac 판
# Windows 가 끝까지 됐을 때만 (게시 + 푸시). 앱은 위에서 이미 다시 띄웠다.
$winDone = ($exitCode -eq 0 -and -not $DryRun)
$macState = ''
$macCmd = "release-mac.bat $script:newVer"
if ($winDone) {
    if ($NoGit) {
        $macState = 'skipped'
    } else {
        try {
            Invoke-MacRelease $script:newVer $Notes $url $key $script:pushed $false $false
            $macState = 'ok'
        }
        catch {
            $msg = "$_"
            if ($msg -like 'RELEASE_FAIL: *') { $msg = $msg.Substring(14) }
            Write-Host ""
            Write-Host "[X] Mac: $msg" -ForegroundColor Red
            Write-Host "    Windows $script:newVer 은 게시됐다 - 그대로 둔다."
            Write-Host "    원인을 고친 뒤 Mac 만 다시:  $macCmd"
            $macState = 'failed'
            $exitCode = 1
        }
    }
} elseif ($script:winPublished) {
    # Windows 는 서버에 올라갔는데 그 뒤(dist, 커밋, 푸시)에서 멈췄다. Mac CI 는 푸시된 커밋이 있어야 돈다.
    Write-Host "    Mac 판은 하지 않았다. 위를 고치고 푸시한 뒤 Mac 만:  $macCmd"
}

if ($winDone) {
    Write-Host ""
    if ($macState -eq 'ok') { Write-Host "끝. $script:newVer 이 서버에 있다 (Windows + Mac)." -ForegroundColor Green }
    else { Write-Host "끝. $script:newVer 이 서버에 있다 (Windows)." -ForegroundColor Green }
    Write-Host "개인 PC 는 한 시간 안에 띠가 뜬다 (버전 단추를 누르면 바로)."
    Write-Host "기업 PC 는 대시보드 > 프로그램 업데이트 > Windows > $script:newVer [승인] 을 눌러야 받는다."
    if ($macState -eq 'ok') {
        Write-Host "기업 Mac 은 같은 곳의 Mac > $script:newVer [승인] 을 따로 눌러야 받는다."
        Write-Host "새로 까는 Mac 은 저장소 맨 위의 SmartScreen-mac.zip 을 쓴다."
    } elseif ($macState -eq 'skipped') {
        Write-Host "Mac 판은 건너뛰었다 (-NoGit: CI 는 푸시된 커밋만 빌드한다). 푸시한 뒤 Mac 만:  $macCmd" -ForegroundColor Yellow
    } elseif ($macState -eq 'failed') {
        Write-Host "Mac 판은 올라가지 않았다 (위의 [X] Mac). 다시:  $macCmd" -ForegroundColor Yellow
    }
}
exit $exitCode
