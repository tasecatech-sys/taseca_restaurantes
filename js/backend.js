/* ==========================================================================
   NASCAR · backend.js
   DOS decisiones, antes de que arranque nada más:

     1. A qué base de datos se habla, según dónde se abra la página.
     2. DE QUÉ EMPRESA es esta visita.

   Ninguna empresa está escrita a la fuerza: NASCAR es una más. La empresa
   se resuelve, en este orden:

     · ?empresa=empresa_pizzeria   → gana siempre, sirve para probar
     · el subdominio               → pizzeria.taseca.tech ⇒ empresa_pizzeria
     · EMPRESAS[subdominio]        → para los casos que no calcen con la regla
     · en este equipo (localhost)  → la de NASCAR.EMPRESA_POR_DEFECTO
     · dominio de pruebas          → EMPRESA_VITRINA, la que se enseña

   El panel de Taseca (taseca-admin.html) es la excepción: no es de ninguna
   empresa, así que no necesita nada de esto.

   La clave `apikey` es PÚBLICA: Supabase la reparte para que viaje en el
   navegador. No da acceso a nada por sí sola — quién puede ver y hacer qué
   lo siguen decidiendo el token de la sesión y los permisos de la base.
   La contraseña de la base NUNCA aparece aquí.
   ========================================================================== */

window.NASCAR = window.NASCAR || {};

