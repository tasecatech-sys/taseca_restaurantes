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

  /* Con cuánto paga el cliente, en el mostrador. Vive aquí y no dentro de
     pintarTicket porque el ticket se repinta con cada «+» y lo escrito no
     puede borrarse por agregar un producto. El cambio se recalcula solo
     contra el total nuevo. */
  let recibidoMostrador = null;

  /* Los pedidos marcados para cobrar de una vez. Vive aquí y no en el
     DOM porque la lista se repinta sola cada pocos segundos y la marca
     tiene que sobrevivir a eso. */
  const marcados = new Set();
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
      /* Para el cobro en lote: quién cobra -queda en el historial del
         pedido en modo local; en la nube sale del token- y qué repintar
         al terminar, que los contadores del panel cambian. */
      firma: opciones.firma || function () { return null; },
      alCobrar: opciones.alCobrar || function () {},
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
      const marca = e.target.closest('[data-caja-marcar]');
      if (marca) {
        const id = marca.dataset.cajaMarcar;
        marca.checked ? marcados.add(id) : marcados.delete(id);
        return refrescarBarraLote();
      }

      if (e.target.id === 'cajaLoteTodos') {
        const cobrables = listaPagos().filter((p) => p.estadoPago !== 'confirmado');
        if (e.target.checked) cobrables.forEach((p) => marcados.add(String(p.id)));
        else marcados.clear();
        return pintarPorCobrar(); // cambian TODAS las casillas
      }

      if (e.target.closest('#cajaLoteCobrar')) return cobrarLote();

      const b = e.target.closest('[data-caja-cobrar]');
      if (b) return ctx.cobrar(b.dataset.cajaCobrar, refrescar);

      const rc = e.target.closest('[data-caja-recibo]');
      if (rc) {
        imprimirRecibo([S.getPedido(rc.dataset.cajaRecibo)]);
        return U.toast('Imprimiendo el comprobante…');
      }

      const r = e.target.closest('[data-caja-rechazar]');
      if (r) return ctx.rechazar(r.dataset.cajaRechazar, refrescar);

      const c = e.target.closest('[data-caja-comprobante]');
      if (c) return ctx.verComprobante(c.dataset.cajaComprobante);

      const v = e.target.closest('[data-caja-ver]');
      if (v) return ctx.ver(v.dataset.cajaVer);
    });

    /* 🍳 Cocina con comanda: listo, reimprimir y la estación de este equipo */
    const coc = $('#cajaCocinaVista');
    if (coc) {
      coc.addEventListener('click', accionCocina);
      arrancarEstacion();
    }

    /* 🛵 Domiciliarios: cobrarle a uno y asignar quién llevó cada domicilio */
    const dom = $('#cajaDomiciliarios');
    if (dom) {
      dom.addEventListener('click', function (e) {
        const b = e.target.closest('[data-cobrar-dom]');
        if (b) cobrarADomiciliario(b.dataset.cobrarDom);
      });
      dom.addEventListener('change', function (e) {
        const sel = e.target.closest('[data-asignar-dom]');
        if (!sel) return;
        try {
          const p = S.asignarDomiciliario(sel.dataset.asignarDom, sel.value || null);
          U.toast(p && p.domiciliario ? p.codigo + ' → ' + p.domiciliario : 'Domiciliario quitado.');
        } catch (err) {
          U.toast(err.message, 'error');
        }
        refrescar();
      });
    }
  }

  /* =================================================================
     LO QUE SE PUEDE VENDER
     ================================================================= */
  function carta() {
    const suc = sucursal();
    return S.getCarta({ sucursalId: suc, personal: true }).filter((p) => p.activo !== false && !p.agotado);
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

  function subtotalTicket() {
    return ticket.reduce((s, x) => s + x.precio * x.cantidad, 0);
  }

  /* Lo que el método de pago le cobra encima al cliente. Lo calcula el
     store, no esta pantalla: la factura y el panel tienen que decir el
     mismo número. */
  function recargoTicket() {
    return S.recargoDeMetodo(metodo, subtotalTicket());
  }

  /* LO QUE SE LE PIDE AL CLIENTE.

     Esto sumaba sólo los productos. crearPedido SÍ le sumaba el recargo
     del método, así que con Nequi la caja leía 9.000 en pantalla, le
     pedía 9.000 al cliente, y el sistema registraba la venta en 9.500:
     faltaban 500 en el cajón por cada venta con recargo y nada lo
     avisaba. Encima, el cambio se calculaba contra el número de la
     pantalla, así que también se devolvía de más. */
  function total() {
    return subtotalTicket() + recargoTicket();
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

      /* El recargo sólo se nombra si lo hay: una línea en cero no informa
         y hace dudar de si se está cobrando algo de más. Pero si lo hay,
         tiene que verse, porque es lo que la caja le va a decir al
         cliente que pague. */
      (recargoTicket() > 0
        ? '<div class="caja-ticket__recargo"><span>Recargo · ' +
          U.esc(nombreCorto(metodosActivos().find((m) => m.id === metodo) || { id: metodo })) +
          '</span><b>' + U.money(recargoTicket()) + '</b></div>'
        : '') +

      '<div class="caja-ticket__total"><span>Total</span><b>' + U.money(total()) + '</b></div>' +

      /* En el mostrador el cliente paga de frente y casi siempre con un
         billete. Sin ticket no hay nada que cobrar, así que tampoco hay
         cambio que calcular. */
      (ticket.length ? U.bloqueCambio(total(), 'cm', recibidoMostrador) : '') +

      '<button class="btn btn--bloque caja-ticket__cobrar" id="cajaCobrar"' +
      (ticket.length ? '' : ' disabled') + '>' +
      '💵 Cobrar' + (n ? ' · ' + n + (n === 1 ? ' producto' : ' productos') : '') + '</button>' +
      (ticket.length
        ? '<button class="btn btn--fantasma btn--bloque mt-8" id="cajaVaciar">Vaciar</button>'
        : '') +
      '</div>';

    const sel = $('#cajaMetodo');

    /* Sólo el efectivo deja cambio. El bloque se queda montado y se
       muestra u oculta: así no se pierde lo ya escrito al cambiar de
       método por error. */
    const cajaCambio = $('#cmCaja');
    function seguirMetodo() {
      if (cajaCambio) cajaCambio.classList.toggle('oculto', metodo !== 'efectivo');
    }
    if (sel)
      sel.addEventListener('change', function () {
        metodo = this.value;
        /* Se repinta entero: con el método cambia el RECARGO y por tanto
           el total, los atajos del cambio y lo que hay que devolver. Lo
           ya escrito sobrevive en recibidoMostrador. */
        pintarTicket();
      });

    leerCambio = ticket.length
      ? U.montarCambio(caja, total(), 'cm', function (e) { recibidoMostrador = e.recibido; })
      : null;
    seguirMetodo();

    U.unaVez($('#cajaCobrar'), '⏳ Cobrando…', cobrar);
  }

  /* =================================================================
     COBRAR
     ================================================================= */
  /* Lo devuelve montarCambio; se rellena en cada repintado del ticket. */
  let leerCambio = null;

  function cobrar() {
    if (!ticket.length) return false;
    if (!A.exigir('pagos')) return false;

    /* La venta de mostrador NACE cobrada: una vez registrada no hay dónde
       volver a cobrar. Si lo que hay en la mano no alcanza, se para aquí. */
    const efectivo = metodo === 'efectivo' && leerCambio ? leerCambio() : null;
    if (efectivo && efectivo.falta > 0) {
      U.toast('No alcanza: faltan ' + U.money(efectivo.falta) + '.', 'error');
      return false;
    }

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
    if (metodo === 'efectivo') {
      siCajonImprimir([venta], { metodo: 'efectivo', recibido: efectivo && efectivo.recibido });
    }
    ticket = [];
    claveVenta = '';
    recibidoMostrador = null;   // lo del cliente anterior no es lo del siguiente
    U.toast(
      'Venta ' + venta.codigo + ' cobrada · ' + U.money(venta.total) +
      (efectivo && efectivo.cambio > 0 ? ' · devuelve ' + U.money(efectivo.cambio) : '') +
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
    /* El que recoge también tiene nombre: es quien va a aparecer en el
       mostrador a reclamarlo, así que en caja hay que poder buscarlo por
       ahí. Sin el caso, caía en «Mostrador» y no se distinguía de una
       venta directa. */
    if (p.tipo === 'recoger') return U.esc(p.cliente.nombre || 'Recoge en el local');
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
      /* La casilla sólo en la COLA: en el histórico no hay nada que
         cobrar y una casilla ahí sólo confundiría. */
      (enCola
        ? '<input class="pago-check" type="checkbox" data-caja-marcar="' + U.esc(p.id) + '"' +
          (marcados.has(String(p.id)) ? ' checked' : '') +
          ' aria-label="Marcar ' + U.esc(p.codigo) + ' para cobrar en lote">'
        : '') +
      '<span class="op-card__codigo">' + U.esc(p.codigo) + '</span>' +
      (BADGE_PAGO[p.estadoPago] || BADGE_PAGO.pendiente) +
      '</div>' +

      '<div class="op-datos">' +
      '<div><span>Quién</span><b>' + quienEs(p) + '</b></div>' +
      '<div><span>Total</span><b>' + U.money(p.total) + '</b></div>' +
      '<div><span>' + (p.estadoPago === 'confirmado' ? 'Pagó con' : 'Dice pagar con') +
      '</span><b>' + U.esc(S.nombreDeMetodo(p.metodoPago)) + '</b></div>' +
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
          'style="border-color:var(--peligro);color:var(--peligro-claro)">✕ Rechazar pago</button>'
        : '') +
      '<button class="btn btn--fantasma btn--sm' + (enCola ? '' : ' crece') +
      '" data-caja-ver="' + U.esc(p.id) + '">Ver pedido</button>' +
      (p.estadoPago === 'confirmado' && tieneCajon(p.sucursalId)
        ? '<button class="btn btn--fantasma btn--sm" data-caja-recibo="' + U.esc(p.id) + '">🖨 Recibo</button>'
        : '') +
      '</div>' +
      '</div>'
    );
  }

  /* ---------------------------------------------------------------
     COBRAR VARIOS DE UNA VEZ

     Confirmar un pago cuesta unos 460 ms, y casi todo es el viaje a la
     base: el trabajo del servidor son ~16 ms. Veinte cobros de uno en
     uno eran veinte viajes con el navegador congelado en cada uno. Esto
     los manda juntos, en una sola llamada.
     --------------------------------------------------------------- */
  function barraLote(lista, modo) {
    if (modo !== 'por-confirmar') return '';
    const cobrables = lista.filter((p) => p.estadoPago !== 'confirmado');
    if (cobrables.length < 2) return ''; // con uno solo no hay lote que valga

    const sel = cobrables.filter((p) => marcados.has(String(p.id)));
    const monto = sel.reduce((s, p) => s + p.total, 0);
    const todos = sel.length === cobrables.length;

    return (
      '<div class="lote-barra" id="cajaLoteBarra">' +
      '<label class="lote-barra__todos">' +
      '<input type="checkbox" id="cajaLoteTodos"' + (todos ? ' checked' : '') + '>' +
      '<span>' + (todos ? 'Quitar todos' : 'Marcar los ' + cobrables.length) + '</span></label>' +
      '<span class="lote-barra__cuenta" id="cajaLoteCuenta">' +
      (sel.length
        ? sel.length + ' marcado' + (sel.length === 1 ? '' : 's') + ' · ' + U.money(monto)
        : 'Marca los que ya recibiste') +
      '</span>' +
      '<button class="btn btn--sm lote-barra__btn" id="cajaLoteCobrar"' +
      (sel.length ? '' : ' disabled') + '>💵 Cobrar ' +
      (sel.length ? 'los ' + sel.length : 'marcados') + '</button>' +
      '</div>'
    );
  }

  /* Sólo cambia el texto y el botón: repintar la lista entera en cada
     clic haría perder el scroll justo cuando se está marcando. */
  function refrescarBarraLote() {
    const barra = $('#cajaLoteBarra');
    if (!barra) return;
    const cobrables = listaPagos().filter((p) => p.estadoPago !== 'confirmado');
    const sel = cobrables.filter((p) => marcados.has(String(p.id)));
    const monto = sel.reduce((s, p) => s + p.total, 0);

    $('#cajaLoteCuenta').textContent = sel.length
      ? sel.length + ' marcado' + (sel.length === 1 ? '' : 's') + ' · ' + U.money(monto)
      : 'Marca los que ya recibiste';

    const btn = $('#cajaLoteCobrar');
    btn.disabled = !sel.length;
    btn.innerHTML = '💵 Cobrar ' + (sel.length ? 'los ' + sel.length : 'marcados');

    const todos = $('#cajaLoteTodos');
    todos.checked = sel.length === cobrables.length && cobrables.length > 0;
    todos.nextElementSibling.textContent = todos.checked
      ? 'Quitar todos'
      : 'Marcar los ' + cobrables.length;
  }

  function cobrarLote() {
    const cobrables = listaPagos().filter((p) => p.estadoPago !== 'confirmado');
    const sel = cobrables.filter((p) => marcados.has(String(p.id)));
    if (!sel.length) return false;

    const monto = sel.reduce((s, p) => s + p.total, 0);

    /* Se pregunta antes: cobrar es irreversible desde la pantalla, y
       marcar veinte casillas es fácil de hacer sin querer. */
    U.confirmar(
      'Vas a dar por recibidos ' + U.money(monto) + ' de ' + sel.length +
      ' pedido' + (sel.length === 1 ? '' : 's') + '. Cada uno se cobra con SU método ' +
      'de pago, el que dijo el cliente.',
      function () {
        let r;
        try {
          r = S.confirmarPagos(sel.map((p) => p.id), null, ctx.firma ? ctx.firma() : null);
        } catch (e) {
          return U.toast(e.message, 'error');
        }
        marcados.clear();
        const ok = new Set(((r && r.ok) || []).map((x) => String(x.id)));
        const cobrados = sel.filter((p) => !r || !r.ok || ok.has(String(p.id)) || ok.has(String(p.idBase)))
          .map((p) => S.getPedido(p.id) || p);
        if (cobrados.some((p) => p.metodoPago === 'efectivo')) {
          siCajonImprimir(cobrados, { titulo: 'Cobro de ' + cobrados.length + ' pedidos' });
        }
        refrescar();
        if (ctx.alCobrar) ctx.alCobrar();

        if (r.fallidos) {
          U.toast('Cobrados ' + r.cobrados + '. No se pudo con ' + r.fallidos + ': ' +
                  (r.mal[0] ? r.mal[0].codigo + ' · ' + r.mal[0].motivo : ''), 'error');
        } else {
          U.toast('Cobrados ' + r.cobrados + ' pedidos · ' + U.money(monto) + '.');
        }
      },
      'Sí, cobrar los ' + sel.length
    );
    return false;
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

    /* Al repintar, se olvidan las marcas de lo que ya no está en la
       lista: si un pedido se cobró o se filtró, su marca no puede
       quedarse viva e invisible. */
    const visibles = new Set(lista.map((p) => String(p.id)));
    Array.from(marcados).forEach((id) => { if (!visibles.has(id)) marcados.delete(id); });

    $('#cajaPorCobrar').innerHTML = lista.length
      ? barraLote(lista, modo) + lista.map(tarjetaPago).join('')
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
     🛵 DOMICILIARIOS

     Qué domicilios llevó cada uno y cuánto EFECTIVO hay que cobrarle.
     Sólo el efectivo: lo de Nequi, datáfono o transferencia no pasa por
     sus manos, se confirma en «Por cobrar» como siempre.
       · Te debe     entregado, en efectivo, pago sin confirmar.
       · En la calle salió y aún no entrega (todavía no tiene el dinero).
       · Cobrado hoy lo que ya se le cobró en la jornada.
     ================================================================= */
  function domiciliosDeSede() {
    return S.getPedidos({ sucursalId: sucursal(), tipo: 'domicilio' })
      .filter((p) => p.estado !== 'cancelado' && p.estado !== 'anulado');
  }

  const esEfectivo = (p) => (NASCAR.GRUPO_DE_METODO || {})[p.metodoPago] === 'efectivo' || p.metodoPago === 'efectivo';
  const pagoAbierto = (p) => p.estadoPago !== 'confirmado' && p.estadoPago !== 'rechazado';
  const leDebe = (p) => p.estado === 'entregado' && esEfectivo(p) && pagoAbierto(p);

  function deudaDomiciliarios() {
    try {
      return domiciliosDeSede().filter((p) => p.domiciliarioId && leDebe(p)).reduce((s, p) => s + p.total, 0);
    } catch (e) {
      return 0;
    }
  }

  function selectorDomiciliario(p, lista) {
    if (!pagoAbierto(p)) return '';
    return '<select class="select select--sm" data-asignar-dom="' + U.esc(p.id) + '" style="max-width:170px">' +
      '<option value="">' + (p.domiciliarioId ? '— Quitar —' : '— Asignar a… —') + '</option>' +
      lista.map((d) => '<option value="' + d.id + '"' + (String(d.id) === String(p.domiciliarioId) ? ' selected' : '') + '>' +
        U.esc(d.nombre) + '</option>').join('') +
      '</select>';
  }

  function filaDomicilio(p, lista) {
    return '<div class="fila" style="gap:8px;align-items:center;padding:6px 0;border-top:1px solid var(--borde, rgba(255,255,255,.08))">' +
      '<span class="mono"><b>' + U.esc(p.codigo) + '</b></span>' +
      '<span class="crece mini">' + U.esc(p.cliente.nombre || 'Domicilio') + ' · ' +
      U.esc(S.ETIQUETA_ESTADO[p.estado] || p.estado) + ' · ' + U.esc(S.nombreDeMetodo(p.metodoPago)) + '</span>' +
      '<b class="num">' + U.money(p.total) + '</b>' +
      selectorDomiciliario(p, lista) +
      '</div>';
  }

  function pintarDomiciliarios() {
    const lista = S.getDomiciliarios ? S.getDomiciliarios(sucursal()) : [];
    const pedidos = domiciliosDeSede();
    const hoy = S.hoy();

    /* Por domiciliario: los conocidos y los que aparezcan en pedidos (por si
       alguien dejó de estar activo con plata pendiente). */
    const grupos = {};
    lista.forEach((d) => (grupos[d.id] = { id: d.id, nombre: d.nombre }));
    pedidos.forEach(function (p) {
      if (p.domiciliarioId && !grupos[p.domiciliarioId])
        grupos[p.domiciliarioId] = { id: p.domiciliarioId, nombre: p.domiciliario || 'Domiciliario ' + p.domiciliarioId };
    });

    const filas = Object.keys(grupos).map(function (id) {
      const g = grupos[id];
      const suyos = pedidos.filter((p) => String(p.domiciliarioId) === String(id));
      g.debe = suyos.filter(leDebe);
      g.calle = suyos.filter((p) => p.estado === 'camino');
      g.cobradoHoy = suyos.filter((p) => p.fecha === hoy && esEfectivo(p) && p.estadoPago === 'confirmado');
      g.monto = g.debe.reduce((s, p) => s + p.total, 0);
      return g;
    }).sort((a, b) => b.monto - a.monto || a.nombre.localeCompare(b.nombre));

    const sinAsignar = pedidos.filter((p) => !p.domiciliarioId && pagoAbierto(p) &&
      (p.estado === 'listo' || p.estado === 'camino' || p.estado === 'entregado'));
    const totalDebe = filas.reduce((s, g) => s + g.monto, 0);
    const enCalle = filas.reduce((s, g) => s + g.calle.length, 0);

    $('#kpisDomiciliarios').innerHTML =
      kpi('Efectivo por cobrarles', U.money(totalDebe), 'Domicilios entregados en efectivo', totalDebe ? 'rojo' : 'verde') +
      kpi('En la calle', enCalle, 'Salieron y aún no entregan', enCalle ? 'ambar' : 'verde') +
      kpi('Sin domiciliario', sinAsignar.length, 'Asígnalos para saber a quién cobrar', sinAsignar.length ? 'ambar' : 'verde') +
      kpi('Cobrado hoy', U.money(filas.reduce((s, g) => s + g.cobradoHoy.reduce((t, p) => t + p.total, 0), 0)), 'Efectivo ya recibido', 'verde');

    let html = '';
    if (!lista.length && !filas.length) {
      html += '<div class="vacio"><div class="vacio__ico">🛵</div><h3>No hay domiciliarios</h3>' +
        '<p class="mini">Crea los usuarios con el rol «Domiciliario» en Configuración → Usuarios y asígnales esta sede.</p></div>';
    }

    if (sinAsignar.length) {
      html += '<div class="caja mb-16"><h3 style="margin:0 0 6px">⚠️ Sin domiciliario</h3>' +
        '<p class="mini tenue" style="margin:0 0 6px">Elige quién lo llevó: si no, no hay a quién cobrarle.</p>' +
        sinAsignar.map((p) => filaDomicilio(p, lista)).join('') + '</div>';
    }

    html += filas.map(function (g) {
      const cobrado = g.cobradoHoy.reduce((s, p) => s + p.total, 0);
      return '<div class="caja mb-16">' +
        '<div class="fila fila--entre" style="align-items:center;gap:8px">' +
        '<h3 style="margin:0">🛵 ' + U.esc(g.nombre) + '</h3>' +
        '<span class="mini tenue">' + g.calle.length + ' en la calle · cobrado hoy ' + U.money(cobrado) + '</span></div>' +
        (g.debe.length
          ? '<p class="mini" style="margin:8px 0 4px">Te debe <b>' + U.money(g.monto) + '</b> de ' + g.debe.length +
            ' domicilio' + (g.debe.length === 1 ? '' : 's') + ' entregado' + (g.debe.length === 1 ? '' : 's') + ' en efectivo:</p>' +
            g.debe.map((p) => filaDomicilio(p, lista)).join('') +
            '<button class="btn btn--bloque mt-8 caja-ticket__cobrar" data-cobrar-dom="' + U.esc(g.id) + '">' +
            '💵 Recibí ' + U.money(g.monto) + ' de ' + U.esc(g.nombre) + '</button>'
          : '<p class="mini tenue" style="margin:8px 0 0">No te debe efectivo.</p>') +
        (g.calle.length
          ? '<details class="mt-8"><summary class="mini">En la calle (' + g.calle.length + ')</summary>' +
            g.calle.map((p) => filaDomicilio(p, lista)).join('') + '</details>'
          : '') +
        '</div>';
    }).join('');

    $('#cajaDomiciliarios').innerHTML = html;
  }

  function cobrarADomiciliario(id) {
    const debe = domiciliosDeSede().filter((p) => String(p.domiciliarioId) === String(id) && leDebe(p));
    if (!debe.length) return;
    const nombre = debe[0].domiciliario || 'el domiciliario';
    const monto = debe.reduce((s, p) => s + p.total, 0);
    U.confirmar(
      '¿Recibiste ' + U.money(monto) + ' en efectivo de ' + nombre + '? Se confirma el pago de ' + debe.length +
      ' domicilio' + (debe.length === 1 ? '' : 's') + ' (' + debe.map((p) => p.codigo).join(', ') + ').',
      function () {
        let r;
        try {
          r = S.confirmarPagos(debe.map((p) => p.id), 'Efectivo entregado por ' + nombre, ctx.firma ? ctx.firma() : null);
        } catch (e) {
          return U.toast(e.message, 'error');
        }
        siCajonImprimir(debe.map((p) => S.getPedido(p.id) || p), { titulo: 'Efectivo entregado por ' + nombre });
        refrescar();
        if (ctx.alCobrar) ctx.alCobrar();
        if (r && r.fallidos) {
          U.toast('Cobrados ' + r.cobrados + '. No se pudo con ' + r.fallidos + ': ' +
                  (r.mal[0] ? r.mal[0].codigo + ' · ' + r.mal[0].motivo : ''), 'error');
        } else {
          U.toast('Recibido ' + U.money(monto) + ' de ' + nombre + '.');
        }
      },
      'Sí, lo recibí'
    );
  }

  /* =================================================================
     🍳 COCINA CON COMANDA IMPRESA (migración 52)

     En una sede con comanda, la cocina no toca el sistema: el pedido entra
     directo a «En preparación» y sale impreso. Aquí caja ve lo que está en
     cocina y marca «Listo» cuando la cocina le avisa.

     LA ESTACIÓN: el equipo junto a la impresora. Se marca UNA vez en ese
     equipo («Este equipo imprime las comandas») y, mientras el panel esté
     abierto, pregunta cada pocos segundos y manda a imprimir. Con Chrome en
     modo --kiosk-printing la comanda sale sin preguntar; sin él, aparece el
     cuadro de imprimir (sirve para probar). La base reparte cada comanda
     una sola vez aunque haya dos equipos marcados.
     ================================================================= */
  const CLAVE_ESTACION = 'taseca.estacionComandas.v1';
  let estadoEstacion = null;     // lo último que dijo la base: latido y pendientes
  let estadoPedidoEn = 0;
  let sondeo = null;
  let imprimiendo = Promise.resolve();

  function enPreparacion() {
    return S.getPedidos({ sucursalId: sucursal() })
      .filter((p) => p.estado === 'nuevo' || p.estado === 'preparacion')
      .sort((a, b) => (a.creado < b.creado ? -1 : 1));
  }

  /* La estación de ESTE equipo: { empresa, sede } o null. Vive en el
     navegador a propósito: es una propiedad del equipo, no del usuario. */
  function estacionDeEsteEquipo() {
    try {
      const e = JSON.parse(localStorage.getItem(CLAVE_ESTACION) || 'null');
      const emp = (S.getEmpresaActual && S.getEmpresaActual()) || {};
      return e && e.empresa === (emp.codigo || emp.id) ? e : null;
    } catch (err) {
      return null;
    }
  }

  function marcarEstacion(activa) {
    try {
      const emp = (S.getEmpresaActual && S.getEmpresaActual()) || {};
      if (activa) localStorage.setItem(CLAVE_ESTACION, JSON.stringify({ empresa: emp.codigo || emp.id, sede: Number(sucursal()) }));
      else localStorage.removeItem(CLAVE_ESTACION);
    } catch (err) {
      U.toast('Este navegador no deja guardar la preferencia (modo incógnito).', 'error');
    }
  }

  function estacionCaida() {
    return !!(estadoEstacion && estadoEstacion.activa &&
      (estadoEstacion.segundos_sin_estacion == null || estadoEstacion.segundos_sin_estacion > 90));
  }

  /* Cada 20 s, si la sede usa comanda: ¿la estación está viva? */
  function consultarEstacion() {
    const suc = sucursal();
    if (!(U.sucursal(suc) || {}).comandaImpresa || !S.estadoComandas) return;
    if (Date.now() - estadoPedidoEn < 20000) return;
    estadoPedidoEn = Date.now();
    S.estadoComandas(suc).then(function (r) {
      const antes = estacionCaida();
      estadoEstacion = r;
      if (antes !== estacionCaida() || vista === 'cocina') refrescar();
    }).catch(function () { /* sin red: se intenta en la próxima vuelta */ });
  }

  /* La estación: toma lo pendiente y lo imprime, en orden. */
  function vueltaEstacion() {
    const e = estacionDeEsteEquipo();
    if (e && S.tomarComandas && (U.sucursal(e.sede) || {}).comandaImpresa) {
      S.tomarComandas(e.sede).then(function (lista) {
        lista.forEach(function (x) {
          imprimiendo = imprimiendo.then(() => imprimirComandaCocina(x.pedido, x.cocina));
        });
        if (lista.length) refrescar();
      }).catch(function (err) {
        if (vista === 'cocina') U.toast('Estación de comandas: ' + err.message, 'error');
      });
    }
    consultarEstacion();
  }

  function arrancarEstacion() {
    if (sondeo) return;
    sondeo = setInterval(vueltaEstacion, 6000);
    setTimeout(vueltaEstacion, 1500);
  }

  function nombreDelPedido(p) {
    if (p.tipo === 'mesa') return 'MESA ' + (p.mesa || '');
    if (p.tipo === 'domicilio') return 'DOMICILIO';
    if (p.tipo === 'recoger') return 'PARA LLEVAR';
    return 'MOSTRADOR';
  }

  /* La comanda de cocina: grande, sin precios, sólo lo que se prepara. */
  function htmlComanda(p, cocina) {
    const items = (p.items || []).filter((it) => !cocina || cocina.indexOf(Number(it.itemId)) >= 0);
    const emp = (S.getEmpresaActual && S.getEmpresaActual()) || {};
    const suc = U.sucursal(p.sucursalId) || {};
    const e = U.esc;
    return '<!DOCTYPE html><html lang="es"><head><meta charset="utf-8"><title>Comanda ' + e(p.codigo) + '</title><style>' +
      '@page{margin:0}body{font:14px/1.35 Arial,Helvetica,sans-serif;margin:0;padding:6px 8px;width:72mm;color:#000}' +
      '.cab{text-align:center;font-size:12px}.quien{font-size:24px;font-weight:900;text-align:center;margin:4px 0}' +
      '.cod{display:flex;justify-content:space-between;font-size:13px}hr{border:0;border-top:2px dashed #000;margin:6px 0}' +
      '.it{margin:6px 0}.it b{font-size:18px}.det{font-size:15px;font-weight:bold;padding-left:10px}' +
      '.nota{font-size:14px;font-style:italic;padding-left:10px}.gen{font-size:15px;font-weight:bold;border:2px solid #000;padding:4px;margin-top:6px}' +
      '</style></head><body>' +
      '<div class="cab">' + e(emp.nombre || '') + ' · ' + e(suc.corto || suc.nombre || '') + '</div>' +
      '<div class="quien">' + e(nombreDelPedido(p)) + '</div>' +
      (p.tipo !== 'mesa' && p.cliente && p.cliente.nombre ? '<div class="cab"><b>' + e(p.cliente.nombre) + '</b></div>' : '') +
      '<div class="cod"><b>#' + e(p.codigo) + '</b><span>' +
      new Date(p.creado).toLocaleTimeString('es-CO', { hour: 'numeric', minute: '2-digit' }) + '</span></div>' +
      (p.usuarioNombre ? '<div class="cab">Tomó: ' + e(p.usuarioNombre) + '</div>' : '') +
      '<hr>' +
      items.map((it) =>
        '<div class="it"><b>' + it.cantidad + ' × ' + e(it.nombre.replace(' (menú del día)', '')) + '</b>' +
        (it.detalle ? '<div class="det">' + e(it.detalle) + '</div>' : '') +
        (it.notas ? '<div class="nota">* ' + e(it.notas) + '</div>' : '') + '</div>').join('') +
      (p.cliente && p.cliente.notas ? '<div class="gen">📌 ' + e(p.cliente.notas) + '</div>' : '') +
      '<hr><div class="cab">' + new Date().toLocaleString('es-CO') + '</div>' +
      '</body></html>';
  }

  /* Imprime en un marco oculto: con --kiosk-printing sale directo a la
     impresora predeterminada de Windows, sin cuadro de diálogo. */
  function imprimirComandaCocina(p, cocina) {
    return imprimirHTML(htmlComanda(p, cocina), 'la comanda ' + p.codigo);
  }

  /* Imprime un documento en un marco oculto. Con Chrome --kiosk-printing
     sale directo a la impresora predeterminada, sin cuadro de diálogo. Si
     el marco nunca termina de cargar, a los 15 s se sigue con lo próximo. */
  function imprimirHTML(html, que) {
    return new Promise(function (listo) {
      setTimeout(listo, 15000);
      const marco = document.createElement('iframe');
      marco.setAttribute('aria-hidden', 'true');
      marco.style.cssText = 'position:fixed;right:0;bottom:0;width:0;height:0;border:0;visibility:hidden';
      marco.onload = function () {
        try {
          marco.contentWindow.focus();
          marco.contentWindow.print();
        } catch (err) {
          U.toast('No se pudo imprimir ' + (que || 'el documento') + ': ' + err.message, 'error');
        }
        setTimeout(function () { marco.remove(); }, 60000);
        setTimeout(listo, 1500); // un respiro entre documentos
      };
      marco.srcdoc = html;
      document.body.appendChild(marco);
    });
  }

  /* =================================================================
     💵 CAJÓN MONEDERO (migración 54)

     En una sede con cajón, cada vez que la caja recibe efectivo se imprime
     el comprobante de pago. El cajón va conectado a la impresora y se abre
     cuando ella imprime (lo hace el driver de Windows, «abrir el cajón al
     imprimir»): el sistema sólo tiene que imprimir.

     El comprobante NO es una factura electrónica y lo dice.
     ================================================================= */
  function tieneCajon(sucursalId) {
    return !!(U.sucursal(sucursalId || sucursal()) || {}).cajonMonedero;
  }

  function htmlRecibo(pedidos, extra) {
    extra = extra || {};
    const e = U.esc;
    const emp = (S.getEmpresaActual && S.getEmpresaActual()) || {};
    const suc = U.sucursal((pedidos[0] && pedidos[0].sucursalId) || sucursal()) || {};
    const nit = NASCAR.CONFIG && NASCAR.CONFIG.pago && NASCAR.CONFIG.pago.nit;
    const uno = pedidos.length === 1 ? pedidos[0] : null;
    const total = pedidos.reduce((s, p) => s + (Number(p.total) || 0), 0);
    const linea = (izq, der, cls) =>
      '<div class="f' + (cls ? ' ' + cls : '') + '"><span>' + izq + '</span><span>' + der + '</span></div>';
    // En el papel, «Efectivo» a secas: «contra entrega» es cosa del domicilio
    const metodoCorto = (m) => (m === 'efectivo' ? 'Efectivo' : S.nombreDeMetodo(m));

    let cuerpo;
    if (uno) {
      cuerpo =
        linea('<b>#' + e(uno.codigo) + '</b>', e(nombreDelPedido(uno).toLowerCase())) +
        '<hr>' +
        (uno.items || []).map((it) =>
          '<div class="it">' + linea(it.cantidad + ' × ' + e(String(it.nombre).replace(' (menú del día)', '')),
            U.money((Number(it.precio) || 0) * (Number(it.cantidad) || 0))) +
          (it.detalle ? '<div class="n">' + e(it.detalle) + '</div>' : '') + '</div>').join('') +
        '<hr>' +
        linea('Subtotal', U.money(uno.subtotal)) +
        (uno.domicilio ? linea('Domicilio', U.money(uno.domicilio)) : '') +
        (uno.recargo ? linea('Recargo del pago', U.money(uno.recargo)) : '');
    } else {
      cuerpo = (extra.titulo ? '<div class="c"><b>' + e(extra.titulo) + '</b></div><hr>' : '<hr>') +
        pedidos.map((p) => linea('#' + e(p.codigo) + ' · ' + e(metodoCorto(p.metodoPago)), U.money(p.total))).join('') +
        '<hr>';
    }

    return '<!DOCTYPE html><html lang="es"><head><meta charset="utf-8"><title>Comprobante</title><style>' +
      '@page{margin:0}body{font:13px/1.4 "Courier New",monospace;margin:0;padding:8px 10px;width:72mm;color:#000}' +
      'h1{font:800 17px/1.2 Arial,Helvetica,sans-serif;margin:0;text-align:center}.c{text-align:center}' +
      '.f{display:flex;justify-content:space-between;gap:8px}.tot{font-size:17px;font-weight:bold;margin-top:4px}' +
      '.it{margin:4px 0}.n{font-size:11px;padding-left:12px}hr{border:0;border-top:1px dashed #000;margin:7px 0}' +
      '.aviso{font-size:10px;text-align:center;margin-top:6px}' +
      '</style></head><body>' +
      '<h1>' + e(emp.nombre || '') + '</h1>' +
      '<div class="c">' + e(suc.nombre || '') + (suc.direccion ? '<br>' + e(suc.direccion) : '') +
      (nit ? '<br>NIT ' + e(nit) : '') + '</div>' +
      '<hr><div class="c"><b>COMPROBANTE DE PAGO</b><br>' + new Date().toLocaleString('es-CO') + '</div><hr>' +
      cuerpo +
      linea('TOTAL', U.money(total), 'tot') +
      (uno ? linea('Pagó con', e(metodoCorto(extra.metodo || uno.metodoPago))) : '') +
      (extra.recibido ? linea('Recibido', U.money(extra.recibido)) : '') +
      (extra.recibido && extra.recibido > total ? linea('Cambio', U.money(extra.recibido - total)) : '') +
      (extra.atendio ? '<div class="c" style="margin-top:6px">Atendió: ' + e(extra.atendio) + '</div>' : '') +
      '<hr><div class="c">¡Gracias por su compra!</div>' +
      '<div class="aviso">Documento informativo. No es una factura electrónica.</div>' +
      '</body></html>';
  }

  /* Lo usa el panel (confirmar pago en admin.js) y esta misma caja. */
  function imprimirRecibo(pedidos, extra) {
    const lista = (Array.isArray(pedidos) ? pedidos : [pedidos]).filter(Boolean);
    if (!lista.length) return;
    const firma = A.firma ? A.firma() : null;
    const datos = Object.assign({ atendio: firma && firma.usuarioNombre }, extra || {});
    imprimiendo = imprimiendo.then(() => imprimirHTML(htmlRecibo(lista, datos), 'el comprobante'));
  }

  /* Al recibir efectivo en una sede con cajón: comprobante y cajón abierto. */
  function siCajonImprimir(pedidos, extra) {
    if (!tieneCajon()) return;
    imprimirRecibo(pedidos, extra);
  }

  /* ¿Lleva comanda? Lo mismo que decide la base (core.fn_pedido_va_a_cocina):
     menú del día siempre; de la carta, lo que no se entrega en el acto. Un
     pedido sólo de vitrina no se imprime, así que no se ofrece reimprimirlo. */
  function llevaComanda(p) {
    return (p.items || []).some(function (it) {
      if (it.origen && it.origen !== 'carta') return true;
      const prod = S.getPlatoCarta ? S.getPlatoCarta(it.refId) : null;
      return !prod || prod.requierePreparacion !== false;
    });
  }

  function pintarCocina() {
    const suc = sucursal();
    const sede = U.sucursal(suc) || {};
    const e = estacionDeEsteEquipo();
    const soyEstacion = !!(e && Number(e.sede) === Number(suc));
    const st = estadoEstacion;

    let aviso;
    if (soyEstacion) {
      aviso = '<div class="caja-datos" style="border-left:4px solid var(--verde)"><b>🖨 Este equipo imprime las comandas de ' +
        U.esc(sede.nombre || '') + '.</b><br><span class="mini tenue">Déjalo con el panel abierto. Para que salgan sin el cuadro ' +
        'de imprimir, abre Chrome con <code>--kiosk-printing</code> y la impresora térmica como predeterminada.</span>' +
        '<div class="mt-8"><button class="btn btn--fantasma btn--xs" data-estacion="no">Dejar de imprimir en este equipo</button> ' +
        '<button class="btn btn--fantasma btn--xs" data-estacion="prueba">🖨 Imprimir una prueba</button></div></div>';
    } else if (st && st.activa && !estacionCaida()) {
      aviso = '<div class="caja-datos" style="border-left:4px solid var(--verde)">🟢 <b>Estación de comandas conectada.</b> ' +
        '<span class="mini tenue">Los pedidos nuevos salen por la impresora de cocina.</span>' +
        '<div class="mt-8"><button class="btn btn--fantasma btn--xs" data-estacion="si">Usar este equipo como estación</button></div></div>';
    } else {
      aviso = '<div class="caja-datos" style="border-left:4px solid var(--rojo)">⚠️ <b>Ninguna estación de comandas está imprimiendo' +
        (st && st.segundos_sin_estacion != null ? ' (la última respondió hace ' + Math.round(st.segundos_sin_estacion / 60) + ' min)' : '') +
        '.</b><br><span class="mini">Los pedidos se guardan y saldrán apenas se conecte. Si este es el equipo de la impresora, márcalo:</span>' +
        (st && st.sin_imprimir ? '<br><span class="mini"><b>' + st.sin_imprimir + '</b> comanda(s) esperando impresión.</span>' : '') +
        '<div class="mt-8"><button class="btn btn--rojo btn--xs" data-estacion="si">🖨 Este equipo imprime las comandas</button></div></div>';
    }
    $('#cajaEstacion').innerHTML = aviso;

    const lista = enPreparacion();
    $('#cajaCocina').innerHTML = lista.length
      ? '<p class="mini tenue" style="margin:12px 0 6px">Cuando la cocina avise que un pedido está listo, márcalo aquí: ' +
        'el cliente, la mesera y el domiciliario lo ven al instante.</p>' +
        lista.map(function (p) {
          return '<div class="op-card op-card--' + p.estado + '">' +
            '<div class="op-card__top"><span class="op-card__codigo">' + U.esc(p.codigo) + '</span>' +
            '<span class="badge badge--ambar">' + U.esc(nombreDelPedido(p)) + '</span></div>' +
            '<div class="mini tenue">' + quienEs(p) + ' · ' + U.esc(U.haceCuanto(p.creado)) +
            (p.comandaImpresaEn === null ? ' · <b>sin imprimir</b>' : '') + '</div>' +
            '<div class="mt-8">' + (p.items || []).map((it) =>
              '<div><b>' + it.cantidad + ' ×</b> ' + U.esc(it.nombre) +
              (it.detalle ? '<br><span class="mini">' + U.esc(it.detalle) + '</span>' : '') +
              (it.notas ? '<br><span class="mini tenue">* ' + U.esc(it.notas) + '</span>' : '') + '</div>').join('') + '</div>' +
            '<div class="fila mt-8" style="gap:8px">' +
            '<button class="btn btn--bloque crece caja-ticket__cobrar" data-comanda-lista="' + U.esc(p.id) + '">✓ Listo</button>' +
            (llevaComanda(p)
              ? '<button class="btn btn--fantasma btn--sm" data-comanda-reimp="' + U.esc(p.id) + '">🖨 Reimprimir</button>'
              : '<span class="mini tenue" title="Todo sale de vitrina o se entrega en el acto">Sale de vitrina: no lleva comanda</span>') +
            '</div></div>';
        }).join('')
      : '<div class="vacio"><div class="vacio__ico">🍳</div><h3>Nada en cocina</h3>' +
        '<p class="mini">Los pedidos nuevos entran aquí directo, en preparación.</p></div>';
  }

  function accionCocina(e) {
    const est = e.target.closest('[data-estacion]');
    if (est) {
      const que = est.dataset.estacion;
      if (que === 'prueba') {
        imprimiendo = imprimiendo.then(() => imprimirComandaCocina({
          codigo: 'PRUEBA', tipo: 'mesa', mesa: '0', sucursalId: sucursal(), creado: new Date().toISOString(),
          usuarioNombre: 'Prueba de impresora', cliente: { notas: 'Si lees esto, la estación imprime bien.' },
          items: [{ cantidad: 1, nombre: 'Comanda de prueba', detalle: 'Entrada: Sopa · Bebida: Limonada' }],
        }, null));
        return;
      }
      marcarEstacion(que === 'si');
      estadoPedidoEn = 0;
      U.toast(que === 'si' ? 'Este equipo imprimirá las comandas.' : 'Este equipo ya no imprime comandas.');
      if (que === 'si') vueltaEstacion();
      return refrescar();
    }

    const l = e.target.closest('[data-comanda-lista]');
    if (l) {
      try {
        const p = S.comandaLista(l.dataset.comandaLista);
        U.toast((p ? p.codigo : 'El pedido') + ' está listo: el cliente ya lo ve.');
      } catch (err) {
        U.toast(err.message, 'error');
      }
      return refrescar();
    }

    const r = e.target.closest('[data-comanda-reimp]');
    if (r) {
      try {
        S.reimprimirComanda(r.dataset.comandaReimp);
        U.toast('La comanda vuelve a salir por la impresora de cocina.');
      } catch (err) {
        U.toast(err.message, 'error');
      }
      return refrescar();
    }
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
      '💳 Por cobrar' + (n ? ' <b>' + n + '</b>' : '') + '</button>' +
      ($('#cajaDomiciliariosVista')
        ? '<button class="sub-tab' + (vista === 'domiciliarios' ? ' is-activo' : '') + '" data-caja-vista="domiciliarios">' +
          '🛵 Domiciliarios' + (deudaDomiciliarios() ? ' <b>' + U.money(deudaDomiciliarios()) + '</b>' : '') + '</button>'
        : '');

    const conComanda = !!(U.sucursal(sucursal()) || {}).comandaImpresa && !!$('#cajaCocinaVista');
    if (!conComanda && vista === 'cocina') vista = 'cobrar';
    if (conComanda) {
      const enCocina = enPreparacion().length;
      $('#cajaSub').innerHTML +=
        '<button class="sub-tab' + (vista === 'cocina' ? ' is-activo' : '') + '" data-caja-vista="cocina">' +
        '🍳 Cocina' + (enCocina ? ' <b>' + enCocina + '</b>' : '') +
        (estacionCaida() ? ' <b title="La estación de comandas no responde">⚠️</b>' : '') + '</button>';
    }

    $('#cajaVender').classList.toggle('oculto', vista !== 'vender');
    $('#cajaCobrarVista').classList.toggle('oculto', vista !== 'cobrar');
    if ($('#cajaDomiciliariosVista')) $('#cajaDomiciliariosVista').classList.toggle('oculto', vista !== 'domiciliarios');
    if ($('#cajaCocinaVista')) $('#cajaCocinaVista').classList.toggle('oculto', vista !== 'cocina');

    if (vista === 'cocina') {
      pintarCocina();
    } else if (vista === 'vender') {
      pintarCategorias();
      pintarProductos();
      pintarTicket();
    } else if (vista === 'domiciliarios') {
      pintarDomiciliarios();
    } else {
      pintarPorCobrar();
    }
  }

  return { iniciar: iniciar, refrescar: refrescar, imprimirRecibo: imprimirRecibo, tieneCajon: tieneCajon };
})();
