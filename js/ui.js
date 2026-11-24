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
  /* -----------------------------------------------------------------
     UN BOTÓN QUE NO SE TOCA DOS VECES

     Las escrituras viajan por XHR síncrono: mientras la petición va y
     vuelve, la pantalla se queda congelada. Quien atiende cree que no
     registró y vuelve a tocar, y los toques se encolan.

     Esto bloquea el botón al primer toque y le pone un texto que explica
     la espera. Si la acción falla, el botón vuelve: devolviendo `false` o
     lanzando un error. Si sale bien, se queda bloqueado -ya no hay nada
     que tocar-.

     Es sólo la mitad visible del candado. La que de verdad impide la
     factura repetida está en la base: cada envío lleva su clave y la base
     devuelve el mismo pedido si le llega dos veces. Ver
     database/23_pedidos_sin_duplicados.sql.
     ----------------------------------------------------------------- */
  function ocupado(boton, textoEspera, accion) {
    if (!boton) return;
    if (boton.disabled) return;   // ya hay una en camino

    const antes = boton.innerHTML;
    boton.disabled = true;
    boton.innerHTML = textoEspera || 'Enviando…';

    const soltar = function () {
      boton.disabled = false;
      boton.innerHTML = antes;
    };

    /* Un respiro antes de la petición: si no, el navegador no alcanza a
       pintar «Enviando…» y la espera se ve como un cuelgue. */
    setTimeout(function () {
      let salioBien = false;
      try {
        salioBien = accion() !== false;
      } catch (e) {
        if (typeof toast === 'function') toast(e.message || 'No se pudo completar.', 'error');
      }
      /* Sólo se suelta si la acción avisó de que falló -devolviendo false o
         lanzando-, para poder reintentar. Si salió bien se queda bloqueado:
         el modal se cierra o la lista se repinta, y el botón desaparece con
         ellos. Soltarlo abriría una ventana de doble toque de 200 ms, que es
         justo lo que se quiere evitar. */
      if (!salioBien) soltar();
    }, 0);
  }

  /* El mismo candado, enganchado a un botón fijo. */
  function unaVez(boton, textoEspera, accion) {
    if (!boton) return;
    boton.addEventListener('click', function () {
      ocupado(boton, textoEspera, accion);
    });
  }

  /* La clave de un ENVÍO (no de un pedido): identifica el intento. Si hay
     que reintentar el mismo pedido se reutiliza la misma, y así la base
     sabe que es el mismo y no crea otra factura. */
  function claveEnvio() {
    try {
      if (window.crypto && typeof crypto.randomUUID === 'function') return crypto.randomUUID();
    } catch (e) {
      /* navegadores viejos: se arma a mano */
    }
    return 'e-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10);
  }

  /* Cómo se llama un pedido en pantalla. Cuatro tipos; el día que haya
     otro se añade aquí y no en seis sitios. */
  function etiquetaTipo(p, opciones) {
    const o = opciones || {};
    const conMesa = o.conMesa !== false;
    if (!p) return '';
    if (p.tipo === 'mesa') return (o.icono ? '🍽️ ' : '') + (conMesa ? 'Mesa ' + esc(p.mesa) : 'Mesa');
    if (p.tipo === 'mostrador') return (o.icono ? '🧾 ' : '') + 'Mostrador';
    if (p.tipo === 'recoger') return (o.icono ? '🥡 ' : '') + 'Recoge en el local';
    return (o.icono ? '🛵 ' : '') + 'Domicilio';
  }

  /* El color del distintivo según el tipo.

     Ámbar para el que recoge porque en el tablero hay que distinguirlo de
     un domicilio de un vistazo: el rojo quiere decir «sale a la calle» y
     éste no sale, espera a que vengan por él. */
  function colorTipo(p) {
    if (!p) return 'badge--rojo';
    if (p.tipo === 'mesa') return 'badge--azul';
    if (p.tipo === 'mostrador') return 'badge--verde';
    if (p.tipo === 'recoger') return 'badge--ambar';
    return 'badge--rojo';
  }

  /* ---------------------------------------------------------------
     EL CAMBIO EN EFECTIVO

     Cuando el cliente paga con un billete hay que devolverle, y hasta
     ahora esa resta se hacía de cabeza, de pie, frente al cliente y con
     fila detrás. Aquí se escribe con cuánto paga y el cambio se ve en
     grande ANTES de confirmar, que es cuando todavía se puede corregir.

     Sólo aparece con EFECTIVO: lo que entra por datáfono, transferencia
     o billetera entra por el valor exacto y no hay nada que devolver.

     No guarda nada. Es una calculadora en el sitio donde hace falta.
     --------------------------------------------------------------- */

  const fmtMiles = new Intl.NumberFormat('es-CO', { maximumFractionDigits: 0 });

  /** Puntos de miles para leer la cifra mientras se escribe: 25000 → «25.000». */
  function conMiles(n) {
    return fmtMiles.format(Math.round(Number(n) || 0));
  }

  /** Lo escrito, como número. «$ 25.000» → 25000; vacío o sin cifras → null. */
  function montoEscrito(texto) {
    const d = String(texto == null ? '' : texto).replace(/\D/g, '');
    if (!d) return null;
    /* Un dedo apoyado en el 9 no puede volverse un número absurdo que
       rompa la resta. El tope es alto a propósito: cabe cualquier cuenta
       real y no cabe un error de tecleo infinito. */
    return Math.min(Number(d), 99999999);
  }

  /**
   * Con cuánto suele pagar alguien que debe `total`.
   *
   * No son múltiplos arbitrarios: son los redondeos que de verdad se
   * usan con los billetes que circulan. Para 23.400 → 25.000, 30.000 y
   * 40.000; para 8.500 → 10.000, 20.000 y 50.000.
   */
  function montosProbables(total) {
    const t = Math.max(0, Math.ceil(Number(total) || 0));
    const vistos = {};
    const salida = [];
    [5000, 10000, 20000, 50000, 100000].forEach(function (paso) {
      const m = Math.ceil(t / paso) * paso;
      if (m > t && !vistos[m]) {
        vistos[m] = 1;
        salida.push(m);
      }
    });
    return salida.sort((a, b) => a - b).slice(0, 3);
  }

  /** El HTML del bloque. `pre` prefija los id para poder usarlo dos veces
      en la misma página sin que choquen. */
  function bloqueCambio(total, pre, recibidoInicial) {
    pre = pre || 'cb';
    const valor = recibidoInicial ? conMiles(recibidoInicial) : '';
    return (
      '<div class="cambio" id="' + pre + 'Caja">' +
      '<label class="campo"><span>¿Con cuánto paga?</span>' +
      '<input class="input cambio__monto" id="' + pre + 'Recibido" type="text" inputmode="numeric" ' +
      'autocomplete="off" value="' + esc(valor) + '" placeholder="' + esc(conMiles(total)) + '"></label>' +
      '<div class="cambio__rapidos">' +
      '<button type="button" class="btn btn--fantasma btn--xs" data-cambio-monto="' + total + '">Justo</button>' +
      montosProbables(total)
        .map(function (m) {
          return '<button type="button" class="btn btn--fantasma btn--xs" data-cambio-monto="' + m + '">' +
            esc(conMiles(m)) + '</button>';
        })
        .join('') +
      '</div>' +
      '<div class="cambio__resultado" id="' + pre + 'Resultado" aria-live="polite"></div>' +
      '</div>'
    );
  }

  /**
   * Enciende el bloque: los botones rápidos, los puntos de miles y el
   * cambio en vivo.
   *
   * Devuelve una función que dice en qué estado está:
   *     { recibido, cambio, falta }
   * `falta > 0` significa que lo recibido NO alcanza: quien llama decide
   * si eso bloquea el cobro (en caja, sí).
   */
  function montarCambio(raiz, total, pre, alCambiar) {
    pre = pre || 'cb';
    const vacio = { recibido: null, cambio: 0, falta: 0 };
    const caja = $('#' + pre + 'Caja', raiz);
    if (!caja) return function () { return vacio; };

    const campo = $('#' + pre + 'Recibido', caja);
    const salida = $('#' + pre + 'Resultado', caja);
    let estado = vacio;

    function pintar(normalizar) {
      const r = montoEscrito(campo.value);

      /* Reescribir el campo en cada tecla movería el cursor al final y
         haría imposible corregir una cifra por el medio. Se reescribe
         sólo si el cursor YA está al final, o al salir del campo. */
      if (r !== null && (normalizar || campo.selectionStart === campo.value.length)) {
        const texto = conMiles(r);
        if (campo.value !== texto) {
          campo.value = texto;
          try {
            campo.setSelectionRange(texto.length, texto.length);
          } catch (e) {
            /* input oculto o de un tipo que no deja mover el cursor */
          }
        }
      }

      estado =
        r === null
          ? vacio
          : { recibido: r, cambio: Math.max(0, r - total), falta: Math.max(0, total - r) };

      if (r === null) {
        salida.innerHTML = '';
      } else if (estado.falta > 0) {
        salida.innerHTML =
          '<div class="cambio__falta">No alcanza · faltan <b>' + esc(money(estado.falta)) + '</b></div>';
      } else if (estado.cambio === 0) {
        salida.innerHTML = '<div class="cambio__justo">Pagó justo · no hay que devolver</div>';
      } else {
        salida.innerHTML =
          '<div class="cambio__devolver"><span>Devuelve</span><b>' + esc(money(estado.cambio)) + '</b></div>';
      }

      if (alCambiar) alCambiar(estado);
    }

    campo.addEventListener('input', function () { pintar(false); });
    campo.addEventListener('blur', function () { pintar(true); });
    caja.addEventListener('click', function (ev) {
      const b = ev.target.closest('[data-cambio-monto]');
      if (!b) return;
      ev.preventDefault();
      campo.value = conMiles(b.dataset.cambioMonto);
      pintar(true);
      campo.focus();
    });

    pintar(true);
    return function () { return estado; };
  }

  /* =================================================================
     PAGO DIVIDIDO (migración 56)

     Una fila por método: «Efectivo 20.000» + «Nequi …». La ÚLTIMA fila no
     se escribe: se llena sola con lo que falta de la cuenta, así la caja
     sólo dice cuánto le dieron por un lado y el resto sale solo.

     `cuenta` es subtotal + domicilio, SIN recargo. Si un método tiene
     recargo, se calcula sobre su parte y se muestra en su fila; el total
     a recibir es la cuenta más esos recargos.

     montarPagoDividido(raiz, {
       pre, cuenta, metodos: [{id, nombre}], empresaId, inicial: [m1, m2],
       alCambiar(r)
     })
     Devuelve leer(), que da lo de store.calcularPagoDividido más:
       efectivo  lo que entra en billete (para el cambio y el cajón)
       cambio    { recibido, cambio, falta } del efectivo
     ================================================================= */
  function bloquePagoDividido(pre) {
    pre = pre || 'pd';
    return (
      '<div class="pago-dividido" id="' + pre + 'Div">' +
      '<div class="pago-dividido__filas" id="' + pre + 'DivFilas"></div>' +
      '<button type="button" class="btn btn--fantasma btn--xs" id="' + pre + 'DivMas">+ Otro método</button>' +
      '<div class="pago-dividido__resumen" id="' + pre + 'DivResumen" aria-live="polite"></div>' +
      '<div id="' + pre + 'DivCambio"></div>' +
      '</div>'
    );
  }

  function montarPagoDividido(raiz, op) {
    const pre = op.pre || 'pd';
    const S = NASCAR.Store;
    const cuenta = Math.round(Number(op.cuenta) || 0);
    const metodos = op.metodos || [];
    const caja = $('#' + pre + 'Div', raiz);
    const cajaFilas = $('#' + pre + 'DivFilas', caja);
    const resumen = $('#' + pre + 'DivResumen', caja);
    const marcoCambio = $('#' + pre + 'DivCambio', caja);
    const botonMas = $('#' + pre + 'DivMas', caja);

    // Lo sugerido sólo vale si está entre los métodos que se ofrecen
    const ini = (op.inicial || []).filter((id) => metodos.some((m) => m.id === id));
    const primero = ini[0] || (metodos[0] || {}).id;
    const segundo = (ini[1] !== primero && ini[1]) || (metodos.find((m) => m.id !== primero) || {}).id;
    // La última fila no guarda base: es lo que falta
    const filas = [{ metodo: primero, base: null }, { metodo: segundo, base: null }];

    let efectivoMontado = null;
    let leerCambio = function () { return { recibido: null, cambio: 0, falta: 0 }; };
    let ultimoRecibido = null;
    let resultado = null;

    const esEfectivo = (id) => id === 'efectivo' || (NASCAR.GRUPO_DE_METODO || {})[id] === 'efectivo';
    const nombre = (id) => ((metodos.find((m) => m.id === id) || {}).nombre) || id;

    function restante() {
      const escrito = filas.slice(0, -1).reduce((s, f) => s + (Number(f.base) || 0), 0);
      return cuenta - escrito;
    }

    function partes() {
      return filas.map((f, i) => ({
        metodo: f.metodo,
        base: i === filas.length - 1 ? restante() : Number(f.base) || 0,
      }));
    }

    function pintarFilas() {
      cajaFilas.innerHTML = filas
        .map(function (f, i) {
          const ultima = i === filas.length - 1;
          return (
            '<div class="pago-dividido__fila" data-fila="' + i + '">' +
            '<select class="select" data-pd-metodo="' + i + '" aria-label="Método de la parte ' + (i + 1) + '">' +
            metodos.map((m) => '<option value="' + esc(m.id) + '"' + (m.id === f.metodo ? ' selected' : '') + '>' +
              esc(m.nombre) + '</option>').join('') +
            '</select>' +
            '<input class="input cambio__monto" type="text" inputmode="numeric" autocomplete="off" ' +
            'data-pd-base="' + i + '"' +
            (ultima
              ? ' readonly tabindex="-1" title="Se llena sola con lo que falta de la cuenta"'
              : ' placeholder="¿Cuánto?" value="' + (f.base ? esc(conMiles(f.base)) : '') + '"') +
            '>' +
            (filas.length > 2
              ? '<button type="button" class="btn btn--fantasma btn--xs" data-pd-quitar="' + i + '" aria-label="Quitar esta parte">✕</button>'
              : '') +
            '<span class="pago-dividido__nota mini tenue" data-pd-nota="' + i + '"></span>' +
            '</div>'
          );
        })
        .join('');
      botonMas.classList.toggle('oculto', filas.length >= metodos.length);
      recalcular();
    }

    function recalcular() {
      const r = S.calcularPagoDividido(partes(), cuenta, op.empresaId);
      resultado = r;

      // La última fila muestra lo que falta (o el exceso, en rojo)
      const ultimaInput = $('[data-pd-base="' + (filas.length - 1) + '"]', cajaFilas);
      const falta = restante();
      if (ultimaInput) {
        ultimaInput.value = conMiles(Math.max(0, falta));
        ultimaInput.classList.toggle('input--error', falta <= 0);
      }

      r.partes.forEach(function (x, i) {
        const nota = $('[data-pd-nota="' + i + '"]', cajaFilas);
        if (nota) nota.textContent = x.recargo > 0 && x.base > 0
          ? '+ recargo ' + money(x.recargo) + ' = ' + money(x.valor)
          : '';
      });

      resumen.innerHTML = r.error
        ? '<span class="ambar">' + esc(falta <= 0 && !r.error.includes('dos veces')
            ? 'Lo escrito ya cubre toda la cuenta: baja una parte o quítala.'
            : r.error) + '</span>'
        : 'Total a recibir <b>' + esc(money(r.total)) + '</b>' +
          (r.recargo > 0 ? ' <span class="tenue">(incluye ' + esc(money(r.recargo)) + ' de recargo)</span>' : '') +
          '<br><span class="tenue">' + esc(r.partes.map((x) => nombre(x.metodo) + ' ' + money(x.valor)).join(' + ')) + '</span>';

      // Cambio sólo para lo que entra en billete
      const efectivo = r.error ? 0 : r.partes.filter((x) => esEfectivo(x.metodo)).reduce((s, x) => s + x.valor, 0);
      if (efectivo !== efectivoMontado) {
        ultimoRecibido = leerCambio().recibido || ultimoRecibido;
        efectivoMontado = efectivo;
        if (efectivo > 0) {
          marcoCambio.innerHTML = '<p class="mini tenue" style="margin:8px 0 0">En efectivo: <b>' +
            esc(money(efectivo)) + '</b></p>' + bloqueCambio(efectivo, pre + 'Ef', ultimoRecibido);
          leerCambio = montarCambio(marcoCambio, efectivo, pre + 'Ef');
        } else {
          marcoCambio.innerHTML = '';
          leerCambio = function () { return { recibido: null, cambio: 0, falta: 0 }; };
        }
      }

      if (op.alCambiar) op.alCambiar(leer());
    }

    function leer() {
      const r = resultado || S.calcularPagoDividido(partes(), cuenta, op.empresaId);
      return Object.assign({}, r, { efectivo: efectivoMontado || 0, cambio: leerCambio() });
    }

    cajaFilas.addEventListener('change', function (ev) {
      const s = ev.target.closest('[data-pd-metodo]');
      if (!s) return;
      filas[Number(s.dataset.pdMetodo)].metodo = s.value;
      recalcular();
    });
    cajaFilas.addEventListener('input', function (ev) {
      const c = ev.target.closest('[data-pd-base]');
      if (!c || c.readOnly) return;
      filas[Number(c.dataset.pdBase)].base = montoEscrito(c.value);
      recalcular();
    });
    cajaFilas.addEventListener('focusout', function (ev) {
      const c = ev.target.closest('[data-pd-base]');
      if (!c || c.readOnly) return;
      const v = montoEscrito(c.value);
      c.value = v ? conMiles(v) : '';
    });
    cajaFilas.addEventListener('click', function (ev) {
      const q = ev.target.closest('[data-pd-quitar]');
      if (!q) return;
      ev.preventDefault();
      filas.splice(Number(q.dataset.pdQuitar), 1);
      // La que quede de última pasa a ser «lo que falta»
      filas[filas.length - 1].base = null;
      pintarFilas();
    });
    botonMas.addEventListener('click', function (ev) {
      ev.preventDefault();
      const usados = filas.map((f) => f.metodo);
      const libre = (metodos.find((m) => usados.indexOf(m.id) < 0) || {}).id;
      if (!libre) return;
      // La que era última deja de serlo: se queda con lo que faltaba
      const anterior = filas[filas.length - 1];
      anterior.base = Math.max(0, restante());
      filas.push({ metodo: libre, base: null });
      pintarFilas();
    });

    pintarFilas();
    const primerCampo = $('[data-pd-base="0"]', cajaFilas);
    if (primerCampo && op.enfocar !== false) primerCampo.focus();
    return leer;
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

    /* Un clic FUERA no cierra.

       Estos cuadros llevan trabajo escrito dentro —el valor de la base de
       caja, el motivo de una anulación, el conteo de un cierre— y un clic
       de más al lado lo borraba todo sin preguntar. Se sale por la X, por
       «Cancelar» o con Escape: las tres son decisiones, no resbalones.

       Pero el clic tampoco se traga en silencio, que parecería que la
       pantalla se quedó pegada: el cuadro se mueve un instante y se
       enciende la X, que es por donde se sale. Se escucha `mousedown` y
       no `click` a propósito, porque seleccionar texto dentro y soltar el
       ratón fuera también dispara un `click` en el fondo, y eso no es
       querer salir. */
    fondo.addEventListener('mousedown', function (e) {
      if (e.target !== fondo) return;
      const caja = $('.modal', fondo);
      if (!caja) return;
      caja.classList.remove('modal--insiste');
      void caja.offsetWidth; // reinicia la animación si se insiste
      caja.classList.add('modal--insiste');
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
        // Mismo producto con otra gaseosa elegida (58) es otra línea
        const i = items.findIndex(
          (x) => x.refId === producto.refId && (x.notas || '') === (producto.notas || '') &&
            (x.claveCambios || '') === (producto.claveCambios || '')
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
     Elegir en la receta (migración 58): la gaseosa del combo.

     producto.cambios = [{ de, grupo, opciones: [{ id, nombre }] }], con
     la de la receta primero. Sin nada que elegir, alElegir(null) enseguida.
     Con un solo grupo, tocar la opción ya agrega; con varios se marca uno
     de cada grupo y se toca «Agregar». alElegir recibe:
       { cambios: [{ de, a }], detalle: 'Gaseosa 1.5: Coca-Cola 1.5',
         clave: '12>15' }   ← la clave separa líneas del carrito
     --------------------------------------------------------------- */
  function resultadoCambios(grupos, elegido) {
    const cambios = grupos.map((g) => ({ de: Number(g.de), a: Number(elegido[g.de]) }));
    return {
      cambios: cambios,
      detalle: grupos
        .map((g) => g.grupo + ': ' +
          ((g.opciones || []).find((o) => Number(o.id) === Number(elegido[g.de])) || {}).nombre)
        .join(' · '),
      clave: cambios.map((c) => c.de + '>' + c.a).join(','),
    };
  }

  function elegirCambios(producto, alElegir) {
    const grupos = ((producto && producto.cambios) || []).filter((g) => (g.opciones || []).length > 1);
    if (!grupos.length) return alElegir(null);

    const elegido = {};
    grupos.forEach((g) => { elegido[g.de] = Number(g.opciones[0].id); });
    const varios = grupos.length > 1;
    const m = modal({
      titulo: producto.nombre,
      ancho: 420,
      contenido:
        grupos.map((g) =>
          '<div class="campo"><span>¿Qué ' + esc(String(g.grupo).toLowerCase()) + '?</span>' +
          '<div data-de="' + Number(g.de) + '" style="display:flex;flex-wrap:wrap;gap:8px">' +
          g.opciones.map((o) =>
            '<button type="button" class="btn ' + (varios && Number(o.id) === elegido[g.de] ? 'btn--rojo' : 'btn--fantasma') +
            '" data-a="' + Number(o.id) + '">' + esc(o.nombre) + '</button>').join('') +
          '</div></div>').join('') +
        (varios ? '<div class="fila fila--fin"><button type="button" class="btn btn--rojo" data-listo>Agregar</button></div>' : ''),
    });

    let hecho = false; // un toque doble no agrega dos veces
    function terminar() {
      if (hecho) return;
      hecho = true;
      m.cerrar();
      alElegir(resultadoCambios(grupos, elegido));
    }
    m.raiz.addEventListener('click', function (e) {
      const b = e.target.closest('[data-a]');
      if (b) {
        const caja = b.closest('[data-de]');
        elegido[caja.dataset.de] = Number(b.dataset.a);
        $$('[data-a]', caja).forEach(function (x) {
          x.classList.toggle('btn--rojo', x === b);
          x.classList.toggle('btn--fantasma', x !== b);
        });
        if (!varios) terminar();
        return;
      }
      if (e.target.closest('[data-listo]')) terminar();
    });
  }

  /* Lo elegido, puesto en una línea del carrito (o nada si no hubo). */
  function conCambios(linea, r) {
    if (!r) return linea;
    return Object.assign(linea, { cambios: r.cambios, detalle: r.detalle, claveCambios: r.clave });
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
  /**
   * La foto de un plato, para la tarjeta de la carta.
   *
   * La misma en el portal del cliente y en la pantalla de mesa, que
   * pintan la misma tarjeta: si se escribiera en cada sitio, mañana una
   * de las dos se quedaría atrás.
   *
   * Sin foto devuelve cadena vacía, no un hueco ni una imagen de
   * relleno: una carta sin fotos tiene que seguir viéndose igual que
   * antes de que esto existiera.
   */
  function fotoPlato(plato) {
    const src = plato && plato.imagen ? String(plato.imagen).trim() : '';
    if (!src) return '';
    return (
      '<figure class="plato__marco">' +
      '<img class="plato__foto" src="' + esc(src) + '" alt="" ' +
      'loading="lazy" decoding="async">' +
      '</figure>'
    );
  }

  /**
   * LA TARJETA DE UN PLATO, completa.
   *
   * Se escribía dos veces —en el portal del cliente y en la pantalla de
   * mesa— con el mismo marcado copiado. Eran ya dos copias de diez
   * líneas de HTML en cadenas: cualquier cambio de diseño había que
   * hacerlo en los dos sitios y acordarse de los dos.
   *
   * Qué recibe:
   *   plato      el producto de la carta
   *   opciones   .etiqueta  ['badge--rojo', '★ El más pedido'] o nada
   *              .icono     el emoji de su categoría, si no hay foto
   *
   * CÓMO ESTÁ ARMADA, que importa para el CSS:
   *
   *   .plato                    sin relleno, recorta lo que sobresale
   *     .plato__marco           la foto, en 4:3 (sólo si hay foto)
   *       .plato__foto
   *       .plato__sello         la etiqueta, encima de la foto
   *     .plato__cuerpo          aquí vive TODO el relleno
   *       .plato__sello         la etiqueta, si no hay foto donde ponerla
   *       h3.plato__nombre
   *       p.plato__desc
   *       .plato__pie           precio a la izquierda, botón a la derecha
   *
   * La foto no se sangra con márgenes negativos: antes compensaba a mano
   * el relleno de la tarjeta, así que cambiar ese relleno descolocaba la
   * foto. Ahora el relleno está un nivel más adentro y la foto no sabe
   * nada de él.
   */
  function tarjetaPlato(plato, opciones) {
    const o = opciones || {};
    const et = o.etiqueta;
    const nombre = esc(plato.nombre);

    /* Sin foto, el emoji de la categoría a tamaño grande y apagado.

       No es un adorno: en una rejilla donde la mayoría de las tarjetas
       llevan foto, la que no la lleva se estiraba hasta la altura de las
       demás y quedaba un rectángulo vacío que parece un error de carga.
       Con el emoji el hueco se lee como lo que es —un plato sin foto
       todavía— y la rejilla conserva su ritmo.

       El emoji sale de la categoría, que ya lo tiene; no se inventa
       ninguno ni se pone una foto de relleno que no sea del negocio. */
    const foto =
      fotoPlato(plato) ||
      (o.icono
        ? '<figure class="plato__marco plato__marco--vacio" aria-hidden="true">' +
          '<span class="plato__icono">' + esc(o.icono) + '</span>' +
          '</figure>'
        : '');

    /* El sello va sobre la foto. Sin foto no hay dónde ponerlo, así que
       entra en el cuerpo como una línea más: la etiqueta es información
       («el más pedido»), no decoración, y no puede desaparecer porque al
       producto le falte la imagen. */
    const sello = et
      ? '<span class="plato__sello badge ' + et[0] + '">' + et[1] + '</span>'
      : '';

    const accion = plato.disponible
      ? '<button class="btn btn--azul plato__add" data-add-carta="' + plato.id + '"' +
        ' aria-label="Agregar ' + nombre + '">Agregar</button>'
      : '<span class="badge badge--gris">Agotado</span>';

    return (
      '<article class="plato' +
      (plato.disponible ? '' : ' no-disp') +
      (foto ? '' : ' plato--sin-foto') +
      '">' +
      (foto ? foto.replace('</figure>', sello + '</figure>') : '') +
      '<div class="plato__cuerpo">' +
      (foto ? '' : sello) +
      '<h3 class="plato__nombre">' + nombre + '</h3>' +
      (plato.desc ? '<p class="plato__desc">' + esc(plato.desc) + '</p>' : '') +
      '<div class="plato__pie">' +
      '<span class="plato__precio">' + money(plato.precio) + '</span>' +
      accion +
      '</div>' +
      '</div>' +
      '</article>'
    );
  }

  function iniciarComunes() {
    $$('[data-anio]').forEach((n) => (n.textContent = new Date().getFullYear()));

    /* Una foto que no carga no deja el icono de imagen rota en la carta:
       se quita y la tarjeta queda como si no tuviera. La dirección la
       escribe una persona, así que esto va a pasar.

       En captura porque el evento `error` de una imagen no burbujea. */
    document.addEventListener(
      'error',
      function (e) {
        const n = e.target;
        if (!n || !n.classList || !n.classList.contains('plato__foto')) return;
        /* Se va el MARCO, no sólo la imagen: quitar la <img> dejaba un
           rectángulo gris de 4:3 vacío, que se ve peor que no tener
           foto. La tarjeta pasa a verse como las que no la tienen. */
        const marco = n.closest('.plato__marco');
        const tarjeta = n.closest('.plato');
        if (tarjeta) tarjeta.classList.add('plato--sin-foto');
        (marco || n).remove();
      },
      true
    );

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
    conMiles: conMiles,
    montoEscrito: montoEscrito,
    montosProbables: montosProbables,
    bloqueCambio: bloqueCambio,
    montarCambio: montarCambio,
    bloquePagoDividido: bloquePagoDividido,
    montarPagoDividido: montarPagoDividido,
    fechaLarga: fechaLarga,
    hora: hora,
    haceCuanto: haceCuanto,
    esc: esc,
    $: $,
    $$: $$,
    unaVez: unaVez,
    ocupado: ocupado,
    etiquetaTipo: etiquetaTipo,
    colorTipo: colorTipo,
    claveEnvio: claveEnvio,
    el: el,
    acciones: acciones,
    toast: toast,
    modal: modal,
    confirmar: confirmar,
    Carrito: Carrito,
    elegirCambios: elegirCambios,
    conCambios: conCambios,
    descargarArchivo: descargarArchivo,
    filaCSV: filaCSV,
    sucursal: sucursal,
    sucursalPorDefectoId: sucursalPorDefectoId,
    numeroWhatsApp: numeroWhatsApp,
    enlaceWhatsApp: enlaceWhatsApp,
    comprimirImagen: comprimirImagen,
    fotoPlato: fotoPlato,
    tarjetaPlato: tarjetaPlato,
    paramURL: paramURL,
    iniciarComunes: iniciarComunes,
  };
})();
