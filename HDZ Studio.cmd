@echo off
rem Lanzador de HDZ Studio (doble clic). Requiere PowerShell 7 (pwsh).
rem Delega en el .vbs para arrancar la GUI OCULTA (sin ventana de consola).
where pwsh >nul 2>nul
if errorlevel 1 (
    echo Se necesita PowerShell 7. Instalalo con:  winget install Microsoft.PowerShell
    pause
    exit /b 1
)
start "" wscript.exe "%~dp0HDZ Studio.vbs"
