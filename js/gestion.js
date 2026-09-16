/* ==========================================================================
   NASCAR · gestion.js
   Pantallas de administración de la configuración del restaurante:

     🍽 Carta        productos y categorías
     📦 Stock        catálogo de inventario (el mismo que usan los cierres)
     👥 Usuarios     usuarios y roles del MVP
     🏪 Unidades     unidades / locales de la empresa
     ⚙️ Configuración datos del negocio y métodos de pago

   Todo pasa por NASCAR.Store; aquí no se toca localStorage.
   Cada acción comprueba permisos con NASCAR.Auth antes de ejecutarse:
   ocultar un botón no basta.
   ========================================================================== */

window.NASCAR = window.NASCAR || {};

NASCAR.Gestion = (function () {
  'use strict';

  const S = NASCAR.Store;
  const U = NASCAR.UI;
  const A = NASCAR.Auth;

  let ctx = null; // { raiz, sucursalGlobal() }

  function $(sel) {
    return ctx.raiz.querySelector(sel);
  }
  function $$(sel) {
    return Array.prototype.slice.call(ctx.raiz.querySelectorAll(sel));
  }

  /* La unidad en la que se trabaja. Carta, categorías y stock son de
     ella: lo de otra unidad no se lista ni se toca desde aquí. */
  function unidadCtx() {
    return Number(ctx.sucursalGlobal()) || S.unidadActivaId();
  }

  /* Ejecuta una escritura y, si falla (por ejemplo, la base de datos la
     rechaza), muestra el motivo. Devuelve si se pudo. */
  function intentar(fn) {
    try {
      fn();
      return true;
    } catch (err) {
      U.toast(err.message || 'No se pudo guardar.', 'error');
      return false;
    }
  }

  function badgeUnidad(idU) {
    const s = U.sucursal(idU);
    return '<span class="badge badge--linea">' + S.getTipoNegocio(s.tipoNegocio).icono + ' ' + U.esc(s.nombre) + '</span>';
  }

  /* =================================================================
     ARRANQUE
     ================================================================= */
  function iniciar(opciones) {
    ctx = {
      raiz: opciones.raiz,
      sucursalGlobal: opciones.sucursalGlobal || (() => ''),
      irATab: opciones.irATab || null,
    };

    conectarSubTabs();
    if ($('[data-panel="carta"]')) conectarCarta();
    if ($('[data-panel="stock"]')) conectarStock();
    if ($('[data-panel="usuarios"]')) conectarUsuarios();
    if ($('[data-panel="config"]')) conectarConfig();

    refrescar();
  }

  function refrescar() {
    if (!ctx) return;
    if ($('#tablaProductos')) pintarProductos();
    if ($('#tablaCategorias')) pintarCategorias();
    if ($('#tablaStock')) pintarStock();
    if ($('#tablaUsuarios')) pintarUsuarios();
    if ($('#formConfig')) pintarConfig();
    if ($('#listaSucursalesAdmin')) pintarSucursalesAdmin();
    if ($('#listaMetodosPago')) pintarMetodosPago();
    if ($('#listaModulos')) pintarModulos();
  }

  /* Sub-pestañas genéricas dentro de un panel */
  function conectarSubTabs() {
    ctx.raiz.addEventListener('click', function (e) {
      const t = e.target.closest('.sub-tab[data-sub]');
      if (!t) return;
      const grupo = t.closest('[data-panel]');
      if (!grupo) return;
      grupo.querySelectorAll('.sub-tab[data-sub]').forEach((x) => x.classList.toggle('is-activo', x === t));
      grupo.querySelectorAll('[data-sub-panel]').forEach((p) =>
        p.classList.toggle('oculto', p.dataset.subPanel !== t.dataset.sub)
      );
    });
  }

  /* =================================================================
     🍽  CARTA · PRODUCTOS
     ================================================================= */
  function conectarCarta() {
    $('#btnNuevoProducto').addEventListener('click', () => editarProducto(null));
    $('#btnNuevaCategoria').addEventListener('click', () => editarCategoria(null));

    ['#fBuscarProducto', '#fCatProducto', '#fEstadoProducto'].forEach(function (s) {
      const el = $(s);
      if (el) {
        el.addEventListener('input', pintarProductos);
        el.addEventListener('change', pintarProductos);
      }
    });

    $('#btnResetCarta').addEventListener('click', function () {
      if (!A.exigir('carta')) return;
      U.confirmar(
        'La carta de ESTA unidad vuelve a como viene de fábrica. Los productos creados ' +
          'en esta unidad se pierden; las demás unidades no se tocan.',
        function () {
          if (!intentar(() => S.resetCarta(null, unidadCtx()))) return;
          U.toast('Carta restaurada.', 'info');
          avisarCambio();
        },
        'Sí, restaurar'
      );
    });

    // Edición rápida en la tabla (precio y disponibilidad)
    $('#tablaProductos').addEventListener('change', function (e) {
      const pr = e.target.closest('[data-precio]');
      if (pr) {
        if (!A.exigir('carta')) return pintarProductos();
        const v = Number(pr.value);
        if (!isFinite(v) || v < 0) {
          U.toast('Precio inválido.', 'error');
          return pintarProductos();
        }
        if (!intentar(() => S.ajustarPlatoCarta(pr.dataset.precio, { precio: v }))) return pintarProductos();
        U.toast('Precio actualizado.');
        return avisarCambio();
      }
    });

    $('#tablaProductos').addEventListener('click', function (e) {
      const ed = e.target.closest('[data-editar-prod]');
      if (ed) return editarProducto(ed.dataset.editarProd);

      const ag = e.target.closest('[data-agotar]');
      if (ag) {
        if (!A.exigir('carta')) return;
        const p = S.getPlatoCarta(ag.dataset.agotar);
        if (!intentar(() => S.ajustarPlatoCarta(p.id, { agotado: !p.agotado }))) return;
        U.toast(p.agotado ? 'Vuelve a estar disponible.' : 'Marcado como agotado.', 'info');
        return avisarCambio();
      }

      const ac = e.target.closest('[data-activar-prod]');
      if (ac) {
        if (!A.exigir('carta')) return;
        const p = S.getPlatoCarta(ac.dataset.activarProd);
        if (!intentar(() => S.ajustarPlatoCarta(p.id, { activo: !p.activo }))) return;
        U.toast(p.activo ? 'Producto ocultado de la carta.' : 'Producto visible de nuevo.', 'info');
        return avisarCambio();
      }

      const bo = e.target.closest('[data-borrar-prod]');
      if (bo) {
        if (!A.exigir('carta')) return;
        const p = S.getPlatoCarta(bo.dataset.borrarProd);
        return U.confirmar(
          '¿Eliminar "' + p.nombre + '" de la carta?',
          function () {
            let res;
            if (!intentar(() => (res = S.borrarPlatoCarta(p.id)))) return;
            U.toast(
              res.eliminado
                ? 'Producto eliminado.'
                : 'El producto ya tiene ventas registradas, así que se ocultó en vez de borrarlo (los pedidos antiguos no se tocan).',
              res.eliminado ? 'ok' : 'info'
            );
            avisarCambio();
          },
          'Sí, eliminar'
        );
      }
    });

    $('#tablaCategorias').addEventListener('click', function (e) {
      const ed = e.target.closest('[data-editar-cat]');
      if (ed) return editarCategoria(ed.dataset.editarCat);

      const ac = e.target.closest('[data-activar-cat]');
      if (ac) {
        if (!A.exigir('carta')) return;
        const c = S.getCategorias({ todas: true }).find((x) => x.id === ac.dataset.activarCat);
        if (!intentar(() => S.guardarCategoria({ id: c.id, activa: c.activa === false }))) return;
        U.toast(c.activa === false ? 'Categoría activada.' : 'Categoría desactivada.', 'info');
        return avisarCambio();
      }

      const bo = e.target.closest('[data-borrar-cat]');
      if (bo) {
        if (!A.exigir('carta')) return;
        const c = S.getCategorias({ todas: true }).find((x) => x.id === bo.dataset.borrarCat);
        return U.confirmar('¿Eliminar la categoría "' + c.nombre + '"?', function () {
          try {
            S.borrarCategoria(c.id);
            U.toast('Categoría eliminada.', 'info');
            avisarCambio();
          } catch (err) {
            U.toast(err.message, 'error');
          }
        }, 'Sí, eliminar');
      }
    });
  }

  function pintarProductos() {
    const q = ($('#fBuscarProducto').value || '').trim().toLowerCase();
    const cat = $('#fCatProducto').value;
    const estado = $('#fEstadoProducto').value;

    const unidad = unidadCtx();

    // Selector de categorías siempre al día (las de ESTA unidad)
    const cats = S.getCategorias({ todas: true, sucursalId: unidad });
    const sel = $('#fCatProducto');
    if (sel.dataset.n !== String(cats.length)) {
      sel.innerHTML =
        '<option value="">Todas las categorías</option>' +
        cats.map((c) => '<option value="' + c.id + '">' + U.esc(c.nombre) + '</option>').join('');
      sel.dataset.n = String(cats.length);
      sel.value = cat;
    }

    const cartaUnidad = S.getCarta({ todas: true, sucursalId: unidad });
    let lista = cartaUnidad.slice();
    if (cat) lista = lista.filter((p) => p.cat === cat);
    if (q) lista = lista.filter((p) => p.nombre.toLowerCase().includes(q) || (p.codigo || '').toLowerCase().includes(q));
    if (estado === 'activos') lista = lista.filter((p) => p.activo);
    if (estado === 'inactivos') lista = lista.filter((p) => !p.activo);
    if (estado === 'agotados') lista = lista.filter((p) => p.agotado);

    const nombreCat = {};
    cats.forEach((c) => (nombreCat[c.id] = c.nombre));
    const sucursales = S.getSucursales({ todas: true });

    $('#kpisCarta').innerHTML =
      kpi('Productos en carta', cartaUnidad.length, 'De ' + U.sucursal(unidad).nombre) +
      kpi('Visibles al público', S.getCartaDisponible(unidad).length, 'Activos y con existencias', 'verde') +
      kpi('Agotados', cartaUnidad.filter((p) => p.agotado).length, 'No se pueden pedir', 'ambar') +
      kpi('Ocultos', cartaUnidad.filter((p) => !p.activo).length, 'No aparecen en la carta');

    if (!lista.length) {
      $('#tablaProductos').innerHTML =
        '<tr><td colspan="7"><div class="vacio" style="border:0">Sin resultados.</div></td></tr>';
      return;
    }

    $('#tablaProductos').innerHTML = lista
      .map(function (p) {
        const sucTexto = !p.sucursales.length
          ? '<span class="mini ambar">Sin unidad</span>'
          : p.sucursales
              .map(function (idS) {
                const s = sucursales.find((x) => Number(x.id) === Number(idS));
                return '<span class="badge badge--linea">' + U.esc(s ? s.corto : idS) + '</span>';
              })
              .join(' ');

        return (
          '<tr' + (!p.activo ? ' style="opacity:.55"' : '') + '>' +
          '<td><b>' + U.esc(p.nombre) + '</b>' +
          '<br><span class="mini tenue mono">' + U.esc(p.codigo) + '</span>' +
          (p.desc ? '<br><span class="mini tenue">' + U.esc(p.desc) + '</span>' : '') + '</td>' +

          '<td><span class="badge badge--linea">' + U.esc(nombreCat[p.cat] || p.cat) + '</span></td>' +

          '<td class="derecha nowrap">' +
          '<input class="input num derecha" type="number" min="0" step="500" data-precio="' + p.id + '" ' +
          'value="' + p.precio + '" style="width:118px;padding:7px 10px">' +
          (p.modificado ? '<br><span class="mini tenue">antes ' + U.money(p.precioBase) + '</span>' : '') +
          '</td>' +

          '<td class="col-num">' + p.orden + '</td>' +
          '<td>' + sucTexto + '</td>' +

          '<td>' +
          (!p.activo
            ? '<span class="badge badge--gris">Oculto</span>'
            : p.agotado
            ? '<span class="badge badge--ambar">Agotado</span>'
            : '<span class="badge badge--verde">Disponible</span>') +
          '</td>' +

          '<td class="nowrap">' +
          '<button class="btn btn--fantasma btn--xs" data-editar-prod="' + p.id + '">Editar</button> ' +
          '<button class="btn btn--fantasma btn--xs" data-agotar="' + p.id + '">' +
          (p.agotado ? 'Reactivar' : 'Agotar') + '</button> ' +
          '<button class="btn btn--fantasma btn--xs" data-activar-prod="' + p.id + '">' +
          (p.activo ? 'Ocultar' : 'Mostrar') + '</button> ' +
          '<button class="btn btn--fantasma btn--xs" data-borrar-prod="' + p.id + '" ' +
          'style="border-color:var(--rojo);color:var(--rojo-claro)">✕</button>' +
          '</td></tr>'
        );
      })
      .join('');
  }

  function editarProducto(platoId) {
    if (!A.exigir('carta')) return;

    const p = platoId
      ? S.getPlatoCarta(platoId)
      : { id: '', codigo: '', nombre: '', desc: '', cat: '', precio: 0, tag: '',
          orden: (S.getCarta({ todas: true, sucursalId: unidadCtx() }).length + 1) * 10,
          activo: true, agotado: false, sucursales: [unidadCtx()], imagen: '' };

    // Las categorías de la(s) unidad(es) del producto
    const cats = S.getCategorias({ todas: true }).filter((c) =>
      (c.sucursales || []).some((x) => p.sucursales.map(Number).indexOf(Number(x)) >= 0)
    );

    const m = U.modal({
      titulo: platoId ? 'Editar producto' : 'Nuevo producto de la carta',
      ancho: 580,
      contenido:
        '<div class="rejilla-2">' +
        '<label class="campo"><span>Nombre <i class="req">*</i></span>' +
        '<input class="input" id="pNombre" value="' + U.esc(p.nombre) + '" placeholder="Ej. Churrasco Pole Position"></label>' +
        '<label class="campo"><span>Código interno</span>' +
        '<input class="input" id="pCodigo" value="' + U.esc(p.codigo) + '" placeholder="Se genera solo si lo dejas vacío"></label>' +
        '</div>' +

        '<label class="campo"><span>Descripción</span>' +
        '<textarea class="textarea" id="pDesc" placeholder="Lo que ve el cliente debajo del nombre">' + U.esc(p.desc) + '</textarea></label>' +

        '<div class="rejilla-2">' +
        '<label class="campo"><span>Categoría <i class="req">*</i></span>' +
        '<select class="select" id="pCat"><option value="">Elegir…</option>' +
        cats.map((c) => '<option value="' + c.id + '"' + (c.id === p.cat ? ' selected' : '') + '>' +
          U.esc(c.nombre) + (c.activa === false ? ' (inactiva)' : '') + '</option>').join('') +
        '</select></label>' +

        '<label class="campo"><span>Precio (COP) <i class="req">*</i></span>' +
        '<input class="input" type="number" min="0" step="500" id="pPrecio" value="' + Number(p.precio) + '"></label>' +

        '<label class="campo"><span>Etiqueta</span>' +
        '<select class="select" id="pTag">' +
        [['', 'Sin etiqueta'], ['popular', '★ El más pedido'], ['nuevo', 'Nuevo'],
         ['picante', '🌶 Picante'], ['compartir', 'Para compartir']]
          .map(([v, t]) => '<option value="' + v + '"' + (v === (p.tag || '') ? ' selected' : '') + '>' + t + '</option>')
          .join('') +
        '</select></label>' +

        '<label class="campo"><span>Orden de aparición</span>' +
        '<input class="input" type="number" min="0" step="10" id="pOrden" value="' + Number(p.orden) + '"></label>' +
        '</div>' +

        '<label class="campo"><span>Imagen (URL opcional)</span>' +
        '<input class="input" id="pImagen" value="' + U.esc(p.imagen || '') + '" placeholder="https://…"></label>' +

        '<div class="campo"><span>Unidad</span>' +
        '<div class="fila" style="gap:6px">' + p.sucursales.map(badgeUnidad).join('') + '</div>' +
        '<span class="mini tenue">' +
        (p.sucursales.length > 1
          ? 'Producto anterior a las unidades: lo comparten estas unidades.'
          : 'El producto es de esta unidad y sólo se vende aquí.') +
        '</span></div>' +

        '<div class="fila" style="gap:18px;margin:8px 0 16px">' +
        '<label class="fila mini" style="gap:8px"><input type="checkbox" id="pActivo"' +
        (p.activo ? ' checked' : '') + ' style="accent-color:var(--verde);width:18px;height:18px"> Visible en la carta</label>' +
        '<label class="fila mini" style="gap:8px"><input type="checkbox" id="pAgotado"' +
        (p.agotado ? ' checked' : '') + ' style="accent-color:var(--ambar);width:18px;height:18px"> Agotado hoy</label>' +
        '</div>' +

        '<div class="fila fila--fin">' +
        '<button class="btn btn--fantasma" id="pNo">Cancelar</button>' +
        '<button class="btn btn--rojo" id="pSi">Guardar</button></div>',
    });

    U.$('#pNo', m.raiz).onclick = m.cerrar;
    U.$('#pSi', m.raiz).onclick = function () {
      try {
        S.guardarPlatoCarta({
          id: p.id || undefined,
          codigo: U.$('#pCodigo', m.raiz).value.trim(),
          nombre: U.$('#pNombre', m.raiz).value.trim(),
          desc: U.$('#pDesc', m.raiz).value.trim(),
          cat: U.$('#pCat', m.raiz).value,
          precio: U.$('#pPrecio', m.raiz).value,
          tag: U.$('#pTag', m.raiz).value,
          orden: Number(U.$('#pOrden', m.raiz).value) || 0,
          imagen: U.$('#pImagen', m.raiz).value.trim(),
          sucursales: p.sucursales,
          activo: U.$('#pActivo', m.raiz).checked,
          agotado: U.$('#pAgotado', m.raiz).checked,
        });
      } catch (err) {
        return U.toast(err.message, 'error');
      }

      m.cerrar();
      U.toast(platoId ? 'Producto actualizado.' : 'Producto creado y publicado en la carta.');
      avisarCambio();
    };
  }

  /* =================================================================
     🍽  CARTA · CATEGORÍAS
     ================================================================= */
  function pintarCategorias() {
    const cats = S.getCategorias({ todas: true, sucursalId: unidadCtx() });
    const carta = S.getCarta({ todas: true, sucursalId: unidadCtx() });

    $('#tablaCategorias').innerHTML = cats
      .map(function (c) {
        const n = carta.filter((p) => p.cat === c.id).length;
        return (
          '<tr' + (c.activa === false ? ' style="opacity:.55"' : '') + '>' +
          '<td style="font-size:22px">' + (c.icono || '🍽️') + '</td>' +
          '<td><b>' + U.esc(c.nombre) + '</b><br><span class="mini tenue mono">' + U.esc(c.id) + '</span></td>' +
          '<td class="col-num">' + (c.orden || 0) + '</td>' +
          '<td class="col-num">' + n + '</td>' +
          '<td>' + (c.activa === false
            ? '<span class="badge badge--gris">Inactiva</span>'
            : '<span class="badge badge--verde">Activa</span>') + '</td>' +
          '<td class="nowrap">' +
          '<button class="btn btn--fantasma btn--xs" data-editar-cat="' + c.id + '">Editar</button> ' +
          '<button class="btn btn--fantasma btn--xs" data-activar-cat="' + c.id + '">' +
          (c.activa === false ? 'Activar' : 'Desactivar') + '</button> ' +
          (n === 0
            ? '<button class="btn btn--fantasma btn--xs" data-borrar-cat="' + c.id + '" ' +
              'style="border-color:var(--rojo);color:var(--rojo-claro)">✕</button>'
            : '') +
          '</td></tr>'
        );
      })
      .join('');
  }

  function editarCategoria(catId) {
    if (!A.exigir('carta')) return;
    const c = catId
      ? S.getCategorias({ todas: true }).find((x) => x.id === catId)
      : { id: '', nombre: '', icono: '🍽️', activa: true, sucursales: [unidadCtx()],
          orden: (S.getCategorias({ todas: true, sucursalId: unidadCtx() }).length + 1) * 10 };

    const m = U.modal({
      titulo: catId ? 'Editar categoría' : 'Nueva categoría',
      ancho: 460,
      contenido:
        '<div class="rejilla-2">' +
        '<label class="campo"><span>Nombre <i class="req">*</i></span>' +
        '<input class="input" id="cNombre" value="' + U.esc(c.nombre) + '" placeholder="Ej. Parrilla"></label>' +
        '<label class="campo"><span>Icono</span>' +
        '<input class="input" id="cIcono" value="' + U.esc(c.icono || '') + '" placeholder="🔥" maxlength="4"></label>' +
        '</div>' +
        '<label class="campo"><span>Orden de aparición</span>' +
        '<input class="input" type="number" min="0" step="10" id="cOrden" value="' + Number(c.orden || 0) + '"></label>' +
        '<label class="fila mini" style="gap:8px;margin-bottom:16px">' +
        '<input type="checkbox" id="cActiva"' + (c.activa !== false ? ' checked' : '') +
        ' style="accent-color:var(--verde);width:18px;height:18px"> Se muestra en la carta</label>' +
        '<div class="fila fila--fin">' +
        '<button class="btn btn--fantasma" id="cNo">Cancelar</button>' +
        '<button class="btn btn--rojo" id="cSi">Guardar</button></div>',
    });

    U.$('#cNo', m.raiz).onclick = m.cerrar;
    U.$('#cSi', m.raiz).onclick = function () {
      const nombre = U.$('#cNombre', m.raiz).value.trim();
      if (nombre.length < 2) return U.toast('Escribe el nombre de la categoría.', 'error');

      const ok = intentar(() =>
        S.guardarCategoria({
          id: c.id || undefined,
          nombre: nombre,
          icono: U.$('#cIcono', m.raiz).value.trim() || '🍽️',
          orden: Number(U.$('#cOrden', m.raiz).value) || 0,
          activa: U.$('#cActiva', m.raiz).checked,
          sucursales: c.sucursales && c.sucursales.length ? c.sucursales : [unidadCtx()],
        })
      );
      if (!ok) return;
      m.cerrar();
      U.toast(catId ? 'Categoría actualizada.' : 'Categoría creada.');
      avisarCambio();
    };
  }

  /* =================================================================
     📦  STOCK
     ================================================================= */
  /* Filtro rápido activo en 📦 Stock: '' | normal | bajo | sin | inactivos */
  let filtroStock = '';

  function conectarStock() {
    $('#btnNuevoStock').addEventListener('click', () => editarProductoStock(null));
    ['#fBuscarStock', '#fAreaStock'].forEach(function (s) {
      const el = $(s);
      el.addEventListener('input', pintarStock);
      el.addEventListener('change', pintarStock);
    });

    $('#chipsStock').addEventListener('click', function (e) {
      const b = e.target.closest('[data-chip-stock]');
      if (!b) return;
      filtroStock = b.dataset.chipStock;
      pintarStock();
    });

    /* 🛒 Productos por pedir: dos accesos rápidos, los dos reutilizando
       lo que ya existe. "Ver producto" abre la ficha del propio módulo
       Stock; "Registrar entrada" lleva a la pestaña Entradas con el
       producto ya elegido — no hay un segundo sistema de compras. */
    $('#porPedirStock').addEventListener('click', function (e) {
      const ver = e.target.closest('[data-ver-producto]');
      if (ver) return editarProductoStock(ver.dataset.verProducto);

      const ent = e.target.closest('[data-pedir-entrada]');
      if (ent) {
        if (!A.exigir('entradas')) return;
        if (NASCAR.Inventario && NASCAR.Inventario.prepararEntrada)
          NASCAR.Inventario.prepararEntrada(ent.dataset.pedirEntrada, ent.dataset.cantidad);
        if (ctx.irATab) ctx.irATab('entradas');
      }
    });

    $('#fAreaStock').innerHTML =
      '<option value="">Comidas y bar</option>' +
      NASCAR.AREAS.map((a) => '<option value="' + a.id + '">' + a.icono + ' ' + a.nombre + '</option>').join('');

    $('#btnResetStock').addEventListener('click', function () {
      if (!A.exigir('stock')) return;
      U.confirmar(
        'El catálogo de stock de ESTA unidad vuelve a como viene de fábrica. Las demás unidades ' +
          'y los cierres ya registrados NO se tocan.',
        function () {
          if (!intentar(() => S.resetStock(null, unidadCtx()))) return;
          U.toast('Catálogo de stock restaurado.', 'info');
          avisarCambio();
        },
        'Sí, restaurar'
      );
    });

    $('#tablaStock').addEventListener('change', function (e) {
      const inp = e.target.closest('[data-stock-actual]');
      if (!inp) return;
      if (!A.exigir('stock')) return pintarStock();
      try {
        S.ajustarStockActual(inp.dataset.stockActual, inp.value, 'Ajuste manual desde el panel');
        U.toast('Stock actualizado.');
        avisarCambio();
      } catch (err) {
        U.toast(err.message, 'error');
        pintarStock();
      }
    });

    $('#tablaStock').addEventListener('click', function (e) {
      const ed = e.target.closest('[data-editar-stock]');
      if (ed) return editarProductoStock(ed.dataset.editarStock);

      const ac = e.target.closest('[data-activar-stock]');
      if (ac) {
        if (!A.exigir('stock')) return;
        const p = S.getStock({ todos: true }).find((x) => x.codigo === ac.dataset.activarStock);
        if (!intentar(() => S.activarProductoStock(p.codigo, !p.activo))) return;
        U.toast(
          p.activo
            ? 'Producto desactivado. No aparecerá en los cierres nuevos; los anteriores no cambian.'
            : 'Producto activo de nuevo.',
          'info'
        );
        return avisarCambio();
      }
    });
  }

  /* Cómo se pinta cada estado. Un solo sitio, para que la tabla, los
     chips y la lista de "por pedir" digan siempre lo mismo. */
  const PINTA_ESTADO = {
    normal: { badge: 'badge--verde', punto: '🟢', nombre: 'Stock normal', corto: 'Normal' },
    bajo: { badge: 'badge--ambar', punto: '🟡', nombre: 'Stock bajo', corto: 'Bajo' },
    sin: { badge: 'badge--rojo', punto: '🔴', nombre: 'Sin stock', corto: 'Sin stock' },
  };

  function pintarStock() {
    /* La sucursal la manda el selector global del panel. El catálogo de
       stock es de la EMPRESA —`stockActual` es uno solo—, así que al
       elegir una sede se miran las existencias que ESA sede contó en su
       último cierre. Ver store.estadoAbastecimiento(). */
    const suc = unidadCtx();
    const area = $('#fAreaStock').value || undefined;
    const texto = $('#fBuscarStock').value || undefined;

    const abast = S.estadoAbastecimiento({ sucursalId: suc, area: area, texto: texto });
    const r = abast.resumen;

    // --- Tarjetas
    $('#kpisStock').innerHTML =
      kpi('Total productos', r.total, 'Activos en el catálogo') +
      kpi('🟢 Stock normal', r.normal, 'Por encima del mínimo', 'verde') +
      kpi('🟡 Stock bajo', r.bajo, r.bajo ? 'Conviene reponer' : 'Ninguno', r.bajo ? 'ambar' : '') +
      kpi('🔴 Sin stock', r.sin, r.sin ? 'Agotados' : 'Ninguno', r.sin ? 'rojo' : '');

    // --- De dónde sale el número que se está mirando
    const fuente =
      'Stock de <b>' + U.esc(abast.sucursalNombre) + '</b>. Lo que la unidad ya contó en un cierre muestra ' +
      'el saldo de ese conteo (▣); lo que nunca ha contado, el stock registrado en el producto. ' +
      'Los productos de otras unidades no aparecen aquí.';

    /* En una instalación nueva el catálogo viene sin cantidades ni
       mínimos, así que TODO sale en rojo. Es correcto —cero es cero—
       pero sin esta línea parece una alarma en vez de un catálogo por
       estrenar. El mínimo se configura en Editar, producto a producto. */
    const avisoMinimos = r.sinMinimo
      ? ' <span class="ambar">· ' + r.sinMinimo + ' producto' + (r.sinMinimo === 1 ? '' : 's') +
        ' sin stock mínimo configurado: sin mínimo no puede haber aviso de stock bajo. ' +
        'Se define en <b>Editar</b>.</span>'
      : '';

    $('#fuenteStock').innerHTML = fuente + avisoMinimos;

    // --- Filtros rápidos
    const inactivos = S.getStock({ todos: true, area: area, texto: texto, sucursalId: suc }).filter((p) => !p.activo);
    const chips = [
      { id: '', etiqueta: 'Todos', n: r.total },
      { id: 'normal', etiqueta: '🟢 Stock normal', n: r.normal },
      { id: 'bajo', etiqueta: '🟡 Stock bajo', n: r.bajo },
      { id: 'sin', etiqueta: '🔴 Sin stock', n: r.sin },
      { id: 'inactivos', etiqueta: 'Inactivos', n: inactivos.length },
    ];
    $('#chipsStock').innerHTML = chips
      .map(
        (c) =>
          '<button class="btn btn--sm ' +
          (filtroStock === c.id ? 'btn--azul' : 'btn--fantasma') +
          '" data-chip-stock="' + c.id + '">' + c.etiqueta + ' (' + c.n + ')</button>'
      )
      .join('');

    // --- Tabla
    const lista =
      filtroStock === 'inactivos'
        ? inactivos.map((p) => Object.assign({}, p, { existencia: p.stockActual, estado: null }))
        : abast.productos.filter((p) => !filtroStock || p.estado === filtroStock);

    if (!lista.length) {
      $('#tablaStock').innerHTML =
        '<tr><td colspan="8"><div class="vacio" style="border:0">Sin resultados.</div></td></tr>';
      return pintarPorPedir(abast);
    }

    $('#tablaStock').innerHTML = lista
      .map(function (p) {
        const e = PINTA_ESTADO[p.estado];
        /* El stock actual se edita aquí cuando el producto es SÓLO de esta
           unidad y todavía no tiene conteo de cierre: entonces el número
           del producto es el de la unidad. Si ya se contó, manda el cierre;
           si lo comparte con otra unidad (datos anteriores a las unidades),
           no se toca desde aquí para no mover el de la otra. */
        const exclusivo = (p.sucursales || []).length === 1;
        const editable = p.activo && p.origen === 'catalogo' && exclusivo;
        const celdaExistencia = editable
          ? '<input class="input num derecha" type="number" min="0" step="1" data-stock-actual="' +
            p.codigo + '" value="' + p.stockActual + '" style="width:100px;padding:7px 10px">'
          : '<b class="num">' + (p.existencia != null ? p.existencia : p.stockActual) + '</b>' +
            (p.origen === 'cierre'
              ? ' <span class="mini tenue" title="Saldo del último cierre de esta unidad">▣</span>'
              : '') +
            (!exclusivo
              ? ' <span class="mini tenue" title="Producto compartido con otra unidad (anterior a las unidades)">⇄</span>'
              : '');

        return (
          '<tr' + (!p.activo ? ' style="opacity:.55"' : '') + '>' +
          '<td class="mono"><b>' + U.esc(p.codigo) + '</b></td>' +
          '<td><b>' + U.esc(p.nombre) + '</b></td>' +
          '<td class="mini">' + U.esc(p.categoria) + '</td>' +
          '<td><span class="badge badge--linea">' +
          (p.area === 'bar' ? '🍺 Bar' : '🍽️ Comidas') + '</span></td>' +
          '<td class="mini tenue">' + U.esc(p.unidad) + '</td>' +
          '<td class="derecha nowrap">' + celdaExistencia + '</td>' +
          '<td class="col-num">' + (p.stockMinimo || '—') + '</td>' +
          '<td class="nowrap">' +
          (!p.activo
            ? '<span class="badge badge--gris">Inactivo</span> '
            : '<span class="badge ' + e.badge + '">' + e.punto + ' ' + e.corto + '</span> ') +
          '<button class="btn btn--fantasma btn--xs" data-editar-stock="' + p.codigo + '">Editar</button> ' +
          '<button class="btn btn--fantasma btn--xs" data-activar-stock="' + p.codigo + '">' +
          (p.activo ? 'Desactivar' : 'Activar') + '</button>' +
          '</td></tr>'
        );
      })
      .join('');

    pintarPorPedir(abast);
  }

  /* --- 🛒 Productos por pedir -----------------------------------
     Lista de REFERENCIA. No crea órdenes de compra ni mueve nada: dice
     qué está en cero o bajo mínimo y cuánto faltaría para volver al
     mínimo. La decisión de comprar sigue siendo de una persona. */
  function pintarPorPedir(abast) {
    const nodo = $('#porPedirStock');
    if (!nodo) return;

    const lista = abast.porPedir;
    const puedeEntradas = A.puede('entradas');

    if (!lista.length) {
      return (nodo.innerHTML =
        '<div class="caja"><h3>🛒 Productos por pedir</h3>' +
        '<div class="vacio" style="border:0">Nada por pedir: ningún producto activo está en cero ni bajo mínimo.</div>' +
        '</div>');
    }

    nodo.innerHTML =
      '<div class="caja">' +
      '<div class="fila fila--entre mb-8" style="flex-wrap:wrap;gap:10px">' +
      '<h3 style="margin:0">🛒 Productos por pedir (' + lista.length + ')</h3>' +
      '<span class="mini tenue">' + U.esc(abast.sucursalNombre) + '</span>' +
      '</div>' +
      '<p class="mini tenue">La cantidad sugerida es <b>mínimo − actual</b>, sólo como referencia. ' +
      'El sistema no genera órdenes de compra.</p>' +
      /* Aviso necesario: registrar la entrada NO mueve el stock actual.
         En este sistema las entradas alimentan el campo EN del cruce, y
         el stock se actualiza a mano o al aplicar los saldos de un
         cierre. Sin esta línea, la gente esperaría que el semáforo
         cambiara solo al recibir la mercancía. */
      (NASCAR.Remoto && NASCAR.Remoto.activo
        ? '<p class="mini ambar">Registrar la entrada suma al stock actual y alimenta el campo <b>EN</b> ' +
          'del cruce de esa jornada. Las ventas no lo descuentan: el stock se corrige a mano aquí, ' +
          'o de una vez al aplicar los saldos de un cierre.</p>'
        : '<p class="mini ambar">Registrar la entrada no cambia por sí sola el stock actual: ' +
          'alimenta el campo <b>EN</b> del cruce de esa jornada. El stock se actualiza a mano aquí, ' +
          'o de una vez al aplicar los saldos de un cierre.</p>') +
      '<div class="tabla-wrap"><table class="tabla"><thead><tr>' +
      '<th>Producto</th><th class="col-num">Stock actual</th><th class="col-num">Stock mínimo</th>' +
      '<th class="col-num">Diferencia</th><th>Estado</th><th class="derecha">Acciones</th>' +
      '</tr></thead><tbody>' +
      lista
        .map(function (p) {
          const e = PINTA_ESTADO[p.estado];
          return (
            '<tr><td><b>' + U.esc(p.nombre) + '</b>' +
            '<div class="mini tenue mono">' + U.esc(p.codigo) + ' · ' + U.esc(p.unidad) + '</div></td>' +
            '<td class="col-num"><b>' + p.existencia + '</b></td>' +
            '<td class="col-num">' + (p.stockMinimo || '—') + '</td>' +
            '<td class="col-num">' +
            (p.sinMinimo
              ? '<span class="mini tenue">sin mínimo</span>'
              : '<b class="ambar">+' + p.sugerido + '</b>') +
            '</td>' +
            '<td><span class="badge ' + e.badge + '">' + e.punto + ' ' + e.corto + '</span></td>' +
            '<td class="derecha nowrap">' +
            '<button class="btn btn--fantasma btn--xs" data-ver-producto="' + p.codigo + '">Ver producto</button> ' +
            (puedeEntradas
              ? '<button class="btn btn--fantasma btn--xs" data-pedir-entrada="' + p.codigo +
                '" data-cantidad="' + p.sugerido + '">Registrar entrada</button>'
              : '') +
            '</td></tr>'
          );
        })
        .join('') +
      '</tbody></table></div></div>';
  }

  function editarProductoStock(codigo) {
    if (!A.exigir('stock')) return;
    const p = codigo
      ? S.getStock({ todos: true }).find((x) => x.codigo === codigo)
      : { codigo: '', nombre: '', categoria: '', area: 'comidas', unidad: 'unidad',
          activo: true, stockActual: 0, stockMinimo: 0, ventaRefIds: [], sucursales: [unidadCtx()] };

    /* Inventario y carta son cosas distintas: el producto de stock
       (lo que se cuenta) sólo se enlaza con un producto de la carta de
       SU unidad (lo que se vende). */
    const carta = S.getCarta({ todas: true }).filter((c) =>
      (c.sucursales || []).some((x) => (p.sucursales || []).map(Number).indexOf(Number(x)) >= 0)
    );

    const m = U.modal({
      titulo: codigo ? 'Editar producto de stock' : 'Nuevo producto de stock',
      ancho: 560,
      contenido:
        '<div class="rejilla-2">' +
        '<label class="campo"><span>Código <i class="req">*</i></span>' +
        '<input class="input mono" id="sCodigo" value="' + U.esc(p.codigo) + '" placeholder="Ej. C028"></label>' +
        '<label class="campo"><span>Nombre <i class="req">*</i></span>' +
        '<input class="input" id="sNombre" value="' + U.esc(p.nombre) + '" placeholder="Ej. Cerveza importada"></label>' +
        '<label class="campo"><span>Categoría</span>' +
        '<input class="input" id="sCategoria" value="' + U.esc(p.categoria) + '" placeholder="Ej. Embotellados"></label>' +
        '<label class="campo"><span>Área <i class="req">*</i></span>' +
        '<select class="select" id="sArea">' +
        NASCAR.AREAS.map((a) => '<option value="' + a.id + '"' + (a.id === p.area ? ' selected' : '') + '>' +
          a.icono + ' ' + a.nombre + '</option>').join('') +
        '</select></label>' +
        '<label class="campo"><span>Unidad de conteo</span>' +
        '<input class="input" id="sUnidad" value="' + U.esc(p.unidad) + '" placeholder="unidad, botella, porción…"></label>' +
        '<label class="campo"><span>Stock actual</span>' +
        '<input class="input" type="number" min="0" step="1" id="sActual" value="' + Number(p.stockActual) + '"></label>' +
        '<label class="campo"><span>Stock mínimo</span>' +
        '<input class="input" type="number" min="0" step="1" id="sMinimo" value="' + Number(p.stockMinimo) + '"></label>' +
        '</div>' +

        '<p class="mini tenue" style="margin:-4px 0 12px">Unidad: ' + (p.sucursales || []).map(badgeUnidad).join(' ') + '</p>' +
        '<label class="campo"><span>¿Qué producto de la carta descuenta este stock?</span>' +
        '<select class="select" id="sRef"><option value="">Ninguno (no se vende directamente)</option>' +
        carta.map((c) => '<option value="' + c.id + '"' +
          (p.ventaRefIds.indexOf(c.id) >= 0 ? ' selected' : '') + '>' + U.esc(c.nombre) + '</option>').join('') +
        '</select>' +
        '<span class="mini tenue">De aquí sale el campo <b>Z</b> (ventas) del cruce de inventario. ' +
        'Si no se vende directo, Z queda en 0.</span></label>' +

        '<label class="fila mini" style="gap:8px;margin:6px 0 16px">' +
        '<input type="checkbox" id="sActivo"' + (p.activo ? ' checked' : '') +
        ' style="accent-color:var(--verde);width:18px;height:18px"> Activo (aparece en los cierres nuevos)</label>' +

        '<div class="fila fila--fin">' +
        '<button class="btn btn--fantasma" id="sNo">Cancelar</button>' +
        '<button class="btn btn--rojo" id="sSi">Guardar</button></div>',
    });

    U.$('#sNo', m.raiz).onclick = m.cerrar;
    U.$('#sSi', m.raiz).onclick = function () {
      const ref = U.$('#sRef', m.raiz).value;
      try {
        S.guardarProductoStock(
          {
            codigo: U.$('#sCodigo', m.raiz).value.trim(),
            nombre: U.$('#sNombre', m.raiz).value.trim(),
            categoria: U.$('#sCategoria', m.raiz).value.trim() || 'General',
            area: U.$('#sArea', m.raiz).value,
            unidad: U.$('#sUnidad', m.raiz).value.trim() || 'unidad',
            stockActual: U.$('#sActual', m.raiz).value,
            stockMinimo: U.$('#sMinimo', m.raiz).value,
            ventaRefIds: ref ? [ref] : [],
            activo: U.$('#sActivo', m.raiz).checked,
            sucursales: p.sucursales,
          },
          codigo
        );
      } catch (err) {
        return U.toast(err.message, 'error');
      }
      m.cerrar();
      U.toast(codigo ? 'Producto de stock actualizado.' : 'Producto agregado al stock y a los cierres.');
      avisarCambio();
    };
  }

  /* =================================================================
     👥  USUARIOS
     ================================================================= */
  function conectarUsuarios() {
    $('#btnNuevoUsuario').addEventListener('click', () => editarUsuario(null));

    $('#tablaUsuarios').addEventListener('click', function (e) {
      const ed = e.target.closest('[data-editar-usuario]');
      if (ed) return editarUsuario(ed.dataset.editarUsuario);

      const ac = e.target.closest('[data-activar-usuario]');
      if (ac) {
        if (!A.exigir('usuarios')) return;
        const u = S.getUsuario(ac.dataset.activarUsuario);
        const yo = A.getUsuarioActual();
        if (yo && yo.usuarioId === u.id && u.activo)
          return U.toast('No puedes desactivar tu propio usuario.', 'error');
        if (!intentar(() => S.activarUsuario(u.id, !u.activo))) return;
        U.toast(u.activo ? 'Usuario desactivado.' : 'Usuario activado.', 'info');
        return avisarCambio();
      }
    });
  }

  function pintarUsuarios() {
    const lista = S.getUsuarios({ todos: true });
    const yo = A.getUsuarioActual();

    $('#kpisUsuarios').innerHTML =
      kpi('Usuarios activos', lista.filter((u) => u.activo !== false).length, 'Pueden entrar al sistema', 'verde') +
      kpi('Roles en uso', new Set(lista.map((u) => u.rol)).size, 'de ' + A.rolesDeEmpresa().length + ' disponibles') +
      kpi('Sesión actual', yo ? U.esc(yo.nombre) : '—', yo ? A.nombreRol(yo.rol) : '', 'azul');

    $('#tablaUsuarios').innerHTML = lista
      .map(function (u) {
        const suc = u.sucursalId ? U.sucursal(u.sucursalId) : null;
        const esYo = yo && yo.usuarioId === u.id;
        return (
          '<tr' + (u.activo === false ? ' style="opacity:.55"' : '') + '>' +
          '<td><b>' + U.esc(u.nombre) + '</b>' + (esYo ? ' <span class="badge badge--azul">Tú</span>' : '') +
          '<br><span class="mini tenue mono">' + U.esc(u.usuario) + '</span></td>' +
          '<td>' + A.iconoRol(u.rol) + ' ' + U.esc(A.nombreRol(u.rol)) + '</td>' +
          '<td class="mini">' + (suc ? U.esc(suc.corto) : '<span class="tenue">Todas</span>') + '</td>' +
          '<td class="mini mono">' + '••••' + '</td>' +
          '<td>' + (u.activo === false
            ? '<span class="badge badge--gris">Inactivo</span>'
            : '<span class="badge badge--verde">Activo</span>') + '</td>' +
          '<td class="nowrap">' +
          '<button class="btn btn--fantasma btn--xs" data-editar-usuario="' + u.id + '">Editar</button> ' +
          '<button class="btn btn--fantasma btn--xs" data-activar-usuario="' + u.id + '">' +
          (u.activo === false ? 'Activar' : 'Desactivar') + '</button>' +
          '</td></tr>'
        );
      })
      .join('');
  }

  function editarUsuario(usuarioId) {
    if (!A.exigir('usuarios')) return;
    const u = usuarioId
      ? S.getUsuario(usuarioId)
      : { id: '', nombre: '', usuario: '', pin: '', rol: 'mesero', sucursalId: null, activo: true };

    const sucursales = S.getSucursales({ todas: true });
    // Con la base de datos el PIN está cifrado: al editar no se muestra y vacío = no cambia
    const conBase = !!(NASCAR.Remoto && NASCAR.Remoto.activo);
    const pinOpcional = !!usuarioId && !u.pin;

    const m = U.modal({
      titulo: usuarioId ? 'Editar usuario' : 'Nuevo usuario',
      ancho: 520,
      contenido:
        '<div class="rejilla-2">' +
        '<label class="campo"><span>Nombre <i class="req">*</i></span>' +
        '<input class="input" id="uNombre" value="' + U.esc(u.nombre) + '" placeholder="Ej. María Rodríguez"></label>' +
        '<label class="campo"><span>Usuario de acceso <i class="req">*</i></span>' +
        '<input class="input mono" id="uUsuario" value="' + U.esc(u.usuario) + '" placeholder="mesero2"></label>' +
        '<label class="campo"><span>PIN (4 a 6 dígitos)' + (pinOpcional ? '' : ' <i class="req">*</i>') + '</span>' +
        '<input class="input mono" id="uPin" inputmode="numeric" maxlength="6" value="' + U.esc(u.pin || '') + '"' +
        (pinOpcional ? ' placeholder="Vacío = no cambia"' : '') + '></label>' +
        '<label class="campo"><span>Rol <i class="req">*</i></span>' +
        '<select class="select" id="uRol">' +
        /* Sólo roles de EMPRESA. El SuperAdmin es de la plataforma
           Taseca: no existe "NASCAR → SuperAdmin". */
        A.rolesDeEmpresa().map((k) => '<option value="' + k + '"' + (k === u.rol ? ' selected' : '') + '>' +
          A.ROLES[k].icono + ' ' + A.ROLES[k].nombre + '</option>').join('') +
        '</select></label>' +
        '</div>' +

        '<label class="campo"><span>Unidad asignada</span>' +
        '<select class="select" id="uSucursal"><option value="">Todas las unidades</option>' +
        sucursales.map((s) => '<option value="' + s.id + '"' +
          (Number(u.sucursalId) === Number(s.id) ? ' selected' : '') + '>' + U.esc(s.nombre) + '</option>').join('') +
        '</select></label>' +

        '<div id="uDescRol" class="caja-datos"></div>' +

        '<label class="fila mini" style="gap:8px;margin:6px 0 16px">' +
        '<input type="checkbox" id="uActivo"' + (u.activo !== false ? ' checked' : '') +
        ' style="accent-color:var(--verde);width:18px;height:18px"> Puede entrar al sistema</label>' +

        (conBase
          ? '<p class="mini tenue" style="margin-bottom:16px">El PIN se guarda cifrado en la base de datos: nadie puede ' +
            'verlo, sólo cambiarlo.' + (u.unidades && u.unidades.length > 1 && !u.sucursalId
              ? ' Este usuario tiene varias unidades asignadas en la base; si no cambias la unidad, se conservan.'
              : '') + '</p>'
          : '<p class="mini ambar" style="margin-bottom:16px">Este PIN no es seguridad real: sirve para ' +
            'separar perfiles mientras el sistema no tenga servidor.</p>') +

        '<div class="fila fila--fin">' +
        '<button class="btn btn--fantasma" id="uNo">Cancelar</button>' +
        '<button class="btn btn--rojo" id="uSi">Guardar</button></div>',
    });

    function pintarDescRol() {
      const rol = U.$('#uRol', m.raiz).value;
      const d = A.ROLES[rol];
      const permisos = d.permisos.indexOf('*') >= 0 ? Object.keys(A.PERMISOS) : d.permisos;
      U.$('#uDescRol', m.raiz).innerHTML =
        '<b>' + d.icono + ' ' + U.esc(d.nombre) + '</b>' +
        '<p class="mini tenue" style="margin:4px 0 8px">' + U.esc(d.descripcion) + '</p>' +
        '<div class="fila" style="gap:6px">' +
        permisos.map((p) => '<span class="badge badge--linea">' + U.esc(A.PERMISOS[p] || p) + '</span>').join('') +
        '</div>';
    }
    U.$('#uRol', m.raiz).addEventListener('change', pintarDescRol);
    pintarDescRol();

    U.$('#uNo', m.raiz).onclick = m.cerrar;
    U.$('#uSi', m.raiz).onclick = function () {
      try {
        S.guardarUsuario({
          id: u.id || undefined,
          nombre: U.$('#uNombre', m.raiz).value.trim(),
          usuario: U.$('#uUsuario', m.raiz).value.trim(),
          pin: U.$('#uPin', m.raiz).value.trim(),
          rol: U.$('#uRol', m.raiz).value,
          sucursalId: U.$('#uSucursal', m.raiz).value || null,
          activo: U.$('#uActivo', m.raiz).checked,
        });
      } catch (err) {
        return U.toast(err.message, 'error');
      }
      m.cerrar();
      U.toast(usuarioId ? 'Usuario actualizado.' : 'Usuario creado.');
      avisarCambio();
    };
  }

  /* =================================================================
     ⚙️  CONFIGURACIÓN
     ================================================================= */
  function conectarConfig() {
    $('#btnGuardarConfig').addEventListener('click', guardarConfigGeneral);
    $('#btnNuevaSucursal').addEventListener('click', () => editarSucursal(null));

    $('#listaSucursalesAdmin').addEventListener('click', function (e) {
      const ed = e.target.closest('[data-editar-suc]');
      if (ed) return editarSucursal(Number(ed.dataset.editarSuc));

      const ver = e.target.closest('[data-ver-unidad]');
      if (ver) return verUnidad(Number(ver.dataset.verUnidad));

      // Cambiar la unidad en la que se trabaja (no requiere permisos de edición)
      const usar = e.target.closest('[data-usar-unidad]');
      if (usar) {
        try {
          S.setUnidadActiva(Number(usar.dataset.usarUnidad));
        } catch (err) {
          return U.toast(err.message, 'error');
        }
        U.toast('Ahora trabajas en ' + S.getUnidadActiva().nombre + '.');
        return avisarCambio();
      }

      const ac = e.target.closest('[data-activar-suc]');
      if (ac) {
        if (!A.exigir('config_sucursales')) return;
        const s = S.getSucursal(Number(ac.dataset.activarSuc));
        const cambiar = function () {
          try {
            S.activarSucursal(s.id, s.activa === false);
          } catch (err) {
            return U.toast(err.message, 'error');
          }
          U.toast(
            s.activa === false ? 'Unidad activada.' : 'Unidad desactivada. Su información histórica se conserva.',
            'info'
          );
          avisarCambio();
        };
        if (s.activa === false) return cambiar();
        return U.confirmar(
          '¿Desactivar "' + s.nombre + '"? No se podrán tomar pedidos ni registrar gastos, bases, ' +
            'cierres o entradas en ella. Nada de lo que ya tiene se borra.',
          cambiar,
          'Sí, desactivar'
        );
      }
    });

    $('#listaMetodosPago').addEventListener('change', function (e) {
      const chk = e.target.closest('[data-metodo]');
      if (!chk) return;
      if (!A.exigir('config_pagos')) return pintarMetodosPago();

      const metodos = S.getConfig().metodosPago.map(function (m) {
        return m.id === chk.dataset.metodo ? Object.assign({}, m, { activo: chk.checked }) : m;
      });
      if (!metodos.some((m) => m.activo)) {
        U.toast('Tiene que quedar al menos un método de pago activo.', 'error');
        return pintarMetodosPago();
      }
      S.guardarConfig({ metodosPago: metodos });
      U.toast('Métodos de pago actualizados.');
      avisarCambio();
    });
  }

  function pintarConfig() {
    const c = S.getConfig();
    const puedeLocal = A.puede('config_local');

    const campo = (id, etiqueta, valor, ayuda, tipo) =>
      '<label class="campo"><span>' + etiqueta + '</span>' +
      '<input class="input" type="' + (tipo || 'text') + '" id="' + id + '" value="' + U.esc(valor == null ? '' : valor) + '"' +
      (puedeLocal ? '' : ' disabled') + '>' +
      (ayuda ? '<span class="mini tenue">' + ayuda + '</span>' : '') + '</label>';

    $('#formConfig').innerHTML =
      '<div class="rejilla-2">' +
      campo('cfgMarca', 'Nombre del restaurante', c.marca) +
      campo('cfgNit', 'NIT', c.pago.nit) +
      campo('cfgWhatsapp', 'WhatsApp del restaurante', c.contacto.whatsapp,
            'Con indicativo de país y sin signos. Ej. 573001112233') +
      campo('cfgTelefono', 'Teléfono fijo', c.contacto.telefono) +
      campo('cfgEmail', 'Correo electrónico', c.contacto.email, '', 'email') +
      campo('cfgDireccion', 'Dirección principal', c.contacto.direccion) +
      campo('cfgHorario', 'Horario general', c.contacto.horarioGeneral) +
      campo('cfgEslogan', 'Eslogan', c.eslogan) +
      '</div>' +

      '<label class="campo"><span>Descripción del restaurante</span>' +
      '<textarea class="textarea" id="cfgDescripcion"' + (puedeLocal ? '' : ' disabled') + '>' +
      U.esc(c.descripcion) + '</textarea></label>' +

      '<h3 class="mt-24" style="font-family:var(--f-cond);font-size:17px;letter-spacing:.08em;text-transform:uppercase">Datos para transferencias</h3>' +
      '<div class="rejilla-2">' +
      campo('cfgNequi', 'Nequi', c.pago.nequi) +
      campo('cfgDaviplata', 'Daviplata', c.pago.daviplata) +
      campo('cfgBancolombia', 'Bancolombia', c.pago.bancolombia) +
      campo('cfgTitular', 'Titular de la cuenta', c.pago.titular) +
      '</div>' +

      '<h3 class="mt-24" style="font-family:var(--f-cond);font-size:17px;letter-spacing:.08em;text-transform:uppercase">Operación</h3>' +
      '<div class="rejilla-2">' +
      campo('cfgTiempoMesa', 'Tiempo estimado en mesa', c.tiempos.mesa) +
      campo('cfgTiempoDomicilio', 'Tiempo estimado a domicilio', c.tiempos.domicilio) +
      campo('cfgCorte', 'Hora en que empieza el día siguiente', c.horaCorteOperativa,
            'Para los cierres de madrugada. 6 = lo de antes de las 6 a.m. cuenta al día anterior.', 'number') +
      // Con la base de datos no hay PIN general: cada quien entra con su usuario y su PIN
      (NASCAR.Remoto && NASCAR.Remoto.activo
        ? ''
        : campo('cfgPin', 'PIN general de respaldo', c.pinAdmin,
                'Sirve si se pierden los usuarios. Los usuarios tienen su propio PIN.')) +
      '</div>';

    $('#btnGuardarConfig').classList.toggle('oculto', !puedeLocal);
    $('#avisoPermisoConfig').innerHTML = puedeLocal
      ? ''
      : '<div class="caja-datos" style="border-color:var(--ambar)"><b class="ambar">Sólo lectura</b>' +
        '<p class="mini tenue" style="margin:4px 0 0">Tu perfil (' + U.esc(A.nombreRol(A.rolActual())) +
        ') puede consultar esta información pero no modificarla.</p></div>';
  }

  function guardarConfigGeneral() {
    if (!A.exigir('config_local')) return;
    const v = (id) => ($('#' + id) || {}).value;

    const wa = String(v('cfgWhatsapp') || '').replace(/\D/g, '');
    if (wa && wa.length < 10)
      return U.toast('El WhatsApp debe incluir el indicativo del país. Ej. 573001112233', 'error');

    S.guardarConfig({
      marca: v('cfgMarca'),
      eslogan: v('cfgEslogan'),
      descripcion: v('cfgDescripcion'),
      pinAdmin: $('#cfgPin') ? v('cfgPin') : S.getConfig().pinAdmin,
      horaCorteOperativa: Number(v('cfgCorte')) || 6,
      contacto: {
        whatsapp: wa,
        telefono: v('cfgTelefono'),
        email: v('cfgEmail'),
        direccion: v('cfgDireccion'),
        horarioGeneral: v('cfgHorario'),
      },
      pago: {
        nit: v('cfgNit'),
        nequi: v('cfgNequi'),
        daviplata: v('cfgDaviplata'),
        bancolombia: v('cfgBancolombia'),
        titular: v('cfgTitular'),
      },
      tiempos: { mesa: v('cfgTiempoMesa'), domicilio: v('cfgTiempoDomicilio') },
    });

    U.toast('Configuración guardada. Ya se ve en la página pública.');
    avisarCambio();
  }

  function pintarMetodosPago() {
    const c = S.getConfig();
    const puedeEditar = A.puede('config_pagos');

    $('#listaMetodosPago').innerHTML =
      (c.metodosPago || [])
        .map(
          (m) =>
            '<label class="op" style="cursor:' + (puedeEditar ? 'pointer' : 'default') + '">' +
            '<input type="checkbox" data-metodo="' + m.id + '"' + (m.activo ? ' checked' : '') +
            (puedeEditar ? '' : ' disabled') + '>' +
            '<div><b>' + U.esc(m.nombre) + '</b><span>' + U.esc(m.descripcion || '') + '</span></div></label>'
        )
        .join('') +
      (puedeEditar
        ? '<p class="mini tenue">Lo que desactives aquí deja de ofrecerse al cliente en el pedido a domicilio.</p>'
        : '<p class="mini ambar">Sólo el rol Admin puede cambiar los métodos de pago.</p>');
  }

  /* ---- Módulos contratados (sólo lectura) ----

     El administrador ve qué incluye su plan, pero no lo cambia: los
     módulos los habilita el SuperAdmin. Por eso aquí no hay ni un
     control editable, y store.guardarEmpresa() descarta el campo
     `modulos` aunque alguien lo mande a mano. */
  function pintarModulos() {
    const empresa = S.getEmpresaActual();
    const activos = S.getModulos();

    $('#listaModulos').innerHTML =
      '<div class="caja mb-16">' +
      '<h3>Plan de ' + U.esc(empresa ? empresa.nombre : 'la empresa') + '</h3>' +
      '<p class="mini tenue">Los módulos se contratan con el proveedor del sistema. ' +
      'Desde aquí sólo se consultan.</p></div>' +
      S.catalogoModulos()
        .map(function (m) {
          const on = activos[m.id] !== false;
          return (
            '<div class="caja mb-16"' + (on ? '' : ' style="opacity:.55"') + '>' +
            '<div class="fila fila--entre mb-8">' +
            '<h3 style="margin:0">' + m.icono + ' ' + U.esc(m.nombre) + '</h3>' +
            '<span class="badge badge--' + (on ? 'verde' : 'linea') + '">' +
            (on ? 'Incluido' : 'No incluido') + '</span></div>' +
            '<p class="mini tenue">' + U.esc(m.descripcion) +
            (m.obligatorio ? ' Siempre incluido.' : '') + '</p>' +
            '<div class="fila mt-8" style="gap:6px;flex-wrap:wrap">' +
            m.incluye
              .map((x) => '<span class="badge badge--linea">' + U.esc(x) + '</span>')
              .join('') +
            '</div></div>'
          );
        })
        .join('');
  }

  /* =================================================================
     🏪  UNIDADES / LOCALES
     ================================================================= */
  function cifrasUnidad(idU) {
    /* Con la base de datos, stock, gastos y cierres todavía no se leen de
       ella: sus datos locales no son los de la base, así que no se cuentan. */
    const pendiente = (permiso) => NASCAR.Remoto && !NASCAR.Remoto.permisoDisponible(permiso);
    return {
      carta: S.getCarta({ todas: true, sucursalId: idU }).length,
      categorias: S.getCategorias({ todas: true, sucursalId: idU }).length,
      stock: pendiente('stock') ? '—' : S.getStock({ todos: true, sucursalId: idU }).length,
      pedidos: S.getPedidos({ sucursalId: idU }).length,
      gastos: pendiente('gastos') ? '—' : S.getGastos({ sucursalId: idU }).length,
      cierres: pendiente('cierres') ? '—' : S.getCierres({ sucursalId: idU }).length,
    };
  }

  function logoUnidad(s, clase) {
    const tipo = S.getTipoNegocio(s.tipoNegocio);
    return s.branding && s.branding.logo
      ? '<img class="unidad__logo' + (clase ? ' ' + clase : '') + '" src="' + s.branding.logo + '" alt="">'
      : '<span class="unidad__logo unidad__logo--icono' + (clase ? ' ' + clase : '') + '" aria-hidden="true">' +
          tipo.icono + '</span>';
  }

  function pintarSucursalesAdmin() {
    const lista = S.getSucursales({ todas: true });
    const puedeEditar = A.puede('config_sucursales');
    const actual = S.unidadActivaId();
    const atado = !!A.sucursalDelUsuario();
    const empresa = S.getEmpresaActual();

    $('#btnNuevaSucursal').classList.toggle('oculto', !puedeEditar);
    const resumen = $('#resumenUnidades');
    if (resumen)
      resumen.innerHTML =
        '<span class="mini tenue">' + U.esc(empresa ? empresa.nombre : '') + ' · ' +
        lista.filter((s) => s.activa !== false).length + ' activas de ' + lista.length + '</span>';

    $('#listaSucursalesAdmin').innerHTML = lista
      .map(function (s) {
        const tipo = S.getTipoNegocio(s.tipoNegocio);
        const inactiva = s.activa === false;
        const esActual = Number(s.id) === Number(actual);
        const n = cifrasUnidad(s.id);
        const contacto = [s.telefono, s.whatsapp].filter(Boolean).join(' · ');

        return (
          '<article class="unidad' + (inactiva ? ' is-inactiva' : '') + (esActual ? ' is-actual' : '') + '"' +
          (s.branding.color ? ' style="--unidad-color:' + s.branding.color + '"' : '') + '>' +
          '<header class="unidad__cab">' +
          logoUnidad(s) +
          '<div class="unidad__titulo"><h3>' + U.esc(s.nombre) + '</h3>' +
          '<span class="unidad__tipo">' + tipo.icono + ' ' + U.esc(tipo.nombre) + '</span></div>' +
          (inactiva
            ? '<span class="badge badge--gris">INACTIVA</span>'
            : '<span class="badge badge--verde">ACTIVA</span>') +
          '</header>' +
          (esActual ? '<div class="unidad__actual">● Unidad en la que estás trabajando</div>' : '') +
          '<div class="unidad__datos">' +
          '<div class="dato"><span class="dato__ico">📍</span><span>' +
          (s.direccion ? U.esc(s.direccion) + (s.ciudad ? ' · ' + U.esc(s.ciudad) : '') : '<span class="tenue">Sin dirección</span>') +
          '</span></div>' +
          '<div class="dato"><span class="dato__ico">📞</span><span>' +
          (contacto ? U.esc(contacto) : '<span class="tenue">Sin contacto</span>') + '</span></div>' +
          '</div>' +
          '<div class="unidad__cifras">' +
          '<div class="unidad__cifra"><b>' + n.carta + '</b><span>en carta</span></div>' +
          '<div class="unidad__cifra"><b>' + n.stock + '</b><span>en stock</span></div>' +
          '<div class="unidad__cifra"><b>' + n.pedidos + '</b><span>pedidos</span></div>' +
          '</div>' +
          '<footer class="unidad__acciones">' +
          '<button class="btn btn--fantasma btn--xs" data-ver-unidad="' + s.id + '">Consultar</button>' +
          (puedeEditar
            ? '<button class="btn btn--fantasma btn--xs" data-editar-suc="' + s.id + '">Editar</button>' +
              '<button class="btn btn--fantasma btn--xs" data-activar-suc="' + s.id + '">' +
              (inactiva ? 'Activar' : 'Desactivar') + '</button>'
            : '') +
          (!inactiva && !esActual && !atado
            ? '<button class="btn btn--rojo btn--xs" data-usar-unidad="' + s.id + '">Trabajar aquí</button>'
            : '') +
          '</footer>' +
          '</article>'
        );
      })
      .join('');
  }

  /* Ficha de consulta: todo lo de la unidad en un vistazo. No edita. */
  function verUnidad(idU) {
    const s = S.getSucursal(idU);
    if (!s) return;
    const tipo = S.getTipoNegocio(s.tipoNegocio);
    const n = cifrasUnidad(s.id);
    const linea = (k, v) => '<div class="linea"><span class="tenue">' + k + '</span><b>' + v + '</b></div>';

    const m = U.modal({
      titulo: s.nombre,
      ancho: 560,
      contenido:
        '<div class="unidad__cab mb-16">' + logoUnidad(s) +
        '<div class="unidad__titulo"><h3>' + U.esc(s.nombre) + '</h3>' +
        '<span class="unidad__tipo">' + tipo.icono + ' ' + U.esc(tipo.nombre) + '</span></div>' +
        (s.activa === false ? '<span class="badge badge--gris">INACTIVA</span>' : '<span class="badge badge--verde">ACTIVA</span>') +
        '</div>' +
        '<div class="caja-datos">' +
        linea('Nombre corto', U.esc(s.corto || '—')) +
        linea('Dirección', U.esc([s.direccion, s.ciudad].filter(Boolean).join(' · ') || '—')) +
        linea('Teléfono', U.esc(s.telefono || '—')) +
        linea('WhatsApp', U.esc(s.whatsapp || 'Usa el de la empresa')) +
        linea('Horario', U.esc(s.horario || '—')) +
        linea('Mesas', String(s.mesas || 0)) +
        linea('Zonas de domicilio', String((s.zonas || []).length)) +
        linea('Identidad', s.branding.logo || s.branding.color ? 'Propia' : 'La de la empresa') +
        linea('Creada', s.creado ? U.esc(s.creado.slice(0, 10)) : 'Antes de las unidades') +
        '</div>' +
        '<h4 class="mini tenue mt-16">Su operación</h4>' +
        '<div class="unidad__cifras unidad__cifras--6">' +
        [['carta', 'en carta'], ['categorias', 'categorías'], ['stock', 'en stock'],
         ['pedidos', 'pedidos'], ['gastos', 'gastos'], ['cierres', 'cierres']]
          .map((c) => '<div class="unidad__cifra"><b>' + n[c[0]] + '</b><span>' + c[1] + '</span></div>')
          .join('') +
        '</div>' +
        '<div class="fila fila--fin mt-16"><button class="btn btn--fantasma" data-cerrar-ficha>Cerrar</button></div>',
    });
    U.$('[data-cerrar-ficha]', m.raiz).onclick = m.cerrar;
  }

  /* Alta rápida: nombre, tipo, estado, dirección, contacto y logo. Lo
     demás —nombre corto, horario, mesas, zonas…— queda en «Configuración
     avanzada», plegado, para no convertir el alta en un formulario enorme. */
  function editarSucursal(sucursalId) {
    if (!A.exigir('config_sucursales')) return;
    const s = sucursalId
      ? S.getSucursal(sucursalId)
      : { id: '', nombre: '', corto: '', tipoNegocio: NASCAR.TIPO_NEGOCIO_DEFECTO || 'restaurante',
          direccion: '', ciudad: '', telefono: '', whatsapp: '', horario: '', mapa: '', mesas: 10,
          color: 'azul', zonas: [], activa: true, branding: { logo: '', color: '' } };
    let logo = (s.branding && s.branding.logo) || '';

    const filaZona = (z, i) =>
      '<div class="fila" data-zona="' + i + '" style="gap:8px;margin-bottom:8px">' +
      '<input class="input crece" data-z-nombre placeholder="Nombre de la zona" value="' + U.esc(z.nombre || '') + '">' +
      '<input class="input" type="number" min="0" step="500" data-z-costo placeholder="Costo" ' +
      'value="' + Number(z.costo || 0) + '" style="width:110px">' +
      '<input class="input" type="number" min="0" step="1000" data-z-min placeholder="Mínimo" ' +
      'value="' + Number(z.min || 0) + '" style="width:110px">' +
      '<button class="btn btn--fantasma btn--xs" data-quitar-zona="' + i + '" ' +
      'style="border-color:var(--rojo);color:var(--rojo-claro)">✕</button></div>';

    const m = U.modal({
      titulo: sucursalId ? 'Editar unidad' : 'Nueva unidad / local',
      ancho: 620,
      contenido:
        '<label class="campo"><span>Nombre del local <i class="req">*</i></span>' +
        '<input class="input" id="scNombre" value="' + U.esc(s.nombre) + '" placeholder="Ej. COMIC\'ENDO AREPA"></label>' +

        '<div class="rejilla-2">' +
        '<label class="campo"><span>Tipo de negocio <i class="req">*</i></span>' +
        '<select class="select" id="scTipo">' +
        (NASCAR.TIPOS_NEGOCIO || [])
          .map((x) => '<option value="' + x.id + '"' + (x.id === s.tipoNegocio ? ' selected' : '') + '>' +
            x.icono + ' ' + U.esc(x.nombre) + '</option>')
          .join('') +
        '</select></label>' +
        '<label class="campo"><span>Estado</span>' +
        '<select class="select" id="scEstado">' +
        '<option value="activa"' + (s.activa !== false ? ' selected' : '') + '>Activa</option>' +
        '<option value="inactiva"' + (s.activa === false ? ' selected' : '') + '>Inactiva</option>' +
        '</select></label>' +
        '<label class="campo"><span>Dirección</span>' +
        '<input class="input" id="scDireccion" value="' + U.esc(s.direccion) + '"></label>' +
        '<label class="campo"><span>Teléfono</span>' +
        '<input class="input" id="scTelefono" value="' + U.esc(s.telefono) + '"></label>' +
        '<label class="campo"><span>WhatsApp</span>' +
        '<input class="input" id="scWhatsapp" value="' + U.esc(s.whatsapp || '') + '" placeholder="573001112233"></label>' +
        '<div class="campo"><span>Logo (opcional)</span>' +
        '<div class="unidad-logo-campo">' +
        '<span id="scLogoVista"></span>' +
        '<label class="btn btn--fantasma btn--xs" style="cursor:pointer">Subir logo' +
        '<input type="file" id="scLogo" accept="image/png,image/jpeg,image/webp" class="oculto"></label>' +
        '<button type="button" class="btn btn--fantasma btn--xs" id="scQuitarLogo">Quitar</button>' +
        '</div></div>' +
        '</div>' +
        '<p class="mini tenue" style="margin-top:-4px">Sin logo ni color propio, la unidad se ve con la identidad de la empresa.</p>' +

        '<details class="unidad-avanzada"' + (sucursalId ? ' open' : '') + '>' +
        '<summary>Configuración avanzada (opcional)</summary>' +
        '<div class="rejilla-2">' +
        '<label class="campo"><span>Nombre corto</span>' +
        '<input class="input" id="scCorto" value="' + U.esc(s.corto) + '" placeholder="Se genera solo si lo dejas vacío"></label>' +
        '<label class="campo"><span>Ciudad</span>' +
        '<input class="input" id="scCiudad" value="' + U.esc(s.ciudad || '') + '"></label>' +
        '<label class="campo"><span>Número de mesas</span>' +
        '<input class="input" type="number" min="0" max="200" id="scMesas" value="' + Number(s.mesas || 0) + '"></label>' +
        '<label class="campo"><span>Color propio de la unidad</span>' +
        '<input class="input mono" id="scMarcaColor" value="' + U.esc(s.branding.color || '') + '" placeholder="#RRGGBB (opcional)"></label>' +
        '<label class="campo"><span>Color de acento en la página pública</span>' +
        '<select class="select" id="scColor">' +
        [['azul', 'Azul'], ['rojo', 'Rojo']]
          .map(([v, x]) => '<option value="' + v + '"' + (v === s.color ? ' selected' : '') + '>' + x + '</option>')
          .join('') +
        '</select></label>' +
        '<label class="campo"><span>Horario</span>' +
        '<input class="input" id="scHorario" value="' + U.esc(s.horario) + '" placeholder="Lunes a Domingo · 11:00 a.m. – 10:00 p.m."></label>' +
        '</div>' +
        '<label class="campo"><span>Enlace del mapa</span>' +
        '<input class="input" id="scMapa" value="' + U.esc(s.mapa || '') + '" placeholder="https://maps.google.com/?q=…"></label>' +
        '<div class="campo"><span>Zonas de domicilio</span>' +
        '<div class="fila mini tenue" style="gap:8px;margin-bottom:6px">' +
        '<span class="crece">Zona</span><span style="width:110px">Costo</span>' +
        '<span style="width:110px">Pedido mínimo</span><span style="width:32px"></span></div>' +
        '<div id="scZonas">' + (s.zonas || []).map(filaZona).join('') + '</div>' +
        '<button class="btn btn--fantasma btn--xs mt-8" id="scAddZona">+ Agregar zona</button></div>' +
        '</details>' +

        '<div class="fila fila--fin">' +
        '<button class="btn btn--fantasma" id="scNo">Cancelar</button>' +
        '<button class="btn btn--rojo" id="scSi">' + (sucursalId ? 'Guardar' : 'Crear unidad') + '</button></div>',
    });

    function pintarLogo() {
      const tipo = S.getTipoNegocio(U.$('#scTipo', m.raiz).value);
      U.$('#scLogoVista', m.raiz).innerHTML = logo
        ? '<img class="unidad__logo" src="' + logo + '" alt="Logo">'
        : '<span class="unidad__logo unidad__logo--icono">' + tipo.icono + '</span>';
      U.$('#scQuitarLogo', m.raiz).classList.toggle('oculto', !logo);
    }
    pintarLogo();
    U.$('#scTipo', m.raiz).addEventListener('change', pintarLogo);
    U.$('#scQuitarLogo', m.raiz).onclick = function () {
      logo = '';
      pintarLogo();
    };
    U.$('#scLogo', m.raiz).addEventListener('change', function () {
      const archivo = this.files && this.files[0];
      if (!archivo) return;
      // Un logo no necesita más de 320 px: pesa poco y carga rápido en el portal
      U.comprimirImagen(archivo, { ladoMaximoPx: 320, pesoGuardadoMaximoKB: 250 })
        .then(function (res) {
          logo = res.dataUrl;
          pintarLogo();
        })
        .catch((err) => U.toast(err.message, 'error'));
    });

    let contadorZona = (s.zonas || []).length;
    U.$('#scAddZona', m.raiz).onclick = function () {
      U.$('#scZonas', m.raiz).insertAdjacentHTML('beforeend', filaZona({}, contadorZona++));
    };
    m.raiz.addEventListener('click', function (e) {
      const q = e.target.closest('[data-quitar-zona]');
      if (q) q.closest('[data-zona]').remove();
    });

    U.$('#scNo', m.raiz).onclick = m.cerrar;
    U.$('#scSi', m.raiz).onclick = function () {
      const nombre = U.$('#scNombre', m.raiz).value.trim();
      if (nombre.length < 2) return U.toast('Escribe el nombre del local.', 'error');
      const color = U.$('#scMarcaColor', m.raiz).value.trim();
      if (color && !/^#[0-9a-f]{6}$/i.test(color))
        return U.toast('El color propio debe tener el formato #RRGGBB.', 'error');

      const zonas = Array.prototype.slice
        .call(m.raiz.querySelectorAll('[data-zona]'))
        .map(function (f) {
          return {
            nombre: f.querySelector('[data-z-nombre]').value.trim(),
            costo: Number(f.querySelector('[data-z-costo]').value) || 0,
            min: Number(f.querySelector('[data-z-min]').value) || 0,
          };
        })
        .filter((z) => z.nombre);

      try {
        S.guardarSucursal({
          id: s.id || undefined,
          nombre: nombre,
          tipoNegocio: U.$('#scTipo', m.raiz).value,
          activa: U.$('#scEstado', m.raiz).value === 'activa',
          corto: U.$('#scCorto', m.raiz).value.trim(),
          direccion: U.$('#scDireccion', m.raiz).value.trim(),
          ciudad: U.$('#scCiudad', m.raiz).value.trim(),
          telefono: U.$('#scTelefono', m.raiz).value.trim(),
          whatsapp: U.$('#scWhatsapp', m.raiz).value.replace(/\D/g, ''),
          horario: U.$('#scHorario', m.raiz).value.trim(),
          mapa: U.$('#scMapa', m.raiz).value.trim(),
          mesas: Number(U.$('#scMesas', m.raiz).value) || 0,
          color: U.$('#scColor', m.raiz).value,
          zonas: zonas,
          branding: { logo: logo, color: color },
        });
      } catch (err) {
        return U.toast(err.message, 'error');
      }

      m.cerrar();
      U.toast(sucursalId ? 'Unidad actualizada.' : 'Unidad creada. Empieza con su carta y su stock vacíos.');
      avisarCambio();
    };
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

  /* Store ya emite su propio evento al escribir; esto refresca lo local. */
  function avisarCambio() {
    refrescar();
  }

  return {
    iniciar: iniciar,
    refrescar: refrescar,
  };
})();
