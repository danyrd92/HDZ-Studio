@echo off
REM ============================================================
REM  Instalar HDZ Studio  -  doble clic para dejar todo listo.
REM  Usa Windows PowerShell 5.1 (siempre presente) porque puede
REM  que PowerShell 7 aun no este instalado. Se auto-eleva a
REM  administrador (necesario para instalar PowerShell 7).
REM ============================================================
title Instalar HDZ Studio

REM --- Comprobar privilegios de administrador ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de administrador...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo  Instalando HDZ Studio. Esto puede tardar unos minutos
echo  (descarga de herramientas). No cierres la ventana.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar-HDZStudio.ps1"

echo.
pause
