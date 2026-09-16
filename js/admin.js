/* ==========================================================================
   NASCAR · admin.js
   Panel interno: tablero de pedidos, confirmación de pagos, menú del día,
   ajustes de carta, reportes de ventas y respaldo de datos.
   ========================================================================== */

(function () {
  'use strict';

  const S = NASCAR.Store;
  const U = NASCAR.UI;
  const A = NASCAR.Auth;

  /* Raíz de esta vista — ver la nota en app.js. */
  const RAIZ = document.querySelector('[data-vista="panel"]') || document;
  const SOLO_ARCHIVO = RAIZ !== document;
  const $ = (sel) => U.$(sel, RAIZ);
  const $$ = (sel) => U.$$(sel, RAIZ);

  let tabActiva = 'pedidos';
  /* Unidad activa del panel (id en texto). Sale SIEMPRE del store —
     S.unidadActivaId()— y se sincroniza en pintarSelectorUnidad(). */
  let sucursalGlobal = '';

  /* =================================================================
     LOGIN
     ================================================================= */
  function iniciarLogin() {
    const entrar = function () {
      const usuario = $('#usuarioAcceso').value.trim();
      const pin = $('#pin').value;

      // Sin usuario se acepta sólo el PIN, como antes.
      const ok = usuario ? A.entrar(usuario, pin) : S.login(pin);

      if (ok) {
        $('#pin').value = '';
        mostrarPanel();
      } else {
        U.toast('Usuario o PIN incorrectos.', 'error');
        $('#pin').value = '';
        $('#pin').focus();
      }
    };

    $('#btnEntrar').addEventListener('click', entrar);
    $('#pin').addEventListener('keydown', (e) => e.key === 'Enter' && entrar());
    $('#usuarioAcceso').addEventListener('keydown', (e) => e.key === 'Enter' && $('#pin').focus());

    // Accesos rápidos: un botón por usuario activo, para poder probar
    // cada perfil sin tener que acordarse de los PIN.
    $('#accesoRapido').innerHTML = S.getUsuarios()
      .map(
        (u) =>
          '<button data-acceso="' + U.esc(u.usuario) + '" data-pin="' + U.esc(u.pin) + '">' +
          '<i>' + A.iconoRol(u.rol) + '</i><b>' + U.esc(A.nombreRol(u.rol)) + '</b>' +
          '<span>' + U.esc(u.usuario) + '</span></button>'
      )
      .join('');

    $('#accesoRapido').addEventListener('click', function (e) {
      const b = e.target.closest('[data-acceso]');
      if (!b) return;
      $('#usuarioAcceso').value = b.dataset.acceso;
      $('#pin').value = b.dataset.pin;
      entrar();
    });
  }

  /* =================================================================
     PUERTA DEL PORTAL OPERATIVO

     Ésta es una dirección del negocio, no del cliente. Quien llegue
     escribiéndola a mano se encuentra el login, y si su sesión no da
     acceso a nada, el aviso de no autorizado — no un panel vacío.

     Ocultar el enlace en el portal del cliente es la mitad; esto es la
     otra mitad. Y cada acción del panel vuelve a comprobar su permiso
     por su cuenta (NASCAR.Auth.exigir).
     ================================================================= */
  function tieneAcceso() {
    const u = A.getUsuarioActual();
    if (!u) return false;
    // Un rol sin ninguna sección visible no tiene nada que hacer aquí.
    return A.seccionesVisibles().length > 0;
  }

  function accesoDenegado() {
    const u = A.getUsuarioActual();
    $('#pantallaPanel').classList.add('oculto');
    $('#pantallaLogin').classList.remove('oculto');

    const aviso = $('#avisoAcceso');
    if (aviso)
      aviso.innerHTML =
        '<div class="caja mb-16" style="border-color:var(--rojo)">' +
        '<b>Acceso no autorizado.</b>' +
        '<p class="mini tenue" style="margin:6px 0 0">' +
        (u
          ? 'Tu perfil (' + U.esc(A.nombreRol(u.rol)) + ') no tiene ninguna sección ' +
            'habilitada en esta empresa.'
          : 'Este acceso es para el equipo del negocio. Entra con tu usuario.') +
        '</p>' +
        (u
          ? '<button class="btn btn--fantasma btn--sm mt-16" data-salir-denegado>Salir de la sesión</button>'
          : '') +
        '</div>';

    const b = $('[data-salir-denegado]');
    if (b)
      b.addEventListener('click', function () {
        S.logout();
        location.reload();
      });
  }

  function mostrarPanel() {
    if (!tieneAcceso()) return accesoDenegado();

    const aviso = $('#avisoAcceso');
    if (aviso) aviso.innerHTML = '';

    $('#pantallaLogin').classList.add('oculto');
    $('#pantallaPanel').classList.remove('oculto');
    arrancarPanel();
    // Si alguien entra con otro usuario sin recargar la página, hay que
    // volver a decidir qué ve: el panel ya estaba construido.
    aplicarPermisos();
  }

  /* =================================================================
     ESTRUCTURA DEL PANEL
     ================================================================= */
  let panelListo = false;

  function arrancarPanel() {
    if (panelListo) return refrescarTodo();
    panelListo = true;

    S.sembrar();

    /* Unidad activa. Forma parte del contexto, como la empresa: todo el
       panel —pedidos, ventas, gastos, stock, cierres, carta, menú— trabaja
       sobre ella. Ya no hay "todas": la información de una unidad no se
       mezcla con la de otra. */
    pintarSelectorUnidad();
    $('#qrSucursal').innerHTML = NASCAR.SUCURSALES.map(
      (s) => '<option value="' + s.id + '">' + U.esc(s.nombre) + '</option>'
    ).join('');

    $('#sucursalGlobal').addEventListener('change', function () {
      try {
        S.setUnidadActiva(Number(this.value));
      } catch (err) {
        U.toast(err.message, 'error');
      }
      refrescarTodo();
      const u = S.getUnidadActiva();
      if (u) U.toast('Trabajando en ' + u.nombre + '.', 'info');
    });

    // Fechas por defecto
    const hoy = S.hoy();
    $('#fFechaPedido').value = hoy;
    $('#fFechaDia').value = hoy;
    $('#vDesde').value = hoy;
    $('#vHasta').value = hoy;
    $('#fPagoDesde').value = restarDias(hoy, 7);
    $('#fPagoHasta').value = hoy;

    aplicarPermisos();

    /* Barra lateral: es el MISMO componente que usa el panel de Taseca.
       Sólo maneja el aspecto —colapsar, recordar la preferencia, el
       cajón de móvil—; qué opciones se ven lo sigue decidiendo
       aplicarPermisos(), que no se ha tocado. */
    if (NASCAR.Sidebar) {
      NASCAR.Sidebar.iniciar({ shell: $('[data-sidebar-shell]'), clave: 'empresa' });
      NASCAR.Sidebar.prepararTooltips($('[data-sidebar-shell]'));
    }

    conectarTabs();
    conectarPedidos();
    conectarPagos();
    conectarDia();
    conectarVentas();
    conectarAjustes();

    NASCAR.Gestion.iniciar({
      raiz: RAIZ === document ? document.body : RAIZ,
      sucursalGlobal: () => sucursalGlobal,
      // Para el acceso rápido "Registrar entrada" desde 📦 Stock
      irATab: irATab,
    });

    NASCAR.Operacion.iniciar({
      raiz: RAIZ === document ? document.body : RAIZ,
      sucursalGlobal: () => sucursalGlobal,
    });

    montajeListo = true;
    montarModulos();

    pintarTablaRoles();

    $('#btnSalir').addEventListener('click', function () {
      S.logout();
      location.reload();
    });

    tictac();
    setInterval(tictac, 1000);

    refrescarTodo();

    // Otra pestaña (mesa o landing) creó un pedido -> se refleja aquí.
    S.onChange(refrescarTodo);
    // Relee cada 20 s por si algo quedó fuera de sincronía.
    setInterval(refrescarTodo, 20000);

    /* Avisos sonoros: a cada rol le suena lo suyo (js/avisos.js). */
    if (NASCAR.Avisos) NASCAR.Avisos.iniciar();

    U.iniciarComunes();
  }

  function tictac() {
    const d = new Date();
    $('#reloj').textContent = d.toLocaleTimeString('es-CO', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    $('#relojFecha').textContent = d.toLocaleDateString('es-CO', { weekday: 'short', day: 'numeric', month: 'short' });
  }

  function restarDias(iso, n) {
    const d = S.desdeISO(iso);
    d.setDate(d.getDate() - n);
    return S.aISO(d);
  }
  function sumarDias(iso, n) {
    return restarDias(iso, -n);
  }

  /* ---------------------------------------------------------------
     Montaje de los módulos grandes, que viven en sus propios archivos.
     Aquí sólo se les entrega su contenedor y el selector de sucursal,
     para que respeten el filtro global del panel.

     Se monta lo que el perfil puede ver Y la empresa tiene contratado
     (A.puede ya comprueba las dos cosas). Se vuelve a llamar al cambiar
     de usuario sin recargar, porque entrar con otra persona puede
     significar otra empresa y, con ella, otros módulos: lo que no
     estaba montado se monta entonces.

     Cada módulo se monta una sola vez; `montados` evita duplicar
     manejadores si se entra y se sale varias veces.
     --------------------------------------------------------------- */
  const montados = {};
  let montajeListo = false; // hasta que el panel base esté armado

  function montarModulos() {
    const modulos = {
      inventario: {
        permiso: 'cierres',
        montar: () =>
          NASCAR.Inventario.iniciarPanel({
            raiz: $('[data-panel="inventario"]'),
            sucursalGlobal: () => sucursalGlobal,
          }),
      },
      /* Pestaña 📦 Cierre: la pantalla de registro, la misma que usa
         cierre.html. */
      cierre: {
        permiso: 'cierres_registrar',
        montar: () => NASCAR.Inventario.iniciarRegistro($('[data-registro-cierre]')),
      },
      /* Entradas de mercancía: pestaña propia con su permiso, para que
         caja pueda recibir mercancía sin ver el cruce ni los cierres. */
      entradas: {
        permiso: 'entradas',
        montar: () =>
          NASCAR.Inventario.iniciarEntradas({
            raiz: $('[data-panel="entradas"]'),
            sucursalGlobal: () => sucursalGlobal,
          }),
      },
      gastos: {
        permiso: 'gastos',
        montar: () =>
          NASCAR.Gastos.iniciar({
            raiz: $('[data-panel="gastos"]'),
            sucursalGlobal: () => sucursalGlobal,
          }),
      },
      /* 📊 Cruce de información: el informe de caja de la jornada. Es
         sólo consulta sobre ventas, gastos y cierres; lo único que
         registra es la base de caja. */
      informe: {
        permiso: 'informe',
        montar: () =>
          NASCAR.Informe.iniciar({
            raiz: $('[data-panel="informe"]'),
            sucursalGlobal: () => sucursalGlobal,
            irATab: irATab,
          }),
      },
    };

    Object.keys(modulos).forEach(function (clave) {
      if (montados[clave]) return;
      if (!A.puede(modulos[clave].permiso)) return;
      modulos[clave].montar();
      montados[clave] = true;
    });
  }

  /* ---------------------------------------------------------------
     Permisos: qué pestañas ve quien está conectado.

     Ocultar la pestaña es sólo la mitad; cada acción del panel vuelve
     a comprobar el permiso antes de ejecutarse (NASCAR.Auth.exigir).
     --------------------------------------------------------------- */
  function aplicarPermisos() {
    if (montajeListo) montarModulos();

    const visibles = A.seccionesVisibles();
    const usuario = A.getUsuarioActual();

    $$('.tab').forEach(function (t) {
      t.classList.toggle('oculto', visibles.indexOf(t.dataset.tab) < 0);
    });

    /* La unidad del contexto. Quien está asignado a una unidad trabaja en
       la suya: el selector se ve —para saber dónde se está— pero no se
       puede cambiar. */
    pintarSelectorUnidad();
    $('#campoSucursalGlobal').classList.remove('oculto');

    /* Barra de contexto de plataforma.

       Quien viene de Taseca conserva su identidad al entrar a una
       empresa: sigue siendo superadmin con scope de plataforma, y lo
       único que cambió es qué empresa está mirando. La barra lo dice y
       ofrece el camino de vuelta. Para un usuario de la empresa no
       existe. */
    const barra = $('#barraPlataforma');
    if (barra) {
      const dePlataforma = A.esPlataforma();
      barra.classList.toggle('oculto', !dePlataforma);
      if (dePlataforma) {
        const e = A.empresaActual();
        $('#bpEmpresa').textContent = e ? e.nombre : 'sin empresa';
        // En el archivo único no viaja el panel de Taseca: no hay a dónde volver.
        const volver = barra.querySelector('a[href="taseca-admin.html"]');
        if (volver && SOLO_ARCHIVO) volver.classList.add('oculto');
      }
    }

    // Identidad visible en todo momento
    const chip = $('#usuarioChip');
    if (usuario) {
      chip.innerHTML =
        '<i>' + A.iconoRol(usuario.rol) + '</i>' +
        '<div><b>' + U.esc(usuario.nombre) + '</b>' +
        '<span>' + U.esc(A.nombreRol(usuario.rol)) + '</span></div>';
    }

    // Se abre en la primera pestaña a la que sí tiene acceso
    const inicial = A.seccionInicial();
    if (inicial) irATab(inicial);

    /* Un grupo del menú en el que este perfil no tiene ninguna opción no
       se muestra. Va DESPUÉS de decidir qué .tab se ven y sólo lee esa
       decisión: agrupar no da ni quita acceso a nada. */
    if (NASCAR.Sidebar && NASCAR.Sidebar.actualizarGrupos)
      NASCAR.Sidebar.actualizarGrupos($('[data-sidebar-shell]'));
  }

  function irATab(tab) {
    const anterior = tabActiva;
    tabActiva = tab;
    // Con la base de datos, el historial de ventas se descarga sólo al pedirlo
    if (tab === 'ventas' && NASCAR.Remoto) NASCAR.Remoto.asegurarHistorial();
    // …y el inventario se pone al día al entrar a sus secciones
    if (NASCAR.Remoto && ['stock', 'inventario', 'entradas', 'cierre'].indexOf(tab) >= 0)
      NASCAR.Remoto.refrescarInventario();
    if (NASCAR.Remoto && (tab === 'gastos' || tab === 'informe')) NASCAR.Remoto.refrescarCaja();
    // La preferencia de avisos se puede haber cambiado desde el botón 🔔 de la barra
    if (tab === 'ajustes' && pintarAvisos) pintarAvisos();
    $$('.tab').forEach((t) => t.classList.toggle('is-activo', t.dataset.tab === tab));
    $$('.panel').forEach((p) => p.classList.toggle('is-activo', p.dataset.panel === tab));

    /* Grupos del menú lateral: se marca el que contiene la sección y, si
       se acaba de llegar a ella con su grupo cerrado, se abre. Sólo pinta:
       a qué sección se puede ir ya lo decidió quien llama. */
    if (NASCAR.Sidebar && NASCAR.Sidebar.revelarActivo)
      NASCAR.Sidebar.revelarActivo($('[data-sidebar-shell]'), { abrir: anterior !== tab });
  }

  function conectarTabs() {
    $('#tabs').addEventListener('click', function (e) {
      const b = e.target.closest('.tab');
      if (!b) return;
      if (A.seccionesVisibles().indexOf(b.dataset.tab) < 0) {
        /* Se distingue el motivo: que el módulo no esté contratado no
           es lo mismo que no tener el perfil para entrar. */
        const modulo = (NASCAR.MODULO_DE_TAB || {})[b.dataset.tab];
        if (!A.hasModule(modulo)) return A.exigirModulo(modulo);
        return U.toast('Tu perfil no tiene acceso a esa sección.', 'error');
      }
      irATab(b.dataset.tab);
      refrescarTodo();
    });
  }

  function pintarTablaRoles() {
    const tabla = $('#tablaRoles');
    if (!tabla) return;
    /* Sólo los roles del restaurante. El SuperAdmin pertenece a la
       plataforma Taseca, que está por encima de esta empresa y no se
       administra desde aquí. */
    tabla.innerHTML = A.rolesDeEmpresa()
      .map(function (k) {
        const r = A.ROLES[k];
        const permisos =
          r.permisos.indexOf('*') >= 0
            ? ['Todos los permisos del sistema']
            : r.permisos.map((p) => A.PERMISOS[p] || p);
        return (
          '<tr><td style="white-space:nowrap"><b>' + r.icono + ' ' + U.esc(r.nombre) + '</b></td>' +
          '<td>' + U.esc(r.descripcion) +
          '<div class="fila mt-8" style="gap:6px">' +
          permisos.map((p) => '<span class="badge badge--linea">' + U.esc(p) + '</span>').join('') +
          '</div></td></tr>'
        );
      })
      .join('');
  }

  /* Selector de unidad de la cabecera. Se repinta en cada refresco: una
     unidad creada, renombrada o desactivada —o elegida en otra pestaña—
     se refleja al momento, y `sucursalGlobal` nunca se queda con la
     unidad anterior. */
  function pintarSelectorUnidad() {
    const sel = $('#sucursalGlobal');
    if (!sel) return;
    const actual = S.unidadActivaId();
    const atada = A.sucursalDelUsuario();
    const lista = atada
      ? S.getSucursales({ todas: true }).filter((s) => Number(s.id) === Number(atada))
      : S.getSucursales();

    const html = lista.length
      ? lista
          .map(
            (s) =>
              '<option value="' + s.id + '">' + S.getTipoNegocio(s.tipoNegocio).icono + ' ' +
              U.esc(s.nombre) + (s.activa === false ? ' (inactiva)' : '') + '</option>'
          )
          .join('')
      : '<option value="">Sin unidades activas</option>';
    if (sel.dataset.html !== html) {
      sel.innerHTML = html;
      sel.dataset.html = html;
    }
    sel.value = actual ? String(actual) : '';
    sel.disabled = !!atada || lista.length < 2;
    sucursalGlobal = actual ? String(actual) : '';
  }

  function refrescarTodo() {
    pintarSelectorUnidad();
    pintarPedidos();
    pintarPagos();
    pintarDiaAdmin();
    pintarVentas();
    pintarQR();
    if (A.puede('cierres')) NASCAR.Inventario.refrescarPanel();
    if (A.puede('entradas')) NASCAR.Inventario.refrescarEntradas();
    NASCAR.Gestion.refrescar();
    NASCAR.Operacion.refrescar();
    if (A.puede('gastos')) NASCAR.Gastos.refrescar();
    if (A.puede('informe')) NASCAR.Informe.refrescar();
    pintarContadores();
  }

  function pintarContadores() {
    const f = { activos: true };
    if (sucursalGlobal) f.sucursalId = sucursalGlobal;
    const activos = S.getPedidos(f).length;
    const pillP = $('#pillPedidos');
    pillP.textContent = activos;
    pillP.classList.toggle('oculto', activos === 0);

    const porConfirmar = pedidosPorConfirmar().length;
    const pillPa = $('#pillPagos');
    pillPa.textContent = porConfirmar;
    pillPa.classList.toggle('oculto', porConfirmar === 0);

    // Cierres registrados que todavía no ha revisado administración
    const fc = { estado: 'completado' };
    if (sucursalGlobal) fc.sucursalId = sucursalGlobal;
    const porRevisar = S.getCierres(fc).length;
    const pillCi = $('#pillCierres');
    pillCi.textContent = porRevisar;
    pillCi.classList.toggle('oculto', porRevisar === 0);

    // Gastos registrados que todavía nadie ha confirmado
    const fg = { estado: 'registrado' };
    if (sucursalGlobal) fg.sucursalId = sucursalGlobal;
    const gastosPend = S.getGastos(fg).length;
    const pillGa = $('#pillGastos');
    pillGa.textContent = gastosPend;
    pillGa.classList.toggle('oculto', gastosPend === 0 || !A.puede('gastos_confirmar'));

    // La marca es la de la empresa que se está atendiendo, no una fija
    document.title =
      (activos ? '(' + activos + ') ' : '') +
      ((S.getConfig().marca || 'Panel') + ' · Panel administrativo');
  }

  /* =================================================================
     TAB · PEDIDOS
     ================================================================= */
  function conectarPedidos() {
    ['#fTipoPedido', '#fFechaPedido', '#fSoloActivos'].forEach((s) =>
      $(s).addEventListener('change', pintarPedidos)
    );
    $('#btnRefrescar').addEventListener('click', function () {
      refrescarTodo();
      U.toast('Actualizado.', 'info');
    });

    $('#tablero').addEventListener('click', function (e) {
      const avanzar = e.target.closest('[data-avanzar]');
      if (avanzar) {
        e.stopPropagation();
        if (!A.exigir('pedidos_gestionar')) return;
        S.avanzarEstado(avanzar.dataset.avanzar);
        return U.toast('Pedido actualizado.');
      }
      const ver = e.target.closest('[data-ver]');
      if (ver) return verDetallePedido(ver.dataset.ver);
    });
  }

  function pintarPedidos() {
    const filtro = { fecha: $('#fFechaPedido').value || S.hoy() };
    if (sucursalGlobal) filtro.sucursalId = sucursalGlobal;
    if ($('#fTipoPedido').value) filtro.tipo = $('#fTipoPedido').value;

    let pedidos = S.getPedidos(filtro);
    const soloActivos = $('#fSoloActivos').checked;

    // KPIs del día
    const v = S.ventas(filtro.fecha, filtro.fecha, sucursalGlobal || null);
    const activos = pedidos.filter((p) => p.estado !== 'entregado' && p.estado !== 'cancelado');

    $('#kpisPedidos').innerHTML =
      kpi('Pedidos activos', activos.length, 'En cocina o en ruta', 'rojo') +
      kpi('Pedidos del día', v.pedidos, 'Sin contar cancelados') +
      kpi('Vendido hoy', U.money(v.total), 'Domicilios incluidos', 'verde') +
      kpi('Ticket promedio', U.money(v.ticketPromedio), v.pedidos + ' pedidos') +
      kpi('Por cobrar', U.money(v.montoPendiente), v.pendientesCobro + ' pedidos', 'ambar');

    // Tablero por estado. 'camino' sólo aparece si hay domicilios en juego.
    const hayDomicilios = pedidos.some((p) => p.tipo === 'domicilio');
    let columnas = S.ESTADOS.filter((e) => e !== 'camino' || hayDomicilios);
    if (!soloActivos) columnas = columnas.concat(['cancelado']);

    $('#tablero').style.gridTemplateColumns =
      'repeat(' + Math.min(columnas.length, 5) + ', minmax(0,1fr))';

    $('#tablero').innerHTML = columnas
      .map(function (estado) {
        let enEstado = pedidos.filter((p) => p.estado === estado);
        if (soloActivos && (estado === 'entregado' || estado === 'cancelado')) {
          enEstado = enEstado.slice(0, 5); // sólo los últimos, como referencia
        }

        return (
          '<div class="columna columna--' + estado + '">' +
          '<div class="columna__head"><span>' + S.ETIQUETA_ESTADO[estado] + '</span>' +
          '<span class="badge badge--gris">' + enEstado.length + '</span></div>' +
          '<div class="columna__body">' +
          (enEstado.length
            ? enEstado.map(tarjetaPedido).join('')
            : '<p class="mini tenue centro" style="padding:20px 0">Sin pedidos</p>') +
          '</div></div>'
        );
      })
      .join('');
  }

  function tarjetaPedido(p) {
    const suc = U.sucursal(p.sucursalId);
    const minutos = Math.floor((Date.now() - new Date(p.creado).getTime()) / 60000);
    const urgente = p.estado !== 'entregado' && p.estado !== 'cancelado' && minutos > 30;

    const siguiente = {
      nuevo: 'A preparación',
      preparacion: 'Marcar listo',
      listo: p.tipo === 'domicilio' ? 'Despachar' : 'Entregado',
      camino: 'Entregado',
    }[p.estado];

    return (
      '<article class="tarjeta-pedido' + (urgente ? ' urgente' : '') + '" data-ver="' + p.id + '">' +
      '<div class="tp__top">' +
      '<span class="tp__codigo">' + U.esc(p.codigo) + '</span>' +
      '<span class="badge ' + (p.tipo === 'mesa' ? 'badge--azul' : 'badge--rojo') + '">' +
      (p.tipo === 'mesa' ? 'Mesa ' + U.esc(p.mesa) : 'Domicilio') + '</span>' +
      '</div>' +

      '<div class="tp__meta">' +
      U.esc(p.cliente.nombre || '—') + ' · ' + U.esc(suc.corto) + '<br>' +
      '<span class="' + (urgente ? 'rojo' : 'tenue') + '">🕐 ' + U.haceCuanto(p.creado) + '</span>' +
      (p.tipo === 'domicilio' ? ' · ' + U.esc(p.cliente.zona || '') : '') +
      '</div>' +

      '<div class="tp__items">' +
      p.items
        .slice(0, 4)
        .map((it) => '<div><span>' + it.cantidad + '× ' + U.esc(it.nombre) +
          (it.detalle ? ' <small class="tenue">(' + U.esc(it.detalle) + ')</small>' : '') + '</span></div>')
        .join('') +
      (p.items.length > 4 ? '<div class="tenue">+ ' + (p.items.length - 4) + ' más…</div>' : '') +
      '</div>' +

      '<div class="tp__pie">' +
      '<div><span class="tp__total">' + U.money(p.total) + '</span><br>' + insigniaPago(p) + '</div>' +
      (siguiente
        ? '<button class="btn btn--azul btn--xs" data-avanzar="' + p.id + '">' + siguiente + ' →</button>'
        : '') +
      '</div>' +
      '</article>'
    );
  }

  function insigniaPago(p) {
    const m = { efectivo: 'Efectivo', transferencia: 'Transf.', datafono: 'Datáfono' }[p.metodoPago] || p.metodoPago;
    const e = {
      confirmado: '<span class="badge badge--verde">Pagado</span>',
      reportado: '<span class="badge badge--ambar">Reportado</span>',
      rechazado: '<span class="badge badge--rojo">Rechazado</span>',
      pendiente: p.estado === 'entregado'
        ? '<span class="badge badge--ambar">Por cobrar en caja</span>'
        : '<span class="badge badge--linea">Pendiente</span>',
    }[p.estadoPago];
    return '<span class="mini tenue">' + m + '</span> ' + e;
  }

  /* --- Detalle del pedido (modal) -------------------------------- */
  function verDetallePedido(pedidoId) {
    const p = S.getPedido(pedidoId);
    if (!p) return;
    const suc = U.sucursal(p.sucursalId);

    const m = U.modal({
      titulo: 'Pedido ' + p.codigo,
      ancho: 560,
      contenido: '<div id="detBody"></div>',
    });

    function pintar() {
      const p = S.getPedido(pedidoId);
      const cont = U.$('#detBody', m.raiz);

      cont.innerHTML =
        '<div class="fila fila--entre mb-16">' +
        '<span class="badge ' + (p.tipo === 'mesa' ? 'badge--azul' : 'badge--rojo') + '">' +
        (p.tipo === 'mesa' ? 'Mesa ' + U.esc(p.mesa) : 'Domicilio') + '</span>' +
        '<span class="badge ' + (p.estado === 'anulado' ? 'badge--rojo' : 'badge--gris') + '">' +
        S.ETIQUETA_ESTADO[p.estado] + '</span>' +
        insigniaPago(p) +
        '</div>' +

        avisoAnulada(p) +

        '<div class="caja-datos">' +
        '<div class="linea"><span class="tenue">Sucursal</span><b>' + U.esc(suc.nombre) + '</b></div>' +
        '<div class="linea"><span class="tenue">Cliente</span><b>' + U.esc(p.cliente.nombre || '—') + '</b></div>' +
        (p.cliente.telefono
          ? '<div class="linea"><span class="tenue">Teléfono</span><b>' + U.esc(p.cliente.telefono) + '</b></div>'
          : '') +
        (p.cliente.direccion
          ? '<div class="linea"><span class="tenue">Dirección</span><b class="derecha">' +
            U.esc(p.cliente.direccion) + '<br><span class="mini tenue">' + U.esc(p.cliente.zona || '') + '</span></b></div>'
          : '') +
        '<div class="linea"><span class="tenue">Recibido</span><b>' + U.hora(p.creado) + ' · ' + U.haceCuanto(p.creado) + '</b></div>' +
        (p.cliente.pagaCon
          ? '<div class="linea"><span class="tenue">Paga con</span><b>' + U.money(p.cliente.pagaCon) +
            ' <span class="mini tenue">(vueltas ' + U.money(Math.max(0, p.cliente.pagaCon - p.total)) + ')</span></b></div>'
          : '') +
        '</div>' +

        (p.cliente.notas
          ? '<div class="caja-datos" style="border-color:var(--ambar)"><b class="ambar">Observaciones</b>' +
            '<p class="mini" style="margin:4px 0 0">' + U.esc(p.cliente.notas) + '</p></div>'
          : '') +

        '<table class="detalle-items">' +
        p.items
          .map(
            (it) =>
              '<tr><td class="c">' + it.cantidad + '×</td>' +
              '<td>' + U.esc(it.nombre) +
              (it.detalle ? '<br><span class="mini">🍽️ ' + U.esc(it.detalle) + '</span>' : '') +
              (it.notas ? '<br><span class="mini ambar">📝 ' + U.esc(it.notas) + '</span>' : '') + '</td>' +
              '<td class="p">' + U.money(it.precio * it.cantidad) + '</td></tr>'
          )
          .join('') +
        '</table>' +

        '<div class="totales">' +
        '<div><span>Subtotal</span><span class="num">' + U.money(p.subtotal) + '</span></div>' +
        (p.domicilio ? '<div><span>Domicilio</span><span class="num">' + U.money(p.domicilio) + '</span></div>' : '') +
        '<div class="total"><span>Total</span><span class="num">' + U.money(p.total) + '</span></div>' +
        '</div>' +

        '<h4 class="mt-16" style="font-family:var(--f-cond);letter-spacing:.1em;text-transform:uppercase;font-size:14px;color:var(--gris)">Historial</h4>' +
        '<ul class="linea-tiempo">' +
        p.historial
          .map((h) => '<li class="hecho"><b>' + U.esc(h.texto) + '</b><span>' + U.hora(h.ts) + '</span></li>')
          .join('') +
        '</ul>' +

        '<div class="fila mt-16">' +
        /* Una factura anulada ya no se opera: ni cambia de estado, ni se
           cobra, ni se cancela, ni se vuelve a anular. */
        (p.estado !== 'entregado' && p.estado !== 'cancelado' && p.estado !== 'anulado'
          ? '<select class="select" id="detEstado" style="max-width:190px">' +
            S.flujoEstados(p.tipo)
              .map(
                (e) => '<option value="' + e + '"' + (e === p.estado ? ' selected' : '') + '>' +
                  S.ETIQUETA_ESTADO[e] + '</option>'
              )
              .join('') +
            '</select>'
          : '') +
        (p.estadoPago !== 'confirmado' && p.estado !== 'anulado'
          ? '<button class="btn btn--sm" id="detPagar" style="background:var(--verde);border-color:var(--verde);color:#04220f">✓ Confirmar pago</button>'
          : '') +
        '<div class="crece"></div>' +
        '<button class="btn btn--fantasma btn--sm" id="detImprimir">🖨 Comanda</button>' +
        (p.estado !== 'cancelado' && p.estado !== 'anulado'
          ? '<button class="btn btn--fantasma btn--sm" id="detCancelar" style="border-color:var(--rojo);color:var(--rojo-claro)">Cancelar</button>'
          : '') +
        /* Anular es sólo del Admin: es echar atrás una venta hecha y
           devolver mercancía al inventario. */
        (p.estado !== 'cancelado' && p.estado !== 'anulado' && A.puede('pedidos_anular')
          ? '<button class="btn btn--rojo btn--sm" id="detAnular">❌ Anular factura</button>'
          : '') +
        '</div>';

      const sel = U.$('#detEstado', m.raiz);
      if (sel)
        sel.addEventListener('change', function () {
          S.cambiarEstado(pedidoId, this.value);
          U.toast('Estado actualizado.');
          pintar();
        });

      const bp = U.$('#detPagar', m.raiz);
      if (bp) bp.addEventListener('click', () => abrirConfirmarPago(pedidoId, pintar));

      const bc = U.$('#detCancelar', m.raiz);
      if (bc)
        bc.addEventListener('click', function () {
          U.confirmar('¿Cancelar el pedido ' + p.codigo + '? No se contará en las ventas.', function () {
            S.cancelarPedido(pedidoId, 'Cancelado desde el panel');
            U.toast('Pedido cancelado.', 'info');
            pintar();
          }, 'Sí, cancelar');
        });

      const ba = U.$('#detAnular', m.raiz);
      if (ba) ba.addEventListener('click', () => abrirAnularFactura(pedidoId, pintar));

      U.$('#detImprimir', m.raiz).addEventListener('click', () => imprimirComanda(pedidoId));
    }

    pintar();
  }

  /* --- Aviso de factura anulada ----------------------------------
     Se ve arriba del todo, con el motivo, quién y cuándo. Una factura
     anulada tiene que reconocerse de un vistazo. */
  function avisoAnulada(p) {
    if (p.estado !== 'anulado' || !p.anulacion) return '';
    const a = p.anulacion;

    const retorno = a.productos && a.productos.length
      ? a.productos.map((x) => U.esc(x.codigo) + ' +' + x.cantidad).join(', ')
      : 'sin productos de inventario asociados';

    return (
      '<div class="caja mb-16" style="border-color:var(--rojo)">' +
      '<div class="fila" style="gap:10px;align-items:center">' +
      '<span class="badge badge--rojo" style="font-size:14px">ANULADA</span>' +
      '<b>' + U.esc(a.motivo) + '</b></div>' +
      '<p class="mini tenue" style="margin:8px 0 0">' +
      'Anuló <b>' + U.esc(a.usuarioNombre) + '</b>' +
      (a.rol ? ' (' + U.esc(A.nombreRol(a.rol)) + ')' : '') +
      ' el ' + U.esc(a.fecha) + ' a las ' + U.esc(a.hora) +
      ' · ' + U.esc(a.sucursalNombre) + '</p>' +
      '<p class="mini" style="margin:6px 0 0">Retorno de inventario: ' + retorno +
      (a.diferido
        ? ' <span class="ambar">· imputado a la jornada ' + U.esc(a.jornadaRetorno) +
          ', porque la del ' + U.esc(a.jornadaOriginal) + ' ya tenía cierre y no se toca.</span>'
        : ' · en la jornada ' + U.esc(a.jornadaRetorno) + '.') +
      '</p></div>'
    );
  }

  /* --- Anular factura -------------------------------------------
     Se enseña todo lo que se va a anular antes de preguntar, y el
     motivo es obligatorio. La barrera de verdad está en el permiso:
     el botón se oculta, pero la acción también se niega. */
  function abrirAnularFactura(pedidoId, alTerminar) {
    if (!A.exigir('pedidos_anular')) return;

    const p = S.getPedido(pedidoId);
    if (!p) return;

    const suc = U.sucursal(p.sucursalId);
    const productos = S.consumoDePedido(p);
    const metodo =
      { efectivo: 'Efectivo', transferencia: 'Transferencia', datafono: 'Datáfono' }[p.metodoPago] ||
      p.metodoPago;

    const m = U.modal({
      titulo: 'Anular factura ' + p.codigo,
      ancho: 520,
      contenido:
        '<p class="mb-16"><b>¿Está seguro de que desea anular esta factura?</b></p>' +

        '<div class="caja-datos mb-16">' +
        '<div class="linea"><span class="tenue">Factura</span><b>' + U.esc(p.codigo) + '</b></div>' +
        '<div class="linea"><span class="tenue">Fecha</span><b>' + U.esc(p.fecha) + ' · ' + U.hora(p.creado) + '</b></div>' +
        '<div class="linea"><span class="tenue">Cliente</span><b>' + U.esc(p.cliente.nombre || '—') + '</b></div>' +
        '<div class="linea"><span class="tenue">Sucursal</span><b>' + U.esc(suc.nombre) + '</b></div>' +
        '<div class="linea"><span class="tenue">Total</span><b>' + U.money(p.total) + '</b></div>' +
        '<div class="linea"><span class="tenue">Método de pago</span><b>' + U.esc(metodo) + '</b></div>' +
        '</div>' +

        (productos.length
          ? '<div class="caja-datos mb-16"><b class="mini">Retorno de inventario</b>' +
            productos
              .map(
                (x) =>
                  '<div class="linea"><span class="tenue">' + U.esc(x.nombre) +
                  ' <span class="mini">(' + U.esc(x.codigo) + ')</span></span><b>+' +
                  x.cantidad + '</b></div>'
              )
              .join('') +
            '</div>'
          : '<p class="mini tenue mb-16">Esta venta no tiene productos de inventario asociados: ' +
            'no hay nada que devolver.</p>') +

        '<label class="campo"><span>Motivo de la anulación *</span>' +
        '<textarea class="input" id="anMotivo" rows="2" placeholder="Por qué se anula esta factura"></textarea></label>' +

        '<p class="mini ambar">La factura no se borra: queda guardada como <b>ANULADA</b>, con su ' +
        'historial y su pago, y deja de contar como venta.</p>' +

        '<div class="fila fila--fin mt-16">' +
        '<button class="btn btn--fantasma" data-no>Cancelar</button>' +
        '<button class="btn btn--rojo" data-si>❌ Anular factura</button></div>',
    });

    U.$('[data-no]', m.raiz).onclick = m.cerrar;
    U.$('[data-si]', m.raiz).onclick = function () {
      const motivo = U.$('#anMotivo', m.raiz).value.trim();
      if (motivo.length < 3) return U.toast('El motivo de la anulación es obligatorio.', 'error');

      let r;
      try {
        r = S.anularPedido(pedidoId, motivo);
      } catch (err) {
        return U.toast(err.message, 'error');
      }

      m.cerrar();
      U.toast(
        'Factura ' + p.codigo + ' anulada.' +
          (r.retorno.productos.length
            ? r.retorno.diferido
              ? ' El retorno se imputó a la jornada ' + r.retorno.jornadaRetorno +
                ': la del cierre no se toca.'
              : ' Inventario devuelto.'
            : ''),
        'info'
      );
      if (alTerminar) alTerminar();
      refrescarTodo();
    };
  }

  /* --- Comanda para cocina --------------------------------------- */
  function imprimirComanda(pedidoId) {
    const p = S.getPedido(pedidoId);
    const suc = U.sucursal(p.sucursalId);

    const w = window.open('', '_blank', 'width=380,height=640');
    if (!w) return U.toast('El navegador bloqueó la ventana de impresión.', 'error');

    w.document.write(
      '<!DOCTYPE html><html lang="es"><head><meta charset="utf-8"><title>Comanda ' + p.codigo + '</title>' +
      '<style>' +
      'body{font:13px/1.45 "Courier New",monospace;padding:14px;max-width:300px;margin:0 auto;color:#000}' +
      'h1{font-size:19px;margin:0;text-align:center;letter-spacing:2px}' +
      'hr{border:0;border-top:1px dashed #000;margin:9px 0}' +
      '.f{display:flex;justify-content:space-between;gap:8px}' +
      '.it{margin:6px 0}.n{font-size:11px;font-style:italic;padding-left:14px}' +
      '.tot{font-size:16px;font-weight:bold}.c{text-align:center}' +
      '</style></head><body>' +

      '<h1>NASCAR</h1>' +
      '<div class="c">' + suc.nombre + '<br>' + suc.direccion + '<br>NIT ' + NASCAR.CONFIG.pago.nit + '</div>' +
      '<hr>' +
      '<div class="f"><b>' + p.codigo + '</b><span>' + new Date(p.creado).toLocaleString('es-CO') + '</span></div>' +
      '<div class="f"><span>' + (p.tipo === 'mesa' ? 'MESA ' + p.mesa : 'DOMICILIO') + '</span>' +
      '<span>' + (p.cliente.nombre || '') + '</span></div>' +
      (p.cliente.direccion ? '<div>' + p.cliente.direccion + (p.cliente.zona ? ' (' + p.cliente.zona + ')' : '') + '</div>' : '') +
      (p.cliente.telefono ? '<div>Tel: ' + p.cliente.telefono + '</div>' : '') +
      '<hr>' +

      p.items
        .map(
          (it) =>
            '<div class="it"><div class="f"><span>' + it.cantidad + ' x ' + it.nombre + '</span>' +
            '<span>' + U.money(it.precio * it.cantidad) + '</span></div>' +
            (it.detalle ? '<div class="n">' + U.esc(it.detalle) + '</div>' : '') +
            (it.notas ? '<div class="n">* ' + it.notas + '</div>' : '') + '</div>'
        )
        .join('') +

      '<hr>' +
      '<div class="f"><span>Subtotal</span><span>' + U.money(p.subtotal) + '</span></div>' +
      (p.domicilio ? '<div class="f"><span>Domicilio</span><span>' + U.money(p.domicilio) + '</span></div>' : '') +
      '<div class="f tot"><span>TOTAL</span><span>' + U.money(p.total) + '</span></div>' +
      '<hr>' +
      '<div>Pago: ' + p.metodoPago.toUpperCase() + ' (' + p.estadoPago + ')</div>' +
      (p.cliente.notas ? '<div><b>OBS:</b> ' + p.cliente.notas + '</div>' : '') +
      '<hr><div class="c">Gracias por preferirnos</div>' +
      '</body></html>'
    );
    w.document.close();
    w.focus();
    setTimeout(() => w.print(), 260);
  }

  /* =================================================================
     TAB · PAGOS
     ================================================================= */
  function pedidosPorConfirmar() {
    // Mesa y domicilio: todo pago pasa por caja, también el efectivo ya entregado
    const f = {};
    if (sucursalGlobal) f.sucursalId = sucursalGlobal;
    return S.getPedidos(f).filter(
      (p) => p.estado !== 'cancelado' && p.estado !== 'anulado' &&
        p.estadoPago !== 'confirmado' && p.estadoPago !== 'rechazado'
    );
  }

  function conectarPagos() {
    ['#fTipoPago', '#fEstadoPago', '#fPagoDesde', '#fPagoHasta'].forEach((s) =>
      $(s).addEventListener('change', pintarPagos)
    );

    $('#tablaPagos').addEventListener('click', function (e) {
      const c = e.target.closest('[data-confirmar]');
      if (c) return abrirConfirmarPago(c.dataset.confirmar, pintarPagos);

      const r = e.target.closest('[data-rechazar]');
      if (r) {
        const p = S.getPedido(r.dataset.rechazar);
        return U.confirmar(
          'Marcar el pago de ' + p.codigo + ' como RECHAZADO. El pedido queda sin cobrar.',
          function () {
            if (!A.exigir('pagos')) return;
            try {
              S.rechazarPago(p.id, 'No se encontró el pago', A.firma());
            } catch (err) {
              return U.toast(err.message, 'error');
            }
            U.toast('Pago marcado como rechazado.', 'info');
            refrescarTodo();
          },
          'Sí, rechazar'
        );
      }

      const v = e.target.closest('[data-ver]');
      if (v) return verDetallePedido(v.dataset.ver);

      const comp = e.target.closest('[data-ver-comprobante]');
      if (comp) return verComprobante(comp.dataset.verComprobante);
    });
  }

  /* Visor del comprobante que adjuntó el cliente, con los botones de
     confirmar y rechazar a la mano. */
  function verComprobante(pedidoId) {
    const p = S.getPedido(pedidoId);
    const comp = S.getComprobante(pedidoId);
    if (!p) return;
    if (!comp)
      return U.toast('Este pedido no tiene comprobante adjunto.', 'info');

    const m = U.modal({
      titulo: 'Comprobante · ' + p.codigo,
      ancho: 560,
      contenido:
        '<div class="comprobante-visor">' +
        '<img src="' + comp.dataUrl + '" alt="Comprobante de pago de ' + U.esc(p.codigo) + '">' +
        '</div>' +

        '<div class="caja-datos">' +
        '<div class="linea"><span class="tenue">Cliente</span><b>' + U.esc(p.cliente.nombre || '—') + '</b></div>' +
        '<div class="linea"><span class="tenue">Total del pedido</span><b>' + U.money(p.total) + '</b></div>' +
        '<div class="linea"><span class="tenue">Referencia del cliente</span><b>' +
        (p.comprobante ? U.esc(p.comprobante) : '<span class="tenue">sin referencia</span>') + '</b></div>' +
        '<div class="linea"><span class="tenue">Adjuntado</span><b>' +
        new Date(comp.subido).toLocaleString('es-CO') + '</b></div>' +
        '<div class="linea"><span class="tenue">Archivo</span><b>' +
        U.esc(comp.nombreArchivo || 'imagen') + ' · ' + comp.pesoKB + ' KB</b></div>' +
        '</div>' +

        '<p class="mini ambar">Compara el valor y la fecha con el extracto del banco antes de confirmar. ' +
        'Una imagen se puede editar.</p>' +

        (p.estadoPago === 'confirmado'
          ? '<div class="caja-datos" style="border-color:var(--verde)"><b class="verde">Este pago ya está confirmado</b></div>'
          : '<div class="fila fila--fin">' +
            '<button class="btn btn--fantasma" id="vcRechazar" ' +
            'style="border-color:var(--rojo);color:var(--rojo-claro)">✕ Rechazar</button>' +
            '<button class="btn" id="vcConfirmar" ' +
            'style="background:var(--verde);border-color:var(--verde);color:#04220f">✓ Confirmar pago</button>' +
            '</div>'),
    });

    const bc = U.$('#vcConfirmar', m.raiz);
    if (bc)
      bc.addEventListener('click', function () {
        if (!A.exigir('pagos')) return;
        m.cerrar();
        abrirConfirmarPago(pedidoId, refrescarTodo);
      });

    const br = U.$('#vcRechazar', m.raiz);
    if (br)
      br.addEventListener('click', function () {
        if (!A.exigir('pagos')) return;
        U.confirmar(
          'Marcar el pago de ' + p.codigo + ' como RECHAZADO. El pedido queda sin cobrar.',
          function () {
            try {
              S.rechazarPago(p.id, 'Comprobante no válido', A.firma());
            } catch (err) {
              return U.toast(err.message, 'error');
            }
            m.cerrar();
            U.toast('Pago marcado como rechazado.', 'info');
            refrescarTodo();
          },
          'Sí, rechazar'
        );
      });
  }

  function abrirConfirmarPago(pedidoId, alTerminar) {
    if (!A.exigir('pagos')) return;
    const p = S.getPedido(pedidoId);
    if (!p) return;
    const comp = S.getComprobante(pedidoId);

    /* Con qué pagó de verdad: los métodos activos de la empresa. Si el del
       pedido ya no está activo, igual se ofrece para poder dejarlo como está. */
    const metodos = (S.getConfig().metodosPago || []).filter((x) => x.activo || x.id === p.metodoPago);
    if (!metodos.some((x) => x.id === p.metodoPago)) metodos.unshift({ id: p.metodoPago, nombre: p.metodoPago });
    const nombreCorto = (x) =>
      ({ efectivo: 'Efectivo', transferencia: 'Transferencia', datafono: 'Datáfono' }[x.id] || x.nombre || x.id);

    const m = U.modal({
      titulo: 'Confirmar pago · ' + p.codigo,
      ancho: 450,
      contenido:
        '<div class="caja-datos">' +
        '<div class="linea"><span class="tenue">' + (p.tipo === 'mesa' ? 'Mesa' : 'Cliente') + '</span><b>' +
        U.esc(p.tipo === 'mesa' ? p.mesa + (p.cliente.nombre ? ' · ' + p.cliente.nombre : '') : p.cliente.nombre || '—') + '</b></div>' +
        '<div class="linea"><span class="tenue">Pedido</span><b>' + U.esc(S.ETIQUETA_ESTADO[p.estado] || p.estado) + '</b></div>' +
        (p.comprobante
          ? '<div class="linea"><span class="tenue">Ref. del cliente</span><b>' + U.esc(p.comprobante) + '</b></div>'
          : '') +
        '<div class="linea"><span class="tenue">Total a recibir</span><b>' + U.money(p.total) + '</b></div>' +
        '</div>' +

        (comp
          ? '<div class="comprobante-visor mb-16">' +
            '<img src="' + comp.dataUrl + '" alt="Comprobante adjunto">' +
            '<p class="mini tenue" style="margin:0">Comprobante adjuntado por el cliente</p></div>'
          : '') +

        '<label class="campo"><span>¿Con qué pagó el cliente? *</span>' +
        '<select class="select" id="cpMetodo">' +
        metodos
          .map((x) => '<option value="' + U.esc(x.id) + '"' + (x.id === p.metodoPago ? ' selected' : '') + '>' +
            U.esc(nombreCorto(x)) + '</option>')
          .join('') +
        '</select></label>' +

        '<p class="mini ambar">Confirma sólo con el dinero en la mano, el voucher del datáfono o la transferencia ' +
        'vista en el banco. Esta acción marca el pedido como cobrado y ya no se puede cambiar.</p>' +

        '<label class="campo"><span>Referencia / comprobante</span>' +
        '<input class="input" id="cpRef" placeholder="Número de la transacción" value="' + U.esc(p.comprobante || '') + '"></label>' +

        '<div class="fila fila--fin">' +
        '<button class="btn btn--fantasma" id="cpNo">Cancelar</button>' +
        '<button class="btn" id="cpSi" style="background:var(--verde);border-color:var(--verde);color:#04220f">✓ Confirmar pago</button>' +
        '</div>',
    });

    U.$('#cpNo', m.raiz).onclick = m.cerrar;
    U.$('#cpSi', m.raiz).onclick = function () {
      if (!A.exigir('pagos')) return;
      const metodo = U.$('#cpMetodo', m.raiz).value;
      // Queda registrado quién confirmó el pago, cuándo y con qué método
      try {
        S.confirmarPago(pedidoId, U.$('#cpRef', m.raiz).value.trim(), A.firma(), metodo);
      } catch (err) {
        return U.toast(err.message, 'error');
      }
      m.cerrar();
      U.toast('Pago de ' + p.codigo + ' confirmado · ' + nombreCorto(metodos.find((x) => x.id === metodo) || { id: metodo }) + '.');
      if (alTerminar) alTerminar();
      refrescarTodo();
    };
  }

  function pintarPagos() {
    const filtro = {
      desde: $('#fPagoDesde').value,
      hasta: $('#fPagoHasta').value,
    };
    const tipo = ($('#fTipoPago') || {}).value;
    if (tipo) filtro.tipo = tipo;
    if (sucursalGlobal) filtro.sucursalId = sucursalGlobal;

    /* Las anuladas salen de aquí igual que las canceladas: ya no hay
       nada que cobrar. El movimiento de pago NO se borra — queda en la
       factura, con su estado de pago tal como estaba al anular. */
    let lista = S.getPedidos(filtro).filter(
      (p) => p.estado !== 'cancelado' && p.estado !== 'anulado'
    );
    const modo = $('#fEstadoPago').value;

    if (modo === 'por-confirmar')
      lista = lista.filter((p) => p.estadoPago !== 'confirmado' && p.estadoPago !== 'rechazado');
    else if (modo === 'confirmado') lista = lista.filter((p) => p.estadoPago === 'confirmado');
    else if (modo === 'rechazado') lista = lista.filter((p) => p.estadoPago === 'rechazado');

    const porConfirmar = lista.filter((p) => p.estadoPago !== 'confirmado' && p.estadoPago !== 'rechazado');
    const monto = porConfirmar.reduce((s, p) => s + p.total, 0);
    const entregados = porConfirmar.filter((p) => p.estado === 'entregado');

    $('#kpisPagos').innerHTML =
      kpi('Por confirmar', porConfirmar.length, 'Mesa y domicilio sin cobrar', 'ambar') +
      kpi('Monto pendiente', U.money(monto), 'Dinero aún no recibido en caja', 'rojo') +
      kpi('Entregados sin cobrar', entregados.length, U.money(entregados.reduce((s, p) => s + p.total, 0)),
        entregados.length ? 'rojo' : 'verde') +
      kpi('Confirmados en el rango', lista.filter((p) => p.estadoPago === 'confirmado').length, '', 'verde');

    if (!lista.length) {
      $('#tablaPagos').innerHTML =
        '<tr><td colspan="7"><div class="vacio" style="border:0">✅ No hay pagos pendientes en este rango.</div></td></tr>';
      return;
    }

    $('#tablaPagos').innerHTML = lista
      .map(function (p) {
        const pendiente = p.estadoPago !== 'confirmado' && p.estadoPago !== 'rechazado';
        return (
          '<tr>' +
          '<td><b class="mono">' + U.esc(p.codigo) + '</b><br><span class="mini tenue">' +
          U.esc(U.sucursal(p.sucursalId).corto) + ' · ' + U.hora(p.creado) + '</span></td>' +

          '<td><span class="badge ' + (p.tipo === 'mesa' ? 'badge--azul' : 'badge--rojo') + '">' +
          (p.tipo === 'mesa' ? 'Mesa ' + U.esc(p.mesa) : 'Domicilio') + '</span> ' +
          '<span class="mini tenue">' + U.esc(S.ETIQUETA_ESTADO[p.estado] || p.estado) + '</span><br>' +
          U.esc(p.cliente.nombre || '') +
          (p.cliente.telefono ? ' <span class="mini tenue">' + U.esc(p.cliente.telefono) + '</span>' : '') + '</td>' +

          '<td><span class="badge badge--linea">' + U.esc(p.metodoPago) + '</span>' +
          (pendiente ? '<br><span class="mini tenue">por confirmar</span>' : '') + '</td>' +

          '<td class="mini">' +
          (p.comprobante || p.referenciaPago
            ? U.esc(p.comprobante || p.referenciaPago)
            : '<span class="tenue">—</span>') +
          (S.getComprobante(p.id)
            ? '<br><button class="comprobante-chip mt-8" data-ver-comprobante="' + p.id + '">' +
              '📎 Comprobante adjunto</button>'
            : '') +
          '</td>' +

          '<td class="derecha num" style="font-size:16px">' + U.money(p.total) + '</td>' +

          '<td>' +
          {
            confirmado: '<span class="badge badge--verde">Confirmado</span>',
            reportado: '<span class="badge badge--ambar">Reportado</span>',
            rechazado: '<span class="badge badge--rojo">Rechazado</span>',
            pendiente: '<span class="badge badge--linea">Pendiente</span>',
          }[p.estadoPago] +
          '</td>' +

          '<td class="nowrap">' +
          (pendiente
            ? '<button class="btn btn--xs" data-confirmar="' + p.id + '" style="background:var(--verde);border-color:var(--verde);color:#04220f">✓ Confirmar</button> ' +
              '<button class="btn btn--fantasma btn--xs" data-rechazar="' + p.id + '">✕</button> '
            : '') +
          '<button class="btn btn--fantasma btn--xs" data-ver="' + p.id + '">Ver</button>' +
          '</td>' +
          '</tr>'
        );
      })
      .join('');
  }

  /* =================================================================
     TAB · MENÚ DEL DÍA

     Cada sucursal, en cada fecha, publica UNA modalidad:
       · Menú armado   → categorías (Sopa, Principio…) con opciones; el
                         cliente elige una por categoría. Un solo precio.
       · Menú del chef → platos completos, uno por registro.

     Aquí sólo se pinta y se llama al store: qué se publica, las
     validaciones y el permiso viven en NASCAR.Store. Cada acción exige
     el permiso 'menu' antes de ejecutarse, y el store lo vuelve a exigir.
     ================================================================= */
  let sucursalDia = null; // la sucursal que se está editando en esta pestaña
  let globalVistaDia = null; // para seguir al selector de sucursal de arriba

  function claveDia() {
    // El menú del día es de la UNIDAD ACTIVA: se cambia arriba, no aquí
    const suc = Number(sucursalGlobal) || S.unidadActivaId() || null;
    sucursalDia = suc;
    globalVistaDia = sucursalGlobal;

    return { fecha: $('#fFechaDia').value || S.hoy(), sucursalId: suc };
  }

  /* Ejecuta una acción del menú: permiso primero, error contado en
     pantalla en vez de romper, y repintado. */
  function accionDia(fn, mensaje) {
    if (!A.exigir('menu')) return false;
    try {
      fn();
    } catch (err) {
      U.toast(err.message || 'No se pudo guardar.', 'error');
      return false;
    }
    if (mensaje) U.toast(mensaje);
    pintarDiaAdmin(true);
    return true;
  }

  function fechaLargaDia(iso) {
    return S.desdeISO(iso).toLocaleDateString('es-CO', { weekday: 'long', day: 'numeric', month: 'long' });
  }

  function infoTipoDia(tipo) {
    return (NASCAR.TIPOS_MENU_DIA || []).find((x) => x.id === tipo) || { id: tipo, nombre: tipo, icono: '' };
  }

  function conectarDia() {
    $('#fFechaDia').addEventListener('change', () => pintarDiaAdmin(true));
    $('#fSucDia').addEventListener('change', function () {
      sucursalDia = Number(this.value);
      pintarDiaAdmin(true);
    });

    $('#btnCopiarAyer').addEventListener('click', function () {
      const k = claveDia();
      copiarDia(restarDias(k.fecha, 1), k.fecha, k.sucursalId, 'ayer');
    });
    $('#btnCopiarManana').addEventListener('click', function () {
      const k = claveDia();
      copiarDia(k.fecha, sumarDias(k.fecha, 1), k.sucursalId, 'manana');
    });

    const cont = $('#listaDiaAdmin');
    cont.addEventListener('click', clicDia);

    cont.addEventListener('submit', function (e) {
      const k = claveDia();

      // Datos del menú armado
      const fa = e.target.closest('[data-form-armado]');
      if (fa) {
        e.preventDefault();
        const campos = fa.elements;
        return accionDia(
          () =>
            S.guardarDatosArmado(k.fecha, k.sucursalId, {
              nombre: campos.nombre.value,
              precio: campos.precio.value,
              descripcion: campos.descripcion.value,
              disponible: campos.disponible.checked,
            }),
          'Datos del menú guardados.'
        );
      }

      // Título y mensaje del portal
      const ft = e.target.closest('[data-form-texto]');
      if (ft) {
        e.preventDefault();
        const campos = ft.elements;
        const alcance = campos.alcance.value;
        return accionDia(
          () =>
            S.guardarTextoMenuDia(
              k.fecha,
              k.sucursalId,
              { titulo: campos.titulo.value, mensaje: campos.mensaje.value },
              alcance
            ),
          alcance === 'unidad'
            ? 'Texto guardado para todos los días de esta unidad.'
            : 'Texto guardado sólo para esta fecha.'
        );
      }

      // Opción nueva: se escribe y Enter, sin abrir ventanas
      const fo = e.target.closest('[data-nueva-opcion]');
      if (fo) {
        e.preventDefault();
        const catId = fo.dataset.nuevaOpcion;
        const nombre = fo.querySelector('input').value;
        const ok = accionDia(
          () => S.guardarOpcionArmado(k.fecha, k.sucursalId, catId, { nombre: nombre }),
          'Opción agregada.'
        );
        if (ok) {
          // El cursor vuelve a la misma categoría para seguir agregando
          const otra = Array.prototype.find.call(
            cont.querySelectorAll('[data-nueva-opcion]'),
            (x) => x.dataset.nuevaOpcion === catId
          );
          if (otra) otra.querySelector('input').focus();
        }
      }
    });
  }

  function copiarDia(origen, destino, sucursalId, sentido) {
    if (!A.exigir('menu')) return;
    let r;
    try {
      r = S.copiarMenuDia(origen, destino, sucursalId);
    } catch (err) {
      return U.toast(err.message, 'error');
    }
    if (r.copiadas) {
      U.toast(sentido === 'ayer' ? 'Se copió el menú de ayer.' : 'Menú copiado a mañana.');
    } else if (r.omitidas.length) {
      U.toast(
        (sentido === 'ayer' ? 'Esta fecha' : 'Mañana') + ' ya tiene menú en ' + r.omitidas.join(', ') +
          '. Copiar nunca reemplaza un menú.',
        'info'
      );
    } else {
      U.toast(sentido === 'ayer' ? 'Ayer no había menú para copiar.' : 'No hay menú en esta fecha para copiar.', 'info');
    }
    pintarDiaAdmin(true);
  }

  function clicDia(e) {
    const b = e.target.closest('button[data-md]');
    if (!b) return;

    const k = claveDia();
    const accion = b.dataset.md;
    const catId = b.dataset.cat;
    const opId = b.dataset.op;
    const platoId = b.dataset.plato;

    const menu = S.getMenuDia(k.fecha, k.sucursalId);
    const cat = menu && catId ? menu.armado.categorias.find((c) => c.id === catId) : null;
    const op = cat && opId ? cat.opciones.find((o) => o.id === opId) : null;
    const plato = platoId ? S.getPlatosChef(k.fecha, k.sucursalId).find((p) => p.id === platoId) : null;

    switch (accion) {
      case 'tipo':
        return cambiarTipoDia(k, b.dataset.tipo);

      case 'texto-quitar':
        return U.confirmar(
          '¿Quitar el texto propio de esta fecha? Volverá a mostrarse el de la unidad.',
          () =>
            accionDia(
              () => S.guardarTextoMenuDia(k.fecha, k.sucursalId, { titulo: '', mensaje: '' }, 'fecha'),
              'Esta fecha vuelve a usar el texto de la unidad.'
            ),
          'Sí, quitar'
        );

      // ---- categorías ----
      case 'nueva-cat':
        return editarCategoriaDia(k, null);
      case 'cat-editar':
        return cat && editarCategoriaDia(k, cat);
      case 'cat-subir':
      case 'cat-bajar':
        return accionDia(() => S.moverCategoriaArmado(k.fecha, k.sucursalId, catId, accion === 'cat-subir' ? -1 : 1));
      case 'cat-activa':
        if (!cat) return;
        return accionDia(
          () => S.guardarCategoriaArmado(k.fecha, k.sucursalId, { id: catId, activa: !cat.activa }),
          cat.activa ? 'Categoría desactivada: el cliente ya no la ve.' : 'Categoría activada.'
        );
      case 'cat-borrar':
        if (!cat) return;
        return U.confirmar(
          '¿Eliminar la categoría "' + cat.nombre + '"' +
            (cat.opciones.length ? ' y sus ' + cat.opciones.length + ' opciones' : '') +
            '? Si sólo quieres ocultarla, usa «Desactivar».',
          () => accionDia(() => S.borrarCategoriaArmado(k.fecha, k.sucursalId, catId), 'Categoría eliminada.'),
          'Sí, eliminar'
        );

      // ---- opciones ----
      case 'op-editar':
        return op && editarOpcionDia(k, cat, op);
      case 'op-subir':
      case 'op-bajar':
        return accionDia(() =>
          S.moverOpcionArmado(k.fecha, k.sucursalId, catId, opId, accion === 'op-subir' ? -1 : 1)
        );
      case 'op-activa':
        if (!op) return;
        return accionDia(
          () => S.guardarOpcionArmado(k.fecha, k.sucursalId, catId, { id: opId, activa: !op.activa }),
          op.activa ? '"' + op.nombre + '" desactivada.' : '"' + op.nombre + '" activada.'
        );
      case 'op-borrar':
        if (!op) return;
        return U.confirmar(
          '¿Eliminar "' + op.nombre + '" de ' + cat.nombre + '? Si sólo quieres ocultarla hoy, usa «Desactivar».',
          () => accionDia(() => S.borrarOpcionArmado(k.fecha, k.sucursalId, catId, opId), 'Opción eliminada.'),
          'Sí, eliminar'
        );

      // ---- platos del chef ----
      case 'nuevo-plato':
        return editarPlatoDia(k, null);
      case 'plato-editar':
        return plato && editarPlatoDia(k, plato);
      case 'plato-subir':
      case 'plato-bajar':
        return accionDia(() => S.moverPlatoDia(platoId, accion === 'plato-subir' ? -1 : 1));
      case 'plato-activo':
        if (!plato) return;
        return accionDia(
          () => S.guardarPlatoDia({ id: plato.id, disponible: plato.disponible === false }),
          plato.disponible === false ? 'El plato vuelve a estar disponible.' : 'Plato desactivado: el cliente ya no lo ve.'
        );
      case 'plato-borrar':
        if (!plato) return;
        return U.confirmar(
          '¿Eliminar "' + plato.nombre + '" del menú del chef?' +
            (plato.vendidos
              ? ' Ya lleva ' + plato.vendidos + ' vendidos: esos pedidos no cambian.'
              : '') +
            ' Si sólo quieres ocultarlo, usa «Desactivar».',
          () => accionDia(() => S.borrarPlatoDia(plato.id), 'Plato eliminado.'),
          'Sí, eliminar'
        );
    }
  }

  function cambiarTipoDia(k, tipo) {
    if (!A.exigir('menu')) return;
    if (S.tipoMenuDia(k.fecha, k.sucursalId) === tipo) return;

    const info = infoTipoDia(tipo);
    const hacer = () => accionDia(() => S.setTipoMenuDia(k.fecha, k.sucursalId, tipo), 'Ahora se publica el ' + info.nombre.toLowerCase() + '.');

    // Si todavía no hay nada configurado, no hay nada que avisar
    const hayAlgo = S.getMenuDia(k.fecha, k.sucursalId) || S.getPlatosChef(k.fecha, k.sucursalId).length;
    if (!hayAlgo) return hacer();

    U.confirmar(
      '¿Publicar el ' + info.nombre.toLowerCase() + ' en ' + U.sucursal(k.sucursalId).nombre +
        ' el ' + fechaLargaDia(k.fecha) + '? Lo que tengas en la otra modalidad no se borra: sólo deja de mostrarse.',
      hacer,
      'Sí, cambiar'
    );
  }

  /* Pinta la pestaña. Sin `forzar` no se repinta mientras se escribe en
     uno de sus campos: el panel se refresca con cada cambio guardado (un
     pedido nuevo, otra pestaña…) y no debe borrar lo que se está tecleando. */
  function pintarDiaAdmin(forzar) {
    const cont = $('#listaDiaAdmin');
    if (!cont) return;
    const foco = document.activeElement;
    if (forzar !== true && foco && cont.contains(foco) && /^(INPUT|TEXTAREA|SELECT)$/.test(foco.tagName)) return;

    const k = claveDia();
    pintarSelectorSucDia(k.sucursalId);

    if (!k.sucursalId) {
      cont.innerHTML = '<div class="vacio" style="padding:30px">Esta empresa todavía no tiene unidades activas.</div>';
      return;
    }

    const tipo = S.tipoMenuDia(k.fecha, k.sucursalId);
    const pub = S.getMenuPublico(k.fecha, k.sucursalId);

    cont.innerHTML =
      htmlEstadoDia(pub, k) +
      htmlTextoDia(k) +
      htmlTiposDia(tipo) +
      (tipo === 'armado' ? htmlArmadoDia(S.getMenuDia(k.fecha, k.sucursalId)) : htmlChefDia(k));
  }

  function pintarSelectorSucDia(actual) {
    const sel = $('#fSucDia');
    if (!sel) return;
    const lista = NASCAR.SUCURSALES || [];
    sel.innerHTML = lista
      .map(
        (s) =>
          '<option value="' + s.id + '"' + (Number(s.id) === Number(actual) ? ' selected' : '') + '>' +
          U.esc(s.nombre) + '</option>'
      )
      .join('');
    // Quien está atado a una sucursal no elige otra
    sel.disabled = true; // la unidad se cambia en la cabecera del panel
  }

  /* ---- ¿Se ve en el portal? ---- */
  function htmlEstadoDia(pub, k) {
    const info = infoTipoDia(pub.tipo);
    let resumen = pub.motivo;
    if (pub.publicado && pub.tipo === 'armado') {
      const opciones = pub.armado.categorias.reduce((n, c) => n + c.opciones.length, 0);
      resumen =
        pub.armado.categorias.length + ' categorías · ' + opciones + ' opciones · ' + U.money(pub.armado.precio);
    } else if (pub.publicado) {
      resumen = pub.platos.length + (pub.platos.length === 1 ? ' plato disponible' : ' platos disponibles');
    }

    return (
      '<div class="md-estado ' + (pub.publicado ? 'md-estado--ok' : 'md-estado--no') + '" role="status">' +
      '<span class="md-estado__punto" aria-hidden="true"></span>' +
      '<div>' +
      '<b>' + (pub.publicado ? 'Se ve en el portal' : 'Todavía no se ve en el portal') + '</b>' +
      '<span>' + U.esc(U.sucursal(k.sucursalId).nombre) + ' · ' + U.esc(fechaLargaDia(k.fecha)) + ' · ' +
      info.icono + ' ' + U.esc(info.nombre) + '</span>' +
      '<span class="mini">' + U.esc(resumen) + '</span>' +
      '</div></div>'
    );
  }

  /* ---- Lo que ve el cliente (título y mensaje del portal) ----

     Se guarda para la UNIDAD —todos los días— o sólo para ESTA FECHA. Sin
     nada escrito se usa el texto de fábrica (NASCAR.TEXTO_MENU_DIA). Así
     el administrador lo escribe una vez y sólo lo cambia el día que quiera
     decir otra cosa. */
  const FUENTE_TEXTO = {
    fecha: 'Texto propio de esta fecha',
    unidad: 'Texto de esta unidad',
    defecto: 'Texto por defecto',
  };

  function htmlTextoDia(k) {
    const t = S.getTextoMenuDia(k.fecha, k.sucursalId);
    return (
      '<form class="caja mb-24" data-form-texto>' +
      '<div class="md-cabecera">' +
      '<div><h3 class="md-sub" style="margin:0">Lo que ve el cliente</h3>' +
      '<p class="mini tenue">Encabezado del menú del día en la página pública y en las pantallas de mesa de esta unidad.</p></div>' +
      '<span class="badge badge--linea">' + FUENTE_TEXTO[t.origenMensaje] + '</span>' +
      '</div>' +

      '<div class="md-datos__rejilla">' +
      '<label class="campo"><span>Título</span>' +
      '<input class="input" name="titulo" maxlength="60" placeholder="Menú del día" value="' + U.esc(t.titulo) + '"></label>' +
      '<label class="campo"><span>Guardar para</span>' +
      '<select class="select" name="alcance">' +
      '<option value="unidad">Todos los días de esta unidad</option>' +
      '<option value="fecha"' + (t.propioDeLaFecha ? ' selected' : '') + '>Sólo esta fecha</option>' +
      '</select></label>' +
      '</div>' +

      '<label class="campo"><span>Mensaje</span>' +
      '<textarea class="textarea" name="mensaje" rows="2" maxlength="400" ' +
      'placeholder="Ej. El almuerzo se sirve de 12:00 m. a 3:00 p.m. o hasta agotar existencias.">' +
      U.esc(t.mensaje) + '</textarea></label>' +

      '<div class="md-datos__pie">' +
      (t.propioDeLaFecha
        ? '<button type="button" class="btn btn--fantasma btn--sm" data-md="texto-quitar">Usar el texto de la unidad</button>'
        : '<span class="mini tenue">El horario y los avisos van dentro del mensaje: no hay texto fijo en el código.</span>') +
      '<button class="btn btn--rojo btn--sm" type="submit">Guardar texto</button>' +
      '</div></form>'
    );
  }

  /* ---- Tipo de menú ---- */
  function htmlTiposDia(tipo) {
    return (
      '<div class="md-tipos" role="radiogroup" aria-label="Tipo de menú">' +
      (NASCAR.TIPOS_MENU_DIA || [])
        .map(function (t) {
          const activo = t.id === tipo;
          return (
            '<button type="button" class="md-tipo' + (activo ? ' is-activo' : '') + '" role="radio" aria-checked="' +
            activo + '" data-md="tipo" data-tipo="' + t.id + '">' +
            '<i aria-hidden="true">' + t.icono + '</i>' +
            '<span class="md-tipo__txt"><b>' + U.esc(t.nombre) + '</b><span>' + U.esc(t.desc) + '</span></span>' +
            '<span class="md-tipo__marca">' + (activo ? '✓ En uso' : 'Usar este') + '</span>' +
            '</button>'
          );
        })
        .join('') +
      '</div>'
    );
  }

  function botonDia(accion, texto, extra, opciones) {
    const o = opciones || {};
    return (
      '<button type="button" class="btn btn--fantasma btn--xs' + (o.clase ? ' ' + o.clase : '') + '" data-md="' +
      accion + '" ' + extra +
      (o.etiqueta ? ' aria-label="' + o.etiqueta + '" title="' + o.etiqueta + '"' : '') +
      (o.deshabilitado ? ' disabled' : '') + '>' + texto + '</button>'
    );
  }

  /* ---- Menú armado ---- */
  function htmlArmadoDia(menu) {
    const a = menu.armado;
    return (
      '<form class="caja mb-24" data-form-armado>' +
      '<h3 class="md-sub">1 · Datos del menú</h3>' +
      '<div class="md-datos__rejilla">' +
      '<label class="campo"><span>Nombre que ve el cliente <i class="req">*</i></span>' +
      '<input class="input" name="nombre" maxlength="60" value="' + U.esc(a.nombre) + '"></label>' +
      '<label class="campo"><span>Precio del menú (COP) <i class="req">*</i></span>' +
      '<input class="input" name="precio" type="number" min="0" step="500" placeholder="Ej. 18000" value="' +
      (a.precio || '') + '"></label>' +
      '</div>' +
      '<label class="campo"><span>Descripción corta</span>' +
      '<input class="input" name="descripcion" maxlength="240" placeholder="Ej. Incluye sopa, seco y jugo. De 12 a 3 p.m." value="' +
      U.esc(a.descripcion) + '"></label>' +
      '<div class="md-datos__pie">' +
      '<label class="fila mini" style="gap:8px"><input type="checkbox" name="disponible"' +
      (a.disponible ? ' checked' : '') + ' style="accent-color:var(--verde);width:18px;height:18px"> Disponible para pedir</label>' +
      (a.vendidos ? '<span class="mini tenue">Vendidos: ' + a.vendidos + '</span>' : '') +
      '<button class="btn btn--rojo btn--sm" type="submit">Guardar datos</button>' +
      '</div>' +
      '</form>' +

      '<div class="md-cabecera">' +
      '<div><h3 class="md-sub" style="margin:0">2 · Categorías y opciones</h3>' +
      '<p class="mini tenue">El cliente elige las opciones de cada categoría: una, o hasta el máximo que definas (el principio suele admitir dos). Con ↑ ↓ cambias el orden en que las ve.</p></div>' +
      '<button type="button" class="btn btn--fantasma btn--sm" data-md="nueva-cat">+ Nueva categoría</button>' +
      '</div>' +

      (a.categorias.length
        ? '<div class="md-cats">' +
          a.categorias.map((c, i) => htmlCategoriaDia(c, i, a.categorias.length)).join('') +
          '</div>'
        : '<div class="vacio" style="padding:30px">No hay categorías. Crea la primera con «+ Nueva categoría».</div>')
    );
  }

  function htmlCategoriaDia(c, i, total) {
    const extra = 'data-cat="' + c.id + '"';
    const activas = c.opciones.filter((o) => o.activa).length;
    return (
      '<section class="caja md-cat' + (c.activa ? '' : ' is-inactiva') + '">' +
      '<header class="md-cat__cab">' +
      '<div class="md-cat__titulo">' +
      '<span class="md-cat__ico" aria-hidden="true">' + (U.esc(c.icono) || '🍽️') + '</span>' +
      '<div><h4>' + U.esc(c.nombre) + '</h4>' +
      '<span class="mini tenue">' + activas + ' de ' + c.opciones.length + ' opciones activas</span></div>' +
      '<span class="badge ' + (c.obligatoria ? 'badge--rojo' : 'badge--gris') + '">' +
      (c.obligatoria ? 'Obligatoria' : 'Opcional') + '</span>' +
      (c.maxSeleccion > 1
        ? '<span class="badge badge--azul">Elige hasta ' + c.maxSeleccion + '</span>'
        : '') +
      (c.activa ? '' : '<span class="badge badge--gris">Oculta</span>') +
      '</div>' +
      '<div class="md-acciones">' +
      botonDia('cat-subir', '↑', extra, { clase: 'md-orden', etiqueta: 'Subir ' + U.esc(c.nombre), deshabilitado: i === 0 }) +
      botonDia('cat-bajar', '↓', extra, { clase: 'md-orden', etiqueta: 'Bajar ' + U.esc(c.nombre), deshabilitado: i === total - 1 }) +
      botonDia('cat-editar', 'Editar', extra) +
      botonDia('cat-activa', c.activa ? 'Desactivar' : 'Activar', extra) +
      botonDia('cat-borrar', '✕', extra, { clase: 'md-borrar', etiqueta: 'Eliminar ' + U.esc(c.nombre) }) +
      '</div>' +
      '</header>' +

      (c.opciones.length
        ? '<ul class="md-ops">' + c.opciones.map((o, j) => htmlOpcionDia(c, o, j, c.opciones.length)).join('') + '</ul>'
        : '<p class="mini tenue md-ops__vacio">Todavía no hay opciones. Escribe la primera aquí abajo.</p>') +

      '<form class="md-nueva" data-nueva-opcion="' + c.id + '">' +
      '<input class="input" maxlength="60" placeholder="Nueva opción de ' + U.esc(c.nombre) + '…" aria-label="Nueva opción de ' +
      U.esc(c.nombre) + '">' +
      '<button class="btn btn--rojo btn--sm" type="submit">+ Agregar</button>' +
      '</form>' +
      '</section>'
    );
  }

  function htmlOpcionDia(c, o, j, total) {
    const extra = 'data-cat="' + c.id + '" data-op="' + o.id + '"';
    return (
      '<li class="md-op' + (o.activa ? '' : ' is-inactiva') + '">' +
      '<span class="md-op__nombre">' + U.esc(o.nombre) + '</span>' +
      '<span class="badge ' + (o.activa ? 'badge--verde' : 'badge--gris') + '">' + (o.activa ? 'Activa' : 'Inactiva') + '</span>' +
      '<span class="md-acciones">' +
      botonDia('op-subir', '↑', extra, { clase: 'md-orden', etiqueta: 'Subir ' + U.esc(o.nombre), deshabilitado: j === 0 }) +
      botonDia('op-bajar', '↓', extra, { clase: 'md-orden', etiqueta: 'Bajar ' + U.esc(o.nombre), deshabilitado: j === total - 1 }) +
      botonDia('op-editar', 'Editar', extra) +
      botonDia('op-activa', o.activa ? 'Desactivar' : 'Activar', extra) +
      botonDia('op-borrar', '✕', extra, { clase: 'md-borrar', etiqueta: 'Eliminar ' + U.esc(o.nombre) }) +
      '</span>' +
      '</li>'
    );
  }

  function editarCategoriaDia(k, c) {
    if (!A.exigir('menu')) return;
    const m = U.modal({
      titulo: c ? 'Editar categoría' : 'Nueva categoría',
      ancho: 460,
      contenido:
        '<label class="campo"><span>Nombre <i class="req">*</i></span>' +
        '<input class="input" id="mcNombre" maxlength="40" placeholder="Ej. Postre" value="' + U.esc(c ? c.nombre : '') + '"></label>' +
        '<div class="rejilla-2">' +
        '<label class="campo"><span>Icono (opcional)</span>' +
        '<input class="input" id="mcIcono" maxlength="8" placeholder="Ej. 🍮" value="' + U.esc(c ? c.icono : '') + '"></label>' +
        '<label class="campo"><span>Máximo de opciones que puede elegir</span>' +
        '<input class="input" type="number" id="mcMax" min="1" max="10" value="' + (c ? c.maxSeleccion || 1 : 1) + '">' +
        '<span class="mini tenue">1 = una sola opción. El principio suele ser 2.</span></label>' +
        '</div>' +
        '<label class="fila mini" style="gap:8px;margin:6px 0 8px"><input type="checkbox" id="mcObl"' +
        (!c || c.obligatoria ? ' checked' : '') +
        ' style="accent-color:var(--rojo);width:18px;height:18px"> Obligatoria: el cliente tiene que elegir una opción</label>' +
        '<label class="fila mini" style="gap:8px;margin:0 0 16px"><input type="checkbox" id="mcAct"' +
        (!c || c.activa ? ' checked' : '') +
        ' style="accent-color:var(--verde);width:18px;height:18px"> Visible para el cliente</label>' +
        '<div class="fila fila--fin"><button class="btn btn--fantasma" id="mcNo">Cancelar</button>' +
        '<button class="btn btn--rojo" id="mcSi">Guardar</button></div>',
    });

    U.$('#mcNombre', m.raiz).focus();
    U.$('#mcNo', m.raiz).onclick = m.cerrar;
    U.$('#mcSi', m.raiz).onclick = function () {
      const ok = accionDia(
        () =>
          S.guardarCategoriaArmado(k.fecha, k.sucursalId, {
            id: c ? c.id : undefined,
            nombre: U.$('#mcNombre', m.raiz).value,
            icono: U.$('#mcIcono', m.raiz).value,
            obligatoria: U.$('#mcObl', m.raiz).checked,
            maxSeleccion: U.$('#mcMax', m.raiz).value,
            activa: U.$('#mcAct', m.raiz).checked,
          }),
        c ? 'Categoría actualizada.' : 'Categoría creada.'
      );
      if (ok) m.cerrar();
    };
    enterGuarda(m.raiz, '#mcSi');
  }

  function editarOpcionDia(k, c, o) {
    if (!A.exigir('menu')) return;
    const m = U.modal({
      titulo: 'Editar opción de ' + c.nombre,
      ancho: 440,
      contenido:
        '<label class="campo"><span>Nombre <i class="req">*</i></span>' +
        '<input class="input" id="moNombre" maxlength="60" value="' + U.esc(o.nombre) + '"></label>' +
        '<label class="fila mini" style="gap:8px;margin:6px 0 16px"><input type="checkbox" id="moAct"' +
        (o.activa ? ' checked' : '') + ' style="accent-color:var(--verde);width:18px;height:18px"> Activa (el cliente la ve)</label>' +
        '<div class="fila fila--fin"><button class="btn btn--fantasma" id="moNo">Cancelar</button>' +
        '<button class="btn btn--rojo" id="moSi">Guardar</button></div>',
    });

    U.$('#moNombre', m.raiz).focus();
    U.$('#moNo', m.raiz).onclick = m.cerrar;
    U.$('#moSi', m.raiz).onclick = function () {
      const ok = accionDia(
        () =>
          S.guardarOpcionArmado(k.fecha, k.sucursalId, c.id, {
            id: o.id,
            nombre: U.$('#moNombre', m.raiz).value,
            activa: U.$('#moAct', m.raiz).checked,
          }),
        'Opción actualizada.'
      );
      if (ok) m.cerrar();
    };
    enterGuarda(m.raiz, '#moSi');
  }

  function enterGuarda(raiz, boton) {
    raiz.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' && e.target.tagName === 'INPUT') {
        e.preventDefault();
        U.$(boton, raiz).click();
      }
    });
  }

  /* ---- Menú del chef ---- */
  function htmlChefDia(k) {
    const platos = S.getPlatosChef(k.fecha, k.sucursalId);
    return (
      '<div class="md-cabecera">' +
      '<div><h3 class="md-sub" style="margin:0">Platos del chef</h3>' +
      '<p class="mini tenue">Cada plato se edita por separado. Con ↑ ↓ cambias el orden en que los ve el cliente.</p></div>' +
      '<button type="button" class="btn btn--rojo btn--sm" data-md="nuevo-plato">+ Nuevo plato</button>' +
      '</div>' +
      (platos.length
        ? '<div class="md-platos">' + platos.map((p, i) => htmlPlatoDia(p, i, platos.length)).join('') + '</div>'
        : '<div class="vacio" style="padding:30px">Todavía no hay platos del chef para esta fecha. ' +
          'Crea el primero con «+ Nuevo plato» o usa «Copiar el de ayer».</div>')
    );
  }

  function htmlPlatoDia(p, i, total) {
    const extra = 'data-plato="' + p.id + '"';
    const disponible = p.disponible !== false;
    const cupos = typeof p.cupos === 'number' && p.cupos > 0;
    const combo = [p.sopa, p.principio, p.proteina, p.bebida].filter(Boolean).join(' · ');

    return (
      '<article class="caja md-plato' + (disponible ? '' : ' is-inactiva') + '">' +
      '<div class="md-plato__orden">' +
      botonDia('plato-subir', '↑', extra, { clase: 'md-orden', etiqueta: 'Subir ' + U.esc(p.nombre), deshabilitado: i === 0 }) +
      botonDia('plato-bajar', '↓', extra, { clase: 'md-orden', etiqueta: 'Bajar ' + U.esc(p.nombre), deshabilitado: i === total - 1 }) +
      '</div>' +
      '<div class="md-plato__emoji" aria-hidden="true">' + (U.esc(p.emoji || '') || '🍽️') + '</div>' +
      '<div class="md-plato__info">' +
      '<h4>' + U.esc(p.nombre) + '</h4>' +
      (p.desc ? '<p>' + U.esc(p.desc) + '</p>' : '<p class="tenue">Sin descripción</p>') +
      (combo ? '<p class="mini tenue">Incluye: ' + U.esc(combo) + '</p>' : '') +
      '</div>' +
      '<div class="md-plato__precio"><b>' + U.money(p.precio) + '</b>' +
      '<span class="mini tenue">Vendidos ' + (p.vendidos || 0) +
      (cupos ? ' · quedan ' + Math.max(0, p.cupos - (p.vendidos || 0)) : '') + '</span></div>' +
      '<span class="badge ' + (disponible ? 'badge--verde' : 'badge--gris') + '">' +
      (disponible ? 'Disponible' : 'No disponible') + '</span>' +
      '<div class="md-acciones">' +
      botonDia('plato-activo', disponible ? 'Desactivar' : 'Activar', extra) +
      botonDia('plato-editar', 'Editar', extra) +
      botonDia('plato-borrar', '✕', extra, { clase: 'md-borrar', etiqueta: 'Eliminar ' + U.esc(p.nombre) }) +
      '</div>' +
      '</article>'
    );
  }

  function editarPlatoDia(k, existente) {
    if (!A.exigir('menu')) return;
    const p = existente || Object.assign({}, NASCAR.PLANTILLA_DIA, { emoji: '' });
    const conComposicion = [p.sopa, p.principio, p.proteina, p.bebida].some(Boolean);

    const m = U.modal({
      titulo: existente ? 'Editar plato del chef' : 'Nuevo plato del chef',
      ancho: 580,
      contenido:
        '<p class="mini tenue" style="margin-top:0">📍 ' + U.esc(U.sucursal(k.sucursalId).nombre) + ' · ' +
        U.esc(fechaLargaDia(existente ? existente.fecha : k.fecha)) + '</p>' +

        '<div class="md-form-plato">' +
        '<label class="campo"><span>Emoji</span>' +
        '<input class="input md-emoji-input" id="dEmoji" maxlength="8" placeholder="🍽️" value="' + U.esc(p.emoji || '') + '"></label>' +
        '<label class="campo"><span>Nombre del plato <i class="req">*</i></span>' +
        '<input class="input" id="dNombre" maxlength="60" placeholder="Ej. Bisteck a caballo" value="' + U.esc(p.nombre || '') + '"></label>' +
        '</div>' +
        '<div class="md-emojis" role="group" aria-label="Emojis sugeridos">' +
        (NASCAR.EMOJIS_PLATO || [])
          .map((x) => '<button type="button" class="chip" data-emoji="' + x + '" aria-label="Usar ' + x + '">' + x + '</button>')
          .join('') +
        '<button type="button" class="chip" data-emoji="">Sin emoji</button>' +
        '</div>' +

        '<label class="campo"><span>Descripción</span>' +
        '<textarea class="textarea" id="dDesc" rows="3" maxlength="400" placeholder="Ej. Corte de res en salsa criolla con 2 huevos fritos, arroz, papa francesa y ensalada. Incluye entrada y bebida.">' +
        U.esc(p.desc || '') + '</textarea></label>' +

        '<div class="rejilla-2">' +
        '<label class="campo"><span>Precio (COP) <i class="req">*</i></span>' +
        '<input class="input" type="number" id="dPrecio" min="0" step="500" value="' + (Number(p.precio) || '') + '"></label>' +
        '<label class="campo"><span>Cupos del día</span>' +
        '<input class="input" type="number" id="dCupos" min="0" placeholder="Sin límite" value="' +
        (typeof p.cupos === 'number' && p.cupos > 0 ? p.cupos : '') + '"></label>' +
        '</div>' +

        '<details class="md-incluye"' + (conComposicion ? ' open' : '') + '>' +
        '<summary>Qué incluye (opcional)</summary>' +
        '<div class="rejilla-2">' +
        '<label class="campo"><span>Sopa</span><input class="input" id="dSopa" value="' + U.esc(p.sopa || '') + '"></label>' +
        '<label class="campo"><span>Principio</span><input class="input" id="dPrin" value="' + U.esc(p.principio || '') + '"></label>' +
        '<label class="campo"><span>Proteína</span><input class="input" id="dProt" value="' + U.esc(p.proteina || '') + '"></label>' +
        '<label class="campo"><span>Bebida</span><input class="input" id="dBeb" value="' + U.esc(p.bebida || '') + '"></label>' +
        '</div></details>' +

        '<label class="fila mini" style="gap:8px;margin:6px 0 16px">' +
        '<input type="checkbox" id="dDisp"' + (p.disponible !== false ? ' checked' : '') +
        ' style="accent-color:var(--verde);width:18px;height:18px"> Disponible (el cliente lo ve)</label>' +

        '<div class="fila fila--fin">' +
        '<button class="btn btn--fantasma" id="dNo">Cancelar</button>' +
        '<button class="btn btn--rojo" id="dSi">Guardar</button></div>',
    });

    U.$('#dNombre', m.raiz).focus();
    m.raiz.addEventListener('click', function (e) {
      const b = e.target.closest('[data-emoji]');
      if (b) U.$('#dEmoji', m.raiz).value = b.dataset.emoji;
    });

    U.$('#dNo', m.raiz).onclick = m.cerrar;
    U.$('#dSi', m.raiz).onclick = function () {
      const nombre = U.$('#dNombre', m.raiz).value.trim();
      const precio = Number(U.$('#dPrecio', m.raiz).value);
      const cupos = Number(U.$('#dCupos', m.raiz).value);

      if (nombre.length < 3) return U.toast('Escribe el nombre del plato (mínimo 3 letras).', 'error');
      if (!(precio > 0)) return U.toast('El precio debe ser mayor a cero.', 'error');

      const datos = {
        nombre: nombre,
        emoji: U.$('#dEmoji', m.raiz).value,
        desc: U.$('#dDesc', m.raiz).value.trim(),
        sopa: U.$('#dSopa', m.raiz).value.trim(),
        principio: U.$('#dPrin', m.raiz).value.trim(),
        proteina: U.$('#dProt', m.raiz).value.trim(),
        bebida: U.$('#dBeb', m.raiz).value.trim(),
        precio: Math.round(precio),
        cupos: cupos > 0 ? Math.round(cupos) : null, // vacío = sin límite
        disponible: U.$('#dDisp', m.raiz).checked,
      };
      if (existente) datos.id = existente.id;
      else Object.assign(datos, { sucursalId: k.sucursalId, fecha: k.fecha, vendidos: 0 });

      if (accionDia(() => S.guardarPlatoDia(datos), existente ? 'Plato actualizado.' : 'Plato creado.')) m.cerrar();
    };
  }

  /* La carta ahora se administra en js/gestion.js (pestaña 🍽 Carta),
     con productos y categorías completos. Aquí ya no queda lógica de
     carta para no tener dos implementaciones de lo mismo. */

  /* =================================================================
     TAB · VENTAS
     ================================================================= */
  function conectarVentas() {
    $('#btnVerVentas').addEventListener('click', pintarVentas);
    ['#vDesde', '#vHasta'].forEach((s) => $(s).addEventListener('change', pintarVentas));

    $$('[data-rango]').forEach((b) =>
      b.addEventListener('click', function () {
        const r = this.dataset.rango;
        const hoy = S.hoy();
        if (r === 'hoy') {
          $('#vDesde').value = hoy;
          $('#vHasta').value = hoy;
        } else if (r === 'ayer') {
          $('#vDesde').value = restarDias(hoy, 1);
          $('#vHasta').value = restarDias(hoy, 1);
        } else {
          $('#vDesde').value = restarDias(hoy, Number(r) - 1);
          $('#vHasta').value = hoy;
        }
        pintarVentas();
      })
    );

    $('#btnCSV').addEventListener('click', descargarCSV);

    $('#tablaVentas').addEventListener('click', function (e) {
      const v = e.target.closest('[data-ver]');
      if (v) verDetallePedido(v.dataset.ver);
    });
  }

  function pintarVentas() {
    const desde = $('#vDesde').value || S.hoy();
    const hasta = $('#vHasta').value || desde;
    const v = S.ventas(desde, hasta, sucursalGlobal || null);

    $('#kpisVentas').innerHTML =
      kpi('Venta total', U.money(v.total), v.pedidos + ' pedidos', 'verde') +
      kpi('Ticket promedio', U.money(v.ticketPromedio), 'Por pedido') +
      kpi('Domicilios cobrados', U.money(v.domicilios), v.porTipo.domicilio.n + ' entregas', 'azul') +
      kpi('Venta en mesa', U.money(v.porTipo.mesa.total), v.porTipo.mesa.n + ' pedidos') +
      kpi('Pendiente de cobro', U.money(v.montoPendiente), v.pendientesCobro + ' sin confirmar', 'ambar');

    // Ventas por día
    const dias = Object.keys(v.porDia).sort();
    const maxDia = Math.max(1, ...dias.map((d) => v.porDia[d].total));
    $('#ventasPorDia').innerHTML = dias.length
      ? dias
          .map(
            (d) =>
              barra(
                S.desdeISO(d).toLocaleDateString('es-CO', { weekday: 'short', day: 'numeric', month: 'short' }),
                U.money(v.porDia[d].total) + ' · ' + v.porDia[d].n + ' ped.',
                (v.porDia[d].total / maxDia) * 100
              )
          )
          .join('')
      : '<p class="tenue mini">Sin ventas en el rango.</p>';

    // Top platos
    const maxPlato = Math.max(1, ...v.topPlatos.map((p) => p.cantidad));
    $('#topPlatos').innerHTML = v.topPlatos.length
      ? v.topPlatos
          .map((p) => barra(p.nombre, p.cantidad + ' und · ' + U.money(p.total), (p.cantidad / maxPlato) * 100))
          .join('')
      : '<p class="tenue mini">Sin datos.</p>';

    // Por método de pago
    const pagos = Object.keys(v.porPago);
    const maxPago = Math.max(1, ...pagos.map((k) => v.porPago[k].total));
    $('#porPago').innerHTML = pagos.length
      ? pagos
          .map((k) =>
            barra(
              { efectivo: 'Efectivo', transferencia: 'Transferencia', datafono: 'Datáfono', por_cobrar: '⏳ Por cobrar en caja' }[k] || k,
              U.money(v.porPago[k].total) + ' · ' + v.porPago[k].n + ' ped.',
              (v.porPago[k].total / maxPago) * 100
            )
          )
          .join('')
      : '<p class="tenue mini">Sin datos.</p>';

    // Por sucursal
    const sucs = Object.keys(v.porSucursal);
    const maxSuc = Math.max(1, ...sucs.map((k) => v.porSucursal[k].total));
    $('#porSucursal').innerHTML =
      (sucs.length
        ? sucs
            .map((k) =>
              barra(
                U.sucursal(k).nombre,
                U.money(v.porSucursal[k].total) + ' · ' + v.porSucursal[k].n + ' ped.',
                (v.porSucursal[k].total / maxSuc) * 100
              )
            )
            .join('')
        : '<p class="tenue mini">Sin datos.</p>') +
      '<div class="mt-16">' +
      barra('Mesa', U.money(v.porTipo.mesa.total) + ' · ' + v.porTipo.mesa.n + ' ped.',
        (v.porTipo.mesa.total / Math.max(1, v.total)) * 100) +
      barra('Domicilio', U.money(v.porTipo.domicilio.total) + ' · ' + v.porTipo.domicilio.n + ' ped.',
        (v.porTipo.domicilio.total / Math.max(1, v.total)) * 100) +
      '</div>';

    // Detalle
    const filtro = { desde: desde, hasta: hasta };
    if (sucursalGlobal) filtro.sucursalId = sucursalGlobal;
    const pedidos = S.getPedidos(filtro);

    $('#tablaVentas').innerHTML = pedidos.length
      ? pedidos
          .map(
            (p) =>
              '<tr data-ver="' + p.id + '" style="cursor:pointer">' +
              '<td><b class="mono">' + U.esc(p.codigo) + '</b></td>' +
              '<td class="mini tenue">' + p.fecha + '<br>' + U.hora(p.creado) + '</td>' +
              '<td>' + (p.tipo === 'mesa' ? 'Mesa ' + U.esc(p.mesa) : 'Domicilio') + '</td>' +
              '<td class="mini">' + U.esc(U.sucursal(p.sucursalId).corto) + '</td>' +
              '<td class="mini">' + U.esc(p.cliente.nombre || '—') + '</td>' +
              '<td>' + insigniaPago(p) + '</td>' +
              '<td class="derecha num" style="font-size:16px">' + U.money(p.total) + '</td>' +
              '<td><span class="badge ' +
              (p.estado === 'cancelado' || p.estado === 'anulado'
                ? 'badge--rojo'
                : p.estado === 'entregado'
                ? 'badge--verde'
                : 'badge--linea') +
              '">' + S.ETIQUETA_ESTADO[p.estado] + '</span></td>' +
              '</tr>'
          )
          .join('')
      : '<tr><td colspan="8"><div class="vacio" style="border:0">Sin pedidos en el rango seleccionado.</div></td></tr>';
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

  function descargarCSV() {
    const desde = $('#vDesde').value || S.hoy();
    const hasta = $('#vHasta').value || desde;
    const filtro = { desde: desde, hasta: hasta };
    if (sucursalGlobal) filtro.sucursalId = sucursalGlobal;

    const pedidos = S.getPedidos(filtro);
    if (!pedidos.length) return U.toast('No hay pedidos para exportar.', 'error');

    const cab = [
      'Codigo', 'Fecha', 'Hora', 'Tipo', 'Mesa', 'Sucursal', 'Cliente', 'Telefono',
      'Zona', 'Items', 'Subtotal', 'Domicilio', 'Total', 'MetodoPago', 'EstadoPago', 'Estado',
    ];

    const filas = pedidos.map((p) => [
      p.codigo,
      p.fecha,
      U.hora(p.creado),
      p.tipo,
      p.mesa || '',
      U.sucursal(p.sucursalId).nombre,
      p.cliente.nombre || '',
      p.cliente.telefono || '',
      p.cliente.zona || '',
      p.items.map((i) => i.cantidad + 'x ' + i.nombre).join(' | '),
      p.subtotal,
      p.domicilio,
      p.total,
      p.metodoPago,
      p.estadoPago,
      p.estado,
    ]);

    const csv =
      '﻿' + // BOM para que Excel respete los acentos
      [cab, ...filas]
        .map((f) => f.map((c) => '"' + String(c).replace(/"/g, '""') + '"').join(';'))
        .join('\r\n');

    descargar(csv, 'ventas-nascar-' + desde + '_a_' + hasta + '.csv', 'text/csv;charset=utf-8');
    U.toast('CSV descargado (' + pedidos.length + ' pedidos).');
  }

  function descargar(contenido, nombre, tipo) {
    const blob = new Blob([contenido], { type: tipo });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = nombre;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1500);
  }

  /* =================================================================
     TAB · AJUSTES
     ================================================================= */
  /* ---- Facturas de prueba ---- */
  function pintarFacturasPrueba() {
    const info = $('#facturasPruebaInfo');
    if (!info) return;
    const viejas = S.contarFacturasPrueba('anteriores').pedidos;
    const todas = S.contarFacturasPrueba('todas').pedidos;
    const conBase = !!(NASCAR.Remoto && NASCAR.Remoto.activo);
    const donde = conBase ? 'de esta empresa en la base de datos' : 'en este navegador';
    info.textContent =
      todas === 0
        ? 'No hay facturas guardadas ' + donde + '.'
        : todas + (todas === 1 ? ' factura ' : ' facturas ') + donde +
          (conBase ? '.' : ' · ' + viejas + ' con el formato anterior.');
  }

  function confirmarBorrarFacturas(alcance) {
    const n = S.contarFacturasPrueba(alcance);
    if (!n.pedidos) return U.toast('No hay facturas para borrar.', 'info');

    const m = U.modal({
      titulo: 'Borrar facturas de prueba',
      ancho: 460,
      contenido:
        '<p>Se van a borrar <b>' + n.pedidos + (n.pedidos === 1 ? ' factura' : ' facturas') + '</b>' +
        (alcance === 'todas' ? ' (todas) y la numeración vuelve a <b>00001</b>' : ' con el formato anterior') +
        (n.entradas ? ', y ' + n.entradas + ' entradas de retorno por anulación' : '') + '.</p>' +
        '<p class="mini tenue">No se puede deshacer. Los cierres, gastos, stock y menús no se tocan.</p>' +
        '<label class="campo"><span>Escribe BORRAR para confirmar</span>' +
        '<input class="input" id="bfConfirma" autocomplete="off" style="text-transform:uppercase"></label>' +
        '<button class="btn btn--rojo btn--bloque" id="bfOk" disabled>Borrar facturas</button>',
    });
    const input = U.$('#bfConfirma', m.raiz);
    const ok = U.$('#bfOk', m.raiz);
    input.addEventListener('input', () => (ok.disabled = input.value.trim().toUpperCase() !== 'BORRAR'));
    ok.addEventListener('click', function () {
      try {
        const r = S.borrarFacturasPrueba(alcance, input.value);
        m.cerrar();
        U.toast(r.pedidos + (r.pedidos === 1 ? ' factura borrada.' : ' facturas borradas.'));
        refrescarTodo();
        pintarFacturasPrueba();
      } catch (e) {
        U.toast(e.message, 'error');
      }
    });
    input.focus();
  }

  /* La pinta la sección de Ajustes; irATab la vuelve a llamar al entrar. */
  let pintarAvisos = null;

  function conectarAjustes() {
    $('#qrSucursal').addEventListener('change', pintarQR);

    /* Avisos sonoros. La preferencia es de este equipo, no del negocio:
       la tablet de cocina puede sonar y el computador de la oficina no. */
    const av = NASCAR.Avisos;
    if (av && $('#avSonido')) {
      pintarAvisos = function () {
        const p = av.prefs();
        $('#avSonido').checked = !!p.sonido;
        $('#avSistema').checked = !!p.sistema;
        $('#avSistema').disabled = !p.sonido;
      };

      $('#avSonido').addEventListener('change', function () {
        av.guardarPrefs({ sonido: this.checked });
        if (this.checked) av.probar();
        pintarAvisos();
      });

      $('#avSistema').addEventListener('change', function () {
        if (!this.checked) {
          av.guardarPrefs({ sistema: false });
          return pintarAvisos();
        }
        av.pedirPermisoSistema().then(function (estado) {
          av.guardarPrefs({ sistema: estado === 'granted' });
          if (estado !== 'granted')
            U.toast('El navegador no dio permiso para avisar en segundo plano.', 'error');
          pintarAvisos();
        });
      });

      $('#btnAvisoProbar').addEventListener('click', function () {
        if (!av.prefs().sonido) return U.toast('Primero activa los avisos.', 'info');
        av.probar();
      });

      pintarAvisos();
    }

    $('#btnExportar').addEventListener('click', function () {
      descargar(S.exportar(), 'respaldo-nascar-' + S.hoy() + '.json', 'application/json');
      U.toast('Respaldo descargado.');
    });

    $('#fileImportar').addEventListener('change', function () {
      const f = this.files[0];
      if (!f) return;
      const lector = new FileReader();
      lector.onload = function () {
        U.confirmar(
          'Restaurar el respaldo reemplaza los pedidos, el menú del día y los ajustes de carta actuales.',
          function () {
            try {
              S.importar(lector.result);
              U.toast('Respaldo restaurado.');
              refrescarTodo();
            } catch (e) {
              U.toast('El archivo no es un respaldo válido.', 'error');
            }
          },
          'Sí, restaurar'
        );
      };
      lector.readAsText(f);
      this.value = '';
    });

    pintarFacturasPrueba();
    S.onChange(pintarFacturasPrueba);
    $$('[data-borrar-facturas]').forEach((b) =>
      b.addEventListener('click', () => {
        if (!NASCAR.Auth.puede('pedidos_anular')) return U.toast('Sólo el perfil Admin puede borrar facturas.', 'error');
        confirmarBorrarFacturas(b.dataset.borrarFacturas);
      })
    );

    $('#btnBorrar').addEventListener('click', function () {
      U.confirmar(
        'Se borran TODOS los pedidos, el menú del día y los ajustes. Esta acción no se puede deshacer. ' +
          'Descarga un respaldo antes si quieres conservarlos.',
        function () {
          S.borrarTodo();
          U.toast('Datos borrados.', 'info');
          setTimeout(() => location.reload(), 700);
        },
        'Sí, borrar todo'
      );
    });

    $('#listaQR').addEventListener('click', function (e) {
      const c = e.target.closest('[data-copiar]');
      if (!c) return;
      const texto = c.dataset.copiar;
      if (navigator.clipboard) {
        navigator.clipboard.writeText(texto).then(
          () => U.toast('Enlace copiado.'),
          () => U.toast('No se pudo copiar. Selecciónalo a mano.', 'error')
        );
      } else {
        U.toast('Copia el enlace manualmente: ' + texto, 'info');
      }
    });
  }

  function pintarQR() {
    const sucId = Number($('#qrSucursal').value || U.sucursalPorDefectoId());
    const suc = U.sucursal(sucId);
    // Sin el hash y, en la versión de varios archivos, sin el nombre del archivo.
    const base = location.href.replace(/[#?].*$/, '').replace(/empleados\.html$/, '');

    let html = '<div class="tabla-wrap"><table class="tabla" style="min-width:0"><tbody>';
    for (let i = 1; i <= suc.mesas; i++) {
      const url = SOLO_ARCHIVO
        ? base + '#mesa/' + sucId + '/' + i
        : location.origin +
          (NASCAR.rutaDe ? NASCAR.rutaDe('mesa') : '/mesa.html') +
          '?suc=' + sucId + '&mesa=' + i;
      html +=
        '<tr><td style="width:70px"><b>Mesa ' + i + '</b></td>' +
        '<td class="mini tenue" style="word-break:break-all">' + U.esc(url) + '</td>' +
        '<td class="nowrap">' +
        '<a class="btn btn--fantasma btn--xs" href="' + U.esc(url) + '" target="_blank" rel="noopener">Abrir</a> ' +
        '<button class="btn btn--fantasma btn--xs" data-copiar="' + U.esc(url) + '">Copiar</button>' +
        '</td></tr>';
    }
    html += '</tbody></table></div>';
    $('#listaQR').innerHTML = html;
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

  /* =================================================================
     ARRANQUE
     ================================================================= */
  document.addEventListener('DOMContentLoaded', function () {
    iniciarLogin();
    /* Se comprueba la sesión ANTES de pintar nada. Sin ella —o con una
       que no da acceso— no se llega al panel escribiendo la dirección. */
    if (S.estaAutenticado()) mostrarPanel();
    else $('#pin').focus();
  });
})();
