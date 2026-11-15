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
    const claro = t.modo === 'claro';

    raiz.style.setProperty('--azul', t.primary);
    raiz.style.setProperty('--rojo', t.secondary);
    /* El acento se usa como texto —el precio de un plato, los estados— y
       el que luce sobre negro no se lee sobre blanco. En claro se
       oscurece conservando el tono. */
    raiz.style.setProperty('--azul-claro', claro ? paraFondoClaro(t.accent) : t.accent);
    /* El color de fondo de la empresa es una elección DEL MODO OSCURO: un
       azul casi negro precioso sobre el que se lee en blanco. En claro no
       sirve, y además se mete por estilo en línea, que le gana a
       [data-tema='claro'] y dejaría la página negra con el texto negro.
       En claro se quita y manda la rampa clara. */
    if (claro) raiz.style.removeProperty('--negro-900');
    else raiz.style.setProperty('--negro-900', t.background);

    /* Los resplandores se derivan del color, para que no queden de otro
       tono cuando la empresa cambia de paleta. */
    raiz.style.setProperty('--azul-glow', conAlfa(t.primary, 0.35));
    raiz.style.setProperty('--rojo-glow', conAlfa(t.secondary, 0.35));

    // --- Tipografía
    cargarFuente(t.fontFamily);
    raiz.style.setProperty('--f-body', S.familiaTipografica(t.fontFamily));

    /* Claro u oscuro. Es un atributo en <html> y nada más: el bloque
       [data-tema='claro'] de css/styles.css cambia los VALORES de los
       tokens y todo lo pintado con ellos se adapta solo. Ninguna pantalla
       tiene que saber en qué modo está. */
    raiz.setAttribute('data-tema', t.modo === 'claro' ? 'claro' : 'oscuro');

    // --- Motivo de marca (la banda de la portada y las fichas)
    aplicarPatron(t);

    // --- Marca visible
    pintarLogotipo(t);
    pintarFavicon(t);
    pintarTitulo();

    return t;
  }

  /**
   * El motivo de marca.
   *
   * Es un solo atributo en <html>; el dibujo de cada motivo vive en
   * css/styles.css, que lo pinta con los colores del tema. La empresa
   * elige de una lista cerrada (NASCAR.PATRONES): de aquí no sale CSS
   * suyo a ninguna parte.
   *
   * De paso se cambia el emblema de los botones. La bandera a cuadros
   * es de la carrera, no de todos los negocios, así que un restaurante
   * cualquiera no tiene por qué llevarla.
   */
  function aplicarPatron(t) {
    const p = S.patron ? S.patron(t.patron) : null;
    if (!p) return;
    document.documentElement.setAttribute('data-patron', p.id);
    pintarEmblemas(p.emblema || '');
  }

  /* Los HTML traen el emblema escrito para que se vea algo antes de que
     cargue nada; aquí se reemplaza por el que toque, o se quita. */
  function pintarEmblemas(emblema) {
    document.querySelectorAll('[data-emblema]').forEach(function (nodo) {
      nodo.textContent = emblema;
      nodo.classList.toggle('oculto', !emblema);
    });
  }

  /**
   * El color de acento, pero legible sobre fondo claro.
   *
   * El acento se elige mirando el tema oscuro: un azul luminoso que
   * brilla sobre negro. Ese mismo azul sobre blanco da un contraste de
   * 2,8 — por debajo de lo que se lee. Y el acento se usa como TEXTO en
   * bastantes sitios (el precio de un plato, los estados).
   *
   * Se oscurece hasta que contrasta, conservando el tono: sigue siendo
   * su azul, sólo que el que se puede leer. No se toca el color
   * guardado; esto es sólo cómo se pinta en modo claro.
   */
  function paraFondoClaro(hex) {
    const v = String(hex || '').replace('#', '');
    if (v.length !== 6) return hex;

    let r = parseInt(v.slice(0, 2), 16),
        g = parseInt(v.slice(2, 4), 16),
        b = parseInt(v.slice(4, 6), 16);

    /* Luminancia relativa, que es como se mide el contraste de verdad.
       Se baja en pasos hasta llegar al objetivo; 0.18 deja alrededor de
       4,5 contra blanco, que es el mínimo para texto normal. */
    const luz = () => {
      const f = (c) => {
        c /= 255;
        return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
      };
      return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
    };

    let vueltas = 0;
    while (luz() > 0.18 && vueltas++ < 24) {
      r = Math.round(r * 0.9);
      g = Math.round(g * 0.9);
      b = Math.round(b * 0.9);
    }

    const dos = (n) => ('0' + n.toString(16)).slice(-2);
    return '#' + dos(r) + dos(g) + dos(b);
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
  /**
   * La ficha que va al lado del logotipo.
   *
   * Es un MOTIVO de marca —la bandera a cuadros de la carrera, o el que
   * haya elegido la empresa—, no un logo. Cuando la empresa subió el
   * suyo sobra: se veía un rectángulo de color suelto pegado a su
   * imagen, como si fueran dos logos.
   *
   * La excepción es la barra lateral encogida: ahí la ficha es lo ÚNICO
   * que queda a la vista, así que la imagen la sustituye en lugar de
   * quitarla. Si se escondiera, el panel encogido se quedaría sin marca.
   */
  function pintarFichas(t) {
    const conImagen = !!t.logo;

    document.querySelectorAll('.logo__cuadros').forEach(function (ficha) {
      const esIso = ficha.classList.contains('app-side__iso');

      if (esIso && conImagen) {
        ficha.classList.remove('cuadros', 'cuadros--fina', 'oculto');
        ficha.innerHTML =
          '<img src="' + t.logo + '" alt="" ' +
          'style="width:100%;height:100%;object-fit:contain;display:block">';
        return;
      }

      /* Se vuelve a dejar como estaba: aplicar() corre otra vez cada vez
         que cambia la empresa activa, y la anterior pudo tener imagen. */
      if (esIso) {
        ficha.innerHTML = '';
        ficha.classList.add('cuadros', 'cuadros--fina');
      }
      ficha.classList.toggle('oculto', conImagen);
    });
  }

  function pintarLogotipo(t) {
    const empresa = S.getEmpresaActual();
    const nombre = empresa ? empresa.nombre : '';

    pintarFichas(t);

    /* Que la marca sea una IMAGEN o un TEXTO cambia cómo se compone la
       cabecera entera, no sólo este nodo: con imagen sobra el subtítulo
       de debajo. Se marca en <html> para que el CSS lo resuelva solo, en
       vez de repartir estilos en línea por aquí. */
    document.documentElement.setAttribute('data-logo', t.logo ? 'imagen' : 'texto');

    document.querySelectorAll('.logo__marca').forEach(function (nodo) {
      if (t.logo) {
        /* El tamaño lo manda css/styles.css (.logo__img). Estaba escrito
           aquí como `height:30px` en línea, que además de quedar perdido
           en una barra de 74px le ganaba a cualquier regla del CSS: no
           había forma de encogerlo en el móvil. */
        nodo.innerHTML =
          '<img class="logo__img" src="' + t.logo + '" alt="' + escapar(nombre) + '">';
        return;
      }
      if (t.logoTexto || t.logoAcento) {
        nodo.innerHTML = escapar(t.logoTexto) + (t.logoAcento ? '<em>' + escapar(t.logoAcento) + '</em>' : '');
        return;
      }
      if (nombre) nodo.textContent = nombre;
    });
  }

  /* El título de la pestaña: la marca de la empresa + lo que sea esta
     página, que cada HTML declara en <body data-titulo="…">. Sin eso, el
     título del archivo se queda como está. */
  function pintarTitulo() {
    const sufijo = document.body && document.body.dataset ? document.body.dataset.titulo : '';
    const marca = (S.getConfig && S.getConfig().marca) || '';
    if (!marca || !sufijo) return;
    document.title = marca + ' · ' + sufijo;
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

  return { aplicar: aplicar, aplicarPatron: aplicarPatron };
})();