(function () {
  'use strict';

  /* ---- Base en la nube --------------------------------------------------
     url     → https://<referencia-del-proyecto>.supabase.co/rest/v1
     apikey  → clave publicable del proyecto (sb_publishable_… o la anon)
     esquema → 'rest', el único esquema que publica la aplicación          */
  const NUBE = {
    url: 'https://sybyknbzdquvkaovixma.supabase.co/rest/v1',
    apikey: 'sb_publishable_ML-n5271NiXSQeBZIN9b6w_E2C33u-y',
    esquema: 'rest',
  };

  /* Qué empresa se muestra si la dirección no dice ninguna. Vacío a
     propósito: sin empresa la página lo dice en vez de suponer una. Cada
     negocio entra por su ruta (/nascar/panel) o por su subdominio. */
  const EMPRESA_VITRINA = '';

  /* ---- Subdominios con nombre propio ------------------------------------
     Sólo hace falta anotar aquí los que NO siguen la regla
     «subdominio → empresa_subdominio». Por ejemplo, si el código quedó
     largo al darla de alta:

       'pizzeria': 'empresa_pizzeria_del_parque',                          */
  const EMPRESAS = {
    // 'pizzeria': 'empresa_pizzeria_del_parque',
  };

  /* Subdominios que NO son de una empresa: el sitio de la plataforma. */
  const RESERVADOS = ['www', 'taseca', 'admin', 'plataforma', 'app'];

  /* La resolución vive en una función aparte, con el host como parámetro,
     para poder comprobarla con cualquier dominio sin tener que publicarlo:
       NASCAR.Backend.empresaDe('pizzeria.taseca.tech')  →  'empresa_pizzeria' */
  function esDeEsteEquipo(host) {
    return (
      host === 'localhost' ||
      host === '127.0.0.1' ||
      host === '::1' ||
      host === '' ||
      /^192\.168\./.test(host) ||
      /^10\./.test(host) ||
      /^172\.(1[6-9]|2\d|3[01])\./.test(host) ||
      /\.local$/.test(host) ||
      /\.localhost$/.test(host)
    );
  }

  function subdominioDe(host) {
    // Una IP no tiene subdominios: 192.168.1.50 no es "la empresa 192"
    if (/^[0-9.]+$/.test(host) || host.indexOf(':') >= 0) return '';
    const partes = host.split('.');
    if (partes.length < 3) return '';
    if (/\.vercel\.app$/.test(host)) return '';
    const sub = partes[0];
    return RESERVADOS.indexOf(sub) >= 0 ? '' : sub;
  }

  /* Las páginas del negocio, tal como se escriben en la dirección. El panel
     de Taseca no está aquí: no es de ninguna empresa. */
  const PAGINAS = { '': 'index.html', panel: 'empleados.html', mesa: 'mesa.html', cierre: 'cierre.html' };

  /* empresa_pizzeria_del_parque  ⇄  pizzeria-del-parque */
  function aRanura(codigo) {
    return String(codigo || '').replace(/^empresa_/, '').replace(/_/g, '-');
  }

  function aCodigo(ranura) {
    if (!ranura) return '';
    return EMPRESAS[ranura] || 'empresa_' + ranura.replace(/-/g, '_');
  }

  /* El primer tramo de la ruta, si nombra una empresa: /nascar/panel → nascar.
     Los nombres de página y de archivo no cuentan como empresa. */
  function ranuraDe(camino) {
    const tramo = String(camino || '').split('/')[1] || '';
    if (!tramo || tramo.indexOf('.') >= 0) return '';
    if (tramo === 'taseca' || Object.prototype.hasOwnProperty.call(PAGINAS, tramo)) return '';
    return tramo.toLowerCase();
  }

  function empresaDe(host, busqueda, camino) {
    host = (host || '').toLowerCase();
    const pedida = new URLSearchParams(busqueda || '').get('empresa');
    if (pedida) return pedida;

    const ranura = ranuraDe(camino);
    if (ranura) return aCodigo(ranura);

    const sub = subdominioDe(host);
    if (sub) return aCodigo(sub);

    // En el equipo del negocio se trabaja con la empresa instalada
    if (esDeEsteEquipo(host)) return NASCAR.EMPRESA_POR_DEFECTO || '';

    return EMPRESA_VITRINA;
  }

  /* La dirección de una página PARA una empresa:
       rutaDe('panel')                        → /nascar/panel   (la de esta visita)
       rutaDe('panel', 'empresa_pizzeria')    → /pizzeria/panel
     Con subdominio propio la empresa ya va delante, así que no se repite. */
  function rutaDe(pagina, codigo) {
    const cod = codigo || NASCAR.BACKEND.empresa || '';
    const hoja = pagina === 'publico' ? '' : pagina;
    if (subdominioDe((location.hostname || '').toLowerCase()) && !codigo) {
      return '/' + hoja;
    }
    const ranura = aRanura(cod);
    return ranura ? '/' + ranura + (hoja ? '/' + hoja : '/') : '/' + (hoja || '');
  }

  NASCAR.Backend = {
    empresaDe: empresaDe, subdominioDe: subdominioDe, esDeEsteEquipo: esDeEsteEquipo,
    ranuraDe: ranuraDe, aRanura: aRanura, aCodigo: aCodigo, PAGINAS: PAGINAS,
  };
  NASCAR.rutaDe = rutaDe;

  /* Los enlaces del HTML siguen escritos como archivos (empleados.html) para
     que el archivo de un solo fichero se pueda seguir generando. Aquí se
     traducen a la dirección con empresa, ya en el navegador. */
  function traducirEnlaces() {
    const deArchivo = { 'index.html': 'publico', 'empleados.html': 'panel',
                        'mesa.html': 'mesa', 'cierre.html': 'cierre' };
    document.querySelectorAll('a[href]').forEach(function (a) {
      const href = a.getAttribute('href');
      const m = /^([a-z-]+\.html)(\?.*)?$/i.exec(href || '');
      if (!m) return;
      if (m[1] === 'taseca-admin.html') {
        a.setAttribute('href', '/taseca' + (m[2] || ''));
        return;
      }
      const pagina = deArchivo[m[1].toLowerCase()];
      if (!pagina) return;
      a.setAttribute('href', rutaDe(pagina) + (m[2] || ''));
    });
  }

  const host = (location.hostname || '').toLowerCase();
  const enEsteEquipo = esDeEsteEquipo(host);

  const empresa = empresaDe(host, location.search, location.pathname);

  if (!enEsteEquipo && NUBE.url) {
    NASCAR.BACKEND = Object.assign({}, NASCAR.BACKEND, NUBE, { empresa: empresa });
    return;
  }

  /* Publicada en internet pero todavía sin base en la nube: se avisa en vez
     de intentar una conexión que no existe (el puerto 3000 de un dominio
     público no lleva a ninguna parte). */
  if (!enEsteEquipo) {
    NASCAR.BACKEND = Object.assign({}, NASCAR.BACKEND, { modo: 'local', sinNube: true });
    return;
  }

  if (empresa) NASCAR.BACKEND = Object.assign({}, NASCAR.BACKEND, { empresa: empresa });
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', traducirEnlaces);
  } else {
    traducirEnlaces();
  }
})();
