#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
NASCAR · Generador de la version de un solo archivo
====================================================

Toma index.html, mesa.html, empleados.html, el CSS y los JS, y los mete todos
dentro de un unico archivo: NASCAR-movil.html

Ese archivo se puede mandar por WhatsApp o correo y abrirlo en el celular
con doble toque: no necesita las carpetas css/ ni js/.

Uso:
    py build-movil.py

Hay que volver a ejecutarlo cada vez que se cambie algo en los archivos
originales (por ejemplo, los precios en js/data.js).
"""

import re
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent
SALIDA = RAIZ / "NASCAR-movil.html"

# El orden importa. admin.js usa Auth, Inventario, Gestion y Operacion,
# así que todos esos van antes que él. menu-dia.js lo usan app, mesa y
# operacion: va justo después de ui.js.
SCRIPTS = ["js/data.js", "js/store.js", "js/remoto.js", "js/ui.js", "js/menu-dia.js", "js/auth.js",
           "js/inventario.js", "js/gestion.js", "js/operacion.js",
           "js/gastos.js", "js/informe.js",
           "js/sidebar.js",
           "js/tema.js",
           "js/avisos.js",
           "js/app.js", "js/mesa.js", "js/admin.js"]

PAGINAS = [("index.html", "publico", "Pedir"),
           ("mesa.html", "mesa", "Mesa"),
           ("cierre.html", "cierre", "Cierre"),
           ("empleados.html", "panel", "Panel")]


def leer(rel: str) -> str:
    ruta = RAIZ / rel
    if not ruta.exists():
        sys.exit(f"ERROR: falta el archivo {rel}")
    return ruta.read_text(encoding="utf-8")


def cuerpo(html: str) -> str:
    """Devuelve el contenido de <body>, sin las etiquetas <script src=...>."""
    m = re.search(r"<body[^>]*>(.*)</body>", html, re.S | re.I)
    if not m:
        sys.exit("ERROR: no se encontro <body>")
    txt = m.group(1)
    txt = re.sub(r'\s*<script\s+src="[^"]*"\s*></script>', "", txt, flags=re.I)
    return txt.strip()


def reescribir_enlaces(html: str) -> str:
    """Los enlaces entre archivos pasan a ser enlaces internos (#)."""
    # mesa.html?suc=1&mesa=3  ->  #mesa/1/3
    html = re.sub(r'href="mesa\.html\?suc=(\d+)&(?:amp;)?mesa=([^"]+)"',
                  r'href="#mesa/\1/\2"', html, flags=re.I)
    html = re.sub(r'href="mesa\.html"', 'href="#mesa"', html, flags=re.I)
    html = re.sub(r'href="empleados\.html"', 'href="#panel"', html, flags=re.I)
    html = re.sub(r'href="index\.html"', 'href="#publico"', html, flags=re.I)
    html = re.sub(r'href="cierre\.html"', 'href="#cierre"', html, flags=re.I)

    # Abrir en pestaña nueva no tiene sentido si el destino es otra vista
    # del mismo archivo: se quita target/rel a los enlaces internos.
    def limpiar_ancla(m):
        tag = m.group(0)
        if 'href="#' not in tag:
            return tag
        tag = re.sub(r'\s+target="_blank"', "", tag, flags=re.I)
        tag = re.sub(r'\s+rel="noopener"', "", tag, flags=re.I)
        return tag

    return re.sub(r"<a\b[^>]*>", limpiar_ancla, html, flags=re.I)


CSS_EXTRA = """
/* ===== Version de un solo archivo: conmutador de pantallas ===== */
.vista { display: none; }
.vista.is-activa { display: block; }

.cambia-vista {
  display: flex;
  background: var(--negro-800);
  border-bottom: 1px solid var(--borde);
}
.cambia-vista button {
  flex: 1;
  padding: 12px 6px 10px;
  border: 0;
  border-bottom: 3px solid transparent;
  background: transparent;
  color: var(--gris);
  font-family: var(--f-cond);
  font-size: 14px;
  font-weight: 700;
  letter-spacing: 0.12em;
  text-transform: uppercase;
  cursor: pointer;
  transition: color 150ms, border-color 150ms;
}
.cambia-vista button:hover { color: var(--blanco); }
.cambia-vista button.is-activa {
  color: var(--blanco);
  border-bottom-color: var(--rojo);
}
.cambia-vista button i {
  display: block;
  font-style: normal;
  font-size: 17px;
  margin-bottom: 1px;
}
"""

ROUTER_JS = """
/* ===== Version de un solo archivo: enrutador por # =====
   #publico (por defecto) | #mesa | #mesa/1/5 | #panel            */
(function () {
  'use strict';

  var VISTAS = { publico: 'NASCAR \\u00b7 Restaurante',
                 mesa:    'NASCAR \\u00b7 Pedido de mesa',
                 cierre:  'NASCAR \\u00b7 Cierre de inventario',
                 panel:   'NASCAR \\u00b7 Panel' };

  /* Que modulo necesita cada vista. En un solo archivo las vistas son
     el equivalente de las paginas sueltas, asi que el # es la URL: si
     el modulo no esta contratado, esa direccion no debe llevar a
     ninguna parte. Se pregunta a la misma funcion de siempre. */
  var MODULO_DE_VISTA = { publico: 'basico', mesa: 'basico',
                          cierre: 'cierre', panel: 'basico' };

  /* A qué PORTAL pertenece cada vista. En un solo archivo no hay
     direcciones distintas, así que la separación se hace en la barra:
     desde el portal del cliente no se ofrece ninguna ruta visible a los
     destinos operativos. Se llega a ellos escribiendo el # —y ahí
     manda el login, igual que en la versión de varios archivos. */
  var PORTAL_DE_VISTA = { publico: 'cliente', mesa: 'cliente',
                          cierre: 'operativo', panel: 'operativo' };

  function haySesion() {
    var S = window.NASCAR && NASCAR.Store;
    try { return !!(S && S.estaAutenticado && S.estaAutenticado()); } catch (e) { return false; }
  }

  function vistaDisponible(v) {
    var S = window.NASCAR && NASCAR.Store;
    if (!S || !S.hasModule) return true;
    return S.hasModule(MODULO_DE_VISTA[v]);
  }

  /* Con que mesa arranco la pagina: si el # cambia a otra mesa hay que
     recargar, porque el contexto se lee una sola vez al iniciar. */
  var PATRON_MESA = /^#mesa\\/[^\\/]+\\/[^\\/]+/;
  var mesaInicial = PATRON_MESA.test(location.hash) ? location.hash : null;

  function vistaActual() {
    var h = (location.hash || '').replace(/^#/, '').split('/')[0];
    if (!VISTAS[h]) return 'publico';
    // Acceso directo por #: si el modulo esta apagado, no se entra.
    return vistaDisponible(h) ? h : 'publico';
  }

  function aplicar() {
    var v = vistaActual();
    var nodos = document.querySelectorAll('[data-vista]');
    for (var i = 0; i < nodos.length; i++) {
      nodos[i].classList.toggle('is-activa', nodos[i].dataset.vista === v);
    }
    var btns = document.querySelectorAll('.cambia-vista button');
    for (var j = 0; j < btns.length; j++) {
      var destino = btns[j].dataset.ir;
      btns[j].classList.toggle('is-activa', destino === v);
      /* Se oculta si el modulo esta apagado, y tambien si es un destino
         OPERATIVO y no hay nadie dentro: el portal del cliente no
         ofrece rutas al panel. */
      var operativo = PORTAL_DE_VISTA[destino] === 'operativo';
      btns[j].hidden = !vistaDisponible(destino) || (operativo && !haySesion());
    }
    document.title = VISTAS[v];
    window.scrollTo(0, 0);
  }

  /* Al entrar o salir cambia lo que la barra puede ofrecer. */
  document.addEventListener('DOMContentLoaded', function () {
    var S = window.NASCAR && NASCAR.Store;
    if (S && S.onChange) S.onChange(aplicar);
    document.addEventListener('click', function (e) {
      if (e.target && e.target.closest && e.target.closest('#btnEntrar, #btnSalir'))
        setTimeout(aplicar, 300);
    });
  });

  window.addEventListener('hashchange', function () {
    if (PATRON_MESA.test(location.hash) && location.hash !== mesaInicial) {
      location.reload();
      return;
    }
    aplicar();
  });

  document.addEventListener('DOMContentLoaded', function () {
    var barra = document.querySelector('.cambia-vista');
    barra.addEventListener('click', function (e) {
      var b = e.target.closest('button[data-ir]');
      if (b) location.hash = '#' + b.dataset.ir;
    });
    aplicar();
  });
})();
"""


def main() -> None:
    # styles.css (base) + sidebar.css (componente compartido de navegación)
    css = leer("css/styles.css") + "\n" + leer("css/sidebar.css")
    js = "\n\n".join(f"/* ===================== {s} ===================== */\n"
                     + leer(s) for s in SCRIPTS)

    vistas, botones = [], []
    iconos = {"publico": "\U0001F3C1", "mesa": "\U0001F37D",
              "cierre": "\U0001F4E6", "panel": "\U0001F4CA"}

    for archivo, clave, etiqueta in PAGINAS:
        html = reescribir_enlaces(cuerpo(leer(archivo)))
        vistas.append(f'<div class="vista" data-vista="{clave}">\n{html}\n</div>')
        botones.append(f'<button data-ir="{clave}"><i>{iconos[clave]}</i>{etiqueta}</button>')

    salida = f"""<!DOCTYPE html>
<html lang="es-CO">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="NASCAR">
<meta name="format-detection" content="telephone=no">
<title>NASCAR · Restaurante</title>
<meta name="robots" content="noindex">
<meta name="theme-color" content="#06080c">

<!-- ARCHIVO GENERADO AUTOMATICAMENTE. No lo edites a mano:
     los cambios se pierden al volver a ejecutar `py build-movil.py`.
     Edita los archivos originales (index.html, js/data.js, css/styles.css...)
     y vuelve a generar este. -->

<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'><rect width='32' height='32' fill='%2306080c'/><rect x='4' y='4' width='8' height='8' fill='%23fff'/><rect x='20' y='4' width='8' height='8' fill='%23fff'/><rect x='12' y='12' width='8' height='8' fill='%23fff'/><rect x='4' y='20' width='8' height='8' fill='%23fff'/><rect x='20' y='20' width='8' height='8' fill='%23fff'/></svg>">

<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Archivo+Black&family=Barlow+Condensed:wght@400;600;700&family=Barlow:wght@400;500;600&display=swap" rel="stylesheet">

<style>
{css}
{CSS_EXTRA}
</style>
</head>

<body>

<!-- Si el teléfono abre este archivo en un visor que NO ejecuta la app
     (el iPhone lo hace al tocarlo desde WhatsApp, Archivos o el correo),
     esto es lo único que se ve. Cuando la app arranca, lo quita. -->
<div id="sinApp" style="position:fixed;inset:0;z-index:9999;display:flex;align-items:center;justify-content:center;padding:28px;background:#06080c;color:#fff;font:16px/1.5 -apple-system,system-ui,sans-serif;text-align:center">
  <div style="max-width:420px">
    <div style="font-size:44px">📱</div>
    <h2 style="margin:8px 0">Este visor no puede abrir la app</h2>
    <p style="color:#aab3c2">Tu teléfono está mostrando el archivo como vista previa, sin ejecutarlo. Pasa en iPhone al abrirlo desde WhatsApp, Archivos o el correo.</p>
    <p style="color:#aab3c2">Ábrelo desde el <b>navegador</b> (Safari o Chrome) con la dirección del Wi-Fi del restaurante, por ejemplo <b>http://192.168.1.20:8000</b>.</p>
  </div>
</div>
<script>document.getElementById('sinApp').remove();</script>

<nav class="cambia-vista">
{chr(10).join(botones)}
</nav>

{chr(10).join(vistas)}

<script>
{js}

{ROUTER_JS}
</script>
</body>
</html>
"""

    SALIDA.write_text(salida, encoding="utf-8")
    kb = SALIDA.stat().st_size / 1024
    print(f"OK  ->  {SALIDA.name}  ({kb:.0f} KB)")
    print("    Mandalo al celular por WhatsApp o correo y abrelo con doble toque.")


if __name__ == "__main__":
    main()
