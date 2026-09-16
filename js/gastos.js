/* ==========================================================================
   NASCAR · gastos.js
   Módulo 💰 Gastos: las salidas de dinero del restaurante.

   Está a propósito SEPARADO de las ventas: no toca ningún pedido ni el
   cálculo de `ventas()`. Un gasto no es una venta en negativo. Cuando
   exista el módulo de Caja se cruzarán las dos cosas.

   Toda la persistencia pasa por NASCAR.Store; aquí no se toca localStorage.
   Cada acción comprueba permisos antes de ejecutarse: ocultar un botón
   no basta.
   ========================================================================== */

window.NASCAR = window.NASCAR || {};

NASCAR.Gastos = (function () {
  'use strict';

  const S = NASCAR.Store;
  const U = NASCAR.UI;
  const A = NASCAR.Auth;

  let ctx = null;

  function $(sel) {
    return ctx.raiz.querySelector(sel);
  }

  /* =================================================================
     HELPERS
     ================================================================= */
  function nombreCategoria(catId) {
    const c = S.categoriaGasto(catId);
    return c ? c.nombre : catId;
  }
  function iconoCategoria(catId) {
    const c = S.categoriaGasto(catId);
    return c ? c.icono : '📌';
  }

  function nombreMetodo(metodoId) {
    const m = (S.getConfig().metodosPago || []).find((x) => x.id === metodoId);
    return m ? m.nombre : metodoId;
  }

  function badgeEstado(estado) {
    const e = (NASCAR.ESTADOS_GASTO || []).find((x) => x.id === estado);
    return '<span class="badge ' + (e ? e.badge : 'badge--gris') + '">' +
      (e ? e.nombre : estado) + '</span>';
  }

  function fechaCorta(iso) {
    if (!iso) return '—';
    const [a, m, d] = String(iso).slice(0, 10).split('-');
    return d + '/' + m + '/' + a;
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

  function barra(nombre, valor, pct) {
    return (
      '<div class="barra-dato">' +
      '<span class="barra-dato__nombre">' + U.esc(nombre) + '</span>' +
      '<span class="barra-dato__valor">' + valor + '</span>' +
      '<div class="barra-dato__pista"><div class="barra-dato__relleno" style="width:' +
      Math.max(2, Math.min(100, pct)) + '%"></div></div>' +
      '</div>'
    );
  }

  /* Quién está haciendo la acción, para la auditoría. */
  function firma() {
    return A ? A.firma() : { usuarioId: null, usuarioNombre: 'Sistema', rol: null };
  }

  /* =================================================================
     ARRANQUE
     ================================================================= */
  function iniciar(opciones) {
    ctx = { raiz: opciones.raiz, sucursalGlobal: opciones.sucursalGlobal || (() => '') };
    if (!ctx.raiz) return;

    llenarSelectores();

    const hoy = S.hoy();
    $('#gaDesde').value = hoy.slice(0, 8) + '01'; // desde el 1 del mes
    $('#gaHasta').value = hoy;

    $('#btnNuevoGasto').addEventListener('click', () => editarGasto(null));
    $('#btnGastosCSV').addEventListener('click', exportarCSV);

    ['#gaDesde', '#gaHasta', '#gaCategoria', '#gaEstado', '#gaMetodo', '#gaBuscar'].forEach(
      function (sel) {
        const el = $(sel);
        el.addEventListener('change', refrescar);
        el.addEventListener('input', refrescar);
      }
    );

    $('#tablaGastos').addEventListener('click', function (e) {
      const ver = e.target.closest('[data-ver-gasto]');
      if (ver) return verGasto(ver.dataset.verGasto);

      const conf = e.target.closest('[data-confirmar-gasto]');
      if (conf) return confirmar(conf.dataset.confirmarGasto);

      const anu = e.target.closest('[data-anular-gasto]');
      if (anu) return anular(anu.dataset.anularGasto);

      const ed = e.target.closest('[data-editar-gasto]');
      if (ed) return editarGasto(ed.dataset.editarGasto);
    });

    refrescar();
  }

  function llenarSelectores() {
    $('#gaCategoria').innerHTML =
      '<option value="">Todas las categorías</option>' +
      S.getCategoriasGasto({ todas: true })
        .map((c) => '<option value="' + c.id + '">' + c.icono + ' ' + U.esc(c.nombre) + '</option>')
        .join('');

    $('#gaEstado').innerHTML =
      '<option value="">Todos los estados</option>' +
      (NASCAR.ESTADOS_GASTO || [])
        .map((e) => '<option value="' + e.id + '">' + U.esc(e.nombre) + '</option>')
        .join('');

    // Los métodos de pago salen de la configuración: no hay segundo catálogo
    $('#gaMetodo').innerHTML =
      '<option value="">Todos los métodos</option>' +
      (S.getConfig().metodosPago || [])
        .map((m) => '<option value="' + m.id + '">' + U.esc(m.nombre) + '</option>')
        .join('');
  }

  function filtroActual() {
    const f = {
      desde: $('#gaDesde').value || undefined,
      hasta: $('#gaHasta').value || undefined,
      categoria: $('#gaCategoria').value || undefined,
      estado: $('#gaEstado').value || undefined,
      metodoPago: $('#gaMetodo').value || undefined,
      texto: $('#gaBuscar').value || undefined,
    };
    const suc = ctx.sucursalGlobal();
    if (suc) f.sucursalId = suc;
    return f;
  }

  /* =================================================================
     PINTAR
     ================================================================= */
  function refrescar() {
    if (!ctx || !ctx.raiz) return;
    pintarResumen();
    pintarTabla();
  }

  function pintarResumen() {
    const f = filtroActual();
    const r = S.resumenGastos(f.desde, f.hasta, f.sucursalId);
    const puedeConfirmar = !A || A.puede('gastos_confirmar');

    $('#kpisGastos').innerHTML =
      kpi('Gastos de hoy', U.money(r.totalDia), r.nDia + ' registros', 'rojo') +
      kpi('Gastos del mes', U.money(r.totalMes), r.nMes + ' registros', 'ambar') +
      kpi('Total del rango', U.money(r.total), r.n + ' registros') +
      kpi(
        puedeConfirmar ? 'Por confirmar' : 'Registrados',
        U.money(r.montoPendiente),
        r.pendientes + ' gastos',
        r.pendientes ? 'azul' : 'verde'
      ) +
      kpi('Anulados', r.anulados || 0, U.money(r.montoAnulado || 0) + ' no cuentan');

    // Por categoría
    const cats = Object.keys(r.porCategoria);
    const maxCat = Math.max(1, ...cats.map((k) => r.porCategoria[k].total));
    $('#gastosPorCategoria').innerHTML = cats.length
      ? cats
          .sort((a, b) => r.porCategoria[b].total - r.porCategoria[a].total)
          .map((k) =>
            barra(
              iconoCategoria(k) + ' ' + nombreCategoria(k),
              U.money(r.porCategoria[k].total) + ' · ' + r.porCategoria[k].n,
              (r.porCategoria[k].total / maxCat) * 100
            )
          )
          .join('')
      : '<p class="tenue mini">Sin gastos en el rango.</p>';

    // Por sucursal
    const sucs = Object.keys(r.porSucursal);
    const maxSuc = Math.max(1, ...sucs.map((k) => r.porSucursal[k].total));
    $('#gastosPorSucursal').innerHTML =
      (sucs.length
        ? sucs
            .map((k) =>
              barra(
                U.sucursal(k).nombre,
                U.money(r.porSucursal[k].total) + ' · ' + r.porSucursal[k].n,
                (r.porSucursal[k].total / maxSuc) * 100
              )
            )
            .join('')
        : '<p class="tenue mini">Sin gastos en el rango.</p>') +
      (Object.keys(r.porMetodo).length
        ? '<div class="mt-16">' +
          Object.keys(r.porMetodo)
            .map((k) =>
              barra(
                nombreMetodo(k),
                U.money(r.porMetodo[k].total) + ' · ' + r.porMetodo[k].n,
                (r.porMetodo[k].total / Math.max(1, r.total)) * 100
              )
            )
            .join('') +
          '</div>'
        : '');
  }

  function pintarTabla() {
    const lista = S.getGastos(filtroActual());
    const puedeConfirmar = !A || A.puede('gastos_confirmar');
    const puedeAnular = !A || A.puede('gastos_anular');

    if (!lista.length) {
      $('#tablaGastos').innerHTML =
        '<tr><td colspan="9"><div class="vacio" style="border:0">' +
        '<div class="vacio__ico">💰</div><h3>Sin gastos en este rango</h3>' +
        '<p class="mini">Usa <b>+ Nuevo gasto</b> para registrar una salida de dinero.</p>' +
        '</div></td></tr>';
      return;
    }

    $('#tablaGastos').innerHTML = lista
      .map(function (g) {
        const anulado = g.estado === 'anulado';
        return (
          '<tr' + (anulado ? ' style="opacity:.55"' : '') + '>' +
          '<td><b>' + fechaCorta(g.fecha) + '</b>' +
          '<br><span class="mini tenue">' + U.esc(g.hora || '') + ' · ' +
          U.esc(g.consecutivo || '') + '</span></td>' +

          '<td><span class="badge badge--linea">' + iconoCategoria(g.categoria) + ' ' +
          U.esc(nombreCategoria(g.categoria)) + '</span></td>' +

          '<td><b' + (anulado ? ' style="text-decoration:line-through"' : '') + '>' +
          U.esc(g.concepto) + '</b>' +
          (g.tercero ? '<br><span class="mini tenue">' + U.esc(g.tercero) + '</span>' : '') + '</td>' +

          '<td class="mini">' + U.esc(U.sucursal(g.sucursalId).corto) + '</td>' +

          '<td class="derecha num" style="font-size:16px">' + U.money(g.valor) + '</td>' +

          '<td class="mini">' + U.esc(nombreMetodo(g.metodoPago)) + '</td>' +

          '<td class="mini">' + U.esc(g.usuarioNombre || '—') +
          (g.confirmadoPor
            ? '<br><span class="tenue">✓ ' + U.esc(g.confirmadoPor) + '</span>'
            : '') +
          (g.anuladoPor ? '<br><span class="rojo">✕ ' + U.esc(g.anuladoPor) + '</span>' : '') +
          '</td>' +

          '<td>' + badgeEstado(g.estado) + '</td>' +

          '<td class="nowrap">' +
          '<button class="btn btn--fantasma btn--xs" data-ver-gasto="' + g.id + '">Ver</button> ' +
          (g.estado === 'registrado'
            ? '<button class="btn btn--fantasma btn--xs" data-editar-gasto="' + g.id + '">Editar</button> ' +
              (puedeConfirmar
                ? '<button class="btn btn--xs" data-confirmar-gasto="' + g.id + '" ' +
                  'style="background:var(--verde);border-color:var(--verde);color:#04220f">✓</button> '
                : '') +
              (puedeAnular
                ? '<button class="btn btn--fantasma btn--xs" data-anular-gasto="' + g.id + '" ' +
                  'style="border-color:var(--rojo);color:var(--rojo-claro)">✕</button>'
                : '')
            : '') +
          '</td></tr>'
        );
      })
      .join('');
  }

  /* =================================================================
     NUEVO / EDITAR
     ================================================================= */
  function editarGasto(gastoId) {
    if (A && !A.exigir('gastos')) return;

    const g = gastoId
      ? S.getGasto(gastoId)
      : {
          id: '',
          fecha: S.hoyOperativo(),
          hora: new Date().toTimeString().slice(0, 5),
          sucursalId: (A && A.sucursalDelUsuario()) || ctx.sucursalGlobal() || U.sucursalPorDefectoId(),
          categoria: '',
          concepto: '',
          tercero: '',
          valor: '',
          metodoPago: '',
          observaciones: '',
        };

    if (gastoId && g.estado !== 'registrado')
      return U.toast('Un gasto ' + g.estado + ' ya no se puede editar.', 'error');

    const metodos = (S.getConfig().metodosPago || []).filter((m) => m.activo || m.id === g.metodoPago);
    // El gasto es de SU unidad: se registra en la del contexto, no en otra
    const sucursales = S.getSucursales({ todas: true }).filter((s) => Number(s.id) === Number(g.sucursalId));

    const m = U.modal({
      titulo: gastoId ? 'Editar gasto' : 'Registrar un gasto',
      ancho: 560,
      contenido:
        '<div class="rejilla-2">' +
        '<label class="campo"><span>Fecha del gasto <i class="req">*</i></span>' +
        '<input class="input" type="date" id="gFecha" value="' + g.fecha + '"></label>' +
        '<label class="campo"><span>Hora</span>' +
        '<input class="input" type="time" id="gHora" value="' + U.esc(g.hora || '') + '"></label>' +

        '<label class="campo"><span>Unidad</span>' +
        '<select class="select" id="gSucursal" disabled>' +
        sucursales
          .map(
            (s) => '<option value="' + s.id + '"' +
              (Number(s.id) === Number(g.sucursalId) ? ' selected' : '') + '>' +
              U.esc(s.nombre) + '</option>'
          )
          .join('') +
        '</select></label>' +

        '<label class="campo"><span>Categoría <i class="req">*</i></span>' +
        '<select class="select" id="gCategoria"><option value="">Elegir…</option>' +
        S.getCategoriasGasto()
          .map(
            (c) => '<option value="' + c.id + '"' + (c.id === g.categoria ? ' selected' : '') + '>' +
              c.icono + ' ' + U.esc(c.nombre) + '</option>'
          )
          .join('') +
        '</select></label>' +
        '</div>' +

        '<label class="campo"><span>Concepto <i class="req">*</i></span>' +
        '<input class="input" id="gConcepto" value="' + U.esc(g.concepto) + '" ' +
        'placeholder="Ej. Carne de res 20 kg"></label>' +

        '<div class="rejilla-2">' +
        '<label class="campo"><span>Proveedor o persona</span>' +
        '<input class="input" id="gTercero" value="' + U.esc(g.tercero) + '" ' +
        'placeholder="Ej. Carnes La 80 · o el nombre del empleado"></label>' +

        '<label class="campo"><span>Valor (COP) <i class="req">*</i></span>' +
        '<input class="input" type="number" min="0" step="1000" id="gValor" ' +
        'value="' + (g.valor || '') + '" placeholder="0"></label>' +
        '</div>' +

        '<label class="campo"><span>Método de pago <i class="req">*</i></span>' +
        '<select class="select" id="gMetodo"><option value="">Elegir…</option>' +
        metodos
          .map(
            (x) => '<option value="' + x.id + '"' + (x.id === g.metodoPago ? ' selected' : '') + '>' +
              U.esc(x.nombre) + '</option>'
          )
          .join('') +
        '</select>' +
        '<span class="mini tenue">Son los mismos métodos que administra ⚙️ Configuración.</span></label>' +

        '<label class="campo"><span>Observaciones</span>' +
        '<textarea class="textarea" id="gObs" placeholder="Número de factura, detalle…">' +
        U.esc(g.observaciones) + '</textarea></label>' +

        '<div class="fila fila--fin">' +
        '<button class="btn btn--fantasma" id="gNo">Cancelar</button>' +
        '<button class="btn btn--rojo" id="gSi">' +
        (gastoId ? 'Guardar cambios' : 'Registrar gasto') + '</button></div>',
    });

    U.$('#gNo', m.raiz).onclick = m.cerrar;
    U.$('#gSi', m.raiz).onclick = function () {
      const datos = {
        fecha: U.$('#gFecha', m.raiz).value,
        hora: U.$('#gHora', m.raiz).value,
        sucursalId: U.$('#gSucursal', m.raiz).value,
        categoria: U.$('#gCategoria', m.raiz).value,
        concepto: U.$('#gConcepto', m.raiz).value,
        tercero: U.$('#gTercero', m.raiz).value,
        valor: U.$('#gValor', m.raiz).value,
        metodoPago: U.$('#gMetodo', m.raiz).value,
        observaciones: U.$('#gObs', m.raiz).value,
      };

      try {
        if (gastoId) {
          S.actualizarGasto(gastoId, datos, firma());
        } else {
          const f = firma();
          S.crearGasto(
            Object.assign({}, datos, {
              usuarioId: f.usuarioId,
              usuarioNombre: f.usuarioNombre,
              rolUsuario: f.rol,
            })
          );
        }
      } catch (err) {
        return U.toast(err.message, 'error');
      }

      m.cerrar();
      U.toast(gastoId ? 'Gasto actualizado.' : 'Gasto registrado.');
      refrescar();
    };
  }

  /* =================================================================
     VER · CONFIRMAR · ANULAR
     ================================================================= */
  function verGasto(gastoId) {
    const g = S.getGasto(gastoId);
    if (!g) return;

    const m = U.modal({
      titulo: 'Gasto ' + (g.consecutivo || ''),
      ancho: 520,
      contenido: '<div id="vgBody"></div>',
    });

    function pintar() {
      const g = S.getGasto(gastoId);
      const puedeConfirmar = !A || A.puede('gastos_confirmar');
      const puedeAnular = !A || A.puede('gastos_anular');

      U.$('#vgBody', m.raiz).innerHTML =
        '<div class="fila fila--entre mb-16">' +
        '<span class="badge badge--linea">' + iconoCategoria(g.categoria) + ' ' +
        U.esc(nombreCategoria(g.categoria)) + '</span>' +
        badgeEstado(g.estado) +
        '</div>' +

        '<div class="ticket" style="padding:4px 0 12px">' +
        '<p class="tenue mini" style="margin:0">Valor del gasto</p>' +
        '<div class="ticket__codigo" style="font-size:30px">' + U.money(g.valor) + '</div>' +
        '</div>' +

        '<div class="caja-datos">' +
        '<div class="linea"><span class="tenue">Concepto</span><b class="derecha">' +
        U.esc(g.concepto) + '</b></div>' +
        (g.tercero
          ? '<div class="linea"><span class="tenue">Proveedor / persona</span><b>' +
            U.esc(g.tercero) + '</b></div>'
          : '') +
        '<div class="linea"><span class="tenue">Fecha y hora</span><b>' +
        fechaCorta(g.fecha) + ' · ' + U.esc(g.hora || '') + '</b></div>' +
        '<div class="linea"><span class="tenue">Sucursal</span><b>' +
        U.esc(g.sucursalNombre || U.sucursal(g.sucursalId).nombre) + '</b></div>' +
        '<div class="linea"><span class="tenue">Método de pago</span><b>' +
        U.esc(nombreMetodo(g.metodoPago)) + '</b></div>' +
        '<div class="linea"><span class="tenue">Registró</span><b>' +
        U.esc(g.usuarioNombre || '—') +
        (g.rolUsuario ? ' <span class="mini tenue">(' + U.esc(A ? A.nombreRol(g.rolUsuario) : g.rolUsuario) + ')</span>' : '') +
        '</b></div>' +
        '<div class="linea"><span class="tenue">Registrado el</span><b>' +
        new Date(g.creado).toLocaleString('es-CO') + '</b></div>' +
        (g.confirmadoPor
          ? '<div class="linea"><span class="tenue">Confirmó</span><b class="verde">' +
            U.esc(g.confirmadoPor) + ' · ' + new Date(g.confirmado).toLocaleString('es-CO') + '</b></div>'
          : '') +
        '</div>' +

        (g.observaciones
          ? '<div class="caja-datos"><b class="tenue mini">Observaciones</b>' +
            '<p class="mini" style="margin:4px 0 0">' + U.esc(g.observaciones) + '</p></div>'
          : '') +

        (g.estado === 'anulado'
          ? '<div class="caja-datos" style="border-color:var(--rojo)">' +
            '<b class="rojo">Gasto anulado</b>' +
            '<p class="mini" style="margin:4px 0 0">' + U.esc(g.motivoAnulacion) + '</p>' +
            '<p class="mini tenue" style="margin:4px 0 0">Por ' + U.esc(g.anuladoPor) + ' · ' +
            new Date(g.anulado).toLocaleString('es-CO') + '</p>' +
            '<p class="mini tenue" style="margin:6px 0 0">No suma en ningún total, pero se conserva ' +
            'para poder auditarlo.</p></div>'
          : '') +

        '<h4 class="mt-16" style="font-family:var(--f-cond);letter-spacing:.1em;' +
        'text-transform:uppercase;font-size:13px;color:var(--gris)">Historial</h4>' +
        '<ul class="linea-tiempo">' +
        (g.historial || [])
          .map((h) => '<li class="hecho"><b>' + U.esc(h.texto) + '</b><span>' + U.hora(h.ts) + '</span></li>')
          .join('') +
        '</ul>' +

        (g.estado === 'registrado'
          ? '<div class="fila fila--fin mt-16">' +
            (puedeAnular
              ? '<button class="btn btn--fantasma" id="vgAnular" ' +
                'style="border-color:var(--rojo);color:var(--rojo-claro)">✕ Anular</button>'
              : '') +
            (puedeConfirmar
              ? '<button class="btn" id="vgConfirmar" ' +
                'style="background:var(--verde);border-color:var(--verde);color:#04220f">✓ Confirmar gasto</button>'
              : '<span class="mini tenue">Administración se encarga de confirmarlo.</span>') +
            '</div>'
          : '');

      const bc = U.$('#vgConfirmar', m.raiz);
      if (bc) bc.addEventListener('click', () => confirmar(gastoId, pintar));

      const ba = U.$('#vgAnular', m.raiz);
      if (ba) ba.addEventListener('click', () => anular(gastoId, pintar));
    }

    pintar();
  }

  function confirmar(gastoId, alTerminar) {
    if (A && !A.exigir('gastos_confirmar')) return;
    const g = S.getGasto(gastoId);
    if (!g) return;

    U.confirmar(
      'Confirmar el gasto de ' + U.money(g.valor) + ' por "' + g.concepto + '". ' +
        'Verifica que el dinero salió de verdad: después ya no se puede editar.',
      function () {
        try {
          S.confirmarGasto(gastoId, firma());
          U.toast('Gasto confirmado.');
          refrescar();
          if (alTerminar) alTerminar();
        } catch (e) {
          U.toast(e.message, 'error');
        }
      },
      'Sí, confirmar'
    );
  }

  function anular(gastoId, alTerminar) {
    if (A && !A.exigir('gastos_anular')) return;
    const g = S.getGasto(gastoId);
    if (!g) return;

    const m = U.modal({
      titulo: 'Anular gasto',
      ancho: 440,
      contenido:
        '<p class="tenue">Vas a anular el gasto de <b>' + U.money(g.valor) + '</b> por "' +
        U.esc(g.concepto) + '".</p>' +
        '<p class="mini ambar">El registro no se borra: queda con tu nombre y el motivo, ' +
        'y deja de sumar en los totales.</p>' +
        '<label class="campo"><span>Motivo de la anulación <i class="req">*</i></span>' +
        '<textarea class="textarea" id="anMotivo" placeholder="Ej. Se registró dos veces por error"></textarea></label>' +
        '<div class="fila fila--fin">' +
        '<button class="btn btn--fantasma" id="anNo">Cancelar</button>' +
        '<button class="btn btn--rojo" id="anSi">Anular gasto</button></div>',
    });

    U.$('#anNo', m.raiz).onclick = m.cerrar;
    U.$('#anSi', m.raiz).onclick = function () {
      try {
        S.anularGasto(gastoId, U.$('#anMotivo', m.raiz).value, firma());
      } catch (e) {
        return U.toast(e.message, 'error');
      }
      m.cerrar();
      U.toast('Gasto anulado.', 'info');
      refrescar();
      if (alTerminar) alTerminar();
    };
  }

  /* =================================================================
     EXPORTAR
     ================================================================= */
  function exportarCSV() {
    const lista = S.getGastos(filtroActual());
    if (!lista.length) return U.toast('No hay gastos para exportar.', 'error');

    const cab = [
      'Consecutivo', 'Fecha', 'Hora', 'Sucursal', 'Categoria', 'Concepto',
      'Proveedor/Persona', 'Valor', 'MetodoPago', 'Estado', 'Observaciones',
      'Registro', 'Confirmo', 'Anulo', 'MotivoAnulacion',
    ];

    const filas = lista.map((g) => [
      g.consecutivo || '',
      g.fecha,
      g.hora || '',
      g.sucursalNombre || U.sucursal(g.sucursalId).nombre,
      nombreCategoria(g.categoria),
      g.concepto,
      g.tercero || '',
      g.valor,
      nombreMetodo(g.metodoPago),
      g.estado,
      g.observaciones || '',
      g.usuarioNombre || '',
      g.confirmadoPor || '',
      g.anuladoPor || '',
      g.motivoAnulacion || '',
    ]);

    const f = filtroActual();
    const csv =
      '﻿' +
      [
        U.filaCSV(['Gastos NASCAR']),
        U.filaCSV(['Rango', fechaCorta(f.desde) + ' a ' + fechaCorta(f.hasta)]),
        U.filaCSV(['Generado', new Date().toLocaleString('es-CO')]),
        '',
        U.filaCSV(cab),
        ...filas.map(U.filaCSV),
      ].join('\r\n');

    U.descargarArchivo(
      csv,
      'gastos-nascar-' + (f.desde || '') + '_a_' + (f.hasta || '') + '.csv',
      'text/csv;charset=utf-8'
    );
    U.toast('CSV descargado (' + filas.length + ' gastos).');
  }

  return {
    iniciar: iniciar,
    refrescar: refrescar,
  };
})();
