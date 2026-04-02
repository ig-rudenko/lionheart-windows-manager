$ErrorActionPreference = "Stop"

$repoBase = "https://github.com/ig-rudenko/lionheart-windows-manager/raw/refs/heads/master"
$installDir = Join-Path $env:USERPROFILE "lionheart"

New-Item -ItemType Directory -Force -Path $installDir | Out-Null

$files = @(
    "vpn-lionheart.ps1",
    "vpn-lionheart.bat"
)

foreach ($file in $files)
{
    Invoke-WebRequest -Uri "$repoBase/$file" -OutFile (Join-Path $installDir $file)
}

Start-Process -FilePath (Join-Path $installDir "vpn-lionheart.bat") -WorkingDirectory $installDir -Verb RunAs
