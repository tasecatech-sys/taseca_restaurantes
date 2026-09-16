/* ==========================================================================
   NASCAR · ui.js
   Utilidades compartidas: formato, DOM, avisos, modales y carrito.
   ========================================================================== */

window.NASCAR = window.NASCAR || {};

NASCAR.UI = (function () {
  'use strict';

  /* ---------------------------------------------------------------
     Formato
     --------------------------------------------------------------- */
  const fmtCOP = new Intl.NumberFormat('es-CO', {
    style: 'currency',
    currency: 'COP',
    maximumFractionDigits: 0,
  });

  function money(n) {
    return fmtCOP.format(Number(n) || 0).replace(/\s/g, ' ');
  }

  function fechaLarga(iso) {
    const d = typeof iso === 'string' && iso.length === 10 ? NASCAR.Store.desdeISO(iso) : new Date(iso);
    return d.toLocaleDateString('es-CO', {
      weekday: 'long',
      day: 'numeric',
      month: 'long',
      year: 'numeric',
    });
  }

  function hora(iso) {
    return new Date(iso).toLocaleTimeString('es-CO', {
      hour: '2-digit',
      minute: '2-digit',
    });
  }

  function haceCuanto(iso) {
    const min = Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
    if (min < 1) return 'ahora';
    if (min < 60) return 'hace ' + min + ' min';
    const h = Math.floor(min / 60);
    if (h < 24) return 'hace ' + h + ' h';
    return 'hace ' + Math.floor(h / 24) + ' d';
  }

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  /* ---------------------------------------------------------------
     DOM
     --------------------------------------------------------------- */
  function $(sel, ctx) {
    return (ctx || document).querySelector(sel);
  }
  function $$(sel, ctx) {
    return Array.prototype.slice.call((ctx || document).querySelectorAll(sel));
  }
  function el(tag, attrs, html) {
    const n = document.createElement(tag);
    if (attrs) Object.keys(attrs).forEach((k) => n.setAttribute(k, attrs[k]));
    if (html != null) n.innerHTML = html;
    return n;
  }

  /* Delegación de eventos por atributo data-accion */
  function acciones(raiz, mapa) {
    raiz.addEventListener('click', function (ev) {
      const t = ev.target.closest('[data-accion]');
      if (!t || !raiz.contains(t)) return;
      const fn = mapa[t.dataset.accion];
      if (fn) {
        ev.preventDefault();
        fn(t, ev);
      }
    });
  }

  /* ---------------------------------------------------------------
     Avisos (toast)
     --------------------------------------------------------------- */
  let contenedorToast;
  function toast(mensaje, tipo) {
    if (!contenedorToast) {
      contenedorToast = el('div', { class: 'toast-wrap', 'aria-live': 'polite' });
      document.body.appendChild(contenedorToast);
    }
    const t = el('div', { class: 'toast toast--' + (tipo || 'ok') }, esc(mensaje));
    contenedorToast.appendChild(t);
    requestAnimationFrame(() => t.classList.add('is-in'));
    setTimeout(function () {
      t.classList.remove('is-in');
      setTimeout(() => t.remove(), 300);
    }, 3200);
  }

  /* ---------------------------------------------------------------
     Modal genérico
     --------------------------------------------------------------- */
  function modal(opciones) {
    const o = Object.assign({ titulo: '', contenido: '', ancho: 520, alCerrar: null }, opciones);

    const fondo = el('div', { class: 'modal-fondo' });
    fondo.innerHTML =
      '<div class="modal" role="dialog" aria-modal="true" style="max-width:' +
      o.ancho +
      'px">' +
      '<header class="modal__head"><h3>' +
      esc(o.titulo) +
      '</h3><button class="modal__x" aria-label="Cerrar">&times;</button></header>' +
      '<div class="modal__body"></div>' +
      '</div>';

    const cuerpo = $('.modal__body', fondo);
    if (typeof o.contenido === 'string') cuerpo.innerHTML = o.contenido;
    else cuerpo.appendChild(o.contenido);

    function cerrar() {
      fondo.classList.remove('is-in');
      setTimeout(() => fondo.remove(), 200);
      document.removeEventListener('keydown', onKey);
      if (o.alCerrar) o.alCerrar();
    }
    function onKey(e) {
      if (e.key === 'Escape') cerrar();
    }

    $('.modal__x', fondo).addEventListener('click', cerrar);
    fondo.addEventListener('click', (e) => {
      if (e.target === fondo) cerrar();
    });
    document.addEventListener('keydown', onKey);

    document.body.appendChild(fondo);
    requestAnimationFrame(() => fondo.classList.add('is-in'));

    return { cerrar: cerrar, cuerpo: cuerpo, raiz: fondo };
  }

  function confirmar(mensaje, alAceptar, textoBoton) {
    const m = modal({
      titulo: 'Confirmar',
      ancho: 420,
      contenido:
        '<p class="mb-16">' +
        esc(mensaje) +
        '</p><div class="fila fila--fin"><button class="btn btn--fantasma" data-no>Cancelar</button>' +
        '<button class="btn btn--rojo" data-si>' +
        esc(textoBoton || 'Sí, continuar') +
        '</button></div>',
    });
    $('[data-no]', m.raiz).onclick = m.cerrar;
    $('[data-si]', m.raiz).onclick = function () {
      m.cerrar();
      alAceptar();
    };
  }

  /* ---------------------------------------------------------------
     CARRITO
     Se guarda en sessionStorage con una clave por contexto, para que
     el carrito de una mesa no se mezcle con el de domicilio.
     --------------------------------------------------------------- */
  function Carrito(clave) {
    const K = 'nascar.carrito.' + clave;
    const suscriptores = [];
    let respaldo = null; // si sessionStorage está bloqueado (archivo local, incógnito)

    function leer() {
      if (respaldo) return respaldo;
      try {
        return JSON.parse(sessionStorage.getItem(K)) || [];
      } catch (e) {
        return [];
      }
    }
    function guardar(items) {
      try {
        sessionStorage.setItem(K, JSON.stringify(items));
        respaldo = null;
      } catch (e) {
        respaldo = items;
      }
      suscriptores.forEach((f) => f(items));
    }

    return {
      items: leer,
      onCambio: function (f) {
        suscriptores.push(f);
        f(leer());
      },
      agregar: function (producto, cantidad) {
        const items = leer();
        const n = Number(cantidad) || 1;
        const i = items.findIndex(
          (x) => x.refId === producto.refId && (x.notas || '') === (producto.notas || '')
        );
        if (i >= 0) items[i].cantidad += n;
        else items.push(Object.assign({}, producto, { cantidad: n }));
        guardar(items);
      },
      cambiarCantidad: function (indice, delta) {
        const items = leer();
        if (!items[indice]) return;
        items[indice].cantidad += delta;
        if (items[indice].cantidad <= 0) items.splice(indice, 1);
        guardar(items);
      },
      fijarNotas: function (indice, notas) {
        const items = leer();
        if (!items[indice]) return;
        items[indice].notas = notas;
        guardar(items);
      },
      quitar: function (indice) {
        const items = leer();
        items.splice(indice, 1);
        guardar(items);
      },
      vaciar: function () {
        guardar([]);
      },
      cantidad: function () {
        return leer().reduce((s, x) => s + x.cantidad, 0);
      },
      subtotal: function () {
        return leer().reduce((s, x) => s + x.precio * x.cantidad, 0);
      },
    };
  }

  /* ---------------------------------------------------------------
     Descargar un archivo generado en el navegador
     --------------------------------------------------------------- */
  function descargarArchivo(contenido, nombre, tipo) {
    const blob = new Blob([contenido], { type: tipo || 'text/plain;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = nombre;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1500);
  }

  /* Una fila de CSV con separador de punto y coma (lo que espera Excel
     en configuración regional española). */
  function filaCSV(campos) {
    return campos.map((c) => '"' + String(c == null ? '' : c).replace(/"/g, '""') + '"').join(';');
  }

  /* ---------------------------------------------------------------
     Sucursales
     --------------------------------------------------------------- */
  /* Busca en TODAS las sucursales, incluidas las desactivadas: un pedido
     o un cierre viejo puede apuntar a una que ya no está activa, y
     etiquetarlo con la sucursal equivocada sería peor que decir que no
     se conoce. */
  function sucursal(idSuc) {
    const todas = NASCAR.Store.getSucursales({ todas: true });
    const encontrada = todas.find((s) => Number(s.id) === Number(idSuc));
    if (encontrada) return encontrada;
    if (idSuc === undefined || idSuc === null) return todas[0] || sucursalDesconocida(idSuc);
    return sucursalDesconocida(idSuc);
  }

  /* Id de la sede con la que arrancan los formularios.

     Antes las pantallas leían NASCAR.SUCURSALES[0].id directamente, y
     eso reventaba con una empresa recién creada, que todavía no tiene
     ninguna. Aquí se devuelve null en ese caso: el formulario se queda
     sin sede propuesta y la validación del store da un error claro, en
     vez de tumbar el panel entero. */
  function sucursalPorDefectoId() {
    // La unidad activa del contexto manda: es donde se está trabajando
    const activa = NASCAR.Store.unidadActivaId ? NASCAR.Store.unidadActivaId() : null;
    if (activa) return activa;
    const activas = NASCAR.Store.getSucursales();
    if (activas.length) return activas[0].id;
    const todas = NASCAR.Store.getSucursales({ todas: true });
    return todas.length ? todas[0].id : null;
  }

  function sucursalDesconocida(idSuc) {
    return {
      id: idSuc,
      nombre: 'Unidad ' + idSuc,
      corto: 'Unidad ' + idSuc,
      direccion: '',
      ciudad: '',
      telefono: '',
      whatsapp: '',
      horario: '',
      mapa: '',
      mesas: 0,
      color: 'azul',
      zonas: [],
      activa: false,
      desconocida: true,
    };
  }

  /* ---------------------------------------------------------------
     WhatsApp
     El número nunca se escribe a mano en las pantallas: sale de la
     configuración de la sucursal y, si no tiene, de la configuración
     general del restaurante.
     --------------------------------------------------------------- */
  function numeroWhatsApp(sucursalId) {
    const cfg = NASCAR.Store.getConfig();
    if (sucursalId !== undefined && sucursalId !== null) {
      const s = sucursal(sucursalId);
      if (s && s.whatsapp) return String(s.whatsapp).replace(/\D/g, '');
    }
    return String((cfg.contacto && cfg.contacto.whatsapp) || '').replace(/\D/g, '');
  }

  function enlaceWhatsApp(sucursalId, mensaje) {
    const num = numeroWhatsApp(sucursalId);
    if (!num) return '';
    return 'https://wa.me/' + num + (mensaje ? '?text=' + encodeURIComponent(mensaje) : '');
  }

  /* ---------------------------------------------------------------
     Imágenes: comprimir antes de guardar

     localStorage es pequeño (unos 5 MB en total), así que una foto de
     celular sin tocar lo llenaría de una. Se redimensiona y se
     recomprime a JPEG antes de persistirla.
     Devuelve una promesa con { dataUrl, pesoKB, ancho, alto }.
     --------------------------------------------------------------- */
  function comprimirImagen(archivo, opciones) {
    const cfg = NASCAR.Store.getConfig().comprobantes || {};
    const o = Object.assign(
      {
        ladoMaximoPx: cfg.ladoMaximoPx || 1000,
        calidad: cfg.calidadJpeg || 0.72,
        formatos: cfg.formatos || ['image/jpeg', 'image/png', 'image/webp'],
        pesoMaximoKB: cfg.pesoMaximoKB || 600,
        pesoGuardadoMaximoKB: cfg.pesoGuardadoMaximoKB || 450,
      },
      opciones || {}
    );

    return new Promise(function (resolver, rechazar) {
      if (!archivo) return rechazar(new Error('No se seleccionó ningún archivo.'));

      const tipo = (archivo.type || '').toLowerCase();
      if (o.formatos.indexOf(tipo) < 0 && !/\.(jpe?g|png|webp)$/i.test(archivo.name || ''))
        return rechazar(new Error('Formato no admitido. Usa una imagen JPG, PNG o WEBP.'));

      const pesoKB = Math.round(archivo.size / 1024);
      if (pesoKB > o.pesoMaximoKB)
        return rechazar(
          new Error(
            'La imagen pesa ' + pesoKB + ' KB y el máximo son ' + o.pesoMaximoKB + ' KB. ' +
              'Tómala de nuevo con menor resolución o recórtala.'
          )
        );

      const lector = new FileReader();
      lector.onerror = () => rechazar(new Error('No se pudo leer el archivo.'));
      lector.onload = function () {
        const img = new Image();
        img.onerror = () => rechazar(new Error('El archivo no es una imagen válida.'));
        img.onload = function () {
          let { width: w, height: h } = img;
          const escala = Math.min(1, o.ladoMaximoPx / Math.max(w, h));
          w = Math.max(1, Math.round(w * escala));
          h = Math.max(1, Math.round(h * escala));

          const lienzo = document.createElement('canvas');
          lienzo.width = w;
          lienzo.height = h;
          const ctx = lienzo.getContext('2d');
          ctx.fillStyle = '#fff'; // los PNG con transparencia salen en negro sin esto
          ctx.fillRect(0, 0, w, h);
          ctx.drawImage(img, 0, 0, w, h);

          let dataUrl;
          try {
            dataUrl = lienzo.toDataURL('image/jpeg', o.calidad);
          } catch (e) {
            return rechazar(new Error('No se pudo procesar la imagen.'));
          }

          const guardadoKB = Math.round((dataUrl.length * 2) / 1024);
          if (guardadoKB > o.pesoGuardadoMaximoKB)
            return rechazar(
              new Error(
                'Aun comprimida la imagen ocupa ' + guardadoKB + ' KB, más de los ' +
                  o.pesoGuardadoMaximoKB + ' KB que caben. Recorta la foto al comprobante.'
              )
            );

          resolver({ dataUrl: dataUrl, pesoKB: guardadoKB, ancho: w, alto: h });
        };
        img.src = lector.result;
      };
      lector.readAsDataURL(archivo);
    });
  }

  function paramURL(nombre, porDefecto) {
    const v = new URLSearchParams(location.search).get(nombre);
    return v === null ? porDefecto : v;
  }

  /* ---------------------------------------------------------------
     Año en el pie de página + reveal al hacer scroll
     --------------------------------------------------------------- */
  function iniciarComunes() {
    $$('[data-anio]').forEach((n) => (n.textContent = new Date().getFullYear()));

    const objetivos = $$('.reveal');
    if (!objetivos.length) return;
    if (!('IntersectionObserver' in window)) {
      objetivos.forEach((n) => n.classList.add('is-visible'));
      return;
    }
    const io = new IntersectionObserver(
      function (entradas) {
        entradas.forEach(function (e) {
          if (e.isIntersecting) {
            e.target.classList.add('is-visible');
            io.unobserve(e.target);
          }
        });
      },
      { threshold: 0.12 }
    );
    objetivos.forEach((n) => io.observe(n));
  }

  return {
    money: money,
    fechaLarga: fechaLarga,
    hora: hora,
    haceCuanto: haceCuanto,
    esc: esc,
    $: $,
    $$: $$,
    el: el,
    acciones: acciones,
    toast: toast,
    modal: modal,
    confirmar: confirmar,
    Carrito: Carrito,
    descargarArchivo: descargarArchivo,
    filaCSV: filaCSV,
    sucursal: sucursal,
    sucursalPorDefectoId: sucursalPorDefectoId,
    numeroWhatsApp: numeroWhatsApp,
    enlaceWhatsApp: enlaceWhatsApp,
    comprimirImagen: comprimirImagen,
    paramURL: paramURL,
    iniciarComunes: iniciarComunes,
  };
})();
