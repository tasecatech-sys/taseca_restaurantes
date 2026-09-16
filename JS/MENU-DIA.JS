/* ==========================================================================
   menu-dia.js · PRESENTACIÓN DEL MENÚ DEL DÍA

   Una sola forma de pintar el menú del día para las tres pantallas que lo
   ofrecen: la página pública (index.html), la mesa (mesa.html) y la toma
   de pedidos del mesero (panel). Así el menú armado y el del chef se ven
   y se piden igual en todas.

   Sólo PINTA y LEE lo que el cliente eligió. Qué se publica lo decide
   NASCAR.Store.getMenuPublico(): este archivo nunca escribe nada.
   ========================================================================== */

window.NASCAR = window.NASCAR || {};

NASCAR.MenuDia = (function () {
  'use strict';

  function esc(t) {
    return NASCAR.UI.esc(t == null ? '' : t);
  }
  function money(n) {
    return NASCAR.UI.money(n);
  }
  function buscar(lista, fn) {
    return Array.prototype.find.call(lista, fn);
  }

  const BADGE_HOY =
    '<span class="badge badge--linea" style="color:#fff;border-color:rgba(255,255,255,.5)">Hoy</span>';

  /* ---------------------------------------------------------------
     MENÚ DEL CHEF · una tarjeta por plato
     --------------------------------------------------------------- */
  function tarjetaChef(p, o) {
    const restantes =
      typeof p.cupos === 'number' && p.cupos > 0 ? Math.max(0, p.cupos - (p.vendidos || 0)) : null;

    // Los platos de antes traían su composición fija: se sigue mostrando
    const combo = [
      ['Sopa', p.sopa],
      ['Principio', p.principio],
      ['Proteína', p.proteina],
      ['Bebida', p.bebida],
    ].filter((c) => c[1]);

    return (
      '<article class="plato-dia plato-dia--chef">' +
      '<div class="plato-dia__head">' +
      '<div>' +
      '<span class="plato-dia__tipo">Menú del chef</span>' +
      '<h3>' +
      (p.emoji ? '<span class="plato-dia__emoji" aria-hidden="true">' + esc(p.emoji) + '</span>' : '') +
      esc(p.nombre) +
      '</h3>' +
      (o.sucursal ? '<span class="plato-dia__suc">📍 ' + esc(o.sucursal.nombre) + '</span>' : '') +
      '</div>' +
      BADGE_HOY +
      '</div>' +

      '<div class="plato-dia__body">' +
      (p.desc ? '<p class="plato-dia__desc">' + esc(p.desc) + '</p>' : '') +
      (combo.length
        ? '<ul class="combo">' +
          combo.map((c) => '<li><b>' + c[0] + '</b><span>' + esc(c[1]) + '</span></li>').join('') +
          '</ul>'
        : '') +

      '<div class="plato-dia__pie">' +
      '<div class="precio"><small>Precio</small>' + money(p.precio) + '</div>' +
      '<div class="derecha">' +
      (restantes !== null && restantes <= 10
        ? '<div class="cupos">Quedan ' + restantes + '</div>'
        : '<div class="plato-dia__disp">● Disponible</div>') +
      '<button class="btn btn--rojo btn--sm mt-8" data-add-dia="' + esc(p.id) + '">Agregar</button>' +
      '</div>' +
      '</div>' +

      '</div></article>'
    );
  }

  /* ---------------------------------------------------------------
     MENÚ ARMADO · categorías con opciones de radio
     --------------------------------------------------------------- */
  function nombreRadio(clave, menu, cat) {
    return 'md-' + clave + '-' + menu.menuId + '-' + cat.id;
  }

  /* Cuántas opciones se pueden elegir en la categoría. Lo dice el
     administrador por categoría (maxSeleccion); los menús anteriores no
     lo traen y valen 1, como siempre. */
  function maxDe(c) {
    const n = Math.floor(Number(c.maxSeleccion));
    return isFinite(n) && n >= 1 ? n : 1;
  }

  function reglaDe(c) {
    const max = maxDe(c);
    return (max > 1 ? 'Elige hasta ' + max : 'Elige 1') + (c.obligatoria ? ' · Obligatorio' : ' · Opcional');
  }

  /**
   * Las categorías y sus opciones. Se usa en la tarjeta pública, en la
   * mesa y en la toma de pedidos del mesero: una sola implementación.
   * `clave` separa los grupos cuando el mismo menú aparece dos veces en
   * la misma página.
   *
   * Con máximo 1 son botones de radio; con más, casillas que se bloquean
   * al llegar al tope. Al final va el aviso de "menú agregado", oculto
   * hasta que se agrega uno.
   */
  function camposArmado(menu, clave) {
    const k = clave || 'pub';
    return (
      '<div class="armado" data-clave="' + esc(k) + '">' +
      menu.armado.categorias
        .map(function (c) {
          const nombre = nombreRadio(k, menu, c);
          const max = maxDe(c);
          const multiple = max > 1;
          const tipo = multiple ? 'checkbox' : 'radio';

          return (
            /* data-armado-cat y no data-cat: la toma de pedidos del mesero
               ya usa [data-cat] para los filtros de la carta. */
            '<fieldset class="armado__cat" data-armado-cat="' + esc(c.id) + '" data-max="' + max + '"' +
            (c.obligatoria ? ' data-obligatoria="1"' : '') + '>' +
            '<legend class="armado__leyenda">' +
            '<span class="armado__titulo">' +
            (c.icono ? '<i aria-hidden="true">' + esc(c.icono) + '</i>' : '') +
            esc(c.nombre) +
            '</span>' +
            '<em class="armado__regla' + (c.obligatoria ? ' armado__regla--req' : '') + '">' +
            reglaDe(c) + '</em>' +
            '</legend>' +
            '<div class="armado__ops" role="' + (multiple ? 'group' : 'radiogroup') + '" aria-label="' +
            esc(c.nombre) + '"' + (c.obligatoria ? ' aria-required="true"' : '') + '>' +
            c.opciones
              .map(
                (op) =>
                  '<label class="armado__op"><input type="' + tipo + '" name="' + nombre + '" value="' +
                  esc(op.id) + '"><span>' + esc(op.nombre) + '</span></label>'
              )
              .join('') +
            // En una opcional de una sola opción también se puede no elegir nada
            (c.obligatoria || multiple
              ? ''
              : '<label class="armado__op armado__op--ninguna"><input type="radio" name="' + nombre +
                '" value="" checked><span>Sin ' + esc(c.nombre.toLowerCase()) + '</span></label>') +
            '</div>' +
            (multiple
              ? '<p class="armado__tope oculto">Puedes elegir máximo ' + max + ' opciones de ' + esc(c.nombre) + '.</p>'
              : '') +
            '<p class="armado__falta" role="alert">' +
            (multiple ? 'Elige al menos una opción de ' : 'Elige una opción de ') + esc(c.nombre) + '.</p>' +
            '</fieldset>'
          );
        })
        .join('') +
      '</div>' +

      '<div class="armado__hecho oculto" role="status">' +
      '<b>✓ Menú agregado</b>' +
      '<span class="mini tenue" data-cuenta-menus></span>' +
      '<button type="button" class="btn btn--rojo btn--sm" data-otro-menu>+ Agregar otro menú</button>' +
      '</div>'
    );
  }

  function tarjetaArmado(menu, o) {
    const a = menu.armado;
    const hayObligatorias = a.categorias.some((c) => c.obligatoria);

    return (
      '<article class="plato-dia plato-dia--armado" data-armado="' + esc(menu.menuId) +
      '" data-sucursal="' + Number(menu.sucursalId) + '">' +
      '<div class="plato-dia__head">' +
      '<div>' +
      '<span class="plato-dia__tipo">Menú armado</span>' +
      '<h3>' + esc(a.nombre) + '</h3>' +
      (o.sucursal ? '<span class="plato-dia__suc">📍 ' + esc(o.sucursal.nombre) + '</span>' : '') +
      '</div>' +
      BADGE_HOY +
      '</div>' +

      '<div class="plato-dia__body">' +
      (a.descripcion ? '<p class="plato-dia__desc">' + esc(a.descripcion) + '</p>' : '') +
      '<p class="armado__ayuda">Arma tu menú y agrégalo' +
      (hayObligatorias ? '. Las categorías marcadas como <b>obligatorio</b> son necesarias' : '') +
      '. Puedes agregar varios menús, uno por persona, cada uno con sus propias opciones.</p>' +
      camposArmado(menu, o.clave) +

      '<div class="plato-dia__pie">' +
      '<div class="precio"><small>Precio del menú</small>' + money(a.precio) + '</div>' +
      '<div class="derecha" data-acciones-armado>' +
      '<button class="btn btn--rojo btn--sm" data-add-armado="' + esc(menu.menuId) + '">Agregar al pedido</button>' +
      '</div>' +
      '</div>' +

      '</div></article>'
    );
  }

  /**
   * Tarjetas de UNA sucursal, con lo que getMenuPublico() devolvió:
   * las del chef o la del menú armado. '' si no hay nada publicado.
   *
   *   opciones.sucursal → si se pasa, cada tarjeta dice de qué sede es
   *   opciones.clave    → prefijo de los radios ('pub', 'mesa', …)
   */
  function tarjetas(menu, opciones) {
    const o = opciones || {};
    if (!menu || !menu.publicado) return '';
    return menu.tipo === 'armado'
      ? tarjetaArmado(menu, o)
      : menu.platos.map((p) => tarjetaChef(p, o)).join('');
  }

  /* Repinta sin perder lo que el cliente ya había marcado. El menú se
     vuelve a pintar cada vez que cambia algo guardado (un pedido desde
     otra pestaña, el administrador editando…): no puede borrarle la
     selección a quien está eligiendo. */
  function pintar(contenedor, html) {
    if (!contenedor) return;
    const marcadas = Array.prototype.map.call(
      contenedor.querySelectorAll('.armado input:checked'),
      (r) => [r.name, r.value]
    );
    contenedor.innerHTML = html;
    const entradas = contenedor.querySelectorAll('.armado input');
    marcadas.forEach(function (m) {
      const r = buscar(entradas, (x) => x.name === m[0] && x.value === m[1]);
      if (r) r.checked = true;
    });
    contenedor.querySelectorAll('.armado__cat').forEach(aplicarTope);
  }

  /* Con la categoría en su tope, lo que queda se deshabilita: el cliente
     ve POR QUÉ no puede marcar una tercera opción, en vez de recibir un
     aviso después de intentarlo. */
  function aplicarTope(fs) {
    const max = Number(fs.dataset.max) || 1;
    if (max <= 1) return;
    const entradas = Array.prototype.slice.call(fs.querySelectorAll('input[type="checkbox"]'));
    const marcadas = entradas.filter((x) => x.checked).length;
    const tope = marcadas >= max;

    entradas.forEach(function (x) {
      x.disabled = tope && !x.checked;
      const etiqueta = x.closest('.armado__op');
      if (etiqueta) etiqueta.classList.toggle('is-bloqueada', x.disabled);
    });
    const aviso = fs.querySelector('.armado__tope');
    if (aviso) aviso.classList.toggle('oculto', !tope);
  }

  /* Deja el configurador como recién abierto: sin selecciones, sin avisos
     y listo para otra combinación. Lo que ya se agregó vive en el carrito,
     no aquí: reiniciar NUNCA toca el pedido. */
  function reiniciar(raiz) {
    if (!raiz) return;
    raiz.querySelectorAll('.armado input').forEach(function (x) {
      x.disabled = false;
      // En una categoría opcional vuelve a quedar marcado el "Sin …"
      x.checked = x.type === 'radio' && x.value === '';
    });
    raiz.querySelectorAll('.armado__op').forEach((l) => l.classList.remove('is-bloqueada'));
    raiz.querySelectorAll('.armado__cat').forEach(function (fs) {
      fs.classList.remove('is-falta');
      const aviso = fs.querySelector('.armado__tope');
      if (aviso) aviso.classList.add('oculto');
    });

    const forma = raiz.querySelector('.armado');
    if (forma) forma.classList.remove('oculto');
    const acciones = raiz.querySelector('[data-acciones-armado]');
    if (acciones) acciones.classList.remove('oculto');
    const hecho = raiz.querySelector('.armado__hecho');
    if (hecho) hecho.classList.add('oculto');
  }

  /**
   * Se agregó una combinación al pedido: el configurador se limpia y se
   * ofrece "Agregar otro menú". La combinación anterior queda en el
   * carrito con su propio detalle; aquí no queda nada de ella.
   */
  function agregado(raiz, cuantos) {
    if (!raiz) return;
    reiniciar(raiz);

    const forma = raiz.querySelector('.armado');
    if (forma) forma.classList.add('oculto');
    const acciones = raiz.querySelector('[data-acciones-armado]');
    if (acciones) acciones.classList.add('oculto');

    const hecho = raiz.querySelector('.armado__hecho');
    if (!hecho) return;
    const cuenta = hecho.querySelector('[data-cuenta-menus]');
    if (cuenta)
      cuenta.textContent = cuantos
        ? cuantos === 1
          ? '1 menú en tu pedido'
          : cuantos + ' menús en tu pedido'
        : '';
    hecho.classList.remove('oculto');
  }

  /**
   * Lee lo elegido dentro de `raiz` (la tarjeta, la mesa o el bloque del
   * mesero).
   *
   *   → { ok, faltan: ['Sopa', …],
   *       elegidas: [{ categoria, opciones: [{ id, nombre }] }] }
   *
   * Una categoría obligatoria sin elegir queda marcada en rojo. Se
   * respeta el máximo de la categoría y sólo cuentan opciones que siguen
   * publicadas en `menu`.
   */
  function leerSeleccion(raiz, menu) {
    const r = { ok: true, faltan: [], elegidas: [] };
    if (!raiz || !menu || !menu.armado) return { ok: false, faltan: [], elegidas: [] };

    const bloque = raiz.matches && raiz.matches('.armado') ? raiz : raiz.querySelector('.armado');
    const clave = (bloque && bloque.dataset.clave) || 'pub';
    const entradas = raiz.querySelectorAll('.armado input');
    const grupos = raiz.querySelectorAll('.armado__cat');

    menu.armado.categorias.forEach(function (c) {
      const nombre = nombreRadio(clave, menu, c);
      const marcadas = Array.prototype.filter.call(
        entradas,
        (x) => x.name === nombre && x.checked && x.value
      );
      const opciones = marcadas
        .map((x) => c.opciones.find((o) => o.id === x.value))
        .filter(Boolean)
        .slice(0, maxDe(c))
        .map((o) => ({ id: o.id, nombre: o.nombre }));

      const falta = c.obligatoria && !opciones.length;
      const fs = buscar(grupos, (x) => x.dataset.armadoCat === c.id);
      if (fs) fs.classList.toggle('is-falta', falta);

      if (falta) {
        r.ok = false;
        r.faltan.push(c.nombre);
      }
      if (opciones.length) r.elegidas.push({ categoria: c.nombre, opciones: opciones });
    });

    return r;
  }

  /**
   * La línea de pedido de UNA combinación.
   *
   * El nombre es el del menú —así Ventas lo cuenta como un solo producto—
   * y lo elegido va en `detalle`, aparte de las notas del cliente para que
   * una nota nunca lo borre. El refId lleva las opciones ordenadas: dos
   * combinaciones distintas son dos líneas independientes, y la misma
   * combinación repetida suma cantidad.
   */
  function itemArmado(menu, elegidas) {
    const ids = [];
    elegidas.forEach((e) => e.opciones.forEach((o) => ids.push(o.id)));

    return {
      refId: 'armado:' + menu.menuId + ':' + ids.slice().sort().join('.'),
      nombre: menu.armado.nombre,
      detalle: elegidas
        .map((e) => e.categoria + ': ' + e.opciones.map((o) => o.nombre).join(', '))
        .join(' · '),
      precio: menu.armado.precio,
      origen: 'armado',
      sucursalId: menu.sucursalId,
    };
  }

  /* Al marcar una opción su categoría deja de estar en rojo y se recalcula
     el tope. "Agregar otro menú" reinicia el configurador: una sola
     implementación para el portal, la mesa y el mesero. */
  function conectar(raiz) {
    if (!raiz || !raiz.dataset || raiz.dataset.menuDiaListo === '1') return;
    raiz.dataset.menuDiaListo = '1';

    raiz.addEventListener('change', function (e) {
      const x = e.target;
      if (!x || (x.type !== 'radio' && x.type !== 'checkbox')) return;
      const fs = x.closest('.armado__cat');
      if (!fs) return;
      fs.classList.remove('is-falta');
      aplicarTope(fs);
    });

    raiz.addEventListener('click', function (e) {
      const b = e.target.closest('[data-otro-menu]');
      if (!b) return;
      reiniciar(b.closest('[data-armado], [data-armado-mesero]') || raiz);
    });
  }

  return {
    tarjetas: tarjetas,
    camposArmado: camposArmado,
    pintar: pintar,
    leerSeleccion: leerSeleccion,
    itemArmado: itemArmado,
    conectar: conectar,
    reiniciar: reiniciar,
    agregado: agregado,
    maxDe: maxDe,
  };
})();
