# release.ps1 - 새 버전을 한 번에 내놓는다. release.bat 이 이 파일을 띄운다.
#
#   release.bat              패치 번호를 하나 올리고 (1.1.1 -> 1.1.2) 메모를 묻는다
#   release.bat 1.2.0        이 번호로
#   release.bat -NoGit       커밋·푸시는 하지 않는다
#   release.bat -DryRun      게시·커밋 없이 빌드까지만 돌려 본다 (번호는 되돌린다)
#
# 순서: .env 읽기 -> version.h 올리기 -> 메모 -> 앱 정상 종료 -> do_build.bat ->
#       Publish.exe -> make_dist + zip -> git commit/push -> 닫았던 앱 다시 띄우기
#
# 왜 이 순서인가: 앱이 떠 있으면 링크가 실패하고(exe 를 못 연다), 그러면 Publish.exe
# 가 낡은 빌드라고 거절한다 - 그래서 종료가 빌드보다 먼저다. 빌드가 실패하면
# version.h 를 되돌린다 - 안 그러면 다음 시도가 번호를 두 번 올린다. 어디서 멈추든
# 닫았던 앱은 다시 띄운다 - 화면을 지키는 프로그램이 배포 스크립트 때문에 꺼져 있으면
# 안 된다.
#
# PowerShell 5.1 함정 둘: (1) $null 을 string 매개변수에 넘기면 "" 가 된다 - FindWindow
# 의 제목 인자는 IntPtr 로 받는다. (2) 네이티브 명령의 stderr 는 오류 레코드가 되고,
# ErrorActionPreference=Stop 이면 vcvarsall 의 잡음 한 줄("vswhere 없음")에도 스크립트가
# 죽는다 - 그래서 Continue 로 두고 종료 코드를 직접 본다.
#
# 한글이 있으므로 이 파일은 UTF-8 BOM 으로 저장돼 있어야 한다 (NEXT_SESSION.md 함정).
param(
    [string]$Version = "",
    [string]$Notes = "",
    [switch]$NoGit,
    [switch]$DryRun
)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root
$utf8 = New-Object Text.UTF8Encoding $false
$vhPath = Join-Path $root 'client\version.h'

function Step($m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "   [OK] $m" -ForegroundColor Green }
function Fail($m) { throw "RELEASE_FAIL: $m" }

Add-Type @"
using System; using System.Runtime.InteropServices;
public class SSWin {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c, IntPtr n);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
"@

# finally 에서 쓰는 상태
$script:origVersionText = $null   # 되돌릴 version.h 내용 (올렸으면)
$script:oldVer = ""; $script:newVer = ""
$script:published = $false        # 게시가 됐으면 번호를 두지, 되돌리지 않는다
$script:closedPath = $null        # 우리가 닫은 앱의 경로
$script:relaunched = $false
$exitCode = 0

try {
    # ------------------------------------------------------------ .env
    Step ".env"
    if (!(Test-Path '.env')) { Fail ".env 가 없다. .env.example 을 복사해 채워라" }
    $cfg = @{}
    Get-Content '.env' | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim() }
    }
    $url = $cfg['SUPABASE_URL']; $key = $cfg['SUPABASE_ANON_KEY']
    if (!$url -or !$key) { Fail ".env 에 SUPABASE_URL / SUPABASE_ANON_KEY 가 없다" }
    Ok $url

    # ------------------------------------------------------------ version.h
    Step "버전"
    $vhText = [IO.File]::ReadAllText($vhPath, $utf8)
    $nums = @{}
    foreach ($n in 'MAJOR', 'MINOR', 'PATCH') {
        if ($vhText -match "#define SS_VERSION_$n (\d+)") { $nums[$n] = [int]$Matches[1] }
        else { Fail "version.h 에서 SS_VERSION_$n 을 못 읽었다" }
    }
    $script:oldVer = "$($nums.MAJOR).$($nums.MINOR).$($nums.PATCH)"
    if ($Version) {
        if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)$') { Fail "버전은 a.b.c 꼴이어야 한다: $Version" }
        $nums.MAJOR = [int]$Matches[1]; $nums.MINOR = [int]$Matches[2]; $nums.PATCH = [int]$Matches[3]
    } else {
        $nums.PATCH += 1
    }
    $script:newVer = "$($nums.MAJOR).$($nums.MINOR).$($nums.PATCH)"
    if ($script:newVer -eq $script:oldVer) { Fail "지금 버전과 같다: $script:oldVer" }
    $script:origVersionText = $vhText
    $vhText = $vhText -replace '#define SS_VERSION_MAJOR \d+', "#define SS_VERSION_MAJOR $($nums.MAJOR)"
    $vhText = $vhText -replace '#define SS_VERSION_MINOR \d+', "#define SS_VERSION_MINOR $($nums.MINOR)"
    $vhText = $vhText -replace '#define SS_VERSION_PATCH \d+', "#define SS_VERSION_PATCH $($nums.PATCH)"
    [IO.File]::WriteAllText($vhPath, $vhText, $utf8)
    Ok "$script:oldVer -> $script:newVer"

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
    # 리다이렉션은 cmd 가 한다. PowerShell 이 하면 stderr 줄마다 오류 레코드가 된다.
    cmd /c "call ""$root\do_build.bat"" > ""$buildLog"" 2>&1"
    $log = if (Test-Path $buildLog) { Get-Content $buildLog -Raw } else { "" }
    if ($log -notmatch 'BUILD_SUCCESS') {
        Write-Host (($log -split "`n") | Select-Object -Last 25) -Separator "`n"
        Fail "빌드 실패. 위가 로그의 끝이다 (전체: $buildLog)"
    }
    Ok "SmartScreen.exe / Publish.exe $script:newVer"
    & "$root\build\Publish.exe" --selftest | Out-Null
    if ($LASTEXITCODE -ne 0) { & "$root\build\Publish.exe" --selftest; Fail "Publish.exe --selftest 실패" }

    if ($DryRun) {
        Step "DryRun - 여기까지. 게시·커밋은 하지 않고 번호를 되돌린다"
    } else {
        # -------------------------------------------------------- 게시
        Step "게시 (Publish.exe - 브라우저에서 로그인)"
        & "$root\build\Publish.exe" $url $key "$root\build\SmartScreen.exe" --notes $Notes
        if ($LASTEXITCODE -ne 0) {
            # 빌드는 새 번호로 됐으니 번호는 둔다. 같은 번호로 다시 올리면 된다.
            $script:published = $true
            Fail "게시 실패. 버전은 $script:newVer 그대로다 - 원인을 고친 뒤 'release.bat $script:newVer' 으로 같은 번호를 다시 올려라"
        }
        $script:published = $true

        # -------------------------------------------------------- dist + zip (새로 까는 PC 용)
        Step "dist\ 와 SmartScreen-desktop.zip"
        cmd /c "call ""$root\make_dist.bat"" > nul 2>&1"
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

if ($exitCode -eq 0 -and -not $DryRun) {
    Write-Host ""
    Write-Host "끝. $script:newVer 이 서버에 있다." -ForegroundColor Green
    Write-Host "개인 PC 는 한 시간 안에 띠가 뜬다 (버전 단추를 누르면 바로)."
    Write-Host "기업 PC 는 대시보드 > 프로그램 업데이트 > $script:newVer [승인] 을 눌러야 받는다."
}
exit $exitCode
