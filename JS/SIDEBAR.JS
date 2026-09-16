/* ==========================================================================
   sidebar.js · CONTROLADOR COMPARTIDO DE NAVEGACIÓN

   El mismo para los dos paneles —el de Taseca y el de cada empresa— para
   no tener dos menús que mantener. Lo único que cambia entre ellos es la
   piel (css/taseca.css vs css/styles.css) y qué opciones lleva dentro.

   QUÉ HACE:  colapsar y expandir, recordar la preferencia, el cajón de
              móvil, el aria, el cierre automático al navegar y los
              grupos plegables del menú (Operación, Ventas y caja…).

   QUÉ NO HACE:  decidir qué opciones se ven. Eso lo siguen decidiendo
   NASCAR.Auth.seccionesVisibles() y admin.js, exactamente igual que
   antes. Este archivo no sabe de roles, permisos ni módulos, y no puede
   convertirse en una forma de saltárselos.
   ========================================================================== */

window.NASCAR = window.NASCAR || {};

NASCAR.Sidebar = (function () {
  'use strict';

  /* La preferencia se guarda por panel: el usuario puede querer el de
     Taseca encogido y el de su empresa abierto. Es sólo estado visual,
     así que va a localStorage sin pasar por el store de negocio. */
  const PREFIJO = 'nascar.sidebar.';

  function leerPreferencia(clave) {
    try {
      return localStorage.getItem(PREFIJO + clave) === '1';
    } catch (e) {
      return false; // sin almacenamiento, se abre expandido
    }
  }

  function guardarPreferencia(clave, colapsado) {
    try {
      localStorage.setItem(PREFIJO + clave, colapsado ? '1' : '0');
    } catch (e) {
      /* incógnito o almacenamiento bloqueado: no pasa nada, se pierde
         la preferencia pero el menú funciona igual */
    }
  }

  /* ---- Grupos del menú ----
     Segundo nivel de plegado: además de encoger la barra entera, cada
     grupo se abre o se cierra. Se recuerda por panel, igual que el
     colapso: es estado visual, no de negocio. { grupo: true } = cerrado. */
  const PREFIJO_GRUPOS = PREFIJO + 'grupos.';

  function leerGrupos(clave) {
    try {
      const v = JSON.parse(localStorage.getItem(PREFIJO_GRUPOS + clave));
      return v && typeof v === 'object' ? v : {};
    } catch (e) {
      return {}; // sin almacenamiento, todos abiertos
    }
  }

  function guardarGrupo(clave, grupo, cerrado) {
    try {
      const estado = leerGrupos(clave);
      estado[grupo] = cerrado;
      localStorage.setItem(PREFIJO_GRUPOS + clave, JSON.stringify(estado));
    } catch (e) {
      /* el grupo se pliega igual; sólo no se recuerda */
    }
  }

  function pintarGrupo(grupo, cerrado) {
    grupo.classList.toggle('is-cerrado', cerrado);
    const cab = grupo.querySelector('[data-grupo-toggle]');
    if (cab) cab.setAttribute('aria-expanded', cerrado ? 'false' : 'true');
  }

  function esMovil() {
    return window.matchMedia('(max-width: 900px)').matches;
  }

  /**
   * iniciar({ shell, clave })
   *
   *   shell → el contenedor con la barra y el contenido (.app-shell)
   *   clave → con qué nombre se recuerda la preferencia ('taseca', 'empresa')
   */
  function iniciar(opciones) {
    const o = opciones || {};
    const shell = o.shell || document.querySelector('[data-sidebar-shell]');
    if (!shell || shell.dataset.sidebarListo === '1') return null;
    shell.dataset.sidebarListo = '1';

    const clave = o.clave || 'panel';
    const toggle = shell.querySelector('[data-sidebar-toggle]');
    const abrir = shell.querySelector('[data-sidebar-abrir]');
    const fondo = shell.querySelector('[data-sidebar-fondo]');
    const barra = shell.querySelector('.app-side');

    let colapsado = leerPreferencia(clave);

    // Los grupos arrancan como el usuario los dejó (abiertos si nunca los tocó)
    const gruposGuardados = leerGrupos(clave);
    shell.querySelectorAll('[data-grupo]').forEach(function (g) {
      pintarGrupo(g, gruposGuardados[g.dataset.grupo] === true);
    });

    /* ---- Pintado del estado ---- */
    function aplicar() {
      shell.classList.toggle('is-colapsado', colapsado);

      if (toggle) {
        const icono = toggle.querySelector('i');
        const texto = toggle.querySelector('span');
        // Flecha hacia dónde va a moverse el menú si se pulsa
        if (icono) icono.textContent = colapsado ? '→' : '←';
        if (texto) texto.textContent = colapsado ? 'Expandir' : 'Contraer menú';

        const etiqueta = colapsado ? 'Expandir menú' : 'Contraer menú';
        toggle.setAttribute('aria-label', etiqueta);
        toggle.setAttribute('title', etiqueta);
        toggle.setAttribute('data-titulo', etiqueta);
        // aria-expanded describe el menú que controla, no el botón
        toggle.setAttribute('aria-expanded', colapsado ? 'false' : 'true');
      }

      if (barra) barra.setAttribute('aria-label', 'Menú de navegación');
    }

    /* ---- Colapsar / expandir (escritorio) ---- */
    function alternar() {
      colapsado = !colapsado;
      guardarPreferencia(clave, colapsado);
      aplicar();
    }

    /* ---- Cajón (móvil) ---- */
    function abrirCajon() {
      shell.classList.add('is-abierto');
      if (abrir) abrir.setAttribute('aria-expanded', 'true');
      // Al abrir el cajón, el foco va al menú: se puede recorrer con Tab
      // El primero que se VE: puede haber grupos enteros ocultos o cerrados
      const primero = Array.prototype.find.call(
        shell.querySelectorAll('.app-side__menu button:not(.oculto)'),
        (b) => b.offsetParent !== null
      );
      if (primero) primero.focus();
    }

    function cerrarCajon() {
      shell.classList.remove('is-abierto');
      if (abrir) abrir.setAttribute('aria-expanded', 'false');
    }

    if (toggle) toggle.addEventListener('click', alternar);
    if (abrir) abrir.addEventListener('click', abrirCajon);
    if (fondo) fondo.addEventListener('click', cerrarCajon);

    /* Abrir / cerrar un grupo. Sólo pliega: no navega, no cierra el cajón
       en móvil y no mira permisos. */
    shell.addEventListener('click', function (e) {
      const cab = e.target.closest('[data-grupo-toggle]');
      if (!cab || !shell.contains(cab)) return;
      const g = cab.closest('[data-grupo]');
      if (!g) return;
      const cerrar = !g.classList.contains('is-cerrado');
      pintarGrupo(g, cerrar);
      guardarGrupo(clave, g.dataset.grupo, cerrar);
    });

    /* En móvil, elegir una opción cierra el cajón: si no, el menú taparía
       justo lo que se acaba de abrir. En escritorio no se toca nada — el
       estado del menú sólo lo cambia el usuario (§16). */
    if (barra)
      barra.addEventListener('click', function (e) {
        if (!esMovil()) return;
        if (e.target.closest('button, a') && !e.target.closest('[data-sidebar-toggle], [data-grupo-toggle]'))
          cerrarCajon();
      });

    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && shell.classList.contains('is-abierto')) cerrarCajon();
    });

    // Al pasar de móvil a escritorio, el cajón sobra
    window.addEventListener('resize', function () {
      if (!esMovil()) cerrarCajon();
    });

    aplicar();

    return {
      alternar: alternar,
      abrir: abrirCajon,
      cerrar: cerrarCajon,
      estaColapsado: () => colapsado,
    };
  }

  /**
   * Marca cuál es la opción activa del menú.
   *
   * Sólo pinta: no comprueba permisos ni cambia de sección. Quien decide
   * a dónde se va sigue siendo el controlador de cada panel.
   */
  function marcarActivo(shell, atributo, valor) {
    if (!shell) return;
    shell.querySelectorAll('.app-side__menu [' + atributo + ']').forEach(function (b) {
      const activo = b.getAttribute(atributo) === valor;
      b.classList.toggle('is-activo', activo);
      b.setAttribute('aria-current', activo ? 'page' : 'false');
    });
  }

  /* El tooltip del estado colapsado sale de `data-titulo`. Se rellena
     con el texto que ya tiene el botón, para no repetirlo en el HTML y
     que nunca se queden desincronizados. */
  function prepararTooltips(shell) {
    if (!shell) return;
    // Las cabeceras de grupo no llevan tooltip: con la barra encogida no se ven
    shell.querySelectorAll('.app-side__menu button:not([data-grupo-toggle]), .app-side__pie button').forEach(function (b) {
      if (b.dataset.titulo) return;
      const etiqueta = b.querySelector('span:not(.pill)');
      const texto = (etiqueta ? etiqueta.textContent : b.textContent).trim();
      if (texto) {
        b.dataset.titulo = texto;
        if (!b.getAttribute('aria-label')) b.setAttribute('aria-label', texto);
      }
    });
  }

  /**
   * Esconde los grupos que se quedaron sin opciones visibles y marca el
   * que contiene la sección activa.
   *
   * Se llama DESPUÉS de que el panel haya decidido qué opciones ve el
   * perfil. No decide nada: sólo lee `.oculto`, que lo pone quien sabe de
   * permisos. Un grupo vacío sería un título que no lleva a ninguna parte.
   */
  function actualizarGrupos(shell) {
    if (!shell) return;
    shell.querySelectorAll('[data-grupo]').forEach(function (g) {
      const visibles = Array.prototype.filter.call(
        g.querySelectorAll('.app-side__grupo-items > button, .app-side__grupo-items > a'),
        (b) => !b.classList.contains('oculto')
      );
      g.classList.toggle('oculto', visibles.length === 0);
      g.classList.toggle('tiene-activo', visibles.some((b) => b.classList.contains('is-activo')));
    });
  }

  /**
   * Al LLEGAR a una sección cuyo grupo estaba cerrado (al entrar, o desde
   * un enlace interno) el grupo se abre, para que se vea dónde está uno.
   * No se guarda: la preferencia la sigue cambiando sólo el usuario.
   *
   *   opciones.abrir → false para sólo actualizar las marcas
   */
  function revelarActivo(shell, opciones) {
    if (!shell) return;
    actualizarGrupos(shell);
    if (opciones && opciones.abrir === false) return;
    const activo = shell.querySelector('[data-grupo] .is-activo');
    const g = activo && activo.closest('[data-grupo]');
    if (g && g.classList.contains('is-cerrado')) pintarGrupo(g, false);
  }

  return {
    iniciar: iniciar,
    marcarActivo: marcarActivo,
    prepararTooltips: prepararTooltips,
    actualizarGrupos: actualizarGrupos,
    revelarActivo: revelarActivo,
  };
})();
