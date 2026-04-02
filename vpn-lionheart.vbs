Set shellApp = CreateObject("Shell.Application")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File """ & scriptDir & "\vpn-lionheart.ps1"""
shellApp.ShellExecute "powershell.exe", args, scriptDir, "runas", 0
