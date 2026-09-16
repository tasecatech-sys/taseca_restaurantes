/* ==========================================================================
   NASCAR · inventario.js
   Módulo de Cierre de Caja e Inventario.

   Dos consumidores, un mismo archivo:

     1. cierre.html  -> Inventario.iniciarRegistro(raiz)
        Pantalla de la mesera. Registra los saldos físicos al terminar
        la jornada. Pensada para celular.

     2. empleados.html -> Inventario.iniciarPanel(opciones)
        Pestañas de la administradora: Cierres, Cruce y Entradas.

   Toda la persistencia pasa por NASCAR.Store. Este archivo no toca
   localStorage en ningún momento.
   ========================================================================== */

window.NASCAR = window.NASCAR || {};

NASCAR.Inventario = (function () {
  'use strict';

  const S = NASCAR.Store;
  const U = NASCAR.UI;

  /* =================================================================
     HELPERS COMPARTIDOS
     ================================================================= */
  function nombreArea(area) {
    const a = NASCAR.AREAS.find((x) => x.id === area);
    return a ? a.nombre : area;
  }
  function iconoArea(area) {
    const a = NASCAR.AREAS.find((x) => x.id === area);
    return a ? a.icono : '📦';
  }
  function nombreEstado(estado) {
    const e = NASCAR.ESTADOS_CIERRE.find((x) => x.id === estado);
    return e ? e.nombre : estado;
  }
  function badgeEstado(estado) {
    const e = NASCAR.ESTADOS_CIERRE.find((x) => x.id === estado);
    return '<span class="badge ' + (e ? e.badge : 'badge--gris') + '">' + (e ? e.nombre : estado) + '</span>';
  }

  /* Fecha corta para tablas: 28/08/2026 */
  function fechaCorta(iso) {
    if (!iso) return '—';
    const [a, m, d] = iso.split('-');
    return d + '/' + m + '/' + a;
  }

  /* Etiqueta visual de la diferencia. Nunca oculta el número. */
  function etiquetaDF(fila) {
    if (!fila.registrado) return '<span class="df df--sin">Sin registrar</span>';
    if (fila.DF === 0) return '<span class="df df--ok">🟢 OK</span>';
    if (fila.DF > 0) return '<span class="df df--sobrante">🟡 Sobrante ' + fila.DF + '</span>';
    return '<span class="df df--faltante">🔴 Faltante ' + Math.abs(fila.DF) + '</span>';
  }

  function agrupar(lista, clave) {
    const g = {};
    lista.forEach(function (x) {
      const k = clave(x);
      (g[k] = g[k] || []).push(x);
    });
    return g;
  }

  /* =================================================================
     ===============  1. PANTALLA DE LA MESERA  ======================
     ================================================================= */
  /**
   * Markup de la pantalla de registro.
   *
   * Vive aquí y no en el HTML porque la usan dos sitios: la página suelta
   * `cierre.html` (la que abre la mesera desde su celular) y la pestaña
   * 📦 Cierre del panel. Tenerlo en un solo lugar evita que las dos
   * versiones se separen con el tiempo.
   */
  function plantillaRegistro() {
    return (
      /* ---------- PASO 1 · Datos del cierre ---------- */
      '<section id="paso1">' +
      '<div class="titulo-seccion" style="margin-bottom:22px">' +
      '<span class="titulo-seccion__kicker">Paso 1 de 2</span>' +
      '<h2 style="font-size:30px">Datos del cierre</h2>' +
      '<p>Confirma a qué jornada corresponde este conteo antes de empezar.</p>' +
      '</div>' +

      '<div class="caja mb-24">' +
      '<label class="campo"><span>Sucursal <i class="req">*</i></span>' +
      '<select class="select" id="cSucursal"></select></label>' +
      '<label class="campo"><span>Fecha del cierre <i class="req">*</i></span>' +
      '<input class="input" type="date" id="cFecha"></label>' +
      '<div id="avisoMadrugada"></div>' +
      /* Sale del usuario que entró: el cierre lo firma quien está
         dentro, no un nombre escrito a mano. */
      '<label class="campo"><span>Quién registra</span>' +
      '<input class="input" id="cUsuario" autocomplete="name" readonly ' +
      'title="Es el usuario con el que entraste"></label>' +
      '</div>' +

      '<div class="caja mb-24">' +
      '<h3 style="font-size:17px;margin-bottom:14px">Área que vas a contar <i class="req rojo">*</i></h3>' +
      '<div class="inv-areas" id="cAreas"></div>' +
      '<p class="mini tenue mt-16" style="margin-bottom:0">' +
      'Si vas a contar las dos, elige <b>Comidas + Bar</b>: se guardan como dos cierres ' +
      'separados, uno por área.</p>' +
      '</div>' +

      '<div id="avisoExistente"></div>' +
      '<button class="btn btn--rojo btn--bloque" id="btnEmpezar" disabled>Empezar conteo →</button>' +

      '<div class="caja mt-24" id="cajaMisCierres">' +
      '<h3 style="font-size:17px">Cierres registrados</h3>' +
      '<div id="misCierres"></div>' +
      '</div>' +
      '</section>' +

      /* ---------- PASO 2 · Registro de saldos ---------- */
      '<section id="paso2" class="oculto">' +
      '<div class="inv-contexto" id="cContexto"></div>' +

      '<div class="inv-progreso">' +
      '<div class="inv-progreso__texto">' +
      '<div class="inv-progreso__n" id="progN">0 <small>/ 0 productos registrados</small></div>' +
      '<div class="mini tenue" id="progPend"></div>' +
      '</div>' +
      '<div class="inv-progreso__pista">' +
      '<div class="inv-progreso__relleno" id="progBarra" style="width:0%"></div>' +
      '</div></div>' +

      '<div class="barra-herramientas">' +
      '<label class="campo crece" style="margin:0"><span>Buscar producto</span>' +
      '<input class="input" id="cBuscar" placeholder="Código o nombre…"></label>' +
      '<button class="btn btn--fantasma btn--sm" id="btnSoloPend">Ver sólo pendientes</button>' +
      '<button class="btn btn--fantasma btn--sm" id="btnCeros">Poner 0 a los pendientes</button>' +
      '</div>' +

      '<div id="cLista"></div>' +

      '<p class="mini tenue centro mt-24">Sólo tienes que escribir cuánto queda físicamente de ' +
      'cada producto. Los cálculos los hace el sistema después.</p>' +
      '</section>' +

      /* ---------- Barra fija de guardado ---------- */
      '<div class="inv-guardar oculto" id="barraGuardar">' +
      '<div class="contenedor inv-guardar__inner">' +
      '<button class="btn btn--fantasma btn--sm" id="btnVolver">←<span class="txt-ancho"> Cambiar datos</span></button>' +
      '<div class="crece"></div>' +
      '<button class="btn btn--fantasma btn--sm" id="btnBorrador">💾<span class="txt-ancho"> Guardar</span> borrador</button>' +
      '<button class="btn btn--rojo" id="btnGuardar">🏁 Guardar<span class="txt-ancho"> cierre</span></button>' +
      '</div></div>'
    );
  }

  /* Pantalla de entrada de la página suelta de cierre. Usa el mismo
     login del sistema —A.entrar()— así que no hay un segundo mecanismo
     de acceso: es el usuario de siempre, con su rol de siempre. */
  function pedirIdentificacion(raiz) {
    const A = NASCAR.Auth;
    raiz.classList.add('inv-main');
    raiz.innerHTML =
      '<div class="login-caja" style="margin:4vh auto">' +
      '<h3 style="margin:0 0 6px">Identifícate para registrar el cierre</h3>' +
      '<p class="mini tenue mb-24">El cierre queda firmado a tu nombre, así que ' +
      'entra con tu usuario. Si eres mesera, es el mismo con el que tomas los pedidos.</p>' +
      '<div id="avisoCierre"></div>' +
      '<label class="campo" style="text-align:left"><span>Usuario</span>' +
      '<input class="input" id="ciUsuario" autocomplete="username" autocapitalize="off"></label>' +
      '<label class="campo" style="text-align:left"><span>PIN</span>' +
      '<input class="pin-input" id="ciPin" type="password" inputmode="numeric" maxlength="6" ' +
      'placeholder="••••" autocomplete="current-password"></label>' +
      '<button class="btn btn--rojo btn--bloque mt-8" id="ciEntrar">Entrar</button>' +
      '</div>';

    const entrar = function () {
      const u = raiz.querySelector('#ciUsuario').value.trim();
      const pin = raiz.querySelector('#ciPin').value;
      raiz.querySelector('#ciPin').value = '';

      if (!A.entrar(u, pin)) {
        U.toast('Usuario o PIN incorrectos.', 'error');
        return raiz.querySelector('#ciPin').focus();
      }
      // Ya identificado: se vuelve a montar, y ahora sí pasa la puerta.
      iniciarRegistro(raiz);
    };

    raiz.querySelector('#ciEntrar').addEventListener('click', entrar);
    raiz.querySelector('#ciPin').addEventListener('keydown', (e) => e.key === 'Enter' && entrar());
    raiz.querySelector('#ciUsuario').addEventListener('keydown', function (e) {
      if (e.key === 'Enter') raiz.querySelector('#ciPin').focus();
    });
    raiz.querySelector('#ciUsuario').focus();
  }

  /* Entró alguien, pero su rol no registra cierres. */
  function sinPermiso(raiz) {
    const A = NASCAR.Auth;
    const u = A.getUsuarioActual();
    raiz.classList.add('inv-main');
    raiz.innerHTML =
      '<div class="caja centro">' +
      '<div style="font-size:40px">🔒</div>' +
      '<h3>Acceso no autorizado</h3>' +
      '<p class="tenue">Estás como <b>' + U.esc(u.nombre) + '</b> (' +
      U.esc(A.nombreRol(u.rol)) + '), y ese perfil no registra cierres de inventario.</p>' +
      '<button class="btn btn--fantasma mt-16" id="ciSalir">Entrar con otro usuario</button>' +
      '</div>';

    raiz.querySelector('#ciSalir').addEventListener('click', function () {
      S.logout();
      iniciarRegistro(raiz);
    });
  }

  function iniciarRegistro(raiz) {
    if (!raiz) return;

    /* Acceso directo por URL. `cierre.html` es una dirección que se
       reparte por WhatsApp, así que alguien puede abrirla en una empresa
       que no contrató el módulo. Aquí no se monta nada: se dice por qué
       y se acabó. Ocultar la pestaña del panel no habría bastado. */
    if (!S.hasModule('cierre')) {
      raiz.classList.add('inv-main');
      raiz.innerHTML =
        '<div class="caja centro">' +
        '<div style="font-size:40px">🔒</div>' +
        '<h3>Módulo no habilitado</h3>' +
        '<p class="tenue">El cierre de inventario no está incluido en el plan de ' +
        U.esc((S.getEmpresaActual() || {}).nombre || 'esta empresa') + '.</p>' +
        '<a class="btn btn--fantasma mt-16" href="index.html">Volver</a>' +
        '</div>';
      return;
    }

    /* ---------------------------------------------------------------
       QUIÉN REGISTRA

       El cierre lo firma una persona con nombre y apellido, así que hay
       que identificarse antes de tocarlo. La mesera entra con SU perfil
       —rol mesero, que lleva el permiso `cierres_registrar`— y el cierre
       queda a su nombre.

       Esto vale igual para la página suelta `cierre.html`, que es una
       dirección que se reparte por WhatsApp: allí se pinta el login
       aquí mismo, para que no haya que rebotar por otra pantalla.

       Desde la pestaña 📦 Cierre del panel esto no se nota: quien llegó
       hasta ahí ya entró.
       --------------------------------------------------------------- */
    const Auth = NASCAR.Auth;
    if (Auth && !Auth.getUsuarioActual()) return pedirIdentificacion(raiz);
    if (Auth && !Auth.puede('cierres_registrar')) return sinPermiso(raiz);

    // Si el contenedor viene vacío (la pestaña del panel), se monta aquí.
    if (!raiz.querySelector('#paso1')) {
      raiz.classList.add('inv-main');
      raiz.innerHTML = plantillaRegistro();
    }

    /* En `cierre.html` la barra de guardar puede estar fuera del <main>,
       por eso se busca primero dentro de la raíz y luego en el ámbito. */
    const AMBITO = raiz.closest('[data-vista]') || document;
    const $ = (s) => raiz.querySelector(s) || AMBITO.querySelector(s);

    const A = NASCAR.Auth;
    const sesion = A ? A.getUsuarioActual() : null;

    /* --- Estado de la pantalla --- */
    const st = {
      // Si quien entró tiene sucursal asignada se propone la suya.
      sucursalId: (A && A.sucursalDelUsuario()) || U.sucursalPorDefectoId(),
      fechaCierre: S.hoyOperativo(),
      areas: [], // ['comidas'] | ['bar'] | ['comidas','bar']
      usuario: sesion ? sesion.nombre : '',
      saldos: {}, // codigo -> número | null
      edicion: {}, // area -> id del cierre que se está corrigiendo
      soloPendientes: false,
      busqueda: '',
    };

    /* El cierre es de UNA unidad y sólo cuenta SU catálogo. Dentro del
       panel es la unidad activa (se cambia arriba); en la página suelta
       cierre.html se elige aquí. Un usuario asignado a una unidad registra
       siempre en la suya. */
    const enPanel = !!raiz.closest('[data-panel]');
    let unidadContexto = S.unidadActivaId();

    /* ---------------------------------------------------------------
       PASO 1 · Datos del cierre
       --------------------------------------------------------------- */
    function pintarPaso1() {
      $('#cSucursal').innerHTML = NASCAR.SUCURSALES.map(
        (s) => '<option value="' + s.id + '">' + U.esc(s.nombre) + '</option>'
      ).join('');
      $('#cSucursal').value = st.sucursalId;
      $('#cSucursal').disabled = enPanel || !!(A && A.sucursalDelUsuario());
      $('#cFecha').value = st.fechaCierre;

      // La fecha de hoy operativo es el tope: no se cierra el futuro.
      $('#cFecha').max = S.hoyOperativo();

      $('#cAreas').innerHTML = [
        opcionArea(['comidas'], '🍽️', 'Comidas', contarProductos('comidas') + ' productos'),
        opcionArea(['bar'], '🍺', 'Bar', contarProductos('bar') + ' productos'),
        opcionArea(['comidas', 'bar'], '📦', 'Comidas + Bar', 'Registrar las dos'),
      ].join('');

      // El nombre de quien está conectado viene puesto
      $('#cUsuario').value = st.usuario;

      pintarAvisoMadrugada();
      pintarAvisoExistente();
      pintarMisCierres();
      actualizarBotonEmpezar();
    }

    /* Consulta de los cierres ya registrados en esa sucursal.
       Sólo lectura: el cruce con las ventas es cosa de administración. */
    function pintarMisCierres() {
      const cont = $('#misCierres');
      if (!cont) return;
      const lista = S.getCierres({ sucursalId: st.sucursalId }).slice(0, 8);

      if (!lista.length) {
        cont.innerHTML =
          '<p class="mini tenue" style="margin:0">Todavía no hay cierres registrados en esta sucursal.</p>';
        return;
      }

      cont.innerHTML =
        '<div class="tabla-wrap"><table class="tabla" style="min-width:0"><tbody>' +
        lista
          .map(
            (c) =>
              '<tr><td><b>' + fechaCorta(c.fechaCierre) + '</b><br>' +
              '<span class="mini tenue">' + U.hora(c.fechaRegistro) + '</span></td>' +
              '<td>' + iconoArea(c.area) + ' ' + nombreArea(c.area) + '</td>' +
              '<td class="mini">' + U.esc(c.usuarioNombre) + '</td>' +
              '<td>' + badgeEstado(c.estado) + '</td>' +
              '<td class="derecha"><button class="btn btn--fantasma btn--xs" ' +
              'data-consultar="' + c.id + '">Ver</button></td></tr>'
          )
          .join('') +
        '</tbody></table></div>';
    }

    function contarProductos(area) {
      return S.getProductosInventario({ area: area, sucursalId: st.sucursalId }).length;
    }

    function opcionArea(areas, icono, titulo, sub) {
      const activo = areas.join(',') === st.areas.join(',');
      return (
        '<button type="button" class="inv-area' + (activo ? ' is-activa' : '') + '" ' +
        'data-areas="' + areas.join(',') + '">' +
        '<i>' + icono + '</i><b>' + titulo + '</b><span>' + U.esc(sub) + '</span></button>'
      );
    }

    /* Aviso clave: si se está registrando de madrugada, se explica por qué
       la fecha propuesta es la del día anterior. */
    function pintarAvisoMadrugada() {
      const cont = $('#avisoMadrugada');
      const ahora = new Date();
      const enMadrugada = ahora.getHours() < S.horaCorte();

      let html =
        '<div class="caja-datos" style="margin-top:0">' +
        '<div class="linea"><span class="tenue">Jornada del cierre</span>' +
        '<b>' + U.fechaLarga(st.fechaCierre) + '</b></div>' +
        '<div class="linea"><span class="tenue">Se registra</span>' +
        '<b>' + ahora.toLocaleString('es-CO', {
          day: '2-digit', month: '2-digit', year: 'numeric',
          hour: '2-digit', minute: '2-digit',
        }) + '</b></div>';

      if (enMadrugada) {
        html +=
          '<p class="mini ambar" style="margin:8px 0 0">' +
          'Son las ' + ahora.toLocaleTimeString('es-CO', { hour: '2-digit', minute: '2-digit' }) +
          ', así que este conteo corresponde a la jornada de <b>' + fechaCorta(st.fechaCierre) +
          '</b>. Si no es así, cambia la fecha arriba.</p>';
      }
      html += '</div>';
      cont.innerHTML = html;
    }

    /* Nunca se crea un duplicado en silencio: si ya existe un cierre para
       esa sucursal + fecha + área, se avisa y se ofrece consultarlo o
       corregirlo. */
    function pintarAvisoExistente() {
      const cont = $('#avisoExistente');
      if (!st.areas.length) return (cont.innerHTML = '');

      const suc = U.sucursal(st.sucursalId);
      const existentes = st.areas
        .map((a) => S.buscarCierre(st.sucursalId, st.fechaCierre, a))
        .filter(Boolean);

      if (!existentes.length) {
        st.edicion = {};
        return (cont.innerHTML = '');
      }

      cont.innerHTML = existentes
        .map(function (c) {
          const revisado = c.estado === 'revisado';
          const borrador = c.estado === 'borrador';
          return (
            '<div class="caja-datos mb-16" style="border-color:var(--ambar)">' +
            '<b class="ambar">' +
            (borrador ? 'Tienes un cierre a medias' : 'Ya existe un cierre registrado') + '</b>' +
            '<p class="mini" style="margin:6px 0 10px">' +
            U.esc(suc.nombre) + ' — ' + nombreArea(c.area) + ' — ' + fechaCorta(c.fechaCierre) +
            '<br><span class="tenue">Registrado por ' + U.esc(c.usuarioNombre) + ' a las ' +
            U.hora(c.fechaRegistro) + ' · ' + nombreEstado(c.estado) + ' · ' +
            c.productos.length + ' productos</span></p>' +
            '<div class="fila">' +
            '<button class="btn btn--fantasma btn--xs" data-consultar="' + c.id + '">Consultar</button>' +
            (revisado
              ? '<span class="mini tenue">Ya fue revisado por administración: no se puede corregir.</span>'
              : '<button class="btn btn--azul btn--xs" data-corregir="' + c.id + '">' +
                (borrador ? 'Continuar este cierre' : 'Corregir este cierre') + '</button>') +
            '</div></div>'
          );
        })
        .join('');
    }

    function actualizarBotonEmpezar() {
      const suc = U.sucursal(st.sucursalId);
      const bloqueado = st.areas.some(function (a) {
        const c = S.buscarCierre(st.sucursalId, st.fechaCierre, a);
        return c && c.estado === 'revisado' && !st.edicion[a];
      });
      const listo = st.areas.length > 0 && !!st.fechaCierre && !!st.sucursalId && !bloqueado;

      const btn = $('#btnEmpezar');
      btn.disabled = !listo;
      btn.textContent = !st.areas.length
        ? 'Elige un área para continuar'
        : bloqueado
        ? 'Ese cierre ya fue revisado'
        : 'Empezar conteo · ' + suc.corto + ' → ';
    }

    /* ---------------------------------------------------------------
       PASO 2 · Registro de saldos
       --------------------------------------------------------------- */
    function productosDelCierre() {
      let lista = [];
      st.areas.forEach(function (a) {
        lista = lista.concat(S.getProductosInventario({ area: a, sucursalId: st.sucursalId }));
      });
      return lista;
    }

    function irAPaso2() {
      // Precargar saldos si se está corrigiendo un cierre existente
      st.saldos = {};
      st.areas.forEach(function (a) {
        const existente = S.buscarCierre(st.sucursalId, st.fechaCierre, a);
        if (existente && existente.estado !== 'revisado') {
          st.edicion[a] = existente.id;
          existente.productos.forEach((p) => (st.saldos[p.codigo] = p.saldo));
        }
      });

      /* Quien firma es el usuario de la sesión, no lo que hubiera en el
         campo: éste es de sólo lectura y sale de ahí. */
      st.usuario = (sesion && sesion.nombre) || ($('#cUsuario').value || '').trim();

      $('#paso1').classList.add('oculto');
      $('#paso2').classList.remove('oculto');
      $('#barraGuardar').classList.remove('oculto');

      pintarContexto();
      pintarLista();
      window.scrollTo(0, 0);
    }

    function volverAPaso1() {
      $('#paso2').classList.add('oculto');
      $('#barraGuardar').classList.add('oculto');
      $('#paso1').classList.remove('oculto');
      pintarPaso1();
      window.scrollTo(0, 0);
    }

    function pintarContexto() {
      const suc = U.sucursal(st.sucursalId);
      const corrigiendo = Object.keys(st.edicion).length > 0;

      $('#cContexto').innerHTML =
        dato('Sucursal', suc.corto) +
        dato('Jornada', fechaCorta(st.fechaCierre)) +
        dato('Área', st.areas.map(nombreArea).join(' + ')) +
        dato('Registra', st.usuario || 'Mesera') +
        (corrigiendo ? dato('Modo', 'Corrección') : '');
    }

    function dato(etiqueta, valor) {
      return (
        '<div class="inv-contexto__dato"><span>' + U.esc(etiqueta) + '</span>' +
        '<b>' + U.esc(valor) + '</b></div>'
      );
    }

    function pintarLista() {
      const todos = productosDelCierre();
      const q = st.busqueda.trim().toLowerCase();

      let visibles = todos;
      if (q)
        visibles = visibles.filter(
          (p) => p.nombre.toLowerCase().includes(q) || p.codigo.toLowerCase().includes(q)
        );
      if (st.soloPendientes)
        visibles = visibles.filter((p) => !esRegistrado(p.codigo));

      const cont = $('#cLista');

      if (!visibles.length) {
        cont.innerHTML =
          '<div class="vacio">' +
          (st.soloPendientes
            ? '<div class="vacio__ico">✅</div><h3>No queda nada pendiente</h3>' +
              '<p class="mini">Ya registraste todos los productos.</p>'
            : '<div class="vacio__ico">🔍</div><h3>Sin resultados</h3>' +
              '<p class="mini">Ningún producto coincide con la búsqueda.</p>') +
          '</div>';
        actualizarProgreso();
        return;
      }

      // Agrupado por área y, dentro, por categoría
      const porArea = agrupar(visibles, (p) => p.area);
      let html = '';

      st.areas.forEach(function (area) {
        const deArea = porArea[area];
        if (!deArea || !deArea.length) return;

        if (st.areas.length > 1) {
          html +=
            '<div class="prod-grupo"><div class="prod-grupo__titulo" style="font-size:15px;color:var(--blanco)">' +
            iconoArea(area) + ' ' + nombreArea(area) + '</div></div>';
        }

        const porCat = agrupar(deArea, (p) => p.categoria);
        Object.keys(porCat).forEach(function (cat) {
          html +=
            '<div class="prod-grupo"><div class="prod-grupo__titulo">' + U.esc(cat) + '</div>' +
            '<div class="prod-lista">' +
            porCat[cat].map(tarjetaProducto).join('') +
            '</div></div>';
        });
      });

      cont.innerHTML = html;
      actualizarProgreso();
    }

    function esRegistrado(codigo) {
      const v = st.saldos[codigo];
      return v !== undefined && v !== null && v !== '';
    }

    function tarjetaProducto(p) {
      const valor = esRegistrado(p.codigo) ? st.saldos[p.codigo] : '';
      return (
        '<div class="prod-card' + (esRegistrado(p.codigo) ? ' is-registrado' : '') +
        '" data-card="' + p.codigo + '">' +
        '<div class="prod-card__info">' +
        '<div class="prod-card__codigo">' + U.esc(p.codigo) + '</div>' +
        '<div class="prod-card__nombre">' + U.esc(p.nombre) + '</div>' +
        '<div class="prod-card__unidad">Saldo físico en ' + U.esc(p.unidad || 'unidades') + '</div>' +
        '</div>' +
        '<div class="stepper">' +
        '<button type="button" data-menos="' + p.codigo + '" aria-label="Restar uno">−</button>' +
        '<input type="number" inputmode="numeric" min="0" step="1" ' +
        'class="' + (esRegistrado(p.codigo) ? '' : 'is-vacio') + '" ' +
        'data-saldo="' + p.codigo + '" value="' + valor + '" placeholder="—" ' +
        'aria-label="Saldo de ' + U.esc(p.nombre) + '">' +
        '<button type="button" data-mas="' + p.codigo + '" aria-label="Sumar uno">+</button>' +
        '</div></div>'
      );
    }

    function actualizarProgreso() {
      const todos = productosDelCierre();
      const hechos = todos.filter((p) => esRegistrado(p.codigo)).length;
      const total = todos.length;
      const pct = total ? (hechos / total) * 100 : 0;

      $('#progN').innerHTML = hechos + ' <small>/ ' + total + ' productos registrados</small>';
      $('#progPend').textContent =
        hechos === total ? '¡Todo listo!' : total - hechos + ' pendientes';

      const barra = $('#progBarra');
      barra.style.width = pct + '%';
      barra.classList.toggle('is-completo', hechos === total && total > 0);
    }

    /* Cambia el saldo de un producto y refresca sólo su tarjeta.
       Repintar toda la lista en cada pulsación haría perder el foco. */
    function fijarSaldo(codigo, valor, repintarTarjeta) {
      if (valor === '' || valor === null || valor === undefined) {
        st.saldos[codigo] = null;
      } else {
        const n = Math.floor(Number(valor));
        st.saldos[codigo] = isFinite(n) && n >= 0 ? n : 0;
      }

      const card = $('[data-card="' + codigo + '"]');
      if (card) {
        card.classList.toggle('is-registrado', esRegistrado(codigo));
        const input = card.querySelector('[data-saldo]');
        input.classList.toggle('is-vacio', !esRegistrado(codigo));
        if (repintarTarjeta) input.value = esRegistrado(codigo) ? st.saldos[codigo] : '';
      }
      actualizarProgreso();
    }

    /* ---------------------------------------------------------------
       GUARDAR
       --------------------------------------------------------------- */
    function intentarGuardar() {
      const todos = productosDelCierre();
      const hechos = todos.filter((p) => esRegistrado(p.codigo));
      const pendientes = todos.length - hechos.length;

      if (!hechos.length)
        return U.toast('Registra al menos un producto antes de guardar.', 'error');

      const suc = U.sucursal(st.sucursalId);
      const areasTexto = st.areas.map(nombreArea).join(' y ');

      const cuerpo =
        '<p>¿Confirmas el cierre de inventario de <b>' + U.esc(suc.nombre) + '</b> — ' +
        '<b>' + U.esc(areasTexto) + '</b> correspondiente al <b>' + fechaCorta(st.fechaCierre) + '</b>?</p>' +

        '<div class="caja-datos">' +
        '<div class="linea"><span class="tenue">Productos registrados</span><b>' + hechos.length + '</b></div>' +
        '<div class="linea"><span class="tenue">Sin registrar</span><b class="' +
        (pendientes ? 'ambar' : 'verde') + '">' + pendientes + '</b></div>' +
        '<div class="linea"><span class="tenue">Registra</span><b>' + U.esc(st.usuario || 'Mesera') + '</b></div>' +
        '</div>' +

        (pendientes
          ? '<div class="caja-datos" style="border-color:var(--ambar)">' +
            '<b class="ambar">Quedan ' + pendientes + ' productos sin registrar</b>' +
            '<p class="mini tenue" style="margin:4px 0 0">Los productos sin saldo no se guardan y ' +
            'aparecerán como “sin registrar” en el cruce. Puedes volver y completarlos.</p></div>'
          : '') +

        '<label class="campo mt-16"><span>Observaciones (opcional)</span>' +
        '<textarea class="textarea" id="gObs" placeholder="Novedades del turno, roturas, cortesías…"></textarea></label>' +

        '<div class="fila fila--fin mt-16">' +
        '<button class="btn btn--fantasma" id="gNo">Cancelar</button>' +
        '<button class="btn btn--rojo" id="gSi">Confirmar cierre</button></div>';

      const m = U.modal({ titulo: 'Confirmar cierre', ancho: 480, contenido: cuerpo });

      U.$('#gNo', m.raiz).onclick = m.cerrar;
      U.$('#gSi', m.raiz).onclick = function () {
        const obs = U.$('#gObs', m.raiz).value.trim();
        m.cerrar();
        guardarDefinitivo(obs);
      };
    }

    function guardarDefinitivo(observaciones, estado) {
      /* El MÓDULO se exige siempre, haya sesión o no: si la empresa no
         contrató Cierre, no se guarda ni desde la página suelta. */
      if (A && !A.exigirModulo('cierre')) return;

      /* Y el PERMISO también, siempre. Ya no hay camino sin sesión:
         para llegar hasta aquí hubo que identificarse, y esta línea es
         la última barrera por si alguien llamara la función a mano. */
      if (A && !A.exigir('cierres_registrar')) return;

      estado = estado || 'completado';
      const resultados = [];

      try {
        st.areas.forEach(function (area) {
          // Sólo los productos de esta área que tengan saldo
          const productos = S.getProductosInventario({ area: area, sucursalId: st.sucursalId })
            .filter((p) => esRegistrado(p.codigo))
            .map((p) => ({ codigo: p.codigo, nombre: p.nombre, saldo: st.saldos[p.codigo] }));

          if (!productos.length) return; // esa área no se contó

          const datos = {
            sucursalId: st.sucursalId,
            fechaCierre: st.fechaCierre,
            area: area,
            // Queda registrado quién lo hizo, con su id si hay sesión
            usuarioId: sesion ? sesion.usuarioId : null,
            usuarioNombre: st.usuario || (sesion ? sesion.nombre : 'Mesera'),
            estado: estado,
            productos: productos,
            observaciones: observaciones,
          };

          if (st.edicion[area]) {
            const previo = S.getCierre(st.edicion[area]);
            const eraBorrador = previo && previo.estado === 'borrador';
            S.actualizarCierre(st.edicion[area], {
              productos: productos,
              observaciones: observaciones,
              usuarioNombre: datos.usuarioNombre,
              // Un borrador que se termina pasa a completado; lo que ya
              // estaba completado no se degrada al guardar otro borrador.
              estado: estado === 'borrador' && !eraBorrador ? undefined : estado,
              motivo:
                estado === 'borrador'
                  ? 'Borrador actualizado por ' + datos.usuarioNombre
                  : (eraBorrador ? 'Borrador completado por ' : 'Corregido por ') + datos.usuarioNombre,
            });
            resultados.push({ area: area, corregido: true, estado: estado });
          } else {
            S.guardarCierre(datos);
            resultados.push({ area: area, corregido: false, estado: estado });
          }
        });
      } catch (e) {
        if (e.codigo === 'YA_EXISTE') {
          return U.toast(
            'Ya existe un cierre para esa sucursal, fecha y área. Vuelve atrás para corregirlo.',
            'error'
          );
        }
        return U.toast(e.message || 'No se pudo guardar el cierre.', 'error');
      }

      if (!resultados.length)
        return U.toast('No había productos con saldo para guardar.', 'error');

      mostrarComprobante(resultados);
    }

    function mostrarComprobante(resultados) {
      const suc = U.sucursal(st.sucursalId);
      const ahora = new Date();
      const esBorrador = resultados.every((r) => r.estado === 'borrador');

      const m = U.modal({
        titulo: esBorrador ? 'Borrador guardado' : '¡Cierre guardado!',
        ancho: 440,
        contenido:
          '<div class="ticket">' +
          '<div class="ticket__ok"' + (esBorrador ? ' style="background:var(--ambar);color:#2a1a00"' : '') + '>' +
          (esBorrador ? '💾' : '✓') + '</div>' +
          '<p class="tenue mini" style="margin:0">' +
          (esBorrador ? 'Guardado a medias' : 'Cierre registrado') + '</p>' +
          '<div class="ticket__codigo" style="font-size:26px">' + fechaCorta(st.fechaCierre) + '</div>' +
          '</div>' +

          '<div class="caja-datos">' +
          '<div class="linea"><span class="tenue">Sucursal</span><b>' + U.esc(suc.nombre) + '</b></div>' +
          resultados
            .map(
              (r) =>
                '<div class="linea"><span class="tenue">' + nombreArea(r.area) + '</span>' +
                '<b class="' + (r.estado === 'borrador' ? 'ambar' : 'verde') + '">' +
                (r.estado === 'borrador' ? 'Borrador' : r.corregido ? 'Corregido' : 'Guardado') +
                '</b></div>'
            )
            .join('') +
          '<div class="linea"><span class="tenue">Hora de registro</span><b>' +
          ahora.toLocaleTimeString('es-CO', { hour: '2-digit', minute: '2-digit' }) + '</b></div>' +
          '<div class="linea"><span class="tenue">Registra</span><b>' +
          U.esc(st.usuario || 'Mesera') + '</b></div>' +
          '</div>' +

          '<p class="mini tenue centro mt-16">' +
          (esBorrador
            ? 'Cuando vuelvas a esta fecha y área podrás continuar donde lo dejaste.'
            : 'Administración ya puede ver el cruce con las ventas. No tienes que hacer ningún cálculo.') +
          '</p>' +

          (esBorrador
            ? '<button class="btn btn--fantasma btn--bloque mt-16" data-seguir>Seguir contando</button>'
            : '') +
          '<button class="btn btn--rojo btn--bloque mt-8" data-otro>' +
          (esBorrador ? 'Salir' : 'Registrar otro cierre') + '</button>',
      });

      const seguir = U.$('[data-seguir]', m.raiz);
      if (seguir) seguir.onclick = m.cerrar;

      U.$('[data-otro]', m.raiz).onclick = function () {
        m.cerrar();
        st.saldos = {};
        st.edicion = {};
        st.areas = [];
        st.busqueda = '';
        st.soloPendientes = false;
        volverAPaso1();
      };

      U.toast(esBorrador ? 'Borrador guardado.' : 'Cierre guardado correctamente.', esBorrador ? 'info' : 'ok');
    }

    /* ---------------------------------------------------------------
       EVENTOS
       --------------------------------------------------------------- */
    // Paso 1
    $('#cSucursal').addEventListener('change', function () {
      st.sucursalId = Number(this.value);
      st.edicion = {};
      pintarPaso1(); // cada unidad tiene sus propios productos por área
    });

    $('#misCierres').addEventListener('click', function (e) {
      const b = e.target.closest('[data-consultar]');
      if (b) verCierre(b.dataset.consultar);
    });

    $('#cFecha').addEventListener('change', function () {
      st.fechaCierre = this.value;
      st.edicion = {};
      pintarAvisoMadrugada();
      pintarAvisoExistente();
      actualizarBotonEmpezar();
    });

    $('#cAreas').addEventListener('click', function (e) {
      const b = e.target.closest('[data-areas]');
      if (!b) return;
      st.areas = b.dataset.areas.split(',');
      st.edicion = {};
      raiz.querySelectorAll('.inv-area').forEach((x) => x.classList.toggle('is-activa', x === b));
      pintarAvisoExistente();
      actualizarBotonEmpezar();
    });

    $('#avisoExistente').addEventListener('click', function (e) {
      const cons = e.target.closest('[data-consultar]');
      if (cons) return verCierre(cons.dataset.consultar);

      const corr = e.target.closest('[data-corregir]');
      if (corr) {
        const c = S.getCierre(corr.dataset.corregir);
        if (!c) return;
        st.edicion[c.area] = c.id;
        U.toast('Vas a corregir el cierre de ' + nombreArea(c.area) + '.', 'info');
        irAPaso2();
      }
    });

    $('#btnEmpezar').addEventListener('click', irAPaso2);
    $('#btnVolver').addEventListener('click', volverAPaso1);
    $('#btnGuardar').addEventListener('click', intentarGuardar);

    /* Guardar a medias y seguir después. Usa el estado 'borrador' que ya
       existía en el flujo; no inventa uno nuevo. */
    $('#btnBorrador').addEventListener('click', function () {
      const hechos = productosDelCierre().filter((p) => esRegistrado(p.codigo)).length;
      if (!hechos) return U.toast('Registra al menos un producto antes de guardar.', 'error');
      U.confirmar(
        'Se guarda lo que llevas (' + hechos + ' productos) como borrador. ' +
          'Puedes volver cuando quieras a terminarlo; el cierre no cuenta como completado hasta entonces.',
        function () {
          guardarDefinitivo('', 'borrador');
        },
        'Sí, guardar borrador'
      );
    });

    // Paso 2
    $('#cBuscar').addEventListener('input', function () {
      st.busqueda = this.value;
      pintarLista();
    });

    $('#btnSoloPend').addEventListener('click', function () {
      st.soloPendientes = !st.soloPendientes;
      this.textContent = st.soloPendientes ? 'Ver todos' : 'Ver sólo pendientes';
      this.classList.toggle('btn--azul', st.soloPendientes);
      this.classList.toggle('btn--fantasma', !st.soloPendientes);
      pintarLista();
    });

    $('#btnCeros').addEventListener('click', function () {
      const pend = productosDelCierre().filter((p) => !esRegistrado(p.codigo));
      if (!pend.length) return U.toast('No hay productos pendientes.', 'info');
      U.confirmar(
        'Se pondrá 0 en los ' + pend.length + ' productos que aún no has contado. ' +
          'Úsalo sólo si de verdad no queda nada de esos productos.',
        function () {
          pend.forEach((p) => (st.saldos[p.codigo] = 0));
          pintarLista();
          U.toast(pend.length + ' productos marcados en 0.', 'info');
        },
        'Sí, poner en 0'
      );
    });

    // Contadores de las tarjetas
    $('#cLista').addEventListener('click', function (e) {
      const mas = e.target.closest('[data-mas]');
      if (mas) {
        const cod = mas.dataset.mas;
        fijarSaldo(cod, (esRegistrado(cod) ? st.saldos[cod] : 0) + 1, true);
        return;
      }
      const menos = e.target.closest('[data-menos]');
      if (menos) {
        const cod = menos.dataset.menos;
        const actual = esRegistrado(cod) ? st.saldos[cod] : 0;
        fijarSaldo(cod, Math.max(0, actual - 1), true);
      }
    });

    $('#cLista').addEventListener('input', function (e) {
      const inp = e.target.closest('[data-saldo]');
      if (!inp) return;
      // Se limpia cualquier cosa que no sea dígito (teclados de celular)
      const limpio = inp.value.replace(/[^\d]/g, '');
      if (limpio !== inp.value) inp.value = limpio;
      fijarSaldo(inp.dataset.saldo, limpio, false);
    });

    /* --- Arranque --- */
    pintarPaso1();
    U.iniciarComunes();

    /* Si en el panel se cambia de unidad mientras se está en el paso 1, el
       cierre pasa a ser de la nueva. Un conteo a medias (paso 2) no se
       interrumpe: sigue siendo de la unidad con la que se empezó. */
    S.onChange(function () {
      if (!enPanel || (A && A.sucursalDelUsuario())) return;
      const ahora = S.unidadActivaId();
      if (!ahora || ahora === unidadContexto) return;
      if (!$('#paso1') || $('#paso1').classList.contains('oculto')) return;
      unidadContexto = ahora;
      st.sucursalId = ahora;
      st.edicion = {};
      st.areas = [];
      pintarPaso1();
    });
  }

  /* =================================================================
     =========  2. VISOR DE UN CIERRE (compartido)  ==================
     ================================================================= */
  function verCierre(cierreId, alCambiar) {
    const c = S.getCierre(cierreId);
    if (!c) return U.toast('No se encontró el cierre.', 'error');

    const suc = U.sucursal(c.sucursalId);
    const m = U.modal({
      titulo: 'Cierre · ' + nombreArea(c.area) + ' · ' + fechaCorta(c.fechaCierre),
      ancho: 560,
      contenido: '<div id="vcBody"></div>',
    });

    function pintar() {
      const c = S.getCierre(cierreId);
      U.$('#vcBody', m.raiz).innerHTML =
        '<div class="fila fila--entre mb-16">' +
        '<span class="badge badge--azul">' + iconoArea(c.area) + ' ' + nombreArea(c.area) + '</span>' +
        badgeEstado(c.estado) +
        '<span class="mini tenue">' + c.productos.length + ' productos</span>' +
        '</div>' +

        '<div class="caja-datos">' +
        '<div class="linea"><span class="tenue">Sucursal</span><b>' + U.esc(suc.nombre) + '</b></div>' +
        '<div class="linea"><span class="tenue">Jornada del cierre</span><b>' + fechaCorta(c.fechaCierre) + '</b></div>' +
        '<div class="linea"><span class="tenue">Registrado</span><b>' +
        new Date(c.fechaRegistro).toLocaleString('es-CO', {
          day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit',
        }) + '</b></div>' +
        '<div class="linea"><span class="tenue">Por</span><b>' + U.esc(c.usuarioNombre) + '</b></div>' +
        '<div class="linea"><span class="tenue">Identificador</span><b class="mini mono">' + U.esc(c.id) + '</b></div>' +
        '</div>' +

        (c.observaciones
          ? '<div class="caja-datos" style="border-color:var(--ambar)"><b class="ambar">Observaciones</b>' +
            '<p class="mini" style="margin:4px 0 0">' + U.esc(c.observaciones) + '</p></div>'
          : '') +

        '<div class="tabla-wrap mt-16"><table class="tabla" style="min-width:0"><thead><tr>' +
        '<th>CD</th><th>Producto</th><th class="col-num">Saldo</th></tr></thead><tbody>' +
        c.productos
          .map(
            (p) =>
              '<tr><td class="mono">' + U.esc(p.codigo) + '</td>' +
              '<td>' + U.esc(p.nombre) + '</td>' +
              '<td class="col-num">' + p.saldo + '</td></tr>'
          )
          .join('') +
        '</tbody></table></div>' +

        '<h4 class="mt-16" style="font-family:var(--f-cond);letter-spacing:.1em;text-transform:uppercase;font-size:13px;color:var(--gris)">Historial</h4>' +
        '<ul class="linea-tiempo">' +
        (c.historial || [])
          .map((h) => '<li class="hecho"><b>' + U.esc(h.texto) + '</b><span>' + U.hora(h.ts) + '</span></li>')
          .join('') +
        '</ul>';
    }

    pintar();
    return m;
  }

  /* =================================================================
     ==========  3. PANEL DE LA ADMINISTRADORA  ======================
     ================================================================= */
  let panel = null;

  function iniciarPanel(opciones) {
    panel = {
      raiz: opciones.raiz,
      sucursalGlobal: opciones.sucursalGlobal || (() => ''),
    };
    const $ = (s) => panel.raiz.querySelector(s);

    const hoyOp = S.hoyOperativo();

    // Valores por defecto de los filtros.
    // Las entradas ya no viven aquí: tienen su propia pestaña.
    $('#ciDesde').value = restarDias(hoyOp, 14);
    $('#ciHasta').value = hoyOp;
    $('#crFecha').value = hoyOp;

    // --- Cierres
    ['#ciDesde', '#ciHasta', '#ciArea', '#ciEstado'].forEach((s) =>
      $(s).addEventListener('change', pintarCierres)
    );
    $('#tablaCierres').addEventListener('click', function (e) {
      const v = e.target.closest('[data-ver-cierre]');
      if (v) return verCierre(v.dataset.verCierre);

      const cr = e.target.closest('[data-cruce]');
      if (cr) {
        const c = S.getCierre(cr.dataset.cruce);
        if (!c) return;
        $('#crFecha').value = c.fechaCierre;
        $('#crArea').value = c.area;
        irASubTab('cruce');
        pintarCruce();
        return;
      }

      const rev = e.target.closest('[data-revisar]');
      if (rev) {
        // Dar por revisado es de administración, no de quien cuenta.
        if (NASCAR.Auth && !NASCAR.Auth.exigir('cierres_revisar')) return;
        const c = S.getCierre(rev.dataset.revisar);
        return U.confirmar(
          'Marcar como REVISADO el cierre de ' + nombreArea(c.area) + ' del ' +
            fechaCorta(c.fechaCierre) + '. Después de esto la mesera ya no podrá corregirlo.',
          function () {
            try {
              S.cambiarEstadoCierre(c.id, 'revisado', 'Administración');
            } catch (err) {
              return U.toast(err.message || 'No se pudo marcar como revisado.', 'error');
            }
            U.toast('Cierre marcado como revisado.');
            refrescarPanel();
          },
          'Sí, marcar revisado'
        );
      }
    });

    // --- Cruce
    ['#crFecha', '#crArea'].forEach((s) => $(s).addEventListener('change', pintarCruce));
    $('#btnCruceCSV').addEventListener('click', exportarCruceCSV);
    $('#btnCruceImprimir').addEventListener('click', () => window.print());
    $('#btnAplicarStock').addEventListener('click', aplicarSaldosAlStock);

    // Las entradas viven en su propia pestaña (ver iniciarEntradas):
    // quien recibe mercancía no tiene por qué ver el cruce con las ventas.

    // --- Sub-pestañas
    panel.raiz.addEventListener('click', function (e) {
      const t = e.target.closest('.sub-tab');
      if (t) irASubTab(t.dataset.sub);
    });

    llenarSelectoresFijos();
    refrescarPanel();
  }

  function irASubTab(id) {
    panel.raiz.querySelectorAll('.sub-tab').forEach((t) => t.classList.toggle('is-activo', t.dataset.sub === id));
    panel.raiz.querySelectorAll('[data-sub-panel]').forEach((p) =>
      p.classList.toggle('oculto', p.dataset.subPanel !== id)
    );
  }

  function llenarSelectoresFijos() {
    const $ = (s) => panel.raiz.querySelector(s);
    const opcionesArea = NASCAR.AREAS.map(
      (a) => '<option value="' + a.id + '">' + a.icono + ' ' + a.nombre + '</option>'
    ).join('');

    $('#ciArea').innerHTML = '<option value="">Comidas y bar</option>' + opcionesArea;
    $('#crArea').innerHTML = opcionesArea;

    $('#ciEstado').innerHTML =
      '<option value="">Todos los estados</option>' +
      NASCAR.ESTADOS_CIERRE.map((e) => '<option value="' + e.id + '">' + e.nombre + '</option>').join('');
  }

  function restarDias(iso, n) {
    const d = S.desdeISO(iso);
    d.setDate(d.getDate() - n);
    return S.aISO(d);
  }

  function refrescarPanel() {
    if (!panel) return;
    pintarCierres();
    pintarCruce();
    refrescarEntradas(); // el cruce depende de EN, así que van juntos
  }

  /* ---------------------------------------------------------------
     3.1 · Pestaña CIERRES
     --------------------------------------------------------------- */
  function pintarCierres() {
    const $ = (s) => panel.raiz.querySelector(s);
    const filtro = {
      desde: $('#ciDesde').value || undefined,
      hasta: $('#ciHasta').value || undefined,
      area: $('#ciArea').value || undefined,
      estado: $('#ciEstado').value || undefined,
    };
    const suc = panel.sucursalGlobal();
    if (suc) filtro.sucursalId = suc;

    const lista = S.getCierres(filtro);

    // Indicadores
    const hoyOp = S.hoyOperativo();
    const deHoy = S.getCierres({ fechaCierre: hoyOp, sucursalId: suc || undefined });
    const esperados = (suc ? 1 : NASCAR.SUCURSALES.length) * NASCAR.AREAS.length;

    $('#kpisCierres').innerHTML =
      kpi('Cierres en el rango', lista.length, filtro.desde ? fechaCorta(filtro.desde) + ' → ' + fechaCorta(filtro.hasta) : '') +
      kpi('Jornada de hoy', deHoy.length + ' / ' + esperados,
          deHoy.length >= esperados ? 'Completa' : 'Faltan cierres',
          deHoy.length >= esperados ? 'verde' : 'ambar') +
      kpi('Por revisar', lista.filter((c) => c.estado === 'completado').length, 'Pendientes de tu visto bueno', 'azul') +
      kpi('Revisados', lista.filter((c) => c.estado === 'revisado').length, '', 'verde');

    if (!lista.length) {
      $('#tablaCierres').innerHTML =
        '<tr><td colspan="7"><div class="vacio" style="border:0">' +
        '<div class="vacio__ico">📦</div><h3>Sin cierres en este rango</h3>' +
        '<p class="mini">Los cierres los registran las meseras desde <b>cierre.html</b>.</p>' +
        '</div></td></tr>';
      return;
    }

    $('#tablaCierres').innerHTML = lista
      .map(function (c) {
        const s = U.sucursal(c.sucursalId);
        return (
          '<tr>' +
          '<td><b>' + fechaCorta(c.fechaCierre) + '</b></td>' +
          '<td>' + U.esc(s.corto) + '</td>' +
          '<td>' + iconoArea(c.area) + ' ' + nombreArea(c.area) + '</td>' +
          '<td>' + U.esc(c.usuarioNombre) + '</td>' +
          '<td class="mini tenue">' + U.hora(c.fechaRegistro) + '<br>' + fechaCorta(c.fechaRegistro.slice(0, 10)) + '</td>' +
          '<td>' + badgeEstado(c.estado) + '</td>' +
          '<td class="nowrap">' +
          '<button class="btn btn--fantasma btn--xs" data-ver-cierre="' + c.id + '">Ver</button> ' +
          '<button class="btn btn--azul btn--xs" data-cruce="' + c.id + '">Cruce</button>' +
          (c.estado !== 'revisado' && (!NASCAR.Auth || NASCAR.Auth.puede('cierres_revisar'))
            ? ' <button class="btn btn--fantasma btn--xs" data-revisar="' + c.id + '">✓ Revisar</button>'
            : '') +
          '</td></tr>'
        );
      })
      .join('');
  }

  /* ---------------------------------------------------------------
     3.2 · Pestaña CRUCE
     --------------------------------------------------------------- */
  let ultimoCruce = null;

  function pintarCruce() {
    const $ = (s) => panel.raiz.querySelector(s);

    const sucursalId = panel.sucursalGlobal() || U.sucursalPorDefectoId();
    const fecha = $('#crFecha').value;
    const area = $('#crArea').value;

    // El cruce siempre es de UNA sucursal: si el panel está en "todas",
    // se usa la primera y se avisa.
    $('#crAvisoSucursal').innerHTML = panel.sucursalGlobal()
      ? ''
      : '<p class="mini ambar">Mostrando <b>' + U.esc(U.sucursal(sucursalId).nombre) +
        '</b>. Usa el selector de sucursal de arriba para ver la otra: los inventarios no se mezclan.</p>';

    if (!fecha || !area) return;

    let cruce;
    try {
      cruce = S.calcularCruce(sucursalId, fecha, area);
    } catch (err) {
      // Con la base de datos el cruce se calcula allá: si falla, se dice y el panel sigue
      ultimoCruce = null;
      $('#crVeredicto').innerHTML =
        '<div class="caja-datos" style="border-color:var(--rojo)"><b class="rojo">No se pudo calcular el cruce</b>' +
        '<p class="mini tenue" style="margin:4px 0 0">' + U.esc(err.message || '') + '</p></div>';
      return;
    }
    ultimoCruce = cruce;

    const r = cruce.resumen;
    const suc = U.sucursal(sucursalId);

    // --- Veredicto general
    let veredicto;
    if (!cruce.hayCierre) {
      veredicto =
        '<div class="inv-veredicto inv-veredicto--vacio"><i>📭</i><div>' +
        '<b>Sin cierre registrado</b>' +
        '<span>Nadie ha registrado el inventario de ' + nombreArea(area) + ' de ' +
        U.esc(suc.corto) + ' para el ' + fechaCorta(fecha) + '.</span></div></div>';
    } else if (r.sinDiferencias) {
      veredicto =
        '<div class="inv-veredicto inv-veredicto--ok"><i>🟢</i><div>' +
        '<b>Cierre sin diferencias</b>' +
        '<span>Los ' + r.revisados + ' productos contados coinciden con lo esperado.</span></div></div>';
    } else {
      veredicto =
        '<div class="inv-veredicto inv-veredicto--dif"><i>🔴</i><div>' +
        '<b>Cierre con diferencias</b>' +
        '<span>' + r.faltantes + ' con faltante y ' + r.sobrantes + ' con sobrante. ' +
        'Diferencia neta: ' + (r.diferenciaTotal > 0 ? '+' : '') + r.diferenciaTotal + ' unidades.</span>' +
        '</div></div>';
    }

    /* De dónde salió el saldo inicial. Importa decirlo: un IN contado en
       un cierre anterior es un dato firme; uno heredado del catálogo de
       Stock es sólo la línea base que configuró administración. */
    const partes = [];
    if (r.inDesdeCierre)
      partes.push(
        '<b>' + r.inDesdeCierre + '</b> del cierre anterior' +
          (cruce.hayCierreAnterior ? ' (' + fechaCorta(cruce.cierreAnterior.fechaCierre) + ')' : '')
      );
    if (r.inDesdeStock) partes.push('<b>' + r.inDesdeStock + '</b> del stock configurado');
    if (r.inSinDato) partes.push('<b>' + r.inSinDato + '</b> sin dato previo (0)');

    veredicto +=
      '<p class="mini tenue">Saldo inicial (IN): ' + partes.join(' · ') + '.<br>' +
      'Z calculado sobre la jornada operativa del ' + fechaCorta(fecha) +
      ' (incluye lo vendido después de medianoche, hasta las ' + S.horaCorte() + ':00).</p>';

    if (r.inSinDato && cruce.hayCierre) {
      veredicto +=
        '<div class="caja-datos" style="border-color:var(--ambar)">' +
        '<b class="ambar">' + r.inSinDato + ' productos sin saldo inicial</b>' +
        '<p class="mini tenue" style="margin:4px 0 0">Nunca se han contado y no tienen stock ' +
        'configurado, así que su IN es 0 y sus diferencias no son confiables. Ponles el saldo ' +
        'en <b>📦 Stock</b> o cuéntalos una primera vez: a partir de ahí la cadena se arma sola.</p></div>';
    }

    $('#crVeredicto').innerHTML = veredicto;

    // --- Tarjetas de resumen
    $('#kpisCruce').innerHTML =
      kpi('Productos revisados', r.revisados, 'de ' + r.totalCatalogo + ' en el catálogo') +
      kpi('Coinciden', r.ok, 'Sin diferencia', 'verde') +
      kpi('Con sobrante', r.sobrantes, '+' + r.unidadesSobrantes + ' unidades', 'ambar') +
      kpi('Con faltante', r.faltantes, '−' + r.unidadesFaltantes + ' unidades', 'rojo') +
      kpi('Diferencia total', (r.diferenciaTotal > 0 ? '+' : '') + r.diferenciaTotal, 'unidades',
          r.diferenciaTotal === 0 ? 'verde' : 'rojo');

    // --- Tabla principal
    $('#tablaCruce').innerHTML = cruce.filas
      .map(function (f) {
        return (
          '<tr class="fila--' + f.estado + '">' +
          '<td class="mono">' + U.esc(f.codigo) + '</td>' +
          '<td>' + U.esc(f.nombre) + '</td>' +
          '<td class="col-num">' + f.IN +
          (f.origenIN === 'stock'
            ? '<span class="origen-in" title="Saldo inicial tomado del módulo Stock: este producto todavía no se ha contado en ningún cierre">◇</span>'
            : '') +
          '</td>' +
          '<td class="col-num">' + (f.EN ? '+' + f.EN : '0') + '</td>' +
          '<td class="col-num">' + f.Z + '</td>' +
          '<td class="col-num">' + (f.registrado ? f.SD : '—') + '</td>' +
          '<td class="col-num col-sldc">' + f.SLDC + '</td>' +
          '<td class="col-num">' + (f.registrado ? (f.DF > 0 ? '+' + f.DF : f.DF) : '—') + '</td>' +
          '<td>' + etiquetaDF(f) + '</td>' +
          '</tr>'
        );
      })
      .join('');

    // --- Sólo las diferencias
    const dif = cruce.filas.filter((f) => f.registrado && f.DF !== 0);
    $('#tablaDiferencias').innerHTML = dif.length
      ? dif
          .map(
            (f) =>
              '<tr class="fila--' + f.estado + '">' +
              '<td class="mono">' + U.esc(f.codigo) + '</td>' +
              '<td>' + U.esc(f.nombre) + '</td>' +
              '<td class="col-num">' + f.SLDC + '</td>' +
              '<td class="col-num">' + f.SD + '</td>' +
              '<td class="col-num">' + (f.DF > 0 ? '+' + f.DF : f.DF) + '</td>' +
              '<td>' + etiquetaDF(f) + '</td></tr>'
          )
          .join('')
      : '<tr><td colspan="6"><div class="vacio" style="border:0;padding:26px">' +
        (cruce.hayCierre ? '🟢 Ningún producto presenta diferencias.' : 'Todavía no hay cierre para comparar.') +
        '</div></td></tr>';

    $('#crTituloDif').textContent = dif.length ? 'Productos con diferencias (' + dif.length + ')' : 'Productos con diferencias';

    /* Sólo tiene sentido llevar saldos al stock si hay algo contado y
       la empresa tiene el módulo Stock: es un botón que cruza de un
       módulo a otro, y el de destino puede no estar contratado. */
    $('#btnAplicarStock').classList.toggle(
      'oculto',
      !cruce.hayCierre || !S.hasModule('stock')
    );
  }

  /**
   * Cierra el ciclo Stock → Cierre → Stock.
   *
   * El sistema NO toca el stock por su cuenta: es la administradora quien
   * decide, ya revisadas las diferencias, que lo contado pasa a ser el
   * saldo bueno. Por eso es un botón explícito y con confirmación, y no
   * un efecto secundario de guardar el cierre.
   */
  function aplicarSaldosAlStock() {
    if (!ultimoCruce || !ultimoCruce.hayCierre)
      return U.toast('No hay un cierre registrado para esta fecha y área.', 'error');

    const A = NASCAR.Auth;
    if (A && !A.exigir('stock')) return;

    const c = ultimoCruce;
    const suc = U.sucursal(c.sucursalId);
    const n = c.cierre.productos.length;
    const dif = c.resumen.sobrantes + c.resumen.faltantes;

    U.confirmar(
      'El stock actual de ' + n + ' productos de ' + nombreArea(c.area) + ' en ' + suc.corto +
        ' pasará a ser el saldo contado el ' + fechaCorta(c.fechaCierre) + '.' +
        (dif
          ? ' Ojo: ' + dif + ' productos tienen diferencias sin explicar; al aplicarlos quedan como buenos.'
          : '') +
        ' El cierre no se modifica.',
      function () {
        try {
          const aplicados = S.aplicarCierreAStock(c.cierre.id);
          U.toast('Stock actualizado en ' + aplicados + ' productos.');
          refrescarPanel();
          if (NASCAR.Gestion) NASCAR.Gestion.refrescar();
        } catch (e) {
          U.toast(e.message || 'No se pudo actualizar el stock.', 'error');
        }
      },
      'Sí, actualizar el stock'
    );
  }

  function exportarCruceCSV() {
    if (!ultimoCruce || !ultimoCruce.filas.length)
      return U.toast('No hay nada que exportar.', 'error');

    const c = ultimoCruce;
    const suc = U.sucursal(c.sucursalId);

    // Las columnas son exactamente las de la plantilla en papel
    const cab = ['CD', 'PRODUCTOS', 'IN', 'EN', 'Z', 'SD', 'SLDC', 'DF'];
    const filas = c.filas.map((f) => [
      f.codigo,
      f.nombre,
      f.IN,
      f.EN,
      f.Z,
      f.registrado ? f.SD : '',
      f.SLDC,
      f.registrado ? f.DF : '',
    ]);

    const csv =
      '﻿' + // BOM para que Excel respete los acentos
      [
        U.filaCSV(['Cierre de inventario NASCAR']),
        U.filaCSV(['Sucursal', suc.nombre]),
        U.filaCSV(['Jornada del cierre', fechaCorta(c.fechaCierre)]),
        U.filaCSV(['Área', nombreArea(c.area)]),
        U.filaCSV(['Generado', new Date().toLocaleString('es-CO')]),
        '',
        U.filaCSV(cab),
        ...filas.map(U.filaCSV),
      ].join('\r\n');

    U.descargarArchivo(
      csv,
      'cierre-' + suc.corto.toLowerCase() + '-' + c.area + '-' + c.fechaCierre + '.csv',
      'text/csv;charset=utf-8'
    );
    U.toast('CSV descargado (' + filas.length + ' productos).');
  }

  /* =================================================================
     ============  4. ENTRADAS DE MERCANCÍA  =========================

     Alimentan el campo EN del cruce. Tienen su propia pestaña y su
     propio permiso ('entradas') porque quien recibe la mercancía —caja,
     por ejemplo— no tiene por qué ver el cruce con las ventas ni tocar
     los cierres.

     Se puede corregir una entrada mientras el cierre de esa jornada no
     haya sido revisado; después queda congelada (lo decide el store con
     entradaEditable()).
     ================================================================= */
  let ent = null;

  function iniciarEntradas(opciones) {
    ent = { raiz: opciones.raiz, sucursalGlobal: opciones.sucursalGlobal || (() => '') };
    if (!ent.raiz) return;

    const $ = (s) => ent.raiz.querySelector(s);
    const hoyOp = S.hoyOperativo();

    $('#enArea').innerHTML = NASCAR.AREAS.map(
      (a) => '<option value="' + a.id + '">' + a.icono + ' ' + a.nombre + '</option>'
    ).join('');
    /* Los tipos automáticos no se ofrecen: los genera el sistema (el
       retorno por anulación de factura), no una persona. */
    $('#enTipo').innerHTML = NASCAR.TIPOS_ENTRADA.filter((t) => !t.automatico)
      .map((t) => '<option value="' + t.id + '">' + U.esc(t.nombre) + '</option>')
      .join('');

    $('#enFecha').value = hoyOp;
    $('#enFiltroDesde').value = restarDias(hoyOp, 14);
    $('#enFiltroHasta').value = hoyOp;

    $('#enArea').addEventListener('change', llenarProductosEntrada);
    $('#btnGuardarEntrada').addEventListener('click', guardarEntradaDesdeFormulario);
    ['#enFiltroDesde', '#enFiltroHasta', '#enFiltroArea'].forEach(function (s) {
      const el = $(s);
      if (el) el.addEventListener('change', pintarEntradas);
    });
    const buscar = $('#enBuscar');
    if (buscar) buscar.addEventListener('input', pintarEntradas);

    $('#tablaEntradas').addEventListener('click', function (e) {
      const ed = e.target.closest('[data-editar-entrada]');
      if (ed) return editarEntrada(ed.dataset.editarEntrada);

      const b = e.target.closest('[data-borrar-entrada]');
      if (!b) return;
      if (NASCAR.Auth && !NASCAR.Auth.exigir('entradas')) return;
      U.confirmar('¿Eliminar esta entrada? El cruce de esa jornada se recalculará.', function () {
        try {
          S.borrarEntrada(b.dataset.borrarEntrada);
          U.toast('Entrada eliminada.', 'info');
          refrescarEntradas();
          refrescarPanel();
        } catch (err) {
          U.toast(err.message, 'error');
        }
      }, 'Sí, eliminar');
    });

    if ($('#enFiltroArea')) {
      $('#enFiltroArea').innerHTML =
        '<option value="">Comidas y bar</option>' +
        NASCAR.AREAS.map((a) => '<option value="' + a.id + '">' + a.icono + ' ' + a.nombre + '</option>').join('');
    }

    llenarProductosEntrada();
    pintarEntradas();
  }

  /* Repinta si la pestaña está montada. La llaman tanto el módulo de
     entradas como el de cierres, porque el cruce depende de EN. */
  /* La unidad en la que se registra la mercancía: la asignada al usuario
     o la activa del panel. */
  function unidadEntradas() {
    return (
      (NASCAR.Auth && NASCAR.Auth.sucursalDelUsuario()) ||
      Number(ent.sucursalGlobal()) ||
      U.sucursalPorDefectoId()
    );
  }

  function refrescarEntradas() {
    if (!ent || !ent.raiz) return;
    // Al cambiar de unidad cambia el catálogo que se ofrece
    if (ent.unidadProductos !== unidadEntradas()) llenarProductosEntrada();
    pintarEntradas();
  }

  function llenarProductosEntrada() {
    const $ = (s) => ent.raiz.querySelector(s);
    const area = $('#enArea').value || NASCAR.AREAS[0].id;
    ent.unidadProductos = unidadEntradas();
    $('#enProducto').innerHTML = S.getProductosInventario({ area: area, sucursalId: ent.unidadProductos })
      .map((p) => '<option value="' + p.codigo + '">' + p.codigo + ' · ' + U.esc(p.nombre) + '</option>')
      .join('');
  }

  /**
   * Deja el formulario de Entradas listo para un producto concreto.
   *
   * Lo usa el acceso rápido "Registrar entrada" de 📦 Stock → Productos
   * por pedir. No guarda nada: sólo rellena, para que quien recibe la
   * mercancía confirme la cantidad de verdad antes de registrarla. Así
   * se reutiliza este módulo en vez de montar un segundo sistema de
   * compras.
   */
  function prepararEntrada(codigo, cantidadSugerida) {
    if (!ent || !ent.raiz) return false;
    const prod = S.getProductoInventario(codigo);
    if (!prod) return false;

    const $ = (s) => ent.raiz.querySelector(s);
    $('#enArea').value = prod.area;
    llenarProductosEntrada();
    $('#enProducto').value = prod.codigo;

    const n = Number(cantidadSugerida);
    $('#enCantidad').value = isFinite(n) && n > 0 ? n : '';
    $('#enObs').value = 'Reposición sugerida desde Stock';
    $('#enCantidad').focus();
    return true;
  }

  function firmaEntrada() {
    const A = NASCAR.Auth;
    return A ? A.firma() : { usuarioId: null, usuarioNombre: 'Administración', rol: null };
  }

  function guardarEntradaDesdeFormulario() {
    const A = NASCAR.Auth;
    if (A && !A.exigir('entradas')) return;

    const $ = (s) => ent.raiz.querySelector(s);
    // Quien está atado a una sucursal registra en la suya
    const sucursalId =
      (A && A.sucursalDelUsuario()) || ent.sucursalGlobal() || U.sucursalPorDefectoId();
    const f = firmaEntrada();

    try {
      const e = S.guardarEntrada({
        fecha: $('#enFecha').value,
        sucursalId: sucursalId,
        codigo: $('#enProducto').value,
        cantidad: $('#enCantidad').value,
        tipoEntrada: $('#enTipo').value,
        observacion: $('#enObs').value.trim(),
        usuarioId: f.usuarioId,
        usuarioNombre: f.usuarioNombre,
        rolUsuario: f.rol,
      });
      U.toast('Entrada registrada: +' + e.cantidad + ' de ' + e.nombre + '.');
      $('#enCantidad').value = '';
      $('#enObs').value = '';
      pintarEntradas();
      refrescarPanel();
    } catch (err) {
      U.toast(err.message || 'No se pudo registrar la entrada.', 'error');
    }
  }

  function editarEntrada(entradaId) {
    const A = NASCAR.Auth;
    if (A && !A.exigir('entradas')) return;

    const e = S.getEntradas({}).find((x) => x.id === entradaId);
    if (!e) return;

    const permiso = S.entradaEditable(e);
    if (!permiso.editable) return U.toast(permiso.motivo, 'error');

    const productos = S.getProductosInventario({ area: e.area, soloActivos: false, sucursalId: e.sucursalId });

    const m = U.modal({
      titulo: 'Corregir entrada',
      ancho: 500,
      contenido:
        '<div class="rejilla-2">' +
        '<label class="campo"><span>Jornada</span>' +
        '<input class="input" type="date" id="edFecha" value="' + e.fecha + '"></label>' +
        '<label class="campo"><span>Cantidad</span>' +
        '<input class="input" type="number" min="1" step="1" id="edCantidad" value="' + e.cantidad + '"></label>' +
        '</div>' +

        '<label class="campo"><span>Producto</span>' +
        '<select class="select" id="edProducto">' +
        productos
          .map(
            (p) => '<option value="' + p.codigo + '"' + (p.codigo === e.codigo ? ' selected' : '') + '>' +
              p.codigo + ' · ' + U.esc(p.nombre) + '</option>'
          )
          .join('') +
        '</select></label>' +

        '<label class="campo"><span>Tipo de entrada</span>' +
        '<select class="select" id="edTipo">' +
        NASCAR.TIPOS_ENTRADA.filter((t) => !t.automatico || t.id === e.tipoEntrada)
          .map(
            (t) => '<option value="' + t.id + '"' + (t.id === e.tipoEntrada ? ' selected' : '') + '>' +
              U.esc(t.nombre) + '</option>'
          )
          .join('') +
        '</select></label>' +

        '<label class="campo"><span>Observación</span>' +
        '<input class="input" id="edObs" value="' + U.esc(e.observacion || '') + '"></label>' +

        '<div class="caja-datos"><span class="mini tenue">Registró</span> ' +
        '<b>' + U.esc(e.usuarioNombre || '—') + '</b> ' +
        '<span class="mini tenue">· ' + new Date(e.registrado).toLocaleString('es-CO') + '</span></div>' +

        '<div class="fila fila--fin">' +
        '<button class="btn btn--fantasma" id="edNo">Cancelar</button>' +
        '<button class="btn btn--rojo" id="edSi">Guardar</button></div>',
    });

    U.$('#edNo', m.raiz).onclick = m.cerrar;
    U.$('#edSi', m.raiz).onclick = function () {
      try {
        S.actualizarEntrada(
          entradaId,
          {
            fecha: U.$('#edFecha', m.raiz).value,
            cantidad: U.$('#edCantidad', m.raiz).value,
            codigo: U.$('#edProducto', m.raiz).value,
            tipoEntrada: U.$('#edTipo', m.raiz).value,
            observacion: U.$('#edObs', m.raiz).value.trim(),
          },
          firmaEntrada()
        );
      } catch (err) {
        return U.toast(err.message, 'error');
      }
      m.cerrar();
      U.toast('Entrada corregida.');
      pintarEntradas();
      refrescarPanel();
    };
  }

  function pintarEntradas() {
    if (!ent || !ent.raiz) return;
    const A = NASCAR.Auth;
    const $ = (s) => ent.raiz.querySelector(s);

    const filtro = {
      desde: $('#enFiltroDesde').value || undefined,
      hasta: $('#enFiltroHasta').value || undefined,
      area: ($('#enFiltroArea') && $('#enFiltroArea').value) || undefined,
      texto: undefined,
    };
    const suc = (A && A.sucursalDelUsuario()) || ent.sucursalGlobal();
    if (suc) filtro.sucursalId = suc;

    let lista = S.getEntradas(filtro);

    const q = (($('#enBuscar') && $('#enBuscar').value) || '').trim().toLowerCase();
    if (q)
      lista = lista.filter(
        (e) =>
          (e.nombre || '').toLowerCase().includes(q) ||
          (e.codigo || '').toLowerCase().includes(q) ||
          (e.observacion || '').toLowerCase().includes(q)
      );

    const nombresTipo = {};
    NASCAR.TIPOS_ENTRADA.forEach((t) => (nombresTipo[t.id] = t.nombre));

    const sucActual = suc || U.sucursalPorDefectoId();
    if ($('#enSucursalActual')) $('#enSucursalActual').textContent = U.sucursal(sucActual).nombre;

    if ($('#kpisEntradas')) {
      const unidades = lista.reduce((s, e) => s + e.cantidad, 0);
      const hoyOp = S.hoyOperativo();
      const deHoy = lista.filter((e) => e.fecha === hoyOp);
      $('#kpisEntradas').innerHTML =
        kpi('Entradas en el rango', lista.length, unidades + ' unidades') +
        kpi('Recibidas hoy', deHoy.length, deHoy.reduce((s, e) => s + e.cantidad, 0) + ' unidades', 'verde') +
        kpi('Comidas', lista.filter((e) => e.area === 'comidas').length, '') +
        kpi('Bar', lista.filter((e) => e.area === 'bar').length, '');
    }

    if (!lista.length) {
      $('#tablaEntradas').innerHTML =
        '<tr><td colspan="8"><div class="vacio" style="border:0">' +
        '<div class="vacio__ico">📥</div><h3>Sin entradas registradas</h3>' +
        '<p class="mini">Mientras no registres compras, EN queda en 0 en el cruce. ' +
        'El sistema nunca inventa cantidades.</p></div></td></tr>';
      return;
    }

    $('#tablaEntradas').innerHTML = lista
      .map(function (e) {
        const editable = S.entradaEditable(e);
        return (
          '<tr>' +
          '<td><b>' + fechaCorta(e.fecha) + '</b></td>' +
          '<td class="mini">' + U.esc(U.sucursal(e.sucursalId).corto) + '</td>' +
          '<td class="mono">' + U.esc(e.codigo) + '</td>' +
          '<td>' + U.esc(e.nombre) + '<br><span class="mini tenue">' +
          iconoArea(e.area) + ' ' + nombreArea(e.area) + '</span></td>' +
          '<td class="col-num verde">+' + e.cantidad + '</td>' +
          '<td class="mini">' + U.esc(nombresTipo[e.tipoEntrada] || e.tipoEntrada) +
          (e.observacion ? '<br><span class="tenue">' + U.esc(e.observacion) + '</span>' : '') + '</td>' +
          '<td class="mini">' + U.esc(e.usuarioNombre || '—') +
          '<br><span class="tenue">' + U.hora(e.registrado) + '</span></td>' +
          '<td class="nowrap">' +
          (editable.editable
            ? '<button class="btn btn--fantasma btn--xs" data-editar-entrada="' + e.id + '">Editar</button> ' +
              '<button class="btn btn--fantasma btn--xs" data-borrar-entrada="' + e.id + '" ' +
              'style="border-color:var(--rojo);color:var(--rojo-claro)">✕</button>'
            : '<span class="badge badge--gris" title="' + U.esc(editable.motivo) + '">Cerrada</span>') +
          '</td></tr>'
        );
      })
      .join('');
  }

  /* --- Tarjeta de indicador (mismo formato que el resto del panel) --- */
  function kpi(label, valor, extra, color) {
    return (
      '<div class="kpi' + (color ? ' kpi--' + color : '') + '">' +
      '<div class="kpi__label">' + U.esc(label) + '</div>' +
      '<div class="kpi__valor">' + valor + '</div>' +
      (extra ? '<div class="kpi__extra">' + U.esc(extra) + '</div>' : '') +
      '</div>'
    );
  }

  /* =================================================================
     API PÚBLICA
     ================================================================= */
  return {
    iniciarRegistro: iniciarRegistro,
    iniciarPanel: iniciarPanel,
    refrescarPanel: refrescarPanel,
    iniciarEntradas: iniciarEntradas,
    refrescarEntradas: refrescarEntradas,
    prepararEntrada: prepararEntrada,
    verCierre: verCierre,
    // utilidades reutilizables
    nombreArea: nombreArea,
    iconoArea: iconoArea,
    badgeEstado: badgeEstado,
    fechaCorta: fechaCorta,
    etiquetaDF: etiquetaDF,
  };
})();
