<#
    AHK2ManagerEx 构建脚本

    工具链（都放在项目内，避免依赖具体机器）：
      - 编译器：<仓库>\tools\Compiler\Ahk2Exe.exe   （可用环境变量 AHK2EXE 覆盖）
      - 基准文件：<仓库>\tools\AutoHotkey64.exe      （可用环境变量 AHK_BASE_X64 覆盖）

      本机没有 Ahk2Exe 时，在仓库根目录执行（用 curl.exe；代理环境下 Invoke-WebRequest 会失败）：
        curl.exe -L --fail -o tools\Ahk2Exe.zip https://github.com/AutoHotkey/Ahk2Exe/releases/download/Ahk2Exe1.1.37.02a2/Ahk2Exe1.1.37.02a2.zip
        Expand-Archive tools\Ahk2Exe.zip -DestinationPath tools\Compiler -Force

    用法（一般由 npm script 调用）：
      .\build.ps1 <version> prod    <appname>   # 编译到 build\ 并打包 zip + 校验和
      .\build.ps1 <version> dev     <appname>   # 编译到 test\，本地验证
      .\build.ps1 <version> version <appname>   # 只把版本号写进源码的 @Ahk2Exe-SetVersion
#>

Import-Module Microsoft.PowerShell.Utility
$ErrorActionPreference = 'Stop'

$cwd = (Get-Location).Path
$version = $args[0]
$envName = $args[1]
$appname = $args[2]
$setversion = ";@Ahk2Exe-SetVersion " + $version
$zipname = $appname

Write-Host "App:" $appname
Write-Host "Version:" $version
Write-Host "Environment:" $envName

function Resolve-FirstExisting {
    param([string]$Label, [string[]]$Candidates)
    foreach ($p in $Candidates) {
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) {
            return (Get-Item -LiteralPath $p).FullName
        }
    }
    throw ("$Label 未找到，已尝试：`n  " + (($Candidates | Where-Object { $_ }) -join "`n  "))
}

# ---------- 定位工具链 ----------
$ahk2exe = Resolve-FirstExisting -Label 'Ahk2Exe.exe' -Candidates @(
    $env:AHK2EXE,
    "$cwd\tools\Compiler\Ahk2Exe.exe",
    "$cwd\tools\Ahk2Exe.exe",
    "$env:ProgramFiles\AutoHotkey\Compiler\Ahk2Exe.exe",
    "${env:ProgramFiles(x86)}\AutoHotkey\Compiler\Ahk2Exe.exe"
)

$baseX64 = Resolve-FirstExisting -Label 'x64 基准文件 AutoHotkey64.exe' -Candidates @(
    $env:AHK_BASE_X64,
    "$cwd\tools\AutoHotkey64.exe",
    "$cwd\tools\Compiler\AutoHotkey64.exe",
    "$env:ProgramFiles\AutoHotkey\AutoHotkey64.exe",
    "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
    "${env:ProgramFiles(x86)}\AutoHotkey\AutoHotkey64.exe"
)

Write-Host "Ahk2Exe:  " $ahk2exe
Write-Host "Base x64:" $baseX64

# ---------- 写入版本号 ----------
# 必须显式按 UTF-8 读写：Windows PowerShell 5.1 的 Set-Content 默认走 ANSI，
# 会把源码里的中文注释写成乱码。
function Set-SourceVersion {
    param([string]$Pattern, [string]$Replacement)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    foreach ($file in (Get-ChildItem -Path $Pattern -File)) {
        $text = [System.IO.File]::ReadAllText($file.FullName, $utf8)
        $new = [regex]::Replace($text, ';@Ahk2Exe-SetVersion [0-9]+\.[0-9]+\.[0-9]+', $Replacement)
        if ($new -ne $text) {
            [System.IO.File]::WriteAllText($file.FullName, $new, $utf8)
            Write-Host ("  版本号已更新:" + $file.Name)
        }
    }
}

