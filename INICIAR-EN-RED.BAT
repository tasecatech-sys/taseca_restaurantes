@echo off
chcp 65001 >nul
title NASCAR - Servidor en red local (para celulares)
cd /d "%~dp0"

echo.
echo   ================================================
echo      NASCAR  -  Servidor en red local
echo   ================================================
echo.
echo   Buscando la direccion de este computador...
echo.

for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 ^| Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.PrefixOrigin -ne 'WellKnown' } ^| Sort-Object -Property InterfaceMetric ^| Select-Object -First 1).IPAddress"`) do set IP=%%i

if "%IP%"=="" (
  echo   No se pudo detectar la direccion IP.
  echo   Revisa que el computador este conectado a una red Wi-Fi.
  echo.
  pause
  exit /b
)

echo   Direccion de este computador: %IP%
echo.
echo   ------------------------------------------------
echo   DESDE EL CELULAR, conectado a la MISMA red Wi-Fi,
echo   abre el navegador y escribe:
echo.
echo       http://%IP%:8000/
echo.
echo   Otras pantallas:
echo       http://%IP%:8000/empleados.html         (panel)
echo       http://%IP%:8000/mesa.html?suc=1^&mesa=1
echo   ------------------------------------------------
echo.
echo   Si el celular no abre la pagina, es el Firewall de
echo   Windows: acepta el aviso que aparece al iniciar, o
echo   permite Python en redes privadas.
echo.
echo   Para detener: cierra esta ventana o pulsa Ctrl+C
echo.

start "" http://localhost:8000/

py -m http.server 8000 --bind 0.0.0.0 2>nul
if errorlevel 1 (
  python -m http.server 8000 --bind 0.0.0.0 2>nul
)
if errorlevel 1 (
  echo.
  echo   No se encontro Python en este equipo.
  echo.
  pause
)
