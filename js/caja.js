/* ==========================================================================
   NASCAR · caja.js
   LA ESTACIÓN DE CAJA

   Una sola pantalla para quien está cobrando, pensada para no salir de ella
   en todo el turno. Dos cosas, porque son las dos que hace esa persona:

     🧾  Vender       toca productos, ve el total y cobra. Lo que no hay que
                      preparar se entrega en el acto; lo que sí, se va a
                      cocina ya pagado.
     💳  Por cobrar   todo el dinero de un pedido: lo que espera cobro, el
                      comprobante que adjuntó el cliente, el rechazo y el
                      histórico de lo ya resuelto.

   Antes eran dos sitios distintos -la venta no existía y lo pendiente vivía
   en «Pagos»-, y eso es justo lo que el cliente pidió arreglar: encontrar
   las cosas con un par de toques. «Pagos» ya no existe como sección: era
   otro sitio para lo mismo, y tener dos listas de lo que falta cobrar
   invita a cobrar dos veces.

   Quien cobra NO decide nada aquí por su cuenta: confirmar y rechazar
   siguen pidiendo el permiso `pagos` y pasando por el mismo cuadro de
   diálogo de siempre, que vive en js/admin.js y se recibe por ctx.

   Lo que decide si algo pasa por cocina es el PRODUCTO, no quien vende:
   cada plato de la carta lleva su marca (Carta → «Se entrega en el acto»).
   Quien cobra no tiene que acordarse de nada.
   ========================================================================== */

window.NASCAR = window.NASCAR || {};

