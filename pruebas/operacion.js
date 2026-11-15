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

    const bloques = [pruebasDobleEnvio, pruebasDatos, pruebasEstados, pruebasVariosClientes, pruebasDinero];
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
