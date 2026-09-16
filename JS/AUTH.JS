/* ==========================================================================
   NASCAR · auth.js
   Roles, permisos y sesión.

   ⚠️  MVP LOCAL. Esto NO es autenticación de producción: los PIN viajan al
   navegador dentro del código. Sirve para separar perfiles y poder
   demostrar y probar el sistema con cada rol.

   La estructura sí está pensada para migrar: cuando exista un backend,
   `getUsuarioActual()` pasará a leer la sesión del servidor y `puede()`
   consultará los permisos que este devuelva. Las pantallas no cambian,
   porque nunca preguntan por el rol directamente: preguntan por permisos.
   ========================================================================== */

window.NASCAR = window.NASCAR || {};

NASCAR.Auth = (function () {
  'use strict';

  const S = NASCAR.Store;

  /* =================================================================
     CATÁLOGO DE PERMISOS
     Una única definición. Ningún archivo debe inventar permisos sueltos.
     ================================================================= */
  const PERMISOS = {
    // Operación
    pedidos_ver: 'Ver el tablero de pedidos',
    pedidos_gestionar: 'Cambiar el estado de cualquier pedido',
    pedidos_cocina: 'Trabajar los pedidos en cocina',
    pedidos_domicilio: 'Entregar domicilios',
    pedidos_mesa: 'Tomar pedidos de mesa',
    pedidos_listos: 'Ver y entregar los pedidos listos',
    pedidos_cancelar: 'Cancelar pedidos',

    /* Anular una factura NO es cancelar un pedido:
         · Cancelar -> el pedido no llegó a cumplirse (pedidos_cancelar)
         · Anular   -> la venta se hizo y se echa atrás, con motivo y
                       devolviendo al inventario lo que consumió
       Por eso va en su propio permiso y no cuelga de pedidos_cancelar:
       el Administrador cancela, pero no anula. */
    pedidos_anular: 'Anular facturas ya vendidas, con retorno de inventario',

    // Cierre de inventario.
    // Se reparte en tres porque son cosas distintas: contar el inventario
    // lo hace quien está en el piso, mientras que ver el cruce con las
    // ventas y dar un cierre por revisado es trabajo de administración.
    cierres_registrar: 'Registrar el inventario del cierre',
    cierres: 'Consultar los cierres y el cruce',
    cierres_revisar: 'Dar un cierre por revisado',

    // Entradas de mercancía (el campo EN del cruce). Van aparte de los
    // cierres porque quien recibe la mercancía no tiene por qué ver el
    // cruce con las ventas ni dar cierres por revisados.
    entradas: 'Registrar y consultar entradas de mercancía',

    // Gastos (salidas de dinero).
    // Separados igual que el cierre: quien paga registra, y la revisión
    // del gasto la hace administración. Si quieres que caja confirme sus
    // propios gastos, basta con añadir 'gastos_confirmar' a su rol.
    gastos: 'Registrar y consultar gastos',
    gastos_confirmar: 'Confirmar gastos',
    gastos_anular: 'Anular gastos',

    /* Cruce de información — el informe de caja de la jornada.
       Ver el informe y registrar la base son dos cosas distintas: se
       puede querer que alguien consulte cómo va el día sin poder tocar
       el dinero con el que se abre el cajón. */
    informe: 'Ver el cruce de información y la caja del día',
    base_caja: 'Registrar la base de caja de la jornada',

    // Administración del negocio
    pagos: 'Confirmar y rechazar pagos',
    menu: 'Publicar el menú del día',
    carta: 'Administrar la carta y las categorías',
    stock: 'Administrar el stock',
    ventas: 'Ver los reportes de ventas',
    ajustes: 'Respaldos y enlaces de mesa',

    // Configuración sensible — sólo el rol admin
    usuarios: 'Crear y editar usuarios',
    config_local: 'Cambiar los datos del restaurante',
    config_sucursales: 'Configurar las unidades / locales',
    config_pagos: 'Configurar los métodos de pago',

    // Plataforma — por encima de cualquier empresa
    plataforma: 'Administrar la plataforma y sus empresas',
  };

  /* Permisos que el comodín '*' NO concede.

     Esto es lo que separa al dueño de un restaurante del dueño del
     sistema. El rol `admin` tiene '*' y manda en TODO lo suyo, pero
     administrar la plataforma —crear empresas, encender módulos, entrar
     a la empresa de al lado— no es suyo. Hay que tenerlo escrito con
     nombre y apellido, y sólo `superadmin` lo tiene.

     Si esto no existiera, bastaría con ser admin de cualquier empresa
     para gobernar las demás. */
  const PERMISOS_PLATAFORMA = ['plataforma'];

  /* =================================================================
     QUÉ MÓDULO NECESITA CADA PERMISO

     El rol dice qué puede hacer una persona; el módulo dice qué compró
     la empresa. Son dos preguntas distintas y las dos tienen que dar
     que sí.

     Lo que no esté en esta lista pertenece al módulo Básico, que es el
     sistema mismo y siempre está encendido. Un arreglo se lee como
     "cualquiera de estos".
     ================================================================= */
  const MODULO_DE_PERMISO = {
    /* La plataforma está por encima de las empresas: no depende de que
       ninguna haya contratado nada. `null` = sin módulo asociado. */
    plataforma: null,
    /* El cruce vive de ventas y gastos, que son del módulo Básico: lo
       tiene toda empresa. Del Cierre sólo ofrece un enlace, y ese enlace
       se comprueba aparte. */
    informe: 'basico',
    base_caja: 'basico',
    pedidos_anular: 'basico',
    stock: 'stock',
    entradas: ['stock', 'cierre'], // alimentan el stock y la columna EN del cruce
    cierres_registrar: 'cierre',
    cierres: 'cierre',
    cierres_revisar: 'cierre',
  };

  function moduloDePermiso(permiso) {
    return Object.prototype.hasOwnProperty.call(MODULO_DE_PERMISO, permiso)
      ? MODULO_DE_PERMISO[permiso]
      : 'basico';
  }

  /**
   * hasModule('basico') | hasModule('stock') | hasModule('cierre')
   *
   * Reenvía a store.hasModule: la lógica vive en un solo sitio. Se
   * expone también aquí porque las pantallas ya hablan con Auth para
   * preguntar qué se puede mostrar, y así no tienen que conocer dos
   * objetos distintos.
   */
  function hasModule(modulo) {
    return S.hasModule(modulo);
  }

  /* =================================================================
     ROLES
     '*' significa todos los permisos.
     ================================================================= */
  const ROLES = {
    /* Rol GLOBAL: no pertenece a ninguna empresa. Es el administrador
       de la plataforma, no de un restaurante.

       Lleva 'plataforma' escrito aparte porque el comodín '*' no lo
       concede: ver PERMISOS_PLATAFORMA. */
    superadmin: {
      nombre: 'SuperAdmin',
      descripcion: 'Administra la plataforma Taseca: empresas, módulos y accesos.',
      icono: '🛠️',
      /* NIVEL 1. No es un rol del restaurante: no se ofrece al crear
         usuarios de una empresa ni aparece en su tabla de roles. */
      scope: 'platform',
      permisos: ['*', 'plataforma'],
    },
    admin: {
      scope: 'empresa',
      nombre: 'Admin',
      descripcion: 'Control total del sistema y su configuración.',
      icono: '👑',
      permisos: ['*'],
    },
    administrador: {
      scope: 'empresa',
      nombre: 'Administrador',
      descripcion: 'Opera el restaurante completo, sin tocar la configuración sensible.',
      icono: '📋',
      permisos: [
        'pedidos_ver', 'pedidos_gestionar', 'pedidos_cancelar',
        'pagos', 'menu', 'carta', 'stock', 'ventas', 'ajustes',
        'cierres_registrar', 'cierres', 'cierres_revisar', 'entradas',
        'gastos', 'gastos_confirmar', 'gastos_anular',
        'informe', 'base_caja',
      ],
    },
    caja: {
      scope: 'empresa',
      nombre: 'Caja',
      descripcion: 'Maneja el dinero del punto: confirma pagos, registra gastos y recibe mercancía.',
      icono: '💵',
      /* Rol operativo de dinero. Puede mover plata y mercancía, pero no
         configura nada del negocio: ni carta, ni precios, ni stock
         maestro, ni usuarios, ni métodos de pago. Tampoco ve el cruce
         de inventario ni puede tocar cierres. */
      /* Caja abre el cajón con la base y ve el cruce del día: es quien
         maneja el dinero del punto, así que necesita las dos cosas. */
      permisos: ['pagos', 'gastos', 'gastos_confirmar', 'entradas', 'informe', 'base_caja'],
    },
    mesero: {
      scope: 'empresa',
      nombre: 'Mesero',
      descripcion:
        'Toma pedidos de mesa, lleva los que están listos y registra el cierre de inventario.',
      icono: '🍽️',
      // Registra el cierre, pero no ve el cruce con las ventas ni puede
      // darlo por revisado: eso lo hace administración.
      permisos: ['pedidos_mesa', 'pedidos_listos', 'cierres_registrar'],
    },
    cocinero: {
      scope: 'empresa',
      nombre: 'Cocinero',
      descripcion: 'Prepara los pedidos y marca cuándo están listos.',
      icono: '👨‍🍳',
      permisos: ['pedidos_cocina'],
    },
    domiciliario: {
      scope: 'empresa',
      nombre: 'Domiciliario',
      descripcion: 'Ve los pedidos listos para entregar y los cierra.',
      icono: '🛵',
      permisos: ['pedidos_domicilio'],
    },
  };

  /* =================================================================
     SESIÓN
     ================================================================= */
  function getUsuarioActual() {
    return S.getSesion();
  }

  function rolActual() {
    const u = getUsuarioActual();
    return u ? u.rol : null;
  }

  function definicionRol(rol) {
    return ROLES[rol] || null;
  }

  function nombreRol(rol) {
    const d = ROLES[rol];
    return d ? d.nombre : rol || '—';
  }

  function iconoRol(rol) {
    const d = ROLES[rol];
    return d ? d.icono : '👤';
  }

  /* La sucursal a la que está atado el usuario, si tiene una.
     null = puede ver todas. */
  function sucursalDelUsuario() {
    const u = getUsuarioActual();
    return u && u.sucursalId ? Number(u.sucursalId) : null;
  }

  /* =================================================================
     PERMISOS
     ================================================================= */
  /**
   * ¿Se puede hacer esto?
   *
   * Se comprueba el MÓDULO antes que el rol, y a propósito: si la
   * empresa no contrató el módulo, la respuesta es no para todo el
   * mundo, admin incluido. No es una restricción de perfil, es que esa
   * parte del sistema no existe para esta empresa.
   *
   * Como todo el panel pregunta por aquí — botones, pestañas y las
   * propias acciones a través de exigir() — con esta única línea el
   * módulo apagado desaparece de todas partes, sin repetir la
   * comprobación en cada pantalla.
   */
  function puede(permiso, usuario) {
    /* Conectado a la base de datos (fase 1), las secciones que siguen en
       localStorage no se ofrecen: ver js/remoto.js. */
    if (NASCAR.Remoto && !NASCAR.Remoto.permisoDisponible(permiso)) return false;
    if (!hasModule(moduloDePermiso(permiso))) return false;
    const u = usuario || getUsuarioActual();
    if (!u) return false;
    const def = ROLES[u.rol];
    if (!def) return false;

    // Concedido con nombre y apellido
    if (def.permisos.indexOf(permiso) >= 0) return true;

    /* El comodín cubre todo lo del restaurante, pero no lo de la
       plataforma: eso hay que tenerlo declarado. */
    if (def.permisos.indexOf('*') >= 0) return PERMISOS_PLATAFORMA.indexOf(permiso) < 0;

    return false;
  }

  /* ¿Quien está conectado administra la plataforma? */
  function esSuperAdmin(usuario) {
    const u = usuario || getUsuarioActual();
    return !!u && u.rol === 'superadmin';
  }

  /**
   * ¿La sesión es del NIVEL PLATAFORMA?
   *
   * Ésta es la comprobación que guardan las páginas de Taseca. Mira el
   * `scope` de la sesión y, por si viniera de una versión anterior, el
   * scope declarado en el rol. Un usuario de empresa —admin incluido—
   * da false.
   */
  function esPlataforma(usuario) {
    const u = usuario || getUsuarioActual();
    if (!u) return false;
    if (u.scope) return u.scope === 'platform';
    const def = ROLES[u.rol];
    return !!def && def.scope === 'platform';
  }

  /* Los roles que se pueden asignar DENTRO de una empresa. Deja fuera a
     los de plataforma: no existe "NASCAR → SuperAdmin". */
  function rolesDeEmpresa() {
    return Object.keys(ROLES).filter((k) => ROLES[k].scope !== 'platform');
  }

  /* Cualquiera de los permisos de la lista. */
  function puedeAlguno(permisos, usuario) {
    return (permisos || []).some((p) => puede(p, usuario));
  }

  /**
   * Barrera para las funciones que hacen algo, no sólo para los botones.
   * Ocultar un botón no basta: la acción también tiene que negarse.
   * Devuelve true si puede; si no, avisa y devuelve false.
   */
  function exigir(permiso, opciones) {
    if (puede(permiso)) return true;
    const silencio = opciones && opciones.silencioso;
    if (!silencio && NASCAR.UI) {
      NASCAR.UI.toast(motivoDelBloqueo(permiso), 'error');
    }
    return false;
  }

  /* Por qué se negó: no es lo mismo "tú no puedes" que "esto no está
     contratado". Decirlo mal manda a la gente a pedir permisos que no
     resolverían nada. */
  function motivoDelBloqueo(permiso) {
    const modulo = moduloDePermiso(permiso);
    if (!hasModule(modulo)) {
      const def = S.definicionModulo(Array.isArray(modulo) ? modulo[0] : modulo);
      return (
        'El módulo ' + (def ? def.nombre : modulo) +
        ' no está habilitado para esta empresa.'
      );
    }
    return 'Tu perfil (' + nombreRol(rolActual()) + ') no tiene permiso para esta acción.';
  }

  /**
   * Barrera de módulo para lo que NO cuelga de un permiso: páginas
   * sueltas, rutas por URL y botones que cruzan de un módulo a otro.
   * Devuelve true si el módulo está; si no, avisa y devuelve false.
   */
  function exigirModulo(modulo, opciones) {
    if (hasModule(modulo)) return true;
    const silencio = opciones && opciones.silencioso;
    if (!silencio && NASCAR.UI) {
      const def = S.definicionModulo(Array.isArray(modulo) ? modulo[0] : modulo);
      NASCAR.UI.toast(
        'El módulo ' + (def ? def.nombre : modulo) + ' no está habilitado para esta empresa.',
        'error'
      );
    }
    return false;
  }

  /* =================================================================
     TRANSICIONES DE ESTADO POR ROL

     Cada rol sólo puede mover los pedidos por el tramo que le toca.
     El flujo completo lo define store.flujoEstados(tipo).
     ================================================================= */
  const TRANSICIONES = {
    superadmin: null, // null = todas
    admin: null,
    administrador: null,
    cocinero: [
      ['nuevo', 'preparacion'],
      ['preparacion', 'listo'],
    ],
    mesero: [
      ['nuevo', 'preparacion'],
      ['listo', 'entregado'], // lleva el plato a la mesa
    ],
    domiciliario: [
      ['listo', 'camino'],
      ['camino', 'entregado'],
    ],
  };

  function puedeTransicion(pedido, destino, usuario) {
    const u = usuario || getUsuarioActual();
    if (!u) return false;

    // El destino tiene que ser válido para el tipo de pedido
    const flujo = S.flujoEstados(pedido.tipo);
    if (flujo.indexOf(destino) < 0) return false;

    const permitidas = TRANSICIONES[u.rol];
    if (permitidas === null) return true; // admin y administrador
    if (!permitidas) return false;

    // El mesero sólo cierra pedidos de mesa; el domiciliario sólo domicilios
    if (u.rol === 'mesero' && pedido.tipo !== 'mesa') return false;
    if (u.rol === 'domiciliario' && pedido.tipo !== 'domicilio') return false;

    return permitidas.some((t) => t[0] === pedido.estado && t[1] === destino);
  }

  /* =================================================================
     SECCIONES DEL PANEL VISIBLES SEGÚN EL ROL

     Cada pestaña declara qué permiso necesita. El panel se arma con
     esto, así que agregar una sección nueva es agregar una línea aquí.
     ================================================================= */
  const SECCIONES = [
    { tab: 'mesero', permiso: 'pedidos_mesa', exclusiva: true },
    { tab: 'cierre', permiso: 'cierres_registrar' },
    { tab: 'cocina', permiso: 'pedidos_cocina', exclusiva: true },
    { tab: 'entregas', permiso: 'pedidos_domicilio', exclusiva: true },
    { tab: 'pedidos', permiso: 'pedidos_ver' },
    { tab: 'pagos', permiso: 'pagos' },
    { tab: 'dia', permiso: 'menu' },
    { tab: 'carta', permiso: 'carta' },
    { tab: 'stock', permiso: 'stock' },
    { tab: 'inventario', permiso: 'cierres' },
    { tab: 'entradas', permiso: 'entradas' },
    { tab: 'gastos', permiso: 'gastos' },
    { tab: 'informe', permiso: 'informe' },
    { tab: 'ventas', permiso: 'ventas' },
    { tab: 'unidades', permiso: 'config_sucursales' }, // mismo permiso que ya tenía la sección de sucursales
    { tab: 'usuarios', permiso: 'usuarios' },
    { tab: 'config', permiso: 'config_local' },
    { tab: 'ajustes', permiso: 'ajustes' },
  ];

  /* Una pestaña se ve si el ROL la permite Y el MÓDULO está habilitado
     para la empresa. Así una empresa puede contratar sólo una parte del
     sistema sin que haga falta tocar los roles. */
  function moduloDisponible(tab) {
    const mapa = NASCAR.MODULO_DE_TAB || {};
    return hasModule(mapa[tab]); // sin módulo asociado -> siempre disponible
  }

  function seccionesVisibles(usuario) {
    return SECCIONES.filter(
      (s) => puede(s.permiso, usuario) && moduloDisponible(s.tab)
    ).map((s) => s.tab);
  }

  /* Pestaña con la que arranca cada rol al entrar: la que más usa. */
  const TAB_INICIAL = {
    superadmin: 'pedidos',
    admin: 'pedidos',
    administrador: 'pedidos',
    mesero: 'mesero',
    cocinero: 'cocina',
    domiciliario: 'entregas',
    caja: 'pagos',
  };

  function seccionInicial(usuario) {
    const visibles = seccionesVisibles(usuario);
    if (!visibles.length) return null;
    const u = usuario || getUsuarioActual();
    const preferida = u ? TAB_INICIAL[u.rol] : null;
    return preferida && visibles.indexOf(preferida) >= 0 ? preferida : visibles[0];
  }

  /* =================================================================
     LOGIN / LOGOUT
     ================================================================= */
  function entrar(usuarioAcceso, pin) {
    return S.login(usuarioAcceso, pin);
  }

  function salir() {
    S.logout();
  }

  /* Datos para guardar en los registros: quién hizo qué, y en qué empresa. */
  /* Datos para guardar en los registros: quién hizo qué, en qué empresa
     y desde qué nivel. El `empresaId` es el de la empresa a la que
     pertenece el REGISTRO; el `scope` dice si quien lo hizo era de la
     empresa o de la plataforma administrándola. */
  function firma() {
    const u = getUsuarioActual();
    const e = S.getEmpresaActual();
    return {
      usuarioId: u ? u.usuarioId : null,
      usuarioNombre: u ? u.nombre : 'Sistema',
      rol: u ? u.rol : null,
      scope: u ? u.scope || (ROLES[u.rol] && ROLES[u.rol].scope) || 'empresa' : null,
      empresaId: e ? e.id : null,
    };
  }

  function empresaActual() {
    return S.getEmpresaActual();
  }

  return {
    PERMISOS: PERMISOS,
    ROLES: ROLES,
    SECCIONES: SECCIONES,

    getUsuarioActual: getUsuarioActual,
    rolActual: rolActual,
    definicionRol: definicionRol,
    nombreRol: nombreRol,
    iconoRol: iconoRol,
    sucursalDelUsuario: sucursalDelUsuario,

    puede: puede,
    puedeAlguno: puedeAlguno,
    esSuperAdmin: esSuperAdmin,
    esPlataforma: esPlataforma,
    rolesDeEmpresa: rolesDeEmpresa,
    exigir: exigir,
    puedeTransicion: puedeTransicion,

    seccionesVisibles: seccionesVisibles,
    seccionInicial: seccionInicial,

    entrar: entrar,
    salir: salir,
    firma: firma,
    empresaActual: empresaActual,
    moduloDisponible: moduloDisponible,
    hasModule: hasModule,
    exigirModulo: exigirModulo,
    moduloDePermiso: moduloDePermiso,
  };
})();
