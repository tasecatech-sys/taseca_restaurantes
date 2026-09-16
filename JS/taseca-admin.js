/* ==========================================================================
   TASECA · taseca-admin.js
   Panel de la PLATAFORMA (nivel 1). Aquí no se atiende ningún negocio:
   se administran las empresas clientes que usan el sistema.

       TASECA (plataforma)
         ├── SuperAdmin
         └── Empresas clientes
               ├── NASCAR  → Admin, Administrador, Caja, Mesero…
               ├── Empresa 2
               └── …

   Es una página aparte a propósito, con su propia dirección, su propia
   marca y su propia hoja de estilos (css/taseca.css). El panel de
   `admin.html` es el de UNA empresa; éste está por encima de todas y no
   se llega a él pasando por ninguna.

   QUÉ NO SE MUESTRA AQUÍ: pedidos, ventas, gastos, stock ni cierres de
   ninguna empresa. Eso es operación del negocio y se ve entrando a su
   contexto. Taseca administra la plataforma, no el restaurante.

   ⚠️  MVP LOCAL. La barrera de nivel es de verdad —las funciones se
   niegan, no sólo los botones— pero los PIN siguen viajando en el
   código. Cuando exista un backend, la comprobación de scope se hará en
   el servidor y esta pantalla no cambia: ya pregunta por el nivel.
   ========================================================================== */

