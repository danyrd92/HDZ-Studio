Option Explicit
Dim shell, fs, appRoot, runtime
Set shell = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
appRoot = fs.GetParentFolderName(WScript.ScriptFullName)
runtime = shell.ExpandEnvironmentStrings("%ProgramW6432%") & "\PowerShell\7\pwsh.exe"
If Not fs.FileExists(runtime) Then runtime = shell.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
If Not fs.FileExists(runtime) Then WScript.Quit 2
If Not fs.FileExists(appRoot & "\HDZ-GUI.ps1") Then WScript.Quit 3
shell.CurrentDirectory = appRoot
shell.Run """" & runtime & """ -NoProfile -ExecutionPolicy Bypass -File """ & appRoot & "\HDZ-GUI.ps1""", 0, False
