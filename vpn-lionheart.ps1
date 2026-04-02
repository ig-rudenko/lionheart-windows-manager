Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not $PSScriptRoot)
{
    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

$lionheartPath = Join-Path $PSScriptRoot "lionheart-windows-x64.exe"
$legacyLionheartPath = Join-Path $PSScriptRoot "lionheart-1.2-windows-x64.exe"
$tun2socksPath = Join-Path $PSScriptRoot "tun2socks-windows-amd64.exe"
$tun2socksZipPath = Join-Path $PSScriptRoot "tun2socks-windows-amd64.zip"
$wintunPath = Join-Path $PSScriptRoot "wintun.dll"
$appConfigPath = Join-Path $PSScriptRoot "vpn-lionheart-config.json"
$lionheartConfigPath = Join-Path $PSScriptRoot "config.json"
$lionheartDownloadUrl = "https://github.com/jaykaiperson/lionheart/releases/download/v1.2/lionheart-1.2-windows-x64.exe"
$tun2socksDownloadUrl = "https://github.com/xjasonlyu/tun2socks/releases/download/v2.6.0/tun2socks-windows-amd64.zip"
$wintunDownloadUrl = "https://github.com/ig-rudenko/lionheart-windows-manager/raw/refs/heads/master/extra/wintun.dll"

$global:lionheart = $null
$global:tun2socks = $null
$global:turnBypassIP = $null
$global:isConnected = $false
$global:pendingLogs = New-Object System.Collections.Generic.List[string]
$global:processLogState = @{}
$tunInterface = "wb-tun0"
$tunIP = "10.254.254.1"
$proxyPort = "1080"

function Invoke-UiAction
{
    param([scriptblock]$Action)

    if ($form -and -not $form.IsDisposed)
    {
        if ($form.InvokeRequired)
        {
            $form.BeginInvoke($Action) | Out-Null
        }
        else
        {
            & $Action
        }
    }
    else
    {
        & $Action
    }
}

function Add-Log
{
    param(
        [string]$Message,
        [string]$Source = "app"
    )

    if ([string]::IsNullOrWhiteSpace($Message))
    {
        return
    }

    $timestamp = Get-Date -Format "HH:mm:ss"
    $line = "[$timestamp][$Source] $Message"

    if ($logBox -and -not $logBox.IsDisposed)
    {
        Invoke-UiAction {
            $logBox.AppendText($line + [Environment]::NewLine)
            $logBox.SelectionStart = $logBox.TextLength
            $logBox.ScrollToCaret()
        }
    }
    else
    {
        $global:pendingLogs.Add($line) | Out-Null
    }
}

function Flush-PendingLogs
{
    if (-not $logBox)
    {
        return
    }

    foreach ($line in $global:pendingLogs)
    {
        $logBox.AppendText($line + [Environment]::NewLine)
    }

    $global:pendingLogs.Clear()
}

function Interface-Exists
{
    param($interface)
    return (netsh interface show interface | Select-String $interface)
}

function Get-LionheartBinaryPath
{
    if (Test-Path $lionheartPath)
    {
        return $lionheartPath
    }

    if (Test-Path $legacyLionheartPath)
    {
        return $legacyLionheartPath
    }

    return $lionheartPath
}

function Update-UiState
{
    param(
        [string]$State,
        [string]$Detail = ""
    )

    Invoke-UiAction {
        switch ($State)
        {
            "Disconnected" {
                $global:isConnected = $false
                $status.Text = "Offline"
                $status.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#d9485f")
                $statusDetail.Text = if ($Detail) { $Detail } else { "Ready to start the tunnel" }
                $btnToggle.Text = "Connect"
                $btnToggle.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#ff6b57")
                $btnToggle.Enabled = $true
            }
            "Connecting" {
                $status.Text = "Connecting"
                $status.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#f4b942")
                $statusDetail.Text = if ($Detail) { $Detail } else { "Preparing Lionheart and tun2socks" }
                $btnToggle.Text = "Connecting..."
                $btnToggle.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#f4b942")
                $btnToggle.Enabled = $false
            }
            "Connected" {
                $global:isConnected = $true
                $status.Text = "Connected"
                $status.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#38b46a")
                $statusDetail.Text = if ($Detail) { $Detail } else { "Tunnel active via 127.0.0.1:1080" }
                $btnToggle.Text = "Disconnect"
                $btnToggle.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#1f8f55")
                $btnToggle.Enabled = $true
            }
        }
    }
}

function Load-AppConfig
{
    if (Test-Path $appConfigPath)
    {
        try
        {
            return Get-Content $appConfigPath -Raw | ConvertFrom-Json
        }
        catch
        {
            return $null
        }
    }
}

function Download-File
{
    param(
        [string]$Url,
        [string]$DestinationPath
    )

    Add-Log "Downloading $Url" "download"
    Invoke-WebRequest -Uri $Url -OutFile $DestinationPath
}

function Expand-ArchiveFile
{
    param(
        [string]$ZipPath,
        [string]$DestinationPath
    )

    if (Test-Path $DestinationPath)
    {
        Remove-Item $DestinationPath -Recurse -Force
    }

    Expand-Archive -Path $ZipPath -DestinationPath $DestinationPath -Force
}

function Copy-FirstMatch
{
    param(
        [string]$SearchRoot,
        [string]$Pattern,
        [string]$DestinationPath
    )

    $match = Get-ChildItem -Path $SearchRoot -Recurse -File | Where-Object { $_.Name -eq $Pattern } | Select-Object -First 1
    if (-not $match)
    {
        throw "File $Pattern not found in archive"
    }

    Copy-Item -Path $match.FullName -Destination $DestinationPath -Force
}

function Ensure-LionheartBinary
{
    if (Test-Path (Get-LionheartBinaryPath))
    {
        return
    }

    Update-UiState -State "Connecting" -Detail "Downloading Lionheart"
    Download-File -Url $lionheartDownloadUrl -DestinationPath $lionheartPath
}

function Ensure-Tun2socksBinary
{
    if (Test-Path $tun2socksPath)
    {
        return
    }

    $extractDir = Join-Path $env:TEMP ("tun2socks-" + [guid]::NewGuid().ToString("N"))

    try
    {
        Update-UiState -State "Connecting" -Detail "Downloading tun2socks"
        Download-File -Url $tun2socksDownloadUrl -DestinationPath $tun2socksZipPath
        Expand-ArchiveFile -ZipPath $tun2socksZipPath -DestinationPath $extractDir
        Copy-FirstMatch -SearchRoot $extractDir -Pattern "tun2socks-windows-amd64.exe" -DestinationPath $tun2socksPath
    }
    finally
    {
        if (Test-Path $extractDir)
        {
            Remove-Item $extractDir -Recurse -Force
        }
        if (Test-Path $tun2socksZipPath)
        {
            Remove-Item $tun2socksZipPath -Force
        }
    }
}

function Ensure-WintunBinary
{
    if (Test-Path $wintunPath)
    {
        return
    }

    Update-UiState -State "Connecting" -Detail "Downloading Wintun"
    Download-File -Url $wintunDownloadUrl -DestinationPath $wintunPath
}

function Ensure-Dependencies
{
    try
    {
        Ensure-LionheartBinary
        Ensure-Tun2socksBinary
        Ensure-WintunBinary
    }
    catch
    {
        throw "Dependency download failed: $($_.Exception.Message)"
    }
}

function Save-AppConfig
{
    param([string]$smartKey)

    @{ smart_key = $smartKey } | ConvertTo-Json | Set-Content $appConfigPath
}

function ConvertFrom-SmartKey
{
    param([string]$smartKey)

    try
    {
        $padding = "=" * ((4 - $smartKey.Length % 4) % 4)
        $normalized = $smartKey.Replace("-", "+").Replace("_", "/") + $padding
        $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($normalized))
    }
    catch
    {
        throw "Invalid smart-key"
    }

    $parts = $decoded.Split("|", 2)
    if ($parts.Length -ne 2)
    {
        throw "Corrupted smart-key"
    }

    $peer = $parts[0]
    if (-not $peer.Contains(":"))
    {
        $peer = "$peer:8421"
    }

    return [PSCustomObject]@{
        Role = "client"
        ClientPeer = $peer
        Password = $parts[1]
    }
}

