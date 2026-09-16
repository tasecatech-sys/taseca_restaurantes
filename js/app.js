/* ==========================================================================
   NASCAR · app.js
   Lógica de la landing pública: menú del día, carta, carrito, checkout
   de domicilio y seguimiento de pedidos.
   ========================================================================== */

(function () {
  'use strict';

  const S = NASCAR.Store;
  const U = NASCAR.UI;
  const M = NASCAR.MenuDia; // pintor compartido del menú del día

  /* Raíz de esta vista.
     En la versión de varios archivos no existe [data-vista], así que la raíz
     es todo el documento y todo funciona como siempre. En la versión de un
     solo archivo (nascar-movil.html) las tres pantallas viven en el mismo
     documento y comparten nombres de id, por eso cada controlador limita sus
     búsquedas y sus eventos a su propio contenedor. */
  const RAIZ = document.querySelector('[data-vista="publico"]') || document;
  const EVENTOS = RAIZ === document ? document.body : RAIZ;
  const $ = (sel) => U.$(sel, RAIZ);
  const $$ = (sel) => U.$$(sel, RAIZ);

  const carrito = U.Carrito('domicilio');

  let categoriaActiva = 'todos';
  let paso = 'carrito'; // carrito | datos | pago | listo
  let borrador = {
    sucursalId: U.sucursalPorDefectoId(),
    nombre: '',
    telefono: '',
    direccion: '',
    zona: '',
    notas: '',
    metodoPago: 'efectivo',
    pagaCon: '',
    referencia: '',
    comprobante: null, // { dataUrl, nombreArchivo, pesoKB }
  };
  let ultimoPedido = null;

  /* Unidad / local en la que pide el cliente. Cada unidad tiene su carta y
     su menú del día: el portal muestra UNA a la vez, nunca mezcladas. Se
     llega a ella con ?unidad=ID (un enlace por local) o eligiéndola aquí,
     y se recuerda en la dirección de la página. */
  let unidadPortal = unidadInicial();

  function unidadInicial() {
    const activas = S.getSucursales();
    const pedida = Number(U.paramURL('unidad', null));
    if (pedida && activas.some((s) => Number(s.id) === pedida)) return pedida;
    return activas.length ? Number(activas[0].id) : null;
  }

  function recordarUnidadEnURL() {
    try {
      const url = new URL(location.href);
      url.searchParams.set('unidad', String(unidadPortal));
      history.replaceState(null, '', url.pathname + url.search + url.hash);
    } catch (e) {
      /* archivo local o navegador que no lo permite: se elige igual */
    }
  }

  /* Cambiar de local. Si el pedido ya tiene productos de otro, se avisa:
     cada pedido sale de UNA sola unidad. */
  function cambiarUnidadPortal(nuevaId, despues) {
    nuevaId = Number(nuevaId);
    if (!nuevaId || nuevaId === Number(unidadPortal)) {
      if (despues) despues();
      return;
    }
    const aplicar = function () {
      unidadPortal = nuevaId;
      borrador.sucursalId = nuevaId;
      borrador.zona = '';
      categoriaActiva = 'todos';
      recordarUnidadEnURL();
      pintarUnidadPortal();
      if (despues) despues();
    };

    const delPedido = sucursalObligatoria();
    if (delPedido && delPedido !== nuevaId && carrito.items().length) {
      pintarSelectorSucursalDia(); // el selector vuelve a la actual mientras se decide
      return U.confirmar(
        'Tu pedido tiene productos de ' + U.sucursal(delPedido).nombre + '. Cada pedido sale de una sola ' +
          'unidad: si cambias a ' + U.sucursal(nuevaId).nombre + ' se vacía. ¿Continuar?',
        function () {
          carrito.vaciar();
          aplicar();
        },
        'Sí, cambiar de local'
      );
    }
    aplicar();
  }

  function pintarUnidadPortal() {
    pintarSelectorSucursalDia();
    pintarDia();
    pintarFiltros();
    pintarCarta();
    pintarSucursales();
    pintarPie();
  }

  /* =================================================================
     MENÚ DEL DÍA
     ================================================================= */
  function pintarSelectorSucursalDia() {
    const sel = $('#filtroSucursalDia');
    const activas = S.getSucursales();
    if (!activas.some((s) => Number(s.id) === Number(unidadPortal)))
      unidadPortal = activas.length ? Number(activas[0].id) : null;
    sel.innerHTML = activas
      .map(
        (s) =>
          '<option value="' + s.id + '"' + (Number(s.id) === Number(unidadPortal) ? ' selected' : '') + '>' +
          S.getTipoNegocio(s.tipoNegocio).icono + ' ' + U.esc(s.nombre) + '</option>'
      )
      .join('');
    sel.value = unidadPortal ? String(unidadPortal) : '';
  }

  /* Cada sucursal publica UNA modalidad —menú armado o menú del chef— y
     getMenuPublico() dice cuál y con qué. Aquí sólo se pinta; el dibujo
     de las tarjetas es el mismo de la mesa y del mesero (js/menu-dia.js). */
  function pintarDia() {
    const cont = $('#listaDia');
    const suc = unidadPortal ? U.sucursal(unidadPortal) : null;
    const menu = suc ? S.getMenuPublico(S.hoy(), suc.id) : null;
    const html = menu ? M.tarjetas(menu, { sucursal: suc, clave: 'pub' }) : '';

    /* El encabezado sale de la configuración de la unidad, no del HTML:
       el administrador lo cambia desde el panel (ver getTextoMenuDia). */
    const texto = menu ? menu.texto : S.getTextoMenuDia(S.hoy(), unidadPortal);
    if ($('#tituloDia')) $('#tituloDia').textContent = texto.titulo;
    if ($('#mensajeDia')) $('#mensajeDia').textContent = texto.mensaje;

    if (!html) {
      cont.innerHTML =
        '<div class="vacio" style="grid-column:1/-1">' +
        '<div class="vacio__ico">🍽️</div>' +
        '<h3>Todavía no publicamos el menú de hoy' + (suc ? ' en ' + U.esc(suc.nombre) : '') + '</h3>' +
        '<p>El menú del día se publica cada mañana.' +
        (sinCarta() ? '' : ' Mientras tanto, la carta está disponible.') + '</p>' +
        (sinCarta() ? '' : '<a href="#carta" class="btn btn--fantasma btn--sm">Ir a la carta</a>') +
        '</div>';
      return;
    }

    M.pintar(cont, html);
  }

  /* =================================================================
     CARTA
     ================================================================= */
  function pintarFiltros() {
    const cont = $('#filtrosCarta');
    // Las categorías de la unidad elegida, no las de toda la empresa
    const deUnidad = unidadPortal ? S.getCategorias({ sucursalId: unidadPortal }) : [];
    if (categoriaActiva !== 'todos' && !deUnidad.some((c) => c.id === categoriaActiva)) categoriaActiva = 'todos';
    const cats = [{ id: 'todos', nombre: 'Todo', icono: '🏁' }].concat(deUnidad);
    cont.innerHTML = cats
      .map(
        (c) =>
          '<button class="chip' +
          (c.id === categoriaActiva ? ' is-activo' : '') +
          '" data-cat="' + c.id + '">' + c.icono + ' ' + U.esc(c.nombre) + '</button>'
      )
      .join('');

    if (cont.dataset.listo === '1') return; // el manejador se pone una sola vez
    cont.dataset.listo = '1';
    cont.addEventListener('click', function (e) {
      const b = e.target.closest('[data-cat]');
      if (!b) return;
      categoriaActiva = b.dataset.cat;
      $$('.chip', cont).forEach((c) => c.classList.toggle('is-activo', c === b));
      pintarCarta();
    });
  }

  /* Hay locales que no llevan carta: los restaurantes trabajan sólo con
     el menú del día. En ellos la sección de carta no se muestra, en vez de
     quedar vacía. */
  function sinCarta() {
    return !unidadPortal || S.getCarta({ sucursalId: unidadPortal }).length === 0;
  }

  function pintarCarta() {
    const cont = $('#listaCarta');
    const oculta = sinCarta();
    const seccion = $('#carta');
    if (seccion) seccion.hidden = oculta;
    // Los enlaces a la carta tampoco tienen a dónde llevar
    $$('a[href="#carta"]').forEach((a) => (a.hidden = oculta));
    if (oculta) return;

    let platos = S.getCarta({ sucursalId: unidadPortal });
    if (categoriaActiva !== 'todos') platos = platos.filter((p) => p.cat === categoriaActiva);

    if (!platos.length) {
      cont.innerHTML = '<div class="vacio" style="grid-column:1/-1">Sin platos en esta categoría.</div>';
      return;
    }

    const etiquetas = {
      popular: ['badge--rojo', '★ El más pedido'],
      nuevo: ['badge--azul', 'Nuevo'],
      picante: ['badge--ambar', '🌶 Picante'],
      compartir: ['badge--azul', 'Para compartir'],
    };

    cont.innerHTML = platos
      .map(function (p) {
        const tag = etiquetas[p.tag];
        return (
          '<article class="plato' + (p.disponible ? '' : ' no-disp') + '">' +
          '<div class="plato__top">' +
          '<h3>' + U.esc(p.nombre) + '</h3>' +
          '<span class="plato__precio">' + U.money(p.precio) + '</span>' +
          '</div>' +
          '<p class="plato__desc">' + U.esc(p.desc) + '</p>' +
          '<div class="plato__pie">' +
          (tag ? '<span class="badge ' + tag[0] + '">' + tag[1] + '</span>' : '<span></span>') +
          (p.disponible
            ? '<button class="btn btn--fantasma btn--xs" data-add-carta="' + p.id + '">+ Agregar</button>'
            : '<span class="badge badge--gris">Agotado</span>') +
          '</div>' +
          '</article>'
        );
      })
      .join('');
  }

  /* =================================================================
     SUCURSALES
     ================================================================= */
  function pintarSucursales() {
    $('#listaSucursales').innerHTML = NASCAR.SUCURSALES.map(function (s, i) {
      const tipo = S.getTipoNegocio(s.tipoNegocio);
      const elegida = Number(s.id) === Number(unidadPortal);
      return (
        '<article class="sucursal sucursal--' + (s.color || 'azul') + '">' +
        '<div class="sucursal__cinta"></div>' +
        '<div class="sucursal__cuerpo">' +
        '<span class="sucursal__num">' + String(i + 1).padStart(2, '0') + '</span>' +
        '<span class="sucursal__tipo">' + tipo.icono + ' ' + U.esc(tipo.nombre) + '</span>' +
        '<h3>' + U.esc(s.nombre) + '</h3>' +

        (s.direccion
          ? '<div class="dato"><span class="dato__ico">📍</span><span>' + U.esc(s.direccion) +
            '<br><span class="tenue mini">' + U.esc(s.ciudad || '') + '</span></span></div>'
          : '') +
        (s.horario ? '<div class="dato"><span class="dato__ico">🕐</span><span>' + U.esc(s.horario) + '</span></div>' : '') +
        (s.telefono ? '<div class="dato"><span class="dato__ico">📞</span><span>' + U.esc(s.telefono) + '</span></div>' : '') +
        (s.mesas ? '<div class="dato"><span class="dato__ico">🪑</span><span>' + s.mesas + ' mesas</span></div>' : '') +

        ((s.zonas || []).length
          ? '<div class="zonas"><h4>Zonas de domicilio</h4>' +
            s.zonas
              .map(
                (z) =>
                  '<div class="zona"><span>' + U.esc(z.nombre) +
                  ' <span class="tenue mini">(mín. ' + U.money(z.min) + ')</span></span>' +
                  '<b>' + U.money(z.costo) + '</b></div>'
              )
              .join('') +
            '</div>'
          : '') +

        '<div class="fila mt-16">' +
        (elegida
          ? '<span class="badge badge--verde">✓ Estás pidiendo aquí</span>'
          : '<button class="btn btn--rojo btn--sm" data-pedir-suc="' + s.id + '">Pedir aquí</button>') +
        (s.mapa ? '<a class="btn btn--fantasma btn--sm" href="' + s.mapa + '" target="_blank" rel="noopener">Cómo llegar</a>' : '') +
        '</div>' +

        '</div></article>'
      );
    }).join('');
  }

  function pintarPie() {
    $('#pieSucursales').innerHTML = NASCAR.SUCURSALES.map(
      (s) =>
        '<li><b>' + U.esc(s.corto) + '</b><br><span class="mini">' + U.esc(s.direccion) + '<br>' + U.esc(s.telefono) + '</span></li>'
    ).join('');
    const cfg = S.getConfig();
    $('#pieNit').textContent = 'NIT ' + cfg.pago.nit;
    $('#statPlatos').textContent = (unidadPortal ? S.getCartaDisponible(unidadPortal).length : 0) + '+';
    // Cuántos locales hay abiertos: sale de las unidades activas, no del HTML
    if ($('#statLocales')) $('#statLocales').textContent = S.getSucursales().length;
    const nombreUnidad = $('#unidadPortalNombre');
    if (nombreUnidad) nombreUnidad.textContent = unidadPortal ? U.sucursal(unidadPortal).nombre : '—';

    // Textos de marca configurables desde el panel
    $$('[data-marca]').forEach((n) => (n.textContent = cfg.marca));
    const desc = $('#heroTexto');
    if (desc && cfg.descripcion) desc.textContent = cfg.descripcion;
  }

  /* =================================================================
     CARRITO — apertura / cierre
     ================================================================= */
  function abrirCarrito() {
    $('#carrito').classList.add('is-abierto');
    $('#carritoFondo').classList.add('is-abierto');
    document.body.style.overflow = 'hidden';
  }
  function cerrarCarrito() {
    $('#carrito').classList.remove('is-abierto');
    $('#carritoFondo').classList.remove('is-abierto');
    document.body.style.overflow = '';
    if (paso === 'listo') {
      carrito.vaciar();
      borrador.comprobante = null;
      borrador.referencia = '';
      paso = 'carrito';
      pintarCarrito();
    }
  }

  /* La unidad del pedido: la de los productos que ya están en el carrito.
     Cada pedido sale de UNA sola unidad. */
  function sucursalObligatoria() {
    const it = carrito.items().find((x) => x.sucursalId);
    return it ? Number(it.sucursalId) : null;
  }

  function agregarDelDia(platoId) {
    const p = S.getPlatosDia(S.hoy()).find((x) => x.id === platoId);
    if (!p) return U.toast('Ese plato ya no está disponible.', 'error');
    // Sólo si es lo que su sucursal publica hoy (menú del chef, disponible)
    if (!S.getMenuPublico(S.hoy(), p.sucursalId).platos.some((x) => x.id === p.id))
      return U.toast('Ese plato ya no está disponible.', 'error');

    const fijada = sucursalObligatoria();
    if (fijada && fijada !== Number(p.sucursalId)) {
      return U.toast(
        'Tu pedido ya tiene productos de ' + U.sucursal(fijada).nombre +
          '. Cada pedido sale de una sola unidad.',
        'error'
      );
    }

    carrito.agregar({
      refId: p.id,
      nombre: p.nombre + ' (menú del día)',
      precio: p.precio,
      origen: 'dia',
      sucursalId: p.sucursalId,
    }, 1);

    borrador.sucursalId = Number(p.sucursalId);
    U.toast(p.nombre + ' agregado a tu pedido.');
    abrirCarrito();
  }

  /* Menú armado: se lee lo elegido en la tarjeta, se exigen las categorías
     obligatorias y entra al carrito como una línea con su detalle. */
  function agregarArmado(boton) {
    const tarjeta = boton.closest('[data-armado]');
    if (!tarjeta) return;
    const sucId = Number(tarjeta.dataset.sucursal);
    const menu = S.getMenuPublico(S.hoy(), sucId);
    if (!menu.armado || menu.menuId !== tarjeta.dataset.armado)
      return U.toast('Ese menú ya no está disponible.', 'error');

    const sel = M.leerSeleccion(tarjeta, menu);
    if (!sel.ok) return U.toast('Te falta elegir: ' + sel.faltan.join(', ') + '.', 'error');

    const fijada = sucursalObligatoria();
    if (fijada && fijada !== sucId) {
      return U.toast(
        'Tu pedido ya tiene productos de ' + U.sucursal(fijada).nombre +
          '. Cada pedido sale de una sola unidad.',
        'error'
      );
    }

    carrito.agregar(M.itemArmado(menu, sel.elegidas), 1);
    borrador.sucursalId = sucId;
    U.toast(menu.armado.nombre + ' agregado a tu pedido.');

    /* El configurador queda limpio y ofrece "Agregar otro menú": dos
       personas de la misma mesa piden combinaciones distintas. No se abre
       el carrito para no tapar ese paso. */
    M.agregado(tarjeta, menusEnElCarrito());
  }

  function menusEnElCarrito() {
    return carrito
      .items()
      .filter((x) => x.origen === 'armado')
      .reduce((n, x) => n + x.cantidad, 0);
  }

  function agregarDeCarta(platoId) {
    const p = unidadPortal ? S.getCarta({ sucursalId: unidadPortal }).find((x) => x.id === platoId) : null;
    if (!p || !p.disponible) return U.toast('Ese plato no está disponible.', 'error');

    const fijada = sucursalObligatoria();
    if (fijada && fijada !== Number(unidadPortal))
      return U.toast(
        'Tu pedido es de ' + U.sucursal(fijada).nombre + '. Cada pedido sale de una sola unidad.',
        'error'
      );

    carrito.agregar(
      { refId: p.id, nombre: p.nombre, precio: p.precio, origen: 'carta', sucursalId: Number(unidadPortal) },
      1
    );
    borrador.sucursalId = Number(unidadPortal);
    U.toast(p.nombre + ' agregado a tu pedido.');
  }

  /* =================================================================
     CARRITO — render por pasos
     ================================================================= */
  function pintarCarrito() {
    const items = carrito.items();
    const n = carrito.cantidad();

    const badge = $('#carritoN');
    badge.textContent = n;
    badge.classList.toggle('oculto', n === 0);

    const titulos = {
      carrito: 'Tu pedido',
      datos: 'Datos de entrega',
      pago: 'Método de pago',
      listo: '¡Pedido enviado!',
    };
    $('#carritoTitulo').textContent = titulos[paso];

    if (paso === 'carrito') return pintarPasoCarrito(items);
    if (paso === 'datos') return pintarPasoDatos();
    if (paso === 'pago') return pintarPasoPago();
    if (paso === 'listo') return pintarPasoListo();
  }

  function barraPasos(indice) {
    return (
      '<div class="pasos-nav">' +
      [0, 1, 2].map((i) => '<div class="' + (i <= indice ? 'is-activo' : '') + '"></div>').join('') +
      '</div>'
    );
  }

  /* --- Paso 1: lista de productos ------------------------------- */
  function pintarPasoCarrito(items) {
    const cuerpo = $('#carritoItems');
    const pie = $('#carritoPie');

    if (!items.length) {
      cuerpo.innerHTML =
        '<div class="vacio" style="border:0;padding:52px 10px">' +
        '<div class="vacio__ico">🛒</div>' +
        '<h3>Tu pedido está vacío</h3>' +
        '<p class="mini">Agrega platos de la carta o del menú del día.</p>' +
        '</div>';
      pie.innerHTML = '<button class="btn btn--fantasma btn--bloque" data-accion="cerrar-carrito">Seguir viendo</button>';
      return;
    }

    cuerpo.innerHTML = items
      .map(function (it, i) {
        return (
          '<div class="ci">' +
          '<div class="ci__nombre">' + U.esc(it.nombre) + '</div>' +
          '<div class="ci__precio">' + U.money(it.precio * it.cantidad) + '</div>' +
          (it.detalle ? '<div class="ci__notas ci__detalle">🍽️ ' + U.esc(it.detalle) + '</div>' : '') +
          (it.notas ? '<div class="ci__notas">📝 ' + U.esc(it.notas) + '</div>' : '') +
          '<div class="ci__ctrl">' +
          '<div class="qty">' +
          '<button data-menos="' + i + '" aria-label="Quitar uno">−</button>' +
          '<span>' + it.cantidad + '</span>' +
          '<button data-mas="' + i + '" aria-label="Agregar uno">+</button>' +
          '</div>' +
          '<button class="btn btn--fantasma btn--xs" data-nota="' + i + '">📝 Nota</button>' +
          '<button class="ci__quitar" data-quitar="' + i + '">Quitar</button>' +
          '</div>' +
          '</div>'
        );
      })
      .join('');

    const sub = carrito.subtotal();
    pie.innerHTML =
      '<div class="totales">' +
      '<div><span>Subtotal (' + carrito.cantidad() + ' items)</span><span class="num">' + U.money(sub) + '</span></div>' +
      (hayZonas(U.sucursal(unidadPortal))
        ? '<div class="mini tenue"><span>El domicilio se calcula según tu zona</span></div>'
        : '') +
      '</div>' +
      '<button class="btn btn--rojo btn--bloque" data-accion="ir-datos">Continuar →</button>' +
      '<button class="btn btn--fantasma btn--bloque mt-8" data-accion="vaciar">Vaciar pedido</button>';
  }

  /* --- Paso 2: datos de entrega --------------------------------- */
  function pintarPasoDatos() {
    const suc = U.sucursal(sucursalObligatoria() || unidadPortal || borrador.sucursalId);

    $('#carritoItems').innerHTML =
      barraPasos(0) +
      '<label class="campo"><span>Local que te atiende</span>' +
      '<select class="select" id="fSucursal" disabled>' +
      '<option value="' + suc.id + '" selected>' + U.esc(suc.nombre) + '</option>' +
      '</select>' +
      '<span class="mini tenue">Cada pedido sale de un solo local: el de los productos que elegiste.</span>' +
      '</label>' +

      '<label class="campo"><span>Tu nombre <i class="req">*</i></span>' +
      '<input class="input" id="fNombre" placeholder="Ej. Juan Pérez" value="' + U.esc(borrador.nombre) + '" autocomplete="name"></label>' +

      '<label class="campo"><span>Celular <i class="req">*</i></span>' +
      '<input class="input" id="fTelefono" inputmode="tel" placeholder="Ej. 3001234567" value="' + U.esc(borrador.telefono) + '" autocomplete="tel"></label>' +

      /* La zona sólo se pide si el local tiene zonas configuradas. Sin
         zonas el domicilio no tiene costo ni pedido mínimo. */
      (hayZonas(suc)
        ? '<label class="campo"><span>Zona de entrega <i class="req">*</i></span>' +
          '<select class="select" id="fZona"><option value="">Selecciona tu zona…</option>' +
          suc.zonas
            .map(
              (z) =>
                '<option value="' + U.esc(z.nombre) + '"' + (z.nombre === borrador.zona ? ' selected' : '') + '>' +
                U.esc(z.nombre) + ' · ' + U.money(z.costo) + '</option>'
            )
            .join('') +
          '</select></label>'
        : '') +

      '<label class="campo"><span>Dirección completa <i class="req">*</i></span>' +
      '<input class="input" id="fDireccion" placeholder="Cra. 10 # 20-30, apto 501, torre 2" value="' + U.esc(borrador.direccion) + '" autocomplete="street-address"></label>' +

      '<label class="campo"><span>Indicaciones para el domiciliario</span>' +
      '<textarea class="textarea" id="fNotas" placeholder="Portería, punto de referencia, timbre…">' + U.esc(borrador.notas) + '</textarea></label>' +

      '<div id="avisoMinimo"></div>';

    $('#carritoPie').innerHTML =
      '<div class="totales" id="totalesDatos"></div>' +
      '<button class="btn btn--rojo btn--bloque" data-accion="ir-pago">Ir al pago →</button>' +
      '<button class="btn btn--fantasma btn--bloque mt-8" data-accion="volver-carrito">← Volver al pedido</button>';

    const recalcular = function () {
      leerFormularioDatos();
      pintarTotales('#totalesDatos');
      revisarMinimo();
    };
    ['#fSucursal', '#fZona'].forEach((s) => $(s) && $(s).addEventListener('change', function () {
      leerFormularioDatos();
      if (this.id === 'fSucursal') return pintarCarrito(); // cambian las zonas
      recalcular();
    }));
    ['#fNombre', '#fTelefono', '#fDireccion', '#fNotas'].forEach(
      (s) => $(s) && $(s).addEventListener('input', leerFormularioDatos)
    );

    recalcular();
  }

  function leerFormularioDatos() {
    if (!$('#fNombre')) return;
    borrador.sucursalId = sucursalObligatoria() || Number(unidadPortal) || Number($('#fSucursal').value);
    borrador.nombre = $('#fNombre').value.trim();
    borrador.telefono = $('#fTelefono').value.trim();
    borrador.zona = $('#fZona') ? $('#fZona').value : '';
    borrador.direccion = $('#fDireccion').value.trim();
    borrador.notas = $('#fNotas').value.trim();
  }

  function hayZonas(suc) {
    return !!(suc && (suc.zonas || []).length);
  }

  function zonaActual() {
    const suc = U.sucursal(borrador.sucursalId);
    return ((suc && suc.zonas) || []).find((z) => z.nombre === borrador.zona) || null;
  }

  function costoDomicilio() {
    const z = zonaActual();
    return z ? z.costo : 0;
  }

  function pintarTotales(sel) {
    const cont = $(sel);
    if (!cont) return;
    const sub = carrito.subtotal();
    const dom = costoDomicilio();
    cont.innerHTML =
      '<div><span>Subtotal</span><span class="num">' + U.money(sub) + '</span></div>' +
      '<div><span>Domicilio' + (borrador.zona ? ' · ' + U.esc(borrador.zona) : '') + '</span>' +
      '<span class="num">' +
      (borrador.zona ? U.money(dom) : hayZonas(U.sucursal(borrador.sucursalId)) ? '—' : 'Sin costo') +
      '</span></div>' +
      '<div class="total"><span>Total</span><span class="num">' + U.money(sub + dom) + '</span></div>';
  }

  function revisarMinimo() {
    const aviso = $('#avisoMinimo');
    if (!aviso) return;
    const z = zonaActual();
    if (!z) return (aviso.innerHTML = '');
    const falta = z.min - carrito.subtotal();
    aviso.innerHTML =
      falta > 0
        ? '<div class="caja-datos" style="border-color:var(--rojo)"><b class="rojo">Pedido mínimo para ' +
          U.esc(z.nombre) + ': ' + U.money(z.min) + '</b>' +
          '<p class="mini tenue" style="margin:4px 0 0">Te faltan ' + U.money(falta) + ' para poder despachar a esta zona.</p></div>'
        : '';
  }

  /* --- Paso 3: pago --------------------------------------------- */
  function pintarPasoPago() {
    const cfg = S.getConfig();
    const P = cfg.pago;

    // Sólo los métodos que administración dejó activos
    const metodos = (cfg.metodosPago || []).filter((m) => m.activo);
    if (!metodos.some((m) => m.id === borrador.metodoPago)) {
      borrador.metodoPago = metodos.length ? metodos[0].id : 'efectivo';
    }

    $('#carritoItems').innerHTML =
      barraPasos(1) +
      '<div class="opciones-pago">' +
      metodos
        .map(
          (m) =>
            '<label class="op"><input type="radio" name="mp" value="' + m.id + '"' +
            (borrador.metodoPago === m.id ? ' checked' : '') + '>' +
            '<div><b>' + U.esc(m.nombre) + '</b>' +
            '<span>' + U.esc(m.descripcion || '') + '</span></div></label>'
        )
        .join('') +
      '</div>' +

      '<div id="detallePago" class="mt-16"></div>';

    $('#carritoPie').innerHTML =
      '<div class="totales" id="totalesPago"></div>' +
      '<button class="btn btn--rojo btn--bloque" data-accion="confirmar-pedido">🏁 Confirmar pedido</button>' +
      '<button class="btn btn--fantasma btn--bloque mt-8" data-accion="volver-datos">← Volver a mis datos</button>';

    function pintarDetalle() {
      const d = $('#detallePago');
      if (borrador.metodoPago === 'transferencia') {
        d.innerHTML =
          '<div class="caja-datos">' +
          '<div class="linea"><span class="tenue">Nequi</span><b>' + U.esc(P.nequi) + '</b></div>' +
          '<div class="linea"><span class="tenue">Daviplata</span><b>' + U.esc(P.daviplata) + '</b></div>' +
          '<div class="linea"><span class="tenue">Bancolombia</span><b>' + U.esc(P.bancolombia) + '</b></div>' +
          '<div class="linea"><span class="tenue">Titular</span><b>' + U.esc(P.titular) + '</b></div>' +
          '</div>' +
          '<label class="campo"><span>Número de referencia o comprobante</span>' +
          '<input class="input" id="fReferencia" placeholder="Últimos 6 dígitos del comprobante" value="' + U.esc(borrador.referencia) + '"></label>' +

          '<div class="campo"><span>Adjuntar comprobante</span>' +
          '<label class="adjunto" id="zonaAdjunto">' +
          '<input type="file" id="fComprobante" accept="image/jpeg,image/png,image/webp" class="oculto">' +
          '<div id="adjuntoContenido">' +
          '<i>📎</i><b>Toca para adjuntar</b>' +
          '<span>Foto o captura del pago · JPG, PNG o WEBP</span>' +
          '</div></label></div>' +

          '<p class="mini tenue">Puedes dejarlo en blanco y enviarnos el soporte por WhatsApp. ' +
          'Tu pedido queda como <b>pago por confirmar</b> hasta que lo verifiquemos en caja.</p>';

        $('#fReferencia').addEventListener('input', function () {
          borrador.referencia = this.value.trim();
        });
        conectarAdjunto();
      } else if (borrador.metodoPago === 'efectivo') {
        d.innerHTML =
          '<label class="campo"><span>¿Con cuánto vas a pagar?</span>' +
          '<input class="input" id="fPagaCon" inputmode="numeric" placeholder="Ej. 100000 (para llevar tus vueltas)" value="' + U.esc(borrador.pagaCon) + '"></label>';
        $('#fPagaCon').addEventListener('input', function () {
          borrador.pagaCon = this.value.replace(/\D/g, '');
        });
      } else {
        d.innerHTML =
          '<div class="caja-datos"><p class="mini" style="margin:0">El domiciliario llega con datáfono. ' +
          'Ten a mano tu tarjeta; el cobro se hace por el total del pedido.</p></div>';
      }
    }

    $$('input[name="mp"]').forEach((r) =>
      r.addEventListener('change', function () {
        borrador.metodoPago = this.value;
        pintarDetalle();
      })
    );

    pintarDetalle();
    pintarTotales('#totalesPago');
  }

  /* --- Adjuntar el comprobante de la transferencia ----------------
     La imagen se reduce en el navegador antes de guardarla: en el MVP
     todo vive en localStorage, que es pequeño. Si no cabe, se avisa
     con un mensaje claro en vez de fallar en silencio. */
  function conectarAdjunto() {
    const input = $('#fComprobante');
    if (!input) return;

    pintarEstadoAdjunto();

    input.addEventListener('change', function () {
      const archivo = this.files && this.files[0];
      if (!archivo) return;

      $('#adjuntoContenido').innerHTML = '<i>⏳</i><b>Procesando…</b><span>Un momento</span>';

      U.comprimirImagen(archivo)
        .then(function (res) {
          borrador.comprobante = {
            dataUrl: res.dataUrl,
            nombreArchivo: archivo.name,
            pesoKB: res.pesoKB,
          };
          pintarEstadoAdjunto();
          U.toast('Comprobante adjuntado (' + res.pesoKB + ' KB).');
        })
        .catch(function (err) {
          borrador.comprobante = null;
          input.value = '';
          pintarEstadoAdjunto();
          U.toast(err.message, 'error');
        });
    });
  }

  function pintarEstadoAdjunto() {
    const zona = $('#zonaAdjunto');
    const cont = $('#adjuntoContenido');
    if (!zona || !cont) return;

    if (borrador.comprobante) {
      zona.classList.add('adjunto--cargado');
      cont.innerHTML =
        '<img class="adjunto__vista" src="' + borrador.comprobante.dataUrl + '" alt="Comprobante">' +
        '<b>✓ Comprobante listo</b>' +
        '<span>' + U.esc(borrador.comprobante.nombreArchivo) + ' · ' +
        borrador.comprobante.pesoKB + ' KB — toca para cambiarlo</span>';
    } else {
      zona.classList.remove('adjunto--cargado');
      cont.innerHTML =
        '<i>📎</i><b>Toca para adjuntar</b>' +
        '<span>Foto o captura del pago · JPG, PNG o WEBP</span>';
    }
  }

  /* --- Paso 4: confirmación ------------------------------------- */
  function pintarPasoListo() {
    const p = ultimoPedido;
    const suc = U.sucursal(p.sucursalId);
    const wa = enlaceWhatsApp(p, suc);

    $('#carritoItems').innerHTML =
      '<div class="ticket">' +
      '<div class="ticket__ok">✓</div>' +
      '<p class="tenue mini" style="margin:0">Tu código de pedido</p>' +
      '<div class="ticket__codigo">' + U.esc(p.codigo) + '</div>' +
      '<p class="tenue mini">Guárdalo para consultar el estado.</p>' +
      '</div>' +

      '<div class="caja-datos">' +
      '<div class="linea"><span class="tenue">Local</span><b>' + U.esc(suc.nombre) + '</b></div>' +
      '<div class="linea"><span class="tenue">Entrega en</span><b>' + U.esc(p.cliente.direccion) + '</b></div>' +
      '<div class="linea"><span class="tenue">Tiempo estimado</span><b>' + NASCAR.CONFIG.tiempos.domicilio + '</b></div>' +
      '<div class="linea"><span class="tenue">Total</span><b>' + U.money(p.total) + '</b></div>' +
      '<div class="linea"><span class="tenue">Pago</span><b>' + etiquetaPago(p.metodoPago) + '</b></div>' +
      '</div>' +

      (p.metodoPago === 'transferencia'
        ? '<div class="caja-datos" style="border-color:var(--ambar)">' +
          '<b class="ambar">Pago por confirmar</b>' +
          '<p class="mini tenue" style="margin:4px 0 0">Tu pedido se despacha apenas verifiquemos la transferencia en caja. ' +
          'Enviar el soporte por WhatsApp acelera el proceso.</p></div>'
        : '') +

      '<a class="btn btn--verde btn--bloque mt-16" style="background:#12b76a;border-color:#12b76a;color:#04220f" ' +
      'href="' + wa + '" target="_blank" rel="noopener">💬 Enviar soporte por WhatsApp</a>' +
      '<p class="mini tenue centro mt-8">Se abre WhatsApp con el resumen escrito. Tú decides cuándo enviarlo.</p>';

    $('#carritoPie').innerHTML =
      '<button class="btn btn--fantasma btn--bloque" data-accion="ver-estado" data-codigo="' + U.esc(p.codigo) + '">Ver estado del pedido</button>' +
      '<button class="btn btn--rojo btn--bloque mt-8" data-accion="cerrar-carrito">Listo</button>';
  }

  function etiquetaPago(m) {
    return { efectivo: 'Efectivo', transferencia: 'Transferencia', datafono: 'Datáfono' }[m] || m;
  }

  function enlaceWhatsApp(p, suc) {
    const lineas = [
      '*Pedido ' + p.codigo + '* — NASCAR ' + suc.corto,
      '',
      'Cliente: ' + p.cliente.nombre,
      'Tel: ' + p.cliente.telefono,
      'Dirección: ' + p.cliente.direccion + (p.cliente.zona ? ' (' + p.cliente.zona + ')' : ''),
      '',
      ...p.items.map((it) => '• ' + it.cantidad + ' x ' + it.nombre + (it.detalle ? ' (' + it.detalle + ')' : '') + ' — ' + U.money(it.precio * it.cantidad)),
      '',
      'Subtotal: ' + U.money(p.subtotal),
      'Domicilio: ' + U.money(p.domicilio),
      '*Total: ' + U.money(p.total) + '*',
      'Pago: ' + etiquetaPago(p.metodoPago),
    ];
    // El número sale de la configuración, nunca del código.
    return U.enlaceWhatsApp(p.sucursalId, lineas.join('\n'));
  }

  /* =================================================================
     VALIDACIÓN Y CREACIÓN DEL PEDIDO
     ================================================================= */
  function validarDatos() {
    leerFormularioDatos();
    const errores = [];
    if (borrador.nombre.length < 3) errores.push('Escribe tu nombre completo.');
    if (!/^\d{7,10}$/.test(borrador.telefono.replace(/\D/g, '')))
      errores.push('El celular debe tener entre 7 y 10 dígitos.');
    if (!borrador.zona && hayZonas(U.sucursal(borrador.sucursalId)))
      errores.push('Selecciona tu zona de entrega.');
    if (borrador.direccion.length < 8) errores.push('Escribe la dirección completa.');

    const z = zonaActual();
    if (z && carrito.subtotal() < z.min)
      errores.push('El pedido mínimo para ' + z.nombre + ' es ' + U.money(z.min) + '.');

    if (errores.length) {
      U.toast(errores[0], 'error');
      return false;
    }
    return true;
  }

  function confirmarPedido() {
    if (!carrito.items().length) return U.toast('Tu pedido está vacío.', 'error');

    let pedido;
    try {
      pedido = S.crearPedido({
        tipo: 'domicilio',
        sucursalId: borrador.sucursalId,
        cliente: {
          nombre: borrador.nombre,
          telefono: borrador.telefono,
          direccion: borrador.direccion,
          zona: borrador.zona,
          notas: borrador.notas,
          pagaCon: borrador.pagaCon || '',
        },
        items: carrito.items(),
        metodoPago: borrador.metodoPago,
        costoDomicilio: costoDomicilio(),
      });
    } catch (e) {
      return U.toast(e.message || 'No se pudo crear el pedido.', 'error');
    }

    if (borrador.metodoPago === 'transferencia') {
      if (borrador.comprobante) {
        S.guardarComprobante(pedido.id, borrador.comprobante);
      }
      if (borrador.referencia || borrador.comprobante) {
        S.reportarPago(pedido.id, borrador.referencia || 'con comprobante adjunto');
      }
      pedido = S.getPedido(pedido.id);
    }

    ultimoPedido = pedido;
    paso = 'listo';
    pintarCarrito();
    U.toast('¡Pedido ' + pedido.codigo + ' enviado a cocina!');
  }

  /* =================================================================
     SEGUIMIENTO DE PEDIDO
     ================================================================= */
  function abrirSeguimiento(codigoInicial) {
    const m = U.modal({
      titulo: 'Seguir mi pedido',
      ancho: 500,
      contenido:
        '<form class="seg-buscar" id="sForm">' +
        '<label class="campo"><span>Número del pedido</span>' +
        '<input class="input" id="sCodigo" inputmode="numeric" autocomplete="off" placeholder="Ej. 00027" value="' +
        U.esc(codigoInicial || '') + '" style="text-transform:uppercase"></label>' +
        '<button class="btn btn--azul" id="sBuscar" type="submit">Consultar</button>' +
        '</form>' +
        '<div id="sResultado" class="mt-16" aria-live="polite"></div>',
    });

    let consultado = ''; // lo último que se buscó, para refrescar solo

    /* Cada paso con su icono y un texto corto que cabe en el celular.
       «En camino» sólo existe para los domicilios: una mesa pasa de listo
       a entregado. Un estado sin texto aquí se muestra con su nombre. */
    function pasosDe(p) {
      const dom = p.tipo === 'domicilio';
      const info = {
        nuevo: { ico: '🧾', corto: 'Recibido', titulo: 'Recibimos tu pedido', texto: 'Ya está en el sistema. En un momento la cocina empieza a prepararlo.' },
        preparacion: { ico: '👨‍🍳', corto: 'Preparando', titulo: 'Estamos preparando tu pedido', texto: 'La cocina está trabajando en él.' },
        listo: dom
          ? { ico: '🛍️', corto: 'Listo', titulo: 'Tu pedido está listo', texto: 'Lo estamos empacando para despacharlo.' }
          : { ico: '🍽️', corto: 'Listo', titulo: 'Tu pedido está listo', texto: 'En un momento lo llevamos a tu mesa.' },
        camino: { ico: '🛵', corto: 'En camino', titulo: 'Tu pedido va en camino', texto: 'El domiciliario va hacia tu dirección. Ten tu teléfono a la mano.' },
        entregado: { ico: '✅', corto: 'Entregado', titulo: '¡Pedido entregado!', texto: 'Gracias por pedir con nosotros. ¡Buen provecho!' },
      };
      return S.ESTADOS.filter((e) => e !== 'camino' || dom).map(
        (e) => Object.assign({ id: e }, info[e] || { ico: '•', corto: e, titulo: e, texto: '' })
      );
    }

    function hora(ts) {
      const d = new Date(ts);
      return isNaN(d) ? '' : d.toLocaleTimeString('es-CO', { hour: 'numeric', minute: '2-digit' });
    }

    function pintar() {
      const cont = U.$('#sResultado', m.raiz);
      if (!cont || !consultado) return;
      const p = S.getPedidoPorCodigo(consultado);

      if (!p) {
        cont.innerHTML =
          '<div class="seg-vacio"><div class="seg-vacio__ico">🔎</div>' +
          '<b>No encontramos el pedido ' + U.esc(consultado.toUpperCase()) + '</b>' +
          '<p>Revisa el número. Los pedidos se consultan desde el mismo celular o computador donde se hicieron.</p></div>';
        return;
      }

      const suc = U.sucursal(p.sucursalId);
      const ultimo = (p.historial || []).slice(-1)[0];
      const datos =
        '<div class="seg-datos">' +
        '<div><span>Pedido</span><b>#' + U.esc(p.codigo) + '</b></div>' +
        '<div><span>Local</span><b>' + U.esc(suc ? suc.nombre : '—') + '</b></div>' +
        '<div><span>' + (p.tipo === 'mesa' ? 'Mesa' : 'Entrega') + '</span><b>' +
        (p.tipo === 'mesa' ? U.esc(p.mesa) : 'Domicilio') + '</b></div>' +
        '<div><span>Total</span><b>' + U.money(p.total) + '</b></div>' +
        '<div class="seg-datos__ancho"><span>Pago</span><b>' + insigniaPago(p) + '</b></div>' +
        '</div>';

      if (p.estado === 'cancelado' || p.estado === 'anulado') {
        cont.innerHTML =
          '<div class="seg-actual seg-actual--rojo">' +
          '<div class="seg-actual__ico">✖</div><div>' +
          '<span class="seg-actual__kicker">Estado</span>' +
          '<b>Pedido ' + (p.estado === 'anulado' ? 'anulado' : 'cancelado') + '</b>' +
          '<p>' + U.esc(p.motivoCancelacion || 'Si tienes dudas, comunícate con el local.') + '</p>' +
          '</div></div>' + datos;
        return;
      }

      const pasos = pasosDe(p);
      const i = Math.max(0, pasos.findIndex((x) => x.id === p.estado));
      const actual = pasos[i];
      const fin = i === pasos.length - 1;
      const avance = Math.round((i / (pasos.length - 1)) * 100);

      cont.innerHTML =
        '<div class="seg-actual' + (fin ? ' seg-actual--verde' : '') + '">' +
        '<div class="seg-actual__ico' + (fin ? '' : ' seg-actual__ico--vivo') + '">' + actual.ico + '</div><div>' +
        '<span class="seg-actual__kicker">Paso ' + (i + 1) + ' de ' + pasos.length +
        (ultimo ? ' · ' + hora(ultimo.ts) : '') + '</span>' +
        '<b>' + U.esc(actual.titulo) + '</b>' +
        '<p>' + U.esc(actual.texto) + '</p>' +
        '</div></div>' +

        '<div class="seg-pasos" role="list" style="--seg-avance:' + avance + '%">' +
        '<div class="seg-pasos__riel"><i></i></div>' +
        pasos
          .map(function (x, k) {
            const hecho = k < i || (fin && k === i);
            const cls = hecho ? ' is-hecho' : k === i ? ' is-actual' : '';
            return (
              '<div class="seg-paso' + cls + '" role="listitem"' + (k === i ? ' aria-current="step"' : '') + '>' +
              '<span class="seg-paso__punto">' + (hecho ? '✓' : x.ico) + '</span>' +
              '<span class="seg-paso__txt">' + U.esc(x.corto) + '</span>' +
              '</div>'
            );
          })
          .join('') +
        '</div>' +

        (fin ? '' : '<p class="seg-nota">Esta pantalla se actualiza sola cuando el local cambia el estado.</p>') +
        datos;
    }

    function buscar(e) {
      if (e) e.preventDefault();
      consultado = U.$('#sCodigo', m.raiz).value.trim();
      if (!consultado) {
        U.$('#sCodigo', m.raiz).focus();
        return;
      }
      pintar();
    }

    U.$('#sForm', m.raiz).addEventListener('submit', buscar);
    // Si el local avanza el pedido, el cliente lo ve sin volver a consultar
    S.onChange(function () {
      if (document.body.contains(m.raiz)) pintar();
    });
    if (codigoInicial) buscar();
  }

  function insigniaPago(p) {
    const map = {
      confirmado: '<span class="verde">Confirmado</span>',
      reportado: '<span class="ambar">Reportado, por confirmar</span>',
      rechazado: '<span class="rojo">Rechazado</span>',
      pendiente: '<span class="tenue">Pendiente</span>',
    };
    return (map[p.estadoPago] || p.estadoPago) + ' · ' + etiquetaPago(p.metodoPago);
  }

  /* =================================================================
     EVENTOS
     ================================================================= */
  function conectarEventos() {
    M.conectar(EVENTOS); // quita el aviso rojo al elegir una opción

    // Acciones globales por data-accion
    U.acciones(EVENTOS, {
      'abrir-carrito': abrirCarrito,
      'cerrar-carrito': cerrarCarrito,
      'seguir': () => abrirSeguimiento(''),
      'ver-estado': (t) => abrirSeguimiento(t.dataset.codigo),
      'vaciar': () =>
        U.confirmar('¿Vaciar todo el pedido?', function () {
          carrito.vaciar();
          U.toast('Pedido vaciado.', 'info');
        }, 'Sí, vaciar'),
      'ir-datos': function () {
        if (!carrito.items().length) return U.toast('Agrega algo primero.', 'error');
        paso = 'datos';
        pintarCarrito();
      },
      'ir-pago': function () {
        if (!validarDatos()) return;
        paso = 'pago';
        pintarCarrito();
      },
      'volver-carrito': function () {
        paso = 'carrito';
        pintarCarrito();
      },
      'volver-datos': function () {
        paso = 'datos';
        pintarCarrito();
      },
      'confirmar-pedido': confirmarPedido,
    });

    // Agregar al carrito
    EVENTOS.addEventListener('click', function (e) {
      const d = e.target.closest('[data-add-dia]');
      if (d) return agregarDelDia(d.dataset.addDia);

      const ar = e.target.closest('[data-add-armado]');
      if (ar) return agregarArmado(ar);

      const c = e.target.closest('[data-add-carta]');
      if (c) return agregarDeCarta(c.dataset.addCarta);

      const s = e.target.closest('[data-pedir-suc]');
      if (s) {
        return cambiarUnidadPortal(s.dataset.pedirSuc, function () {
          const dia = $('#dia');
          if (dia) dia.scrollIntoView({ behavior: 'smooth' });
        });
      }
    });

    // Controles dentro del carrito
    $('#carrito').addEventListener('click', function (e) {
      const mas = e.target.closest('[data-mas]');
      if (mas) return carrito.cambiarCantidad(Number(mas.dataset.mas), 1);

      const menos = e.target.closest('[data-menos]');
      if (menos) return carrito.cambiarCantidad(Number(menos.dataset.menos), -1);

      const quitar = e.target.closest('[data-quitar]');
      if (quitar) return carrito.quitar(Number(quitar.dataset.quitar));

      const nota = e.target.closest('[data-nota]');
      if (nota) return pedirNota(Number(nota.dataset.nota));
    });

    $('#carritoFondo').addEventListener('click', cerrarCarrito);
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && $('#carrito').classList.contains('is-abierto')) cerrarCarrito();
    });

    // Menú móvil
    $('#burger').addEventListener('click', () => $('#nav').classList.toggle('is-abierto'));
    $$('#nav a').forEach((a) => a.addEventListener('click', () => $('#nav').classList.remove('is-abierto')));

    // El carrito se repinta solo cuando cambia
    carrito.onCambio(function () {
      if (paso === 'carrito' || paso === 'datos') pintarCarrito();
      else pintarCarrito();
    });
  }

  function pedirNota(indice) {
    const it = carrito.items()[indice];
    if (!it) return;
    const m = U.modal({
      titulo: 'Nota para ' + it.nombre,
      ancho: 430,
      contenido:
        '<label class="campo"><span>Indicaciones para la cocina</span>' +
        '<textarea class="textarea" id="nTexto" placeholder="Sin cebolla, término medio, aparte…">' + U.esc(it.notas || '') + '</textarea></label>' +
        '<div class="fila fila--fin"><button class="btn btn--rojo" id="nOk">Guardar nota</button></div>',
    });
    U.$('#nOk', m.raiz).addEventListener('click', function () {
      carrito.fijarNotas(indice, U.$('#nTexto', m.raiz).value.trim());
      m.cerrar();
      U.toast('Nota guardada.');
    });
  }

  /* =================================================================
     ARRANQUE
     ================================================================= */
  function iniciar() {
    S.sembrar();

    $('#fechaHoy').textContent = U.fechaLarga(S.hoy());

    borrador.sucursalId = unidadPortal || borrador.sucursalId;
    pintarSelectorSucursalDia();
    $('#filtroSucursalDia').addEventListener('change', function () {
      cambiarUnidadPortal(this.value);
    });
    pintarDia();
    pintarFiltros();
    pintarCarta();
    pintarSucursales();
    pintarPie();
    conectarEventos();
    pintarCarrito();
    U.iniciarComunes();

    /* Si el panel cambia algo —carta, precios, sucursales, datos del
       restaurante— la página pública se actualiza sola. */
    S.onChange(function () {
      pintarSelectorSucursalDia();
      pintarDia();
      pintarFiltros();
      pintarCarta();
      pintarSucursales();
      pintarPie();
    });
  }

  document.addEventListener('DOMContentLoaded', iniciar);
})();
