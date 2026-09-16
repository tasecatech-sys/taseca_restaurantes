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

  /* Qué empresa se muestra cuando se entra por el dominio de pruebas, sin
     subdominio y sin ?empresa=. Es una vitrina: en producción cada negocio
     entra por el suyo. Vacío = se pide la empresa en vez de suponerla. */
  const EMPRESA_VITRINA = 'empresa_nascar';

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

  function empresaDe(host, busqueda) {
    host = (host || '').toLowerCase();
    const pedida = new URLSearchParams(busqueda || '').get('empresa');
    if (pedida) return pedida;

    const sub = subdominioDe(host);
    if (sub) return EMPRESAS[sub] || 'empresa_' + sub.replace(/-/g, '_');

    // En el equipo del negocio se trabaja con la empresa instalada
    if (esDeEsteEquipo(host)) return NASCAR.EMPRESA_POR_DEFECTO || '';

    return EMPRESA_VITRINA;
  }

  NASCAR.Backend = { empresaDe: empresaDe, subdominioDe: subdominioDe, esDeEsteEquipo: esDeEsteEquipo };

  const host = (location.hostname || '').toLowerCase();
  const enEsteEquipo = esDeEsteEquipo(host);

  const empresa = empresaDe(host, location.search);

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
})();
