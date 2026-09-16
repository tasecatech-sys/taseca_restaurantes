/* ==========================================================================
   NASCAR · informe.js
   📊 Cruce de información — el informe de caja de la jornada.

   QUÉ ES: una capa de consulta. Lee ventas, gastos y cierres y los pone
   en la misma página. No crea pedidos, no toca gastos, no modifica
   cierres. Lo único que se registra desde aquí es la BASE DE CAJA, que
   no existía en ninguna otra parte.

   QUÉ NO ES: el cruce del Cierre. Son dos preguntas distintas y conviene
   no mezclarlas:

     🔄 Cierres  ->  ¿qué pasó con el INVENTARIO físico?  (IN + EN − Z)
     📊 Cruce    ->  ¿qué pasó con el DINERO de la jornada?

   Por eso este módulo no calcula saldos de productos y aquél no calcula
   plata. Cuando hay cierre de la misma jornada se ofrece el enlace, y
   nada más.
   ========================================================================== */

window.NASCAR = window.NASCAR || {};

NASCAR.Informe = (function () {
  'use strict';

  const S = NASCAR.Store;
  const U = NASCAR.UI;
  const A = NASCAR.Auth;

  let ctx = null;
  let informe = null;

  const $ = (sel) => ctx.raiz.querySelector(sel);

  /* =================================================================
     ARRANQUE
     ================================================================= */
  function iniciar(opciones) {
    ctx = {
      raiz: opciones.raiz,
      sucursalGlobal: opciones.sucursalGlobal || (() => ''),
      irATab: opciones.irATab || null,
    };
    if (!ctx.raiz) return;

    $('#inFecha').value = S.hoyOperativo();
    $('#inFecha').max = S.hoyOperativo();

    llenarSucursales();

    $('#inFecha').addEventListener('change', pintar);
    $('#inSucursal').addEventListener('change', pintar);
    $('#btnInformeCSV').addEventListener('click', exportarCSV);
    $('#btnInformeImprimir').addEventListener('click', () => window.print());

    // La base y el enlace al cierre se pintan cada vez: delegación.
    ctx.raiz.addEventListener('click', function (e) {
      if (e.target.closest('[data-registrar-base]')) return editarBase(false);
      if (e.target.closest('[data-corregir-base]')) return editarBase(true);
      if (e.target.closest('[data-ver-historial]')) return verHistorial();
      const c = e.target.closest('[data-ir-cierre]');
      if (c && ctx.irATab) ctx.irATab('inventario');
    });

    pintar();
  }

  function llenarSucursales() {
    const sel = $('#inSucursal');
    /* El cruce es de la unidad del contexto (la asignada al usuario o la
       activa del panel): no se mezclan unidades ni se elige otra aquí. */
    const propia = A.sucursalDelUsuario() || Number(ctx.sucursalGlobal()) || S.unidadActivaId();

    sel.innerHTML =
      (propia ? '' : '<option value="">Todas las sucursales</option>') +
      S.getSucursales()
        .map((s) => '<option value="' + s.id + '">' + U.esc(s.nombre) + '</option>')
        .join('');

    /* Quien está atado a una sucursal no elige otra: ve la suya, igual
       que en el resto del panel. */
    if (propia) {
      sel.value = String(propia);
      sel.disabled = true;
    } else {
      sel.value = String(ctx.sucursalGlobal() || '');
    }
  }

  function refrescar() {
    if (!ctx) return;
    // El selector global del panel manda mientras no se elija otra aquí.
    const sel = $('#inSucursal');
    const unidad = String(A.sucursalDelUsuario() || ctx.sucursalGlobal() || S.unidadActivaId() || '');
    if (sel.value !== unidad) llenarSucursales();
    pintar();
  }

  /* =================================================================
     PINTADO
     ================================================================= */
  function pintar() {
    if (!ctx) return;
    try {
      informe = S.informeCaja($('#inFecha').value, $('#inSucursal').value || null);
    } catch (err) {
      // Con la base de datos las jornadas antiguas se calculan allá: si falla, se dice
      $('#inBase').innerHTML =
        '<div class="caja" style="border-color:var(--rojo)"><b class="rojo">No se pudo calcular el cruce de caja</b>' +
        '<p class="mini tenue" style="margin:4px 0 0">' + U.esc(err.message || '') + '</p></div>';
      return;
    }

    $('#inEmpresa').innerHTML =
      'Empresa<br><b>' + U.esc(informe.empresaNombre) + '</b>';

    pintarBase();
    pintarKpis();
    pintarFormulas();
    pintarDesglose();
    pintarMetodos();
    pintarCierre();
  }

  /* ---- 💵 Base de caja ---- */
  function pintarBase() {
    const b = informe.base;
    const puedeRegistrar = A.puede('base_caja');

    // Sin sucursal concreta no se registra: la base es de un cajón, y
    // "todas las sucursales" son varios cajones. Se muestra la suma.
    if (!b.unica) {
      return ($('#inBase').innerHTML =
        '<div class="caja">' +
        '<div class="fila fila--entre">' +
        '<div><h3 style="margin:0">💵 Base de caja · ' + U.money(b.valor) + '</h3>' +
        '<p class="mini tenue" style="margin:6px 0 0">Suma de las bases registradas en todas las sucursales de la jornada. ' +
        'Elige una sucursal para registrar o corregir la suya.</p></div>' +
        '</div></div>');
    }

    if (!b.registro) {
      return ($('#inBase').innerHTML =
        '<div class="caja" style="border-color:var(--ambar)">' +
        '<div class="fila fila--entre" style="flex-wrap:wrap;gap:12px">' +
        '<div><h3 style="margin:0">💵 Base de caja sin registrar</h3>' +
        '<p class="mini tenue" style="margin:6px 0 0">Nadie ha anotado con cuánto se abrió el cajón en ' +
        U.esc(informe.sucursalNombre) + ' esta jornada. Sin la base, el efectivo esperado se calcula desde cero.</p></div>' +
        (puedeRegistrar
          ? '<button class="btn btn--rojo btn--sm" data-registrar-base>Registrar base</button>'
          : '<span class="mini tenue">Tu perfil no registra la base.</span>') +
        '</div></div>');
    }

    const r = b.registro;
    const historial = S.getHistorialBase(informe.sucursalId, informe.jornada);

    $('#inBase').innerHTML =
      '<div class="caja">' +
      '<div class="fila fila--entre" style="flex-wrap:wrap;gap:12px">' +
      '<div>' +
      '<h3 style="margin:0">💵 Base inicial de caja: ' + U.money(r.valor) + '</h3>' +
      '<p class="mini tenue" style="margin:6px 0 0">' +
      'Registró <b>' + U.esc(r.usuarioNombre) + '</b>' +
      (r.rol ? ' (' + U.esc(A.nombreRol(r.rol)) + ')' : '') +
      ' a las ' + U.esc(r.hora) + ' · ' + U.esc(r.sucursalNombre) +
      ' · jornada ' + U.esc(r.fecha) +
      '</p>' +
      (r.observaciones ? '<p class="mini" style="margin:6px 0 0">' + U.esc(r.observaciones) + '</p>' : '') +
      (r.corrigeA
        ? '<p class="mini ambar" style="margin:6px 0 0">Corrige una base anterior: ' +
          U.esc(r.motivoCorreccion) + '</p>'
        : '') +
      '</div>' +
      '<div class="fila" style="gap:8px">' +
      (historial.length > 1
        ? '<button class="btn btn--fantasma btn--xs" data-ver-historial>Historial (' + historial.length + ')</button>'
        : '') +
      (puedeRegistrar
        ? '<button class="btn btn--fantasma btn--sm" data-corregir-base>Corregir</button>'
        : '') +
      '</div></div></div>';
  }

  /* ---- Tarjetas ---- */
  function pintarKpis() {
    const v = informe.ventas;
    const g = informe.gastos;

    $('#inKpis').innerHTML =
      kpi('💵 Base de caja', U.money(informe.base.valor), 'Con lo que se abrió') +
      kpi('🛒 Ventas', U.money(v.vendido.total), v.n + ' pedidos', 'verde') +
      kpi('💵 Efectivo', U.money(informe.efectivoEsperado), 'Lo que debería haber en el cajón') +
      kpi('🏦 Transferencias', U.money(v.cobrado.transferencia), 'Recibido, no está en el cajón') +
      kpi('💸 Gastos', U.money(g.bolsa.total), g.n + ' gastos', 'rojo') +
      kpi('🔄 RC', U.money(informe.rc), 'Reposición de caja', 'ambar');
  }

  /* ---- Las dos cuentas, con sus sumas a la vista ---- */
  function pintarFormulas() {
    const v = informe.ventas;
    const g = informe.gastos;

    const avisoCobro =
      v.porCobrar.total > 0
        ? '<p class="mini ambar" style="margin:10px 0 0">Hay ' + U.money(v.porCobrar.total) +
          ' en ' + v.nPorCobrar + ' pedido' + (v.nPorCobrar === 1 ? '' : 's') +
          ' sin pago confirmado. Ese dinero todavía no cuenta aquí.</p>'
        : '';

    const avisoAnuladas =
      v.nAnuladas > 0
        ? '<p class="mini tenue" style="margin:10px 0 0">' + v.nAnuladas + ' factura' +
          (v.nAnuladas === 1 ? '' : 's') + ' anulada' + (v.nAnuladas === 1 ? '' : 's') +
          ' por ' + U.money(v.anuladas.total) + '. No cuentan como venta efectiva ' +
          'ni mueven la caja; siguen en el historial.</p>'
        : '';

    $('#inFormulas').innerHTML =
      // --- Efectivo / RC
      '<div class="caja">' +
      '<h3>💵 Efectivo esperado · 🔄 RC</h3>' +
      '<p class="mini tenue">Sólo lo que mueve dinero físico.</p>' +
      '<div class="caja-datos mt-16">' +
      linea('Base de caja', informe.base.valor) +
      linea('+ Ventas en efectivo', v.cobrado.efectivo) +
      linea('− Gastos en efectivo', -g.bolsa.efectivo) +
      lineaTotal('= Efectivo esperado (RC)', informe.efectivoEsperado) +
      '</div>' +
      avisoCobro +
      avisoAnuladas +
      (informe.arqueo.hay
        ? '<div class="caja-datos mt-16">' +
          linea('Efectivo contado', informe.arqueo.contado) +
          lineaTotal('Diferencia', informe.arqueo.diferencia) +
          '</div>'
        : '<p class="mini tenue" style="margin:10px 0 0">Todavía no hay conteo físico del cajón: ' +
          'cuando exista, aquí saldrá <b>contado</b> contra <b>esperado</b> y su diferencia.</p>') +
      '</div>' +

      // --- Transferencias
      '<div class="caja">' +
      '<h3>🏦 Transferencias</h3>' +
      '<p class="mini tenue">Dinero electrónico. <b>No entra al cajón</b>, por eso va aparte y no suma al RC.</p>' +
      '<div class="caja-datos mt-16">' +
      linea('Recibido por transferencia', v.cobrado.transferencia) +
      linea('− Gastos por transferencia', -g.bolsa.transferencia) +
      lineaTotal('= Neto por transferencia', informe.transferenciasNetas) +
      '</div>' +
      (v.cobrado.otros || g.bolsa.otros
        ? '<div class="caja-datos mt-16">' +
          linea('Otros medios recibidos', v.cobrado.otros) +
          linea('− Otros medios gastados', -g.bolsa.otros) +
          lineaTotal('= Neto otros medios', informe.otrosNetos) +
          '</div>'
        : '') +
      '<p class="mini ambar" style="margin:12px 0 0">RC no son las ventas totales: ' +
      'las ventas de la jornada suman ' + U.money(v.vendido.total) +
      ', y el RC es ' + U.money(informe.rc) + '.</p>' +
      '</div>';
  }

  /* ---- Tabla de desglose ---- */
  function pintarDesglose() {
    const v = informe.ventas;
    const g = informe.gastos;

    // La base es efectivo por definición: es el dinero del cajón.
    const base = { efectivo: informe.base.valor, transferencia: 0, otros: 0, total: informe.base.valor };

    const resultado = {
      efectivo: base.efectivo + v.cobrado.efectivo - g.bolsa.efectivo,
      transferencia: v.cobrado.transferencia - g.bolsa.transferencia,
      otros: v.cobrado.otros - g.bolsa.otros,
    };
    resultado.total = resultado.efectivo + resultado.transferencia + resultado.otros;

    $('#inDesglose').innerHTML =
      fila('Base', base) +
      fila('Ventas cobradas', v.cobrado) +
      (v.porCobrar.total
        ? fila('Ventas por cobrar', v.porCobrar, 'tenue')
        : '') +
      /* Las anuladas se enseñan para que no parezcan perdidas, pero van
         fuera de la cuenta: no suman al resultado. */
      (v.anuladas.total
        ? fila('Facturas anuladas (no cuentan)', v.anuladas, 'tenue')
        : '') +
      fila('Gastos', negativa(g.bolsa)) +
      fila('Resultado', resultado, 'total');
  }

  function negativa(bolsa) {
    return {
      efectivo: -bolsa.efectivo,
      transferencia: -bolsa.transferencia,
      otros: -bolsa.otros,
      total: -bolsa.total,
    };
  }

  function fila(concepto, bolsa, clase) {
    const esTotal = clase === 'total';
    const abre = esTotal ? '<b>' : '';
    const cierra = esTotal ? '</b>' : '';
    return (
      '<tr' + (clase === 'tenue' ? ' class="tenue"' : '') +
      (esTotal ? ' style="border-top:2px solid var(--linea)"' : '') + '>' +
      '<td>' + abre + U.esc(concepto) + cierra + '</td>' +
      '<td class="derecha num">' + abre + U.money(bolsa.efectivo) + cierra + '</td>' +
      '<td class="derecha num">' + abre + U.money(bolsa.transferencia) + cierra + '</td>' +
      '<td class="derecha num">' + abre + U.money(bolsa.otros) + cierra + '</td>' +
      '<td class="derecha num">' + abre + U.money(bolsa.total) + cierra + '</td>' +
      '</tr>'
    );
  }

  /* ---- Detalle método por método, con los que hay configurados ---- */
  function pintarMetodos() {
    const metodos = S.getConfig().metodosPago || [];
    const v = informe.ventas;
    const g = informe.gastos;

    /* Se listan los métodos configurados, más cualquiera que aparezca en
       los datos aunque ya no esté activo: un pedido viejo puede haberse
       pagado con un método que después se desactivó, y ese dinero
       existió. */
    const ids = {};
    metodos.forEach((m) => (ids[m.id] = m.nombre));
    Object.keys(v.porMetodo).forEach((k) => (ids[k] = ids[k] || k));
    Object.keys(g.porMetodo).forEach((k) => (ids[k] = ids[k] || k));

    const grupos = {};
    (NASCAR.GRUPOS_PAGO || []).forEach((x) => (grupos[x.id] = x));

    const filas = Object.keys(ids)
      .map(function (id) {
        const ventas = v.porMetodo[id] || { n: 0, vendido: 0, cobrado: 0, pendiente: 0 };
        const gastos = g.porMetodo[id] || { n: 0, total: 0 };
        if (!ventas.n && !gastos.n) return '';
        const gr = grupos[S.grupoDeMetodo(id)] || { nombre: 'Otros', icono: '💳' };
        return (
          '<tr><td><b>' + U.esc(ids[id]) + '</b>' +
          '<div class="mini tenue">' + gr.icono + ' ' + U.esc(gr.nombre) + '</div></td>' +
          '<td class="derecha num">' + U.money(ventas.vendido) + '</td>' +
          '<td class="derecha num">' + U.money(ventas.cobrado) + '</td>' +
          '<td class="derecha num' + (ventas.pendiente ? ' ambar' : '') + '">' +
          U.money(ventas.pendiente) + '</td>' +
          '<td class="derecha num">' + U.money(gastos.total) + '</td></tr>'
        );
      })
      .join('');

    $('#inMetodos').innerHTML =
      '<h3>Por método de pago</h3>' +
      '<p class="mini tenue">Los métodos son los de ⚙️ Configuración → 💳 Métodos de pago. Este módulo no tiene los suyos.</p>' +
      '<div class="tabla-wrap"><table class="tabla"><thead><tr>' +
      '<th>Método</th><th class="derecha">Vendido</th><th class="derecha">Cobrado</th>' +
      '<th class="derecha">Por cobrar</th><th class="derecha">Gastos</th>' +
      '</tr></thead><tbody>' +
      (filas || '<tr><td colspan="5"><div class="vacio">Sin movimientos en esta jornada.</div></td></tr>') +
      '</tbody></table></div>';
  }

  /* ---- Acceso al cierre de inventario de la misma jornada ---- */
  function pintarCierre() {
    const nodo = $('#inCierre');

    // El enlace sólo tiene sentido si la empresa tiene el módulo Cierre
    // y quien mira puede consultarlo.
    if (!A.puede('cierres') || !informe.cierres.length) {
      return (nodo.innerHTML = '');
    }

    nodo.innerHTML =
      '<div class="caja">' +
      '<div class="fila fila--entre" style="flex-wrap:wrap;gap:12px">' +
      '<div><h3 style="margin:0">🔄 Cierre de inventario de esta jornada</h3>' +
      '<p class="mini tenue" style="margin:6px 0 0">' +
      informe.cierres.length + ' cierre' + (informe.cierres.length === 1 ? '' : 's') +
      ' registrado' + (informe.cierres.length === 1 ? '' : 's') +
      '. El cierre responde otra pregunta —qué pasó con el inventario físico—, ' +
      'y se consulta en su propia pestaña.</p></div>' +
      '<button class="btn btn--fantasma btn--sm" data-ir-cierre>Ver cierre de esta jornada</button>' +
      '</div></div>';
  }

  /* =================================================================
     REGISTRAR / CORREGIR LA BASE
     ================================================================= */
  function editarBase(corrigiendo) {
    if (!A.exigir('base_caja')) return;

    const sucId = informe.sucursalId;
    if (!sucId) return U.toast('Elige una sucursal para registrar su base.', 'error');

    const previa = informe.base.registro;

    const m = U.modal({
      titulo: corrigiendo ? 'Corregir la base de caja' : 'Registrar la base de caja',
      ancho: 480,
      contenido:
        '<p class="mini tenue mb-16">' +
        U.esc(informe.sucursalNombre) + ' · jornada ' + U.esc(informe.jornada) +
        '</p>' +
        (corrigiendo && previa
          ? '<div class="caja-datos mb-16"><div class="linea"><span>Base actual</span><b>' +
            U.money(previa.valor) + '</b></div></div>'
          : '') +
        '<label class="campo"><span>Valor de la base</span>' +
        '<input class="input" id="bValor" type="number" min="0" step="1000" ' +
        'value="' + (corrigiendo && previa ? previa.valor : '') + '" placeholder="100000"></label>' +
        '<label class="campo"><span>Hora</span>' +
        '<input class="input" id="bHora" type="time" value="' +
        new Date().toTimeString().slice(0, 5) + '"></label>' +
        (corrigiendo
          ? '<label class="campo"><span>Motivo de la corrección</span>' +
            '<input class="input" id="bMotivo" placeholder="Se contó mal al abrir"></label>'
          : '') +
        '<label class="campo"><span>Observaciones</span>' +
        '<textarea class="input" id="bObs" rows="2" placeholder="Opcional"></textarea></label>' +
        (corrigiendo
          ? '<p class="mini ambar">La base anterior no se borra: queda marcada como corregida, ' +
            'con su valor y quién la registró.</p>'
          : '') +
        '<div class="fila fila--fin mt-16">' +
        '<button class="btn btn--fantasma" data-cancelar>Cancelar</button>' +
        '<button class="btn btn--rojo" data-guardar>' +
        (corrigiendo ? 'Guardar corrección' : 'Registrar base') + '</button></div>',
    });

    U.$('[data-cancelar]', m.raiz).onclick = m.cerrar;
    U.$('[data-guardar]', m.raiz).onclick = function () {
      const valor = U.$('#bValor', m.raiz).value;
      const motivo = corrigiendo ? U.$('#bMotivo', m.raiz).value : '';

      try {
        S.registrarBase(
          {
            sucursalId: sucId,
            fecha: informe.jornada,
            hora: U.$('#bHora', m.raiz).value,
            valor: valor,
            observaciones: U.$('#bObs', m.raiz).value,
          },
          corrigiendo ? { corregir: true, motivo: motivo } : {}
        );
      } catch (err) {
        return U.toast(err.message, 'error');
      }

      m.cerrar();
      U.toast(corrigiendo ? 'Base corregida.' : 'Base de caja registrada.');
      pintar();
    };
  }

  function verHistorial() {
    const lista = S.getHistorialBase(informe.sucursalId, informe.jornada);

    U.modal({
      titulo: 'Historial de la base · ' + informe.jornada,
      ancho: 560,
      contenido:
        '<p class="mini tenue mb-16">Las bases corregidas se conservan tal como se registraron.</p>' +
        '<div class="tabla-wrap"><table class="tabla"><thead><tr>' +
        '<th>Hora</th><th class="derecha">Valor</th><th>Quién</th><th>Estado</th>' +
        '</tr></thead><tbody>' +
        lista
          .map(function (b) {
            const est = (NASCAR.ESTADOS_BASE || []).find((x) => x.id === b.estado) || {};
            return (
              '<tr><td>' + U.esc(b.hora) + '</td>' +
              '<td class="derecha num">' + U.money(b.valor) + '</td>' +
              '<td>' + U.esc(b.usuarioNombre) + '</td>' +
              '<td><span class="badge ' + (est.badge || 'badge--linea') + '">' +
              U.esc(est.nombre || b.estado) + '</span>' +
              (b.motivoCorreccion
                ? '<div class="mini tenue">' + U.esc(b.motivoCorreccion) + '</div>'
                : '') +
              '</td></tr>'
            );
          })
          .join('') +
        '</tbody></table></div>',
    });
  }

  /* =================================================================
     EXPORTAR
     ================================================================= */
  function exportarCSV() {
    const v = informe.ventas;
    const g = informe.gastos;
    const base = { efectivo: informe.base.valor, transferencia: 0, otros: 0, total: informe.base.valor };

    const filas = [
      ['Empresa', informe.empresaNombre],
      ['Sucursal', informe.sucursalNombre],
      ['Jornada', informe.jornada],
      [],
      ['Concepto', 'Efectivo', 'Transferencia', 'Otros', 'Total'],
      ['Base', base.efectivo, base.transferencia, base.otros, base.total],
      ['Ventas cobradas', v.cobrado.efectivo, v.cobrado.transferencia, v.cobrado.otros, v.cobrado.total],
      ['Ventas por cobrar', v.porCobrar.efectivo, v.porCobrar.transferencia, v.porCobrar.otros, v.porCobrar.total],
      ['Gastos', -g.bolsa.efectivo, -g.bolsa.transferencia, -g.bolsa.otros, -g.bolsa.total],
      ['Facturas anuladas (no cuentan)', v.anuladas.efectivo, v.anuladas.transferencia, v.anuladas.otros, v.anuladas.total],
      [],
      ['Ventas del día (facturado)', v.vendido.total],
      ['Efectivo esperado', informe.efectivoEsperado],
      ['RC (reposicion de caja)', informe.rc],
      ['Neto por transferencia', informe.transferenciasNetas],
    ];

    U.descargarArchivo(
      'cruce-' + informe.jornada + '.csv',
      filas.map(U.filaCSV).join('\n'),
      'text/csv;charset=utf-8'
    );
  }

  /* =================================================================
     HELPERS
     ================================================================= */
  function kpi(label, valor, extra, color) {
    return (
      '<div class="kpi' + (color ? ' kpi--' + color : '') + '">' +
      '<div class="kpi__label">' + U.esc(label) + '</div>' +
      '<div class="kpi__valor">' + valor + '</div>' +
      (extra ? '<div class="kpi__extra">' + U.esc(extra) + '</div>' : '') +
      '</div>'
    );
  }

  function linea(etiqueta, valor) {
    return (
      '<div class="linea"><span>' + U.esc(etiqueta) + '</span>' +
      '<b class="num">' + U.money(valor) + '</b></div>'
    );
  }

  function lineaTotal(etiqueta, valor) {
    return (
      '<div class="linea" style="border-top:2px solid var(--linea);padding-top:8px">' +
      '<span><b>' + U.esc(etiqueta) + '</b></span>' +
      '<b class="num" style="font-size:19px">' + U.money(valor) + '</b></div>'
    );
  }

  return {
    iniciar: iniciar,
    refrescar: refrescar,
  };
})();
