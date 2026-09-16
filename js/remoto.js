/* ==========================================================================
   NASCAR · remoto.js
   Conexión con la base de datos PostgreSQL a través de PostgREST.
   Fase 1: pedidos, cocina, pagos. Fase 2 · bloque 1: carta y menú del día.

   CÓMO FUNCIONA
     La aplicación entera habla con NASCAR.Store y espera respuestas
     inmediatas. Este archivo no cambia eso: al cargar la página trae de
     PostgREST lo que la fase 1 necesita, lo deja en la MEMORIA del Store
     con la misma forma que siempre tuvo, y reemplaza las operaciones de
     pedidos por llamadas a la base.

       lectura    → datos ya cargados en memoria (se refrescan solos)
       escritura  → POST /rpc/... ; la base valida, guarda y responde

     Lo que viene del servidor NUNCA se escribe en localStorage: los datos
     del modo local de este navegador quedan intactos.

   PUENTE DE LA FASE 1
     Las escrituras usan XMLHttpRequest síncrono para que las pantallas no
     tengan que cambiar. Contra un servidor local es instantáneo; en la fase
     2 las pantallas pasan a asíncrono y esto desaparece.

   MODO
     · Por defecto se usa la base si la página se sirve por http(s).
     · Abierto como archivo (nascar-movil.html) siempre es local.
     · ?backend=local  fuerza el modo local  ·  ?backend=postgrest  la base
   ========================================================================== */

window.NASCAR = window.NASCAR || {};

NASCAR.BACKEND = Object.assign(
  {
    modo: 'postgrest',
    // Mismo equipo que sirve la página: funciona igual desde el celular por Wi-Fi.
    // js/backend.js lo cambia cuando la página se sirve desde internet.
    url: location.protocol + '//' + (location.hostname || 'localhost') + ':3000',
    apikey: '',    // sólo Supabase (clave pública del proyecto)
    esquema: '',   // sólo Supabase: el esquema que se consulta ("rest")
    /* De qué empresa es esta visita. La resuelve js/backend.js (subdominio
       o ?empresa=). Ninguna empresa está escrita a la fuerza aquí. */
    empresa: '',
    refrescoPedidosMs: 8000,     // sólo trae lo que cambió (ver refrescarPedidos)
    refrescoCatalogoMs: 300000,  // carta y menú: cada 5 minutos
  },
  NASCAR.BACKEND || {}
);