function Save-LionheartConfig
{
    param([string]$smartKey)

    $config = ConvertFrom-SmartKey -smartKey $smartKey
    $config | ConvertTo-Json | Set-Content $lionheartConfigPath
}

function Initialize-ProcessLog
{
    param([string]$Name)

    $stdoutPath = Join-Path $env:TEMP ("lionheart-gui-" + $Name + "-stdout.log")
    $stderrPath = Join-Path $env:TEMP ("lionheart-gui-" + $Name + "-stderr.log")
    Set-Content -Path $stdoutPath -Value $null -Encoding UTF8
    Set-Content -Path $stderrPath -Value $null -Encoding UTF8
    $global:processLogState[$Name] = @{
        StdoutPath = $stdoutPath
        StdoutPosition = 0L
        StderrPath = $stderrPath
        StderrPosition = 0L
    }
}

function Read-SharedFileChunk
{
    param(
        [string]$Path,
        [int64]$Position
    )

    if (-not (Test-Path $Path))
    {
        return @{
            Text = ""
            Position = $Position
        }
    }

    $fileStream = $null
    $reader = $null

    try
    {
        $fileStream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($Position -gt $fileStream.Length)
        {
            $Position = 0L
        }

        $fileStream.Seek($Position, [System.IO.SeekOrigin]::Begin) | Out-Null
        $reader = New-Object System.IO.StreamReader($fileStream, [System.Text.Encoding]::UTF8, $true)
        $text = $reader.ReadToEnd()
        $newPosition = $fileStream.Position

        return @{
            Text = $text
            Position = $newPosition
        }
    }
    finally
    {
        if ($reader)
        {
            $reader.Dispose()
        }
        elseif ($fileStream)
        {
            $fileStream.Dispose()
        }
    }
}

