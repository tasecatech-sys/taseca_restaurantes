@echo off
title Taseca - acceso directo de la estacion de comandas
echo.
echo   TASECA - Estacion de comandas
echo   Crea en el escritorio el acceso "Taseca Comandas", que abre el panel
echo   en una ventana de Chrome que imprime directo, sin la ventana de impresion.
echo.

set "CHROME="
if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" set "CHROME=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not defined CHROME if exist "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" set "CHROME=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
if not defined CHROME if exist "%LocalAppData%\Google\Chrome\Application\chrome.exe" set "CHROME=%LocalAppData%\Google\Chrome\Application\chrome.exe"
if not defined CHROME (
  echo   No encontre Google Chrome en este equipo. Instalalo y vuelve a abrir este archivo.
  echo.
  pause
  exit /b 1
)

echo   Pega el enlace del panel del restaurante (clic derecho para pegar).
echo   Ejemplo: https://restaurante.taseca.tech/taseca/NOMBRE-DEL-RESTAURANTE/panel
echo.
set "URL="
set /p "URL=  Enlace: "
if not defined URL (
  echo.
  echo   No escribiste el enlace. Vuelve a abrir este archivo.
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$q=[char]34; $d=[Environment]::GetFolderPath('Desktop'); $f=Join-Path $d 'Taseca Comandas.lnk'; $s=(New-Object -ComObject WScript.Shell).CreateShortcut($f); $s.TargetPath=$env:CHROME; $s.Arguments='--kiosk-printing --user-data-dir='+$q+$env:LOCALAPPDATA+'\TasecaComandas'+$q+' --no-first-run --app='+$env:URL.Trim(); $s.WorkingDirectory=Split-Path $env:CHROME; $s.IconLocation=$env:CHROME+',0'; $s.Description='Estacion de comandas Taseca (imprime sin ventana)'; $s.Save(); Write-Host ''; Write-Host ('  Listo: ' + $f)"

echo.
echo   Ahora:
echo   1. Abre "Taseca Comandas" desde el escritorio e inicia sesion.
echo   2. Caja - Cocina - toca "Este equipo imprime las comandas".
echo   3. Toca "Imprimir una prueba": debe salir sin ninguna ventana.
echo.
pause
