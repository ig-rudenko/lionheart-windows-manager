$ErrorActionPreference = "Stop"

$repoBase = "https://github.com/ig-rudenko/lionheart-windows-manager/raw/refs/heads/master"
$installDir = Join-Path $env:USERPROFILE "lionheart"
$desktopPath = [Environment]::GetFolderPath("Desktop")
$shortcutPath = Join-Path $desktopPath "Lionheart VPN.lnk"

New-Item -ItemType Directory -Force -Path $installDir | Out-Null

$files = @(
    "vpn-lionheart.ps1",
    "vpn-lionheart.bat",
    "vpn-lionheart.vbs"
)

foreach ($file in $files)
{
    Invoke-WebRequest -Uri "$repoBase/$file" -OutFile (Join-Path $installDir $file)
}

Write-Host ""
Write-Host "Lionheart installed to: $installDir" -ForegroundColor Green
Write-Host "The launcher requires administrator rights." -ForegroundColor Yellow
Write-Host "The PowerShell and BAT launchers require administrator rights." -ForegroundColor Yellow
Write-Host "The VBS launcher starts the GUI without a visible terminal window." -ForegroundColor Yellow

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $installDir "vpn-lionheart.vbs"
$shortcut.WorkingDirectory = $installDir
$shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,220"
$shortcut.Description = "Launch Lionheart VPN without a terminal window"
$shortcut.Save()

Write-Host "Desktop shortcut created: $shortcutPath" -ForegroundColor Green
Write-Host ""
Write-Host "How to use:" -ForegroundColor Cyan
Write-Host "1. Start 'Lionheart VPN' from the desktop shortcut, or run vpn-lionheart.vbs from $installDir"
Write-Host "2. Approve the UAC prompt"
Write-Host "3. Paste your smart-key and press Connect"
Write-Host ""