NASCAR.Caja = (function () {
  'use strict';

  const S = NASCAR.Store;
  const U = NASCAR.UI;
  const A = NASCAR.Auth;

  let ctx = null;

  /* Lo que se está vendiendo ahora mismo. Vive sólo mientras la pantalla
     está abierta: una venta a medias no se guarda en ninguna parte. */
  let ticket = [];
  let vista = 'vender';        // 'vender' | 'cobrar'
  let categoria = 'todas';
  let busqueda = '';
  let metodo = '';
  let claveVenta = '';         // la del envío en curso, para no duplicar

  function $(sel) {
    return ctx.raiz.querySelector(sel);
  }

  /* La sede en la que se está cobrando: la del usuario si tiene una
     asignada, y si no la del selector del panel. Igual que en las demás
     pantallas de operación. */
  function sucursal() {
    return A.sucursalDelUsuario() || Number(ctx.sucursalGlobal()) || U.sucursalPorDefectoId();
  }

  function iniciar(opciones) {
    /* Las cuatro acciones de dinero las presta el panel: son los mismos
       cuadros de diálogo que se usaban en «Pagos», con su permiso y su
       confirmación. Aquí no se duplican, se reciben. */
    ctx = {
      raiz: opciones.raiz,
      sucursalGlobal: opciones.sucursalGlobal || (() => ''),
      cobrar: opciones.cobrar || function () {},
      rechazar: opciones.rechazar || function () {},
      verComprobante: opciones.verComprobante || function () {},
      ver: opciones.ver || function () {},
    };
    if (!$('[data-panel="caja"]')) return;

    $('#cajaSub').addEventListener('click', function (e) {
      const b = e.target.closest('[data-caja-vista]');
      if (!b) return;
      vista = b.dataset.cajaVista;
      refrescar();
    });

    $('#cajaBuscar').addEventListener('input', function () {
      busqueda = this.value.trim().toLowerCase();
      pintarProductos();
    });

    $('#cajaCategorias').addEventListener('click', function (e) {
      const b = e.target.closest('[data-caja-cat]');
      if (!b) return;
      categoria = b.dataset.cajaCat;
      pintarProductos();
      pintarCategorias();
    });

    $('#cajaProductos').addEventListener('click', function (e) {
      const b = e.target.closest('[data-caja-add]');
      if (b) agregar(b.dataset.cajaAdd);
    });

    $('#cajaTicket').addEventListener('click', function (e) {
      const mas = e.target.closest('[data-caja-mas]');
      if (mas) return cambiar(Number(mas.dataset.cajaMas), 1);

      const menos = e.target.closest('[data-caja-menos]');
      if (menos) return cambiar(Number(menos.dataset.cajaMenos), -1);

      if (e.target.closest('#cajaVaciar')) {
        ticket = [];
        claveVenta = '';
        return pintarTicket();
      }
    });

    /* Los filtros sólo repintan la lista de abajo: no tocan la venta ni
       el contador de la pestaña, que cuenta lo pendiente de verdad. */
    ['#fTipoPago', '#fEstadoPago', '#fPagoDesde', '#fPagoHasta'].forEach(function (sel) {
      const campo = $(sel);
      if (campo) campo.addEventListener('change', pintarPorCobrar);
    });

    $('#cajaPorCobrar').addEventListener('click', function (e) {
      const b = e.target.closest('[data-caja-cobrar]');
      if (b) return ctx.cobrar(b.dataset.cajaCobrar, refrescar);

      const r = e.target.closest('[data-caja-rechazar]');
      if (r) return ctx.rechazar(r.dataset.cajaRechazar, refrescar);

      const c = e.target.closest('[data-caja-comprobante]');
      if (c) return ctx.verComprobante(c.dataset.cajaComprobante);

      const v = e.target.closest('[data-caja-ver]');
      if (v) return ctx.ver(v.dataset.cajaVer);
    });
  }

  /* =================================================================
     LO QUE SE PUEDE VENDER
     ================================================================= */
  function carta() {
    const suc = sucursal();
    return S.getCarta({ sucursalId: suc }).filter((p) => p.activo !== false && !p.agotado);
  }

  function pintarCategorias() {
    const porId = {};
    S.getCategorias({ todas: true }).forEach((c) => (porId[c.id] = c.nombre));
    const cats = {};
    carta().forEach((p) => (cats[p.cat] = porId[p.cat] || 'Otros'));

    const chip = (valor, texto) =>
      '<button class="chip' + (String(categoria) === String(valor) ? ' is-activo' : '') +
      '" data-caja-cat="' + U.esc(valor) + '">' + U.esc(texto) + '</button>';

    $('#cajaCategorias').innerHTML =
      chip('todas', 'Todo') +
      Object.keys(cats).map((id) => chip(id, cats[id])).join('');
  }

  function pintarProductos() {
    const lista = carta().filter(function (p) {
      if (categoria !== 'todas' && String(p.cat) !== String(categoria)) return false;
      if (!busqueda) return true;
      return (p.nombre + ' ' + (p.codigo || '')).toLowerCase().indexOf(busqueda) >= 0;
    });

    $('#cajaProductos').innerHTML = lista.length
      ? lista
          .map(
            (p) =>
              '<button class="caja-prod" data-caja-add="' + U.esc(p.id) + '">' +
              '<span class="caja-prod__nombre">' + U.esc(p.nombre) + '</span>' +
              '<span class="caja-prod__precio">' + U.money(p.precio) + '</span>' +
              (p.requierePreparacion === false
                ? '<span class="caja-prod__marca">Se entrega</span>'
                : '<span class="caja-prod__marca caja-prod__marca--cocina">Cocina</span>') +
              '</button>'
          )
          .join('')
      : '<div class="vacio"><div class="vacio__ico">🔎</div><h3>Nada que mostrar</h3>' +
        '<p class="mini">' +
        (busqueda ? 'Ningún producto coincide con «' + U.esc(busqueda) + '».'
                  : 'Esta sede todavía no tiene carta publicada.') +
        '</p></div>';
  }

  /* =================================================================
     EL TICKET
     ================================================================= */
  function agregar(refId) {
    const p = carta().find((x) => x.id === refId);
    if (!p) return;
    const i = ticket.findIndex((x) => x.refId === refId);
    if (i >= 0) ticket[i].cantidad++;
    else
      ticket.push({
        refId: p.id,
        nombre: p.nombre,
        precio: Number(p.precio),
        cantidad: 1,
        origen: 'carta',
        requierePreparacion: p.requierePreparacion !== false,
      });
    pintarTicket();
  }

  function cambiar(i, delta) {
    if (!ticket[i]) return;
    ticket[i].cantidad += delta;
    if (ticket[i].cantidad <= 0) ticket.splice(i, 1);
    pintarTicket();
  }

  function total() {
    return ticket.reduce((s, x) => s + x.precio * x.cantidad, 0);
  }

  function metodosActivos() {
    return (S.getConfig().metodosPago || []).filter((m) => m.activo);
  }

  /* En el mostrador el nombre largo estorba: los de la configuración están
     escritos para el domicilio («Efectivo contra entrega», «Datáfono en la
     puerta»). Aquí se cobra de frente, así que basta con la palabra. */
  function nombreCorto(m) {
    return { efectivo: 'Efectivo', datafono: 'Datáfono', transferencia: 'Transferencia' }[m.id]
        || m.nombre || m.id;
  }

  function pintarTicket() {
    const caja = $('#cajaTicket');
    const metodos = metodosActivos();
    if (!metodo || !metodos.some((m) => m.id === metodo)) metodo = (metodos[0] || {}).id || 'efectivo';

    const aCocina = ticket.some((x) => x.requierePreparacion);
    const n = ticket.reduce((s, x) => s + x.cantidad, 0);

    caja.innerHTML =
      '<div class="caja-ticket__lista">' +
      (ticket.length
        ? ticket
            .map(
              (x, i) =>
                '<div class="caja-ticket__linea">' +
                '<span class="caja-ticket__nombre">' + U.esc(x.nombre) +
                (x.requierePreparacion ? ' <i class="mini tenue">· cocina</i>' : '') + '</span>' +
                '<span class="fila" style="gap:6px">' +
                '<button class="btn btn--fantasma btn--xs" data-caja-menos="' + i + '">−</button>' +
                '<b style="min-width:24px;text-align:center">' + x.cantidad + '</b>' +
                '<button class="btn btn--fantasma btn--xs" data-caja-mas="' + i + '">+</button>' +
                '<b style="min-width:80px;text-align:right">' + U.money(x.precio * x.cantidad) + '</b>' +
                '</span></div>'
            )
            .join('')
        : '<div class="caja-ticket__vacio">Toca un producto para empezar la venta.</div>') +
      '</div>' +

      '<div class="caja-ticket__pie">' +
      (aCocina
        ? '<p class="mini ambar" style="margin:0 0 8px">Lleva algo que hay que preparar: ' +
          'al cobrar se va a cocina y el cliente espera.</p>'
        : '') +

      '<label class="campo"><span>¿Con qué paga?</span><select class="select" id="cajaMetodo">' +
      metodos
        .map((m) => '<option value="' + U.esc(m.id) + '"' + (m.id === metodo ? ' selected' : '') + '>' +
          U.esc(nombreCorto(m)) + '</option>')
        .join('') +
      '</select></label>' +

      '<div class="caja-ticket__total"><span>Total</span><b>' + U.money(total()) + '</b></div>' +

      '<button class="btn btn--bloque caja-ticket__cobrar" id="cajaCobrar"' +
      (ticket.length ? '' : ' disabled') + '>' +
      '💵 Cobrar' + (n ? ' · ' + n + (n === 1 ? ' producto' : ' productos') : '') + '</button>' +
      (ticket.length
        ? '<button class="btn btn--fantasma btn--bloque mt-8" id="cajaVaciar">Vaciar</button>'
        : '') +
      '</div>';

    const sel = $('#cajaMetodo');
    if (sel) sel.addEventListener('change', function () { metodo = this.value; });

    U.unaVez($('#cajaCobrar'), '⏳ Cobrando…', cobrar);
  }

  /* =================================================================
     COBRAR
     ================================================================= */
  function cobrar() {
    if (!ticket.length) return false;
    if (!A.exigir('pagos')) return false;

    /* Una clave por intento: si el cobro falla y se vuelve a tocar, va la
       misma y la base no registra dos ventas. */
    if (!claveVenta) claveVenta = U.claveEnvio();

    const firma = A.firma();
    let venta;
    try {
      venta = S.crearPedido({
        clave: claveVenta,
        tipo: 'mostrador',
        sucursalId: sucursal(),
        cliente: {},
        items: ticket.map((x) => ({
          refId: x.refId, nombre: x.nombre, precio: x.precio, cantidad: x.cantidad, origen: 'carta',
        })),
        metodoPago: metodo,
        usuarioId: firma.usuarioId,
        usuarioNombre: firma.usuarioNombre,
      });
    } catch (err) {
      U.toast(err.message || 'No se pudo registrar la venta.', 'error');
      return false; // el botón vuelve: se puede reintentar con la misma clave
    }

    const aCocina = ticket.some((x) => x.requierePreparacion);
    ticket = [];
    claveVenta = '';
    U.toast(
      'Venta ' + venta.codigo + ' cobrada · ' + U.money(venta.total) +
      (aCocina ? '. Va a cocina.' : '. Entregada.'),
      aCocina ? 'info' : 'ok'
    );
    refrescar();
  }

  /* =================================================================
     LO QUE ESPERA EL DINERO

     Esta vista reemplaza a la sección «Pagos». Dos cosas que conviene no
     confundir:

       pendientes()  la COLA de trabajo: lo que falta cobrar, pase lo que
                     pase con los filtros. De aquí sale el contador de la
                     pestaña, así que tiene que contar lo real.
       listaPagos()  lo que se está MIRANDO: la cola o el histórico, según
                     los filtros de arriba.

     Un pago rechazado no está en la cola —ya se resolvió, no se cobró—,
     pero tampoco queda intocable: sigue en el histórico con su botón de
     cobrar, porque un rechazo por error no puede dejar una factura
     imposible de cobrar para siempre.
     ================================================================= */
  function pendientes() {
    const suc = sucursal();
    return S.getPedidos({ sucursalId: suc })
      .filter((p) => p.estadoPago !== 'confirmado' && p.estadoPago !== 'rechazado'
                  && p.estado !== 'cancelado' && p.estado !== 'anulado')
      .sort((a, b) => (a.creado < b.creado ? -1 : 1));
  }

  function modoPago() {
    const sel = $('#fEstadoPago');
    return (sel && sel.value) || 'por-confirmar';
  }

  function listaPagos() {
    const modo = modoPago();
    const f = { sucursalId: sucursal() };

    const tipo = ($('#fTipoPago') || {}).value;
    if (tipo) f.tipo = tipo;

    /* El rango de fechas es para CONSULTAR, no para trabajar: a la cola de
       lo que falta cobrar no se le aplica. Una mesa que lleva dos semanas
       sin pagar tiene que verse igual, y un rango de «los últimos 7 días»
       la escondía. */
    if (modo !== 'por-confirmar') {
      const desde = ($('#fPagoDesde') || {}).value;
      const hasta = ($('#fPagoHasta') || {}).value;
      if (desde) f.desde = desde;
      if (hasta) f.hasta = hasta;
    }

    /* Las anuladas salen de aquí igual que las canceladas: ya no hay nada
       que cobrar. El movimiento de pago NO se borra —queda en la factura,
       con su estado de pago tal como estaba al anular. */
    let lista = S.getPedidos(f).filter(
      (p) => p.estado !== 'cancelado' && p.estado !== 'anulado'
    );

    if (modo === 'por-confirmar')
      lista = lista.filter((p) => p.estadoPago !== 'confirmado' && p.estadoPago !== 'rechazado');
    else if (modo === 'confirmado') lista = lista.filter((p) => p.estadoPago === 'confirmado');
    else if (modo === 'rechazado') lista = lista.filter((p) => p.estadoPago === 'rechazado');

    /* Lo que lleva más esperando, primero: es el orden en que hay que
       atenderlo. El histórico se lee al contrario, lo último arriba. */
    return lista.sort(function (a, b) {
      if (modo === 'por-confirmar') return a.creado < b.creado ? -1 : 1;
      return a.creado < b.creado ? 1 : -1;
    });
  }

  function kpi(label, valor, extra, color) {
    return (
      '<div class="kpi' + (color ? ' kpi--' + color : '') + '">' +
      '<div class="kpi__label">' + U.esc(label) + '</div>' +
      '<div class="kpi__valor">' + valor + '</div>' +
      (extra ? '<div class="kpi__extra">' + U.esc(extra) + '</div>' : '') +
      '</div>'
    );
  }

  /* Lo que dice el estado del pago, en las palabras de quien cobra: lo que
     importa no es el nombre del campo, es si entró el dinero. */
  const BADGE_PAGO = {
    confirmado: '<span class="badge badge--verde">Pago confirmado</span>',
    reportado: '<span class="badge badge--ambar">Dice que ya pagó</span>',
    rechazado: '<span class="badge badge--rojo">Pago rechazado</span>',
    pendiente: '<span class="badge badge--linea">Sin cobrar</span>',
  };

  function quienEs(p) {
    if (p.tipo === 'mesa') return 'Mesa ' + U.esc(p.mesa);
    if (p.tipo === 'domicilio') return U.esc(p.cliente.nombre || 'Domicilio');
    return 'Mostrador';
  }

  function tarjetaPago(p) {
    const cobrable = p.estadoPago !== 'confirmado';
    const enCola = p.estadoPago !== 'confirmado' && p.estadoPago !== 'rechazado';
    const comp = S.getComprobante(p.id);
    const ref = p.comprobante || p.referenciaPago || '';

    return (
      '<div class="op-card op-card--' + p.estado + '">' +
      '<div class="op-card__top">' +
      '<span class="op-card__codigo">' + U.esc(p.codigo) + '</span>' +
      (BADGE_PAGO[p.estadoPago] || BADGE_PAGO.pendiente) +
      '</div>' +

      '<div class="op-datos">' +
      '<div><span>Quién</span><b>' + quienEs(p) + '</b></div>' +
      '<div><span>Total</span><b>' + U.money(p.total) + '</b></div>' +
      '<div><span>' + (p.estadoPago === 'confirmado' ? 'Pagó con' : 'Dice pagar con') +
      '</span><b>' + U.esc(p.metodoPago) + '</b></div>' +
      '<div><span>' + (enCola ? 'Esperando' : 'Cuándo') + '</span><b>' +
      (enCola ? U.haceCuanto(p.creado) : U.esc(p.fecha) + ' · ' + U.hora(p.creado)) +
      '</b></div>' +
      '<div><span>Pedido</span><b>' + U.esc(S.ETIQUETA_ESTADO[p.estado] || p.estado) + '</b></div>' +
      '<div><span>Referencia</span><b>' +
      (ref ? U.esc(ref) : '<span class="tenue">—</span>') + '</b></div>' +
      '</div>' +

      /* El comprobante que subió el cliente se mira ANTES de confirmar: una
         imagen se puede editar y el valor hay que cuadrarlo con el banco.
         Por eso el chip va encima del botón de cobrar, no escondido. */
      (comp
        ? '<button class="comprobante-chip mt-8" data-caja-comprobante="' + U.esc(p.id) + '">' +
          '📎 Ver comprobante adjunto</button>'
        : '') +

      (cobrable
        ? '<button class="btn btn--bloque mt-8 caja-ticket__cobrar" data-caja-cobrar="' +
          U.esc(p.id) + '">💵 Cobrar ' + U.money(p.total) + '</button>'
        : '') +

      '<div class="fila mt-8" style="gap:8px">' +
      (enCola
        ? '<button class="btn btn--fantasma btn--sm crece" data-caja-rechazar="' + U.esc(p.id) + '" ' +
          'style="border-color:var(--rojo);color:var(--rojo-claro)">✕ Rechazar pago</button>'
        : '') +
      '<button class="btn btn--fantasma btn--sm' + (enCola ? '' : ' crece') +
      '" data-caja-ver="' + U.esc(p.id) + '">Ver pedido</button>' +
      '</div>' +
      '</div>'
    );
  }

  function pintarPorCobrar() {
    const modo = modoPago();
    const lista = listaPagos();

    /* Los tres primeros números son siempre de la COLA, no de lo que se
       está mirando: son el estado del turno. Mirar el histórico de marzo
       no puede hacer creer que no queda nada por cobrar. */
    const cola = pendientes();
    const monto = cola.reduce((s, p) => s + p.total, 0);
    const entregados = cola.filter((p) => p.estado === 'entregado');

    /* El cuarto acompaña a lo que se mira: trabajando, lo cobrado hoy;
       consultando, lo confirmado en el rango que se pidió. */
    const confirmados = modo === 'por-confirmar'
      ? S.getPedidos({ sucursalId: sucursal(), fecha: S.hoy() })
          .filter((p) => p.estadoPago === 'confirmado').length
      : lista.filter((p) => p.estadoPago === 'confirmado').length;

    $('#kpisPagos').innerHTML =
      kpi('Por cobrar', cola.length, 'Pedidos que esperan el dinero',
        cola.length ? 'ambar' : 'verde') +
      kpi('Monto pendiente', U.money(monto), 'Dinero aún no recibido en caja',
        monto ? 'rojo' : 'verde') +
      kpi('Entregados sin cobrar', entregados.length,
        U.money(entregados.reduce((s, p) => s + p.total, 0)),
        entregados.length ? 'rojo' : 'verde') +
      kpi(modo === 'por-confirmar' ? 'Cobrados hoy' : 'Confirmados en el rango',
        confirmados, '', 'verde');

    const nota = $('#cajaNotaRango');
    if (nota)
      nota.textContent = modo === 'por-confirmar'
        ? 'La cola muestra todo lo que falta cobrar, sin importar las fechas: '
          + 'el rango de arriba sólo filtra el histórico.'
        : '';

    $('#cajaPorCobrar').innerHTML = lista.length
      ? lista.map(tarjetaPago).join('')
      : '<div class="vacio"><div class="vacio__ico">' +
        (modo === 'por-confirmar' ? '✅' : '🔎') + '</div>' +
        '<h3>' + (modo === 'por-confirmar' ? 'Nada por cobrar' : 'Nada en este rango') + '</h3>' +
        '<p class="mini">' +
        (modo === 'por-confirmar'
          ? 'Todo lo de esta sede ya está pagado.'
          : 'Ningún pedido coincide con los filtros.') +
        '</p></div>';
  }

  /* =================================================================
     REPINTADO
     ================================================================= */
  function refrescar() {
    if (!ctx || !$('[data-panel="caja"]')) return;

    const n = pendientes().length;
    $('#cajaSub').innerHTML =
      '<button class="sub-tab' + (vista === 'vender' ? ' is-activo' : '') + '" data-caja-vista="vender">' +
      '🧾 Vender</button>' +
      '<button class="sub-tab' + (vista === 'cobrar' ? ' is-activo' : '') + '" data-caja-vista="cobrar">' +
      '💳 Por cobrar' + (n ? ' <b>' + n + '</b>' : '') + '</button>';

    $('#cajaVender').classList.toggle('oculto', vista !== 'vender');
    $('#cajaCobrarVista').classList.toggle('oculto', vista !== 'cobrar');

    if (vista === 'vender') {
      pintarCategorias();
      pintarProductos();
      pintarTicket();
    } else {
      pintarPorCobrar();
    }
  }

  return { iniciar: iniciar, refrescar: refrescar };
})();
