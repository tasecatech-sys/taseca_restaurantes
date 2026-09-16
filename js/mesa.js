/* ==========================================================================
   NASCAR · mesa.js
   Pantalla de pedido en mesa. Se abre desde el QR de cada mesa con la URL:
       mesa.html?suc=1&mesa=7
   El pedido entra a cocina identificado con la sucursal y el número de mesa.
   ========================================================================== */

(function () {
  'use strict';

  const S = NASCAR.Store;
  const U = NASCAR.UI;
  const M = NASCAR.MenuDia; // pintor compartido del menú del día

  /* Raíz de esta vista — ver la nota en app.js. */
  const RAIZ = document.querySelector('[data-vista="mesa"]') || document;
  const EVENTOS = RAIZ === document ? document.body : RAIZ;
  const SOLO_ARCHIVO = RAIZ !== document; // versión de un solo archivo
  const $ = (sel) => U.$(sel, RAIZ);
  const $$ = (sel) => U.$$(sel, RAIZ);

  /* --- Contexto de la mesa ---------------------------------------
     Versión de varios archivos:  mesa.html?suc=1&mesa=5
     Versión de un solo archivo:  ...nascar-movil.html#mesa/1/5      */
  function contextoMesa() {
    let suc = U.paramURL('suc', null);
    let num = U.paramURL('mesa', null);
    const h = location.hash.match(/^#mesa\/(\d+)\/([^/?]+)/);
    if (h) {
      if (suc === null) suc = h[1];
      if (num === null) num = decodeURIComponent(h[2]);
    }
    return { sucursalId: Number(suc || 1), mesa: String(num || '1') };
  }

  const ctx = contextoMesa();
  const sucursalId = ctx.sucursalId;
  const mesa = ctx.mesa;
  const suc = U.sucursal(sucursalId);

  /* Un carrito por mesa, para que dos mesas en el mismo dispositivo
     (o pestañas distintas) no se mezclen. */
  const carrito = U.Carrito('mesa-' + sucursalId + '-' + mesa);

  let categoriaActiva = 'todos';

  /* =================================================================
     CABECERA
     ================================================================= */
  function pintarCabecera() {
    $('#numMesa').textContent = mesa;
    $('#nomSucursal').textContent = suc.corto;
    if (!SOLO_ARCHIVO) document.title = 'NASCAR · Mesa ' + mesa + ' — ' + suc.corto;

    $('#cabeceraMesa').innerHTML =
      '<div class="barra-dia" style="background:linear-gradient(90deg,rgba(11,95,255,.18),transparent 70%);border-color:rgba(11,95,255,.35)">' +
      '<div>' +
      '<span class="titulo-seccion__kicker" style="margin:0;color:var(--azul-claro)">Pide desde tu celular</span>' +
      '<div class="barra-dia__fecha">Mesa ' + U.esc(mesa) + ' · ' + U.esc(suc.nombre) + '</div>' +
      '<p class="mini tenue" style="margin:4px 0 0">Arma tu pedido y envíalo. Llega directo a cocina con el número de mesa. ' +
      'El pago se hace al final, en caja o con el mesero.</p>' +
      '</div>' +
      '<div class="derecha">' +
      '<div class="cupos" style="color:var(--gris)">Tiempo estimado</div>' +
      '<div class="precio" style="font-size:22px">' + NASCAR.CONFIG.tiempos.mesa + '</div>' +
      '</div>' +
      '</div>' +

      /* En la versión de un solo archivo no hay una URL por mesa, así que
         el mesero elige aquí la sucursal y la mesa. */
      (SOLO_ARCHIVO ? selectorDeMesa() : '');
  }

  function selectorDeMesa() {
    let opciones = '';
    for (let i = 1; i <= suc.mesas; i++) {
      opciones += '<option value="' + i + '"' + (String(i) === mesa ? ' selected' : '') + '>Mesa ' + i + '</option>';
    }
    return (
      '<div class="caja mb-24">' +
      '<h3 style="font-size:16px;margin-bottom:12px">¿Qué mesa está pidiendo?</h3>' +
      '<div class="rejilla-2">' +
      '<label class="campo"><span>Unidad</span><select class="select" id="selSuc">' +
      NASCAR.SUCURSALES.map(
        (s) => '<option value="' + s.id + '"' + (s.id === sucursalId ? ' selected' : '') + '>' + U.esc(s.nombre) + '</option>'
      ).join('') +
      '</select></label>' +
      '<label class="campo"><span>Mesa</span><select class="select" id="selMesa">' + opciones + '</select></label>' +
      '</div>' +
      '<p class="mini tenue" style="margin:0">Cada mesa guarda su propio pedido por separado.</p>' +
      '</div>'
    );
  }

  /* Cambiar de mesa recarga la vista con el contexto nuevo. */
  function conectarSelectorDeMesa() {
    if (!SOLO_ARCHIVO) return;
    const ir = function () {
      const s = $('#selSuc').value;
      const m = $('#selMesa').value;
      location.hash = '#mesa/' + s + '/' + encodeURIComponent(m);
      location.reload();
    };
    $('#selSuc').addEventListener('change', ir);
    $('#selMesa').addEventListener('change', ir);
  }

  /* =================================================================
     MENÚ DEL DÍA (solo el de esta sucursal)
     ================================================================= */
  // Lo que esta sucursal publica hoy: menú armado o platos del chef
  function pintarDia() {
    const bloque = $('#bloqueDia');
    const menu = S.getMenuPublico(S.hoy(), sucursalId);
    const html = M.tarjetas(menu, { clave: 'mesa' });

    // Mismo encabezado configurable que el portal: no está escrito en el HTML
    if ($('#tituloDia')) $('#tituloDia').textContent = menu.texto.titulo;
    if ($('#mensajeDia')) $('#mensajeDia').textContent = menu.texto.mensaje;

    if (!html) {
      bloque.classList.add('oculto');
      return;
    }
    bloque.classList.remove('oculto');
    M.pintar($('#listaDia'), html);
  }

  /* =================================================================
     CARTA
     ================================================================= */
  function pintarFiltros() {
    const cont = $('#filtrosCarta');
    // Las categorías de la unidad de esta mesa
    const cats = [{ id: 'todos', nombre: 'Todo', icono: '🏁' }].concat(S.getCategorias({ sucursalId: sucursalId }));
    cont.innerHTML = cats
      .map(
        (c) =>
          '<button class="chip' + (c.id === categoriaActiva ? ' is-activo' : '') + '" data-cat="' + c.id + '">' +
          c.icono + ' ' + U.esc(c.nombre) + '</button>'
      )
      .join('');

    cont.addEventListener('click', function (e) {
      const b = e.target.closest('[data-cat]');
      if (!b) return;
      categoriaActiva = b.dataset.cat;
      $$('.chip', cont).forEach((c) => c.classList.toggle('is-activo', c === b));
      pintarCarta();
    });
  }

  /* Igual que en el portal: un local sin carta (sólo menú del día) no
     muestra la sección. */
  function sinCarta() {
    return S.getCarta({ sucursalId: sucursalId }).length === 0;
  }

  function pintarCarta() {
    const seccion = $('#seccionCarta');
    if (seccion) seccion.hidden = sinCarta();
    if (sinCarta()) return;

    let platos = S.getCarta({ sucursalId: sucursalId }); // la carta de ESTA unidad
    if (categoriaActiva !== 'todos') platos = platos.filter((p) => p.cat === categoriaActiva);

    $('#listaCarta').innerHTML = platos
      .map(function (p) {
        return (
          '<article class="plato' + (p.disponible ? '' : ' no-disp') + '">' +
          '<div class="plato__top"><h3>' + U.esc(p.nombre) + '</h3>' +
          '<span class="plato__precio">' + U.money(p.precio) + '</span></div>' +
          '<p class="plato__desc">' + U.esc(p.desc) + '</p>' +
          '<div class="plato__pie"><span></span>' +
          (p.disponible
            ? '<button class="btn btn--fantasma btn--xs" data-add-carta="' + p.id + '">+ Agregar</button>'
            : '<span class="badge badge--gris">Agotado</span>') +
          '</div></article>'
        );
      })
      .join('');
  }

  /* =================================================================
     BARRA INFERIOR
     ================================================================= */
  function pintarBarra() {
    const n = carrito.cantidad();
    const barra = $('#barraTotal');
    barra.classList.toggle('is-visible', n > 0);
    $('#btResumen').textContent = n === 1 ? '1 producto' : n + ' productos';
    $('#btTotal').textContent = U.money(carrito.subtotal());
  }

  /* =================================================================
     MODAL "VER PEDIDO"
     ================================================================= */
  function verPedido() {
    const items = carrito.items();
    if (!items.length) return U.toast('Todavía no has agregado nada.', 'info');

    const m = U.modal({ titulo: 'Pedido de la mesa ' + mesa, ancho: 520, contenido: '<div id="mpBody"></div>' });

    function pintar() {
      const items = carrito.items();
      const cont = U.$('#mpBody', m.raiz);

      if (!items.length) {
        cont.innerHTML = '<div class="vacio" style="border:0">Pedido vacío.</div>';
        pintarBarra();
        return;
      }

      cont.innerHTML =
        items
          .map(function (it, i) {
            return (
              '<div class="ci">' +
              '<div class="ci__nombre">' + U.esc(it.nombre) + '</div>' +
              '<div class="ci__precio">' + U.money(it.precio * it.cantidad) + '</div>' +
              (it.detalle ? '<div class="ci__notas ci__detalle">🍽️ ' + U.esc(it.detalle) + '</div>' : '') +
              (it.notas ? '<div class="ci__notas">📝 ' + U.esc(it.notas) + '</div>' : '') +
              '<div class="ci__ctrl">' +
              '<div class="qty"><button data-menos="' + i + '">−</button><span>' + it.cantidad + '</span>' +
              '<button data-mas="' + i + '">+</button></div>' +
              '<button class="btn btn--fantasma btn--xs" data-nota="' + i + '">📝 Nota</button>' +
              '<button class="ci__quitar" data-quitar="' + i + '">Quitar</button>' +
              '</div></div>'
            );
          })
          .join('') +
        '<div class="totales mt-16"><div class="total"><span>Total</span>' +
        '<span class="num">' + U.money(carrito.subtotal()) + '</span></div></div>' +
        '<p class="mini tenue">El pago se realiza al final del servicio. Si necesitas factura, avísale al mesero.</p>' +
        /* Hook propio, no data-accion: el modal vive fuera de la raíz de la
           vista y con data-accion el envío se disparaba dos veces. */
        '<button class="btn btn--rojo btn--bloque mt-16" data-enviar-modal>🏁 Enviar a cocina</button>';

      pintarBarra();
    }

    m.raiz.addEventListener('click', function (e) {
      const mas = e.target.closest('[data-mas]');
      if (mas) { carrito.cambiarCantidad(Number(mas.dataset.mas), 1); return pintar(); }

      const menos = e.target.closest('[data-menos]');
      if (menos) { carrito.cambiarCantidad(Number(menos.dataset.menos), -1); return pintar(); }

      const quitar = e.target.closest('[data-quitar]');
      if (quitar) { carrito.quitar(Number(quitar.dataset.quitar)); return pintar(); }

      const nota = e.target.closest('[data-nota]');
      if (nota) return pedirNota(Number(nota.dataset.nota), pintar);

      if (e.target.closest('[data-enviar-modal]')) {
        m.cerrar();
        enviarACocina();
      }
    });

    pintar();
  }

  function pedirNota(indice, alGuardar) {
    const it = carrito.items()[indice];
    if (!it) return;
    const m = U.modal({
      titulo: 'Nota para ' + it.nombre,
      ancho: 430,
      contenido:
        '<label class="campo"><span>Indicaciones para la cocina</span>' +
        '<textarea class="textarea" id="nTexto" placeholder="Sin cebolla, término medio, sin picante…">' +
        U.esc(it.notas || '') + '</textarea></label>' +
        '<div class="fila fila--fin"><button class="btn btn--rojo" id="nOk">Guardar</button></div>',
    });
    U.$('#nOk', m.raiz).addEventListener('click', function () {
      carrito.fijarNotas(indice, U.$('#nTexto', m.raiz).value.trim());
      m.cerrar();
      U.toast('Nota guardada.');
      if (alGuardar) alGuardar();
    });
  }

  /* =================================================================
     ENVIAR A COCINA
     ================================================================= */
  function enviarACocina() {
    const items = carrito.items();
    if (!items.length) return U.toast('Agrega algo antes de enviar.', 'error');

    const m = U.modal({
      titulo: 'Confirmar pedido · Mesa ' + mesa,
      ancho: 460,
      contenido:
        '<p class="tenue">Vas a enviar <b>' + carrito.cantidad() + ' productos</b> por un total de ' +
        '<b>' + U.money(carrito.subtotal()) + '</b> a la cocina de ' + U.esc(suc.nombre) + '.</p>' +

        '<label class="campo"><span>¿A nombre de quién? (opcional)</span>' +
        '<input class="input" id="mNombre" placeholder="Ej. Mesa de Juan"></label>' +

        '<label class="campo"><span>Observaciones generales</span>' +
        '<textarea class="textarea" id="mNotas" placeholder="Traer todo junto, cuenta separada, celebración…"></textarea></label>' +

        '<div class="fila fila--fin mt-16">' +
        '<button class="btn btn--fantasma" id="mNo">Revisar</button>' +
        '<button class="btn btn--rojo" id="mSi">🏁 Enviar a cocina</button></div>',
    });

    U.$('#mNo', m.raiz).onclick = m.cerrar;
    U.$('#mSi', m.raiz).onclick = function () {
      let pedido;
      try {
        pedido = S.crearPedido({
          tipo: 'mesa',
          sucursalId: sucursalId,
          mesa: mesa,
          cliente: {
            nombre: U.$('#mNombre', m.raiz).value.trim() || 'Mesa ' + mesa,
            notas: U.$('#mNotas', m.raiz).value.trim(),
          },
          items: items,
          metodoPago: 'efectivo',
        });
      } catch (e) {
        return U.toast(e.message || 'No se pudo enviar el pedido.', 'error');
      }

      carrito.vaciar();
      m.cerrar();
      mostrarConfirmacion(pedido);
      pintarDia(); // por si se agotaron cupos del día
    };
  }

  function mostrarConfirmacion(p) {
    U.modal({
      titulo: '¡Pedido enviado!',
      ancho: 430,
      contenido:
        '<div class="ticket">' +
        '<div class="ticket__ok">✓</div>' +
        '<p class="tenue mini" style="margin:0">Código del pedido</p>' +
        '<div class="ticket__codigo">' + U.esc(p.codigo) + '</div>' +
        '</div>' +

        '<div class="caja-datos">' +
        '<div class="linea"><span class="tenue">Mesa</span><b>' + U.esc(p.mesa) + '</b></div>' +
        '<div class="linea"><span class="tenue">Productos</span><b>' +
        p.items.reduce((s, i) => s + i.cantidad, 0) + '</b></div>' +
        '<div class="linea"><span class="tenue">Total</span><b>' + U.money(p.total) + '</b></div>' +
        '<div class="linea"><span class="tenue">Tiempo estimado</span><b>' + NASCAR.CONFIG.tiempos.mesa + '</b></div>' +
        '</div>' +

        '<p class="mini tenue centro mt-16">La cocina ya lo tiene. Si quieres agregar algo más, ' +
        'sigue pidiendo desde esta misma pantalla — llegará como un pedido nuevo a la misma mesa.</p>',
    });
    pintarBarra();
  }

  /* =================================================================
     EVENTOS
     ================================================================= */
  function conectarEventos() {
    M.conectar(EVENTOS); // quita el aviso rojo al elegir una opción

    EVENTOS.addEventListener('click', function (e) {
      const d = e.target.closest('[data-add-dia]');
      if (d) {
        // Sólo lo que esta sucursal publica hoy como menú del chef
        const p = S.getMenuPublico(S.hoy(), sucursalId).platos.find((x) => x.id === d.dataset.addDia);
        if (!p) return U.toast('Ese plato ya no está disponible.', 'error');
        carrito.agregar({
          refId: p.id,
          nombre: p.nombre + ' (menú del día)',
          precio: p.precio,
          origen: 'dia',
          sucursalId: sucursalId,
        }, 1);
        return U.toast(p.nombre + ' agregado.');
      }

      const ar = e.target.closest('[data-add-armado]');
      if (ar) {
        const tarjeta = ar.closest('[data-armado]');
        const menu = S.getMenuPublico(S.hoy(), sucursalId);
        if (!tarjeta || !menu.armado || menu.menuId !== tarjeta.dataset.armado)
          return U.toast('Ese menú ya no está disponible.', 'error');
        const sel = M.leerSeleccion(tarjeta, menu);
        if (!sel.ok) return U.toast('Te falta elegir: ' + sel.faltan.join(', ') + '.', 'error');
        carrito.agregar(M.itemArmado(menu, sel.elegidas), 1);
        U.toast(menu.armado.nombre + ' agregado.');
        // Listo para otra combinación, sin las opciones de la anterior
        return M.agregado(
          tarjeta,
          carrito.items().filter((x) => x.origen === 'armado').reduce((n, x) => n + x.cantidad, 0)
        );
      }

      const c = e.target.closest('[data-add-carta]');
      if (c) {
        const p = S.getCarta({ sucursalId: sucursalId }).find((x) => x.id === c.dataset.addCarta);
        if (!p || !p.disponible) return U.toast('Ese plato no está disponible.', 'error');
        carrito.agregar({ refId: p.id, nombre: p.nombre, precio: p.precio, origen: 'carta' }, 1);
        return U.toast(p.nombre + ' agregado.');
      }
    });

    U.acciones(EVENTOS, {
      'ver-pedido': verPedido,
      'enviar': enviarACocina,
    });

    carrito.onCambio(pintarBarra);
  }

  /* =================================================================
     ARRANQUE
     ================================================================= */
  function iniciar() {
    S.sembrar();

    if (!NASCAR.SUCURSALES.some((s) => s.id === sucursalId)) {
      U.toast('Unidad no reconocida o inactiva, mostrando ' + suc.corto + '.', 'info');
    }

    pintarCabecera();
    conectarSelectorDeMesa();
    pintarDia();
    pintarFiltros();
    pintarCarta();
    conectarEventos();
    pintarBarra();
    U.iniciarComunes();

    S.onChange(function () {
      pintarDia();
      pintarCarta();
    });
  }

  document.addEventListener('DOMContentLoaded', iniciar);
})();
