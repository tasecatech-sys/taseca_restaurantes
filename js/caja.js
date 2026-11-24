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

  /* Cuántas tarjetas de «Por cobrar» se pintan. Con «Todos» o un rango
     largo son cientos de pedidos, y pintarlos todos de una vez congelaba
     la pantalla. Se pintan de a TANDA_PAGOS y «Mostrar más» trae otra
     tanda; al cambiar un filtro se vuelve a la primera. */
  const TANDA_PAGOS = 50;
  let limitePagos = TANDA_PAGOS;
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
      if (vista === 'cuentas') cuentasCache = null; // al entrar, lo último
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

    /* El alto del ticket sigue a la pantalla: al bajar, al girar la
       tableta o al cambiar el tamaño de la ventana. */
    let pendienteAlto = false;
    const alMover = function () {
      if (pendienteAlto) return;
      pendienteAlto = true;
      window.requestAnimationFrame(function () {
        pendienteAlto = false;
        ajustarAltoTicket();
      });
    };
    window.addEventListener('scroll', alMover, { passive: true, capture: true });
    window.addEventListener('resize', alMover);

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
      if (campo) campo.addEventListener('change', function () {
        limitePagos = TANDA_PAGOS;
        pintarPorCobrar();
      });
    });

    $('#cajaPorCobrar').addEventListener('click', function (e) {
      if (e.target.closest('[data-caja-mas]')) {
        limitePagos += TANDA_PAGOS;
        return pintarPorCobrar();
      }

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
    /* (58) Si el producto deja elegir (la gaseosa del combo), primero se
       pregunta. El mismo combo con otra gaseosa es otra línea. */
    U.elegirCambios(p, function (r) {
      const clave = r ? r.clave : '';
      const i = ticket.findIndex((x) => x.refId === refId && (x.claveCambios || '') === clave);
      if (i >= 0) ticket[i].cantidad++;
      else
        ticket.push(U.conCambios({
          refId: p.id,
          nombre: p.nombre,
          precio: Number(p.precio),
          cantidad: 1,
          origen: 'carta',
          requierePreparacion: p.requierePreparacion !== false,
        }, r));
      lineaAVer = i >= 0 ? i : ticket.length - 1;
      pintarTicket();
    });
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

  /* La línea que se acaba de tocar desde la carta: tras repintar se deja a
     la vista dentro de la lista, aunque esté abajo. */
  let lineaAVer = null;

  /* El ticket nunca más alto que lo que queda de pantalla debajo de él.
     Antes de bajar arranca más abajo (encabezado y pestañas encima) y al
     bajar se pega bajo la cabecera: en los dos casos el botón Cobrar tiene
     que quedar dentro de la pantalla. En celular va abajo y no se toca. */
  function ajustarAltoTicket() {
    const caja = $('#cajaTicket');
    if (!caja) return;
    if (window.innerWidth <= 900 || !caja.offsetParent) {
      caja.style.maxHeight = '';
      return;
    }
    const arriba = Math.max(caja.getBoundingClientRect().top, 0);
    caja.style.maxHeight = Math.max(320, window.innerHeight - arriba - 12) + 'px';
  }

  function pintarTicket() {
    const caja = $('#cajaTicket');
    // Repintar no puede devolver la lista arriba del todo cada vez que se toca + o −
    const listaAntes = caja.querySelector('.caja-ticket__lista');
    const pieAntes = caja.querySelector('.caja-ticket__pie');
    const scrollLista = listaAntes ? listaAntes.scrollTop : 0;
    const scrollPie = pieAntes ? pieAntes.scrollTop : 0;
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
                '<span class="caja-ticket__nombre" title="' + U.esc(x.nombre) + '">' + U.esc(x.nombre) +
                (x.requierePreparacion ? '<i class="caja-ticket__marca">cocina</i>' : '') +
                // (58) La gaseosa elegida del combo
                (x.detalle ? '<small class="mini tenue" style="display:block;white-space:normal">' + U.esc(x.detalle) + '</small>' : '') +
                '</span>' +
                '<span class="caja-ticket__cant">' +
                '<button class="btn btn--fantasma btn--xs" data-caja-menos="' + i + '" aria-label="Uno menos">−</button>' +
                '<b>' + x.cantidad + '</b>' +
                '<button class="btn btn--fantasma btn--xs" data-caja-mas="' + i + '" aria-label="Uno más">+</button>' +
                '</span>' +
                '<b class="caja-ticket__importe">' + U.money(x.precio * x.cantidad) + '</b>' +
                '</div>'
            )
            .join('')
        : '<div class="caja-ticket__vacio">Toca un producto para empezar la venta.</div>') +
      '</div>' +

      '<div class="caja-ticket__pie">' +
      (aCocina
        ? '<p class="mini ambar" style="margin:0 0 8px">Lleva algo que hay que preparar: ' +
          'al cobrar se va a cocina y el cliente espera.</p>'
        : '') +

      (dividido && ticket.length
        /* Pago dividido (migración 56): las filas «método + cuánto»
           reemplazan al método único, su recargo y su cambio. */
        ? U.bloquePagoDividido('cmd')
        : '<label class="campo"><span>¿Con qué paga?</span><select class="select" id="cajaMetodo">' +
          metodos
            .map((m) => '<option value="' + U.esc(m.id) + '"' + (m.id === metodo ? ' selected' : '') + '>' +
              U.esc(nombreCorto(m)) + '</option>')
            .join('') +
          '</select></label>' +

          /* El recargo sólo se nombra si lo hay: una línea en cero no informa
             y hace dudar de si se está cobrando algo de más. Pero si lo hay,
             tiene que verse, porque es lo que la caja le va a decir al
             cliente que pague. */
          /* En el mostrador el cliente paga de frente y casi siempre con un
             billete. Sin ticket no hay nada que cobrar, así que tampoco hay
             cambio que calcular. */
          (ticket.length ? U.bloqueCambio(total(), 'cm', recibidoMostrador) : '')) +

      (ticket.length && metodos.length >= 2
        ? '<p class="pago-dividido__alternar mt-8"><button type="button" class="btn btn--fantasma btn--xs" id="cajaDividir">' +
          (dividido ? '↩ Un solo método' : '➗ Pagar con dos métodos') + '</button></p>'
        : '') +
      '</div>' +

      /* Total y Cobrar van abajo y siempre a la vista, aunque la lista o el
         detalle del pago tengan que desplazarse: en una pantalla de POS
         pequeña es lo que no puede esconderse. */
      '<div class="caja-ticket__accion">' +
      (!dividido && recargoTicket() > 0
        ? '<div class="caja-ticket__recargo"><span>Recargo · ' +
          U.esc(nombreCorto(metodosActivos().find((m) => m.id === metodo) || { id: metodo })) +
          '</span><b>' + U.money(recargoTicket()) + '</b></div>'
        : '') +
      '<div class="caja-ticket__total"><span>Total' +
      (n ? ' · ' + n + (n === 1 ? ' producto' : ' productos') : '') + '</span>' +
      (dividido && ticket.length
        ? '<b id="cajaTotalDiv">' + U.money(subtotalTicket()) + '</b>'
        : '<b>' + U.money(total()) + '</b>') +
      '</div>' +
      '<div class="caja-ticket__botones">' +
      (ticket.length
        ? '<button class="btn btn--fantasma" id="cajaVaciar" title="Quitar todo del ticket">Vaciar</button>'
        : '') +
      '<button class="btn caja-ticket__cobrar" id="cajaCobrar"' +
      (ticket.length ? '' : ' disabled') + '>💵 Cobrar</button>' +
      '</div>' +
      '</div>';

    ajustarAltoTicket();
    const lista = caja.querySelector('.caja-ticket__lista');
    const pie = caja.querySelector('.caja-ticket__pie');
    if (lista) lista.scrollTop = scrollLista;
    if (pie) pie.scrollTop = scrollPie;
    if (lista && lineaAVer != null) {
      const l = lista.querySelectorAll('.caja-ticket__linea')[lineaAVer];
      if (l) {
        if (l.offsetTop + l.offsetHeight > lista.scrollTop + lista.clientHeight)
          lista.scrollTop = l.offsetTop + l.offsetHeight - lista.clientHeight;
        else if (l.offsetTop < lista.scrollTop) lista.scrollTop = l.offsetTop;
      }
    }
    lineaAVer = null;

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

    leerCambio = ticket.length && !dividido
      ? U.montarCambio(caja, total(), 'cm', function (e) { recibidoMostrador = e.recibido; })
      : null;
    seguirMetodo();

    /* Se rearma con cada cambio del ticket: si la cuenta cambia, lo que
       se había repartido ya no vale y hay que volver a escribirlo. */
    leerDividido = dividido && ticket.length
      ? U.montarPagoDividido(caja, {
          pre: 'cmd',
          cuenta: subtotalTicket(),
          metodos: metodos.map((m) => ({ id: m.id, nombre: nombreCorto(m) })),
          empresaId: S.empresaActivaId ? S.empresaActivaId() : undefined,
          inicial: ['efectivo', (metodos.find((m) => m.id !== 'efectivo') || {}).id],
          enfocar: false,
          alCambiar: function (r) {
            const t = $('#cajaTotalDiv');
            if (t) t.textContent = U.money(r.error ? subtotalTicket() : r.total);
          },
        })
      : null;
    const botonDividir = $('#cajaDividir');
    if (botonDividir)
      botonDividir.addEventListener('click', function () {
        dividido = !dividido;
        pintarTicket();
      });

    U.unaVez($('#cajaCobrar'), '⏳ Cobrando…', cobrar);
  }

  /* =================================================================
     COBRAR
     ================================================================= */
  /* Lo devuelve montarCambio; se rellena en cada repintado del ticket. */
  let leerCambio = null;
  /* Pago dividido en el mostrador (migración 56): si está encendido y lo
     que devuelve montarPagoDividido. */
  let dividido = false;
  let leerDividido = null;

  function cobrar() {
    if (!ticket.length) return false;
    if (!A.exigir('pagos')) return false;

    /* Pago dividido: las partes tienen que cuadrar con la cuenta, y lo
       que se paga en billete tiene que alcanzar. */
    const partes = dividido && leerDividido ? leerDividido() : null;
    if (partes && partes.error) {
      U.toast(partes.error, 'error');
      return false;
    }
    if (partes && partes.efectivo > 0 && partes.cambio.falta > 0) {
      U.toast('No alcanza el efectivo: faltan ' + U.money(partes.cambio.falta) + '.', 'error');
      return false;
    }

    /* La venta de mostrador NACE cobrada: una vez registrada no hay dónde
       volver a cobrar. Si lo que hay en la mano no alcanza, se para aquí. */
    const efectivo = partes
      ? (partes.efectivo > 0 ? partes.cambio : null)
      : metodo === 'efectivo' && leerCambio ? leerCambio() : null;
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
          cambios: x.cambios, detalle: x.detalle,
        })),
        metodoPago: partes ? partes.partes[0].metodo : metodo,
        // Pago dividido (56): [{ metodo, base }]; sin esto, un solo método
        pagos: partes ? partes.partes.map((x) => ({ metodo: x.metodo, base: x.base })) : undefined,
        usuarioId: firma.usuarioId,
        usuarioNombre: firma.usuarioNombre,
      });
    } catch (err) {
      U.toast(err.message || 'No se pudo registrar la venta.', 'error');
      return false; // el botón vuelve: se puede reintentar con la misma clave
    }

    const aCocina = ticket.some((x) => x.requierePreparacion);
    if (partes ? partes.efectivo > 0 : metodo === 'efectivo') {
      siCajonImprimir([venta], { metodo: 'efectivo', recibido: efectivo && efectivo.recibido });
    }
    ticket = [];
    claveVenta = '';
    recibidoMostrador = null;   // lo del cliente anterior no es lo del siguiente
    dividido = false;           // la siguiente venta arranca con un solo método
    U.toast(
      'Venta ' + venta.codigo + ' cobrada · ' +
      (partes ? S.textoPartes(partes.partes) : U.money(venta.total)) +
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
    /* Sólo si TIENE comprobante, sin traerlo: con base de datos,
       getComprobante descarga la imagen entera, y hacerlo por cada tarjeta
       eran cientos de descargas seguidas con «Todos». La imagen se trae al
       tocar «Ver comprobante». */
    const comp = !!p.tieneComprobante;
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
      '</span><b>' + U.esc(p.pagos && p.pagos.length ? S.textoPartes(p.pagos) : S.nombreDeMetodo(p.metodoPago)) + '</b></div>' +
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

    const visiblesYa = lista.slice(0, limitePagos);
    const quedan = lista.length - visiblesYa.length;

    $('#cajaPorCobrar').innerHTML = lista.length
      ? barraLote(lista, modo) + visiblesYa.map(tarjetaPago).join('') +
        (quedan > 0
          ? '<div class="pagos-mas"><p class="mini tenue">Se ven ' + visiblesYa.length + ' de ' + lista.length +
            ' pedidos. Para ir directo a uno, acota las fechas o el tipo arriba.</p>' +
            '<button class="btn btn--fantasma" data-caja-mas>Mostrar ' + Math.min(TANDA_PAGOS, quedan) +
            ' más</button></div>'
          : '')
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

  const metodoEnEfectivo = (m) => (NASCAR.GRUPO_DE_METODO || {})[m] === 'efectivo' || m === 'efectivo';
  /* Lo que pasa por las manos del domiciliario: el pedido entero si es en
     efectivo, o sólo la parte en efectivo de un pago dividido (56). */
  const efectivoDe = (p) => S.partesDePago(p).filter((x) => metodoEnEfectivo(x.metodo)).reduce((s, x) => s + x.valor, 0);
  const esEfectivo = (p) => efectivoDe(p) > 0;
  const pagoAbierto = (p) => p.estadoPago !== 'confirmado' && p.estadoPago !== 'rechazado';
  const leDebe = (p) => p.estado === 'entregado' && esEfectivo(p) && pagoAbierto(p);

  function deudaDomiciliarios() {
    try {
      return domiciliosDeSede().filter((p) => p.domiciliarioId && leDebe(p)).reduce((s, p) => s + efectivoDe(p), 0);
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
      U.esc(S.ETIQUETA_ESTADO[p.estado] || p.estado) + ' · ' + U.esc(p.pagos && p.pagos.length ? S.textoPartes(p.pagos) : S.nombreDeMetodo(p.metodoPago)) + '</span>' +
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
      kpi('Cobrado hoy', U.money(filas.reduce((s, g) => s + g.cobradoHoy.reduce((t, p) => t + efectivoDe(p), 0), 0)), 'Efectivo ya recibido', 'verde');

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
      const cobrado = g.cobradoHoy.reduce((s, p) => s + efectivoDe(p), 0);
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

  /* El logo de los papeles que se lleva el cliente (ticket y comprobante):
     el de la sede si tiene uno propio, si no el de la empresa. En gris,
     porque la impresora térmica sólo pinta negro. Sin logo, nada. */
  function htmlLogo(sucursalId) {
    const suc = U.sucursal(sucursalId || sucursal()) || {};
    const logo = (suc.branding && suc.branding.logo) || ((S.getTheme && S.getTheme()) || {}).logo || '';
    if (!/^(data:image\/|https:\/\/)/.test(logo)) return '';
    return '<div style="text-align:center;margin:0 0 6px"><img src="' + U.esc(logo) + '" alt="" ' +
      'style="max-width:46mm;max-height:26mm;filter:grayscale(1)"></div>';
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
    /* Pago dividido (56): se imprime cada parte, y el cambio se calcula
       contra lo que se pagó en billete, no contra el total. */
    const partesUno = uno && uno.pagos && uno.pagos.length ? uno.pagos : null;
    const enEfectivo = partesUno
      ? partesUno.filter((x) => x.metodo === 'efectivo' || (NASCAR.GRUPO_DE_METODO || {})[x.metodo] === 'efectivo')
          .reduce((s, x) => s + (Number(x.valor) || 0), 0)
      : total;

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
      htmlLogo(suc.id) +
      '<h1>' + e(emp.nombre || '') + '</h1>' +
      '<div class="c">' + e(suc.nombre || '') + (suc.direccion ? '<br>' + e(suc.direccion) : '') +
      (nit ? '<br>NIT ' + e(nit) : '') + '</div>' +
      '<hr><div class="c"><b>COMPROBANTE DE PAGO</b><br>' + new Date().toLocaleString('es-CO') + '</div><hr>' +
      cuerpo +
      linea('TOTAL', U.money(total), 'tot') +
      (uno && partesUno
        ? linea('Pagó con', '') + partesUno.map((x) => linea('&nbsp; ' + e(metodoCorto(x.metodo)), U.money(x.valor))).join('')
        : uno ? linea('Pagó con', e(metodoCorto(extra.metodo || uno.metodoPago))) : '') +
      (extra.recibido ? linea('Recibido' + (partesUno ? ' en efectivo' : ''), U.money(extra.recibido)) : '') +
      (extra.recibido && extra.recibido > enEfectivo ? linea('Cambio', U.money(extra.recibido - enEfectivo)) : '') +
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
        /* Reimprimir la devuelve a la cola de la ESTACIÓN. Si no hay ninguna
           conectada (ni este equipo lo es), no saldrá nada: hay que decirlo. */
        const soyEstacion = !!estacionDeEsteEquipo();
        if (soyEstacion || (estadoEstacion && estadoEstacion.activa && !estacionCaida())) {
          U.toast('La comanda vuelve a salir por la impresora de cocina.');
        } else {
          U.toast('Quedó en cola, pero ningún equipo está imprimiendo comandas. Toca «🖨 Este equipo imprime las comandas» ' +
                  'en el computador de la impresora.', 'error');
        }
      } catch (err) {
        U.toast(err.message, 'error');
      }
      return refrescar();
    }
  }

  /* =================================================================
     🏦 CUENTAS SEMANALES (migración 61)

     Nequi, Daviplata, Bre-B… son de la EMPRESA (suman todas las sedes).
     El negocio escoge el día en que las desocupa: ese día arranca la
     semana y se anota la base. Debería haber = base + cobrado − gastos
     pagados desde la cuenta − retiros. Al cerrar se escribe lo que dice
     cada app y queda la diferencia. Todas las cuentas las hace la base.
     ================================================================= */
  const DIAS_SEMANA = ['', 'Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo'];
  let semanaCuentas = null; // null = la semana en curso
  let cuentasCache = null; // { semana, datos, ts }
  let cuentasConectado = false;

  function fechaCorta(iso) {
    const d = new Date(String(iso) + 'T12:00:00');
    return d.toLocaleDateString('es-CO', { weekday: 'short', day: 'numeric', month: 'short' });
  }

  function sumarDias(iso, n) {
    const d = new Date(String(iso) + 'T12:00:00');
    d.setDate(d.getDate() + n);
    return d.toISOString().slice(0, 10);
  }

  function datosCuentas(forzar) {
    const vigente = cuentasCache && cuentasCache.semana === semanaCuentas && Date.now() - cuentasCache.ts < 60000;
    if (!forzar && vigente) return cuentasCache.datos;
    const datos = S.getCuentasSemana(semanaCuentas);
    cuentasCache = { semana: semanaCuentas, datos: datos, ts: Date.now() };
    return datos;
  }

  function pintarCuentas(forzar) {
    const caja = $('#cajaCuentas');
    if (!caja) return;
    conectarCuentas();
    let d;
    try {
      d = datosCuentas(forzar);
    } catch (err) {
      caja.innerHTML = '<div class="vacio"><p class="mini rojo">' + U.esc(err.message) + '</p></div>';
      return;
    }

    if (d.soloNube) {
      caja.innerHTML = '<div class="vacio"><h3>🏦 Cuentas semanales</h3>' +
        '<p class="mini">Funcionan con la base de datos: en este modo local no hay ventas de todas las sedes que sumar.</p></div>';
      return;
    }

    if (!d.configurado) {
      caja.innerHTML =
        '<div class="caja-datos" style="max-width:520px;margin:16px auto">' +
        '<h3 style="margin-top:0">🏦 ¿Qué día empieza su semana de cuentas?</h3>' +
        '<p class="mini tenue">Es el día en que desocupan Nequi, Daviplata y las demás cuentas. Ese día se anota con ' +
        'cuánto quedó cada una (la base), y al final de la semana el sistema dice cuánto debería haber.</p>' +
        '<label class="campo"><span>Día</span><select class="select" id="cuDia">' +
        DIAS_SEMANA.slice(1).map((n, i) => '<option value="' + (i + 1) + '">' + n + '</option>').join('') +
        '</select></label>' +
        '<div class="fila fila--fin"><button class="btn btn--rojo" data-cu-dia-guardar>Guardar</button></div></div>';
      return;
    }

    const cerrada = !!d.cerrada;
    const puedeCerrar = !cerrada && d.semana_inicio <= d.hoy;
    const fila = (txt, valor, cls) =>
      '<div class="f' + (cls ? ' ' + cls : '') + '" style="display:flex;justify-content:space-between;gap:8px;margin:4px 0">' +
      '<span>' + txt + '</span><b>' + valor + '</b></div>';

    const tarjetas = (d.cuentas || []).map(function (c) {
      const retiros = (c.retiros_lista || []).map((r) =>
        '<div class="mini" style="display:flex;justify-content:space-between;gap:6px;' + (r.anulado ? 'opacity:.55;text-decoration:line-through' : '') + '">' +
        '<span>' + fechaCorta(r.fecha) + ' · ' + U.esc(r.motivo) + (r.por ? ' <i class="tenue">(' + U.esc(r.por) + ')</i>' : '') + '</span>' +
        '<span>' + U.money(r.monto) +
        (!r.anulado && !cerrada ? ' <button class="btn btn--fantasma btn--xs" data-cu-anular="' + r.id + '" title="Anular este retiro">✕</button>' : '') +
        '</span></div>').join('');
      const dif = Number(c.diferencia);
      return '<div class="caja-datos" style="margin-bottom:12px">' +
        '<div style="display:flex;justify-content:space-between;align-items:center;gap:8px">' +
        '<h3 style="margin:0">' + U.esc(c.nombre) + '</h3>' +
        (cerrada ? '' :
          '<span><button class="btn btn--fantasma btn--xs" data-cu-base="' + U.esc(c.metodo) + '">' +
          (c.base_registrada ? 'Corregir base' : 'Registrar base') + '</button> ' +
          '<button class="btn btn--fantasma btn--xs" data-cu-retiro="' + U.esc(c.metodo) + '">+ Retiro</button></span>') +
        '</div>' +
        fila('Base de la semana' + (c.base_registrada ? '' : ' <i class="ambar">(sin registrar)</i>'), U.money(c.base)) +
        fila('+ Cobrado (todas las sedes)', U.money(c.cobrado)) +
        fila('− Gastos pagados desde la cuenta', U.money(c.gastos)) +
        fila('− Retiros', U.money(c.retiros)) +
        retiros +
        '<hr style="border:0;border-top:1px dashed var(--borde,#444);margin:8px 0">' +
        fila('= Debería haber', U.money(c.esperado), 'tot') +
        (cerrada
          ? fila('Saldo real (lo que decía la app)', U.money(c.saldo_real)) +
            fila('Diferencia', (dif > 0 ? '+' : '') + U.money(dif), dif === 0 ? 'verde' : dif < 0 ? 'rojo' : 'ambar')
          : '') +
        (c.base_motivo ? '<p class="mini tenue" style="margin:4px 0 0">Base corregida: ' + U.esc(c.base_motivo) + '</p>' : '') +
        '</div>';
    }).join('');

    const historial = (d.semanas || []).map((s) =>
      '<button class="btn btn--fantasma btn--xs" data-cu-ir="' + s.semana_inicio + '" style="margin:0 6px 6px 0">' +
      fechaCorta(s.semana_inicio) + ' – ' + fechaCorta(s.semana_fin) +
      (s.cerrada ? ' · ' + (Number(s.diferencia) === 0 ? '✅ cuadró' : 'dif. ' + U.money(s.diferencia)) : ' · abierta') +
      '</button>').join('');

    caja.innerHTML =
      '<div style="display:flex;justify-content:space-between;align-items:center;gap:8px;flex-wrap:wrap;margin:14px 0">' +
      '<div><h3 style="margin:0">🏦 Semana del ' + fechaCorta(d.semana_inicio) + ' al ' + fechaCorta(d.semana_fin) + '</h3>' +
      '<span class="mini tenue">Empieza los ' + DIAS_SEMANA[d.dia].toLowerCase() + ' · suma todas las sedes · ' +
      (cerrada ? '<b class="verde">✅ cerrada</b>' : d.es_actual ? 'en curso' : 'abierta') +
      ' · <a href="#" data-cu-cambiar-dia>cambiar el día</a></span></div>' +
      '<div><button class="btn btn--fantasma btn--xs" data-cu-ir="' + sumarDias(d.semana_inicio, -7) + '">◀ Anterior</button> ' +
      (d.es_actual ? '' : '<button class="btn btn--fantasma btn--xs" data-cu-ir="">Semana actual</button> ') +
      '<button class="btn btn--fantasma btn--xs" data-cu-recargar title="Volver a calcular">↻</button></div></div>' +
      (tarjetas || '<div class="vacio"><p class="mini">No hay cuentas digitales activas (Nequi, Daviplata…).</p></div>') +
      (puedeCerrar
        ? '<div class="fila fila--fin"><button class="btn btn--rojo" data-cu-cerrar>Cerrar la semana</button></div>'
        : '') +
      (historial ? '<h4 style="margin:18px 0 8px">Semanas anteriores</h4><div>' + historial + '</div>' : '');
  }

  function conectarCuentas() {
    if (cuentasConectado || !$('#cajaCuentas')) return;
    cuentasConectado = true;
    $('#cajaCuentas').addEventListener('click', function (e) {
      if (e.target.closest('[data-cu-dia-guardar]')) return guardarDiaCuentas(U.$('#cuDia').value);
      const ir = e.target.closest('[data-cu-ir]');
      if (ir) {
        semanaCuentas = ir.dataset.cuIr || null;
        return pintarCuentas(true);
      }
      if (e.target.closest('[data-cu-recargar]')) return pintarCuentas(true);
      if (e.target.closest('[data-cu-cambiar-dia]')) {
        e.preventDefault();
        return cambiarDiaCuentas();
      }
      const base = e.target.closest('[data-cu-base]');
      if (base) return registrarBaseCuenta(base.dataset.cuBase);
      const ret = e.target.closest('[data-cu-retiro]');
      if (ret) return registrarRetiroCuenta(ret.dataset.cuRetiro);
      const an = e.target.closest('[data-cu-anular]');
      if (an) return anularRetiroCuenta(an.dataset.cuAnular);
      if (e.target.closest('[data-cu-cerrar]')) return cerrarSemanaCuentas();
    });
  }

  function cuentaDe(metodo) {
    return ((cuentasCache && cuentasCache.datos && cuentasCache.datos.cuentas) || []).find((c) => c.metodo === metodo) || {};
  }

  function guardarDiaCuentas(dia) {
    try {
      S.configurarSemanaCuentas(Number(dia));
    } catch (err) {
      return U.toast(err.message, 'error');
    }
    U.toast('Listo: la semana de cuentas empieza los ' + DIAS_SEMANA[Number(dia)].toLowerCase() + '.');
    semanaCuentas = null;
    pintarCuentas(true);
  }

  function cambiarDiaCuentas() {
    const actual = cuentasCache && cuentasCache.datos ? cuentasCache.datos.dia : 1;
    const m = U.modal({
      titulo: 'Día en que empieza la semana',
      ancho: 420,
      contenido:
        '<p class="mini tenue" style="margin-top:0">Las semanas ya cerradas no cambian; desde ahora cada semana empieza el día que escojas.</p>' +
        '<label class="campo"><span>Día</span><select class="select" id="cuDiaNuevo">' +
        DIAS_SEMANA.slice(1).map((n, i) => '<option value="' + (i + 1) + '"' + (i + 1 === actual ? ' selected' : '') + '>' + n + '</option>').join('') +
        '</select></label>' +
        '<div class="fila fila--fin"><button class="btn btn--fantasma" data-no>Cancelar</button> <button class="btn btn--rojo" data-si>Guardar</button></div>',
    });
    U.$('[data-no]', m.raiz).onclick = m.cerrar;
    U.unaVez(U.$('[data-si]', m.raiz), '⏳ Guardando…', function () {
      const dia = U.$('#cuDiaNuevo', m.raiz).value;
      m.cerrar();
      guardarDiaCuentas(dia);
    });
  }

  function registrarBaseCuenta(metodo) {
    const c = cuentaDe(metodo);
    const m = U.modal({
      titulo: 'Base de ' + (c.nombre || metodo),
      ancho: 420,
      contenido:
        '<p class="mini tenue" style="margin-top:0">Con cuánto quedó la cuenta al desocuparla, el día que empezó la semana. Si quedó vacía, 0.</p>' +
        '<label class="campo"><span>Base</span><input class="input" type="number" min="0" step="1" id="cuBase" value="' +
        (c.base_registrada ? Number(c.base) : '') + '" placeholder="0"></label>' +
        (c.base_registrada
          ? '<label class="campo"><span>Motivo de la corrección <i class="req">*</i></span><input class="input" id="cuMotivo" maxlength="200"></label>'
          : '') +
        '<div class="fila fila--fin"><button class="btn btn--fantasma" data-no>Cancelar</button> <button class="btn btn--rojo" data-si>Guardar</button></div>',
    });
    U.$('[data-no]', m.raiz).onclick = m.cerrar;
    U.unaVez(U.$('[data-si]', m.raiz), '⏳ Guardando…', function () {
      try {
        S.registrarBaseCuenta({
          metodo: metodo,
          monto: Number(U.$('#cuBase', m.raiz).value || 0),
          motivo: U.$('#cuMotivo', m.raiz) ? U.$('#cuMotivo', m.raiz).value : null,
          semana: cuentasCache && cuentasCache.datos ? cuentasCache.datos.semana_inicio : null,
        });
      } catch (err) {
        U.toast(err.message, 'error');
        return false;
      }
      m.cerrar();
      U.toast('Base registrada.');
      pintarCuentas(true);
    });
  }

  function registrarRetiroCuenta(metodo) {
    const c = cuentaDe(metodo);
    const d = (cuentasCache && cuentasCache.datos) || {};
    const max = d.hoy < d.semana_fin ? d.hoy : d.semana_fin;
    const m = U.modal({
      titulo: 'Retiro de ' + (c.nombre || metodo),
      ancho: 420,
      contenido:
        '<p class="mini tenue" style="margin-top:0">Plata que se sacó de la cuenta a mitad de semana. Se resta de lo que debería haber.</p>' +
        '<label class="campo"><span>Valor <i class="req">*</i></span><input class="input" type="number" min="1" step="1" id="cuMonto"></label>' +
        '<label class="campo"><span>¿Para qué? <i class="req">*</i></span><input class="input" id="cuMotivoR" maxlength="200" placeholder="Ej. Pago al proveedor de pollo"></label>' +
        '<label class="campo"><span>Fecha</span><input class="input" type="date" id="cuFecha" value="' + max + '" min="' + d.semana_inicio + '" max="' + max + '"></label>' +
        '<div class="fila fila--fin"><button class="btn btn--fantasma" data-no>Cancelar</button> <button class="btn btn--rojo" data-si>Registrar retiro</button></div>',
    });
    U.$('[data-no]', m.raiz).onclick = m.cerrar;
    U.unaVez(U.$('[data-si]', m.raiz), '⏳ Guardando…', function () {
      try {
        S.registrarRetiroCuenta({
          metodo: metodo,
          monto: Number(U.$('#cuMonto', m.raiz).value || 0),
          motivo: U.$('#cuMotivoR', m.raiz).value,
          fecha: U.$('#cuFecha', m.raiz).value,
        });
      } catch (err) {
        U.toast(err.message, 'error');
        return false;
      }
      m.cerrar();
      U.toast('Retiro registrado.');
      pintarCuentas(true);
    });
  }

  function anularRetiroCuenta(id) {
    const m = U.modal({
      titulo: 'Anular retiro',
      ancho: 420,
      contenido:
        '<label class="campo"><span>Motivo <i class="req">*</i></span><input class="input" id="cuMotivoA" maxlength="200" placeholder="Ej. Se registró dos veces"></label>' +
        '<div class="fila fila--fin"><button class="btn btn--fantasma" data-no>Cancelar</button> <button class="btn btn--rojo" data-si>Anular</button></div>',
    });
    U.$('[data-no]', m.raiz).onclick = m.cerrar;
    U.unaVez(U.$('[data-si]', m.raiz), '⏳ Anulando…', function () {
      try {
        S.anularRetiroCuenta(id, U.$('#cuMotivoA', m.raiz).value);
      } catch (err) {
        U.toast(err.message, 'error');
        return false;
      }
      m.cerrar();
      U.toast('Retiro anulado.');
      pintarCuentas(true);
    });
  }

  function cerrarSemanaCuentas() {
    let d;
    try {
      d = datosCuentas(true); // con lo último antes de cerrar
    } catch (err) {
      return U.toast(err.message, 'error');
    }
    const cuentas = d.cuentas || [];
    const m = U.modal({
      titulo: 'Cerrar la semana del ' + fechaCorta(d.semana_inicio) + ' al ' + fechaCorta(d.semana_fin),
      ancho: 520,
      contenido:
        '<p class="mini tenue" style="margin-top:0">Escribe lo que dice cada app ahora (0 si está vacía). ' +
        'Al cerrar queda la foto de la semana y ya no se mueve.</p>' +
        cuentas.map((c) =>
          '<div class="caja-datos" style="margin-bottom:8px">' +
          '<div style="display:flex;justify-content:space-between;gap:8px"><b>' + U.esc(c.nombre) + '</b>' +
          '<span class="mini">Debería haber <b>' + U.money(c.esperado) + '</b></span></div>' +
          '<label class="campo" style="margin:6px 0 0"><span>Saldo real</span>' +
          '<input class="input" type="number" min="0" step="1" data-cu-saldo="' + U.esc(c.metodo) + '" data-esperado="' + Number(c.esperado) + '"></label>' +
          '<span class="mini" data-cu-dif="' + U.esc(c.metodo) + '"></span></div>').join('') +
        '<label class="campo"><span>Observación (opcional)</span><input class="input" id="cuObs" maxlength="300"></label>' +
        '<div class="fila fila--fin"><button class="btn btn--fantasma" data-no>Cancelar</button> <button class="btn btn--rojo" data-si>Cerrar la semana</button></div>',
    });
    // La diferencia se ve mientras se escribe
    m.raiz.addEventListener('input', function (e) {
      const inp = e.target.closest('[data-cu-saldo]');
      if (!inp) return;
      const out = U.$('[data-cu-dif="' + inp.dataset.cuSaldo + '"]', m.raiz);
      if (inp.value === '') return (out.textContent = '');
      const dif = Number(inp.value) - Number(inp.dataset.esperado);
      out.textContent = dif === 0 ? '✅ Cuadra' : (dif < 0 ? 'Faltan ' : 'Sobran ') + U.money(Math.abs(dif));
      out.className = 'mini ' + (dif === 0 ? 'verde' : dif < 0 ? 'rojo' : 'ambar');
    });
    U.$('[data-no]', m.raiz).onclick = m.cerrar;
    U.unaVez(U.$('[data-si]', m.raiz), '⏳ Cerrando…', function () {
      const saldos = U.$$('[data-cu-saldo]', m.raiz).map((i) => ({ metodo: i.dataset.cuSaldo, saldo_real: i.value === '' ? null : Number(i.value) }));
      if (saldos.some((s) => s.saldo_real === null)) {
        U.toast('Escribe el saldo real de cada cuenta (0 si está vacía).', 'error');
        return false;
      }
      try {
        S.cerrarSemanaCuentas({ semana: d.semana_inicio, saldos: saldos, observacion: U.$('#cuObs', m.raiz).value });
      } catch (err) {
        U.toast(err.message, 'error');
        return false;
      }
      m.cerrar();
      U.toast('Semana cerrada.');
      pintarCuentas(true);
    });
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

    // (61) Cuentas semanales: quien ve la caja (informe) o registra su base
    const conCuentas = !!$('#cajaCuentasVista') && (A.puede('informe') || A.puede('base_caja'));
    if (!conCuentas && vista === 'cuentas') vista = 'cobrar';
    if (conCuentas)
      $('#cajaSub').innerHTML +=
        '<button class="sub-tab' + (vista === 'cuentas' ? ' is-activo' : '') + '" data-caja-vista="cuentas">🏦 Cuentas</button>';

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
    if ($('#cajaCuentasVista')) $('#cajaCuentasVista').classList.toggle('oculto', vista !== 'cuentas');

    if (vista === 'cuentas') {
      pintarCuentas(false);
    } else if (vista === 'cocina') {
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

  return { iniciar: iniciar, refrescar: refrescar, imprimirRecibo: imprimirRecibo, tieneCajon: tieneCajon, htmlLogo: htmlLogo, imprimirHTML: imprimirHTML };
})();
