/* ==========================================================================
   NASCAR · operacion.js
   Las tres vistas de piso, pensadas para el celular y para gente con prisa:

     🍽️  Mesero       toma pedidos de mesa y entrega los que están listos
     👨‍🍳  Cocinero     prepara y marca listo
     🛵  Domiciliario  recoge, sale y entrega

   Cada vista sólo muestra lo que ese rol necesita y sólo permite las
   transiciones de estado que le corresponden (NASCAR.Auth.puedeTransicion).
   ========================================================================== */

window.NASCAR = window.NASCAR || {};

NASCAR.Operacion = (function () {
  'use strict';

  const S = NASCAR.Store;
  const U = NASCAR.UI;
  const A = NASCAR.Auth;
  const M = NASCAR.MenuDia; // pintor compartido del menú del día

  let ctx = null;

  function $(sel) {
    return ctx.raiz.querySelector(sel);
  }

  /* Sucursal en la que trabaja quien está conectado. Si el usuario tiene
     sucursal asignada manda esa; si no, la del selector del panel. */
  function sucursalTrabajo() {
    return A.sucursalDelUsuario() || Number(ctx.sucursalGlobal()) || U.sucursalPorDefectoId();
  }

  function iniciar(opciones) {
    ctx = { raiz: opciones.raiz, sucursalGlobal: opciones.sucursalGlobal || (() => '') };

    if ($('[data-panel="mesero"]')) conectarMesero();
    if ($('[data-panel="cocina"]')) conectarCocina();
    if ($('[data-panel="entregas"]')) conectarEntregas();

    refrescar();
  }

  function refrescar() {
    if (!ctx) return;
    if ($('#mesaGrid')) pintarMesero();
    if ($('#listaCocina')) pintarCocina();
    if ($('#listaEntregas')) pintarEntregas();
  }

  /* =================================================================
     🍽️  MESERO
     ================================================================= */
  const carritoMesero = [];
  let mesaSeleccionada = null;
  let categoriaMesero = 'todos';

  function conectarMesero() {
    $('#mSubMesas').addEventListener('click', () => cambiarVistaMesero('mesas'));
    $('#mSubListos').addEventListener('click', () => cambiarVistaMesero('listos'));

    $('#mesaGrid').addEventListener('click', function (e) {
      const b = e.target.closest('[data-mesa-num]');
      if (!b) return;
      mesaSeleccionada = b.dataset.mesaNum;
      abrirTomaPedido();
    });

    $('#listaListos').addEventListener('click', function (e) {
      const b = e.target.closest('[data-entregar]');
      if (!b) return;
      const p = S.getPedido(b.dataset.entregar);
      if (!A.puedeTransicion(p, 'entregado'))
        return U.toast('Tu perfil no puede cerrar este pedido.', 'error');
      U.confirmar('¿Ya entregaste el pedido ' + p.codigo + ' en la mesa ' + p.mesa + '?', function () {
        S.cambiarEstado(p.id, 'entregado');
        U.toast('Pedido ' + p.codigo + ' entregado.' +
          (p.estadoPago !== 'confirmado' ? ' El pago lo cobra y confirma caja.' : ''));
        refrescar();
      }, 'Sí, entregado');
    });
  }

  function cambiarVistaMesero(cual) {
    $('#mSubMesas').classList.toggle('is-activo', cual === 'mesas');
    $('#mSubListos').classList.toggle('is-activo', cual === 'listos');
    $('#vistaMesas').classList.toggle('oculto', cual !== 'mesas');
    $('#vistaListos').classList.toggle('oculto', cual === 'mesas');
  }

  function pintarMesero() {
    const sucId = sucursalTrabajo();
    const suc = U.sucursal(sucId);

    // ---- Mesas
    const activos = S.getPedidos({ sucursalId: sucId, tipo: 'mesa', activos: true });
    const porMesa = {};
    activos.forEach(function (p) {
      (porMesa[p.mesa] = porMesa[p.mesa] || []).push(p);
    });

    $('#mesaContexto').innerHTML =
      '<div class="inv-contexto__dato"><span>Sucursal</span><b>' + U.esc(suc.nombre) + '</b></div>' +
      '<div class="inv-contexto__dato"><span>Mesas ocupadas</span><b>' +
      Object.keys(porMesa).length + ' / ' + suc.mesas + '</b></div>' +
      '<div class="inv-contexto__dato"><span>Pedidos abiertos</span><b>' + activos.length + '</b></div>';

    let html = '';
    for (let i = 1; i <= (suc.mesas || 0); i++) {
      const enMesa = porMesa[String(i)] || [];
      const listos = enMesa.filter((p) => p.estado === 'listo').length;
      const estado = listos ? 'listo' : enMesa.length ? 'ocupada' : 'libre';

      html +=
        '<button class="mesa-btn mesa-btn--' + estado + '" data-mesa-num="' + i + '">' +
        '<b>' + i + '</b>' +
        '<span>' +
        (listos ? '¡Listo!' : enMesa.length ? enMesa.length + ' pedido' + (enMesa.length > 1 ? 's' : '') : 'Libre') +
        '</span></button>';
    }
    $('#mesaGrid').innerHTML = html || '<p class="tenue">Esta sucursal no tiene mesas configuradas.</p>';

    // ---- Listos para llevar a la mesa
    const listos = S.getPedidos({ sucursalId: sucId, tipo: 'mesa', estado: 'listo' });
    $('#mBadgeListos').textContent = listos.length;
    $('#mBadgeListos').classList.toggle('oculto', listos.length === 0);

    $('#listaListos').innerHTML = listos.length
      ? listos
          .map(
            (p) =>
              '<div class="op-card op-card--listo">' +
              '<div class="op-card__top">' +
              '<span class="op-card__codigo">Mesa ' + U.esc(p.mesa) + '</span>' +
              '<span class="badge badge--verde">Listo</span></div>' +
              '<div class="mini tenue mb-8">' + U.esc(p.codigo) + ' · ' + U.haceCuanto(p.creado) + '</div>' +
              '<div class="op-card__items">' +
              p.items.map((it) => '<div>' + it.cantidad + '× ' + U.esc(it.nombre) +
                (it.detalle ? ' <span class="mini tenue">(' + U.esc(it.detalle) + ')</span>' : '') + '</div>').join('') +
              '</div>' +
              '<button class="btn btn--rojo btn--bloque mt-8" data-entregar="' + p.id + '">' +
              '✓ Entregado en la mesa</button></div>'
          )
          .join('')
      : '<div class="vacio"><div class="vacio__ico">☕</div><h3>Nada listo por ahora</h3>' +
        '<p class="mini">Cuando cocina marque un pedido como listo aparecerá aquí.</p></div>';
  }

  /* --- Toma de pedido para una mesa --- */
  function abrirTomaPedido() {
    if (!A.exigir('pedidos_mesa')) return;

    const sucId = sucursalTrabajo();
    const suc = U.sucursal(sucId);
    carritoMesero.length = 0;
    categoriaMesero = 'todos';

    const m = U.modal({
      titulo: 'Mesa ' + mesaSeleccionada + ' · ' + suc.corto,
      ancho: 620,
      contenido:
        '<div id="tpAbiertos"></div>' +
        '<div class="filtros" id="tpFiltros"></div>' +
        '<input class="input mb-16" id="tpBuscar" placeholder="Buscar producto…">' +
        '<div id="tpLista" style="max-height:42vh;overflow-y:auto"></div>' +
        '<div id="tpResumen" class="mt-16"></div>',
    });

    function pintarAbiertos() {
      const abiertos = S.getPedidos({ sucursalId: sucId, tipo: 'mesa', activos: true }).filter(
        (p) => String(p.mesa) === String(mesaSeleccionada)
      );
      U.$('#tpAbiertos', m.raiz).innerHTML = abiertos.length
        ? '<div class="caja-datos mb-16"><b class="azul">Esta mesa ya tiene ' + abiertos.length +
          ' pedido' + (abiertos.length > 1 ? 's' : '') + ' abierto' + (abiertos.length > 1 ? 's' : '') + '</b>' +
          abiertos
            .map(
              (p) =>
                '<div class="linea"><span class="tenue">' + U.esc(p.codigo) + ' · ' +
                S.ETIQUETA_ESTADO[p.estado] + '</span><b>' + U.money(p.total) + '</b></div>'
            )
            .join('') +
          '<p class="mini tenue" style="margin:6px 0 0">Lo que agregues ahora entra como un pedido nuevo a la misma mesa.</p></div>'
        : '';
    }

    function pintarFiltros() {
      const cats = [{ id: 'todos', nombre: 'Todo', icono: '🏁' }].concat(S.getCategorias({ sucursalId: sucId }));
      U.$('#tpFiltros', m.raiz).innerHTML = cats
        .map(
          (c) =>
            '<button class="chip' + (c.id === categoriaMesero ? ' is-activo' : '') +
            '" data-cat="' + c.id + '">' + c.icono + ' ' + U.esc(c.nombre) + '</button>'
        )
        .join('');
    }

    let armadoAbierto = false; // el menú armado desplegado en la lista

    function pintarLista() {
      const q = (U.$('#tpBuscar', m.raiz).value || '').trim().toLowerCase();
      let platos = S.getCartaDisponible(sucId);
      if (categoriaMesero !== 'todos') platos = platos.filter((p) => p.cat === categoriaMesero);
      if (q) platos = platos.filter((p) => p.nombre.toLowerCase().includes(q));

      /* El menú del día también se puede pedir en mesa, en la modalidad que
         publica la sucursal hoy: platos del chef, o el menú armado, que se
         despliega aquí mismo con las mismas opciones que ve el cliente. */
      const menuHoy = S.getMenuPublico(S.hoy(), sucId);
      let lineasDia = '';
      if (menuHoy.tipo === 'armado' && menuHoy.armado) {
        lineasDia =
          '<div class="op-linea"><div class="crece"><b>' + U.esc(menuHoy.armado.nombre) + '</b>' +
          '<span class="mini tenue"> · Menú armado · ' + U.money(menuHoy.armado.precio) + '</span></div>' +
          '<button class="btn btn--rojo btn--xs" data-armar-menu>' + (armadoAbierto ? 'Cerrar' : 'Elegir') + '</button></div>' +
          (armadoAbierto
            ? '<div class="md-mesero" data-armado-mesero>' + M.camposArmado(menuHoy, 'mesero') +
              '<div data-acciones-armado><button class="btn btn--rojo btn--sm btn--bloque" ' +
              'data-add-armado-mesero>Agregar al pedido</button></div></div>'
            : '');
      } else if (menuHoy.tipo === 'chef') {
        lineasDia = menuHoy.platos
          .map(
            (p) =>
              '<div class="op-linea"><div class="crece"><b>' + (p.emoji ? U.esc(p.emoji) + ' ' : '') + U.esc(p.nombre) + '</b>' +
              '<span class="mini tenue"> · ' + U.money(p.precio) + '</span></div>' +
              '<button class="btn btn--rojo btn--xs" data-add-dia="' + p.id + '">+</button></div>'
          )
          .join('');
      }

      U.$('#tpLista', m.raiz).innerHTML =
        (categoriaMesero === 'todos' && !q && lineasDia
          ? '<div class="prod-grupo__titulo">Menú del día</div>' + lineasDia
          : '') +
        (platos.length
          ? '<div class="prod-grupo__titulo">Carta</div>' +
            platos
              .map(
                (p) =>
                  '<div class="op-linea"><div class="crece"><b>' + U.esc(p.nombre) + '</b>' +
                  '<span class="mini tenue"> · ' + U.money(p.precio) + '</span></div>' +
                  '<button class="btn btn--fantasma btn--xs" data-add="' + p.id + '">+</button></div>'
              )
              .join('')
          : '<p class="tenue mini">Sin productos.</p>');
    }

    function pintarResumen() {
      const total = carritoMesero.reduce((s, x) => s + x.precio * x.cantidad, 0);
      const n = carritoMesero.reduce((s, x) => s + x.cantidad, 0);

      U.$('#tpResumen', m.raiz).innerHTML = carritoMesero.length
        ? '<div class="caja-datos">' +
          carritoMesero
            .map(
              (it, i) =>
                '<div class="linea"><span>' + U.esc(it.nombre) +
                (it.detalle ? '<br><span class="mini tenue">' + U.esc(it.detalle) + '</span>' : '') + '</span>' +
                '<span class="fila" style="gap:6px">' +
                '<button class="btn btn--fantasma btn--xs" data-menos="' + i + '">−</button>' +
                '<b style="min-width:26px;text-align:center">' + it.cantidad + '</b>' +
                '<button class="btn btn--fantasma btn--xs" data-mas="' + i + '">+</button>' +
                '<b style="min-width:82px;text-align:right">' + U.money(it.precio * it.cantidad) + '</b>' +
                '</span></div>'
            )
            .join('') +
          '<div class="linea" style="border-top:1px solid var(--borde);padding-top:8px;margin-top:6px">' +
          '<span><b>Total (' + n + ')</b></span><b>' + U.money(total) + '</b></div></div>' +
          '<button class="btn btn--rojo btn--bloque mt-16" id="tpEnviar">🏁 Enviar a cocina</button>'
        : '<p class="mini tenue centro">Agrega productos para armar el pedido.</p>';
    }

    function agregar(producto) {
      const i = carritoMesero.findIndex((x) => x.refId === producto.refId);
      if (i >= 0) carritoMesero[i].cantidad++;
      else carritoMesero.push(Object.assign({ cantidad: 1 }, producto));
      pintarResumen();
    }

    M.conectar(m.raiz); // quita el aviso rojo al elegir una opción del menú armado

    m.raiz.addEventListener('click', function (e) {
      const c = e.target.closest('[data-cat]');
      if (c) {
        categoriaMesero = c.dataset.cat;
        pintarFiltros();
        return pintarLista();
      }

      const a = e.target.closest('[data-add]');
      if (a) {
        const p = S.getPlatoCarta(a.dataset.add);
        return agregar({ refId: p.id, nombre: p.nombre, precio: p.precio, origen: 'carta' });
      }

      const d = e.target.closest('[data-add-dia]');
      if (d) {
        const p = S.getMenuPublico(S.hoy(), sucId).platos.find((x) => x.id === d.dataset.addDia);
        if (!p) return U.toast('Ese plato ya no está disponible.', 'error');
        return agregar({
          refId: p.id, nombre: p.nombre + ' (menú del día)', precio: p.precio, origen: 'dia',
        });
      }

      if (e.target.closest('[data-armar-menu]')) {
        armadoAbierto = !armadoAbierto;
        return pintarLista();
      }

      const am = e.target.closest('[data-add-armado-mesero]');
      if (am) {
        const menu = S.getMenuPublico(S.hoy(), sucId);
        if (!menu.armado) return U.toast('El menú armado ya no está disponible.', 'error');
        const sel = M.leerSeleccion(am.closest('[data-armado-mesero]'), menu);
        if (!sel.ok) return U.toast('Falta elegir: ' + sel.faltan.join(', ') + '.', 'error');
        agregar(M.itemArmado(menu, sel.elegidas));
        /* Se queda abierto y limpio: el mesero encadena las combinaciones
           de la mesa sin volver a abrir el menú. Misma lógica que el
           portal y la mesa (js/menu-dia.js). */
        return M.agregado(
          am.closest('[data-armado-mesero]'),
          carritoMesero.filter((x) => x.origen === 'armado').reduce((n, x) => n + x.cantidad, 0)
        );
      }

      const mas = e.target.closest('[data-mas]');
      if (mas) {
        carritoMesero[Number(mas.dataset.mas)].cantidad++;
        return pintarResumen();
      }

      const menos = e.target.closest('[data-menos]');
      if (menos) {
        const i = Number(menos.dataset.menos);
        carritoMesero[i].cantidad--;
        if (carritoMesero[i].cantidad <= 0) carritoMesero.splice(i, 1);
        return pintarResumen();
      }

      if (e.target.closest('#tpEnviar')) return enviar();
    });

    U.$('#tpBuscar', m.raiz).addEventListener('input', pintarLista);

    function enviar() {
      if (!A.exigir('pedidos_mesa')) return;
      const firma = A.firma();
      let pedido;
      try {
        pedido = S.crearPedido({
          tipo: 'mesa',
          sucursalId: sucId,
          mesa: mesaSeleccionada,
          cliente: { nombre: 'Mesa ' + mesaSeleccionada, notas: '' },
          items: carritoMesero,
          metodoPago: 'efectivo',
          usuarioId: firma.usuarioId,
          usuarioNombre: firma.usuarioNombre,
        });
      } catch (err) {
        return U.toast(err.message || 'No se pudo enviar el pedido.', 'error');
      }
      m.cerrar();
      U.toast('Pedido ' + pedido.codigo + ' enviado a cocina.');
      refrescar();
    }

    pintarAbiertos();
    pintarFiltros();
    pintarLista();
    pintarResumen();
  }

  /* =================================================================
     👨‍🍳  COCINA
     ================================================================= */
  function conectarCocina() {
    $('#listaCocina').addEventListener('click', function (e) {
      const b = e.target.closest('[data-avanzar-cocina]');
      if (!b) return;
      const p = S.getPedido(b.dataset.avanzarCocina);
      const destino = b.dataset.destino;

      if (!A.puedeTransicion(p, destino))
        return U.toast('Tu perfil no puede hacer ese cambio.', 'error');

      S.cambiarEstado(p.id, destino);
      U.toast(p.codigo + ' → ' + S.ETIQUETA_ESTADO[destino]);
      refrescar();
    });

    $('#cocinaSoloMias').addEventListener('change', pintarCocina);
  }

  function pintarCocina() {
    const sucId = A.sucursalDelUsuario() || Number(ctx.sucursalGlobal()) || null;
    const filtro = { activos: true };
    if (sucId) filtro.sucursalId = sucId; // la cocina ve sólo SU unidad

    const pedidos = S.getPedidos(filtro).filter(
      (p) => p.estado === 'nuevo' || p.estado === 'preparacion'
    );
    // En cocina lo más viejo va primero: es lo que lleva más esperando.
    pedidos.sort((a, b) => (a.creado < b.creado ? -1 : 1));

    const nuevos = pedidos.filter((p) => p.estado === 'nuevo');
    const enCurso = pedidos.filter((p) => p.estado === 'preparacion');

    $('#kpisCocina').innerHTML =
      kpi('Por empezar', nuevos.length, 'Pedidos nuevos', nuevos.length ? 'rojo' : 'verde') +
      kpi('En preparación', enCurso.length, 'En las manos de cocina', 'ambar') +
      kpi('Más antiguo', pedidos.length ? U.haceCuanto(pedidos[0].creado) : '—', 'Tiempo de espera');

    $('#listaCocina').innerHTML = pedidos.length
      ? pedidos.map(tarjetaCocina).join('')
      : '<div class="vacio"><div class="vacio__ico">🍳</div><h3>Cocina al día</h3>' +
        '<p class="mini">No hay pedidos pendientes de preparar.</p></div>';
  }

  function tarjetaCocina(p) {
    const suc = U.sucursal(p.sucursalId);
    const minutos = Math.floor((Date.now() - new Date(p.creado).getTime()) / 60000);
    const urgente = minutos > 20;
    const destino = p.estado === 'nuevo' ? 'preparacion' : 'listo';

    return (
      '<div class="op-card op-card--' + p.estado + (urgente ? ' op-card--urgente' : '') + '">' +
      '<div class="op-card__top">' +
      '<span class="op-card__codigo">' +
      (p.tipo === 'mesa' ? '🍽️ Mesa ' + U.esc(p.mesa) : '🛵 Domicilio') + '</span>' +
      '<span class="badge ' + (p.estado === 'nuevo' ? 'badge--rojo' : 'badge--ambar') + '">' +
      S.ETIQUETA_ESTADO[p.estado] + '</span>' +
      '</div>' +

      '<div class="mini tenue mb-8">' + U.esc(p.codigo) + ' · ' + U.esc(suc.corto) +
      ' · <span class="' + (urgente ? 'rojo' : '') + '">🕐 ' + U.haceCuanto(p.creado) + '</span></div>' +

      '<div class="op-card__items">' +
      p.items
        .map(
          (it) =>
            '<div class="op-item"><b>' + it.cantidad + '×</b> ' + U.esc(it.nombre) +
            (it.detalle ? '<div class="op-nota">🍽️ ' + U.esc(it.detalle) + '</div>' : '') +
            (it.notas ? '<div class="op-nota">📝 ' + U.esc(it.notas) + '</div>' : '') + '</div>'
        )
        .join('') +
      '</div>' +

      (p.cliente && p.cliente.notas
        ? '<div class="op-nota op-nota--general">📌 ' + U.esc(p.cliente.notas) + '</div>'
        : '') +

      '<button class="btn ' + (p.estado === 'nuevo' ? 'btn--azul' : 'btn--rojo') +
      ' btn--bloque mt-8" data-avanzar-cocina="' + p.id + '" data-destino="' + destino + '">' +
      (p.estado === 'nuevo' ? '▶ Empezar a preparar' : '✓ Marcar listo') +
      '</button></div>'
    );
  }

  /* =================================================================
     🛵  ENTREGAS
     ================================================================= */
  function conectarEntregas() {
    $('#listaEntregas').addEventListener('click', function (e) {
      const b = e.target.closest('[data-avanzar-entrega]');
      if (b) {
        const p = S.getPedido(b.dataset.avanzarEntrega);
        const destino = b.dataset.destino;

        if (!A.puedeTransicion(p, destino))
          return U.toast('Tu perfil no puede hacer ese cambio.', 'error');

        // Aviso claro antes de cerrar un domicilio que aún no está pagado
        if (destino === 'entregado' && p.estadoPago !== 'confirmado' && p.metodoPago !== 'efectivo') {
          return U.confirmar(
            'El pago de ' + p.codigo + ' (' + p.metodoPago + ') todavía no está confirmado por caja. ' +
              '¿Ya recibiste el dinero?',
            function () {
              S.cambiarEstado(p.id, 'entregado');
              U.toast(p.codigo + ' entregado.');
              refrescar();
            },
            'Sí, entregar'
          );
        }

        S.cambiarEstado(p.id, destino);
        U.toast(p.codigo + ' → ' + S.ETIQUETA_ESTADO[destino] +
          (destino === 'entregado' && p.estadoPago !== 'confirmado'
            ? '. Entrega el dinero en caja: allí se confirma el pago.' : ''));
        return refrescar();
      }

      const v = e.target.closest('[data-ver-entrega]');
      if (v) return verDetalleEntrega(v.dataset.verEntrega);
    });
  }

  function pintarEntregas() {
    const sucId = A.sucursalDelUsuario() || Number(ctx.sucursalGlobal()) || null;
    const filtro = { tipo: 'domicilio', activos: true };
    if (sucId) filtro.sucursalId = sucId;

    const pedidos = S.getPedidos(filtro).filter(
      (p) => p.estado === 'listo' || p.estado === 'camino'
    );
    pedidos.sort((a, b) => (a.creado < b.creado ? -1 : 1));

    const paraRecoger = pedidos.filter((p) => p.estado === 'listo');
    const enRuta = pedidos.filter((p) => p.estado === 'camino');
    const porCobrar = pedidos.filter((p) => p.estadoPago !== 'confirmado');

    $('#kpisEntregas').innerHTML =
      kpi('Listos para salir', paraRecoger.length, 'Recoger en cocina', paraRecoger.length ? 'rojo' : 'verde') +
      kpi('En camino', enRuta.length, 'Ya salieron', 'ambar') +
      kpi('Por cobrar en ruta', porCobrar.length, U.money(porCobrar.reduce((s, p) => s + p.total, 0)), 'azul');

    $('#listaEntregas').innerHTML = pedidos.length
      ? pedidos.map(tarjetaEntrega).join('')
      : '<div class="vacio"><div class="vacio__ico">🛵</div><h3>Sin entregas pendientes</h3>' +
        '<p class="mini">Cuando cocina marque un domicilio como listo aparecerá aquí.</p></div>';
  }

  function tarjetaEntrega(p) {
    const suc = U.sucursal(p.sucursalId);
    const destino = p.estado === 'listo' ? 'camino' : 'entregado';
    const pagoOk = p.estadoPago === 'confirmado';
    const wa = U.enlaceWhatsApp(null, '');

    return (
      '<div class="op-card op-card--' + p.estado + '">' +
      '<div class="op-card__top">' +
      '<span class="op-card__codigo">' + U.esc(p.codigo) + '</span>' +
      '<span class="badge ' + (p.estado === 'listo' ? 'badge--azul' : 'badge--ambar') + '">' +
      S.ETIQUETA_ESTADO[p.estado] + '</span>' +
      '</div>' +

      '<div class="op-datos">' +
      '<div><span>Cliente</span><b>' + U.esc(p.cliente.nombre || '—') + '</b></div>' +
      '<div><span>Dirección</span><b>' + U.esc(p.cliente.direccion || '—') + '</b></div>' +
      '<div><span>Zona</span><b>' + U.esc(p.cliente.zona || '—') + '</b></div>' +
      '<div><span>Sucursal</span><b>' + U.esc(suc.corto) + '</b></div>' +
      '</div>' +

      (p.cliente.notas
        ? '<div class="op-nota op-nota--general">📌 ' + U.esc(p.cliente.notas) + '</div>'
        : '') +

      '<div class="op-cobro' + (pagoOk ? ' op-cobro--ok' : '') + '">' +
      '<div><span class="mini tenue">' +
      (pagoOk ? 'Ya está pagado — no cobres' : 'Cobrar al entregar') + '</span>' +
      '<b>' + U.money(p.total) + '</b></div>' +
      '<div class="derecha"><span class="mini tenue">' + etiquetaMetodo(p.metodoPago) + '</span><br>' +
      (pagoOk
        ? '<span class="badge badge--verde">Pagado</span>'
        : '<span class="badge badge--ambar">Pendiente</span>') +
      (p.cliente.pagaCon
        ? '<br><span class="mini">Paga con ' + U.money(p.cliente.pagaCon) +
          ' · vueltas ' + U.money(Math.max(0, p.cliente.pagaCon - p.total)) + '</span>'
        : '') +
      '</div></div>' +

      '<div class="fila mt-8">' +
      (p.cliente.telefono
        ? '<a class="btn btn--fantasma btn--sm" href="tel:' + U.esc(p.cliente.telefono) + '">📞 Llamar</a>'
        : '') +
      '<button class="btn btn--fantasma btn--sm" data-ver-entrega="' + p.id + '">Ver pedido</button>' +
      '<div class="crece"></div>' +
      '</div>' +

      '<button class="btn ' + (p.estado === 'listo' ? 'btn--azul' : 'btn--rojo') +
      ' btn--bloque mt-8" data-avanzar-entrega="' + p.id + '" data-destino="' + destino + '">' +
      (p.estado === 'listo' ? '🛵 Salgo con este pedido' : '✓ Entregado') +
      '</button></div>'
    );
  }

  function etiquetaMetodo(m) {
    return { efectivo: 'Efectivo', transferencia: 'Transferencia', datafono: 'Datáfono' }[m] || m;
  }

  function verDetalleEntrega(pedidoId) {
    const p = S.getPedido(pedidoId);
    if (!p) return;

    U.modal({
      titulo: 'Pedido ' + p.codigo,
      ancho: 460,
      contenido:
        '<div class="caja-datos">' +
        '<div class="linea"><span class="tenue">Cliente</span><b>' + U.esc(p.cliente.nombre || '—') + '</b></div>' +
        '<div class="linea"><span class="tenue">Teléfono</span><b>' + U.esc(p.cliente.telefono || '—') + '</b></div>' +
        '<div class="linea"><span class="tenue">Dirección</span><b class="derecha">' +
        U.esc(p.cliente.direccion || '—') + '</b></div>' +
        '<div class="linea"><span class="tenue">Zona</span><b>' + U.esc(p.cliente.zona || '—') + '</b></div>' +
        '</div>' +

        '<table class="detalle-items">' +
        p.items
          .map(
            (it) =>
              '<tr><td class="c">' + it.cantidad + '×</td><td>' + U.esc(it.nombre) +
              (it.detalle ? '<br><span class="mini">🍽️ ' + U.esc(it.detalle) + '</span>' : '') +
              (it.notas ? '<br><span class="mini ambar">📝 ' + U.esc(it.notas) + '</span>' : '') +
              '</td><td class="p">' + U.money(it.precio * it.cantidad) + '</td></tr>'
          )
          .join('') +
        '</table>' +

        '<div class="totales">' +
        '<div><span>Subtotal</span><span class="num">' + U.money(p.subtotal) + '</span></div>' +
        '<div><span>Domicilio</span><span class="num">' + U.money(p.domicilio) + '</span></div>' +
        '<div class="total"><span>Total</span><span class="num">' + U.money(p.total) + '</span></div>' +
        '</div>',
    });
  }

  /* ---- helper ---- */
  function kpi(label, valor, extra, color) {
    return (
      '<div class="kpi' + (color ? ' kpi--' + color : '') + '">' +
      '<div class="kpi__label">' + U.esc(label) + '</div>' +
      '<div class="kpi__valor">' + valor + '</div>' +
      (extra ? '<div class="kpi__extra">' + U.esc(extra) + '</div>' : '') +
      '</div>'
    );
  }

  return {
    iniciar: iniciar,
    refrescar: refrescar,
  };
})();
