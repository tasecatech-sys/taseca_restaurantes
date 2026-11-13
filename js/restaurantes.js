/* ==========================================================================
   TASECA · restaurantes.js
   LA PORTADA DE LA PLATAFORMA

   Esta página no es de ningún negocio: es de Taseca. Por eso la lista de
   restaurantes NO está escrita en el HTML, se pide a la plataforma. Dar de
   alta una empresa la hace aparecer aquí sola, y desactivarla la quita, sin
   que nadie toque código. Ningún nombre de cliente vive en este archivo.

   De dónde salen los datos: `rest.empresas` y `rest.unidades`, las dos
   vistas que la base publica SIN sesión —son las mismas que lee el portal
   de cada restaurante para pintar su carta—. La vista ya filtra por
   `estado = 'activa'`, así que lo que llega es lo que se puede enseñar.

   La clave `apikey` es PÚBLICA, como en js/backend.js: no da acceso a nada
   por sí sola. Aquí sólo se leen dos listas que ya son públicas.
   ========================================================================== */

window.NASCAR = window.NASCAR || {};

(function () {
  'use strict';

  const $ = (sel) => document.querySelector(sel);

  /* El directorio es de la PLATAFORMA, no de una empresa, así que siempre
     lee de la nube: en el equipo del negocio `NASCAR.BACKEND` se queda en
     modo local y no tendría de dónde sacar la lista. */
  function conexion() {
    const B = NASCAR.BACKEND || {};
    const N = (NASCAR.Backend || {}).NUBE || {};
    return { url: B.url || N.url || '', apikey: B.apikey || N.apikey || '',
             esquema: B.esquema || N.esquema || '' };
  }

  function esc(t) {
    return String(t == null ? '' : t).replace(/[&<>"']/g,
      (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  async function pedir(ruta) {
    const c = conexion();
    if (!c.url) throw new Error('sin-nube');
    const h = { apikey: c.apikey, Authorization: 'Bearer ' + c.apikey };
    if (c.esquema) h['Accept-Profile'] = c.esquema;
    const r = await fetch(c.url + ruta, { headers: h });
    if (!r.ok) throw new Error('La plataforma respondió ' + r.status + '.');
    return r.json();
  }

  /* =================================================================
     CÓMO SE VE CADA RESTAURANTE

     Con SU identidad, no con una genérica: su logotipo de texto, sus
     iniciales y sus colores salen de la ficha de la empresa. Es lo mismo
     que hace js/tema.js en el portal de cada negocio — ninguna marca está
     escrita a mano, ni siquiera la del cliente más antiguo.
     ================================================================= */
  function iniciales(e) {
    if (e.logo_texto) return { a: e.logo_texto, b: e.logo_acento || '' };
    if (e.iniciales) return { a: e.iniciales, b: '' };
    const palabras = String(e.nombre_comercial || '?').trim().split(/\s+/);
    const dos = (palabras[0][0] || '') + (palabras.length > 1 ? palabras[1][0] : (palabras[0][1] || ''));
    return { a: dos.toUpperCase(), b: '' };
  }

  /* «3 locales · Bogotá D.C.» — lo que necesita saber quien va a pedir:
     cuántos sitios hay y en qué ciudad. */
  function donde(unidades) {
    const n = unidades.length;
    if (!n) return '';
    const ciudades = [];
    unidades.forEach(function (u) {
      const c = (u.ciudad || '').trim();
      if (c && ciudades.indexOf(c) < 0) ciudades.push(c);
    });
    const locales = n + (n === 1 ? ' local' : ' locales');
    return ciudades.length ? locales + ' · ' + ciudades.join(' · ') : locales;
  }

  /* La dirección pública de un restaurante. La arma js/backend.js, que es
     quien sabe de rutas: aquí no se inventa ninguna. */
  function enlace(codigo) {
    if (NASCAR.rutaDe) return NASCAR.rutaDe('publico', codigo);
    return '/taseca/' + String(codigo).replace(/^empresa_/, '').replace(/_/g, '-');
  }

  /* El logotipo de texto de cada empresa mide lo que mide: «NAS»+«CAR» son
     seis letras y «DG» dos, y las dos tienen que caber en el mismo cuadro
     sin recortarse. El tamaño sale del largo — es presentación calculada a
     partir del dato, no un valor que se pueda dejar fijo en la hoja. */
  function tamanoIso(texto) {
    const n = String(texto).length;
    if (n <= 2) return 21;
    if (n === 3) return 18;
    if (n === 4) return 15;
    if (n === 5) return 13;
    return 11;
  }

  function tarjeta(e, unidades) {
    const ini = iniciales(e);
    const sitio = donde(unidades);
    /* El eslogan, el lema o la descripción: lo primero que la empresa haya
       llenado. Si no llenó ninguno, no se inventa una frase. */
    const frase = e.eslogan || e.lema || e.descripcion || '';

    return (
      '<a class="tsc-rest" href="' + esc(enlace(e.codigo)) + '"' +
      ' style="--rest-1:' + esc(e.color_primario || '#d4a437') +
      ';--rest-2:' + esc(e.color_secundario || '#00e5ff') + '">' +

      '<span class="tsc-rest__iso">' +
      (e.logo_url
        ? '<img src="' + esc(e.logo_url) + '" alt="" loading="lazy">'
        : '<b style="font-size:' + tamanoIso(ini.a + ini.b) + 'px">' +
          esc(ini.a) + (ini.b ? '<em>' + esc(ini.b) + '</em>' : '') + '</b>') +
      '</span>' +

      '<span class="tsc-rest__cuerpo">' +
      '<span class="tsc-rest__nombre">' + esc(e.nombre_comercial) + '</span>' +
      (frase ? '<span class="tsc-rest__frase">' + esc(frase) + '</span>' : '') +
      (sitio ? '<span class="tsc-rest__donde">' + esc(sitio) + '</span>' : '') +
      '</span>' +

      '<span class="tsc-rest__ir">Ver carta y pedir <i>→</i></span>' +
      '</a>'
    );
  }

  /* =================================================================
     PINTAR
     ================================================================= */
  function aviso(ico, titulo, texto) {
    return '<div class="tsc-aviso"><div class="tsc-aviso__ico">' + ico + '</div>' +
      '<h3>' + esc(titulo) + '</h3><p>' + esc(texto) + '</p></div>';
  }

  async function pintar() {
    const caja = $('#directorio');
    if (!caja) return;

    let empresas, unidades;
    try {
      /* Las dos de una vez: son independientes y así se abre en un viaje. */
      const [e, u] = await Promise.all([
        pedir('/empresas?select=codigo,nombre_comercial,eslogan,lema,descripcion,logo_url,' +
              'logo_texto,logo_acento,iniciales,color_primario,color_secundario&order=nombre_comercial'),
        pedir('/unidades?select=empresa_codigo,ciudad,activa'),
      ]);
      empresas = e;
      unidades = u;
    } catch (err) {
      caja.innerHTML = err.message === 'sin-nube'
        ? aviso('🔌', 'Sin conexión con la plataforma',
            'Esta página necesita la base en la nube para saber qué restaurantes hay.')
        : aviso('⚠️', 'No se pudo cargar la lista',
            'Vuelve a intentarlo en un momento. ' + err.message);
      return;
    }

    if (!empresas.length) {
      caja.innerHTML = aviso('🍽️', 'Todavía no hay restaurantes publicados',
        'Muy pronto vas a poder pedir desde aquí.');
      return;
    }

    /* Las unidades, agrupadas por empresa. Sólo las activas: un local
       cerrado no cuenta como sitio donde pedir. */
    const porEmpresa = {};
    unidades.forEach(function (u) {
      if (u.activa === false) return;
      (porEmpresa[u.empresa_codigo] = porEmpresa[u.empresa_codigo] || []).push(u);
    });

    caja.innerHTML = empresas
      .map((e) => tarjeta(e, porEmpresa[e.codigo] || []))
      .join('');
  }

  const anio = $('#anio');
  if (anio) anio.textContent = new Date().getFullYear();

  if (document.readyState === 'loading')
    document.addEventListener('DOMContentLoaded', pintar);
  else pintar();
})();
