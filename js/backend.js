/* ==========================================================================
   NASCAR · backend.js
   A qué base de datos habla la aplicación, según DÓNDE se esté abriendo.

   Se carga ANTES que remoto.js y sólo decide la dirección de la API:
   ninguna lógica más.

     · En el local (localhost o la Wi-Fi del negocio)  → PostgREST de ese
       computador, en el puerto 3000, igual que siempre.
     · Publicada en internet (Vercel u otro dominio)   → la base en la nube
       configurada aquí abajo.
     · Abierta como archivo (nascar-movil.html)        → modo local, sin red.

   La clave `apikey` es PÚBLICA: Supabase la reparte para que viaje en el
   navegador. No da acceso a nada por sí sola — quién puede ver y hacer qué
   lo siguen decidiendo el token de la sesión y los permisos de la base.
   La contraseña de la base NUNCA aparece aquí.
   ========================================================================== */

window.NASCAR = window.NASCAR || {};

(function () {
  'use strict';

  /* ---- Base en la nube (se llena al crear el proyecto) ------------------
     url     → https://<referencia-del-proyecto>.supabase.co/rest/v1
     apikey  → clave publicable del proyecto (sb_publishable_… o la anon)
     esquema → 'rest', el único esquema que publica la aplicación          */
  const NUBE = {
    url: '',
    apikey: '',
    esquema: 'rest',
  };

  const host = location.hostname || '';
  const enEsteEquipo =
    host === 'localhost' ||
    host === '127.0.0.1' ||
    host === '::1' ||
    host === '' ||
    /^192\.168\./.test(host) ||
    /^10\./.test(host) ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(host) ||
    /\.local$/.test(host);

  if (!enEsteEquipo && NUBE.url) {
    NASCAR.BACKEND = Object.assign({}, NASCAR.BACKEND, NUBE);
    return;
  }

  /* Publicada en internet pero todavía sin base en la nube: se avisa en vez
     de intentar una conexión que no existe (el puerto 3000 de un dominio
     público no lleva a ninguna parte). */
  if (!enEsteEquipo) {
    NASCAR.BACKEND = Object.assign({}, NASCAR.BACKEND, { modo: 'local', sinNube: true });
  }
})();