(function () {
  'use strict';

  const S = NASCAR.Store;
  const U = NASCAR.UI;
  const A = NASCAR.Auth;

  const $ = (sel) => document.querySelector(sel);

  let seccion = 'dashboard';
  let filtroTexto = '';
  let filtroEstado = '';
  let empresaAbierta = null; // id de la empresa cuyo detalle está desplegado

  /* =================================================================
     PUERTA

     El nivel se comprueba ANTES de dibujar el panel, no después de
     ocultar botones. Un usuario de empresa que llegue a esta dirección
     ve el aviso, y aunque forzara la pantalla no podría hacer nada:
     todas las acciones vuelven a exigir el permiso.
     ================================================================= */
  function esBienvenido() {
    /* Dos condiciones, no una: el NIVEL y el PERMISO.

       Hace falta el nivel porque el rol `admin` de una empresa lleva el
       comodín '*'; y hace falta el permiso porque '*' no alcanza a los
       permisos de plataforma (ver PERMISOS_PLATAFORMA en auth.js). */
    return A.esPlataforma() && A.puede('plataforma');
  }

  function arrancar() {
    if (S.estaAutenticado() && !esBienvenido()) return accesoDenegado();
    if (esBienvenido()) return mostrarPanel();
    mostrarLogin();
  }

  function accesoDenegado() {
    const u = A.getUsuarioActual();
    $('#pantallaPanel').classList.add('oculto');
    $('#pantallaLogin').classList.remove('oculto');
    $('#avisoAcceso').innerHTML =
      '<div class="caja mb-16" style="border-color:var(--platform-danger)">' +
      '<b>Acceso denegado.</b>' +
      '<p class="mini tenue" style="margin:6px 0 0">Estás conectado como <b>' +
      U.esc(u ? u.nombre : '—') + '</b> (' + U.esc(A.nombreRol(u && u.rol)) + '), ' +
      'un usuario de empresa. Este panel es de <b>Taseca</b>, la plataforma que está ' +
      'por encima de las empresas.</p>' +
      '<div class="fila mt-16" style="gap:8px">' +
      '<a class="btn btn--fantasma btn--sm" href="empleados.html">Ir al panel de tu empresa</a>' +
      '<button class="btn btn--fantasma btn--sm" data-salir-denegado>Salir de la sesión</button>' +
      '</div></div>';

    const b = $('[data-salir-denegado]');
    if (b)
      b.addEventListener('click', function () {
        S.logout();
        location.reload();
      });
  }

  function mostrarLogin() {
    $('#pantallaPanel').classList.add('oculto');
    $('#pantallaLogin').classList.remove('oculto');
    $('#usuarioAcceso').focus();
  }

  function iniciarLogin() {
    const entrar = function () {
      const usuario = $('#usuarioAcceso').value.trim();
      const pin = $('#pin').value;
      $('#pin').value = '';

      if (!A.entrar(usuario, pin)) {
        U.toast('Usuario o PIN incorrectos.', 'error');
        return $('#pin').focus();
      }
      if (!esBienvenido()) return accesoDenegado();
      mostrarPanel();
    };

    $('#btnEntrar').addEventListener('click', entrar);
    $('#pin').addEventListener('keydown', (e) => e.key === 'Enter' && entrar());
    $('#usuarioAcceso').addEventListener('keydown', (e) => e.key === 'Enter' && $('#pin').focus());
  }

  /* =================================================================
     PANEL
     ================================================================= */
  let listo = false;

  function mostrarPanel() {
    $('#pantallaLogin').classList.add('oculto');
    $('#pantallaPanel').classList.remove('oculto');

    /* Volver a Taseca es soltar la empresa: se deja de administrar
       ninguna. Sin esto, el panel seguiría marcando como
       "administrando" la última empresa visitada. */
    try {
      if (S.getEmpresaContexto()) S.salirDeEmpresa();
    } catch (e) {
      /* sin sesión de plataforma no hay contexto que soltar */
    }

    const u = A.getUsuarioActual();
    $('#usuarioChip').innerHTML =
      '<i>' + A.iconoRol(u.rol) + '</i><div><b>' + U.esc(u.nombre) + '</b>' +
      '<span>SuperAdmin</span></div>';

    if (!listo) {
      listo = true;
      conectar();
    }
    refrescar();
  }

  function conectar() {
    $('#btnSalir').addEventListener('click', function () {
      S.logout();
      location.reload();
    });

    /* Barra lateral: el MISMO componente del panel de empresa, con la
       piel de Taseca. Ver css/sidebar.css y js/sidebar.js. */
    const shell = $('[data-sidebar-shell]');
    NASCAR.Sidebar.iniciar({ shell: shell, clave: 'taseca' });
    NASCAR.Sidebar.prepararTooltips(shell);

    $('#tscMenu').addEventListener('click', function (e) {
      const b = e.target.closest('[data-seccion]');
      if (b) irASeccion(b.dataset.seccion);
    });

    $('#btnNuevaEmpresa').addEventListener('click', nuevaEmpresa);

    $('#fBuscarEmpresa').addEventListener('input', function () {
      filtroTexto = this.value.trim().toLowerCase();
      pintarTabla();
    });
    $('#fEstadoEmpresa').addEventListener('change', function () {
      filtroEstado = this.value;
      pintarTabla();
    });

    $('#tablaEmpresas').addEventListener('click', function (e) {
      const b = e.target.closest('[data-accion-empresa]');
      if (!b) return;
      const id = b.dataset.empresa;
      const accion = b.dataset.accionEmpresa;
      if (accion === 'editar') return editarEmpresa(id);
      if (accion === 'estado') return alternarEstado(id);
      if (accion === 'ver') return abrirDetalle(id);
      if (accion === 'entrar') return entrarAEmpresa(id);
    });

    $('#detalleEmpresa').addEventListener('change', function (e) {
      const chk = e.target.closest('[data-modulo]');
      if (chk) cambiarModulo(chk.dataset.empresa, chk.dataset.modulo, chk.checked);
    });
    $('#detalleEmpresa').addEventListener('click', function (e) {
      if (e.target.closest('[data-cerrar-detalle]')) {
        empresaAbierta = null;
        return refrescar();
      }
      const ent = e.target.closest('[data-entrar]');
      if (ent) return entrarAEmpresa(ent.dataset.entrar);
      const tem = e.target.closest('[data-tema]');
      if (tem) return editarTema(tem.dataset.tema);
      const edi = e.target.closest('[data-editar]');
      if (edi) return editarEmpresa(edi.dataset.editar);
    });

    U.iniciarComunes();
  }

  /* --- Navegación entre secciones del panel --- */
  function irASeccion(cual) {
    seccion = cual;
    NASCAR.Sidebar.marcarActivo($('[data-sidebar-shell]'), 'data-seccion', cual);
    document.querySelectorAll('[data-seccion-panel]').forEach((p) =>
      p.classList.toggle('oculto', p.dataset.seccionPanel !== cual)
    );
    window.scrollTo(0, 0);
    refrescar();
  }

  function refrescar() {
    pintarContexto();
    if (seccion === 'dashboard') pintarDashboard();
    if (seccion === 'empresas') {
      pintarTabla();
      pintarDetalle();
    }
    if (seccion === 'modulos') pintarModulos();
    if (seccion === 'config') pintarConfig();
    if (seccion === 'perfil') pintarPerfil();
  }

  /* La empresa que se está administrando. El panel sigue siendo Taseca:
     esto es sólo el contexto. */
  function pintarContexto() {
    const id = S.getEmpresaContexto();
    const nodo = $('#tscContexto');
    nodo.classList.toggle('oculto', !id);
    if (id) {
      const e = S.getEmpresa(id);
      $('#tscContextoNombre').textContent = e ? e.nombre : id;
    }
  }

  /* =================================================================
     🏠 DASHBOARD
     ================================================================= */
  function pintarDashboard() {
    const todas = S.getEmpresas({ todas: true });
    const activas = todas.filter((e) => e.activa !== false);

    /* Se cuentan sobre TODAS las empresas, no sólo las activas: para la
       plataforma, una empresa desactivada con Cierre contratado sigue
       siendo una empresa con Cierre. */
    const con = (m) => todas.filter((e) => e.modulos && e.modulos[m] !== false).length;

    $('#kpisEmpresas').innerHTML =
      kpi('Total empresas', todas.length, 'En la plataforma') +
      kpi('Activas', activas.length, 'Pueden operar', 'verde') +
      kpi('Inactivas', todas.length - activas.length, 'Con sus datos guardados', 'ambar');

    $('#kpisModulos').innerHTML = S.catalogoModulos()
      .map((m) => kpi(m.icono + ' Con ' + m.nombre, con(m.id), m.obligatorio ? 'Siempre incluido' : 'Contratado'))
      .join('');

    /* --- Actividad ---
       Sólo lo que EXISTE en los datos: la fecha de alta de cada empresa.
       No se inventan métricas de uso que el sistema no registra. */
    const conFecha = todas.filter((e) => e.creada);
    const recientes = conFecha.slice().sort((a, b) => (a.creada < b.creada ? 1 : -1)).slice(0, 5);

    $('#actividadPlataforma').innerHTML =
      '<div class="caja">' +
      '<h3>Altas recientes</h3>' +
      (recientes.length
        ? '<div class="caja-datos mt-16">' +
          recientes
            .map(
              (e) =>
                '<div class="linea"><span>' + avatar(e, 22) + ' ' + U.esc(e.nombre) + '</span>' +
                '<b class="mono">' + U.esc((e.creada || '').slice(0, 10)) + '</b></div>'
            )
            .join('') +
          '</div>'
        : '<div class="vacio">Todavía no hay empresas dadas de alta.</div>') +
      '</div>' +

      '<div class="caja">' +
      '<h3>Reparto por plan</h3>' +
      '<div class="caja-datos mt-16">' +
      S.catalogoModulos()
        .map(function (m) {
          const n = con(m.id);
          const pct = todas.length ? Math.round((n / todas.length) * 100) : 0;
          return (
            '<div class="linea"><span>' + m.icono + ' ' + U.esc(m.nombre) + '</span>' +
            '<b class="mono">' + n + ' / ' + todas.length + ' · ' + pct + '%</b></div>'
          );
        })
        .join('') +
      '</div>' +
      '<p class="mini tenue" style="margin:12px 0 0">' +
      'La plataforma no guarda métricas de uso de los negocios: aquí sólo se muestra ' +
      'lo que existe en los datos de las empresas.</p>' +
      '</div>';
  }

  /* =================================================================
     🏢 EMPRESAS
     ================================================================= */
  function empresasFiltradas() {
    return S.getEmpresas({ todas: true }).filter(function (e) {
      if (filtroEstado === 'activa' && e.activa === false) return false;
      if (filtroEstado === 'inactiva' && e.activa !== false) return false;
      if (!filtroTexto) return true;
      return (
        (e.nombre + ' ' + (e.razonSocial || '') + ' ' + (e.nit || '') + ' ' + e.id)
          .toLowerCase()
          .indexOf(filtroTexto) >= 0
      );
    });
  }

  /* Avatar con LA identidad de la empresa, no con la de Taseca: así se
     distingue de un vistazo a quién pertenece cada fila. */
  function avatar(empresa, tam) {
    const i = empresa.theme || {};
    const t = tam || 30;
    return (
      '<span class="tsc-avatar" style="width:' + t + 'px;height:' + t + 'px;' +
      'background:linear-gradient(135deg,' + U.esc(i.primary) + ',' + U.esc(i.secondary) + ');' +
      'color:#fff;font-size:' + Math.round(t * 0.4) + 'px">' + U.esc(i.iniciales) + '</span>'
    );
  }

  function pintarTabla() {
    const lista = empresasFiltradas();

    if (!lista.length) {
      $('#tablaEmpresas').innerHTML =
        '<tr><td colspan="6"><div class="vacio">Ninguna empresa coincide con el filtro.</div></td></tr>';
      return;
    }

    const actual = S.getEmpresaContexto();

    $('#tablaEmpresas').innerHTML = lista
      .map(function (e) {
        const activa = e.activa !== false;
        return (
          '<tr' + (activa ? '' : ' style="opacity:.55"') + '>' +
          '<td><div class="fila" style="gap:10px;align-items:center">' + avatar(e) +
          '<div><b>' + U.esc(e.nombre) + '</b>' +
          (e.id === actual ? ' <span class="badge badge--azul">administrando</span>' : '') +
          '<div class="mini tenue">' + U.esc(e.razonSocial || 'Sin razón social') +
          (e.nit ? ' · NIT ' + U.esc(e.nit) : '') + '</div>' +
          '<div class="mini tenue mono">' + U.esc(e.id) + '</div></div></div></td>' +
          '<td><span class="badge badge--' + (activa ? 'verde' : 'linea') + '">' +
          (activa ? 'Activa' : 'Inactiva') + '</span></td>' +
          celdaModulo(e, 'basico') + celdaModulo(e, 'stock') + celdaModulo(e, 'cierre') +
          '<td class="derecha nowrap">' +
          btn(e.id, 'ver', 'Ver') +
          btn(e.id, 'editar', 'Editar') +
          btn(e.id, 'estado', activa ? 'Desactivar' : 'Activar') +
          (activa ? btn(e.id, 'entrar', 'Administrar →', 'azul') : '') +
          '</td></tr>'
        );
      })
      .join('');
  }

  function celdaModulo(empresa, modulo) {
    const on = empresa.modulos && empresa.modulos[modulo] !== false;
    return (
      '<td class="centro"><span class="badge badge--' + (on ? 'verde' : 'linea') + '">' +
      (on ? '✓' : '—') + '</span></td>'
    );
  }

  function btn(empresaId, accion, texto, color) {
    return (
      '<button class="btn btn--' + (color || 'fantasma') + ' btn--xs" ' +
      'data-accion-empresa="' + accion + '" data-empresa="' + U.esc(empresaId) + '">' +
      U.esc(texto) + '</button> '
    );
  }

  /* --- Ficha de una empresa: identidad, módulos, datos y usuarios --- */
  function abrirDetalle(empresaId) {
    empresaAbierta = empresaId;
    pintarDetalle();
    const nodo = $('#detalleEmpresa');
    if (nodo) nodo.scrollIntoView({ block: 'start' });
  }

  function pintarDetalle() {
    const nodo = $('#detalleEmpresa');
    if (!empresaAbierta) {
      nodo.innerHTML = '';
      return;
    }

    const e = S.getEmpresa(empresaAbierta);
    if (!e) {
      empresaAbierta = null;
      nodo.innerHTML = '';
      return;
    }

    /* Los usuarios se piden por empresa. Los de plataforma no salen
       nunca aquí: no pertenecen a ninguna. */
    const usuarios = S.getUsuarios({ todos: true, empresaId: e.id });
    const sucursales = S.getSucursales({ todas: true, empresaId: e.id });
    const i = e.theme;

    nodo.innerHTML =
      '<div class="caja">' +
      '<div class="fila fila--entre mb-16" style="flex-wrap:wrap;gap:12px">' +
      '<h3 style="margin:0">' + U.esc(e.nombre) + '</h3>' +
      '<button class="btn btn--fantasma btn--xs" data-cerrar-detalle>Cerrar</button>' +
      '</div>' +

      // --- Identidad visual de la empresa
      '<h4 class="mini tenue">Tema de la empresa</h4>' +
      '<div class="tsc-identidad mb-24">' +
      '<span class="tsc-identidad__marca" style="background:linear-gradient(135deg,' +
      U.esc(i.primary) + ',' + U.esc(i.secondary) + ');color:#fff">' +
      U.esc(i.iniciales) + '</span>' +
      '<div class="crece"><b>' + U.esc(e.nombre) + '</b>' +
      '<div class="mini tenue">' + U.esc(i.lema || 'Sin lema') + '</div>' +
      '<div class="mini tenue mono">' + U.esc(i.primary) + ' · ' + U.esc(i.secondary) + ' · ' +
      U.esc((S.tipografia(i.fontFamily) || {}).nombre || i.fontFamily) + '</div>' +
      '</div>' +
      '<button class="btn btn--fantasma btn--sm" data-tema="' + U.esc(e.id) + '">Administrar tema</button>' +
      '</div>' +

      // --- Módulos
      '<h4 class="mini tenue">Módulos</h4>' +
      '<div class="opciones-pago mb-24">' +
      S.catalogoModulos().map((m) => filaModulo(e, m)).join('') +
      '</div>' +

      // --- Información general
      '<h4 class="mini tenue">Información general</h4>' +
      '<div class="caja-datos mb-24">' +
      linea('Id', e.id) +
      linea('Razón social', e.razonSocial || '—') +
      linea('NIT', e.nit || '—') +
      linea('Teléfono', e.telefono || '—') +
      linea('WhatsApp', e.whatsapp || '—') +
      linea('Correo', e.email || '—') +
      linea('Estado', e.activa === false ? 'Inactiva' : 'Activa') +
      linea('Creada', (e.creada || '').slice(0, 10) || '—') +
      linea('Unidades / locales', sucursales.length + ' · ' +
        sucursales.map((s) => S.getTipoNegocio(s.tipoNegocio).icono + ' ' + s.nombre).join(', ')) +
      '</div>' +

      // --- Usuarios
      '<h4 class="mini tenue">Usuarios (' + usuarios.length + ')</h4>' +
      (usuarios.length
        ? '<div class="tabla-wrap"><table class="tabla"><thead><tr>' +
          '<th>Nombre</th><th>Acceso</th><th>Rol</th><th>Estado</th></tr></thead><tbody>' +
          usuarios
            .map(
              (u) =>
                '<tr><td>' + U.esc(u.nombre) + '</td>' +
                '<td class="mini tenue mono">' + U.esc(u.usuario) + '</td>' +
                '<td>' + A.iconoRol(u.rol) + ' ' + U.esc(A.nombreRol(u.rol)) + '</td>' +
                '<td>' + (u.activo === false ? 'Inactivo' : 'Activo') + '</td></tr>'
            )
            .join('') +
          '</tbody></table></div>'
        : '<div class="vacio">Esta empresa todavía no tiene usuarios.</div>') +

      '<div class="fila fila--fin mt-24" style="gap:8px">' +
      '<button class="btn btn--fantasma btn--sm" data-editar="' + U.esc(e.id) + '">Editar datos</button>' +
      (e.activa !== false
        ? '<button class="btn btn--azul" data-entrar="' + U.esc(e.id) + '">Administrar ' +
          U.esc(e.nombre) + ' →</button>'
        : '') +
      '</div>' +
      (e.activa === false
        ? '<p class="mini ambar mt-16">Una empresa desactivada no se puede administrar. Actívala primero.</p>'
        : '') +
      '</div>';
  }

  function filaModulo(empresa, m) {
    const on = empresa.modulos && empresa.modulos[m.id] !== false;
    /* Básico no se apaga: es el sistema mismo. Se muestra marcado y
       bloqueado, para que se vea que está y por qué no se toca. */
    const fijo = !!m.obligatorio;

    return (
      '<label class="op" style="cursor:' + (fijo ? 'default' : 'pointer') + '">' +
      '<input type="checkbox" data-modulo="' + m.id + '" data-empresa="' + U.esc(empresa.id) + '"' +
      (on ? ' checked' : '') + (fijo ? ' disabled' : '') + '>' +
      '<div><b>' + m.icono + ' ' + U.esc(m.nombre) + '</b>' +
      '<span>' + U.esc(m.descripcion) + (fijo ? ' Siempre incluido.' : '') + '</span></div></label>'
    );
  }

  function linea(etiqueta, valor) {
    return '<div class="linea"><span>' + U.esc(etiqueta) + '</span><b>' + U.esc(valor) + '</b></div>';
  }

  /* =================================================================
     🧩 MÓDULOS · qué vende la plataforma y quién lo tiene
     ================================================================= */
  function pintarModulos() {
    const todas = S.getEmpresas({ todas: true });

    $('#catalogoModulos').innerHTML = S.catalogoModulos()
      .map(function (m) {
        const conEl = todas.filter((e) => e.modulos && e.modulos[m.id] !== false);
        const sinEl = todas.filter((e) => !e.modulos || e.modulos[m.id] === false);
        return (
          '<div class="caja mb-16">' +
          '<div class="fila fila--entre mb-8" style="flex-wrap:wrap;gap:10px">' +
          '<h3 style="margin:0">' + m.icono + ' ' + U.esc(m.nombre) + '</h3>' +
          '<span class="badge badge--' + (m.obligatorio ? 'azul' : 'linea') + '">' +
          (m.obligatorio ? 'Siempre incluido' : 'Se contrata') + '</span>' +
          '</div>' +
          '<p class="mini tenue">' + U.esc(m.descripcion) + '</p>' +
          '<div class="fila mt-8" style="gap:6px;flex-wrap:wrap">' +
          m.incluye.map((x) => '<span class="badge badge--linea">' + U.esc(x) + '</span>').join('') +
          '</div>' +
          '<div class="caja-datos mt-16">' +
          '<div class="linea"><span>Empresas con este módulo</span><b class="mono">' +
          conEl.length + ' de ' + todas.length + '</b></div>' +
          (conEl.length
            ? '<div class="linea"><span class="tenue">Quiénes</span><b>' +
              conEl.map((e) => U.esc(e.nombre)).join(', ') + '</b></div>'
            : '') +
          (sinEl.length
            ? '<div class="linea"><span class="tenue">Sin contratar</span><b>' +
              sinEl.map((e) => U.esc(e.nombre)).join(', ') + '</b></div>'
            : '') +
          '</div></div>'
        );
      })
      .join('');
  }

  /* =================================================================
     ⚙️ CONFIGURACIÓN DE PLATAFORMA
     ================================================================= */
  function pintarConfig() {
    const porDefecto = NASCAR.MODULOS_POR_DEFECTO || {};
    const conBase = !!(NASCAR.Remoto && NASCAR.Remoto.activo);

    $('#configPlataforma').innerHTML =
      '<div class="caja mb-16">' +
      '<h3>Cómo nace una empresa nueva</h3>' +
      '<p class="mini tenue">Lo que recibe automáticamente al darla de alta.</p>' +
      '<div class="caja-datos mt-16">' +
      S.catalogoModulos()
        .map(
          (m) =>
            '<div class="linea"><span>' + m.icono + ' ' + U.esc(m.nombre) + '</span><b>' +
            (m.obligatorio || porDefecto[m.id] ? 'Incluido' : 'No incluido') + '</b></div>'
        )
        .join('') +
      '<div class="linea"><span>Primera sede</span><b>Se crea sola</b></div>' +
      '<div class="linea"><span>Carta, stock y usuarios</span><b>Vacíos</b></div>' +
      '</div>' +
      '<p class="mini tenue" style="margin:12px 0 0">' +
      'Una empresa nueva no hereda nada de ninguna otra. Los módulos se cambian ' +
      'después desde su ficha.</p>' +
      '</div>' +

      '<div class="caja">' +
      '<h3>Almacenamiento</h3>' +
      '<p class="mini tenue">' +
      (conBase ? 'Los datos viven en la base de datos PostgreSQL, a través de PostgREST.'
               : 'Este MVP guarda todo en el navegador de este equipo.') + '</p>' +
      '<div class="caja-datos mt-16">' +
      '<div class="linea"><span>Modo</span><b>' +
      (conBase ? 'Base de datos (PostgREST)' : S.almacenamientoEsTemporal() ? 'Temporal (memoria)' : 'localStorage') + '</b></div>' +
      '<div class="linea"><span>Empresas registradas</span><b class="mono">' +
      S.getEmpresas({ todas: true }).length + '</b></div>' +
      '<div class="linea"><span>Sitio corporativo</span><b>' +
      '<a href="https://taseca.tech/" target="_blank" rel="noopener">taseca.tech ↗</a></b></div>' +
      '</div>' +
      (conBase
        ? '<p class="mini tenue" style="margin:12px 0 0">Cada acción de este panel la valida la base de datos: ' +
          'sólo un usuario de plataforma puede ejecutarla.</p>'
        : '<p class="mini ambar" style="margin:12px 0 0">' +
          'Sin backend todavía: no hay servidor, ni base de datos, ni autenticación real.</p>') +
      '</div>';
  }

  /* =================================================================
     👤 PERFIL TASECA
     ================================================================= */
  function pintarPerfil() {
    const u = A.getUsuarioActual();
    const ctx = S.getEmpresaContexto();

    $('#perfilPlataforma').innerHTML =
      '<div class="caja">' +
      '<div class="fila mb-16" style="gap:14px;align-items:center">' +
      '<svg class="tsc-marca__logo" style="width:54px;height:54px"><use href="#tsc-logo"></use></svg>' +
      '<div><h3 style="margin:0">' + U.esc(u.nombre) + '</h3>' +
      '<span class="mini tenue mono">Taseca Platform</span></div>' +
      '</div>' +
      '<div class="caja-datos">' +
      linea('Rol', A.nombreRol(u.rol)) +
      linea('Nivel', 'Plataforma (scope: platform)') +
      linea('Empresa a la que pertenece', 'Ninguna — Taseca está por encima de las empresas') +
      linea('Empresa que administra ahora', ctx ? (S.getEmpresa(ctx) || {}).nombre || ctx : 'Ninguna') +
      '</div>' +
      '<p class="mini tenue" style="margin:14px 0 0">' +
      'Entrar a una empresa cambia el <b>contexto</b>, no la identidad: el rol y el ' +
      'nivel siguen siendo los de Taseca, y los registros que se creen quedan firmados ' +
      'a este nombre.</p>' +
      '<div class="fila fila--fin mt-16">' +
      '<button class="btn btn--fantasma btn--sm" id="btnSalirPerfil">Cerrar sesión</button>' +
      '</div></div>';

    const b = $('#btnSalirPerfil');
    if (b)
      b.addEventListener('click', function () {
        S.logout();
        location.reload();
      });
  }

  /* =================================================================
     ACCIONES

     Todas vuelven a exigir el permiso. Que el botón esté en pantalla no
     es la autorización: la autorización se comprueba aquí.
     ================================================================= */
  function cambiarModulo(empresaId, modulo, encender) {
    if (!A.exigir('plataforma')) return refrescar();

    const cambio = {};
    cambio[modulo] = !!encender;

    try {
      S.setModulos(empresaId, cambio, { superadmin: true });
    } catch (err) {
      U.toast(err.message, 'error');
      return refrescar();
    }

    const def = S.definicionModulo(modulo);
    const e = S.getEmpresa(empresaId);
    U.toast(
      'Módulo ' + (def ? def.nombre : modulo) +
        (encender ? ' habilitado' : ' deshabilitado') + ' para ' + e.nombre + '.'
    );
    refrescar();
  }

  function alternarEstado(empresaId) {
    if (!A.exigir('plataforma')) return;
    const e = S.getEmpresa(empresaId);
    const activar = e.activa === false;

    const seguir = function () {
      try {
        S.activarEmpresa(empresaId, activar, { superadmin: true });
      } catch (err) {
        return U.toast(err.message, 'error');
      }
      U.toast(e.nombre + (activar ? ' activada.' : ' desactivada.'));
      refrescar();
    };

    if (activar) return seguir();

    /* Desactivar no borra: los datos se quedan donde están y la empresa
       vuelve tal cual al activarla. Se avisa igualmente porque la gente
       de ese negocio deja de poder entrar. */
    U.confirmar(
      'Al desactivar ' + e.nombre + ', sus usuarios no podrán entrar. Los datos NO se borran ' +
        'y todo vuelve al activarla de nuevo.',
      seguir,
      'Sí, desactivar'
    );
  }

  function entrarAEmpresa(empresaId) {
    if (!A.exigir('plataforma')) return;
    try {
      /* CONTEXTO temporal, no cambio de identidad. La elección vive en
         la sesión del SuperAdmin y muere con ella: no pisa la empresa
         que ven los usuarios de ese negocio, y él sigue siendo
         superadmin con scope de plataforma. */
      S.setEmpresaContexto(empresaId);
    } catch (err) {
      return U.toast(err.message, 'error');
    }
    location.href = (NASCAR.PORTALES || {}).operativo.panel;
  }

  /* =================================================================
     ALTA DE EMPRESA · asistente por pasos

     Tres pasos y una vista previa. Al terminar, la empresa queda lista
     para trabajar: con su id, su tema, sus módulos, su primera sede, su
     configuración y —si se pide— su administrador. Sin tocar código, ni
     copiar carpetas, ni duplicar HTML.
     ================================================================= */
  function nuevaEmpresa() {
    if (!A.exigir('plataforma')) return;

    /* El borrador vive aquí mientras dura el asistente. No se escribe
       nada hasta el último paso: si se cancela a la mitad, no queda una
       empresa a medio montar. */
    const b = {
      paso: 1,
      plantilla: 'personalizado',
      nombre: '', razonSocial: '', nit: '', telefono: '', whatsapp: '',
      email: '', direccion: '', ciudad: '', activa: true,
      theme: Object.assign({}, NASCAR.TEMA_BASE),
      modulos: Object.assign({}, NASCAR.MODULOS_POR_DEFECTO),
      admin: { crear: false, nombre: '', usuario: '', pin: '' },
    };

    const m = U.modal({ titulo: 'Nueva empresa cliente', ancho: 720, contenido: '<div id="wz"></div>' });
    const raiz = m.raiz;
    const $$ = (sel) => U.$(sel, raiz);

    function pintar() {
      $$('#wz').innerHTML =
        pasos(b.paso) +
        (b.paso === 1 ? paso1() : b.paso === 2 ? paso2() : paso3()) +
        '<div class="fila fila--entre mt-24" style="gap:8px">' +
        (b.paso > 1
          ? '<button class="btn btn--fantasma" data-atras>← Atrás</button>'
          : '<button class="btn btn--fantasma" data-cancelar>Cancelar</button>') +
        '<div class="crece"></div>' +
        (b.paso < 3
          ? '<button class="btn btn--azul" data-siguiente>Siguiente →</button>'
          : '<button class="btn btn--azul" data-crear>Crear empresa</button>') +
        '</div>';
      conectarPaso();
    }

    function pasos(actual) {
      const nombres = ['Información', 'Identidad visual', 'Módulos y acceso'];
      return (
        '<div class="fila mb-24" style="gap:8px;flex-wrap:wrap">' +
        nombres
          .map(
            (n, i) =>
              '<span class="badge badge--' + (i + 1 === actual ? 'azul' : 'linea') + '">' +
              (i + 1) + '. ' + n + '</span>'
          )
          .join('') +
        '</div>'
      );
    }

    /* ---------- PASO 1 · Información ---------- */
    function paso1() {
      return (
        '<div class="rejilla-2">' +
        campo('wNombre', 'Nombre comercial *', b.nombre) +
        campo('wRazon', 'Razón social', b.razonSocial) +
        campo('wNit', 'NIT', b.nit) +
        campo('wTelefono', 'Teléfono', b.telefono) +
        campo('wWhatsapp', 'WhatsApp', b.whatsapp, '57 y el número, sin espacios') +
        campo('wEmail', 'Correo', b.email, '', 'email') +
        campo('wDireccion', 'Dirección', b.direccion) +
        campo('wCiudad', 'Ciudad', b.ciudad) +
        '</div>' +
        '<label class="campo mt-16"><span>Estado</span><select class="select" id="wEstado">' +
        '<option value="1"' + (b.activa ? ' selected' : '') + '>Activa</option>' +
        '<option value="0"' + (!b.activa ? ' selected' : '') + '>Inactiva</option>' +
        '</select></label>'
      );
    }

    /* ---------- PASO 2 · Identidad visual ---------- */
    function paso2() {
      const t = b.theme;
      return (
        '<h4 class="mini tenue">Plantilla de partida</h4>' +
        '<p class="mini tenue" style="margin-top:-4px">Sólo propone tema y módulos iniciales. ' +
        'No trae funcionalidad propia de cada sector.</p>' +
        '<div class="fila mb-24" style="gap:8px;flex-wrap:wrap">' +
        (NASCAR.PLANTILLAS_EMPRESA || [])
          .map(
            (pl) =>
              '<button class="btn btn--' + (b.plantilla === pl.id ? 'azul' : 'fantasma') +
              ' btn--sm" data-plantilla="' + pl.id + '" title="' + U.esc(pl.descripcion) + '">' +
              pl.icono + ' ' + U.esc(pl.nombre) + '</button>'
          )
          .join('') +
        '</div>' +

        '<div class="rejilla-2">' +
        colorCampo('wPrim', 'Color principal', t.primary) +
        colorCampo('wSec', 'Color secundario', t.secondary) +
        colorCampo('wAcc', 'Color de acento', t.accent) +
        colorCampo('wBg', 'Color de fondo', t.background) +
        '</div>' +

        '<label class="campo"><span>Tipografía</span><select class="select" id="wFuente">' +
        (NASCAR.TIPOGRAFIAS || [])
          .map(
            (f) =>
              '<option value="' + f.id + '"' + (t.fontFamily === f.id ? ' selected' : '') + '>' +
              U.esc(f.nombre) + ' — ' + U.esc(f.muestra) + '</option>'
          )
          .join('') +
        '</select></label>' +

        '<div class="rejilla-2">' +
        '<label class="campo"><span>Logo</span>' +
        '<input class="input" type="file" id="wLogo" accept="image/png,image/jpeg,image/webp">' +
        '<small class="mini tenue">PNG, JPG o WEBP. Opcional.</small></label>' +
        '<label class="campo"><span>Favicon</span>' +
        '<input class="input" type="file" id="wFavicon" accept="image/png,image/jpeg,image/webp">' +
        '<small class="mini tenue">Opcional.</small></label>' +
        '</div>' +

        '<div class="rejilla-2">' +
        campo('wLogoTexto', 'Logotipo · primera parte', t.logoTexto, 'Si no subes imagen') +
        campo('wLogoAcento', 'Logotipo · parte en acento', t.logoAcento) +
        '</div>' +
        campo('wLema', 'Lema', t.lema, 'Opcional') +

        '<h4 class="mini tenue mt-24">Vista previa</h4>' +
        '<p class="mini tenue" style="margin-top:-4px">Aproximación de cómo verá el cliente su panel.</p>' +
        '<div id="wPreview"></div>'
      );
    }

    /* ---------- PASO 3 · Módulos y acceso ---------- */
    function paso3() {
      const a = b.admin;
      return (
        '<h4 class="mini tenue">Módulos</h4>' +
        '<p class="mini tenue" style="margin-top:-4px">Qué partes del sistema contrata. ' +
        '<b>Independiente del tema visual.</b></p>' +
        '<div class="opciones-pago mb-24">' +
        S.catalogoModulos()
          .map(function (mo) {
            const on = mo.obligatorio || b.modulos[mo.id] === true;
            return (
              '<label class="op" style="cursor:' + (mo.obligatorio ? 'default' : 'pointer') + '">' +
              '<input type="checkbox" data-mod="' + mo.id + '"' + (on ? ' checked' : '') +
              (mo.obligatorio ? ' disabled' : '') + '>' +
              '<div><b>' + mo.icono + ' ' + U.esc(mo.nombre) + '</b>' +
              '<span>' + U.esc(mo.descripcion) + '</span></div></label>'
            );
          })
          .join('') +
        '</div>' +

        '<h4 class="mini tenue">Administrador inicial</h4>' +
        '<label class="op mb-16" style="cursor:pointer">' +
        '<input type="checkbox" id="wCrearAdmin"' + (a.crear ? ' checked' : '') + '>' +
        '<div><b>Crear el administrador de esta empresa</b>' +
        '<span>Pertenecerá únicamente a ella. Nunca es SuperAdmin.</span></div></label>' +
        '<div id="wAdminCampos" class="' + (a.crear ? '' : 'oculto') + '">' +
        '<div class="rejilla-2">' +
        campo('wAdminNombre', 'Nombre', a.nombre) +
        campo('wAdminUsuario', 'Usuario de acceso', a.usuario, 'Único en toda la plataforma') +
        '</div>' +
        campo('wAdminPin', 'PIN', a.pin, 'Entre 4 y 6 dígitos') +
        '</div>' +

        '<div class="caja-datos mt-24">' +
        '<div class="linea"><span class="tenue">Empresa</span><b>' + U.esc(b.nombre || '—') + '</b></div>' +
        '<div class="linea"><span class="tenue">Plantilla</span><b>' + U.esc(nombrePlantilla()) + '</b></div>' +
        '<div class="linea"><span class="tenue">Datos iniciales</span>' +
        '<b>Sede propia, configuración propia, sin heredar nada</b></div>' +
        '</div>'
      );
    }

    function nombrePlantilla() {
      const pl = (NASCAR.PLANTILLAS_EMPRESA || []).find((x) => x.id === b.plantilla);
      return pl ? pl.nombre : b.plantilla;
    }

    /* ---------- Vista previa del panel del cliente ----------
       Se pinta con los colores y la tipografía del borrador, dentro de
       un recuadro aislado. Es sólo una maqueta: no toca nada real. */
    function pintarPreview() {
      const nodo = $$('#wPreview');
      if (!nodo) return;
      const t = b.theme;
      const familia = S.familiaTipografica(t.fontFamily);
      const marca = t.logo
        ? '<img src="' + t.logo + '" alt="" style="height:26px;display:block">'
        : '<span style="font-weight:800;font-size:19px;letter-spacing:.04em">' +
          U.esc(t.logoTexto || b.nombre || 'Tu empresa') +
          (t.logoAcento ? '<span style="color:' + t.accent + '">' + U.esc(t.logoAcento) + '</span>' : '') +
          '</span>';

      nodo.innerHTML =
        '<div style="border-radius:12px;overflow:hidden;border:1px solid var(--platform-border-soft);' +
        'background:' + t.background + ';font-family:' + familia + ';color:#e8ecf2">' +

        // Cabecera + menú
        '<div style="background:linear-gradient(90deg,' + t.primary + ',' + t.secondary + ');height:4px"></div>' +
        '<div style="display:flex;align-items:center;gap:12px;padding:12px 16px;' +
        'border-bottom:1px solid rgba(255,255,255,.09)">' + marca +
        '<div style="flex:1"></div>' +
        '<span style="background:' + t.primary + ';color:#fff;border-radius:999px;' +
        'padding:4px 12px;font-size:11px">Admin</span></div>' +

        '<div style="display:flex;gap:16px;padding:10px 16px;font-size:12px;' +
        'border-bottom:1px solid rgba(255,255,255,.09)">' +
        '<span style="color:' + t.accent + ';border-bottom:2px solid ' + t.secondary + ';padding-bottom:6px">Pedidos</span>' +
        '<span style="opacity:.6">Pagos</span><span style="opacity:.6">Carta</span>' +
        '<span style="opacity:.6">Ventas</span></div>' +

        // Tarjetas
        '<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:10px;padding:16px">' +
        [
          ['Pedidos del día', '12', t.primary],
          ['Vendido hoy', '$ 840.000', t.accent],
          ['Por cobrar', '$ 120.000', t.secondary],
        ]
          .map(
            (k) =>
              '<div style="background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.09);' +
              'border-left:3px solid ' + k[2] + ';border-radius:8px;padding:10px 12px">' +
              '<div style="font-size:10px;letter-spacing:.14em;text-transform:uppercase;opacity:.65">' +
              k[0] + '</div>' +
              '<div style="font-size:19px;font-weight:700;margin-top:4px">' + k[1] + '</div></div>'
          )
          .join('') +
        '</div>' +

        // Encabezado y botones
        '<div style="padding:0 16px 16px">' +
        '<h4 style="margin:0 0 4px;font-size:17px;font-family:inherit">Pedidos de hoy</h4>' +
        '<p style="margin:0 0 12px;font-size:12px;opacity:.65">Así se verán los textos y los botones.</p>' +
        '<span style="background:' + t.primary + ';color:#fff;border-radius:8px;padding:8px 14px;' +
        'font-size:12px;font-weight:600;display:inline-block;margin-right:8px">Botón principal</span>' +
        '<span style="border:1px solid ' + t.accent + ';color:' + t.accent + ';border-radius:8px;' +
        'padding:8px 14px;font-size:12px;display:inline-block">Secundario</span>' +
        (t.lema
          ? '<p style="margin:12px 0 0;font-size:12px;opacity:.7;font-style:italic">' + U.esc(t.lema) + '</p>'
          : '') +
        '</div></div>';
    }

    /* ---------- Cableado de cada paso ---------- */
    function conectarPaso() {
      const bt = (sel, fn) => {
        const el = U.$(sel, raiz);
        if (el) el.onclick = fn;
      };
      bt('[data-cancelar]', m.cerrar);
      bt('[data-atras]', () => { guardarPaso(); b.paso--; pintar(); });
      bt('[data-siguiente]', () => {
        if (!guardarPaso()) return;
        b.paso++;
        pintar();
      });
      bt('[data-crear]', crear);

      if (b.paso === 2) {
        U.$$('[data-plantilla]', raiz).forEach(function (btn) {
          btn.onclick = function () {
            aplicarPlantilla(btn.dataset.plantilla);
            pintar();
          };
        });

        ['#wPrim', '#wSec', '#wAcc', '#wBg', '#wFuente', '#wLogoTexto', '#wLogoAcento', '#wLema'].forEach(
          function (sel) {
            const el = U.$(sel, raiz);
            if (el) el.addEventListener('input', () => { leerTema(); pintarPreview(); });
            if (el) el.addEventListener('change', () => { leerTema(); pintarPreview(); });
          }
        );

        cargarImagen('#wLogo', 'logo');
        cargarImagen('#wFavicon', 'favicon');
        pintarPreview();
      }

      if (b.paso === 3) {
        const chk = U.$('#wCrearAdmin', raiz);
        if (chk)
          chk.onchange = function () {
            b.admin.crear = chk.checked;
            U.$('#wAdminCampos', raiz).classList.toggle('oculto', !chk.checked);
          };
      }
    }

    function cargarImagen(sel, campoTema) {
      const el = U.$(sel, raiz);
      if (!el) return;
      el.addEventListener('change', function () {
        const archivo = el.files && el.files[0];
        if (!archivo) return;
        /* Se reutiliza el compresor de comprobantes: reduce y convierte a
           dataURL, que es lo único que acepta el tema. */
        U.comprimirImagen(archivo, { ladoMaximoPx: campoTema === 'favicon' ? 64 : 320, calidad: 0.85, pesoGuardadoMaximoKB: 250 })
          .then(function (res) {
            // comprimirImagen devuelve { dataUrl, pesoKB… }: el tema guarda sólo la imagen
            b.theme[campoTema] = res && res.dataUrl ? res.dataUrl : res;
            U.toast(campoTema === 'logo' ? 'Logo cargado.' : 'Favicon cargado.');
            pintarPreview();
          })
          .catch((err) => U.toast(err.message, 'error'));
      });
    }

    function aplicarPlantilla(id) {
      const pl = (NASCAR.PLANTILLAS_EMPRESA || []).find((x) => x.id === id);
      b.plantilla = id;
      /* La plantilla propone tema y módulos; lo que ya se hubiera
         escrito a mano en los campos se relee después. */
      b.theme = Object.assign({}, NASCAR.TEMA_BASE, pl && pl.theme ? pl.theme : {});
      b.modulos = Object.assign({}, pl && pl.modulos ? pl.modulos : NASCAR.MODULOS_POR_DEFECTO);
    }

    function leerTema() {
      const v = (id) => (U.$('#' + id, raiz) ? U.$('#' + id, raiz).value : '');
      b.theme.primary = v('wPrim');
      b.theme.secondary = v('wSec');
      b.theme.accent = v('wAcc');
      b.theme.background = v('wBg');
      b.theme.fontFamily = v('wFuente');
      b.theme.logoTexto = v('wLogoTexto');
      b.theme.logoAcento = v('wLogoAcento');
      b.theme.lema = v('wLema');
    }

    function guardarPaso() {
      const v = (id) => (U.$('#' + id, raiz) ? U.$('#' + id, raiz).value.trim() : '');

      if (b.paso === 1) {
        b.nombre = v('wNombre');
        b.razonSocial = v('wRazon');
        b.nit = v('wNit');
        b.telefono = v('wTelefono');
        b.whatsapp = v('wWhatsapp');
        b.email = v('wEmail');
        b.direccion = v('wDireccion');
        b.ciudad = v('wCiudad');
        b.activa = v('wEstado') === '1';
        if (b.nombre.length < 2) {
          U.toast('La empresa necesita un nombre comercial.', 'error');
          return false;
        }
      }

      if (b.paso === 2) leerTema();

      if (b.paso === 3) {
        S.catalogoModulos().forEach(function (mo) {
          const chk = U.$('[data-mod="' + mo.id + '"]', raiz);
          b.modulos[mo.id] = mo.obligatorio ? true : !!(chk && chk.checked);
        });
        b.admin.crear = !!(U.$('#wCrearAdmin', raiz) && U.$('#wCrearAdmin', raiz).checked);
        b.admin.nombre = v('wAdminNombre');
        b.admin.usuario = v('wAdminUsuario');
        b.admin.pin = v('wAdminPin');
      }
      return true;
    }

    function crear() {
      if (!guardarPaso()) return;

      let r;
      try {
        r = S.altaEmpresa(
          {
            nombre: b.nombre, razonSocial: b.razonSocial, nit: b.nit,
            telefono: b.telefono, whatsapp: b.whatsapp, email: b.email,
            direccion: b.direccion, ciudad: b.ciudad, activa: b.activa,
            plantilla: b.plantilla,
            modulos: b.modulos,
            theme: b.theme,
            admin: b.admin.crear ? b.admin : null,
          },
          { superadmin: true }
        );
      } catch (err) {
        return U.toast(err.message, 'error');
      }

      m.cerrar();
      U.toast(
        r.empresa.nombre + ' creada.' + (r.usuario ? ' Administrador: ' + r.usuario.usuario + '.' : ''),
        'info'
      );
      empresaAbierta = r.empresa.id;
      irASeccion('empresas');
    }

    pintar();
  }

  function colorCampo(id, etiqueta, valor) {
    return (
      '<label class="campo"><span>' + U.esc(etiqueta) + '</span>' +
      '<input class="input" type="color" id="' + id + '" value="' + U.esc(valor) + '" ' +
      'style="height:44px;padding:4px"></label>'
    );
  }

  /* =================================================================
     EDITAR UNA EMPRESA YA CREADA
     ================================================================= */
  function editarEmpresa(empresaId) {
    if (!A.exigir('plataforma')) return;
    if (!empresaId) return nuevaEmpresa();

    const e = S.getEmpresa(empresaId);
    if (!e) return;

    const m = U.modal({
      titulo: 'Editar ' + e.nombre,
      ancho: 560,
      contenido:
        '<div class="rejilla-2">' +
        campo('eNombre', 'Nombre comercial', e.nombre) +
        campo('eRazon', 'Razón social', e.razonSocial) +
        campo('eNit', 'NIT', e.nit) +
        campo('eTelefono', 'Teléfono', e.telefono) +
        campo('eWhatsapp', 'WhatsApp', e.whatsapp, '57 y el número, sin espacios') +
        campo('eEmail', 'Correo', e.email, '', 'email') +
        '</div>' +

        '<label class="campo mt-16"><span>Estado</span><select class="select" id="eEstado">' +
        '<option value="1"' + (e.activa !== false ? ' selected' : '') + '>Activa</option>' +
        '<option value="0"' + (e.activa === false ? ' selected' : '') + '>Inactiva</option>' +
        '</select></label>' +

        '<p class="mini tenue mt-16">Los módulos y el tema se administran desde la ficha de la empresa.</p>' +

        '<div class="fila fila--fin mt-24">' +
        '<button class="btn btn--fantasma" data-cancelar>Cancelar</button>' +
        '<button class="btn btn--azul" data-guardar>Guardar</button>' +
        '</div>',
    });

    U.$('[data-cancelar]', m.raiz).onclick = m.cerrar;
    U.$('[data-guardar]', m.raiz).onclick = function () {
      const v = (id) => U.$('#' + id, m.raiz).value.trim();
      try {
        S.guardarEmpresa(
          {
            id: e.id,
            nombre: v('eNombre'),
            razonSocial: v('eRazon'),
            nit: v('eNit'),
            telefono: v('eTelefono'),
            whatsapp: v('eWhatsapp'),
            email: v('eEmail'),
            activa: U.$('#eEstado', m.raiz).value === '1',
          },
          { superadmin: true }
        );
      } catch (err) {
        return U.toast(err.message, 'error');
      }
      m.cerrar();
      U.toast('Empresa actualizada.');
      refrescar();
    };
  }

  /* =================================================================
     TEMA DE UNA EMPRESA YA CREADA

     Cómo se ve el cliente. No repinta el panel de Taseca: aquél tiene
     su propia hoja (css/taseca.css) y ninguna empresa la toca.
     ================================================================= */
  function editarTema(empresaId) {
    if (!A.exigir('plataforma')) return;
    const e = S.getEmpresa(empresaId);
    if (!e) return;
    const t = Object.assign({}, e.theme);

    const m = U.modal({
      titulo: 'Tema de ' + e.nombre,
      ancho: 640,
      contenido:
        '<div class="rejilla-2">' +
        colorCampo('tPrim', 'Color principal', t.primary) +
        colorCampo('tSec', 'Color secundario', t.secondary) +
        colorCampo('tAcc', 'Color de acento', t.accent) +
        colorCampo('tBg', 'Color de fondo', t.background) +
        '</div>' +
        '<label class="campo"><span>Tipografía</span><select class="select" id="tFuente">' +
        (NASCAR.TIPOGRAFIAS || [])
          .map(
            (f) =>
              '<option value="' + f.id + '"' + (t.fontFamily === f.id ? ' selected' : '') + '>' +
              U.esc(f.nombre) + ' — ' + U.esc(f.muestra) + '</option>'
          )
          .join('') +
        '</select></label>' +
        '<div class="rejilla-2">' +
        campo('tLogoTexto', 'Logotipo · primera parte', t.logoTexto) +
        campo('tLogoAcento', 'Logotipo · parte en acento', t.logoAcento) +
        '</div>' +
        '<div class="rejilla-2">' +
        campo('tIniciales', 'Iniciales', t.iniciales, 'Para el avatar en este panel') +
        campo('tLema', 'Lema', t.lema, 'Opcional') +
        '</div>' +
        '<label class="campo"><span>Logo</span>' +
        '<input class="input" type="file" id="tLogo" accept="image/png,image/jpeg,image/webp">' +
        (t.logo ? '<small class="mini tenue">Ya tiene un logo cargado.</small>' : '') +
        '</label>' +
        '<h4 class="mini tenue mt-16">Vista previa</h4>' +
        '<div id="tPreview"></div>' +
        '<div class="fila fila--fin mt-24">' +
        '<button class="btn btn--fantasma" data-cancelar>Cancelar</button>' +
        '<button class="btn btn--azul" data-guardar>Guardar tema</button>' +
        '</div>',
    });

    const leer = function () {
      const v = (id) => U.$('#' + id, m.raiz).value;
      t.primary = v('tPrim');
      t.secondary = v('tSec');
      t.accent = v('tAcc');
      t.background = v('tBg');
      t.fontFamily = v('tFuente');
      t.logoTexto = v('tLogoTexto');
      t.logoAcento = v('tLogoAcento');
      t.iniciales = v('tIniciales');
      t.lema = v('tLema');
    };

    const preview = function () {
      const familia = S.familiaTipografica(t.fontFamily);
      const marca = t.logo
        ? '<img src="' + t.logo + '" alt="" style="height:26px;display:block">'
        : '<span style="font-weight:800;font-size:19px">' + U.esc(t.logoTexto || e.nombre) +
          (t.logoAcento ? '<span style="color:' + t.accent + '">' + U.esc(t.logoAcento) + '</span>' : '') +
          '</span>';
      U.$('#tPreview', m.raiz).innerHTML =
        '<div style="border-radius:12px;border:1px solid var(--platform-border-soft);overflow:hidden;' +
        'background:' + t.background + ';font-family:' + familia + ';color:#e8ecf2">' +
        '<div style="background:linear-gradient(90deg,' + t.primary + ',' + t.secondary + ');height:4px"></div>' +
        '<div style="display:flex;align-items:center;gap:12px;padding:12px 16px">' + marca +
        '<div style="flex:1"></div>' +
        '<span style="background:' + t.primary + ';color:#fff;border-radius:999px;padding:4px 12px;' +
        'font-size:11px">Botón</span></div>' +
        '<div style="padding:0 16px 16px"><h4 style="margin:0;font-family:inherit">Encabezado</h4>' +
        '<p style="margin:4px 0 0;font-size:12px;opacity:.7">' + U.esc(t.lema || 'Texto de ejemplo') +
        '</p></div></div>';
    };

    ['#tPrim', '#tSec', '#tAcc', '#tBg', '#tFuente', '#tLogoTexto', '#tLogoAcento', '#tLema'].forEach((sel) =>
      U.$(sel, m.raiz).addEventListener('input', () => { leer(); preview(); })
    );
    U.$('#tFuente', m.raiz).addEventListener('change', () => { leer(); preview(); });

    U.$('#tLogo', m.raiz).addEventListener('change', function () {
      const archivo = this.files && this.files[0];
      if (!archivo) return;
      U.comprimirImagen(archivo, { ladoMaximoPx: 320, calidad: 0.85, pesoGuardadoMaximoKB: 250 })
        .then(function (res) {
          t.logo = res && res.dataUrl ? res.dataUrl : res;
          U.toast('Logo cargado.');
          preview();
        })
        .catch((err) => U.toast(err.message, 'error'));
    });

    preview();

    U.$('[data-cancelar]', m.raiz).onclick = m.cerrar;
    U.$('[data-guardar]', m.raiz).onclick = function () {
      leer();
      try {
        S.setTheme(empresaId, t, { superadmin: true });
      } catch (err) {
        return U.toast(err.message, 'error');
      }
      m.cerrar();
      U.toast('Tema actualizado.');
      refrescar();
    };
  }

  /* =================================================================
     HELPERS
     ================================================================= */
  function campo(id, etiqueta, valor, ayuda, tipo) {
    return (
      '<label class="campo"><span>' + U.esc(etiqueta) + '</span>' +
      '<input class="input" id="' + id + '" type="' + (tipo || 'text') + '" value="' +
      U.esc(valor || '') + '">' +
      (ayuda ? '<small class="mini tenue">' + U.esc(ayuda) + '</small>' : '') +
      '</label>'
    );
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

  /* =================================================================
     ARRANQUE
     ================================================================= */
  document.addEventListener('DOMContentLoaded', function () {
    S.sembrar();
    iniciarLogin();
    arrancar();
  });
})();
