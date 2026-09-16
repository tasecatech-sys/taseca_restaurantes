@echo off
chcp 65001 >nul
title NASCAR - Servidor local
cd /d "%~dp0"

echo.
echo   ================================================
echo      NASCAR  -  Restaurante
echo   ================================================
echo.
echo   Iniciando servidor local...
echo.
echo      Pagina publica  ->  http://localhost:8000/
echo      Panel interno   ->  http://localhost:8000/empleados.html
echo      Mesa 1 (Norte)  ->  http://localhost:8000/mesa.html?suc=1^&mesa=1
echo.
echo   Para detener el servidor: cierra esta ventana o pulsa Ctrl+C
echo.

start "" http://localhost:8000/

py -m http.server 8000 2>nul
if errorlevel 1 (
  python -m http.server 8000 2>nul
)
if errorlevel 1 (
  echo.
  echo   No se encontro Python en este equipo.
  echo   Puedes abrir index.html directamente con doble clic:
  echo   la pagina funciona igual sin servidor.
  echo.
  pause
)