NASCAR.Remoto = (function () {
  'use strict';

  const S = NASCAR.Store;
  const CFG = NASCAR.BACKEND;

  const parametro = new URLSearchParams(location.search).get('backend');
  const activo =
    location.protocol !== 'file:' &&
    (parametro ? parametro === 'postgrest' : CFG.modo === 'postgrest');

  /* Secciones que en la fase 1 siguen en localStorage y dependen de datos
     que ahora vienen de la base (ids de unidades, carta…): mezclarlas
     daría resultados falsos, así que en modo base de datos no se muestran. */
  // Fase 2 completa: ya no queda ninguna sección fuera de la base de datos
  const PERMISOS_FASE_2 = [];

  const CLAVES = [
    'sucursales', 'unidadActiva', 'categorias', 'cartaV2', 'menusDia', 'dia', 'pedidos', 'usuarios',
    'stock', 'cierres', 'entradas', 'gastos', 'bases', 'empresas', 'config', 'empresaActual',
  ];

  const PAGINA_PLATAFORMA = /taseca-admin/i.test(location.pathname);

  /* Qué empresa se carga: la que administra el SuperAdmin, la del usuario
     conectado, la de la dirección (?empresa=…) o la de la instalación. */
  function codigoEmpresa() {
    const s = S.getSesion();
    // El panel de Taseca siempre abre fuera de cualquier empresa (ver taseca-admin.js)
    if (s && s.scope === 'platform' && s.empresaContext && !PAGINA_PLATAFORMA) return s.empresaContext;
    if (s && s.scope !== 'platform' && s.empresaId) return s.empresaId;
    /* Sin respaldo a propósito: si la dirección no dice de qué empresa es,
       la página lo pide. js/backend.js ya aplica la empresa instalada
       cuando se trabaja desde el equipo del negocio. */
    return new URLSearchParams(location.search).get('empresa') || CFG.empresa || '';
  }

  let empresa = null; // { empresa_id, codigo, ... }
  let caido = false;
  const comprobantesPendientes = {}; // pedidoId -> { dataUrl, nombreArchivo }
  const seguidos = {};               // código -> true (seguimiento sin sesión)

  /* =====================================================================
     HTTP
     ===================================================================== */
  function token() {
    const s = S.getSesion();
    return s && s.token ? s.token : null;
  }

  function mensajeDeError(xhr) {
    if (xhr.status === 0) return 'No hay conexión con la base de datos. ¿Está encendido PostgREST?';
    if (xhr.status === 401) {
      S.establecerSesion(null);
      return 'Tu sesión venció. Vuelve a entrar.';
    }
    try {
      const e = JSON.parse(xhr.responseText);
      return e.message || e.hint || 'La base de datos rechazó la operación.';
    } catch (err) {
      return 'La base de datos respondió con un error (' + xhr.status + ').';
    }
  }

  /* Cabeceras que necesita el servidor, además del token de la sesión:

       apikey   → sólo el Data API de Supabase, que lo exige en su portería.
                  Es una clave PÚBLICA, pensada para ir en el navegador: no
                  da acceso por sí sola, los permisos siguen saliendo del
                  token y de los roles de la base.
       Profile  → el esquema que se consulta ("rest"). PostgREST propio ya
                  publica sólo ese esquema; Supabase publica varios y hay
                  que decírselo en cada petición. */
  function cabeceras(metodo) {
    const h = { Accept: 'application/json' };
    if (CFG.apikey) h.apikey = CFG.apikey;
    if (CFG.esquema) {
      h[metodo === 'GET' ? 'Accept-Profile' : 'Content-Profile'] = CFG.esquema;
    }
    return h;
  }

  /* Petición síncrona (ver PUENTE DE LA FASE 1 arriba). */
  function pedir(metodo, ruta, cuerpo, conSesion) {
    const x = new XMLHttpRequest();
    x.open(metodo, CFG.url + ruta, false);
    const h = cabeceras(metodo);
    Object.keys(h).forEach((k) => x.setRequestHeader(k, h[k]));
    if (cuerpo !== undefined) x.setRequestHeader('Content-Type', 'application/json');
    const t = conSesion === false ? null : token();
    if (t) x.setRequestHeader('Authorization', 'Bearer ' + t);
    try {
      x.send(cuerpo === undefined ? null : JSON.stringify(cuerpo));
    } catch (e) {
      throw new Error('No hay conexión con la base de datos. ¿Está encendido PostgREST?');
    }
    if (x.status < 200 || x.status >= 300) throw new Error(mensajeDeError(x));
    return x.responseText ? JSON.parse(x.responseText) : null;
  }

  const obtener = (ruta, conSesion) => pedir('GET', ruta, undefined, conSesion);
  const rpc = (fn, params, conSesion) => pedir('POST', '/rpc/' + fn, params || {}, conSesion);

  /* Petición asíncrona para los refrescos en segundo plano. */
  function obtenerAsync(ruta) {
    const h = cabeceras('GET');
    const t = token();
    if (t) h.Authorization = 'Bearer ' + t;
    return fetch(CFG.url + ruta, { headers: h }).then(function (r) {
      if (r.status === 401) {
        S.establecerSesion(null);
        throw new Error('sesión vencida');
      }
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    });
  }

  /* =====================================================================
     DE LA BASE A LA FORMA QUE USA LA APLICACIÓN
     Los ids llevan prefijo (p12, c3, m5, d8…) para que nunca se confundan
     con los del modo local.
     ===================================================================== */
  const n = (v) => (v === null || v === undefined ? 0 : Number(v));

  function aUnidad(u) {
    return {
      id: u.unidad_id,
      empresaId: u.empresa_codigo,
      nombre: u.nombre,
      corto: u.nombre_corto,
      direccion: u.direccion || '',
      ciudad: u.ciudad || '',
      telefono: u.telefono || '',
      whatsapp: u.whatsapp || '',
      horario: u.horario || '',
      mapa: u.mapa_url || '',
      mesas: n(u.mesas),
      tipoNegocio: u.tipo_negocio,
      color: u.color || 'azul',
      zonas: (u.zonas || []).map((z) => ({ id: z.zona_id, nombre: z.nombre, costo: n(z.costo), min: n(z.pedido_minimo) })),
      activa: u.activa,
      branding: {
        logo: (logos[u.unidad_id] && logos[u.unidad_id].imagen) || u.logo_url || '',
        color: u.color_marca || '',
      },
      creado: u.creado_en,
    };
  }

  /* Usuarios: sin PIN (la base lo guarda cifrado y nunca lo devuelve).
     La aplicación maneja UNA unidad asignada; en la base pueden ser varias. */
  function aUsuario(u) {
    const unidades = u.unidades || [];
    return {
      id: u.usuario_id,
      empresaId: empresa.codigo,
      nombre: u.nombre,
      usuario: u.usuario,
      pin: '',
      rol: u.rol,
      sucursalId: unidades.length === 1 ? unidades[0] : null,
      unidades: unidades,
      activo: u.activo,
      scope: 'empresa',
    };
  }

  function aCategoria(c) {
    return {
      id: 'c' + c.categoria_id,
      empresaId: empresa.codigo,
      nombre: c.nombre,
      icono: c.icono || '🍽️',
      orden: n(c.orden),
      activa: c.activa,
      sucursales: c.unidades || [],
    };
  }

  function aProducto(p) {
    const unidades = p.unidades || [];
    return {
      id: 'p' + p.producto_id,
      empresaId: empresa.codigo,
      codigo: p.codigo,
      cat: 'c' + p.categoria_id,
      nombre: p.nombre,
      desc: p.descripcion || '',
      precio: n(p.precio),
      tag: p.etiqueta || '',
      orden: n(p.orden),
      activo: p.activo,
      agotado: unidades.some((u) => u.agotado),
      sucursales: unidades.map((u) => u.unidad_id),
      imagen: p.imagen_url || '',
    };
  }

  function aMenu(m) {
    return {
      id: 'm' + m.menu_dia_id,
      empresaId: empresa.codigo,
      sucursalId: m.unidad_id,
      fecha: m.fecha,
      tipo: m.tipo,
      armado: {
        nombre: m.nombre || 'Menú del día',
        descripcion: m.descripcion || '',
        precio: n(m.precio),
        disponible: m.disponible,
        vendidos: 0,
        categorias: (m.categorias || []).map((c) => ({
          id: 'mc' + c.categoria_id,
          nombre: c.nombre,
          icono: c.icono || '',
          orden: n(c.orden),
          obligatoria: c.obligatoria,
          maxSeleccion: n(c.max_seleccion) || 1,
          activa: c.activa,
          opciones: (c.opciones || []).map((o) => ({ id: 'mo' + o.opcion_id, nombre: o.nombre, activa: o.activa, orden: n(o.orden) })),
        })),
      },
      publico: { titulo: m.titulo_fecha || '', mensaje: m.mensaje_fecha || '' },
    };
  }

  function aPlatos(m) {
    return (m.platos || []).map((p) => ({
      id: 'd' + p.plato_dia_id,
      empresaId: empresa.codigo,
      sucursalId: m.unidad_id,
      fecha: m.fecha,
      nombre: p.nombre,
      desc: p.descripcion || '',
      emoji: p.emoji || '',
      precio: n(p.precio),
      cupos: p.cupos === null ? null : n(p.cupos),
      vendidos: n(p.vendidos),
      disponible: p.disponible,
      orden: n(p.orden),
      sopa: p.sopa || '',
      principio: p.principio || '',
      proteina: p.proteina || '',
      bebida: p.bebida || '',
    }));
  }

  /* El texto de la unidad es, en la app, un "menú" con fecha '*'. */
  function aTextoUnidad(t) {
    return {
      id: 'mt' + t.unidad_id,
      empresaId: empresa.codigo,
      sucursalId: t.unidad_id,
      fecha: '*',
      tipo: 'texto',
      publico: { titulo: t.titulo || '', mensaje: t.mensaje || '' },
    };
  }

  function refDeItem(i) {
    if (i.origen === 'carta') return 'p' + i.producto_id;
    if (i.origen === 'chef') return 'd' + i.plato_dia_id;
    return 'armado:m' + i.menu_dia_id + ':' + (i.opciones || []).map((o) => 'mo' + o).sort().join('.');
  }

  function fechaLocal(ts) {
    const d = new Date(ts);
    return isNaN(d) ? ts : S.aISO(d);
  }

  function aPedido(p) {
    if (!p) return null;
    return {
      id: 'o' + p.pedido_id,
      idBase: p.pedido_id,
      empresaId: p.empresa_codigo,
      codigo: p.codigo,
      tipo: p.tipo,
      sucursalId: p.unidad_id,
      sucursalNombre: p.unidad,
      mesa: p.mesa,
      usuarioId: p.tomado_por_id || null,
      usuarioNombre: p.tomado_por || null,
      cliente: {
        nombre: p.cliente || '',
        telefono: p.cliente_telefono || '',
        direccion: p.direccion_entrega || '',
        zona: p.zona || '',
        notas: p.indicaciones || '',
        pagaCon: p.paga_con === null || p.paga_con === undefined ? '' : n(p.paga_con),
      },
      items: (p.items || []).map((i) => ({
        refId: refDeItem(i),
        nombre: i.nombre,
        precio: n(i.precio_unitario),
        cantidad: n(i.cantidad),
        notas: i.notas || '',
        origen: i.origen === 'chef' ? 'dia' : i.origen,
        detalle: i.detalle || undefined,
      })),
      subtotal: n(p.subtotal),
      domicilio: n(p.costo_domicilio),
      total: n(p.total),
      metodoPago: p.metodo_pago,
      estadoPago: p.estado_pago,
      comprobante: p.referencia_pago || '',
      tieneComprobante: !!p.tiene_comprobante,
      estado: p.estado,
      motivoCancelacion: p.motivo_cancelacion || '',
      fecha: fechaLocal(p.creado_en),
      fechaOperativa: p.fecha_operativa,
      creado: p.creado_en,
      actualizado: p.actualizado_en,
      historial: (p.historial || []).map((h) => ({ ts: h.ts, texto: h.texto })),
      anulacion: p.anulacion
        ? {
            motivo: p.anulacion.motivo,
            jornadaOriginal: p.anulacion.jornada_original,
            jornadaRetorno: p.anulacion.jornada_retorno,
            diferido: p.anulacion.diferido,
            ts: p.anulacion.creado_en,
          }
        : undefined,
    };
  }

  /* De la aplicación a la base: el ítem del carrito a la línea del pedido. */
  function aLineaBase(it) {
    const ref = String(it.refId || '');
    const linea = { cantidad: Number(it.cantidad) || 1 };
    if (it.notas) linea.notas = it.notas;

    if (it.origen === 'armado' || ref.indexOf('armado:') === 0) {
      const partes = ref.split(':'); // armado:m12:mo3.mo7
      linea.menu_dia_id = Number(String(partes[1]).replace(/^m/, ''));
      linea.opciones = (partes[2] || '').split('.').filter(Boolean).map((o) => Number(o.replace(/^mo/, '')));
    } else if (it.origen === 'dia' || /^d\d+$/.test(ref)) {
      linea.plato_dia_id = Number(ref.slice(1));
    } else if (/^p\d+$/.test(ref)) {
      linea.producto_id = Number(ref.slice(1));
    } else {
      throw new Error('"' + it.nombre + '" es de la carta local de este navegador y no existe en la base de datos. Vacía el pedido y vuelve a agregarlo.');
    }
    return linea;
  }

  /* =====================================================================
     CARGA Y REFRESCO
     ===================================================================== */
  /* Los logos pesan (hasta ~150 KB): no vienen en /unidades. Se piden
     aparte, y sólo los que cambiaron desde la última vez (logo_version). */
  const logos = {}; // unidad_id -> { version, imagen }

  function cargarLogos(unidades) {
    unidades.forEach(function (u) {
      if (!u.logo_version) delete logos[u.unidad_id];
    });
    const faltan = unidades
      .filter((u) => u.logo_version && (!logos[u.unidad_id] || logos[u.unidad_id].version !== u.logo_version))
      .map((u) => u.unidad_id);
    if (!faltan.length) return;
    obtener('/logos_unidad?unidad_id=in.(' + faltan.join(',') + ')', false).forEach(function (l) {
      logos[l.unidad_id] = { version: l.logo_version, imagen: l.imagen };
    });
  }

  /* =====================================================================
     LA EMPRESA (fase 2 · bloque 5): ficha, módulos, tema y configuración
     vienen de la base. El logo y el ícono, aparte y sólo si cambiaron.
     ===================================================================== */
  const imagenesEmpresa = {}; // empresa_id -> { version, logo, favicon }

  function cargarImagenesEmpresa(filas) {
    const faltan = filas
      .filter((e) => e.imagenes_version && (!imagenesEmpresa[e.empresa_id] || imagenesEmpresa[e.empresa_id].version !== e.imagenes_version))
      .map((e) => e.empresa_id);
    filas.forEach((e) => { if (!e.imagenes_version) delete imagenesEmpresa[e.empresa_id]; });
    if (!faltan.length) return;
    obtener('/empresa_imagenes?empresa_id=in.(' + faltan.join(',') + ')', false).forEach(function (i) {
      imagenesEmpresa[i.empresa_id] = { version: i.imagenes_version, logo: i.logo || '', favicon: i.favicon || '' };
    });
  }

  function aEmpresa(e) {
    const img = imagenesEmpresa[e.empresa_id] || {};
    return {
      id: e.codigo,
      idBase: e.empresa_id,
      nombre: e.nombre_comercial,
      razonSocial: e.razon_social || '',
      nit: e.nit || '',
      telefono: e.telefono || '',
      whatsapp: e.whatsapp || '',
      email: e.email || '',
      activa: e.estado ? e.estado === 'activa' : true,
      creada: e.creado_en,
      plantilla: e.plantilla || '',
      modulos: e.modulos || {},
      theme: {
        logo: img.logo || '',
        favicon: img.favicon || '',
        logoTexto: e.logo_texto || '',
        logoAcento: e.logo_acento || '',
        primary: e.color_primario || '',
        secondary: e.color_secundario || '',
        accent: e.color_acento || '',
        background: e.color_fondo || '',
        fontFamily: e.tipografia || '',
        iniciales: e.iniciales || '',
        lema: e.lema || '',
      },
      unidades: n(e.n_unidades),
      usuarios: n(e.n_usuarios),
    };
  }

  function aConfig(e) {
    const cuentas = e.cuentas || [];
    const cuenta = (entidad) => cuentas.find((c) => String(c.entidad).toLowerCase() === entidad);
    const numero = (entidad) => (cuenta(entidad) ? cuenta(entidad).numero : '');
    return {
      marca: e.nombre_comercial,
      eslogan: e.eslogan || '',
      descripcion: e.descripcion || '',
      pinAdmin: '', // con la base de datos no hay PIN general: cada quien entra con el suyo
      contacto: {
        telefono: e.telefono || '',
        whatsapp: e.whatsapp || '',
        email: e.email || '',
        direccion: e.direccion || '',
        horarioGeneral: e.horario_general || '',
      },
      pago: {
        nit: e.nit || '',
        nequi: numero('nequi'),
        daviplata: numero('daviplata'),
        bancolombia: numero('bancolombia'),
        titular: cuentas.length ? cuentas[0].titular || '' : '',
      },
      metodosPago: (e.metodos_pago || []).map((m) => ({
        id: m.codigo, nombre: m.nombre, descripcion: m.descripcion || '', activo: m.activo,
      })),
      redes: { instagram: e.instagram_url || '', facebook: e.facebook_url || '' },
      tiempos: { mesa: e.tiempo_mesa || '', domicilio: e.tiempo_domicilio || '' },
      horaCorteOperativa: n(e.hora_corte_operativa),
    };
  }

  function cargarCatalogo() {
    const codigo = codigoEmpresa();
    if (!codigo) {
      throw new Error(
        'Falta decir de qué negocio es esta página. Entra por su dirección: ' +
        '/nascar/panel, o nascar.taseca.tech si ya tiene su propio subdominio.'
      );
    }
    const e = obtener('/empresas?codigo=eq.' + encodeURIComponent(codigo), false);
    if (!e || !e.length) throw new Error('La empresa "' + codigo + '" no existe en la base de datos o está desactivada.');
    empresa = e[0];
    const eid = empresa.empresa_id;
    cargarImagenesEmpresa(e);

    // En el panel de Taseca se ven las unidades de todas las empresas
    const unidades = obtener(PAGINA_PLATAFORMA ? '/unidades?order=nombre' : '/unidades?empresa_id=eq.' + eid + '&order=nombre', false);
    cargarLogos(unidades);
    const categorias = obtener('/categorias?empresa_id=eq.' + eid, false);
    const carta = obtener('/carta?empresa_id=eq.' + eid, false);
    const menus = obtener('/menus_dia?empresa_id=eq.' + eid, false);
    const textos = obtener('/textos_menu?empresa_id=eq.' + eid, false);

    const config = {};
    config[empresa.codigo] = aConfig(empresa);
    const datos = { config: config, empresaActual: empresa.codigo };
    // El panel de Taseca tiene su propia lista (todas las empresas): no se pisa
    if (!PAGINA_PLATAFORMA || !esPlataformaConectada()) datos.empresas = [aEmpresa(empresa)];

    S.cargarRemoto(Object.assign(datos, {
      sucursales: unidades.map(aUnidad),
      categorias: categorias.map(aCategoria),
      cartaV2: carta.map(aProducto),
      menusDia: menus.map(aMenu).concat(textos.map(aTextoUnidad)),
      dia: [].concat.apply([], menus.map(aPlatos)),
    }));
  }

  function esPlataformaConectada() {
    const s = S.getSesion();
    return !!(s && s.scope === 'platform' && s.token);
  }

  /* SuperAdmin sin empresa elegida (o en el panel de Taseca): no hay pedidos,
     stock ni caja que refrescar, así que no se gasta red preguntando. */
  function sinOperacion() {
    const s = S.getSesion();
    return !!(s && s.scope === 'platform' && (!s.empresaContext || PAGINA_PLATAFORMA));
  }

  /* Panel de Taseca: todas las empresas (activas o no) y sus usuarios. */
  function cargarPlataforma() {
    if (!PAGINA_PLATAFORMA || !esPlataformaConectada()) return;
    const empresas = obtener('/plataforma_empresas?order=nombre_comercial');
    const usuarios = obtener('/plataforma_usuarios?order=nombre');
    cargarImagenesEmpresa(empresas);
    const config = {};
    empresas.forEach((e) => (config[e.codigo] = aConfig(e)));
    S.cargarRemoto({
      empresas: empresas.map(aEmpresa),
      config: config,
      usuarios: usuarios.map((u) => Object.assign(aUsuario(u), { empresaId: u.empresa_codigo })),
    });
  }

  /* COSTO DE RED (medido con 260 pedidos/día, ver COSTOS_SUPABASE.md):
       31 días completos  ≈ 14 MB  ·  hoy y ayer ≈ 5 MB  ·  sólo cambios ≈ 0 KB
     Por eso el panel abre con hoy y ayer, refresca SÓLO lo que cambió y
     baja el historial una vez, cuando alguien entra a Ventas. */
  let marca = null;              // actualizado_en más reciente que ya tenemos
  let historialCargado = false;

  function ayer() {
    const d = new Date(String(empresa.jornada_actual) + 'T12:00:00');
    d.setDate(d.getDate() - 1);
    return S.aISO(d);
  }

  function anotarMarca(filas) {
    filas.forEach(function (f) {
      const a = f.pedido ? f.pedido.actualizado_en : f.actualizado_en;
      if (a && (!marca || a > marca)) marca = a;
    });
  }

  function mezclarPedidos(filas) {
    if (!filas.length) return;
    const lista = S.leerRemoto('pedidos', []);
    filas.forEach(function (f) {
      const p = aPedido(f.pedido);
      const i = lista.findIndex((x) => x.id === p.id);
      if (i >= 0) lista[i] = p;
      else lista.push(p);
    });
    S.cargarRemoto({ pedidos: lista });
  }

  function cargarPedidos() {
    marca = null;
    historialCargado = false;
    if (!token()) {
      S.cargarRemoto({ pedidos: [] });
      return;
    }
    const filas = obtener('/pedidos?select=pedido&fecha_operativa=gte.' + ayer() + '&order=pedido_id.desc');
    S.cargarRemoto({ pedidos: filas.map((f) => aPedido(f.pedido)) });
    anotarMarca(filas);
    if (!marca) {
      // Nada reciente: la marca es el último cambio de los 31 días, sin bajar sus pedidos
      anotarMarca(obtener('/pedidos?select=actualizado_en&order=actualizado_en.desc&limit=1'));
    }
  }

  /* Usuarios de la empresa: la base sólo los devuelve a quien puede
     administrarlos (a los demás, lista vacía). Pocos KB; no se refrescan
     solos, sólo al entrar y después de guardar. */
  function cargarUsuarios() {
    if (!token()) {
      S.cargarRemoto({ usuarios: [] });
      return;
    }
    S.cargarRemoto({ usuarios: obtener('/usuarios?order=nombre').map(aUsuario) });
  }

  /* El historial de 31 días, una sola vez y sin bloquear la pantalla. */
  function asegurarHistorial() {
    if (!activo || caido || historialCargado || !token()) return;
    historialCargado = true;
    obtenerAsync('/pedidos?select=pedido&fecha_operativa=lt.' + ayer() + '&order=pedido_id.desc')
      .then(mezclarPedidos)
      .catch(function () {
        historialCargado = false;
      });
  }

  /* Reemplaza o agrega un pedido en memoria. */
  function ponerPedido(p) {
    const lista = S.leerRemoto('pedidos', []);
    const i = lista.findIndex((x) => x.id === p.id);
    if (i >= 0) lista[i] = p;
    else lista.push(p);
    S.cargarRemoto({ pedidos: lista });
    return p;
  }

  function buscarEnMemoria(pedidoId) {
    return S.leerRemoto('pedidos', []).find((p) => p.id === pedidoId) || null;
  }

  function idBase(pedidoId) {
    const p = buscarEnMemoria(pedidoId);
    if (p) return p.idBase;
    if (/^o\d+$/.test(String(pedidoId))) return Number(String(pedidoId).slice(1));
    throw new Error('Esa factura no existe.');
  }

  /* Con la pestaña a la vista se refresca cada 8 s. Escondida no se gasta
     red… salvo que los avisos sonoros estén activados: entonces se mira
     cada 30 s, porque de eso viven las notificaciones de cocina, mesero,
     domiciliario y caja. Como sólo se pide lo que cambió, son unos pocos
     bytes por vuelta. */
  const REFRESCO_OCULTO_MS = 30000;
  let ultimoOculto = 0;

  function refrescarPedidos() {
    if (caido) return;
    if (document.hidden) {
      const avisando = NASCAR.Avisos && NASCAR.Avisos.prefs().sonido;
      if (!avisando || Date.now() - ultimoOculto < REFRESCO_OCULTO_MS) return;
      ultimoOculto = Date.now();
    }
    if (sinOperacion()) return;
    if (token()) {
      const desde = marca ? '&actualizado_en=gt.' + encodeURIComponent(marca) : '&fecha_operativa=gte.' + ayer();
      obtenerAsync('/pedidos?select=pedido' + desde + '&order=actualizado_en.asc')
        .then(function (filas) {
          anotarMarca(filas);
          mezclarPedidos(filas);
        })
        .catch(() => {});
      return;
    }
    // Sin sesión: sólo los pedidos que el cliente está siguiendo
    Object.keys(seguidos).forEach(function (codigo) {
      fetch(CFG.url + '/rpc/seguimiento', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify({ p_codigo: codigo, p_empresa: CFG.empresa }),
      })
        .then((r) => (r.ok ? r.json() : null))
        .then(function (json) {
          if (!json) return;
          const nuevo = aPedido(json);
          const actual = buscarEnMemoria(nuevo.id);
          if (!actual || actual.actualizado !== nuevo.actualizado) ponerPedido(nuevo);
        })
        .catch(() => {});
    });
  }

  function refrescarCatalogo() {
    if (caido || document.hidden) return;
    try {
      cargarCatalogo();
    } catch (e) {
      /* se reintenta en el siguiente ciclo */
    }
    refrescarInventario();
    refrescarCaja();
  }

  /* =====================================================================
     OPERACIONES QUE PASAN A LA BASE
     ===================================================================== */
  const operaciones = {
    login: function (usuario, pin) {
      if (pin === undefined) return false; // el ingreso sólo con PIN es del modo local
      const r = rpc('login', { p_usuario: usuario, p_pin: pin }, false);
      if (!r) return false;
      if (r.alcance === 'plataforma') {
        // SuperAdmin de Taseca: no pertenece a ninguna empresa
        S.establecerSesion({
          usuarioId: r.usuario_id,
          nombre: r.nombre,
          rol: r.rol,
          scope: 'platform',
          empresaId: null,
          empresaContext: null,
          sucursalId: null,
          token: r.token,
          expira: r.expira,
        });
        cargarDatosDeSesion();
        return true;
      }
      S.establecerSesion({
        usuarioId: r.usuario_id,
        nombre: r.nombre,
        rol: r.rol,
        scope: 'empresa',
        empresaId: r.empresa_codigo,
        sucursalId: r.unidades && r.unidades.length === 1 ? r.unidades[0] : null,
        token: r.token,
        expira: r.expira,
      });
      // Alguien de otra empresa entra desde esta dirección: se carga la suya
      if (!empresa || empresa.codigo !== r.empresa_codigo) cargarCatalogo();
      cargarDatosDeSesion();
      return true;
    },

    logout: function () {
      S.establecerSesion(null);
      marcaInventario = null;
      marcaCaja = null;
      S.cargarRemoto({ pedidos: [], usuarios: [], stock: [], cierres: [], entradas: [], gastos: [], bases: [] });
    },

    crearPedido: function (datos) {
      const cliente = datos.cliente || {};
      const unidad = S.getSucursal(datos.sucursalId);
      const zona = unidad && cliente.zona ? (unidad.zonas || []).find((z) => z.nombre === cliente.zona) : null;
      const r = rpc('crear_pedido', {
        p_unidad_id: Number(datos.sucursalId),
        p_tipo: datos.tipo,
        p_metodo_pago: datos.metodoPago || 'efectivo',
        p_items: (datos.items || []).map(aLineaBase),
        p_mesa: datos.tipo === 'mesa' ? String(datos.mesa) : null,
        p_cliente_nombre: cliente.nombre || null,
        p_cliente_telefono: cliente.telefono || null,
        p_direccion: cliente.direccion || null,
        p_indicaciones: cliente.notas || null,
        p_zona_id: zona ? zona.id : null,
        p_paga_con: cliente.pagaCon ? Number(cliente.pagaCon) : null,
      });
      const p = ponerPedido(aPedido(r));
      seguidos[p.codigo] = true;
      refrescarCatalogo(); // los cupos del menú del día cambiaron
      return p;
    },

    getPedidoPorCodigo: function (codigo) {
      let c = String(codigo || '').trim().toUpperCase().replace(/^#/, '');
      if (!c) return null;
      if (/^\d{1,5}$/.test(c)) c = c.padStart(5, '0');
      const r = rpc('seguimiento', { p_codigo: c, p_empresa: CFG.empresa }, false);
      if (!r) return null;
      seguidos[c] = true;
      const p = aPedido(r);
      // Con sesión se conserva lo que el panel ya sabía del cliente
      const previo = buscarEnMemoria(p.id);
      if (previo) p.cliente = previo.cliente;
      return ponerPedido(p);
    },

    guardarComprobante: function (pedidoId, comprobante) {
      comprobantesPendientes[pedidoId] = comprobante;
      return true;
    },

    reportarPago: function (pedidoId, referencia) {
      const p = buscarEnMemoria(pedidoId);
      if (!p) throw new Error('Esa factura no existe.');
      const comp = comprobantesPendientes[pedidoId];
      const r = rpc('reportar_pago', {
        p_codigo: p.codigo,
        p_referencia: referencia || null,
        p_imagen: comp ? comp.dataUrl : null,
        p_empresa: CFG.empresa,
      }, false);
      delete comprobantesPendientes[pedidoId];
      const nuevo = aPedido(r);
      nuevo.cliente = p.cliente;
      return ponerPedido(nuevo);
    },

    getComprobante: function (pedidoId) {
      const r = rpc('comprobante', { p_pedido_id: idBase(pedidoId) });
      return r ? { dataUrl: r.imagen, nombreArchivo: 'comprobante', pesoKB: n(r.peso_kb), subido: r.creado_en } : null;
    },

    cambiarEstado: function (pedidoId, estado) {
      if (estado === 'cancelado') return operaciones.cancelarPedido(pedidoId, 'Cancelado desde el panel');
      return ponerPedido(aPedido(rpc('cambiar_estado', { p_pedido_id: idBase(pedidoId), p_estado: estado })));
    },

    avanzarEstado: function (pedidoId) {
      return ponerPedido(aPedido(rpc('avanzar_estado', { p_pedido_id: idBase(pedidoId) })));
    },

    cancelarPedido: function (pedidoId, motivo) {
      return ponerPedido(aPedido(rpc('cancelar_pedido', {
        p_pedido_id: idBase(pedidoId),
        p_motivo: motivo && motivo.length >= 3 ? motivo : 'Cancelado desde el panel',
      })));
    },

    anularPedido: function (pedidoId, motivo) {
      const r = rpc('anular_pedido', { p_pedido_id: idBase(pedidoId), p_motivo: motivo });
      const p = ponerPedido(aPedido(r.pedido));
      despuesDeInventario(); // el retorno de mercancía es una entrada nueva
      return {
        pedido: p,
        retorno: {
          productos: r.retorno.productos || [],
          diferido: r.retorno.diferido,
          jornadaRetorno: r.retorno.jornada_retorno,
        },
      };
    },

    /* `metodo`: con qué pagó de verdad el cliente. Sólo se envía si cambia,
       así que confirmar sin cambiar el método funciona también con una base
       que aún no tiene instalado el 16_pagos_en_caja.sql. */
    confirmarPago: function (pedidoId, referencia, quien, metodo) {
      const actual = buscarEnMemoria(pedidoId);
      const args = { p_pedido_id: idBase(pedidoId), p_referencia: referencia || null };
      if (metodo && (!actual || actual.metodoPago !== metodo)) args.p_metodo = metodo;
      return ponerPedido(aPedido(rpc('confirmar_pago', args)));
    },

    rechazarPago: function (pedidoId, motivo) {
      return ponerPedido(aPedido(rpc('rechazar_pago', { p_pedido_id: idBase(pedidoId), p_motivo: motivo || null })));
    },

    // La semilla de ejemplo es del modo local: la base ya trae sus datos
    sembrar: function () {},

    /* Es una LECTURA que el panel hace al arrancar (Ajustes): nunca debe
       fallar, o se corta el arranque de Mesas, Cocina y Entregas. En la
       base las facturas de prueba se borran con api.sp_borrar_facturas_prueba. */
    contarFacturasPrueba: function () {
      return { pedidos: 0, entradas: 0 };
    },
  };

  /* =====================================================================
     CARTA Y MENÚ DEL DÍA (fase 2 · bloque 1)

     Las pantallas de edición no cambian: cada acción sigue pasando por la
     función del Store, con sus mismas validaciones, sobre los datos en
     memoria. Aquí se compara el catálogo antes y después, se manda a la
     base SÓLO lo que cambió (rest.sincronizar_catalogo, una transacción) y
     se vuelve a cargar el catálogo con los ids definitivos. Si la base
     rechaza el cambio, la memoria vuelve a como estaba y la pantalla
     muestra el motivo.
     ===================================================================== */
  const SINCRONIZADAS = [
    'guardarCategoria', 'borrarCategoria', 'guardarPlatoCarta', 'borrarPlatoCarta', 'ajustarPlatoCarta',
    'guardarPlatoDia', 'borrarPlatoDia', 'copiarPlatosDia', 'moverPlatoDia', 'copiarMenuDia',
    'setTipoMenuDia', 'guardarDatosArmado', 'guardarCategoriaArmado', 'borrarCategoriaArmado',
    'moverCategoriaArmado', 'guardarOpcionArmado', 'borrarOpcionArmado', 'moverOpcionArmado',
    'guardarTextoMenuDia',
  ];
  const CLAVES_CATALOGO = ['categorias', 'cartaV2', 'menusDia', 'dia'];

  function fotoCatalogo() {
    const f = {};
    CLAVES_CATALOGO.forEach((k) => (f[k] = S.leerRemoto(k, [])));
    return f;
  }

  /* Registros nuevos o modificados, e ids que desaparecieron. */
  function diferencia(antes, despues) {
    const previos = {};
    antes.forEach((x) => (previos[String(x.id)] = JSON.stringify(x)));
    const cambiados = [];
    const vistos = {};
    despues.forEach(function (x) {
      const id = String(x.id);
      vistos[id] = true;
      if (previos[id] !== JSON.stringify(x)) cambiados.push(x);
    });
    return { cambiados: cambiados, borrados: Object.keys(previos).filter((id) => !vistos[id]) };
  }

  /* Un menú que pasa a "armado" sin categorías (venía de la base como menú
     del chef) arranca con las de siempre, como en el modo local. */
  function conCategoriasPorDefecto(doc) {
    const a = doc.armado || {};
    if (doc.tipo !== 'armado' || (a.categorias && a.categorias.length)) return doc;
    return Object.assign({}, doc, {
      armado: Object.assign({}, a, {
        categorias: (NASCAR.CATEGORIAS_ARMADO || []).map((c, i) => ({
          id: 'nueva' + i,
          nombre: c.nombre,
          icono: c.icono || '',
          obligatoria: c.obligatoria !== false,
          maxSeleccion: c.maxSeleccion || 1,
          activa: true,
          opciones: [],
        })),
      }),
    });
  }

  function cambiosDelCatalogo(antes, despues) {
    const cat = diferencia(antes.categorias, despues.categorias);
    const car = diferencia(antes.cartaV2, despues.cartaV2);
    const men = diferencia(antes.menusDia, despues.menusDia);
    const dia = diferencia(antes.dia, despues.dia);
    const c = {};
    if (cat.cambiados.length) c.categorias = cat.cambiados;
    if (cat.borrados.length) c.categorias_borradas = cat.borrados;
    if (car.cambiados.length) c.productos = car.cambiados;
    if (car.borrados.length) c.productos_borrados = car.borrados;
    if (men.cambiados.length) c.menus = men.cambiados.map(conCategoriasPorDefecto);
    if (dia.borrados.length) c.platos_borrados = dia.borrados;
    if (dia.cambiados.length) c.platos = dia.cambiados;
    return Object.keys(c).length ? c : null;
  }

  /* =====================================================================
     STOCK, ENTRADAS Y CIERRES (fase 2 · bloque 3)

     Aquí no sirve comparar antes y después: en la base las entradas no se
     editan (se anulan y se registra la correcta), el stock es por unidad y
     el cruce se calcula con TODAS las ventas del tramo, no con los pedidos
     que este navegador tiene en memoria. Cada acción llama a su función
     de la base y después se recarga el inventario.

     COSTO DE RED: el inventario (~200 KB con 62 días de cierres) baja al
     entrar y después de guardar. El refresco de 5 minutos sólo pregunta
     por /inventario_marca (unos bytes) y recarga si algo cambió. El cruce
     se guarda 5 minutos, porque el panel se repinta cada 20 segundos.
     ===================================================================== */
  let marcaInventario = null;
  const cacheCruce = {}; // clave -> { ts, valor }
  const VIGENCIA_CRUCE_MS = 300000;

  function aStock(s) {
    const unidades = s.unidades || [];
    const u = unidades[0] || {};
    return {
      codigo: s.codigo,
      idBase: s.insumo_id,
      empresaId: empresa.codigo,
      nombre: s.nombre,
      categoria: s.categoria || 'General',
      area: s.area,
      unidad: s.unidad_medida || 'unidad',
      activo: s.activo,
      ventaRefIds: (s.productos || []).map((id) => 'p' + id),
      stockActual: n(u.stock_actual),
      stockMinimo: n(u.stock_minimo),
      sucursales: unidades.map((x) => x.unidad_id),
    };
  }

  function aCierre(c) {
    if (!c) return null;
    const historial = [{ ts: c.creado_en, texto: 'Cierre registrado' }];
    if (c.actualizado_en && c.actualizado_en !== c.creado_en && !c.revisado_en)
      historial.push({ ts: c.actualizado_en, texto: 'Última corrección por ' + (c.registrado_por || '—') });
    if (c.aplicado_a_stock) historial.push({ ts: c.actualizado_en, texto: 'Saldos aplicados al stock actual' });
    if (c.revisado_en) historial.push({ ts: c.revisado_en, texto: 'Revisado por ' + (c.revisado_por || 'Administración') });
    return {
      id: 'ci' + c.cierre_id,
      idBase: c.cierre_id,
      empresaId: empresa.codigo,
      sucursalId: c.unidad_id,
      fechaCierre: c.fecha_operativa,
      fechaRegistro: c.creado_en,
      area: c.area,
      usuarioId: c.registrado_por_id || null,
      usuarioNombre: c.registrado_por || '—',
      estado: c.estado,
      productos: (c.productos || []).map((p) => ({ codigo: p.codigo, nombre: p.nombre, saldo: n(p.saldo) })),
      observaciones: c.observacion || '',
      aplicadoAStock: !!c.aplicado_a_stock,
      actualizado: c.actualizado_en,
      historial: historial,
    };
  }

  function aEntrada(e) {
    return {
      id: 'en' + e.entrada_id,
      idBase: e.entrada_id,
      empresaId: empresa.codigo,
      fecha: e.fecha_operativa,
      sucursalId: e.unidad_id,
      codigo: e.codigo,
      nombre: e.nombre,
      area: e.area,
      cantidad: n(e.cantidad),
      tipoEntrada: e.tipo,
      observacion: e.observacion || '',
      registrado: e.creado_en,
      usuarioId: e.usuario_id || null,
      usuarioNombre: e.registrada_por || 'Sistema',
      factura: e.factura || null,
      historial: [],
    };
  }

  function cargarInventario() {
    if (!token()) {
      marcaInventario = null;
      S.cargarRemoto({ stock: [], cierres: [], entradas: [] });
      return;
    }
    // La marca primero: lo que cambie mientras se descarga se ve en el siguiente refresco
    const m = obtener('/inventario_marca');
    const stock = obtener('/stock?order=codigo');
    const cierres = obtener('/cierres?order=fecha_operativa.desc');
    const entradas = obtener('/entradas?order=fecha_operativa.desc,entrada_id.desc');
    marcaInventario = m.length ? m[0].marca : null;
    Object.keys(cacheCruce).forEach((k) => delete cacheCruce[k]);
    S.cargarRemoto({ stock: stock.map(aStock), cierres: cierres.map(aCierre), entradas: entradas.map(aEntrada) });
  }

  /* ¿Cambió algo del inventario? Unos bytes; recarga sólo si sí. */
  function refrescarInventario(forzarCruce) {
    if (caido || !token() || sinOperacion()) return;
    if (forzarCruce) Object.keys(cacheCruce).forEach((k) => delete cacheCruce[k]);
    obtenerAsync('/inventario_marca')
      .then(function (m) {
        const nueva = m.length ? m[0].marca : null;
        if (nueva !== marcaInventario) cargarInventario();
      })
      .catch(() => {});
  }

  function despuesDeInventario() {
    try {
      cargarInventario();
    } catch (e) {
      /* ya quedó guardado; el siguiente refresco lo pone al día */
    }
  }

  function idDe(prefijo, id) {
    const m = new RegExp('^' + prefijo + '(\\d+)$').exec(String(id));
    if (!m) throw new Error('Ese registro es del modo local de este navegador y no existe en la base de datos.');
    return Number(m[1]);
  }

  function productosDeCarta(refs) {
    return (refs || []).filter(Boolean).map(function (ref) {
      if (!/^p\d+$/.test(String(ref)))
        throw new Error('Ese producto de la carta es del modo local de este navegador. Elige uno de la lista.');
      return Number(String(ref).slice(1));
    });
  }

  function cruceDesdeBase(r, sucursalId, fechaCierre, area) {
    const filas = (r.filas || []).map(function (f) {
      const IN = n(f.IN);
      const EN = n(f.EN);
      const Z = n(f.Z);
      const SLDC = IN + EN - Z;
      const registrado = !!f.registrado;
      const SD = registrado ? n(f.SD) : null;
      const DF = registrado ? SD - SLDC : null;
      return {
        codigo: f.codigo,
        nombre: f.nombre,
        categoria: f.categoria,
        unidad: f.unidad || '',
        IN: IN,
        origenIN: f.origenIN || 'sin-dato',
        fuenteIN: f.fuenteIN || null,
        EN: EN,
        Z: Z,
        SD: SD,
        SLDC: SLDC,
        DF: DF,
        registrado: registrado,
        estado: !registrado ? 'sin-registrar' : DF === 0 ? 'ok' : DF > 0 ? 'sobrante' : 'faltante',
      };
    });

    const conSD = filas.filter((f) => f.registrado);
    const resumen = {
      revisados: conSD.length,
      totalCatalogo: filas.length,
      sinRegistrar: filas.length - conSD.length,
      ok: conSD.filter((f) => f.DF === 0).length,
      sobrantes: conSD.filter((f) => f.DF > 0).length,
      faltantes: conSD.filter((f) => f.DF < 0).length,
      diferenciaTotal: conSD.reduce((s, f) => s + f.DF, 0),
      unidadesSobrantes: conSD.filter((f) => f.DF > 0).reduce((s, f) => s + f.DF, 0),
      unidadesFaltantes: conSD.filter((f) => f.DF < 0).reduce((s, f) => s + Math.abs(f.DF), 0),
      inDesdeCierre: filas.filter((f) => f.origenIN === 'cierre').length,
      inDesdeStock: filas.filter((f) => f.origenIN === 'stock').length,
      inSinDato: filas.filter((f) => f.origenIN === 'sin-dato').length,
    };
    resumen.sinDiferencias = resumen.revisados > 0 && resumen.sobrantes === 0 && resumen.faltantes === 0;

    const anterior = r.cierre_anterior
      ? S.getCierre('ci' + r.cierre_anterior.cierre_id) || { id: 'ci' + r.cierre_anterior.cierre_id, fechaCierre: r.cierre_anterior.fecha }
      : null;

    return {
      sucursalId: Number(sucursalId),
      fechaCierre: fechaCierre,
      area: area,
      cierre: aCierre(r.cierre),
      hayCierre: !!r.cierre,
      cierreAnterior: anterior,
      hayCierreAnterior: !!anterior,
      filas: filas,
      resumen: resumen,
    };
  }

  const inventario = {
    guardarProductoStock: function (datos, codigoOriginal) {
      const buscado = String(codigoOriginal || datos.codigo || '').trim().toUpperCase();
      const base = S.leerRemoto('stock', []).find((p) => p.codigo === buscado) || null;
      const cambios = Object.assign({}, datos);
      if (Array.isArray(cambios.sucursales) && !cambios.sucursales.length) delete cambios.sucursales;
      const r = Object.assign({}, base || {}, cambios);
      const unidades = (r.sucursales && r.sucursales.length ? r.sucursales : [S.unidadActivaId()])
        .map(Number)
        .filter(Boolean);

      const insumo = {
        insumo_id: base ? base.idBase : null,
        codigo: r.codigo,
        nombre: r.nombre,
        categoria: r.categoria || 'General',
        area: r.area || 'comidas',
        unidad: r.unidad || 'unidad',
        activo: r.activo !== false,
        unidades: unidades,
      };
      // Sólo lo que cambió: el stock de los demás productos no se toca
      if (cambios.stockActual !== undefined && (!base || Number(cambios.stockActual) !== Number(base.stockActual)))
        insumo.stock_actual = Number(cambios.stockActual);
      if (cambios.stockMinimo !== undefined && (!base || Number(cambios.stockMinimo) !== Number(base.stockMinimo)))
        insumo.stock_minimo = Number(cambios.stockMinimo);
      if (cambios.ventaRefIds !== undefined) insumo.productos = productosDeCarta(cambios.ventaRefIds);

      rpc('guardar_insumo', { p_insumo: insumo });
      despuesDeInventario();
      return S.getStock({ todos: true });
    },

    activarProductoStock: function (codigo, activo) {
      return S.guardarProductoStock({ codigo: codigo, activo: !!activo }, codigo);
    },

    ajustarStockActual: function (codigo, cantidad, motivo) {
      const valor = Number(cantidad);
      if (!isFinite(valor) || valor < 0 || Math.floor(valor) !== valor)
        throw new Error('El stock debe ser un número entero mayor o igual a cero.');
      const p = S.leerRemoto('stock', []).find((x) => x.codigo === codigo);
      if (!p) throw new Error('Ese producto ya no existe. Recarga la página.');
      if ((p.sucursales || []).length !== 1)
        throw new Error('Este producto está en varias unidades: cambia su stock desde «Editar».');
      rpc('ajustar_stock', { p_unidad_id: p.sucursales[0], p_codigo: codigo, p_cantidad: valor });
      despuesDeInventario();
      return { codigo: codigo, stockActual: valor, motivo: motivo || '' };
    },

    aplicarCierreAStock: function (cierreId) {
      const aplicados = rpc('aplicar_cierre_a_stock', { p_cierre_id: idDe('ci', cierreId) });
      despuesDeInventario();
      return Number(aplicados) || 0;
    },

    guardarCierre: function (datos) {
      let r;
      try {
        r = rpc('registrar_cierre', {
          p_cierre: {
            unidad_id: Number(datos.sucursalId),
            area: datos.area,
            fecha: datos.fechaCierre,
            estado: datos.estado || 'completado',
            observacion: datos.observaciones || '',
            productos: (datos.productos || []).map((p) => ({ codigo: p.codigo, saldo: p.saldo })),
            nuevo: true,
          },
        });
      } catch (e) {
        if (/YA_EXISTE/.test(e.message || '')) {
          despuesDeInventario();
          const err = new Error('YA_EXISTE');
          err.codigo = 'YA_EXISTE';
          const existente = S.buscarCierre(datos.sucursalId, datos.fechaCierre, datos.area);
          err.cierreId = existente ? existente.id : null;
          throw err;
        }
        throw e;
      }
      despuesDeInventario();
      return aCierre(r);
    },

    actualizarCierre: function (cierreId, cambios) {
      cambios = cambios || {};
      const c = S.getCierre(cierreId);
      if (!c) return null;
      if (cambios.estado === 'revisado') return S.cambiarEstadoCierre(cierreId, 'revisado');
      const r = rpc('registrar_cierre', {
        p_cierre: {
          unidad_id: c.sucursalId,
          area: c.area,
          fecha: c.fechaCierre,
          estado: cambios.estado || (c.estado === 'borrador' ? 'borrador' : 'completado'),
          observacion: cambios.observaciones !== undefined ? cambios.observaciones : c.observaciones,
          productos: (cambios.productos || c.productos).map((p) => ({ codigo: p.codigo, saldo: p.saldo })),
          nuevo: false,
        },
      });
      despuesDeInventario();
      return aCierre(r);
    },

    cambiarEstadoCierre: function (cierreId, estado) {
      if (estado !== 'revisado') return S.actualizarCierre(cierreId, { estado: estado });
      const r = rpc('revisar_cierre', { p_cierre_id: idDe('ci', cierreId) });
      despuesDeInventario();
      return aCierre(r);
    },

    guardarEntrada: function (datos) {
      const r = rpc('registrar_entrada', {
        p_entrada: {
          unidad_id: Number(datos.sucursalId),
          codigo: datos.codigo,
          tipo: datos.tipoEntrada || 'compra',
          cantidad: datos.cantidad === '' || datos.cantidad == null ? null : Number(datos.cantidad),
          observacion: datos.observacion || '',
          fecha: datos.fecha,
        },
      });
      despuesDeInventario();
      return aEntrada(r);
    },

    actualizarEntrada: function (entradaId, datos) {
      datos = datos || {};
      const cambios = {};
      if (datos.fecha) cambios.fecha = datos.fecha;
      if (datos.codigo) cambios.codigo = datos.codigo;
      if (datos.sucursalId) cambios.unidad_id = Number(datos.sucursalId);
      if (datos.cantidad !== undefined) cambios.cantidad = datos.cantidad === '' ? null : Number(datos.cantidad);
      if (datos.tipoEntrada) cambios.tipo = datos.tipoEntrada;
      if (datos.observacion !== undefined) cambios.observacion = datos.observacion;
      if (cambios.cantidad === null) throw new Error('La cantidad debe ser un número entero mayor que cero.');
      const r = rpc('corregir_entrada', { p_entrada_id: idDe('en', entradaId), p_datos: cambios });
      despuesDeInventario();
      return aEntrada(r);
    },

    borrarEntrada: function (entradaId) {
      rpc('anular_entrada', { p_entrada_id: idDe('en', entradaId), p_motivo: 'Eliminada desde el panel' });
      despuesDeInventario();
      return true;
    },

    calcularCruce: function (sucursalId, fechaCierre, area) {
      const clave = [sucursalId, fechaCierre, area, marcaInventario].join('|');
      const guardado = cacheCruce[clave];
      if (guardado && Date.now() - guardado.ts < VIGENCIA_CRUCE_MS) return guardado.valor;
      if (sinOperacion()) throw new Error('Elige primero la empresa que vas a administrar.');
      const r = rpc('cruce_inventario', { p_unidad_id: Number(sucursalId), p_fecha: fechaCierre, p_area: area });
      const valor = cruceDesdeBase(r, sucursalId, fechaCierre, area);
      cacheCruce[clave] = { ts: Date.now(), valor: valor };
      return valor;
    },
  };

  /* =====================================================================
     BASE DE CAJA, GASTOS Y CRUCE DE CAJA (fase 2 · bloque 4)

     Gastos y bases de los últimos 93 días viven en memoria (son pocos
     KB). Si alguien filtra desde antes, se baja ese tramo una vez.

     El cruce de caja de HOY y AYER se calcula aquí, con la misma función
     de siempre, porque los pedidos de esas jornadas ya están en memoria y
     se refrescan cada 8 segundos: sale gratis y al día. Para jornadas
     anteriores lo calcula la base (rest.informe_caja) y se guarda 5
     minutos, porque el panel se repinta cada 20 segundos.
     ===================================================================== */
  const DIAS_CAJA = 93;
  let marcaCaja = null;
  let desdeCaja = null; // primera jornada que ya está en memoria
  const cacheInforme = {};

  function restarDias(iso, dias) {
    const d = new Date(String(iso) + 'T12:00:00');
    d.setDate(d.getDate() - dias);
    return S.aISO(d);
  }

  function horaCorta(h) {
    return h ? String(h).slice(0, 5) : '';
  }

  function aGasto(g) {
    const suc = S.getSucursal(g.unidad_id);
    const historial = [{ ts: g.creado_en, texto: 'Gasto registrado por ' + (g.registrado_por || 'Sistema') }];
    if (g.confirmado_en) historial.push({ ts: g.confirmado_en, texto: 'Gasto confirmado por ' + (g.confirmado_por || '—') });
    if (g.anulado_en)
      historial.push({ ts: g.anulado_en, texto: 'Anulado por ' + (g.anulado_por || '—') + ': ' + (g.motivo_anulacion || '') });
    return {
      id: 'ga' + g.gasto_id,
      idBase: g.gasto_id,
      empresaId: empresa.codigo,
      consecutivo: g.consecutivo,
      fecha: g.fecha_operativa,
      hora: horaCorta(g.hora),
      sucursalId: g.unidad_id,
      sucursalNombre: suc ? suc.nombre : '',
      categoria: 'cg' + g.categoria_gasto_id,
      concepto: g.descripcion,
      tercero: g.tercero || '',
      valor: n(g.monto),
      metodoPago: g.metodo_pago,
      observaciones: g.observaciones || '',
      estado: g.estado,
      usuarioId: g.registrado_por_id || null,
      usuarioNombre: g.registrado_por || 'Sistema',
      rolUsuario: g.registrado_rol || null,
      creado: g.creado_en,
      confirmadoPor: g.confirmado_por || null,
      confirmado: g.confirmado_en || null,
      anuladoPor: g.anulado_por || null,
      anulado: g.anulado_en || null,
      motivoAnulacion: g.motivo_anulacion || '',
      historial: historial,
    };
  }

  function aBase(b) {
    if (!b) return null;
    return {
      id: 'ba' + b.base_id,
      idBase: b.base_id,
      empresaId: empresa.codigo,
      sucursalId: b.unidad_id,
      sucursalNombre: b.unidad || '',
      fecha: b.fecha_operativa,
      hora: horaCorta(b.hora),
      valor: n(b.monto),
      observaciones: b.observacion || '',
      usuarioId: b.usuario_id || null,
      usuarioNombre: b.registrada_por || 'Sistema',
      rol: b.rol || null,
      estado: b.vigente ? 'activa' : 'corregida',
      registrada: b.creado_en,
      corrigeA: b.reemplaza_a_id ? 'ba' + b.reemplaza_a_id : null,
      motivoCorreccion: b.motivo_correccion || '',
      efectivoContado: null,
      arqueadaPor: null,
      arqueada: null,
    };
  }

  function cargarCaja() {
    if (!token()) {
      marcaCaja = null;
      desdeCaja = null;
      S.cargarRemoto({ gastos: [], bases: [] });
      return;
    }
    const m = obtener('/caja_marca');
    const categorias = obtener('/categorias_gasto?order=categoria_gasto_id');
    // Las categorías de gasto son de la empresa: reemplazan a las de ejemplo
    NASCAR.CATEGORIAS_GASTO = categorias.map((c) => ({
      id: 'cg' + c.categoria_gasto_id,
      nombre: c.nombre,
      icono: c.icono || '📌',
      activa: c.activa,
    }));
    desdeCaja = restarDias(empresa.jornada_actual, DIAS_CAJA);
    const gastos = obtener('/gastos?fecha_operativa=gte.' + desdeCaja + '&order=fecha_operativa.desc,gasto_id.desc');
    const bases = obtener('/bases_caja?fecha_operativa=gte.' + desdeCaja + '&order=base_id.desc');
    marcaCaja = m.length ? m[0].marca : null;
    Object.keys(cacheInforme).forEach((k) => delete cacheInforme[k]);
    S.cargarRemoto({ gastos: gastos.map(aGasto), bases: bases.map(aBase) });
  }

  function refrescarCaja(forzar) {
    if (caido || !token() || sinOperacion()) return;
    if (forzar) Object.keys(cacheInforme).forEach((k) => delete cacheInforme[k]);
    obtenerAsync('/caja_marca')
      .then(function (m) {
        const nueva = m.length ? m[0].marca : null;
        if (nueva !== marcaCaja) cargarCaja();
      })
      .catch(() => {});
  }

  function despuesDeCaja() {
    try {
      cargarCaja();
    } catch (e) {
      /* ya quedó guardado; el siguiente refresco lo pone al día */
    }
  }

  /* Gastos y bases anteriores a lo que hay en memoria, una sola vez. */
  function asegurarCajaDesde(desde) {
    if (!desde || !desdeCaja || desde >= desdeCaja || !token()) return;
    const hasta = desdeCaja;
    const gastos = obtener('/gastos?fecha_operativa=gte.' + desde + '&fecha_operativa=lt.' + hasta);
    const bases = obtener('/bases_caja?fecha_operativa=gte.' + desde + '&fecha_operativa=lt.' + hasta);
    desdeCaja = desde;
    S.cargarRemoto({
      gastos: S.leerRemoto('gastos', []).concat(gastos.map(aGasto)),
      bases: S.leerRemoto('bases', []).concat(bases.map(aBase)),
    });
  }

  function bolsa() {
    return { efectivo: 0, transferencia: 0, otros: 0, total: 0 };
  }

  function sumar(b, grupo, valor) {
    const g = b[grupo] !== undefined ? grupo : 'otros';
    b[g] += valor;
    b.total += valor;
  }

  /* El informe de una jornada antigua, desde la base, con la forma de
     store.informeCaja(). */
  function informeDesdeBase(r, jornada, sucursalId) {
    const vendido = bolsa();
    const cobrado = bolsa();
    const porCobrar = bolsa();
    const anuladas = bolsa();
    const gastado = bolsa();
    const porMetodo = {};
    const porMetodoGasto = {};
    let nPedidos = 0, nPorCobrar = 0, nAnuladas = 0, rechazado = 0;
    let nGastos = 0, gastosPendientes = 0, montoPendienteGastos = 0;

    Object.keys(r.ventas || {}).forEach(function (m) {
      const v = r.ventas[m];
      nPedidos += n(v.n);
      nPorCobrar += n(v.nPendiente);
      rechazado += n(v.rechazado);
      porMetodo[m] = { n: n(v.n), vendido: n(v.vendido), cobrado: n(v.cobrado), pendiente: n(v.pendiente) };
      sumar(vendido, v.grupo, n(v.vendido));
      sumar(cobrado, v.grupo, n(v.cobrado));
      sumar(porCobrar, v.grupo, n(v.pendiente));
    });
    Object.keys(r.anuladas || {}).forEach(function (m) {
      const a = r.anuladas[m];
      nAnuladas += n(a.n);
      sumar(anuladas, a.grupo, n(a.total));
    });
    Object.keys(r.gastos || {}).forEach(function (m) {
      const g = r.gastos[m];
      nGastos += n(g.n);
      gastosPendientes += n(g.pendientes);
      montoPendienteGastos += n(g.montoPendiente);
      porMetodoGasto[m] = { n: n(g.n), total: n(g.total) };
      sumar(gastado, g.grupo, n(g.total));
    });

    const valorBase = n(r.base && r.base.valor);
    const efectivoEsperado = valorBase + cobrado.efectivo - gastado.efectivo;
    const e = S.getEmpresaActual();
    const suc = sucursalId ? S.getSucursal(sucursalId) : null;

    return {
      jornada: jornada,
      empresaId: empresa.codigo,
      empresaNombre: e ? e.nombre : empresa.nombre_comercial || '',
      sucursalId: sucursalId ? Number(sucursalId) : null,
      sucursalNombre: suc ? suc.nombre : 'Todas las sucursales',
      base: { registro: aBase(r.base && r.base.registro), valor: valorBase, unica: !!sucursalId },
      ventas: {
        n: nPedidos, vendido: vendido, cobrado: cobrado, porCobrar: porCobrar, nPorCobrar: nPorCobrar,
        rechazado: rechazado, porMetodo: porMetodo, anuladas: anuladas, nAnuladas: nAnuladas,
      },
      gastos: {
        n: nGastos, bolsa: gastado, porMetodo: porMetodoGasto, pendientes: gastosPendientes,
        montoPendiente: montoPendienteGastos,
      },
      efectivoEsperado: efectivoEsperado,
      rc: efectivoEsperado,
      transferenciasNetas: cobrado.transferencia - gastado.transferencia,
      otrosNetos: cobrado.otros - gastado.otros,
      arqueo: { hay: false, contado: null, diferencia: null },
      cierres: S.getCierres(sucursalId ? { sucursalId: sucursalId } : {}).filter((c) => c.fechaCierre === jornada),
    };
  }

  function idCategoriaGasto(cat) {
    if (!cat) return null;
    return idDe('cg', cat);
  }

  function crearCaja(originales) {
    return {
      getGastos: function (filtro) {
        if (filtro && filtro.desde) asegurarCajaDesde(filtro.desde);
        return originales.getGastos(filtro);
      },

      resumenGastos: function (desde, hasta, sucursalId) {
        asegurarCajaDesde(desde);
        return originales.resumenGastos(desde, hasta, sucursalId);
      },

      crearGasto: function (datos) {
        const r = rpc('guardar_gasto', {
          p_gasto: {
            unidad_id: Number(datos.sucursalId),
            fecha: datos.fecha,
            hora: datos.hora || null,
            categoria_gasto_id: idCategoriaGasto(datos.categoria),
            metodo_pago: datos.metodoPago || null,
            descripcion: datos.concepto || '',
            tercero: datos.tercero || '',
            observaciones: datos.observaciones || '',
            monto: datos.valor === '' || datos.valor == null ? null : Number(datos.valor),
          },
        });
        despuesDeCaja();
        return aGasto(r);
      },

      actualizarGasto: function (gastoId, datos) {
        const g = S.getGasto(gastoId);
        if (!g) throw new Error('No se encontró el gasto.');
        const x = Object.assign({}, g, datos || {});
        const r = rpc('guardar_gasto', {
          p_gasto: {
            gasto_id: idDe('ga', gastoId),
            fecha: x.fecha,
            hora: x.hora || null,
            categoria_gasto_id: idCategoriaGasto(x.categoria),
            metodo_pago: x.metodoPago || null,
            descripcion: x.concepto || '',
            tercero: x.tercero || '',
            observaciones: x.observaciones || '',
            monto: x.valor === '' || x.valor == null ? null : Number(x.valor),
          },
        });
        despuesDeCaja();
        return aGasto(r);
      },

      confirmarGasto: function (gastoId) {
        const r = rpc('confirmar_gasto', { p_gasto_id: idDe('ga', gastoId) });
        despuesDeCaja();
        return aGasto(r);
      },

      anularGasto: function (gastoId, motivo) {
        const r = rpc('anular_gasto', { p_gasto_id: idDe('ga', gastoId), p_motivo: motivo || '' });
        despuesDeCaja();
        return aGasto(r);
      },

      registrarBase: function (datos, opciones) {
        opciones = opciones || {};
        const r = rpc('registrar_base', {
          p_base: {
            unidad_id: Number(datos.sucursalId),
            fecha: datos.fecha,
            monto: datos.valor === '' || datos.valor == null ? null : Number(datos.valor),
            hora: datos.hora || null,
            observaciones: datos.observaciones || '',
            corregir: !!opciones.corregir,
            motivo: opciones.motivo || '',
          },
        });
        despuesDeCaja();
        return aBase(r);
      },

      informeCaja: function (fecha, sucursalId) {
        const jornada = fecha || S.hoyOperativo();
        // Hoy y ayer: con los datos en memoria, que se refrescan solos
        if (jornada >= ayer()) return originales.informeCaja(jornada, sucursalId);

        asegurarCajaDesde(jornada);
        const clave = [jornada, sucursalId || '', marcaCaja].join('|');
        const guardado = cacheInforme[clave];
        if (guardado && Date.now() - guardado.ts < VIGENCIA_CRUCE_MS) return guardado.valor;
        const r = rpc('informe_caja', { p_fecha: jornada, p_unidad_id: sucursalId ? Number(sucursalId) : null });
        const valor = informeDesdeBase(r, jornada, sucursalId);
        cacheInforme[clave] = { ts: Date.now(), valor: valor };
        return valor;
      },
    };
  }

  /* =====================================================================
     USUARIOS Y UNIDADES (fase 2 · bloque 2)
     Mismo mecanismo que la carta: la función del Store valida y cambia la
     memoria; aquí se manda a la base cada registro que cambió.
     ===================================================================== */
  const SINCRONIZADAS_UNIDADES = ['guardarSucursal', 'activarSucursal', 'guardarUnidad', 'activarUnidad'];
  const SINCRONIZADAS_USUARIOS = ['guardarUsuario', 'activarUsuario'];

  function aUnidadBase(u, previa) {
    const datos = {
      unidad_id: previa ? u.id : null, // un id que no existía lo inventó el navegador
      nombre: u.nombre,
      corto: u.corto || '',
      tipoNegocio: u.tipoNegocio,
      activa: u.activa !== false,
      direccion: u.direccion || '',
      ciudad: u.ciudad || '',
      telefono: u.telefono || '',
      whatsapp: u.whatsapp || '',
      horario: u.horario || '',
      mapa: u.mapa || '',
      mesas: Number(u.mesas) || 0,
      color: u.color || 'azul',
      colorMarca: (u.branding && u.branding.color) || '',
      zonas: (u.zonas || []).map((z) => ({ nombre: z.nombre, costo: Number(z.costo) || 0, min: Number(z.min) || 0 })),
    };
    // El logo sólo viaja si cambió (pesa)
    const logo = (u.branding && u.branding.logo) || '';
    const logoPrevio = (previa && previa.branding && previa.branding.logo) || '';
    if (logo !== logoPrevio) datos.logo = logo;
    return datos;
  }

  function aUsuarioBase(u, previo) {
    const datos = {
      usuario_id: previo ? u.id : null,
      nombre: u.nombre,
      usuario: u.usuario,
      rol: u.rol,
      activo: u.activo !== false,
      // Una unidad, todas ([]), o sin tocar (null) si en la base tenía varias y no se cambió
      unidades: u.sucursalId
        ? [Number(u.sucursalId)]
        : previo && (previo.unidades || []).length > 1 && !previo.sucursalId
        ? null
        : [],
    };
    if (u.pin && String(u.pin).trim()) datos.pin = String(u.pin).trim();
    return datos;
  }

  const TIPOS_SINCRONIZACION = {
    catalogo: {
      foto: fotoCatalogo,
      enviar: function (antes, despues) {
        const cambios = cambiosDelCatalogo(antes, despues);
        return cambios ? rpc('sincronizar_catalogo', { p_cambios: cambios }) : undefined;
      },
      recargar: cargarCatalogo,
    },
    unidades: {
      foto: () => ({ sucursales: S.leerRemoto('sucursales', []) }),
      enviar: function (antes, despues) {
        const previas = {};
        antes.sucursales.forEach((u) => (previas[String(u.id)] = u));
        const cambiadas = diferencia(antes.sucursales, despues.sucursales).cambiados;
        if (!cambiadas.length) return undefined;
        return cambiadas.map((u) => rpc('guardar_unidad', { p_unidad: aUnidadBase(u, previas[String(u.id)]) }));
      },
      recargar: cargarCatalogo,
    },
    usuarios: {
      foto: () => ({ usuarios: S.leerRemoto('usuarios', []) }),
      enviar: function (antes, despues) {
        const previos = {};
        antes.usuarios.forEach((u) => (previos[String(u.id)] = u));
        const cambiados = diferencia(antes.usuarios, despues.usuarios).cambiados;
        if (!cambiados.length) return undefined;
        return cambiados.map((u) => rpc('guardar_usuario', { p_usuario: aUsuarioBase(u, previos[String(u.id)]) }));
      },
      recargar: cargarUsuarios, // además borra de la memoria el PIN que se escribió
    },
  };

  function sincronizada(nombre, original, tipo) {
    const t = TIPOS_SINCRONIZACION[tipo || 'catalogo'];
    return function () {
      if (caido) throw new Error('No hay conexión con la base de datos. Recarga la página.');
      if (!token()) throw new Error('Tu sesión venció. Vuelve a entrar.');

      const antes = t.foto();
      let resultado;
      let respuesta;
      try {
        resultado = original.apply(null, arguments);
        respuesta = t.enviar(antes, t.foto());
        if (respuesta === undefined) return resultado;
      } catch (e) {
        S.cargarRemoto(antes); // nada a medias en pantalla
        throw e;
      }

      try {
        t.recargar(); // ids definitivos de lo que se acaba de crear
      } catch (e) {
        /* ya quedó guardado; el siguiente refresco lo pone al día */
      }

      // Si la base ocultó un producto en vez de borrarlo, la pantalla lo dice
      if (nombre === 'borrarPlatoCarta' && respuesta && (respuesta.desactivados || []).length) {
        return { eliminado: false, desactivado: true };
      }
      return resultado;
    };
  }

  /* Lo que todavía no escribe en la base: en vez de guardarse en memoria y
     perderse al recargar, avisa. */
  const SOLO_LECTURA = [
    'resetCarta', 'resetStock', 'borrarCierre', 'borrarComprobante', 'importar', 'borrarTodo', 'restablecerConfig',
  ];

  function soloLectura(nombre) {
    return function () {
      if (nombre === 'resetCarta') {
        throw new Error(
          'Con la base de datos la carta no vuelve a la de fábrica: edita, oculta o elimina los productos uno por uno.'
        );
      }
      if (nombre === 'resetStock') {
        throw new Error(
          'Con la base de datos el stock no vuelve al de fábrica: edita o desactiva los productos uno por uno.'
        );
      }
      if (nombre === 'borrarCierre') {
        throw new Error('Con la base de datos los cierres no se borran: se corrigen mientras no estén revisados.');
      }
      throw new Error(
        'En modo base de datos esta acción todavía no está disponible (fase 2). ' +
          'Hazla desde DBeaver o abre la aplicación con ?backend=local.'
      );
    };
  }

  /* =====================================================================
     AVISO DE CONEXIÓN
     ===================================================================== */
  function avisar(texto) {
    function pintar() {
      if (document.getElementById('avisoRemoto')) return;
      const d = document.createElement('div');
      d.id = 'avisoRemoto';
      d.setAttribute('role', 'alert');
      d.style.cssText =
        'position:fixed;left:0;right:0;bottom:0;z-index:9000;padding:12px 16px;background:#a30020;color:#fff;' +
        'font:14px/1.4 system-ui,sans-serif;text-align:center;box-shadow:0 -6px 20px rgba(0,0,0,.4)';
      d.innerHTML = texto;
      document.body.appendChild(d);
    }
    if (document.body) pintar();
    else document.addEventListener('DOMContentLoaded', pintar);
  }

  /* =====================================================================
     CONFIGURACIÓN, AJUSTES Y PANEL DE TASECA (fase 2 · bloque 5)
     ===================================================================== */

  /* Lo que se descarga según quién está conectado. */
  function cargarDatosDeSesion() {
    const s = S.getSesion();
    if (s && s.scope === 'platform' && (!s.empresaContext || PAGINA_PLATAFORMA)) {
      // SuperAdmin sin empresa elegida: no hay operación de ningún negocio
      S.cargarRemoto({ pedidos: [], usuarios: [], stock: [], cierres: [], entradas: [], gastos: [], bases: [] });
      cargarPlataforma();
      return;
    }
    cargarPedidos();
    cargarUsuarios();
    cargarInventario();
    cargarCaja();
  }

  function colorLargo(c) {
    const v = String(c || '').trim();
    return /^#[0-9a-f]{3}$/i.test(v) ? '#' + v[1] + v[1] + v[2] + v[2] + v[3] + v[3] : v;
  }

  function temaParaBase(t, anterior) {
    const x = {
      primary: colorLargo(t.primary),
      secondary: colorLargo(t.secondary),
      accent: colorLargo(t.accent),
      background: colorLargo(t.background),
      fontFamily: t.fontFamily || '',
      logoTexto: t.logoTexto || '',
      logoAcento: t.logoAcento || '',
      iniciales: t.iniciales || '',
      lema: t.lema || '',
    };
    // Las imágenes sólo viajan si cambiaron
    const logo = typeof t.logo === 'string' ? t.logo : '';
    const favicon = typeof t.favicon === 'string' ? t.favicon : '';
    if (!anterior || logo !== (anterior.logo || '')) x.logo = logo;
    if (!anterior || favicon !== (anterior.favicon || '')) x.favicon = favicon;
    return x;
  }

  function fichaParaBase(e) {
    return {
      nombre_comercial: e.nombre,
      razon_social: e.razonSocial || '',
      nit: e.nit || '',
      telefono: e.telefono || '',
      whatsapp: e.whatsapp || '',
      email: e.email || '',
      activa: e.activa !== false,
    };
  }

  function exigirPlataforma() {
    if (!esPlataformaConectada()) throw new Error('Sólo la plataforma Taseca puede hacer esto.');
  }

  let cacheFacturas = null;

  const configuracion = {
    /* Datos del negocio y métodos de pago (⚙️ Configuración). */
    guardarConfig: function (cambios) {
      cambios = cambios || {};
      const soloMetodos = Object.keys(cambios).length === 1 && cambios.metodosPago;

      if (!soloMetodos) {
        const c = S.getConfig();
        const val = (k) => (cambios[k] !== undefined ? cambios[k] : c[k]);
        const contacto = Object.assign({}, c.contacto, cambios.contacto || {});
        const pago = Object.assign({}, c.pago, cambios.pago || {});
        const tiempos = Object.assign({}, c.tiempos, cambios.tiempos || {});
        const redes = Object.assign({}, c.redes, cambios.redes || {});
        const cuentas = [['Nequi', pago.nequi], ['Daviplata', pago.daviplata], ['Bancolombia', pago.bancolombia]]
          .filter((x) => x[1] && String(x[1]).trim())
          .map((x) => ({ entidad: x[0], numero: String(x[1]).trim(), titular: pago.titular || '' }));
        rpc('guardar_configuracion', {
          p_datos: {
            nombre_comercial: val('marca'),
            eslogan: val('eslogan'),
            descripcion: val('descripcion'),
            nit: pago.nit,
            telefono: contacto.telefono,
            whatsapp: contacto.whatsapp,
            email: contacto.email,
            direccion: contacto.direccion,
            horario_general: contacto.horarioGeneral,
            tiempo_mesa: tiempos.mesa,
            tiempo_domicilio: tiempos.domicilio,
            instagram_url: redes.instagram,
            facebook_url: redes.facebook,
            hora_corte_operativa: val('horaCorteOperativa'),
          },
          p_cuentas: cuentas,
        });
      }
      if (cambios.metodosPago) {
        rpc('guardar_metodos_pago', {
          p_metodos: cambios.metodosPago.map((m) => ({ codigo: m.id, activo: !!m.activo, descripcion: m.descripcion || null })),
        });
      }
      cargarCatalogo();
      return S.getConfig();
    },

    /* 🧹 Ajustes → facturas de prueba. En la base todas tienen el código
       corto: "las del formato anterior" son siempre cero. */
    contarFacturasPrueba: function (alcance) {
      const cero = { pedidos: 0, entradas: 0 };
      if (alcance !== 'todas' || !token() || caido) return cero;
      if (NASCAR.Auth && !NASCAR.Auth.puede('pedidos_anular')) return cero;
      // El panel lo repinta con cada cambio: se pregunta como mucho una vez por minuto
      if (cacheFacturas && Date.now() - cacheFacturas.ts < 60000) return cacheFacturas.valor;
      try {
        const v = rpc('facturas_prueba');
        cacheFacturas = { ts: Date.now(), valor: { pedidos: n(v.pedidos), entradas: n(v.entradas) } };
        return cacheFacturas.valor;
      } catch (e) {
        return cero;
      }
    },

    borrarFacturasPrueba: function (alcance, confirmacion) {
      if (alcance !== 'todas') return { pedidos: 0, entradas: 0 };
      const r = rpc('borrar_facturas_prueba', { p_confirmacion: confirmacion || '' });
      cacheFacturas = null;
      cargarPedidos();
      despuesDeInventario();
      return { pedidos: n(r.pedidos), entradas: n(r.entradas) };
    },

    /* 🛠️ Panel de Taseca. */
    setEmpresaContexto: function (codigo) {
      const ses = S.getSesion();
      if (!ses || ses.scope !== 'platform') throw new Error('Sólo la plataforma administra empresas.');
      const r = rpc('entrar_empresa', { p_empresa: codigo || null });
      S.establecerSesion(Object.assign({}, ses, { empresaContext: codigo || null, token: r.token, expira: r.expira }));
      return codigo || null;
    },

    salirDeEmpresa: function () {
      return S.setEmpresaContexto(null);
    },

    guardarEmpresa: function (datos, opciones) {
      if (!opciones || !opciones.superadmin)
        throw new Error('Los datos de la empresa se cambian desde ⚙️ Configuración.');
      exigirPlataforma();
      const actual = S.getEmpresa(datos.id);
      if (!actual) throw new Error('Esa empresa no existe.');
      rpc('guardar_empresa', { p_empresa: datos.id, p_datos: fichaParaBase(Object.assign({}, actual, datos)) });
      cargarPlataforma();
      return S.getEmpresas({ todas: true });
    },

    activarEmpresa: function (codigo, activa, opciones) {
      return S.guardarEmpresa({ id: codigo, activa: !!activa }, opciones);
    },

    setModulos: function (codigo, modulos, opciones) {
      if (!opciones || opciones.superadmin !== true)
        throw new Error('Sólo el SuperAdmin puede cambiar los módulos de una empresa.');
      exigirPlataforma();
      Object.keys(modulos || {}).forEach(function (m) {
        rpc('modulo_empresa', { p_empresa: codigo, p_modulo: m, p_activo: !!modulos[m] });
      });
      cargarPlataforma();
      return S.getModulos(codigo);
    },

    setTheme: function (codigo, theme, opciones) {
      if (!opciones || opciones.superadmin !== true)
        throw new Error('Sólo el SuperAdmin puede cambiar el tema de una empresa.');
      exigirPlataforma();
      const actual = S.getEmpresa(codigo);
      rpc('guardar_tema_empresa', { p_empresa: codigo, p_tema: temaParaBase(theme || {}, actual && actual.theme) });
      cargarPlataforma();
      return S.getTheme(codigo);
    },

    altaEmpresa: function (d, opciones) {
      if (!opciones || opciones.superadmin !== true)
        throw new Error('Sólo el SuperAdmin puede dar de alta una empresa.');
      exigirPlataforma();
      d = d || {};
      const tipos = (NASCAR.TIPOS_NEGOCIO || []).map((t) => t.id);
      const tipo = tipos.indexOf(d.tipoNegocio) >= 0 ? d.tipoNegocio
        : tipos.indexOf(d.plantilla) >= 0 ? d.plantilla
        : d.plantilla === 'comercio' ? 'otro' : 'restaurante';
      const admin = d.admin && d.admin.usuario ? d.admin : null;

      const r = rpc('alta_empresa', {
        p_datos: Object.assign(fichaParaBase({
          nombre: d.nombre, razonSocial: d.razonSocial, nit: d.nit, telefono: d.telefono,
          whatsapp: d.whatsapp, email: d.email, activa: d.activa,
        }), {
          direccion: d.direccion || '',
          ciudad: d.ciudad || '',
          plantilla: d.plantilla || '',
          tipo_negocio: tipo,
          modulos: d.modulos || {},
          tema: temaParaBase(d.theme || {}, null),
          admin: admin ? { nombre: admin.nombre, usuario: admin.usuario, pin: admin.pin } : null,
        }),
      });
      cargarPlataforma();
      return {
        empresa: S.getEmpresa(r.codigo),
        sucursal: null,
        usuario: admin ? { usuario: String(admin.usuario).trim().toLowerCase(), nombre: admin.nombre } : null,
      };
    },
  };

  /* =====================================================================
     ARRANQUE
     ===================================================================== */
  function iniciar() {
    S.usarClavesRemotas(CLAVES);
    Object.keys(operaciones).forEach((k) => (S[k] = operaciones[k]));
    SINCRONIZADAS.forEach((k) => (S[k] = sincronizada(k, S[k], 'catalogo')));
    SINCRONIZADAS_UNIDADES.forEach((k) => (S[k] = sincronizada(k, S[k], 'unidades')));
    SINCRONIZADAS_USUARIOS.forEach((k) => (S[k] = sincronizada(k, S[k], 'usuarios')));
    Object.keys(inventario).forEach((k) => (S[k] = inventario[k]));
    const caja = crearCaja({ getGastos: S.getGastos, resumenGastos: S.resumenGastos, informeCaja: S.informeCaja });
    Object.keys(caja).forEach((k) => (S[k] = caja[k]));
    SOLO_LECTURA.forEach((k) => (S[k] = soloLectura(k)));

    Object.keys(configuracion).forEach((k) => (S[k] = configuracion[k]));

    try {
      cargarCatalogo();
      try {
        cargarDatosDeSesion();
      } catch (e) {
        // Token vencido o inválido: se entra de nuevo
        S.establecerSesion(null);
        S.cargarRemoto({ pedidos: [], usuarios: [], stock: [], cierres: [], entradas: [], gastos: [], bases: [] });
      }
    } catch (e) {
      caido = true;
      console.error('[Remoto]', e);
      S.cargarRemoto({
        sucursales: [], categorias: [], cartaV2: [], menusDia: [], dia: [], pedidos: [], usuarios: [],
        stock: [], cierres: [], entradas: [], gastos: [], bases: [],
      });
      const detalle = /No hay conexión/.test(e.message || '') ? '' : ' ' + e.message;
      avisar(
        '<b>No hay conexión con la base de datos.</b>' + detalle +
          ' Inicia <code>iniciar-postgrest.bat</code> y recarga, o ' +
          '<a href="?backend=local" style="color:#fff;text-decoration:underline">trabaja en modo local</a>.'
      );
      return;
    }

    setInterval(refrescarPedidos, CFG.refrescoPedidosMs);
    setInterval(refrescarCatalogo, CFG.refrescoCatalogoMs);
    // Al volver a la pestaña se ponen al día de inmediato
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden) refrescarPedidos();
    });
  }

  if (activo) iniciar();

  return {
    activo: activo,
    get caido() {
      return caido;
    },
    get empresa() {
      return empresa;
    },
    /* auth.js pregunta antes de conceder un permiso. */
    permisoDisponible: function (permiso) {
      return !activo || PERMISOS_FASE_2.indexOf(permiso) < 0;
    },
    asegurarHistorial: asegurarHistorial,
    /* Al entrar a Stock, Cierres o Entradas: se pone al día si algo cambió. */
    refrescarInventario: function () {
      if (activo) refrescarInventario(true);
    },
    /* Al entrar a Gastos o al Cruce de caja. */
    refrescarCaja: function () {
      if (activo) refrescarCaja(true);
    },
    refrescar: function () {
      refrescarCatalogo();
      refrescarPedidos();
    },
  };
})();
