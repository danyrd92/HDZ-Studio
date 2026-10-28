@echo off
REM ============================================================
REM  Instalar HDZ Studio  -  doble clic para dejar todo listo.
REM  Usa Windows PowerShell 5.1 (siempre presente) porque puede
REM  que PowerShell 7 aun no este instalado. Solo el requisito
REM  de PowerShell 7 solicita permisos si no esta instalado.
REM ============================================================
title Instalar HDZ Studio

REM La aplicacion se configura con el usuario actual. Solo PowerShell 7,
REM si falta, solicitara permisos de administrador para instalar su MSI.

echo.
echo  Instalando HDZ Studio. Esto puede tardar unos minutos
echo  (verificacion de herramientas incluidas). No cierres la ventana.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar-HDZStudio.ps1" -SkipContextMenu

echo.
pause
