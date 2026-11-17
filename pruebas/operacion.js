/* ==========================================================================
   TASECA · PRUEBAS DEL CAMINO DE UN PEDIDO
   --------------------------------------------------------------------------
   Desde que se crea hasta que se entrega, por los cuatro caminos, más lo
   que de verdad rompe un sistema de pedidos: el doble clic, los datos
   basura y varios clientes pidiendo a la vez.

   CÓMO LEERLO

     Cada prueba dice qué esperaba y qué pasó. Una prueba en rojo no es
     necesariamente un fallo del sistema: puede ser que el sistema haya
     cambiado y la prueba se quedara vieja. Pero hay que mirarla.

   LO QUE NO PRUEBA, Y HAY QUE SABERLO

     · La concurrencia de verdad. El navegador es de un solo hilo: aquí
       dos clientes «a la vez» son dos llamadas seguidas. Lo que sí
       comprueba es la defensa contra el doble envío, que es de donde
       salen las facturas repetidas.
     · La base de datos. Esto corre sobre el modo local. Las reglas que
       vive sólo en PostgreSQL -los permisos, los triggers, el candado de
       clave_envio- se prueban con los scripts database/*_pruebas_*.sql.
   ========================================================================== */
(function () {
  'use strict';

  const S = window.NASCAR && NASCAR.Store;
  const salida = document.getElementById('salida');
  const marcador = document.getElementById('marcador');

  let bien = 0,
    mal = 0,
    grupoActual = null;

  function grupo(titulo) {
    grupoActual = document.createElement('div');
    const h = document.createElement('h2');
    h.textContent = titulo;
    salida.appendChild(h);
    salida.appendChild(grupoActual);
  }

  /** Una comprobación. `detalle` explica qué se vio, pase o falle. */
  function probar(nombre, condicion, detalle) {
    const paso = !!condicion;
    paso ? bien++ : mal++;
    const d = document.createElement('div');
    d.className = 'p';
    d.innerHTML =
      '<b class="' + (paso ? 'ok' : 'no') + '">' + (paso ? '✓' : '✗') + '</b> ' +
      escapar(nombre) +
      (detalle ? '<span class="det">' + escapar(String(detalle)) + '</span>' : '');
    (grupoActual || salida).appendChild(d);
  }

  /** Espera que algo reviente. Devuelve el mensaje, o null si no reventó. */
  function revienta(fn) {
    try {
      fn();
      return null;
    } catch (e) {
      return e.message || String(e);
    }
  }

  function escapar(s) {
    return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  }

  /* ---------------------------------------------------------------- base */

  let UNIDAD = null;
  let PLATO = null;

  function unPedido(extra) {
    return Object.assign(
      {
        tipo: 'domicilio',
        sucursalId: UNIDAD,
        cliente: {
          nombre: 'Cliente de prueba',
          telefono: '3001234567',
          direccion: 'Calle 123 # 45-67, apto 801',
          zona: '',
          notas: '',
        },
        items: [{ refId: PLATO.id, nombre: PLATO.nombre, precio: PLATO.precio, cantidad: 1 }],
        metodoPago: 'efectivo',
        costoDomicilio: 0,
      },
      extra || {}
    );
  }

  /* ================================================================
     1 · EL DOBLE ENVÍO
     Lo que le pasó de verdad a un cliente: tres clics, tres pedidos.
     ================================================================ */
  function pruebasDobleEnvio() {
    grupo('1 · Doble envío');

    const clave = 'prueba-' + Date.now();
    const a = S.crearPedido(unPedido({ clave: clave }));
    const b = S.crearPedido(unPedido({ clave: clave }));
    const c = S.crearPedido(unPedido({ clave: clave }));
    probar(
      'Tres envíos con la misma clave crean UN pedido',
      a.id === b.id && b.id === c.id,
      'códigos: ' + [a.codigo, b.codigo, c.codigo].join(', ')
    );

    const d = S.crearPedido(unPedido({ clave: 'otra-' + Date.now() }));
    probar('Con otra clave sí entra un pedido nuevo', d.id !== a.id, 'código ' + d.codigo);

    /* El caso que originó todo: el pedido entra, falla el reporte del
       pago y el cliente reintenta. Si la clave se hubiera soltado al
       crear el pedido, el reintento crearía otro. */
    const clave2 = 'reintento-' + Date.now();
    const e1 = S.crearPedido(unPedido({ clave: clave2, metodoPago: 'nequi' }));
    const fallo = revienta(() => S.reportarPago(e1.id, 'referencia-que-falla'));
    const e2 = S.crearPedido(unPedido({ clave: clave2, metodoPago: 'nequi' }));
    probar(
      'Si falla el reporte del pago, reintentar NO crea otro pedido',
      e1.id === e2.id,
      fallo ? 'el reporte falló: ' + fallo : 'el reporte no falló en modo local; la clave aguanta igual'
    );

    probar(
      'Un pedido sin productos se rechaza',
      !!revienta(() => S.crearPedido(unPedido({ items: [] }))),
      'mensaje: ' + revienta(() => S.crearPedido(unPedido({ items: [] })))
    );
  }

  /* ================================================================
     2 · DATOS QUE NO DEBERÍAN PASAR
     ================================================================ */
  function pruebasDatos() {
    grupo('2 · Datos no válidos');

    const n = () => S.getPedidos({}).length;

    const antes = n();
    const conCantidad = (c) =>
      unPedido({ items: [{ refId: PLATO.id, nombre: PLATO.nombre, precio: PLATO.precio, cantidad: c }] });

    const cant0 = S.crearPedido(conCantidad(0));
    probar('Cantidad 0 sube a 1', cant0.items[0].cantidad === 1, 'quedó ' + cant0.items[0].cantidad);

    const neg = S.crearPedido(conCantidad(-3));
    probar(
      'Cantidad negativa no genera un total negativo',
      neg.items[0].cantidad === 1 && neg.total > 0,
      'cantidad ' + neg.items[0].cantidad + ', total ' + neg.total + ' (plato a ' + PLATO.precio + ')'
    );

    const mil = S.crearPedido(conCantidad(99999));
    probar(
      'Una cantidad absurda se topa en 99',
      mil.items[0].cantidad === 99,
      'quedó ' + mil.items[0].cantidad + ' — así la cocina no recibe una comanda imposible'
    );

    const medias = S.crearPedido(conCantidad(2.7));
    probar('Una cantidad con decimales se redondea', medias.items[0].cantidad === 3, 'quedó ' + medias.items[0].cantidad);

    const malPrecio = revienta(() =>
      S.crearPedido(unPedido({ items: [{ refId: PLATO.id, nombre: PLATO.nombre, precio: 'no-es-un-número', cantidad: 1 }] }))
    );
    probar(
      'Un precio que no es número se rechaza, no se cobra cero',
      !!malPrecio,
      malPrecio || 'entró igual: el total quedaría en NaN'
    );

    const guion = S.crearPedido(
      unPedido({
        cliente: Object.assign(unPedido().cliente, {
          nombre: '<img src=x onerror="window.__colado=1">',
          notas: "'; DROP TABLE pedidos; --",
        }),
      })
    );
    const pintado = document.createElement('div');
    pintado.innerHTML = NASCAR.UI.esc(guion.cliente.nombre);
    probar(
      'Un nombre con etiquetas HTML se guarda tal cual y se pinta escapado',
      !window.__colado && pintado.querySelector('img') === null,
      'se guardó: ' + guion.cliente.nombre.slice(0, 40)
    );

    /* Los topes son los de la base. Si el cliente no recorta, la base no
       «corta» el texto: rechaza el pedido entero. */
    const largo = 'a'.repeat(10000);
    const conNota = S.crearPedido(
      unPedido({ items: [{ refId: PLATO.id, nombre: PLATO.nombre, precio: PLATO.precio, cantidad: 1, notas: largo }] })
    );
    probar(
      'Una nota larga se recorta a 200 (lo que aguanta pedido_items.notas)',
      conNota.items[0].notas.length === 200,
      'quedó en ' + conNota.items[0].notas.length + ' caracteres'
    );

    const conDireccion = S.crearPedido(
      unPedido({ cliente: Object.assign(unPedido().cliente, { direccion: largo, notas: largo }) })
    );
    probar(
      'La dirección se recorta a 200 y las indicaciones a 300',
      conDireccion.cliente.direccion.length === 200 && conDireccion.cliente.notas.length === 300,
      'dirección ' + conDireccion.cliente.direccion.length + ', indicaciones ' + conDireccion.cliente.notas.length
    );

    probar('Ninguno de estos casos tumbó el almacén', n() > antes, n() - antes + ' pedidos creados en este bloque');
  }

  /* ================================================================
     3 · EL CAMINO DE LOS ESTADOS
     ================================================================ */
  function pruebasEstados() {
    grupo('3 · De nuevo a entregado');

    [
      ['domicilio', ['nuevo', 'preparacion', 'listo', 'camino', 'entregado']],
      ['mesa', ['nuevo', 'preparacion', 'listo', 'entregado']],
      ['recoger', ['nuevo', 'preparacion', 'listo', 'entregado']],
      ['mostrador', ['nuevo', 'preparacion', 'listo', 'entregado']],
    ].forEach(function (par) {
      const flujo = S.flujoEstados(par[0]);
      probar(
        'El flujo de «' + par[0] + '» es el que toca',
        flujo.join('>') === par[1].join('>'),
        flujo.join(' → ')
      );
    });

    /* Un pedido de verdad, recorrido entero. */
    const p = S.crearPedido(unPedido({ clave: 'estados-' + Date.now() }));
    const visto = [p.estado];
    for (let i = 0; i < 8; i++) {
      const sig = S.avanzarEstado(p.id);
      const ahora = S.getPedido(p.id).estado;
      if (visto[visto.length - 1] === ahora) break;
      visto.push(ahora);
    }
    probar(
      'Un domicilio recorre los cinco estados y se para',
      visto.join('>') === 'nuevo>preparacion>listo>camino>entregado',
      visto.join(' → ')
    );

    const yaFinal = S.getPedido(p.id).estado;
    S.avanzarEstado(p.id);
    probar(
      'Avanzar un pedido ya entregado no hace nada',
      S.getPedido(p.id).estado === yaFinal,
      'sigue en ' + S.getPedido(p.id).estado
    );

    /* Doble clic en «A preparación»: dos llamadas seguidas, las dos
       diciendo que venían de «nuevo», que es lo que el usuario veía. */
    const q = S.crearPedido(unPedido({ clave: 'doble-estado-' + Date.now() }));
    S.avanzarEstado(q.id, 'nuevo');
    const segundo = revienta(() => S.avanzarEstado(q.id, 'nuevo'));
    probar(
      'Doble clic en avanzar NO salta dos estados',
      S.getPedido(q.id).estado === 'preparacion',
      'quedó en ' + S.getPedido(q.id).estado + (segundo ? ' · el segundo clic avisó: ' + segundo : '')
    );
    probar('Y el segundo clic avisa de que alguien se adelantó', !!segundo, segundo || 'no avisó nada');

    /* Dos pantallas a la vez: la cocina y el mesero sobre el mismo pedido. */
    const dos = S.crearPedido(unPedido({ clave: 'dos-pantallas-' + Date.now() }));
    S.avanzarEstado(dos.id, 'nuevo'); // la cocina
    const tarde = revienta(() => S.avanzarEstado(dos.id, 'nuevo')); // el mesero, con la pantalla vieja
    probar(
      'Dos pantallas sobre el mismo pedido: sólo avanza una',
      S.getPedido(dos.id).estado === 'preparacion' && !!tarde,
      'quedó en ' + S.getPedido(dos.id).estado
    );

    const r = S.crearPedido(unPedido({ tipo: 'mesa', mesa: '5', clave: 'mesa-' + Date.now() }));
    const vistoMesa = [r.estado];
    for (let i = 0; i < 8; i++) {
      S.avanzarEstado(r.id);
      const ahora = S.getPedido(r.id).estado;
      if (vistoMesa[vistoMesa.length - 1] === ahora) break;
      vistoMesa.push(ahora);
    }
    probar(
      'Un pedido de mesa NO pasa por «en camino»',
      vistoMesa.indexOf('camino') < 0,
      vistoMesa.join(' → ')
    );

    const rec = S.crearPedido(unPedido({ tipo: 'recoger', clave: 'rec-' + Date.now() }));
    probar('Un pedido para recoger no cobra domicilio', rec.domicilio === 0, 'domicilio ' + rec.domicilio);
    probar('Un pedido para recoger no guarda mesa', !rec.mesa, 'mesa: ' + JSON.stringify(rec.mesa));
  }

  /* ================================================================
     4 · VARIOS CLIENTES A LA VEZ
     ================================================================ */
  function pruebasVariosClientes() {
    grupo('4 · Cuatro clientes seguidos');

    const pedidos = [];
    for (let i = 1; i <= 4; i++) {
      pedidos.push(
        S.crearPedido(
          unPedido({
            clave: 'cliente' + i + '-' + Date.now(),
            cliente: Object.assign(unPedido().cliente, { nombre: 'Cliente ' + i, telefono: '30000000' + i }),
          })
        )
      );
    }

    const codigos = pedidos.map((p) => p.codigo);
    probar(
      'Cuatro pedidos, cuatro códigos distintos',
      new Set(codigos).size === 4,
      codigos.join(', ')
    );

    const ids = pedidos.map((p) => p.id);
    probar('Cuatro identificadores distintos', new Set(ids).size === 4, '');

    /* Intercalado: avanzar uno no puede tocar a los otros. */
    S.avanzarEstado(pedidos[1].id);
    S.avanzarEstado(pedidos[1].id);
    const estados = pedidos.map((p) => S.getPedido(p.id).estado);
    probar(
      'Mover un pedido no mueve a los demás',
      estados[0] === 'nuevo' && estados[1] === 'listo' && estados[2] === 'nuevo' && estados[3] === 'nuevo',
      estados.join(', ')
    );

    const nombres = pedidos.map((p) => S.getPedido(p.id).cliente.nombre);
    probar(
      'Cada pedido conserva SU cliente',
      nombres.join('|') === 'Cliente 1|Cliente 2|Cliente 3|Cliente 4',
      nombres.join(', ')
    );
  }

  /* ================================================================
     5 · EL DINERO
     ================================================================ */
  function pruebasDinero() {
    grupo('5 · Pagos y recargos');

    const p = S.crearPedido(unPedido({ clave: 'pago-' + Date.now() }));
    probar('Todo pedido nace con el pago pendiente', p.estadoPago === 'pendiente', 'estadoPago: ' + p.estadoPago);

    probar(
      'El total es subtotal + domicilio + recargo',
      p.total === p.subtotal + p.domicilio + p.recargo,
      p.subtotal + ' + ' + p.domicilio + ' + ' + p.recargo + ' = ' + p.total
    );

    /* El recargo se congela: cambiarlo después no reescribe el pasado. */
    const cfg = S.getConfig();
    const metodos = (cfg.metodosPago || []).map((m) =>
      m.id === 'nequi' ? Object.assign({}, m, { recargo: 2000, recargoTipo: 'fijo' }) : m
    );
    S.guardarConfig({ metodosPago: metodos });

    const conRecargo = S.crearPedido(unPedido({ clave: 'recargo-' + Date.now(), metodoPago: 'nequi' }));
    probar(
      'Un método con recargo lo suma al total',
      conRecargo.recargo === 2000,
      'recargo ' + conRecargo.recargo + ', total ' + conRecargo.total
    );

    const metodos0 = (S.getConfig().metodosPago || []).map((m) =>
      m.id === 'nequi' ? Object.assign({}, m, { recargo: 0 }) : m
    );
    S.guardarConfig({ metodosPago: metodos0 });
    probar(
      'Bajar el recargo NO cambia los pedidos de antes',
      S.getPedido(conRecargo.id).recargo === 2000,
      'el pedido sigue con ' + S.getPedido(conRecargo.id).recargo
    );

    const sinRecargo = S.crearPedido(unPedido({ clave: 'sin-recargo-' + Date.now(), metodoPago: 'nequi' }));
    probar(
      'Con el recargo en 0 el pedido entra y no suma nada',
      sinRecargo.recargo === 0 && Number.isFinite(sinRecargo.total),
      'recargo ' + sinRecargo.recargo + ', total ' + sinRecargo.total
    );
  }

  /* ================================================================
     ARRANQUE
     ================================================================ */
  /* =================================================================
     6 · EL CAMBIO EN EFECTIVO

     Aritmética de caja: si esto se desvía, alguien devuelve de menos a
     un cliente o de más a costa del negocio. Son funciones puras, así
     que se prueban sin tocar la base.
     ================================================================= */
  function pruebasCambio() {
    grupo('6 · Cambio en efectivo');

    const U = window.NASCAR && NASCAR.UI;
    if (!U || !U.montosProbables) {
      probar('ui.js trae la calculadora de cambio', false, 'no se encontró U.montosProbables');
      return;
    }

    /* --- Leer lo que escribe la caja ------------------------------ */
    const lecturas = [
      ['25.000', 25000, 'con los puntos que pone el propio campo'],
      ['$ 25.000', 25000, 'si alguien pega el valor con el signo'],
      ['25000', 25000, 'tecleado a secas'],
      ['', null, 'vacío no es cero: es «no lo usé»'],
      ['abc', null, 'letras no son dinero'],
      ['  12.345  ', 12345, 'con espacios alrededor'],
    ];
    lecturas.forEach(function (c) {
      probar(
        'Lee «' + c[0] + '» como ' + (c[1] === null ? 'nada' : c[1]),
        U.montoEscrito(c[0]) === c[1],
        c[2] + ' — salió ' + U.montoEscrito(c[0])
      );
    });

    probar(
      'Un dedo apoyado en una tecla se topa',
      U.montoEscrito('999999999999') === 99999999,
      'quedó ' + U.montoEscrito('999999999999')
    );

    /* --- Con cuánto se suele pagar -------------------------------- */
    const atajos = [
      [23400, [25000, 30000, 40000]],
      [8500, [10000, 20000, 50000]],
      [99000, [100000]],
      [112000, [115000, 120000, 150000]],
    ];
    atajos.forEach(function (c) {
      const r = U.montosProbables(c[0]);
      probar(
        'Para ' + c[0] + ' ofrece ' + c[1].join(', '),
        r.join(',') === c[1].join(','),
        'ofreció ' + (r.join(', ') || 'nada')
      );
    });

    probar(
      'Nunca ofrece un atajo por DEBAJO del total',
      [1, 999, 7350, 50000, 100000, 237800].every(function (t) {
        return U.montosProbables(t).every((m) => m > t);
      }),
      'un atajo menor que la cuenta sería un cobro incompleto de un toque'
    );

    probar(
      'Los atajos van de menor a mayor y sin repetirse',
      [1500, 23400, 50000, 112000].every(function (t) {
        const r = U.montosProbables(t);
        return r.every((m, i) => i === 0 || m > r[i - 1]);
      }),
      'dos botones iguales serían dos botones desperdiciados'
    );

    /* --- La resta, que es el punto de todo esto ------------------- */
    const marco = document.createElement('div');
    marco.innerHTML = U.bloqueCambio(23400, 'tst');
    document.body.appendChild(marco);
    const leer = U.montarCambio(marco, 23400, 'tst');
    const campo = marco.querySelector('#tstRecibido');

    function conMonto(v) {
      campo.value = v;
      campo.dispatchEvent(new Event('input', { bubbles: true }));
      return leer();
    }

    let e = conMonto('50.000');
    probar('50.000 sobre 23.400 devuelve 26.600', e.cambio === 26600 && e.falta === 0, 'cambio ' + e.cambio);

    e = conMonto('23.400');
    probar('Pagar justo no devuelve nada', e.cambio === 0 && e.falta === 0, 'cambio ' + e.cambio);

    e = conMonto('20.000');
    probar(
      'Pagar de menos avisa de cuánto falta, y no inventa cambio',
      e.falta === 3400 && e.cambio === 0,
      'faltan ' + e.falta + ', cambio ' + e.cambio
    );

    e = conMonto('');
    probar(
      'Sin escribir nada no hay ni cambio ni falta',
      e.recibido === null && e.cambio === 0 && e.falta === 0,
      'la caja puede cobrar sin usar la calculadora'
    );

    marco.remove();
  }

  /* =================================================================
     7 · EL RECARGO SIGUE AL MÉTODO

     El recargo es el precio de pagar ASÍ -los $500 de Nequi-, no un cargo
     del pedido. Cuando caja cambia el método al confirmar, el recargo del
     método anterior deja de aplicar. Dejarlo quieto le cobraba de más al
     cliente en un sentido y se lo comía el negocio en el otro.

     Espejo de database/40_pruebas_recargo.sql, que prueba lo mismo contra
     la base de verdad.
     ================================================================= */
  function pruebasRecargoSigueAlMetodo() {
    grupo('7 · El recargo sigue al método');

    const cfg = S.getConfig();
    const metodos = (cfg.metodosPago || []).map(function (m) {
      if (m.id === 'nequi') return Object.assign({}, m, { recargo: 500, recargoTipo: 'fijo', activo: true });
      if (m.id === 'efectivo') return Object.assign({}, m, { recargo: 0, activo: true });
      return m;
    });
    S.guardarConfig({ metodosPago: metodos });

    if (S.recargoDeMetodo('nequi', 10000) !== 500) {
      probar('Se puede configurar un recargo de 500 en Nequi', false,
             'salió ' + S.recargoDeMetodo('nequi', 10000) + ' — sin esto el resto no prueba nada');
      return;
    }

    const quien = { usuarioId: null, usuarioNombre: 'Prueba' };

    /* --- A · entra con recargo y paga sin él: el total BAJA ------- */
    const a = S.crearPedido(unPedido({ clave: 'rec-a-' + Date.now(), metodoPago: 'nequi' }));
    probar('Un pedido por Nequi nace con los 500 dentro del total', a.recargo === 500,
           'subtotal ' + a.subtotal + ' + recargo ' + a.recargo + ' = ' + a.total);

    const a2 = S.confirmarPago(a.id, '', quien, 'efectivo');
    probar(
      'Pagado en efectivo, se le quitan los 500 de Nequi',
      a2.recargo === 0 && a2.total === a.total - 500,
      'total ' + a.total + ' → ' + a2.total
    );
    probar(
      'Y queda escrito en el historial por qué cambió el total',
      a2.historial.some((h) => h.texto.indexOf('Recargo del pago') === 0),
      'mover una factura en silencio es peor que no moverla'
    );

    /* --- B · entra sin recargo y paga con él: el total SUBE ------- */
    const b = S.crearPedido(unPedido({ clave: 'rec-b-' + Date.now(), metodoPago: 'efectivo' }));
    const b2 = S.confirmarPago(b.id, '', quien, 'nequi');
    probar(
      'Pagado por Nequi, se le ponen los 500 que el negocio si no pagaría',
      b2.recargo === 500 && b2.total === b.total + 500,
      'total ' + b.total + ' → ' + b2.total
    );

    /* --- C · sin cambio de método, nada se mueve ------------------ */
    const c = S.crearPedido(unPedido({ clave: 'rec-c-' + Date.now(), metodoPago: 'nequi' }));
    const c2 = S.confirmarPago(c.id, '', quien, 'nequi');
    probar(
      'Confirmar con el MISMO método no mueve la factura',
      c2.total === c.total && c2.recargo === c.recargo,
      'reconfirmar no puede cobrar de más — total ' + c2.total
    );

    const d = S.crearPedido(unPedido({ clave: 'rec-d-' + Date.now(), metodoPago: 'nequi' }));
    const d2 = S.confirmarPago(d.id, '', quien);
    probar(
      'Confirmar SIN decir método tampoco la mueve',
      d2.total === d.total && d2.recargo === d.recargo,
      'total ' + d2.total
    );

    /* --- E · el recargo no se recarga a sí mismo ------------------ */
    probar(
      'El recargo se calcula sobre subtotal + domicilio, no sobre el total',
      b2.total === b2.subtotal + b2.domicilio + b2.recargo,
      b2.subtotal + ' + ' + b2.domicilio + ' + ' + b2.recargo + ' = ' + b2.total
    );
  }

  function arrancar() {
    if (!S) {
      marcador.textContent = 'No se cargó NASCAR.Store. ¿Están los /js/*.js en su sitio?';
      marcador.className = 'mal';
      return;
    }

    /* Con precio > 0, o las pruebas del dinero no prueban nada: la
       primera vez esto eligió una cerveza a 0 y «cantidad negativa no da
       total negativo» pasaba porque 0 × -3 también es 0. */
    const unidades = S.getSucursales();
    const conCarta = unidades.filter((u) =>
      S.getCarta({ sucursalId: u.id }).some((p) => Number(p.precio) > 0)
    );
    if (!conCarta.length) {
      marcador.textContent = 'Ninguna unidad tiene carta: sin productos no hay nada que pedir.';
      marcador.className = 'mal';
      return;
    }
    UNIDAD = conCarta[0].id;
    PLATO = S.getCarta({ sucursalId: UNIDAD }).filter((p) => Number(p.precio) > 0)[0];

    const bloques = [pruebasDobleEnvio, pruebasDatos, pruebasEstados, pruebasVariosClientes,
                     pruebasDinero, pruebasCambio, pruebasRecargoSigueAlMetodo];
    bloques.forEach(function (fn) {
      try {
        fn();
      } catch (e) {
        probar('El bloque ' + fn.name + ' se cayó a medias', false, e.message + ' — ' + (e.stack || '').split('\n')[1]);
      }
    });

    marcador.className = mal === 0 ? 'bien' : 'mal';
    marcador.innerHTML =
      '<span class="ok n">' + bien + ' bien</span> · ' +
      '<span class="' + (mal ? 'no' : '') + ' n">' + mal + ' mal</span> · ' +
      '<span style="color:#98a2b3;font-weight:400">unidad ' + escapar(conCarta[0].nombre) +
      ', plato «' + escapar(PLATO.nombre) + '»</span>' +
      ' <button id="otraVez" style="margin-left:auto">Repetir</button>';

    document.getElementById('otraVez').onclick = function () {
      location.reload();
    };
  }

  document.addEventListener('DOMContentLoaded', arrancar);
  if (document.readyState !== 'loading') arrancar();
})();