function Read-ProcessLogs
{
    foreach ($entry in $global:processLogState.GetEnumerator())
    {
        $name = $entry.Key
        $state = $entry.Value
        foreach ($stream in @(
            @{ Path = $state.StdoutPath; PositionKey = "StdoutPosition"; Source = $name },
            @{ Path = $state.StderrPath; PositionKey = "StderrPosition"; Source = "$name`:err" }
        ))
        {
            if (-not (Test-Path $stream.Path))
            {
                continue
            }

            try
            {
                $result = Read-SharedFileChunk -Path $stream.Path -Position ([int64]$state[$stream.PositionKey])
                $chunk = $result.Text
                $state[$stream.PositionKey] = [int64]$result.Position
                if (-not [string]::IsNullOrEmpty($chunk))
                {
                    $lines = $chunk -split "(`r`n|`n|`r)"
                    foreach ($line in $lines)
                    {
                        if (-not [string]::IsNullOrWhiteSpace($line))
                        {
                            Add-Log $line $stream.Source
                        }
                    }
                }
            }
            catch
            {
            }
        }
    }
}

function Start-LoggedProcess
{
    param(
        [string]$Name,
        [string]$FilePath,
        [string]$Arguments = ""
    )

    Initialize-ProcessLog -Name $Name
    $logState = $global:processLogState[$Name]
    $startProcessParams = @{
        FilePath = $FilePath
        WorkingDirectory = $PSScriptRoot
        PassThru = $true
        WindowStyle = "Hidden"
        RedirectStandardOutput = $logState.StdoutPath
        RedirectStandardError = $logState.StderrPath
    }
    if (-not [string]::IsNullOrWhiteSpace($Arguments))
    {
        $startProcessParams.ArgumentList = $Arguments
    }

    $process = Start-Process @startProcessParams

    Add-Log "Started $Name (PID $($process.Id))" $Name
    return $process
}

