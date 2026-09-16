/* ==========================================================================
   NASCAR · tema.js
   Aplica el TEMA DE LA EMPRESA activa a la página.

   Es lo que hace que una sola aplicación sirva a muchas empresas sin
   duplicar HTML ni CSS: los colores, la tipografía y el logotipo salen
   de `empresa.theme` y se escriben como variables sobre las que ya usa
   css/styles.css.

   ─────────────────────────────────────────────────────────────────────
   NO CONFUNDIR CON EL TEMA DE TASECA
   ─────────────────────────────────────────────────────────────────────
   Este archivo lo cargan las páginas de EMPRESA (index, mesa, cierre,
   admin). El panel de plataforma NO lo carga: su identidad vive en
   css/taseca.css con variables --platform-* y ninguna empresa la toca.

   ─────────────────────────────────────────────────────────────────────
   POR QUÉ NASCAR NO CAMBIA
   ─────────────────────────────────────────────────────────────────────
   El tema de NASCAR guarda exactamente los valores que llevaban años
   escritos en el CSS (#0b5fff, #e4002b, Barlow, NAS+CAR). Al aplicarse,
   escribe encima lo mismo que ya había: la página queda idéntica.
   ========================================================================== */

window.NASCAR = window.NASCAR || {};

NASCAR.Tema = (function () {
  'use strict';

  const S = NASCAR.Store;

  /* Qué variable de css/styles.css alimenta cada color del tema. Se
     reutiliza la paleta que ya existe en vez de inventar uuna segunda:
     así todo lo pintado hasta hoy sigue funcionando igual. */
  function aplicar(empresaId) {
    if (!S || !S.getTheme) return null;

    const t = S.getTheme(empresaId);
    const raiz = document.documentElement;

    // --- Colores
    raiz.style.setProperty('--azul', t.primary);
    raiz.style.setProperty('--rojo', t.secondary);
    raiz.style.setProperty('--azul-claro', t.accent);
    raiz.style.setProperty('--negro-900', t.background);

    /* Los resplandores se derivan del color, para que no queden de otro
       tono cuando la empresa cambia de paleta. */
    raiz.style.setProperty('--azul-glow', conAlfa(t.primary, 0.35));
    raiz.style.setProperty('--rojo-glow', conAlfa(t.secondary, 0.35));

    // --- Tipografía
    cargarFuente(t.fontFamily);
    raiz.style.setProperty('--f-body', S.familiaTipografica(t.fontFamily));

    // --- Marca visible
    pintarLogotipo(t);
    pintarFavicon(t);

    return t;
  }

  /* #rrggbb -> rgba(r,g,b,a). Si el color no es hexadecimal se devuelve
     tal cual: normalizarTheme() ya garantiza que lo sea, pero mejor no
     reventar si algún día llega otra cosa. */
  function conAlfa(hex, alfa) {
    const v = String(hex || '').replace('#', '');
    if (v.length !== 3 && v.length !== 6) return hex;
    const largo = v.length === 3 ? v.split('').map((c) => c + c).join('') : v;
    const n = parseInt(largo, 16);
    return 'rgba(' + ((n >> 16) & 255) + ',' + ((n >> 8) & 255) + ',' + (n & 255) + ',' + alfa + ')';
  }

  /* Las tipografías salen de una lista cerrada (NASCAR.TIPOGRAFIAS): no
     se admite CSS ni familias arbitrarias. Se carga una sola vez. */
  const cargadas = {};

  function cargarFuente(idFuente) {
    const t = S.tipografia(idFuente);
    if (!t || !t.google || cargadas[t.id]) return;
    cargadas[t.id] = true;

    const enlace = document.createElement('link');
    enlace.rel = 'stylesheet';
    enlace.href = 'https://fonts.googleapis.com/css2?family=' + t.google + '&display=swap';
    document.head.appendChild(enlace);
  }

  /**
   * El logotipo de la cabecera.
   *
   * Si el tema trae una imagen, se pone. Si no, se escribe el logotipo
   * de texto: la primera parte en el color del texto y la segunda en el
   * de acento — que es exactamente como se ha escrito siempre NAS+CAR.
   *
   * Si el tema no dice nada (ni imagen ni texto), NO se toca el marcado:
   * se deja lo que venga en el HTML. Así una página nunca se queda sin
   * marca por un tema a medio configurar.
   */
  function pintarLogotipo(t) {
    const empresa = S.getEmpresaActual();
    const nombre = empresa ? empresa.nombre : '';

    document.querySelectorAll('.logo__marca').forEach(function (nodo) {
      if (t.logo) {
        nodo.innerHTML =
          '<img src="' + t.logo + '" alt="' + escapar(nombre) + '" ' +
          'style="height:30px;width:auto;display:block;object-fit:contain">';
        return;
      }
      if (t.logoTexto || t.logoAcento) {
        nodo.innerHTML = escapar(t.logoTexto) + (t.logoAcento ? '<em>' + escapar(t.logoAcento) + '</em>' : '');
        return;
      }
      if (nombre) nodo.textContent = nombre;
    });
  }

  function pintarFavicon(t) {
    if (!t.favicon) return;
    let icono = document.querySelector('link[rel="icon"]');
    if (!icono) {
      icono = document.createElement('link');
      icono.rel = 'icon';
      document.head.appendChild(icono);
    }
    icono.href = t.favicon;
  }

  function escapar(txt) {
    return String(txt == null ? '' : txt).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  /* Se aplica al cargar y cada vez que cambie la empresa activa —por
     ejemplo cuando el SuperAdmin entra a administrar otra. */
  document.addEventListener('DOMContentLoaded', function () {
    aplicar();
    if (S.onChange) S.onChange(() => aplicar());
  });

  return { aplicar: aplicar };
})();
