@echo off
REM Busca y aplica actualizaciones de HDZ Studio desde GitHub.
title Actualizar HDZ Studio

REM Si no somos administrador, relanzamos este mismo .cmd ELEVADO (para poder
REM sobrescribir los ficheros aunque el programa este en "Archivos de programa").
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Actualizar-HDZStudio.ps1"
echo.
pause