function Stop-LoggedProcess
{
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Name
    )

    if (-not $Process)
    {
        return
    }

    try
    {
        if (-not $Process.HasExited)
        {
            Add-Log "Stopping $Name" "app"
            $Process.Kill()
            $Process.WaitForExit(3000) | Out-Null
        }
    }
    catch
    {
        Add-Log "Failed to stop ${Name}: $($_.Exception.Message)" "app"
    }
    finally
    {
        $Process.Dispose()
    }
}

function Wait-ForSocksProxy
{
    param(
        [string]$ProxyHost = "127.0.0.1",
        [int]$Port = 1080,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline)
    {
        if ($global:lionheart -and $global:lionheart.HasExited)
        {
            return $false
        }

        try
        {
            $client = New-Object System.Net.Sockets.TcpClient
            $async = $client.BeginConnect($ProxyHost, $Port, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(500))
            {
                $client.EndConnect($async)
                $client.Close()
                return $true
            }
            $client.Close()
        }
        catch
        {
        }

        Start-Sleep -Milliseconds 300
    }

    return $false
}

function Start-Tunnel
{
    param([string]$smartKey)

    if ($global:lionheart -or $global:tun2socks)
    {
        [System.Windows.Forms.MessageBox]::Show("Tunnel already running")
        return
    }

    if ([string]::IsNullOrWhiteSpace($smartKey))
    {
        [System.Windows.Forms.MessageBox]::Show("Enter smart-key")
        return
    }

    Add-Log "Starting tunnel" "app"

    try
    {
        Ensure-Dependencies
    }
    catch
    {
        Update-UiState -State "Disconnected" -Detail "Dependency download failed"
        Add-Log $_.Exception.Message "app"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message)
        return
    }

    try
    {
        Save-LionheartConfig -smartKey $smartKey
        Save-AppConfig -smartKey $smartKey
        Add-Log "Client config saved" "app"
    }
    catch
    {
        Add-Log $_.Exception.Message "app"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message)
        return
    }

    try
    {
        Update-UiState -State "Connecting" -Detail "Launching Lionheart client"
        $global:lionheart = Start-LoggedProcess -Name "lionheart" -FilePath (Get-LionheartBinaryPath)
    }
    catch
    {
        Add-Log "lionheart start error: $($_.Exception.Message)" "app"
        [System.Windows.Forms.MessageBox]::Show("lionheart start error: $_")
        return
    }

    if (-not (Wait-ForSocksProxy))
    {
        Add-Log "lionheart did not open SOCKS5 on 127.0.0.1:1080" "app"
        [System.Windows.Forms.MessageBox]::Show("lionheart did not open SOCKS5 on 127.0.0.1:1080")
        Stop-Tunnel
        return
    }

    Add-Log "SOCKS5 proxy detected on 127.0.0.1:1080" "app"

    try
    {
        Update-UiState -State "Connecting" -Detail "SOCKS5 is ready, starting tun2socks"
        $args = "--device tun://$tunInterface --proxy socks5://127.0.0.1:$proxyPort"
        $global:tun2socks = Start-LoggedProcess -Name "tun2socks" -FilePath $tun2socksPath -Arguments $args
    }
    catch
    {
        Add-Log "tun2socks start error: $($_.Exception.Message)" "app"
        [System.Windows.Forms.MessageBox]::Show("tun2socks start error: $_")
        Stop-Tunnel
        return
    }

    Start-Sleep 2

    if (-not (Interface-Exists $tunInterface))
    {
        Add-Log "Interface $tunInterface was not created" "app"
        [System.Windows.Forms.MessageBox]::Show("Interface $tunInterface not created!")
        Stop-Tunnel
        return
    }

    $mask = "255.255.255.255"
    $ipCmd = "netsh interface ip set address name=`"$tunInterface`" static $tunIP $mask"
    Invoke-Expression $ipCmd
    Add-Log "Assigned IP $tunIP to $tunInterface" "app"

    $ifIndex = (Get-NetAdapter | Where-Object { $_.Name -eq $tunInterface }).ifIndex
    if (-not $ifIndex)
    {
        Add-Log "Failed to resolve interface index for $tunInterface" "app"
        [System.Windows.Forms.MessageBox]::Show("Interface index error")
        Stop-Tunnel
        return
    }

    try
    {
        $turnServer = "wb-stream-turn-1.wb.ru"
        $turnIP = (Resolve-DnsName $turnServer -Type A | Select-Object -First 1).IPAddress
        $global:turnBypassIP = $turnIP
        $gateway = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric | Select-Object -First 1).NextHop
        route add $turnIP mask 255.255.255.255 $gateway | Out-Null
        Add-Log "Added bypass route for $turnServer ($turnIP)" "app"
    }
    catch
    {
        Add-Log "Failed to add bypass route for WB TURN" "app"
    }

    netsh interface ipv4 delete route 0.0.0.0/0 $ifIndex 2> $null | Out-Null
    $routeCmd = "netsh interface ipv4 add route 0.0.0.0/0 $ifIndex $tunIP metric=1"
    Invoke-Expression $routeCmd | Out-Null
    Add-Log "Default route redirected through $tunInterface" "app"

    Update-UiState -State "Connected" -Detail "Tunnel active via 127.0.0.1:1080"
}

function Stop-Tunnel
{
    Add-Log "Stopping tunnel" "app"

    if ($global:turnBypassIP)
    {
        try
        {
            route delete $global:turnBypassIP | Out-Null
            Add-Log "Removed bypass route for $global:turnBypassIP" "app"
        }
        catch
        {
            Add-Log "Failed to remove bypass route for $global:turnBypassIP" "app"
        }
        $global:turnBypassIP = $null
    }

    Stop-LoggedProcess -Process $global:tun2socks -Name "tun2socks"
    $global:tun2socks = $null

    Stop-LoggedProcess -Process $global:lionheart -Name "lionheart"
    $global:lionheart = $null

    $global:processLogState.Clear()

    Update-UiState -State "Disconnected" -Detail "Tunnel is stopped"
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Lionheart VPN"
$form.Size = New-Object System.Drawing.Size(720, 620)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#10151d")
$config = Load-AppConfig

$title = New-Object System.Windows.Forms.Label
$title.Text = "Lionheart"
$title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 18)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(28, 22)
$title.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#f3f5f7")

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "Wildberries proxy + tun2socks launcher"
$subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$subtitle.AutoSize = $true
$subtitle.Location = New-Object System.Drawing.Point(31, 56)
$subtitle.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#8b97a8")

$statusCard = New-Object System.Windows.Forms.Panel
$statusCard.Location = New-Object System.Drawing.Point(28, 92)
$statusCard.Size = New-Object System.Drawing.Size(660, 72)
$statusCard.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#171f2b")

$status = New-Object System.Windows.Forms.Label
$status.Text = "Offline"
$status.AutoSize = $true
$status.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 15)
$status.Location = New-Object System.Drawing.Point(18, 12)
$status.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#d9485f")

$statusDetail = New-Object System.Windows.Forms.Label
$statusDetail.Text = "Ready to start the tunnel"
$statusDetail.AutoSize = $true
$statusDetail.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$statusDetail.Location = New-Object System.Drawing.Point(20, 42)
$statusDetail.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#8b97a8")

$statusCard.Controls.Add($status)
$statusCard.Controls.Add($statusDetail)

$lblSmartKey = New-Object System.Windows.Forms.Label
$lblSmartKey.Text = "Smart-key"
$lblSmartKey.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$lblSmartKey.AutoSize = $true
$lblSmartKey.Location = New-Object System.Drawing.Point(30, 182)
$lblSmartKey.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#d9dee7")

$txtSmartKey = New-Object System.Windows.Forms.TextBox
$txtSmartKey.Location = New-Object System.Drawing.Point(30, 208)
$txtSmartKey.Size = New-Object System.Drawing.Size(592, 32)
$txtSmartKey.Multiline = $false
$txtSmartKey.BorderStyle = "FixedSingle"
$txtSmartKey.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#0f141b")
$txtSmartKey.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#f3f5f7")
$txtSmartKey.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$txtSmartKey.UseSystemPasswordChar = $true
$txtSmartKey.Text = if ($config) { $config.smart_key } else { "" }

$btnReveal = New-Object System.Windows.Forms.Button
$btnReveal.Text = "Show"
$btnReveal.Size = New-Object System.Drawing.Size(66, 32)
$btnReveal.Location = New-Object System.Drawing.Point(628, 208)
$btnReveal.FlatStyle = "Flat"
$btnReveal.FlatAppearance.BorderSize = 0
$btnReveal.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#273244")
$btnReveal.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#f3f5f7")
$btnReveal.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
$btnReveal.Add_Click({
    $txtSmartKey.UseSystemPasswordChar = -not $txtSmartKey.UseSystemPasswordChar
    $btnReveal.Text = if ($txtSmartKey.UseSystemPasswordChar) { "Show" } else { "Hide" }
})

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "The smart-key is stored locally and reused on the next launch."
$hint.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$hint.AutoSize = $true
$hint.Location = New-Object System.Drawing.Point(31, 246)
$hint.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#6f7c8f")

$btnToggle = New-Object System.Windows.Forms.Button
$btnToggle.Text = "Connect"
$btnToggle.Size = New-Object System.Drawing.Size(660, 42)
$btnToggle.Location = New-Object System.Drawing.Point(28, 274)
$btnToggle.FlatStyle = "Flat"
$btnToggle.FlatAppearance.BorderSize = 0
$btnToggle.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#ff6b57")
$btnToggle.ForeColor = [System.Drawing.Color]::White
$btnToggle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 11)
$btnToggle.Add_Click({
    if ($global:isConnected)
    {
        Stop-Tunnel
    }
    else
    {
        Start-Tunnel -smartKey $txtSmartKey.Text.Trim()
    }
})

$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = "Logs"
$logLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$logLabel.AutoSize = $true
$logLabel.Location = New-Object System.Drawing.Point(30, 332)
$logLabel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#d9dee7")

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(30, 358)
$logBox.Size = New-Object System.Drawing.Size(658, 210)
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = "Vertical"
$logBox.BorderStyle = "FixedSingle"
$logBox.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#0f141b")
$logBox.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#c9d2de")
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)

$logTimer = New-Object System.Windows.Forms.Timer
$logTimer.Interval = 400
$logTimer.Add_Tick({
    Read-ProcessLogs
})
$logTimer.Start()

$form.Controls.Add($title)
$form.Controls.Add($subtitle)
$form.Controls.Add($statusCard)
$form.Controls.Add($lblSmartKey)
$form.Controls.Add($txtSmartKey)
$form.Controls.Add($btnReveal)
$form.Controls.Add($hint)
$form.Controls.Add($btnToggle)
$form.Controls.Add($logLabel)
$form.Controls.Add($logBox)

$form.Add_Shown({
    Flush-PendingLogs
    Add-Log "GUI ready" "app"
})

$form.Add_FormClosing({
    $logTimer.Stop()
    Stop-Tunnel
})

Update-UiState -State "Disconnected"
$form.ShowDialog()
