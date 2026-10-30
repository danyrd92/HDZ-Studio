# HDZ Studio

Aplicación de escritorio para Windows que prepara releases de vídeo de principio a fin:
remux a MKV, selección de pistas de audio y subtítulos por idioma, fusión Dolby Vision/HDR10,
capturas, creación de torrents privados y subida al tracker, todo desde una interfaz gráfica
y sin preguntas en consola.

## Instalación

1. Descarga `HDZStudio-Setup-<versión>.exe` de la [última release](../../releases/latest).
2. Ejecútalo. Se instala en tu carpeta de usuario y no necesita permisos de administrador.
   Si falta PowerShell 7, el instalador lo instala desde el MSI incluido.

Las herramientas audiovisuales (ffmpeg, MKVToolNix, MediaInfo, dovi_tool) van incluidas y se
verifican con SHA256. Se publican aparte en la release [`herramientas`](../../releases/tag/herramientas).

## Actualizaciones

El botón de actualizar aparece junto a la versión cuando hay una release nueva. El programa
descarga el paquete de GitHub Releases, comprueba la **firma RSA** del manifiesto y el SHA256
de cada archivo, guarda una copia de seguridad y revierte si algo falla.

## Control desde el móvil

En **Ajustes › Control remoto** puedes permitir que otros dispositivos de tu red controlen
HDZ Studio:

1. Activa la opción. Se muestra la dirección (`http://192.168.x.x:8787`) y un código.
2. Abre la dirección en el móvil e introduce el código una sola vez.

Funciona sin servidores externos. En la red local el tráfico no va cifrado; para usarlo fuera
de casa, conecta el PC y el móvil con [Tailscale](https://tailscale.com) u otra VPN propia.

## Problemas

**Ajustes › Reportar un problema** guarda una copia del último log con las claves censuradas
y abre una [incidencia](../../issues/new). Revisa el log antes de adjuntarlo: la incidencia es pública.

## Desarrollo

- `HDZ-GUI.ps1`: interfaz WPF. `HDZnew.ps1`: motor de montaje, que la interfaz lanza como
  proceso aparte con la configuración en `HDZ_CONFIG`.
- `HDZ-Remote.ps1`: servidor local de la web remota (`web/index.html`).
- `instalacion/`: instalador, actualizador y `Preparar-Release.ps1`.

Pruebas:

```powershell
pwsh -NoProfile -File soporte/tests/Run-All.ps1
```

Las pruebas web necesitan Node y Playwright (`HDZ_PLAYWRIGHT` apunta a su carpeta si no está
instalado globalmente).

## Historial de versiones

Las versiones v1.0 a v1.22 corresponden a las publicaciones internas 1.17.16 a 1.17.38.