function Wait-ForFile {
    param([string]$Path, [int]$TimeoutSec = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (!(Test-Path -LiteralPath $Path)) {
        if ((Get-Date) -gt $deadline) { return $false }
        Start-Sleep -Milliseconds 300
    }
    return $true
}

# ---------- 编译 ----------
function Invoke-Compile {
    param([string]$OutDir, [string]$OutSuffix)
    if (!(Test-Path -Path $OutDir)) {
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    }
    # 只编译项目自身的脚本：忽略以 "." 开头的临时文件，
    # 否则根目录随便丢一个 .ahk 探针就会一起编译，其中一个写错就会让整个构建失败
    foreach ($file in (Get-ChildItem -Path "$cwd\*.ahk" -File | Where-Object { $_.Name -notlike '.*' })) {
        $outExe = Join-Path $OutDir ($file.BaseName + $OutSuffix + ".exe")
        if (Test-Path -LiteralPath $outExe) {
            # 用 .NET 删除：Remove-Item 在受限环境（沙箱、或被安全软件接管删除）下会失败
            [System.IO.File]::Delete($outExe)
        }
        Write-Host ("编译:" + $file.Name + " -> " + (Split-Path $outExe -Leaf))
        $compileArgs = @('/silent', 'verbose', '/base', $baseX64, '/out', $outExe, '/in', $file.FullName)

        # 不用 -NoNewWindow / -Redirect*：它们会让 Start-Process 去构建子进程环境块，
        # 一旦本机同时存在 PATH 与 Path 两个变量就会直接抛 ArgumentException。
        try {
            Start-Process -FilePath $ahk2exe -Wait -ArgumentList $compileArgs | Out-Null
        }
        catch {
            Write-Warning ("Start-Process 不可用（" + $_.Exception.Message + "），改用调用运算符重试")
            & $ahk2exe @compileArgs | Out-Null
        }

        if (!(Wait-ForFile -Path $outExe)) {
            throw ("编译失败，没有生成 " + $outExe + "`n手工执行下面这行可以看到 Ahk2Exe 的完整报错：`n  " + $ahk2exe + " /base `"$baseX64`" /out `"$outExe`" /in `"$($file.FullName)`"")
        }
        Write-Host ("  -> " + $outExe + "  " + (Get-Item -LiteralPath $outExe).Length + " bytes")
    }
}

if ($envName -eq 'version') {
    Set-SourceVersion -Pattern "$cwd\*.ahk" -Replacement $setversion
}

if ($envName -eq 'prod') {
    Set-SourceVersion -Pattern "$cwd\*.ahk" -Replacement $setversion

    Invoke-Compile -OutDir "$cwd\build" -OutSuffix ""

    $zip = "$cwd\build\$zipname.zip"
    if (Test-Path -LiteralPath $zip) {
        [System.IO.File]::Delete($zip)
    }
    try {
        Compress-Archive -Path "$cwd\build\$appname.exe" -DestinationPath $zip
    }
    catch {
        Write-Warning ("Compress-Archive 不可用（" + $_.Exception.Message + "），改用系统自带的 tar.exe")
    }
    if (!(Test-Path -LiteralPath $zip)) {
        # 退回 tar：Windows 10 1803+ 自带，-a 会按扩展名自动选择 zip 格式
        $exe = Get-ChildItem "$cwd\build\$appname.exe" -File | Select-Object -First 1
        & tar.exe -a -cf $zip -C "$cwd\build" $exe.Name
    }
    if (!(Test-Path -LiteralPath $zip)) {
        throw ("打包失败，" + $zip + " 没有生成")
    }
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    ("$hash  $zipname.zip") | Set-Content -LiteralPath "$cwd\build\checksums.txt" -Encoding ascii
    Write-Host ("打包完成:" + $zip)
}

if ($envName -eq 'dev') {
    Invoke-Compile -OutDir "$cwd\test" -OutSuffix ""
}
