Option Explicit

Dim sh, fso, pwsh, scriptPath, commandLine
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptPath = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "Capturas-MenuContextual.ps1")
If Not fso.FileExists(scriptPath) Then
    ' La extension moderna puede ejecutar una copia del lanzador desde la
    ' carpeta del paquete; recuperamos la carpeta real de HDZ.
    On Error Resume Next
    scriptPath = fso.BuildPath(sh.RegRead("HKCU\Software\HDZEROStudio\ContextMenu\InstallPath"), "Capturas-MenuContextual.ps1")
    If Err.Number <> 0 Then
        Err.Clear
        scriptPath = fso.BuildPath(sh.RegRead("HKLM\SOFTWARE\HDZEROStudio\ContextMenu\InstallPath"), "Capturas-MenuContextual.ps1")
    End If
    On Error GoTo 0
End If
pwsh = sh.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
If Not fso.FileExists(pwsh) Then pwsh = "pwsh.exe"

If WScript.Arguments.Count = 0 Then WScript.Quit 1
If Not fso.FileExists(scriptPath) Then WScript.Quit 2
commandLine = QuoteArg(pwsh) & " -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File " & QuoteArg(scriptPath)
Dim selectedVideo
' Procesar la selección completa en orden, sin abrir varios trabajos a la vez.
For Each selectedVideo In WScript.Arguments
    sh.Run commandLine & " -Video " & QuoteArg(selectedVideo), 0, True
Next

Function QuoteArg(value)
    QuoteArg = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
