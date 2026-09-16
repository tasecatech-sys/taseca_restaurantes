/* ==========================================================================
   NASCAR · store.js
   Capa de persistencia y reglas de negocio.

   TODO el resto de la app habla ÚNICAMENTE con Store.*  — nunca con
   localStorage directamente. Así, el día que exista un backend real,
   sólo se reescribe este archivo (cambiando los métodos por fetch()) y
   las pantallas siguen funcionando igual.
   ========================================================================== */

window.NASCAR = window.NASCAR || {};

NASCAR.Store = (function () {
  'use strict';

  const K = {
    pedidos: 'nascar.pedidos.v1',
    dia: 'nascar.platosdia.v1',
    menusDia: 'nascar.menusdia.v1', // modalidad del menú del día por sucursal y fecha
    carta: 'nascar.cartaOverrides.v1',
    seq: 'nascar.consecutivo.v1',
    sesion: 'nascar.sesionAdmin.v1',
    seed: 'nascar.semillaAplicada.v1',
    cierres: 'nascar.cierres.v1',
    entradas: 'nascar.entradas.v1',
    // --- configuración administrable ---
    config: 'nascar.config.v1',
    sucursales: 'nascar.sucursales.v1', // las UNIDADES / LOCALES de cada empresa
    unidadActiva: 'nascar.unidadActiva.v1', // unidad en la que se trabaja, por empresa
    categorias: 'nascar.categorias.v1',
    cartaV2: 'nascar.carta.v2',
    stock: 'nascar.stock.v1',
    usuarios: 'nascar.usuarios.v1',
    comprobantes: 'nascar.comprobantes.v1',
    gastos: 'nascar.gastos.v1',
    bases: 'nascar.bases.v1',
    empresas: 'nascar.empresas.v1',
    empresaActual: 'nascar.empresaActual.v1',
    sesionUsuario: 'nascar.sesionUsuario.v1',
    migracion: 'nascar.migracion.v1',
  };

  /* ---------------------------------------------------------------
     Almacenamiento

     Se usa localStorage. Si el navegador lo bloquea —pasa al abrir un
     archivo local en algunos celulares, y en modo incógnito— se cae a una
     copia en memoria: la app sigue funcionando completa, pero los datos se
     pierden al cerrar la pestaña. Se avisa una sola vez.
     --------------------------------------------------------------- */
  const memoria = {};
  let usaMemoria = false;

  (function comprobarAlmacenamiento() {
    try {
      const p = '__nascar_prueba__';
      localStorage.setItem(p, '1');
      localStorage.removeItem(p);
    } catch (e) {
      usaMemoria = true;
      console.warn('[Store] localStorage no disponible; se usa memoria temporal.', e);
    }
  })();

  function almacenamientoEsTemporal() {
    return usaMemoria;
  }

  /* ---- Puente con la base de datos (lo usa sólo js/remoto.js) ---- */

  /* nombres = ['pedidos', 'cartaV2', …] (los de K). Desde aquí esas claves
     se leen y escriben en memoria, empezando vacías. */
  function usarClavesRemotas(nombres) {
    nombres.forEach(function (n) {
      if (!K[n]) throw new Error('Clave desconocida: ' + n);
      clavesRemotas[K[n]] = true;
      delete memoria[K[n]];
    });
  }

  /* datos = { pedidos: [...], sucursales: [...] }. Reemplaza el contenido,
     reconstruye los globales NASCAR.* y avisa a las pantallas. */
  function cargarRemoto(datos) {
    Object.keys(datos).forEach(function (n) {
      if (!K[n] || !clavesRemotas[K[n]]) throw new Error('No es una clave remota: ' + n);
      memoria[K[n]] = JSON.stringify(datos[n]);
    });
    hidratar();
    emitir();
  }

  function leerRemoto(nombre, porDefecto) {
    return leer(K[nombre], porDefecto);
  }

  /* Claves que llegan de la base de datos (modo PostgREST, js/remoto.js):
     viven SÓLO en memoria. Así los datos del servidor nunca pisan lo que
     este navegador tiene guardado en modo local. */
  const clavesRemotas = {};

  function enMemoria(key) {
    return usaMemoria || clavesRemotas[key] === true;
  }

  function leer(key, porDefecto) {
    try {
      const raw = enMemoria(key) ? memoria[key] : localStorage.getItem(key);
      if (raw === null || raw === undefined) return porDefecto;
      return JSON.parse(raw);
    } catch (e) {
      console.warn('[Store] No se pudo leer', key, e);
      return porDefecto;
    }
  }

  let yaAviso = false;

  function escribir(key, valor) {
    const texto = JSON.stringify(valor);
    try {
      if (enMemoria(key)) memoria[key] = texto;
      else localStorage.setItem(key, texto);
      emitir();
      return true;
    } catch (e) {
      // Cuota llena o permiso revocado a mitad de camino: se sigue en memoria.
      console.error('[Store] No se pudo guardar', key, e);
      usaMemoria = true;
      memoria[key] = texto;
      emitir();
      if (!yaAviso) {
        yaAviso = true;
        setTimeout(function () {
          alert(
            'Este navegador no permite guardar información de forma permanente.\n\n' +
              'La aplicación funciona igual, pero los pedidos se perderán al cerrar ' +
              'la pestaña. Para conservarlos, ábrela desde un servidor web en vez ' +
              'de como archivo local.'
          );
        }, 400);
      }
      return true;
    }
  }

  /* Notificación de cambios: misma pestaña (evento propio) y
     otras pestañas del mismo navegador (evento storage). */
  const CANAL = 'nascar:cambio';
  function emitir() {
    window.dispatchEvent(new CustomEvent(CANAL));
  }
  function onChange(cb) {
    window.addEventListener(CANAL, cb);
    window.addEventListener('storage', function (e) {
      if (e.key && e.key.indexOf('nascar.') === 0) cb();
    });
  }

  /* ---------------------------------------------------------------
     Fechas (siempre en horario local, formato YYYY-MM-DD)
     --------------------------------------------------------------- */
  function hoy() {
    return aISO(new Date());
  }
  function aISO(d) {
    const p = (n) => String(n).padStart(2, '0');
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
  }
  function desdeISO(iso) {
    const [a, m, d] = iso.split('-').map(Number);
    return new Date(a, m - 1, d);
  }

  /* ---------------------------------------------------------------
     FECHA OPERATIVA

     El restaurante cierra de madrugada, así que la fecha del reloj no
     sirve para decidir a qué jornada pertenece algo. Un pedido tomado a
     la 1:30 a.m. del 29 es parte de la jornada del 28.

     fechaOperativaDe() traduce un instante real a la jornada a la que
     pertenece, restando un día a todo lo anterior a la hora de corte.

     OJO: esto es sólo para inventario y cierres. Los reportes de ventas
     que ya existían siguen usando la fecha calendario (pedido.fecha),
     que es lo que la administradora ya conoce.
     --------------------------------------------------------------- */
  function horaCorte() {
    const h = NASCAR.CONFIG && NASCAR.CONFIG.horaCorteOperativa;
    return typeof h === 'number' ? h : 6;
  }

  function fechaOperativaDe(instante) {
    const d = instante ? new Date(instante) : new Date();
    if (isNaN(d.getTime())) return hoy();
    if (d.getHours() < horaCorte()) d.setDate(d.getDate() - 1);
    return aISO(d);
  }

  /* Jornada a la que pertenece este momento. Es lo que se propone por
     defecto en la pantalla de cierre, pero la persona puede cambiarlo. */
  function hoyOperativo() {
    return fechaOperativaDe(new Date());
  }

  /* Jornada de un pedido. Los pedidos creados antes de que existiera este
     módulo no tienen el campo guardado: se deduce de la hora de creación. */
  function fechaOperativaPedido(pedido) {
    return pedido.fechaOperativa || fechaOperativaDe(pedido.creado);
  }

  /* ---------------------------------------------------------------
     Consecutivo de pedidos / facturas  ->  00027
     --------------------------------------------------------------- */
  /* Un número corto de 5 dígitos, fácil de dictar por teléfono.

     · Es UNO por empresa, compartido por todos sus locales: si cada local
       contara desde 1, dos pedidos distintos tendrían el mismo código y el
       seguimiento no sabría cuál mostrar. El local ya va en el pedido.
     · Arrancó de cero con este formato (clave 'empresa|facturas'). Los
       pedidos anteriores conservan su código largo (N1-260828-001): no se
       reescriben, y no pueden chocar con uno de sólo dígitos.
     · Nunca se entrega un código que ya exista (p. ej. tras restaurar un
       respaldo): se salta al siguiente libre.
     · Las demás empresas llevan su etiqueta al final (00027-ACME). */
  const DIGITOS_CODIGO = 5;

  function siguienteCodigo(sucursalId, empresaId) {
    const eid = empresaId || empresaActivaId();
    const seq = leer(K.seq, {});
    const clave = eid + '|facturas';
    const usados = leer(K.pedidos, [])
      .filter((p) => (p.empresaId || EMPRESA_DEFECTO) === eid)
      .map((p) => p.codigo);
    let n = seq[clave] || 0;
    let codigo;
    do {
      n++;
      codigo = String(n).padStart(DIGITOS_CODIGO, '0') + tagEmpresa(eid);
    } while (usados.indexOf(codigo) >= 0);
    seq[clave] = n;
    escribir(K.seq, seq);
    return codigo;
  }

  function id() {
    return Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
  }

  function clonar(x) {
    return JSON.parse(JSON.stringify(x));
  }

  /* ===============================================================
     CONFIGURACIÓN ADMINISTRABLE

     data.js sigue siendo la fuente de los valores iniciales. Lo que el
     administrador guarda desde el panel vive en localStorage y TIENE
     PRIORIDAD sobre esos valores.

     Para que las pantallas no tengan que cambiar, al arrancar se
     "rehidratan" los globales NASCAR.CONFIG / SUCURSALES / CATEGORIAS /
     CARTA / INVENTARIO con la versión ya combinada. Así una vista que
     lee NASCAR.CATEGORIAS ve automáticamente lo que el admin configuró,
     y sigue existiendo una sola fuente de verdad: este archivo.
     =============================================================== */

  // Copia intacta de lo que trae data.js, antes de tocar nada.
  const DEFAULTS = {
    config: clonar(NASCAR.CONFIG),
    sucursales: clonar(NASCAR.SUCURSALES),
    categorias: clonar(NASCAR.CATEGORIAS),
    carta: clonar(NASCAR.CARTA),
    stock: clonar(NASCAR.INVENTARIO || []),
    usuarios: clonar(NASCAR.USUARIOS_INICIALES || []),
    usuariosPlataforma: clonar(NASCAR.USUARIOS_PLATAFORMA || []),
    empresas: clonar(NASCAR.EMPRESAS || []),
  };

  /* ===============================================================
     EMPRESAS

     Todo registro lleva `empresaId` y todas las consultas filtran por
     la empresa activa. Así los mismos archivos atienden a varias
     empresas sin que sus datos se toquen.

     La empresa activa se guarda en localStorage: al recargar se vuelve
     a la misma. Entrar con un usuario cambia a la empresa de ese usuario.
     =============================================================== */
  const EMPRESA_DEFECTO = NASCAR.EMPRESA_POR_DEFECTO || 'empresa_nascar';

  /* ---------------------------------------------------------------
     LOS DOS NIVELES DEL SISTEMA

       NIVEL 1 · PLATAFORMA (Taseca)  ->  scope 'platform'
         Administra empresas, módulos y accesos. NO pertenece a ninguna
         empresa cliente: su `empresaId` es null.

       NIVEL 2 · EMPRESA CLIENTE (NASCAR, y las que vengan) -> scope 'empresa'
         El restaurante: pedidos, carta, stock, cierre, gastos, usuarios.

     La pertenencia se marca con `scope`, no con un empresaId inventado.
     Un usuario de plataforma tiene empresaId null y no aparece en
     ninguna consulta por empresa.
     --------------------------------------------------------------- */
  const SCOPE_PLATAFORMA = 'platform';
  const SCOPE_EMPRESA = 'empresa';

  /* Marca de empresa que usaban los usuarios de plataforma antes de que
     existiera `scope`. Se conserva sólo para reconocer instalaciones
     anteriores; los registros nuevos ya no la llevan. */
  const PLATAFORMA = NASCAR.EMPRESA_PLATAFORMA || '*plataforma*';

  /* Versión del formato de datos guardado.
       3 = multiempresa (cada registro lleva empresaId)
       4 = módulos canónicos (basico / stock / cierre)
       5 = usuarios de plataforma (SuperAdmin)
       6 = plataforma separada de las empresas (scope)
       7 = tema de empresa (theme) separado de los módulos
       8 = unidades / locales */
  const VERSION_DATOS = 10; // 10: los locales reales también en instalaciones viejas

  function getEmpresas(opciones) {
    opciones = opciones || {};
    const lista = (leer(K.empresas, null) || clonar(DEFAULTS.empresas)).map(function (e) {
      /* Los módulos y la identidad se devuelven siempre en su forma
         canónica, venga la empresa de donde venga (data.js, respaldo
         antiguo, migración). */
      return Object.assign({}, e, {
        modulos: normalizarModulos(e.modulos),
        theme: normalizarTheme(e.theme, e.nombre),
      });
    });
    return opciones.todas ? lista : lista.filter((e) => e.activa !== false);
  }

  function getEmpresa(empresaId) {
    return getEmpresas({ todas: true }).find((e) => e.id === empresaId) || null;
  }

  /* Id de la empresa activa. Si la guardada ya no existe o se desactivó,
     se cae a la primera activa: nunca se devuelve algo inválido. */
  function existeYActiva(empresaId) {
    return getEmpresas({ todas: true }).some(
      (e) => e.id === empresaId && e.activa !== false
    );
  }

  /**
   * Qué empresa se está mirando ahora mismo.
   *
   * Hay DOS fuentes, y el orden importa:
   *
   *   1. El CONTEXTO del SuperAdmin de Taseca. Cuando entra a
   *      administrar una empresa, la elección vive en su sesión y muere
   *      con ella. No pisa lo que ven los usuarios de esa empresa ni
   *      queda escrito en localStorage.
   *
   *   2. La empresa guardada, que es la del usuario de empresa normal.
   *
   * Así el nivel plataforma y el nivel empresa no se estorban.
   */
  function empresaActivaId() {
    const ses = getSesion();
    if (ses && ses.scope === SCOPE_PLATAFORMA) {
      // Un SuperAdmin sin empresa elegida no está mirando ninguna.
      if (ses.empresaContext && existeYActiva(ses.empresaContext)) return ses.empresaContext;
    }

    const guardada = leer(K.empresaActual, null);
    if (guardada && existeYActiva(guardada)) return guardada;
    const activas = getEmpresas({ todas: true }).filter((e) => e.activa !== false);
    return activas.length ? activas[0].id : EMPRESA_DEFECTO;
  }

  /* La empresa que el SuperAdmin está administrando, o null si está en
     el panel de Taseca sin haber entrado a ninguna. */
  function getEmpresaContexto() {
    const ses = getSesion();
    if (!ses || ses.scope !== SCOPE_PLATAFORMA) return null;
    return ses.empresaContext || null;
  }

  /**
   * El SuperAdmin entra a administrar una empresa.
   *
   * Esto NO lo convierte en usuario de esa empresa: su rol sigue siendo
   * superadmin y su scope sigue siendo platform. Lo único que cambia es
   * qué datos está mirando.
   */
  function setEmpresaContexto(empresaId) {
    const ses = getSesion();
    if (!ses || ses.scope !== SCOPE_PLATAFORMA)
      throw new Error('Sólo la plataforma administra empresas.');

    if (empresaId) {
      const e = getEmpresa(empresaId);
      if (!e) throw new Error('Esa empresa no existe.');
      if (e.activa === false) throw new Error('Esa empresa está desactivada.');
    }

    guardarSesion(Object.assign({}, ses, { empresaContext: empresaId || null }));
    hidratar(); // los globales NASCAR.* pasan a ser los de esta empresa
    return empresaId || null;
  }

  /* Volver a Taseca: se suelta la empresa, la sesión sigue viva. */
  function salirDeEmpresa() {
    return setEmpresaContexto(null);
  }

  function getEmpresaActual() {
    return getEmpresa(empresaActivaId());
  }

  function setEmpresaActual(empresaId) {
    const e = getEmpresa(empresaId);
    if (!e) throw new Error('Esa empresa no existe.');
    if (e.activa === false) throw new Error('Esa empresa está desactivada.');
    escribir(K.empresaActual, empresaId);
    hidratar(); // los globales NASCAR.* pasan a ser los de esta empresa
    return e;
  }

  function guardarEmpresa(datos, opciones) {
    const comoSuper = !!(opciones && opciones.superadmin);
    const lista = getEmpresas({ todas: true });
    const i = lista.findIndex((e) => e.id === datos.id);

    /* La marca de SuperAdmin no basta cuando hay alguien conectado: si
       la sesión es la de un Admin de restaurante, no pasa por más que la
       mande. Sin sesión sí se permite, que es como se siembran los datos
       y como trabaja la consola en desarrollo. Mismo criterio que
       setModulos(). */
    if (comoSuper) {
      const sesion = getSesion();
      if (sesion && sesion.rol !== 'superadmin')
        throw new Error('Sólo el SuperAdmin puede crear o editar otras empresas.');
    } else {
      /* Sin la marca, esta función es la puerta del panel de la empresa
         y sólo puede tocar SU PROPIA ficha: ni crear empresas, ni editar
         la de al lado. El Admin de NASCAR no administra a nadie más. */
      const activa = empresaActivaId();
      if (!datos.id || datos.id !== activa)
        throw new Error('Sólo el SuperAdmin puede crear o editar otras empresas.');

      /* Y dentro de la empresa tampoco vale cualquiera: la ficha —nombre
         comercial, razón social, NIT— es configuración sensible, del
         mismo nivel que los datos del local. Sin esto, un mesero o una
         caja podían renombrar su propia empresa. */
      const sesion = getSesion();
      if (sesion && NASCAR.Auth && !NASCAR.Auth.puede('config_local', sesion))
        throw new Error('Tu perfil no puede editar los datos de la empresa.');
    }

    /* El nombre se exige al CREAR. Al editar sólo se comprueba si viene,
       porque hay cambios que no lo tocan —activar y desactivar, por
       ejemplo— y no tienen por qué mandarlo entero. */
    if (i < 0 || datos.nombre !== undefined) {
      if (!datos.nombre || String(datos.nombre).trim().length < 2)
        throw new Error('La empresa necesita un nombre comercial.');
    }

    /* Los módulos tampoco se tocan desde el panel de la empresa: el
       Admin no puede darse a sí mismo un módulo que no contrató. */
    const datosSeguros = Object.assign({}, datos);
    if (!comoSuper) {
      delete datosSeguros.modulos;
      delete datosSeguros.theme;
    }
    datos = datosSeguros;

    if (i >= 0) {
      lista[i] = Object.assign({}, lista[i], datos, {
        id: lista[i].id,
        modulos: normalizarModulos(comoSuper && datos.modulos ? datos.modulos : lista[i].modulos),
        theme: normalizarTheme(
          comoSuper && datos.theme ? datos.theme : lista[i].theme,
          datos.nombre || lista[i].nombre
        ),
      });
    } else {
      // Id estable: no se deriva del nombre, que puede cambiar
      const nuevoId = datos.id || 'empresa_' + id();
      if (lista.some((e) => e.id === nuevoId))
        throw new Error('Ya existe una empresa con el id ' + nuevoId + '.');
      lista.push(
        Object.assign(
          {
            razonSocial: '', nit: '', telefono: '', whatsapp: '', email: '',
            activa: true,
          },
          datos,
          {
            id: nuevoId,
            creada: new Date().toISOString(),
            /* Se inicializan únicamente los módulos habilitados. Si nadie
               dice nada, la empresa arranca sólo con lo básico. */
            modulos: normalizarModulos(comoSuper ? datos.modulos : null),
            /* Y con un tema: el que venga, o el base de Taseca. Nunca se
               hereda el de otra empresa. */
            theme: normalizarTheme(comoSuper ? datos.theme : null, datos.nombre),
          }
        )
      );
    }
    escribir(K.empresas, lista);

    /* Una empresa recién creada no tiene ni una sede, y el panel da por
       hecho que hay al menos una: sin ella no se puede tomar un pedido,
       ni registrar un gasto, ni cerrar inventario. Se le crea la primera
       con el nombre de la empresa, para que se pueda entrar y trabajar
       desde el minuto uno. El administrador la renombra desde
       ⚙️ Configuración → 📍 Sucursales. */
    if (i < 0) {
      const creada = lista[lista.length - 1];
      if (!soloDeEmpresa(leer(K.sucursales, []) || [], creada.id).length) {
        guardarSucursal(
          {
            nombre: creada.nombre + ' · Sede principal',
            corto: 'Principal',
            telefono: creada.telefono || '',
            whatsapp: creada.whatsapp || '',
            mesas: 10,
            activa: true,
          },
          creada.id
        );
      }
    }

    hidratar();
    return lista;
  }

  /**
   * ALTA COMPLETA DE UNA EMPRESA CLIENTE
   *
   * Lo que hace el asistente del panel de Taseca en una sola llamada.
   * Al terminar, la empresa está lista para trabajar sin que nadie tenga
   * que tocar código, copiar carpetas ni duplicar HTML:
   *
   *   1. Id único y estable (no derivado del nombre, que puede cambiar).
   *   2. Sus módulos, sólo los marcados.
   *   3. Su tema: el de la plantilla elegida, o el base de Taseca.
   *   4. Su primera sede, con la dirección y la ciudad que se den.
   *   5. Su configuración propia, partiendo de los valores de fábrica.
   *   6. Opcionalmente, su administrador inicial.
   *
   * AISLAMIENTO: la empresa nueva NO hereda nada. Ni pedidos, ni ventas,
   * ni gastos, ni stock, ni cierres, ni usuarios, ni la configuración de
   * otra empresa. Todo lo suyo se crea desde cero, y lo que no se crea
   * simplemente no existe todavía.
   */
  function altaEmpresa(datos, opciones) {
    opciones = opciones || {};
    if (opciones.superadmin !== true)
      throw new Error('Sólo el SuperAdmin puede dar de alta una empresa.');

    const d = datos || {};
    if (!d.nombre || String(d.nombre).trim().length < 2)
      throw new Error('La empresa necesita un nombre comercial.');

    /* El administrador inicial se valida ANTES de crear nada: si el
       acceso está repetido, mejor fallar aquí que dejar una empresa a
       medio montar. */
    const admin = d.admin && d.admin.usuario ? d.admin : null;
    if (admin) {
      if (!admin.nombre || String(admin.nombre).trim().length < 2)
        throw new Error('El administrador inicial necesita un nombre.');
      if (String(admin.usuario).trim().length < 3)
        throw new Error('El acceso del administrador debe tener al menos 3 caracteres.');
      if (!/^\d{4,6}$/.test(String(admin.pin || '')))
        throw new Error('El PIN del administrador debe tener entre 4 y 6 dígitos.');
      const acceso = String(admin.usuario).trim().toLowerCase();
      if (usuariosCrudos().some((u) => String(u.usuario).toLowerCase() === acceso))
        throw new Error('Ya existe un usuario con el acceso "' + acceso + '".');
    }

    // 1-3. La ficha, con sus módulos y su tema
    guardarEmpresa(
      {
        nombre: d.nombre,
        razonSocial: d.razonSocial || '',
        nit: d.nit || '',
        telefono: d.telefono || '',
        whatsapp: d.whatsapp || '',
        email: d.email || '',
        activa: d.activa !== false,
        modulos: d.modulos || null,
        theme: d.theme || null,
        plantilla: d.plantilla || 'personalizado',
      },
      { superadmin: true }
    );

    const creada = getEmpresas({ todas: true }).slice(-1)[0];

    /* 4. La primera sede. guardarEmpresa() ya crea una si no hay
       ninguna; aquí se le ponen los datos que se dieron en el alta. */
    const sedes = getSucursales({ todas: true, empresaId: creada.id });
    if (sedes.length) {
      guardarSucursal(
        Object.assign({}, sedes[0], {
          direccion: d.direccion || sedes[0].direccion || '',
          ciudad: d.ciudad || sedes[0].ciudad || '',
          telefono: d.telefono || sedes[0].telefono || '',
          whatsapp: d.whatsapp || sedes[0].whatsapp || '',
          tipoNegocio: tipoInicialDeAlta(d),
        }),
        creada.id
      );
    }

    /* 5. Su configuración: se parte de los valores de fábrica y se le
       pone su nombre. NO se copia la de otra empresa. */
    const cfgs = leer(K.config, {}) || {};
    cfgs[creada.id] = Object.assign(clonar(DEFAULTS.config), {
      marca: creada.nombre,
      contacto: Object.assign({}, clonar(DEFAULTS.config).contacto, {
        telefono: d.telefono || '',
        whatsapp: d.whatsapp || '',
        email: d.email || '',
        direccion: d.direccion || '',
        ciudad: d.ciudad || '',
      }),
    });
    escribir(K.config, cfgs);

    // 6. El administrador inicial, si se pidió
    let usuarioCreado = null;
    if (admin) {
      guardarUsuario(
        {
          nombre: admin.nombre,
          usuario: admin.usuario,
          pin: admin.pin,
          /* Rol de EMPRESA, nunca superadmin: guardarUsuario() lo
             rechazaría, pero se deja explícito para que se lea. */
          rol: 'admin',
          sucursalId: null,
          activo: true,
        },
        creada.id
      );
      usuarioCreado = getUsuarios({ todos: true, empresaId: creada.id })[0] || null;
    }

    hidratar();

    return {
      empresa: getEmpresa(creada.id),
      sucursal: getSucursales({ todas: true, empresaId: creada.id })[0] || null,
      usuario: usuarioCreado,
    };
  }

  /* Las empresas no se borran: se desactivan, para no dejar huérfanos
     los registros históricos que apuntan a ellas. */
  function activarEmpresa(empresaId, activa, opciones) {
    return guardarEmpresa({ id: empresaId, activa: !!activa }, opciones);
  }

  /* ===============================================================
     MÓDULOS

     ÚNICO punto donde se decide si una empresa tiene un módulo. Las
     pantallas nunca miran `empresa.modulos` a mano: preguntan aquí
     (o por NASCAR.Auth.hasModule, que reenvía a esta misma función).
     =============================================================== */

  function catalogoModulos() {
    return NASCAR.MODULOS || [];
  }

  function definicionModulo(moduloId) {
    return catalogoModulos().find((m) => m.id === moduloId) || null;
  }

  /* Deja el mapa de módulos en su forma canónica:
       · sólo las claves de NASCAR.MODULOS (se ignoran las de versiones
         anteriores, como el antiguo 'gastos', que ahora es parte de
         Básico),
       · los módulos obligatorios siempre en true,
       · lo que falte, en su valor por defecto.
     Así da igual de dónde venga el mapa (data.js, un respaldo viejo,
     algo escrito a mano): hasModule() siempre lee lo mismo. */
  function normalizarModulos(mapa) {
    const previo = mapa || {};
    const porDefecto = NASCAR.MODULOS_POR_DEFECTO || {};
    const salida = {};
    catalogoModulos().forEach(function (m) {
      if (m.obligatorio) return (salida[m.id] = true);
      salida[m.id] =
        typeof previo[m.id] === 'boolean' ? previo[m.id] : porDefecto[m.id] !== false;
    });
    return salida;
  }

  /**
   * ¿La empresa tiene este módulo?
   *
   *   hasModule('basico') | hasModule('stock') | hasModule('cierre')
   *
   * Acepta también un arreglo, que se lee como "cualquiera de estos":
   *   hasModule(['stock', 'cierre'])   -> true si tiene al menos uno.
   *
   * Un módulo cuenta como activo sólo si sus dependencias también lo
   * están: si algún día se apagara Básico, todo lo que cuelga de él
   * deja de estar disponible sin tener que repetir la comprobación.
   */
  function hasModule(modulo, empresaId) {
    if (Array.isArray(modulo)) return modulo.some((m) => hasModule(m, empresaId));
    if (!modulo) return true; // sin módulo asociado, siempre disponible

    /* Un id que no está en el catálogo es un error de escritura, no un
       módulo libre: se niega. Vale más que se note una pestaña que
       falta a que se cuele una que nadie contrató. */
    const def = definicionModulo(modulo);
    if (!def) return false;

    const e = getEmpresa(empresaId || empresaActivaId());
    const mapa = normalizarModulos(e ? e.modulos : null);
    if (mapa[modulo] === false) return false;

    if (!def.requiere || !def.requiere.length) return true;
    return def.requiere.every((dep) => hasModule(dep, empresaId));
  }

  /* Nombre anterior, mantenido para no romper llamadas existentes.
     Es la MISMA función: no hay dos implementaciones. */
  function moduloActivo(modulo, empresaId) {
    return hasModule(modulo, empresaId);
  }

  /* Los módulos de la empresa, ya normalizados. Para pintarlos. */
  function getModulos(empresaId) {
    const e = getEmpresa(empresaId || empresaActivaId());
    return normalizarModulos(e ? e.modulos : null);
  }

  /**
   * Cambiar los módulos de una empresa.
   *
   * Exige `opciones.superadmin`. No es una barrera de seguridad real —
   * en un MVP local nada lo es — sino la forma de dejar constancia de
   * que esto NO le corresponde al Admin de la empresa: ninguna pantalla
   * del panel de empresa llama aquí, y guardarEmpresa() descarta el
   * campo. Sólo el panel de Taseca usa esta puerta.
   */
  function setModulos(empresaId, modulos, opciones) {
    if (!opciones || opciones.superadmin !== true)
      throw new Error('Sólo el SuperAdmin puede cambiar los módulos de una empresa.');

    /* La marca sola no basta cuando hay alguien conectado: si la sesión
       es la de un Admin de restaurante, no pasa por más que la mande.
       Sin sesión sí se permite, que es como se siembran los datos y
       como trabaja la consola en desarrollo. */
    const sesion = getSesion();
    if (sesion && sesion.rol !== 'superadmin')
      throw new Error('Sólo el SuperAdmin puede cambiar los módulos de una empresa.');

    const lista = getEmpresas({ todas: true });
    const i = lista.findIndex((e) => e.id === empresaId);
    if (i < 0) throw new Error('Esa empresa no existe.');

    lista[i] = Object.assign({}, lista[i], {
      modulos: normalizarModulos(Object.assign({}, lista[i].modulos, modulos)),
    });
    escribir(K.empresas, lista);
    hidratar();
    return lista[i].modulos;
  }

  /* ---------------------------------------------------------------
     TEMA DE UNA EMPRESA CLIENTE

     CÓMO SE VE la empresa: logo, colores y tipografía. Va aparte de
     `modulos`, que es QUÉ CONTRATÓ. Son dos preguntas distintas y
     mezclarlas sería confundir el aspecto con la funcionalidad.

     Y no confundirlo tampoco con el tema del PANEL TASECA, que vive en
     css/taseca.css con variables --platform-*: aquél es de la
     plataforma y ninguna empresa lo toca.

     La lista de tipografías es CERRADA (NASCAR.TIPOGRAFIAS): no se
     admite CSS ni fuentes arbitrarias. La personalización es controlada.
     --------------------------------------------------------------- */
  function inicialesDe(nombre) {
    const palabras = String(nombre || '').trim().split(/\s+/).filter(Boolean);
    if (!palabras.length) return '??';
    if (palabras.length === 1) return palabras[0].slice(0, 2).toUpperCase();
    return (palabras[0][0] + palabras[1][0]).toUpperCase();
  }

  function tipografia(id) {
    const lista = NASCAR.TIPOGRAFIAS || [];
    return lista.find((t) => t.id === id) || lista[0] || null;
  }

  /* Un color sólo puede ser un hexadecimal. Cualquier otra cosa —una
     función CSS, una variable, un `url()`— se descarta: es la puerta por
     la que se colaría CSS arbitrario. */
  function color(valor, porDefecto) {
    const v = String(valor || '').trim();
    return /^#[0-9a-fA-F]{3}([0-9a-fA-F]{3})?$/.test(v) ? v : porDefecto;
  }

  /* Una imagen sólo puede venir como dataURL de imagen, nunca como una
     URL externa ni un SVG con scripts dentro. */
  function imagenSegura(valor) {
    const v = String(valor || '').trim();
    return /^data:image\/(png|jpeg|jpg|webp|gif);base64,/i.test(v) ? v : '';
  }

  function normalizarTheme(theme, nombre) {
    const base = NASCAR.TEMA_BASE || {};
    const t = theme || {};
    const fuente = tipografia(t.fontFamily || base.fontFamily);

    return {
      logo: imagenSegura(t.logo),
      favicon: imagenSegura(t.favicon),
      /* Logotipo de texto: la primera parte va en el color del texto y
         la segunda en el de acento. Es como se ha escrito siempre
         NAS+CAR, sólo que ahora es un dato. */
      logoTexto: String(t.logoTexto || '').slice(0, 24),
      logoAcento: String(t.logoAcento || '').slice(0, 24),

      primary: color(t.primary, base.primary || '#2563eb'),
      secondary: color(t.secondary, base.secondary || '#64748b'),
      accent: color(t.accent, base.accent || '#38bdf8'),
      background: color(t.background, base.background || '#0b0f16'),

      fontFamily: fuente ? fuente.id : 'inter',

      iniciales: String(t.iniciales || inicialesDe(nombre)).slice(0, 3).toUpperCase(),
      lema: String(t.lema || '').slice(0, 80),
    };
  }

  function getTheme(empresaId) {
    const e = getEmpresa(empresaId || empresaActivaId());
    return normalizarTheme(e ? e.theme : null, e ? e.nombre : '');
  }

  /* Misma puerta que setModulos(): sólo la plataforma. Una empresa no
     cambia su propio tema desde su panel, y desde luego no el de Taseca
     ni el de otra empresa. */
  function setTheme(empresaId, theme, opciones) {
    if (!opciones || opciones.superadmin !== true)
      throw new Error('Sólo el SuperAdmin puede cambiar el tema de una empresa.');
    const sesion = getSesion();
    if (sesion && sesion.rol !== 'superadmin')
      throw new Error('Sólo el SuperAdmin puede cambiar el tema de una empresa.');

    const lista = getEmpresas({ todas: true });
    const i = lista.findIndex((e) => e.id === empresaId);
    if (i < 0) throw new Error('Esa empresa no existe.');

    lista[i] = Object.assign({}, lista[i], {
      theme: normalizarTheme(Object.assign({}, lista[i].theme, theme), lista[i].nombre),
    });
    escribir(K.empresas, lista);
    hidratar();
    return lista[i].theme;
  }

  /* La familia CSS de la tipografía elegida, para aplicarla. */
  function familiaTipografica(idFuente) {
    const t = tipografia(idFuente);
    return t ? t.familia : "system-ui, sans-serif";
  }

  /* --- Utilidades internas de aislamiento --- */

  /* Resuelve qué empresa aplica a una consulta: la que pidan, o la activa. */
  function empresaDe(filtro) {
    if (filtro && filtro.empresaId) return filtro.empresaId;
    return empresaActivaId();
  }

  /* Filtra una lista dejando sólo los registros de esa empresa.
     Los registros sin `empresaId` (anteriores a la migración) se
     consideran de la empresa por defecto: así nada se pierde. */
  function soloDeEmpresa(lista, empresaId) {
    return (lista || []).filter(
      (x) => (x.empresaId || EMPRESA_DEFECTO) === empresaId
    );
  }

  /* Marca un registro nuevo con la empresa activa. */
  function conEmpresa(registro, empresaId) {
    registro.empresaId = empresaId || empresaActivaId();
    return registro;
  }

  /* Etiqueta corta para los consecutivos de empresas distintas a la
     original: así el 00027 de NASCAR y el de otra empresa no se confunden. */
  function tagEmpresa(empresaId) {
    const eid = empresaId || empresaActivaId();
    if (eid === EMPRESA_DEFECTO) return '';
    return '-' + String(eid).replace(/^empresa_/, '').toUpperCase().slice(0, 6);
  }

  /* Mezcla profunda: lo guardado manda, pero si aparece una clave nueva
     en data.js (por una actualización del sistema) se hereda del default. */
  function mezclar(base, encima) {
    if (!encima || typeof encima !== 'object' || Array.isArray(encima)) {
      return encima === undefined ? base : encima;
    }
    const out = Array.isArray(base) ? [] : Object.assign({}, base);
    Object.keys(encima).forEach(function (k) {
      const b = base ? base[k] : undefined;
      out[k] = b && typeof b === 'object' && !Array.isArray(b) ? mezclar(b, encima[k]) : encima[k];
    });
    return out;
  }

  /* ---- Configuración general (una por empresa) ----
     Se guarda como { empresaId: {…} }: cada empresa tiene su nombre,
     su WhatsApp y sus cuentas bancarias. */
  function getConfig(empresaId) {
    const eid = empresaId || empresaActivaId();
    const todas = leer(K.config, {}) || {};
    return mezclar(DEFAULTS.config, todas[eid] || {});
  }

  function guardarConfig(cambios, empresaId) {
    const eid = empresaId || empresaActivaId();
    const todas = leer(K.config, {}) || {};
    todas[eid] = mezclar(todas[eid] || {}, cambios);
    escribir(K.config, todas);
    hidratar();
    return getConfig(eid);
  }

  function restablecerConfig(empresaId) {
    const eid = empresaId || empresaActivaId();
    const todas = leer(K.config, {}) || {};
    todas[eid] = {};
    escribir(K.config, todas);
    hidratar();
    return getConfig(eid);
  }

  /* ---- Unidades / locales ----

     Una UNIDAD es un punto de operación de la empresa: NASCAR-Comidas,
     NASCAR Bar VIP, COMIC'ENDO AREPA… Se guarda en la lista de siempre
     (K.sucursales) y todo lo operativo sigue apuntando a ella con
     `sucursalId`: así ningún pedido, cierre, gasto, base o entrada
     histórico tiene que reescribirse. "Sucursal" es el nombre técnico;
     en pantalla se llama Unidad / Local.

       EMPRESA  (el cliente de Taseca: datos, tema, módulos)
         └─ UNIDAD  (id, empresaId, nombre, corto, tipoNegocio, activa,
                     direccion, ciudad, telefono, whatsapp, horario, mapa,
                     mesas, color, zonas, branding { logo, color }, creado)
              └─ operación: carta, categorías, stock, menú del día,
                 pedidos, ventas, gastos, base de caja, cierres, entradas

     El tipo de negocio es un ATRIBUTO: no decide qué funciones tiene la
     unidad. Eso lo deciden los módulos de la empresa. */
  function tipoNegocioValido(tipo) {
    return (NASCAR.TIPOS_NEGOCIO || []).some((x) => x.id === tipo);
  }

  function getTipoNegocio(tipo) {
    const lista = NASCAR.TIPOS_NEGOCIO || [];
    return (
      lista.find((x) => x.id === tipo) ||
      lista.find((x) => x.id === 'otro') || { id: tipo, nombre: tipo || 'Sin tipo', icono: '🏪' }
    );
  }

  function tipoInicialDeAlta(d) {
    if (tipoNegocioValido(d.tipoNegocio)) return d.tipoNegocio;
    if (tipoNegocioValido(d.plantilla)) return d.plantilla;
    return d.plantilla === 'comercio' ? 'otro' : NASCAR.TIPO_NEGOCIO_DEFECTO || 'restaurante';
  }

  /* Identidad propia opcional. Sin logo ni color, la unidad se ve con la
     identidad de su empresa: nada del tema de la empresa se toca. */
  function normalizarBrandingUnidad(b) {
    b = b || {};
    return {
      logo: typeof b.logo === 'string' && b.logo.indexOf('data:image/') === 0 ? b.logo : '',
      color: /^#[0-9a-f]{6}$/i.test(String(b.color || '')) ? String(b.color).toLowerCase() : '',
    };
  }

  /* Lo que devuelven las consultas. `estado` se DERIVA de `activa`, que
     sigue siendo el único dato guardado: no hay dos campos que puedan
     contradecirse. */
  function normalizarUnidad(s) {
    return Object.assign({}, s, {
      tipoNegocio: tipoNegocioValido(s.tipoNegocio)
        ? s.tipoNegocio
        : NASCAR.TIPO_NEGOCIO_DEFECTO || 'restaurante',
      estado: s.activa === false ? 'inactiva' : 'activa',
      branding: normalizarBrandingUnidad(s.branding),
      creado: s.creado || null,
    });
  }

  function getSucursales(opciones) {
    opciones = opciones || {};
    const eid = empresaDe(opciones);
    const guardadas = leer(K.sucursales, null);
    const lista = (guardadas
      ? soloDeEmpresa(guardadas, eid)
      : soloDeEmpresa(
          clonar(DEFAULTS.sucursales).map((s) => conEmpresa(s, EMPRESA_DEFECTO)),
          eid
        )
    ).map(normalizarUnidad);
    return opciones.todas ? lista : lista.filter((s) => s.activa !== false);
  }

  function getSucursal(sucursalId, empresaId) {
    return (
      getSucursales({ todas: true, empresaId: empresaId }).find(
        (s) => Number(s.id) === Number(sucursalId)
      ) || null
    );
  }

  /* El nombre corto va en los códigos de los cierres y en las listas
     estrechas, así que no se puede repetir dentro de la empresa. Si no se
     escribe, sale del nombre. */
  function cortoLibre(corto, propias, exceptoId) {
    const c = String(corto).toLowerCase();
    return !propias.some(
      (s) => Number(s.id) !== Number(exceptoId) && String(s.corto || '').toLowerCase() === c
    );
  }

  function cortoDeNombre(nombre, propias) {
    const limpio = String(nombre || '').trim();
    const palabras = limpio.split(/\s+/).filter(Boolean);
    const candidatos = [limpio.length <= 18 ? limpio : '', palabras[0], palabras.slice(0, 2).join(' ')]
      .filter(Boolean)
      .map((c) => c.slice(0, 18));
    for (let k = 0; k < candidatos.length; k++) {
      if (cortoLibre(candidatos[k], propias)) return candidatos[k];
    }
    const base = (palabras[0] || 'Unidad').slice(0, 14);
    let n = 2;
    while (!cortoLibre(base + ' ' + n, propias)) n++;
    return base + ' ' + n;
  }

  function guardarSucursal(datos, empresaId) {
    const eid = empresaId || empresaActivaId();

    /* Doble barrera: crear, editar, activar o desactivar unidades es de
       quien tiene 'config_sucursales' (el Admin). Sin sesión se permite:
       es el alta de empresas desde las semillas y la consola. */
    const sesion = getSesion();
    if (sesion && NASCAR.Auth && !NASCAR.Auth.puede('config_sucursales', sesion))
      throw new Error('Tu perfil no puede administrar las unidades de la empresa.');

    const todas = leer(K.sucursales, null) || clonar(DEFAULTS.sucursales).map((s) => conEmpresa(s, EMPRESA_DEFECTO));
    const propias = soloDeEmpresa(todas, eid);
    const i = todas.findIndex(
      (s) => (s.empresaId || EMPRESA_DEFECTO) === eid && Number(s.id) === Number(datos.id)
    );

    const limpio = Object.assign({}, datos);
    // `estado` sólo se traduce: lo que se guarda es `activa`
    if (limpio.estado !== undefined) {
      if (limpio.activa === undefined) limpio.activa = limpio.estado !== 'inactiva';
      delete limpio.estado;
    }
    if (limpio.nombre !== undefined) {
      limpio.nombre = String(limpio.nombre).trim();
      if (limpio.nombre.length < 2) throw new Error('La unidad necesita un nombre.');
    }
    if (limpio.tipoNegocio !== undefined && !tipoNegocioValido(limpio.tipoNegocio))
      throw new Error('Elige un tipo de negocio de la lista.');
    if (limpio.branding !== undefined) limpio.branding = normalizarBrandingUnidad(limpio.branding);

    if (i >= 0) {
      // No puede quedarse la empresa sin ninguna unidad en operación
      if (limpio.activa === false && todas[i].activa !== false) {
        const otras = propias.filter(
          (s) => s.activa !== false && Number(s.id) !== Number(todas[i].id)
        );
        if (!otras.length) throw new Error('Debe quedar al menos una unidad activa.');
      }
      if (limpio.corto !== undefined) {
        limpio.corto =
          String(limpio.corto).trim() ||
          todas[i].corto ||
          cortoDeNombre(limpio.nombre || todas[i].nombre, propias);
        if (!cortoLibre(limpio.corto, propias, todas[i].id))
          throw new Error('Ya hay otra unidad con el nombre corto "' + limpio.corto + '".');
      }
      todas[i] = Object.assign({}, todas[i], limpio, { id: Number(todas[i].id), empresaId: eid });
    } else {
      if (!limpio.nombre) throw new Error('La unidad necesita un nombre.');
      const corto = String(limpio.corto || '').trim() || cortoDeNombre(limpio.nombre, propias);
      if (!cortoLibre(corto, propias))
        throw new Error('Ya hay otra unidad con el nombre corto "' + corto + '".');

      // El id se numera dentro de la empresa: cada una tiene su unidad 1
      const nuevoId = Math.max(0, ...propias.map((s) => Number(s.id))) + 1;
      todas.push(
        conEmpresa(
          Object.assign(
            { corto: '', direccion: '', ciudad: '', telefono: '', whatsapp: '',
              horario: '', mapa: '', mesas: 10, color: 'azul', zonas: [], activa: true,
              tipoNegocio: NASCAR.TIPO_NEGOCIO_DEFECTO || 'restaurante',
              branding: { logo: '', color: '' } },
            limpio,
            { id: nuevoId, corto: corto, creado: new Date().toISOString() }
          ),
          eid
        )
      );
    }
    escribir(K.sucursales, todas);
    hidratar();
    return getSucursales({ todas: true, empresaId: eid });
  }

  /* Las unidades no se borran: se desactivan. Los pedidos, cierres,
     gastos y bases históricos siguen apuntando a su id y deben poder
     resolverlo. */
  function activarSucursal(sucursalId, activa) {
    return guardarSucursal({ id: sucursalId, activa: !!activa });
  }

  /* ---- Unidad activa ----

     La unidad en la que se trabaja forma parte del CONTEXTO, igual que la
     empresa: no se elige en cada pantalla. Se recuerda por empresa en
     localStorage ({ empresaId: sucursalId }).

       · Un usuario asignado a una unidad trabaja siempre en la suya.
       · Si la recordada ya no existe o está inactiva, se toma la primera
         unidad activa. */
  function unidadActivaId(empresaId) {
    const eid = empresaId || empresaActivaId();
    const ses = getSesion();
    if (
      ses && ses.scope !== SCOPE_PLATAFORMA && ses.sucursalId &&
      (ses.empresaId || EMPRESA_DEFECTO) === eid
    )
      return Number(ses.sucursalId);

    const activas = getSucursales({ empresaId: eid });
    const mapa = leer(K.unidadActiva, {}) || {};
    const recordada = Number(mapa[eid]);
    if (recordada && activas.some((s) => Number(s.id) === recordada)) return recordada;
    return activas.length ? Number(activas[0].id) : null;
  }

  function getUnidadActiva(empresaId) {
    const idU = unidadActivaId(empresaId);
    return idU ? getSucursal(idU, empresaId) : null;
  }

  function setUnidadActiva(sucursalId, empresaId) {
    const eid = empresaId || empresaActivaId();
    const u = getSucursal(sucursalId, eid);
    if (!u) throw new Error('Esa unidad no existe en esta empresa.');
    if (u.activa === false)
      throw new Error('La unidad "' + u.nombre + '" está inactiva: no se puede trabajar en ella.');
    const ses = getSesion();
    if (ses && ses.scope !== SCOPE_PLATAFORMA && ses.sucursalId && Number(ses.sucursalId) !== Number(u.id))
      throw new Error('Tu usuario está asignado a otra unidad.');

    const mapa = leer(K.unidadActiva, {}) || {};
    if (Number(mapa[eid]) === Number(u.id)) return Number(u.id);
    mapa[eid] = Number(u.id);
    escribir(K.unidadActiva, mapa);
    return Number(u.id);
  }

  /* Una unidad inactiva conserva su historia pero no admite operación
     nueva: ni pedidos, ni gastos, ni bases, ni cierres, ni entradas, ni
     menú del día. Se comprueba aquí, no sólo en la pantalla. */
  function exigirUnidadOperativa(sucursalId, empresaId) {
    const u = getSucursal(sucursalId, empresaId);
    if (!u) throw new Error('Esa unidad no existe en esta empresa.');
    if (u.activa === false)
      throw new Error(
        'La unidad "' + u.nombre + '" está inactiva: no admite operación nueva. ' +
          'Su información histórica se conserva.'
      );
    return u;
  }

  /* ¿Este registro de catálogo (producto de carta, categoría o producto de
     stock) es de la unidad? Todos llevan `sucursales`: las unidades que
     lo usan. Lo nuevo nace con UNA; lo anterior a las unidades quedó con
     las que la empresa tenía entonces (ver migrarUnidades). */
  function esDeUnidad(registro, sucursalId) {
    return (registro.sucursales || []).map(Number).indexOf(Number(sucursalId)) >= 0;
  }

  function unidadesParaNuevo(sucursales, eid) {
    const lista = (Array.isArray(sucursales) ? sucursales : []).map(Number).filter(Boolean);
    if (lista.length) return lista;
    const activa = unidadActivaId(eid);
    if (!activa) throw new Error('La empresa no tiene ninguna unidad activa.');
    return [activa];
  }

  /* En una edición, una lista de unidades vacía no significa "ninguna":
     se ignora y el registro conserva las suyas. */
  function sinUnidadesVacias(d) {
    const c = Object.assign({}, d);
    if (Array.isArray(c.sucursales) && !c.sucursales.length) delete c.sucursales;
    return c;
  }

  /* ---- Categorías de la carta ---- */
  function categoriasCrudas() {
    return (
      leer(K.categorias, null) ||
      clonar(DEFAULTS.categorias).map((c) => conEmpresa(c, EMPRESA_DEFECTO))
    );
  }

  function getCategorias(opciones) {
    opciones = opciones || {};
    let lista = soloDeEmpresa(categoriasCrudas(), empresaDe(opciones)).map((c) =>
      Object.assign({}, c, { sucursales: Array.isArray(c.sucursales) ? c.sucursales : [] })
    );
    // Cada unidad tiene sus categorías: las de un bar no son las de una arepera
    if (opciones.sucursalId) lista = lista.filter((c) => esDeUnidad(c, opciones.sucursalId));
    const orden = (a, b) => (a.orden || 0) - (b.orden || 0);
    return (opciones.todas ? lista : lista.filter((c) => c.activa !== false)).sort(orden);
  }

  function guardarCategoria(datos, empresaId) {
    const eid = empresaId || empresaActivaId();
    const todas = categoriasCrudas();
    const i = todas.findIndex(
      (c) => (c.empresaId || EMPRESA_DEFECTO) === eid && c.id === datos.id
    );
    if (i >= 0) todas[i] = Object.assign({}, todas[i], sinUnidadesVacias(datos), { empresaId: eid });
    else
      todas.push(
        conEmpresa(
          Object.assign(
            { icono: '🍽️', activa: true, orden: (soloDeEmpresa(todas, eid).length + 1) * 10 },
            datos,
            { id: datos.id || 'cat-' + id(), sucursales: unidadesParaNuevo(datos.sucursales, eid) }
          ),
          eid
        )
      );
    escribir(K.categorias, todas);
    hidratar();
    return getCategorias({ todas: true, empresaId: eid });
  }

  function borrarCategoria(catId, empresaId) {
    const eid = empresaId || empresaActivaId();
    const enUso = getCarta({ todas: true, empresaId: eid }).filter((p) => p.cat === catId);
    if (enUso.length)
      throw new Error(
        'No se puede eliminar: hay ' + enUso.length + ' productos en esta categoría. ' +
          'Muévelos a otra o desactiva la categoría.'
      );
    escribir(
      K.categorias,
      categoriasCrudas().filter(
        (c) => !((c.empresaId || EMPRESA_DEFECTO) === eid && c.id === catId)
      )
    );
    hidratar();
    return true;
  }

  /* ===============================================================
     CARTA  (administrable desde el panel)

     Campos de cada producto:
       id, codigo, nombre, desc, cat, precio, tag, orden,
       activo (se muestra o no), agotado (temporalmente sin existencias),
       sucursales (las unidades que venden el producto)

     `disponible` es un campo CALCULADO (activo && !agotado) que se
     conserva porque las pantallas públicas ya lo usaban.
     =============================================================== */
  function normalizarProductoCarta(p, indice) {
    return Object.assign({}, p, {
      codigo: p.codigo || String(p.id || '').toUpperCase(),
      activo: p.activo !== false,
      agotado: p.agotado === true,
      orden: typeof p.orden === 'number' ? p.orden : (indice + 1) * 10,
      sucursales: Array.isArray(p.sucursales) ? p.sucursales : [],
      imagen: p.imagen || '',
    });
  }

  /* Toda la carta de todas las empresas, tal cual está guardada. */
  function cartaGuardada() {
    const guardada = leer(K.cartaV2, null);
    if (guardada) return guardada;
    return DEFAULTS.carta.map((p, i) => conEmpresa(normalizarProductoCarta(p, i), EMPRESA_DEFECTO));
  }

  /**
   * getCarta({ todas, sucursalId })
   *   todas       incluye los productos desactivados (para el panel)
   *   sucursalId  filtra los que no se venden en esa sucursal
   */
  function getCarta(opciones) {
    opciones = opciones || {};
    let lista = soloDeEmpresa(cartaGuardada(), empresaDe(opciones)).map(function (p, i) {
      const n = normalizarProductoCarta(p, i);
      n.disponible = n.activo && !n.agotado;
      const base = DEFAULTS.carta.find((x) => x.id === n.id);
      n.modificado = !!base && base.precio !== n.precio;
      n.precioBase = base ? base.precio : null;
      return n;
    });

    if (!opciones.todas) lista = lista.filter((p) => p.activo);
    // La carta es de la UNIDAD: la de un bar no aparece en una arepera
    if (opciones.sucursalId) lista = lista.filter((p) => esDeUnidad(p, opciones.sucursalId));

    return lista.sort((a, b) => (a.orden || 0) - (b.orden || 0));
  }

  function getCartaDisponible(sucursalId, empresaId) {
    return getCarta({ sucursalId: sucursalId, empresaId: empresaId }).filter((p) => p.disponible);
  }

  function getPlatoCarta(platoId, empresaId) {
    return getCarta({ todas: true, empresaId: empresaId }).find((p) => p.id === platoId) || null;
  }

  function guardarPlatoCarta(datos, empresaId) {
    if (!datos.nombre || String(datos.nombre).trim().length < 2)
      throw new Error('El producto necesita un nombre.');
    const precio = Number(datos.precio);
    if (!isFinite(precio) || precio < 0) throw new Error('El precio no es válido.');
    if (!datos.cat) throw new Error('El producto necesita una categoría.');

    const eid = empresaId || empresaActivaId();
    const lista = cartaGuardada();
    const i = lista.findIndex(
      (p) => (p.empresaId || EMPRESA_DEFECTO) === eid && p.id === datos.id
    );

    if (i >= 0) {
      lista[i] = Object.assign({}, lista[i], sinUnidadesVacias(datos), { precio: precio, empresaId: eid });
    } else {
      lista.push(
        conEmpresa(
          normalizarProductoCarta(
            Object.assign({ tag: '', desc: '' }, datos, {
              id: datos.id || 'x' + id(),
              precio: precio,
              sucursales: unidadesParaNuevo(datos.sucursales, eid),
            }),
            lista.length
          ),
          eid
        )
      );
    }
    escribir(K.cartaV2, lista);
    hidratar();
    return getCarta({ todas: true, empresaId: eid });
  }

  /* Eliminar de verdad sólo si nunca se vendió; si ya tiene historia,
     se desactiva para no romper los pedidos anteriores. */
  function borrarPlatoCarta(platoId, empresaId) {
    const eid = empresaId || empresaActivaId();
    const vendido = soloDeEmpresa(leer(K.pedidos, []), eid).some((ped) =>
      ped.items.some((it) => it.refId === platoId)
    );
    if (vendido) {
      ajustarPlatoCarta(platoId, { activo: false }, eid);
      return { eliminado: false, desactivado: true };
    }
    escribir(
      K.cartaV2,
      cartaGuardada().filter(
        (p) => !((p.empresaId || EMPRESA_DEFECTO) === eid && p.id === platoId)
      )
    );
    hidratar();
    return { eliminado: true, desactivado: false };
  }

  /* Cambios parciales (precio, agotado, activo…). Se conserva el nombre
     que ya usaba el panel para no romper la pantalla de Carta. */
  function ajustarPlatoCarta(platoId, cambios, empresaId) {
    const eid = empresaId || empresaActivaId();
    const lista = cartaGuardada();
    const i = lista.findIndex(
      (p) => (p.empresaId || EMPRESA_DEFECTO) === eid && p.id === platoId
    );
    if (i < 0) return false;

    // La pantalla antigua mandaba { disponible }: se traduce a `agotado`.
    if (Object.prototype.hasOwnProperty.call(cambios, 'disponible')) {
      cambios = Object.assign({}, cambios, { agotado: cambios.disponible === false });
      delete cambios.disponible;
    }
    lista[i] = Object.assign({}, lista[i], cambios);
    escribir(K.cartaV2, lista);
    hidratar();
    return true;
  }

  /* Retira una unidad de los registros de un catálogo y le vuelve a poner
     los de fábrica. Un registro que era SÓLO de esa unidad se retira; uno
     que comparte con otras unidades sólo deja de ser de ésta. Si el de
     fábrica ya existe (porque otra unidad lo conserva), se vuelve a
     compartir en vez de duplicarse. Las demás unidades y empresas no se
     tocan. */
  function restaurarCatalogoDeUnidad(lista, defaults, eid, suc, llave, normalizar) {
    const salida = [];
    lista.forEach(function (x) {
      if ((x.empresaId || EMPRESA_DEFECTO) !== eid || !esDeUnidad(x, suc)) return salida.push(x);
      const resto = (x.sucursales || []).map(Number).filter((n) => n !== Number(suc));
      if (resto.length) salida.push(Object.assign({}, x, { sucursales: resto }));
    });
    defaults.forEach(function (d, k) {
      const existente = salida.find(
        (x) => (x.empresaId || EMPRESA_DEFECTO) === eid && x[llave] === normalizar(d, k)[llave]
      );
      if (existente) existente.sucursales = (existente.sucursales || []).concat([Number(suc)]);
      else salida.push(conEmpresa(Object.assign(normalizar(d, k), { sucursales: [Number(suc)] }), eid));
    });
    return salida;
  }

  /* Devuelve la carta de UNA unidad (la activa, por defecto) a los valores
     de fábrica, sin tocar las demás unidades ni las demás empresas. */
  function resetCarta(empresaId, sucursalId) {
    const eid = empresaId || empresaActivaId();
    const suc = Number(sucursalId || unidadActivaId(eid));
    if (!suc) throw new Error('No hay una unidad activa.');
    escribir(
      K.cartaV2,
      restaurarCatalogoDeUnidad(
        cartaGuardada(),
        semillaDeUnidad(DEFAULTS.carta, eid, suc), // lo de fábrica de ESTA unidad
        eid, suc, 'id', normalizarProductoCarta
      )
    );
    escribir(K.carta, {}); // limpia el formato antiguo de ajustes
    hidratar();
    return true;
  }

  /* ===============================================================
     STOCK  (catálogo de inventario administrable)

     Es el MISMO catálogo que usa el cierre de inventario: una sola
     fuente de verdad. Antes vivía sólo en data.js; ahora se administra
     desde Panel → 📦 Stock.

     Campos: codigo, nombre, categoria, area, unidad, activo,
             ventaRefIds, stockActual, stockMinimo,
             sucursales (las unidades que llevan este producto)
     =============================================================== */
  function normalizarProductoStock(p) {
    return Object.assign({}, p, {
      codigo: String(p.codigo || '').trim().toUpperCase(),
      nombre: p.nombre || '',
      categoria: p.categoria || 'General',
      area: p.area === 'bar' ? 'bar' : 'comidas',
      unidad: p.unidad || 'unidad',
      activo: p.activo !== false,
      ventaRefIds: Array.isArray(p.ventaRefIds) ? p.ventaRefIds : [],
      stockActual: enteroNoNegativo(p.stockActual, 0),
      stockMinimo: enteroNoNegativo(p.stockMinimo, 0),
      sucursales: Array.isArray(p.sucursales) ? p.sucursales : [],
    });
  }

  function enteroNoNegativo(v, porDefecto) {
    const n = Math.floor(Number(v));
    return isFinite(n) && n >= 0 ? n : porDefecto;
  }

  function stockGuardado() {
    const g = leer(K.stock, null);
    if (g) return g;
    return DEFAULTS.stock.map((p) => conEmpresa(normalizarProductoStock(p), EMPRESA_DEFECTO));
  }

  /**
   * getStock({ todos, area, texto, bajoMinimo })
   *   todos = true incluye los desactivados (para el panel)
   */
  function getStock(opciones) {
    opciones = opciones || {};
    let lista = soloDeEmpresa(stockGuardado(), empresaDe(opciones)).map(normalizarProductoStock);
    if (!opciones.todos) lista = lista.filter((p) => p.activo);
    if (opciones.area) lista = lista.filter((p) => p.area === opciones.area);
    // El stock es de la UNIDAD: lo del bar no aparece en la arepera
    if (opciones.sucursalId) lista = lista.filter((p) => esDeUnidad(p, opciones.sucursalId));
    if (opciones.bajoMinimo)
      lista = lista.filter((p) => p.stockMinimo > 0 && p.stockActual <= p.stockMinimo);
    if (opciones.texto) {
      const q = String(opciones.texto).trim().toLowerCase();
      lista = lista.filter(
        (p) => p.nombre.toLowerCase().includes(q) || p.codigo.toLowerCase().includes(q)
      );
    }
    return lista.sort((a, b) => (a.codigo < b.codigo ? -1 : 1));
  }

  /**
   * Crea o actualiza un producto de stock.
   * Acepta cambios parciales: se fusiona con lo que ya existe y se valida
   * el resultado, no lo que llegó. Así `{ codigo, activo:false }` es válido.
   */
  function guardarProductoStock(datos, codigoOriginal, empresaId) {
    const eid = empresaId || empresaActivaId();
    const lista = stockGuardado().map(normalizarProductoStock);
    const buscado = String(codigoOriginal || datos.codigo || '').trim().toUpperCase();
    const mia = (p) => (p.empresaId || EMPRESA_DEFECTO) === eid;
    const i = lista.findIndex((p) => mia(p) && p.codigo === buscado);

    const base = i >= 0 ? lista[i] : {};
    const cambios = sinUnidadesVacias(datos);
    const resultado = conEmpresa(normalizarProductoStock(Object.assign({}, base, cambios)), eid);
    // Un producto nuevo nace en UNA unidad: la indicada o la activa
    if (i < 0) resultado.sucursales = unidadesParaNuevo(cambios.sucursales, eid);

    if (!resultado.codigo) throw new Error('El producto necesita un código.');
    if (!resultado.nombre || resultado.nombre.trim().length < 2)
      throw new Error('El producto necesita un nombre.');

    // El código es la llave del inventario DENTRO de cada empresa:
    // dos empresas distintas sí pueden tener un C001 cada una.
    const choque = lista.findIndex((p) => mia(p) && p.codigo === resultado.codigo);
    if (choque >= 0 && choque !== i)
      throw new Error(
        'Ya existe otro producto con el código ' + resultado.codigo +
          ' (puede ser de otra unidad de la empresa).'
      );

    if (i >= 0) lista[i] = resultado;
    else lista.push(resultado);

    escribir(K.stock, lista);
    hidratar();
    return getStock({ todos: true, empresaId: eid });
  }

  /* Los productos de stock NO se borran: se desactivan. Los cierres
     históricos guardan su propia copia del producto, así que no se ven
     afectados, pero el cruce debe poder seguir resolviendo el código. */
  function activarProductoStock(codigo, activo) {
    return guardarProductoStock({ codigo: codigo, activo: !!activo }, codigo);
  }

  function ajustarStockActual(codigo, cantidad, motivo) {
    const n = enteroNoNegativo(cantidad, null);
    if (n === null) throw new Error('El stock debe ser un número entero mayor o igual a cero.');
    guardarProductoStock({ codigo: codigo, stockActual: n }, codigo);
    return { codigo: codigo, stockActual: n, motivo: motivo || '' };
  }

  /**
   * Lleva el stock actual al saldo físico contado en un cierre.
   * Es explícito y manual a propósito: el sistema NO descuenta stock
   * automáticamente por ventas, porque todavía no existe módulo de
   * recetas/insumos (ver README).
   */
  function aplicarCierreAStock(cierreId) {
    const c = getCierre(cierreId);
    if (!c) throw new Error('No se encontró el cierre.');

    const eid = c.empresaId || EMPRESA_DEFECTO;
    const lista = stockGuardado().map(normalizarProductoStock);
    let aplicados = 0;
    c.productos.forEach(function (p) {
      const i = lista.findIndex(
        (x) => (x.empresaId || EMPRESA_DEFECTO) === eid && x.codigo === p.codigo
      );
      if (i >= 0) {
        lista[i].stockActual = enteroNoNegativo(p.saldo, 0);
        aplicados++;
      }
    });
    escribir(K.stock, lista);
    hidratar();

    actualizarCierre(cierreId, { motivo: 'Saldos aplicados al stock actual' });
    return aplicados;
  }

  /* El catálogo de stock de UNA unidad vuelve a los valores de fábrica. */
  function resetStock(empresaId, sucursalId) {
    const eid = empresaId || empresaActivaId();
    const suc = Number(sucursalId || unidadActivaId(eid));
    if (!suc) throw new Error('No hay una unidad activa.');
    escribir(
      K.stock,
      restaurarCatalogoDeUnidad(
        stockGuardado().map(normalizarProductoStock),
        semillaDeUnidad(DEFAULTS.stock, eid, suc), // lo de fábrica de ESTA unidad
        eid, suc, 'codigo',
        (p) => normalizarProductoStock(p)
      )
    );
    hidratar();
    return true;
  }

  /* ===============================================================
     USUARIOS  (MVP local — no es autenticación real)
     =============================================================== */
  function usuariosCrudos() {
    return leer(K.usuarios, null) || clonar(DEFAULTS.usuarios).map((u) => conEmpresa(u, EMPRESA_DEFECTO));
  }

  function getUsuarios(opciones) {
    opciones = opciones || {};
    // `todasEmpresas` lo usa el login, que tiene que poder encontrar a
    // alguien antes de saber a qué empresa pertenece.
    /* Los usuarios de PLATAFORMA no son de ninguna empresa: nunca salen
       en una consulta por empresa. Es lo que impide que el SuperAdmin
       de Taseca aparezca —y se pueda tocar— dentro de NASCAR. */
    const deEmpresas = usuariosCrudos().filter((u) => !esUsuarioPlataforma(u));

    const lista = opciones.todasEmpresas
      ? deEmpresas
      : soloDeEmpresa(deEmpresas, empresaDe(opciones));
    return opciones.todos ? lista : lista.filter((u) => u.activo !== false);
  }

  function getUsuario(usuarioId) {
    // Busca en el almacén completo: también los de plataforma. Se compara
    // como texto: los ids de la base son números y los botones los pasan
    // como texto (data-*).
    return usuariosCrudos().find((u) => String(u.id) === String(usuarioId)) || null;
  }

  /* ¿Es un usuario de la PLATAFORMA (Taseca) y no de un restaurante?

     Se decide por `scope`. La comparación con PLATAFORMA es sólo para
     reconocer instalaciones anteriores a la separación, que marcaban la
     pertenencia con un empresaId inventado. */
  function esUsuarioPlataforma(u) {
    if (!u) return false;
    return u.scope === SCOPE_PLATAFORMA || u.empresaId === PLATAFORMA;
  }

  /* Los usuarios de la plataforma. Sólo los mira el panel de Taseca:
     getUsuarios() los excluye siempre de las consultas por empresa. */
  function getUsuariosPlataforma() {
    return usuariosCrudos().filter(esUsuarioPlataforma);
  }

  function guardarUsuario(datos, empresaId) {
    if (!datos.nombre || String(datos.nombre).trim().length < 2)
      throw new Error('El usuario necesita un nombre.');
    if (!datos.usuario || String(datos.usuario).trim().length < 3)
      throw new Error('El nombre de acceso debe tener al menos 3 caracteres.');
    const eid = empresaId || empresaActivaId();
    const todos = usuariosCrudos();
    const acceso = String(datos.usuario).trim().toLowerCase();
    const i = todos.findIndex((u) => u.id === datos.id);

    /* Al editar, un PIN vacío conserva el que ya tiene. Con la base de
       datos el PIN nunca llega al navegador (se guarda cifrado), así que
       editar a alguien no puede exigir volver a escribirlo. */
    const pinVacio = String(datos.pin == null ? '' : datos.pin).trim() === '';
    if (!(i >= 0 && pinVacio) && !/^\d{4,6}$/.test(String(datos.pin || '')))
      throw new Error('El PIN debe tener entre 4 y 6 dígitos.');
    if (i >= 0 && pinVacio) datos = Object.assign({}, datos, { pin: todos[i].pin || '' });

    /* Un usuario de plataforma no se edita desde el panel de ninguna
       empresa: no es suyo. Y desde una empresa tampoco se fabrica un
       SuperAdmin, que sería la forma fácil de saltarse todo lo de
       arriba. Las dos puertas se cierran aquí, no en la pantalla. */
    if (i >= 0 && esUsuarioPlataforma(todos[i]) && eid !== PLATAFORMA)
      throw new Error('Ese usuario es de la plataforma: no se administra desde aquí.');
    if (datos.rol === 'superadmin' && eid !== PLATAFORMA)
      throw new Error('El rol SuperAdmin no se asigna desde el panel de una empresa.');

    // El acceso debe ser único en TODO el sistema, no sólo dentro de la
    // empresa: si no, el login no sabría a cuál de los dos entrar.
    const choque = todos.findIndex((u) => String(u.usuario).toLowerCase() === acceso);
    if (choque >= 0 && choque !== i)
      throw new Error(
        'Ya existe otro usuario con el acceso "' + acceso + '" (puede ser de otra empresa).'
      );

    const limpio = Object.assign({}, datos, {
      usuario: acceso,
      sucursalId: datos.sucursalId ? Number(datos.sucursalId) : null,
      activo: datos.activo !== false,
      /* Nivel EMPRESA, escrito con todas las letras. Los de plataforma
         se crean por otra vía (ver migrarPlataforma) y aquí ya se
         rechaza el rol superadmin. */
      scope: eid === PLATAFORMA ? SCOPE_PLATAFORMA : SCOPE_EMPRESA,
    });

    if (i >= 0) todos[i] = Object.assign({}, todos[i], limpio);
    else todos.push(conEmpresa(Object.assign({}, limpio, { id: datos.id || 'u-' + id() }), eid));

    escribir(K.usuarios, todos);
    return getUsuarios({ todos: true, empresaId: eid });
  }

  /* No se eliminan: se desactivan, para que los registros que los
     mencionan sigan teniendo sentido. */
  function activarUsuario(usuarioId, activo) {
    const todos = usuariosCrudos();
    const i = todos.findIndex((u) => u.id === usuarioId);
    if (i < 0) return false;
    // Nadie desactiva al SuperAdmin desde el panel de un restaurante.
    if (esUsuarioPlataforma(todos[i]) && empresaActivaId() !== PLATAFORMA)
      throw new Error('Ese usuario es de la plataforma: no se administra desde aquí.');
    todos[i].activo = !!activo;
    escribir(K.usuarios, todos);
    return true;
  }

  /* Busca en TODAS las empresas: al entrar todavía no se sabe a cuál
     pertenece la persona. Se prefiere la empresa activa por si hubiera
     un acceso repetido en datos antiguos. */
  function autenticar(usuarioAcceso, pin) {
    const acceso = String(usuarioAcceso).trim().toLowerCase();
    const candidatos = usuariosCrudos().filter(
      (x) => String(x.usuario).toLowerCase() === acceso
    );
    if (!candidatos.length) return null;

    const activa = empresaActivaId();
    const u =
      candidatos.find((x) => (x.empresaId || EMPRESA_DEFECTO) === activa) || candidatos[0];

    if (u.activo === false) return null;
    if (String(u.pin) !== String(pin)) return null;
    return u;
  }

  /* ===============================================================
     COMPROBANTES DE PAGO

     Se guardan aparte de los pedidos para no engordar esa lista: las
     imágenes son grandes y los pedidos se leen constantemente.
     =============================================================== */
  function getComprobante(pedidoId) {
    const todos = leer(K.comprobantes, {});
    return todos[pedidoId] || null;
  }

  function guardarComprobante(pedidoId, comprobante) {
    const todos = leer(K.comprobantes, {});
    todos[pedidoId] = {
      dataUrl: comprobante.dataUrl,
      nombreArchivo: comprobante.nombreArchivo || '',
      pesoKB: comprobante.pesoKB || 0,
      subido: new Date().toISOString(),
    };
    const ok = escribir(K.comprobantes, todos);
    if (ok) _mutar(pedidoId, (p) => (p.tieneComprobante = true));
    return ok;
  }

  function borrarComprobante(pedidoId) {
    const todos = leer(K.comprobantes, {});
    delete todos[pedidoId];
    escribir(K.comprobantes, todos);
    _mutar(pedidoId, (p) => (p.tieneComprobante = false));
    return true;
  }

  function pesoComprobantesKB() {
    try {
      return Math.round((JSON.stringify(leer(K.comprobantes, {})).length * 2) / 1024);
    } catch (e) {
      return 0;
    }
  }

  /* ===============================================================
     REHIDRATACIÓN Y MIGRACIÓN

     hidratar() deja los globales NASCAR.* con la versión combinada
     (defaults + lo que el admin guardó). Se llama al cargar y después
     de cada cambio de configuración, para que las pantallas que leen
     NASCAR.CATEGORIAS o NASCAR.SUCURSALES vean siempre lo vigente.
     =============================================================== */
  function hidratar() {
    // Todo esto es siempre de la EMPRESA ACTIVA: al cambiar de empresa,
    // las pantallas que leen NASCAR.CARTA ven la carta de la otra.
    NASCAR.CONFIG = getConfig();
    NASCAR.SUCURSALES = getSucursales(); // sólo activas: es lo que ven las vistas
    NASCAR.CATEGORIAS = getCategorias(); // sólo activas
    NASCAR.CARTA = getCarta({ todas: true });
    NASCAR.INVENTARIO = getStock(); // sólo activos
    NASCAR.EMPRESA_ACTUAL = getEmpresaActual();
  }

  /**
   * Estampa `empresaId` en los registros que no lo tengan.
   * Todo lo que ya existía es de NASCAR: el sistema sólo atendía a una
   * empresa. Se hace una vez y no se repite.
   */
  function estampar(clave, empresaId) {
    const lista = leer(clave, null);
    if (!Array.isArray(lista)) return 0;
    let n = 0;
    lista.forEach(function (x) {
      if (x && !x.empresaId) {
        x.empresaId = empresaId;
        n++;
      }
    });
    if (n) escribir(clave, lista);
    return n;
  }

  /**
   * Primera vez que se abre esta versión: se copian los valores de
   * data.js a localStorage. Si ya había datos guardados, NO se tocan.
   */
  function migrar() {
    const hecha = leer(K.migracion, null);

    if (!leer(K.sucursales, null))
      escribir(K.sucursales, DEFAULTS.sucursales.map((s) => Object.assign({ activa: true }, s)));

    if (!leer(K.categorias, null))
      escribir(
        K.categorias,
        DEFAULTS.categorias.map((c, i) => Object.assign({ activa: true, orden: (i + 1) * 10 }, c))
      );

    if (!leer(K.cartaV2, null)) {
      // Se respetan los ajustes que el admin ya hubiera hecho con el
      // formato anterior ({ id: { precio, disponible } }).
      const previos = leer(K.carta, {}) || {};
      escribir(
        K.cartaV2,
        DEFAULTS.carta.map(function (p, i) {
          const ov = previos[p.id] || {};
          return normalizarProductoCarta(
            Object.assign({}, p, {
              precio: typeof ov.precio === 'number' ? ov.precio : p.precio,
              agotado: ov.disponible === false,
            }),
            i
          );
        })
      );
    }

    if (!leer(K.stock, null)) escribir(K.stock, DEFAULTS.stock.map(normalizarProductoStock));
    if (!leer(K.usuarios, null)) escribir(K.usuarios, clonar(DEFAULTS.usuarios));
    if (!leer(K.config, null)) escribir(K.config, {});

    migrarAMultiempresa(hecha);
    migrarModulos(hecha);
    migrarPlataforma(hecha);
    migrarScope(hecha);
    migrarTemas(hecha);
    migrarUnidades();
    ajustarUnidadesReales(hecha);
    cargarCatalogoReal(hecha);

    /* Se sella la versión alcanzada. Antes sólo se escribía la marca la
       primera vez, así que una instalación vieja (v2) volvía a correr la
       migración en cada carga: es inofensivo porque es idempotente, pero
       no tiene por qué repetirse. */
    if (!hecha || (hecha.version || 0) < VERSION_DATOS) {
      escribir(K.migracion, {
        version: VERSION_DATOS,
        fecha: new Date().toISOString(),
        desde: hecha ? hecha.version : null,
      });
    }
    hidratar();
  }

  /**
   * MIGRACIÓN A MULTIEMPRESA (versión 3)
   *
   * Todo lo que existía pertenece a NASCAR, porque el sistema sólo
   * atendía a una empresa. Esta función:
   *   · crea la empresa `empresa_nascar` si no está,
   *   · marca con su `empresaId` los registros que no lo tengan,
   *   · reagrupa la configuración, que era un objeto suelto, en un mapa
   *     por empresa,
   *   · vuelve a indexar los consecutivos para que sean por empresa.
   *
   * Es idempotente: no duplica NASCAR ni vuelve a estampar lo estampado,
   * y NO borra ni reinicia nada.
   */
  function migrarAMultiempresa(marcaPrevia) {
    const yaHecha = marcaPrevia && marcaPrevia.version >= 3;

    // 1. La empresa original
    let empresas = leer(K.empresas, null);
    if (!empresas) empresas = clonar(DEFAULTS.empresas);
    if (!empresas.some((e) => e.id === EMPRESA_DEFECTO)) {
      const base = clonar(DEFAULTS.empresas)[0];
      if (base) empresas.unshift(base);
    }
    escribir(K.empresas, empresas);
    if (!leer(K.empresaActual, null)) escribir(K.empresaActual, EMPRESA_DEFECTO);

    if (yaHecha) return;

    // 2. Todos los registros existentes son de NASCAR
    [K.pedidos, K.dia, K.cartaV2, K.stock, K.usuarios, K.sucursales,
     K.categorias, K.cierres, K.entradas, K.gastos, K.bases].forEach(function (clave) {
      estampar(clave, EMPRESA_DEFECTO);
    });

    // 3. La configuración era un objeto suelto -> mapa por empresa.
    //    Se reconoce el formato antiguo porque trae claves del negocio
    //    (marca, pago, contacto…) en vez de ids de empresa.
    const cfg = leer(K.config, {}) || {};
    const pareceAntigua =
      Object.keys(cfg).length > 0 &&
      !Object.keys(cfg).some((k) => k.indexOf('empresa_') === 0);
    if (pareceAntigua) {
      const nuevo = {};
      nuevo[EMPRESA_DEFECTO] = cfg;
      escribir(K.config, nuevo);
    }

    // 4. Consecutivos: '1|2026-08-28' -> 'empresa_nascar|1|2026-08-28',
    //    para que una empresa no consuma la numeración de otra.
    const seq = leer(K.seq, {}) || {};
    const reindexado = {};
    let cambio = false;
    Object.keys(seq).forEach(function (k) {
      if (k.indexOf('empresa_') === 0) {
        reindexado[k] = seq[k];
      } else {
        reindexado[EMPRESA_DEFECTO + '|' + k] = seq[k];
        cambio = true;
      }
    });
    if (cambio) escribir(K.seq, reindexado);
  }

  /**
   * MIGRACIÓN DE LA PLATAFORMA (versión 5)
   *
   * Añade el usuario SuperAdmin si no está. Va después de
   * migrarAMultiempresa() a propósito: así el estampado de `empresaId`
   * ya pasó y no le toca su empresa de plataforma.
   *
   * Es idempotente y NO pisa nada: si alguien ya cambió el PIN o el
   * nombre del SuperAdmin, se respeta. Sólo se agrega lo que falte.
   */
  function migrarPlataforma() {
    const todos = usuariosCrudos();
    const nuevos = (DEFAULTS.usuariosPlataforma || []).filter(
      (p) => !todos.some((u) => u.id === p.id || u.rol === 'superadmin')
    );
    if (!nuevos.length) return;
    escribir(K.usuarios, todos.concat(clonar(nuevos)));
  }

  /**
   * MIGRACIÓN DE TEMAS (versión 7)
   *
   * Cada empresa pasa a llevar su `theme`: cómo se ve, aparte de qué
   * módulos contrató.
   *
   *   · NASCAR conserva EXACTAMENTE sus colores y su tipografía de
   *     siempre. No se le pone el tema de Taseca: los suyos se toman de
   *     data.js, donde están escritos tal como llevaban años en el CSS.
   *   · Una empresa creada en la versión anterior, que llevaba el campo
   *     `identidad`, lo ve convertido en `theme` sin perder sus colores.
   *   · Cualquier otra recibe el tema base de Taseca.
   *
   * No borra nada ni cambia el aspecto de nadie.
   */
  function migrarTemas(marcaPrevia) {
    if (marcaPrevia && (marcaPrevia.version || 0) >= 7) return;

    const lista = leer(K.empresas, null);
    if (!lista) return;

    const base = (DEFAULTS.empresas || []).reduce(function (mapa, e) {
      mapa[e.id] = e.theme;
      return mapa;
    }, {});

    escribir(
      K.empresas,
      lista.map(function (e) {
        if (e.theme) return e;

        /* El campo `identidad` de la versión anterior traía los colores
           y las iniciales: se traducen en vez de perderse. */
        const previa = e.identidad || {};
        const partida = base[e.id] || {
          primary: previa.colorPrimario,
          secondary: previa.colorSecundario,
          iniciales: previa.iniciales,
          lema: previa.lema,
        };

        const limpia = Object.assign({}, e, { theme: normalizarTheme(partida, e.nombre) });
        delete limpia.identidad;
        return limpia;
      })
    );
  }

  /**
   * MIGRACIÓN DE SCOPE (versión 6)
   *
   * Separa de una vez los dos niveles del sistema:
   *
   *   · Los usuarios de PLATAFORMA (el SuperAdmin de Taseca) dejan de
   *     llevar un `empresaId` inventado y pasan a `scope: 'platform'`
   *     con `empresaId: null`. Ya no pertenecen a ninguna empresa ni
   *     de mentira.
   *
   *   · Los usuarios de EMPRESA quedan marcados con `scope: 'empresa'`,
   *     conservando su `empresaId` tal cual.
   *
   * No borra ni mueve nada más: es sólo poner nombre a lo que ya era.
   */
  function migrarScope(marcaPrevia) {
    if (marcaPrevia && (marcaPrevia.version || 0) >= 6) return;

    const todos = leer(K.usuarios, null);
    if (!todos) return;

    let cambio = false;
    const migrados = todos.map(function (u) {
      const esPlataforma = u.scope === SCOPE_PLATAFORMA || u.empresaId === PLATAFORMA ||
        u.rol === 'superadmin';
      const scope = esPlataforma ? SCOPE_PLATAFORMA : SCOPE_EMPRESA;
      const empresaId = esPlataforma ? null : u.empresaId;
      if (u.scope === scope && u.empresaId === empresaId) return u;
      cambio = true;
      return Object.assign({}, u, { scope: scope, empresaId: empresaId });
    });

    if (cambio) escribir(K.usuarios, migrados);
  }

  /**
   * MIGRACIÓN A UNIDADES / LOCALES (versión 8)
   *
   * Las sucursales pasan a ser UNIDADES: cada una con tipo de negocio,
   * identidad opcional y su propio catálogo (carta, categorías y stock).
   *
   *   · A cada unidad que no lo tenga se le pone tipo de negocio
   *     'restaurante' —lo que eran— e identidad vacía. La fecha de
   *     creación no se inventa: queda en null.
   *   · Los productos de carta, las categorías y los productos de stock
   *     que no decían de qué unidad eran ("[] = todas") pasan a decirlo:
   *     las unidades que la empresa tiene en ese momento. Es exactamente
   *     lo que significaban, así que nadie deja de ver nada. Una unidad
   *     creada DESPUÉS empieza con su catálogo vacío: no hereda la carta
   *     ni el stock de otra.
   *
   * No borra, no mueve y no reescribe pedidos, cierres, gastos, bases,
   * entradas ni menús del día: esos ya llevaban `sucursalId`.
   *
   * Es idempotente —sólo completa lo que falta— y por eso también corre
   * al restaurar un respaldo antiguo.
   */
  /* ---- La semilla de fábrica, unidad por unidad ----

     data.js trae el catálogo de cada local con la unidad a la que
     pertenece (`sucursales: [4]` = la arepera). Pero en una instalación
     que ya venía funcionando los ids NO coinciden: la arepera puede ser
     la unidad 7. Por eso la correspondencia se hace por NOMBRE, que es
     lo único estable entre data.js y lo guardado. */
  function nombreUnidad(s) {
    return String((s && s.nombre) || '')
      .trim()
      .toLowerCase();
  }

  function mapaSemillaUnidades(eid) {
    const guardadas = soloDeEmpresa(leer(K.sucursales, []) || [], eid);
    const mapa = {};
    DEFAULTS.sucursales.forEach(function (s) {
      const real = guardadas.find((x) => nombreUnidad(x) === nombreUnidad(s));
      if (real) mapa[Number(s.id)] = Number(real.id);
    });
    return mapa;
  }

  function unidadesReales(x, mapa) {
    return (x.sucursales || []).map((n) => mapa[Number(n)]).filter(Boolean);
  }

  /* Lo que data.js le da de fábrica a UNA unidad. Un registro sin
     `sucursales` es de todas: así se comportaba el catálogo antes de que
     existieran las unidades. */
  function semillaDeUnidad(defaults, eid, suc) {
    const mapa = mapaSemillaUnidades(eid);
    return defaults.filter(function (x) {
      if (!(x.sucursales || []).length) return true;
      return unidadesReales(x, mapa).indexOf(Number(suc)) >= 0;
    });
  }

  /**
   * CARGA DEL CATÁLOGO REAL (versión 9)
   *
   * Cada local de NASCAR tiene lo suyo: la arepera su carta y sus
   * insumos, el bar su planilla de licores, los restaurantes sólo el
   * menú del día. Esta migración pone en localStorage lo que data.js
   * trae para cada unidad y que todavía no esté.
   *
   * Es ADITIVA: nunca reescribe un producto que ya existe (se reconoce
   * por su id o su código), nunca borra y nunca toca un precio que el
   * administrador haya cambiado. Corre una sola vez.
   */
  /**
   * LOS LOCALES REALES EN INSTALACIONES VIEJAS (versión 10)
   *
   * Un navegador que se abrió con la demostración guarda sus propias
   * sucursales (Circuito Norte, Box Sur) y nunca vio los cuatro locales
   * de data.js, porque la semilla sólo se copia la primera vez.
   *
   *   1. Crea, con un id nuevo, cada local de data.js que no exista
   *      (se reconoce por NOMBRE).
   *   2. Desactiva las sucursales de NASCAR.UNIDADES_RETIRADAS, sólo si
   *      ya hay locales reales activos. No borra nada.
   */
  function ajustarUnidadesReales(marcaPrevia) {
    if (marcaPrevia && (marcaPrevia.version || 0) >= 10) return;
    const todas = leer(K.sucursales, null);
    if (!Array.isArray(todas)) return;

    const eid = EMPRESA_DEFECTO;
    const mia = (x) => (x.empresaId || EMPRESA_DEFECTO) === eid;
    const ahora = new Date().toISOString();
    let cambio = false;

    DEFAULTS.sucursales.forEach(function (s) {
      const propias = todas.filter(mia);
      if (propias.some((x) => nombreUnidad(x) === nombreUnidad(s))) return;
      const nuevoId = Math.max(0, ...propias.map((x) => Number(x.id))) + 1;
      todas.push(
        conEmpresa(
          Object.assign({ activa: true, branding: { logo: '', color: '' } }, clonar(s), {
            id: nuevoId,
            creado: ahora,
          }),
          eid
        )
      );
      cambio = true;
    });

    const reales = DEFAULTS.sucursales.map(nombreUnidad);
    const hayReales = todas.some(
      (x) => mia(x) && x.activa !== false && reales.indexOf(nombreUnidad(x)) >= 0
    );
    const retiradas = (NASCAR.UNIDADES_RETIRADAS || []).map((n) => nombreUnidad({ nombre: n }));
    if (hayReales) {
      todas.forEach(function (x) {
        if (mia(x) && x.activa !== false && retiradas.indexOf(nombreUnidad(x)) >= 0) {
          x.activa = false;
          cambio = true;
        }
      });
    }

    if (cambio) escribir(K.sucursales, todas);
  }

  function cargarCatalogoReal(marcaPrevia) {
    /* Vuelve a correr en la 10: un navegador que abrió la versión 9 sin
       tener los locales reales la selló sin cargar nada. Es aditiva, así
       que repetirla no duplica. */
    if (marcaPrevia && (marcaPrevia.version || 0) >= 10) return;

    const eid = EMPRESA_DEFECTO;
    const mapa = mapaSemillaUnidades(eid);
    if (!Object.keys(mapa).length) return; // ninguna unidad de fábrica por aquí

    const mia = (x) => (x.empresaId || EMPRESA_DEFECTO) === eid;

    function agregarFaltantes(clave, defaults, llave, preparar) {
      const lista = leer(clave, null);
      if (!Array.isArray(lista)) return 0;
      let n = 0;
      defaults.forEach(function (d, i) {
        const ids = unidadesReales(d, mapa);
        if (!ids.length) return; // su unidad no existe en esta instalación
        if (lista.some((x) => mia(x) && x[llave] === d[llave])) return;
        lista.push(conEmpresa(preparar(Object.assign({}, d, { sucursales: ids }), i), eid));
        n++;
      });
      if (n) escribir(clave, lista);
      return n;
    }

    agregarFaltantes(K.categorias, DEFAULTS.categorias, 'id', (c, i) =>
      Object.assign({ activa: true, orden: (i + 1) * 10 }, c)
    );
    agregarFaltantes(K.cartaV2, DEFAULTS.carta, 'id', (p, i) => normalizarProductoCarta(p, i));
    agregarFaltantes(K.stock, DEFAULTS.stock, 'codigo', (p) => normalizarProductoStock(p));

    /* Los platos del día de ejemplo de los restaurantes. Sólo si esa
       unidad no tiene nada publicado hoy: no se le pisa el menú a nadie. */
    /* Qué unidades tienen YA algo publicado hoy se mira ANTES de sembrar:
       si se preguntara plato por plato, el primero de ejemplo haría que
       los demás se saltaran. */
    const conMenuHoy = {};
    (NASCAR.SEMILLA_DIA || []).forEach(function (p) {
      const suc = mapa[Number(p.sucursalId)];
      if (!suc || conMenuHoy[suc] !== undefined) return;
      conMenuHoy[suc] = getPlatosDia(hoy(), suc, eid).length > 0;
    });
    (NASCAR.SEMILLA_DIA || []).forEach(function (p) {
      const suc = mapa[Number(p.sucursalId)];
      if (!suc || conMenuHoy[suc]) return;
      guardarPlatoDiaInterno(
        Object.assign({}, p, { sucursalId: suc, fecha: hoy(), vendidos: 0 }),
        eid
      );
    });
  }

  function migrarUnidades() {
    const sucursales = leer(K.sucursales, null);
    if (Array.isArray(sucursales)) {
      let cambio = false;
      const completas = sucursales.map(function (s) {
        if (s.tipoNegocio && s.branding && Object.prototype.hasOwnProperty.call(s, 'creado')) return s;
        cambio = true;
        return Object.assign({}, s, {
          tipoNegocio: s.tipoNegocio || NASCAR.TIPO_NEGOCIO_DEFECTO || 'restaurante',
          branding: s.branding || { logo: '', color: '' },
          creado: s.creado || null,
        });
      });
      if (cambio) escribir(K.sucursales, completas);
    }

    const idsPorEmpresa = {};
    (leer(K.sucursales, []) || []).forEach(function (s) {
      const eid = s.empresaId || EMPRESA_DEFECTO;
      (idsPorEmpresa[eid] = idsPorEmpresa[eid] || []).push(Number(s.id));
    });

    [K.cartaV2, K.categorias, K.stock].forEach(function (clave) {
      const lista = leer(clave, null);
      if (!Array.isArray(lista)) return;
      let cambio = false;
      lista.forEach(function (x) {
        if (!x || (Array.isArray(x.sucursales) && x.sucursales.length)) return;
        const ids = idsPorEmpresa[x.empresaId || EMPRESA_DEFECTO];
        if (!ids || !ids.length) return;
        x.sucursales = ids.slice();
        cambio = true;
      });
      if (cambio) escribir(clave, lista);
    });
  }

  /**
   * MIGRACIÓN DE MÓDULOS (versión 4)
   *
   * La versión anterior guardaba cuatro módulos, uno de ellos 'gastos'.
   * Los módulos de la plataforma son tres — Básico, Stock y Cierre — y
   * Gastos pasó a ser parte de Básico, que es donde le corresponde: es
   * dinero del punto, como los pagos y las ventas.
   *
   * Esta migración deja el mapa de cada empresa en su forma canónica.
   * Como las empresas que ya existían tenían todo encendido, no pierden
   * nada: la clave 'gastos' desaparece y la sección queda dentro de
   * Básico, que siempre está activo.
   *
   * NO cambia qué ve nadie ni borra dato alguno.
   */
  function migrarModulos(marcaPrevia) {
    if (marcaPrevia && (marcaPrevia.version || 0) >= 4) return;

    const lista = leer(K.empresas, null);
    if (!lista) return;
    escribir(
      K.empresas,
      lista.map((e) => Object.assign({}, e, { modulos: normalizarModulos(e.modulos) }))
    );
  }

  /* ===============================================================
     PLATOS DEL DÍA  (dinámicos, por sucursal y fecha)
     =============================================================== */
  function getTodosPlatosDia(empresaId) {
    return soloDeEmpresa(leer(K.dia, []), empresaId || empresaActivaId());
  }

  function getPlatosDia(fecha, sucursalId, empresaId) {
    fecha = fecha || hoy();
    return getTodosPlatosDia(empresaId).filter(function (p) {
      if (p.fecha !== fecha) return false;
      if (sucursalId && Number(p.sucursalId) !== Number(sucursalId)) return false;
      return true;
    });
  }

  /* OJO con el patrón de aquí abajo, que es el que hay que respetar en
     todo lo que escriba en localStorage:

       · se LEE la lista completa    -> leer(K.dia, [])
       · se filtra sólo para BUSCAR  -> soloDeEmpresa(...)
       · se ESCRIBE la lista completa

     Leer la lista ya filtrada por empresa y volver a escribirla entera
     borra los registros de las demás empresas. */
  function guardarPlatoDia(plato, empresaId) {
    exigirPermisoMenu();
    if (!plato.id) exigirUnidadOperativa(plato.sucursalId, empresaId);
    return guardarPlatoDiaInterno(plato, empresaId);
  }

  /* Sin comprobar la sesión: sólo para la semilla de datos, que se siembra
     al abrir cualquier pantalla —también con un perfil que no publica
     menú—. No se exporta. */
  function guardarPlatoDiaInterno(plato, empresaId) {
    const eid = empresaId || empresaActivaId();
    const todos = leer(K.dia, []);

    if (plato.emoji !== undefined) plato.emoji = String(plato.emoji || '').trim().slice(0, 8);

    if (plato.id) {
      // Sólo se puede editar un plato de la propia empresa
      const i = todos.findIndex(
        (p) => p.id === plato.id && (p.empresaId || EMPRESA_DEFECTO) === eid
      );
      if (i >= 0) todos[i] = Object.assign({}, todos[i], plato, { empresaId: eid });
    } else {
      plato.id = id();
      plato.fecha = plato.fecha || hoy();
      plato.creado = new Date().toISOString();
      /* Orden de presentación: el nuevo va al final de su sucursal y fecha.
         Los platos de antes no tenían orden; se les pone el que ya tenían
         en pantalla, sin tocar nada más de ellos. */
      if (typeof plato.orden !== 'number') {
        plato.orden = renumerarPlatos(todos, eid, plato.fecha, plato.sucursalId).length + 1;
      }
      todos.push(conEmpresa(plato, eid));
    }

    escribir(K.dia, todos);
    return plato;
  }

  /* Se borra de la lista completa, y sólo si es de esta empresa: así no
     se puede eliminar el plato de otra ni se pierden los suyos. */
  function borrarPlatoDia(platoId, empresaId) {
    exigirPermisoMenu();
    const eid = empresaId || empresaActivaId();
    return escribir(
      K.dia,
      leer(K.dia, []).filter(
        (p) => !(p.id === platoId && (p.empresaId || EMPRESA_DEFECTO) === eid)
      )
    );
  }

  /* Copia los platos de una fecha a otra (para no re-escribir todo cada día) */
  function copiarPlatosDia(fechaOrigen, fechaDestino, sucursalId) {
    exigirPermisoMenu();
    const eid = empresaActivaId();
    const origen = getPlatosDia(fechaOrigen, sucursalId);
    if (!origen.length) return 0;

    const todos = leer(K.dia, []); // la lista completa, no la de esta empresa
    origen.forEach(function (p) {
      todos.push(
        conEmpresa(
          Object.assign({}, p, {
            id: id(),
            fecha: fechaDestino,
            vendidos: 0,
            creado: new Date().toISOString(),
          }),
          eid
        )
      );
    });
    escribir(K.dia, todos);
    return origen.length;
  }

  /* ===============================================================
     MENÚ DEL DÍA · MODALIDAD (armado / chef)

     Cada EMPRESA + SUCURSAL + FECHA tiene como mucho UN documento en
     K.menusDia que dice qué se publica ese día:

       { id, empresaId, sucursalId, fecha,
         tipo: 'armado' | 'chef',
         armado: { nombre, descripcion, precio, disponible, vendidos,
                   categorias: [{ id, nombre, icono, orden, obligatoria, activa,
                                  opciones: [{ id, nombre, activa, orden }] }] },
         creado, actualizado, actualizadoPor }

     · Menú ARMADO  → vive entero dentro del documento.
     · Menú del CHEF → sus platos siguen siendo los registros de K.dia, uno
       por plato (nombre, desc, precio, emoji, disponible, orden, cupos).
       Son los mismos "platos del día" de siempre: nada se migra ni se borra.

     Si una sucursal no tiene documento para esa fecha se comporta como
     antes de que existieran las modalidades: menú del chef con los platos
     de K.dia. Así los datos anteriores se siguen viendo igual.

     Cambiar de tipo NO borra lo del otro: sólo cambia qué se muestra.
     =============================================================== */
  const TIPOS_MENU = ['armado', 'chef'];

  /* Doble barrera, como anularPedido() y setModulos(): la pantalla ya
     exige el permiso, pero si hay sesión el store también lo exige. Sin
     sesión se permite (consola, semillas). */
  function exigirPermisoMenu() {
    const sesion = getSesion();
    if (sesion && NASCAR.Auth && !NASCAR.Auth.puede('menu', sesion))
      throw new Error('Tu perfil no puede publicar el menú del día.');
  }

  /* ---- Orden de los platos del chef ---- */
  function ordenDePlato(p) {
    return typeof p.orden === 'number' ? p.orden : Number.MAX_SAFE_INTEGER;
  }

  function compararPlatos(a, b) {
    return (
      ordenDePlato(a) - ordenDePlato(b) ||
      String(a.creado || '').localeCompare(String(b.creado || ''))
    );
  }

  /* Numera 1..n los platos de una sucursal y fecha en el orden en que ya
     se veían. Modifica los objetos de `todos` (la lista completa). */
  function renumerarPlatos(todos, eid, fecha, sucursalId) {
    const hermanos = todos
      .filter(
        (p) =>
          (p.empresaId || EMPRESA_DEFECTO) === eid &&
          p.fecha === fecha &&
          Number(p.sucursalId) === Number(sucursalId)
      )
      .sort(compararPlatos);
    hermanos.forEach((p, i) => (p.orden = i + 1));
    return hermanos;
  }

  /** Platos del chef de una sucursal y fecha, en su orden de presentación. */
  function getPlatosChef(fecha, sucursalId, empresaId) {
    return getPlatosDia(fecha || hoy(), sucursalId, empresaId)
      .filter((p) => Number(p.sucursalId) === Number(sucursalId))
      .sort(compararPlatos);
  }

  function moverPlatoDia(platoId, delta) {
    exigirPermisoMenu();
    const eid = empresaActivaId();
    const todos = leer(K.dia, []); // lista completa
    const p = todos.find((x) => x.id === platoId && (x.empresaId || EMPRESA_DEFECTO) === eid);
    if (!p) throw new Error('Ese plato ya no existe.');
    moverEnLista(renumerarPlatos(todos, eid, p.fecha, p.sucursalId), platoId, delta);
    escribir(K.dia, todos);
  }

  /* ---- Utilidades del menú armado ---- */
  function porOrden(a, b) {
    return (Number(a.orden) || 0) - (Number(b.orden) || 0);
  }

  function textoMenu(v, max) {
    return String(v == null ? '' : v).replace(/\s+/g, ' ').trim().slice(0, max || 80);
  }

  function siguienteOrden(lista) {
    return lista.reduce((m, x) => Math.max(m, Number(x.orden) || 0), 0) + 1;
  }

  /* Sube (-1) o baja (+1) un elemento y deja el orden 1..n sin huecos. */
  function moverEnLista(lista, idElemento, delta) {
    lista.sort(porOrden);
    const i = lista.findIndex((x) => x.id === idElemento);
    if (i < 0) throw new Error('Ese elemento ya no existe.');
    const j = i + (delta < 0 ? -1 : 1);
    if (j >= 0 && j < lista.length) {
      const tmp = lista[i];
      lista[i] = lista[j];
      lista[j] = tmp;
    }
    lista.forEach((x, k) => (x.orden = k + 1));
  }

  function nombreRepetido(lista, nombre, exceptoId) {
    const n = nombre.toLowerCase();
    return lista.some((x) => x.id !== exceptoId && String(x.nombre).toLowerCase() === n);
  }

  /* Cuántas opciones puede elegir el cliente en una categoría. Los menús
     creados antes de esta regla no traen el campo: valen 1, que es como
     funcionaban. Nunca se decide por el nombre de la categoría. */
  function maxSeleccionValido(v) {
    const n = Math.floor(Number(v));
    return isFinite(n) && n >= 1 ? Math.min(n, 10) : 1;
  }

  function categoriasArmadoPorDefecto() {
    return (NASCAR.CATEGORIAS_ARMADO || []).map(function (c, i) {
      return {
        id: id(),
        nombre: c.nombre,
        icono: c.icono || '',
        orden: i + 1,
        obligatoria: c.obligatoria !== false,
        maxSeleccion: maxSeleccionValido(c.maxSeleccion),
        activa: true,
        opciones: [],
      };
    });
  }

  function normalizarArmado(a) {
    a = a || {};
    return {
      nombre: textoMenu(a.nombre, 60) || 'Menú del día',
      descripcion: textoMenu(a.descripcion, 240),
      precio: Math.max(0, Number(a.precio) || 0),
      disponible: a.disponible !== false,
      vendidos: Number(a.vendidos) || 0,
      categorias: (Array.isArray(a.categorias) ? a.categorias : [])
        .filter((c) => c && c.id)
        .map(function (c) {
          return {
            id: c.id,
            nombre: textoMenu(c.nombre, 40),
            icono: textoMenu(c.icono, 8),
            orden: Number(c.orden) || 0,
            obligatoria: c.obligatoria !== false,
            maxSeleccion: maxSeleccionValido(c.maxSeleccion),
            activa: c.activa !== false,
            opciones: (Array.isArray(c.opciones) ? c.opciones : [])
              .filter((o) => o && o.id)
              .map((o) => ({
                id: o.id,
                nombre: textoMenu(o.nombre, 60),
                activa: o.activa !== false,
                orden: Number(o.orden) || 0,
              }))
              .sort(porOrden),
          };
        })
        .sort(porOrden),
    };
  }

  /* ---- Lo que el cliente ve encima del menú (título y mensaje) ----

     Tres niveles, de lo más concreto a lo más general:

       1. el texto de ESA fecha           (doc de la fecha, campo `publico`)
       2. el texto de la UNIDAD           (doc con fecha '*', el de siempre)
       3. el de fábrica, en data.js       (NASCAR.TEXTO_MENU_DIA)

     Así el administrador escribe el mensaje UNA vez por unidad y sólo lo
     cambia el día que quiera decir otra cosa. Cada unidad tiene el suyo: el
     mensaje de la arepera no aparece en el bar. */
  const FECHA_TEXTO_UNIDAD = '*';

  function normalizarTextoMenu(p) {
    p = p || {};
    return { titulo: textoMenu(p.titulo, 60), mensaje: textoMenu(p.mensaje, 400) };
  }

  function getTextoMenuDia(fecha, sucursalId, empresaId) {
    const eid = empresaId || empresaActivaId();
    const f = fecha || hoy();
    const docs = leer(K.menusDia, []);
    const delDia = docs.find((x) => esMenuDe(x, eid, f, sucursalId));
    const deUnidad = docs.find((x) => esMenuDe(x, eid, FECHA_TEXTO_UNIDAD, sucursalId));
    const base = normalizarTextoMenu(NASCAR.TEXTO_MENU_DIA);

    function resolver(campo) {
      const dia = delDia ? normalizarTextoMenu(delDia.publico)[campo] : '';
      if (dia) return { valor: dia, origen: 'fecha' };
      const uni = deUnidad ? normalizarTextoMenu(deUnidad.publico)[campo] : '';
      if (uni) return { valor: uni, origen: 'unidad' };
      return { valor: base[campo], origen: 'defecto' };
    }

    const tit = resolver('titulo');
    const men = resolver('mensaje');
    const propio = delDia ? normalizarTextoMenu(delDia.publico) : { titulo: '', mensaje: '' };

    return {
      titulo: tit.valor,
      mensaje: men.valor,
      origenTitulo: tit.origen,
      origenMensaje: men.origen,
      propioDeLaFecha: !!(propio.titulo || propio.mensaje),
      deLaUnidad: deUnidad ? normalizarTextoMenu(deUnidad.publico) : { titulo: '', mensaje: '' },
    };
  }

  /* El texto de la unidad vive en un documento con fecha '*' dentro de la
     misma lista: mismo permiso, mismo aislamiento por empresa y unidad, y
     sin una clave nueva. Nunca se confunde con el menú de un día porque
     ninguna consulta por fecha lo alcanza. */
  function guardarTextoUnidad(sucursalId, texto) {
    exigirPermisoMenu();
    const eid = empresaActivaId();
    if (!sucursalId || !getSucursal(sucursalId, eid))
      throw new Error('Elige una unidad de esta empresa.');

    const todos = leer(K.menusDia, []);
    const ahora = new Date().toISOString();
    const i = todos.findIndex((x) => esMenuDe(x, eid, FECHA_TEXTO_UNIDAD, sucursalId));
    const doc =
      i >= 0
        ? Object.assign({}, todos[i])
        : conEmpresa(
            { id: id(), sucursalId: Number(sucursalId), fecha: FECHA_TEXTO_UNIDAD, tipo: 'texto', creado: ahora },
            eid
          );
    doc.publico = normalizarTextoMenu(texto);
    doc.actualizado = ahora;
    if (i >= 0) todos[i] = doc;
    else todos.push(doc);
    escribir(K.menusDia, todos);
    return doc.publico;
  }

  function guardarTextoFecha(fecha, sucursalId, texto) {
    return mutarMenuDia(fecha, sucursalId, function (doc) {
      doc.publico = normalizarTextoMenu(texto);
    });
  }

  /**
   * guardarTextoMenuDia(fecha, unidad, { titulo, mensaje }, alcance)
   *   alcance 'unidad' (por defecto) → todos los días de esa unidad
   *   alcance 'fecha'                → sólo ese día; vacío = vuelve al de la unidad
   */
  function guardarTextoMenuDia(fecha, sucursalId, texto, alcance) {
    return alcance === 'fecha'
      ? guardarTextoFecha(fecha, sucursalId, texto)
      : guardarTextoUnidad(sucursalId, texto);
  }

  function esMenuDe(m, eid, fecha, sucursalId) {
    return (
      (m.empresaId || EMPRESA_DEFECTO) === eid &&
      m.fecha === fecha &&
      Number(m.sucursalId) === Number(sucursalId)
    );
  }

  /* ---- Lectura ---- */

  /** El documento de modalidad de esa sucursal y fecha, o null. */
  function getMenuDia(fecha, sucursalId, empresaId) {
    const eid = empresaId || empresaActivaId();
    const f = fecha || hoy();
    const m = leer(K.menusDia, []).find((x) => esMenuDe(x, eid, f, sucursalId));
    return m
      ? Object.assign({}, m, { armado: normalizarArmado(m.armado), publico: normalizarTextoMenu(m.publico) })
      : null;
  }

  /** Qué modalidad se publica. Sin documento: la de siempre, el chef. */
  function tipoMenuDia(fecha, sucursalId, empresaId) {
    const m = getMenuDia(fecha, sucursalId, empresaId);
    return m && TIPOS_MENU.indexOf(m.tipo) >= 0 ? m.tipo : 'chef';
  }

  /**
   * Lo que ve el cliente de UNA sucursal en una fecha. Nunca mezcla
   * modalidades ni empresas.
   *
   *   { tipo, fecha, sucursalId, menuId,
   *     platos: [...],   // chef: sólo los disponibles, en su orden
   *     armado: {...},   // armado: sólo categorías activas con opciones activas
   *     publicado, motivo }
   */
  function getMenuPublico(fecha, sucursalId, empresaId) {
    const eid = empresaId || empresaActivaId();
    const f = fecha || hoy();
    const doc = getMenuDia(f, sucursalId, eid);
    const tipo = doc && TIPOS_MENU.indexOf(doc.tipo) >= 0 ? doc.tipo : 'chef';

    const r = {
      tipo: tipo,
      fecha: f,
      sucursalId: Number(sucursalId),
      menuId: doc ? doc.id : null,
      platos: [],
      armado: null,
      publicado: false,
      motivo: '',
      // Título y mensaje configurables de esta unidad/fecha (ver getTextoMenuDia)
      texto: getTextoMenuDia(f, sucursalId, eid),
    };

    if (tipo === 'chef') {
      r.platos = getPlatosChef(f, sucursalId, eid).filter((p) => p.disponible !== false);
      r.publicado = r.platos.length > 0;
      if (!r.publicado) r.motivo = 'No hay platos del chef disponibles para esta fecha.';
      return r;
    }

    const a = doc.armado;
    const categorias = a.categorias
      .filter((c) => c.activa && c.nombre)
      .map((c) => Object.assign({}, c, { opciones: c.opciones.filter((o) => o.activa && o.nombre) }))
      .filter((c) => c.opciones.length > 0);

    if (!a.disponible) r.motivo = 'El menú armado está marcado como no disponible.';
    else if (!(a.precio > 0)) r.motivo = 'Falta ponerle precio al menú armado.';
    else if (!categorias.length) r.motivo = 'Ninguna categoría tiene opciones activas todavía.';
    else {
      r.armado = Object.assign({}, a, { categorias: categorias });
      r.publicado = true;
    }
    return r;
  }

  /* ---- Escritura ---- */

  /* Todas las escrituras de la modalidad pasan por aquí: permiso, lista
     COMPLETA, sólo el documento de esta empresa/sucursal/fecha, y si no
     existe se crea con las categorías por defecto. Si `cambio` lanza un
     error no se escribe nada. */
  function mutarMenuDia(fecha, sucursalId, cambio) {
    exigirPermisoMenu();
    const eid = empresaActivaId();
    const f = fecha || hoy();
    if (!/^\d{4}-\d{2}-\d{2}$/.test(f)) throw new Error('La fecha no es válida.');
    if (!sucursalId) throw new Error('Elige una unidad de esta empresa.');
    exigirUnidadOperativa(sucursalId, eid);

    const todos = leer(K.menusDia, []);
    const ahora = new Date().toISOString();
    const i = todos.findIndex((x) => esMenuDe(x, eid, f, sucursalId));

    const doc =
      i >= 0
        ? Object.assign({}, todos[i])
        : conEmpresa(
            {
              id: id(),
              sucursalId: Number(sucursalId),
              fecha: f,
              tipo: 'chef', // lo que ya se veía antes de crear el documento
              armado: { categorias: categoriasArmadoPorDefecto() },
              creado: ahora,
            },
            eid
          );
    doc.armado = normalizarArmado(clonar(doc.armado || {}));

    const resultado = cambio(doc);

    doc.armado = normalizarArmado(doc.armado);
    doc.publico = normalizarTextoMenu(doc.publico);
    doc.actualizado = ahora;
    const s = getSesion();
    doc.actualizadoPor = s ? s.nombre || '' : '';

    if (i >= 0) todos[i] = doc;
    else todos.push(doc);
    escribir(K.menusDia, todos);
    return resultado === undefined ? doc : resultado;
  }

  function buscarCategoriaArmado(doc, catId) {
    const c = doc.armado.categorias.find((x) => x.id === catId);
    if (!c) throw new Error('Esa categoría ya no existe.');
    return c;
  }

  function setTipoMenuDia(fecha, sucursalId, tipo) {
    if (TIPOS_MENU.indexOf(tipo) < 0) throw new Error('Tipo de menú desconocido.');
    return mutarMenuDia(fecha, sucursalId, function (doc) {
      doc.tipo = tipo;
    });
  }

  function guardarDatosArmado(fecha, sucursalId, datos) {
    const d = datos || {};
    return mutarMenuDia(fecha, sucursalId, function (doc) {
      const a = doc.armado;
      if (d.nombre !== undefined) {
        const nombre = textoMenu(d.nombre, 60);
        if (nombre.length < 3) throw new Error('Escribe el nombre del menú (mínimo 3 letras).');
        a.nombre = nombre;
      }
      if (d.descripcion !== undefined) a.descripcion = textoMenu(d.descripcion, 240);
      if (d.precio !== undefined) {
        const precio = Number(d.precio);
        if (!(precio > 0)) throw new Error('El precio del menú debe ser mayor a cero.');
        a.precio = Math.round(precio);
      }
      if (d.disponible !== undefined) a.disponible = !!d.disponible;
    });
  }

  function guardarCategoriaArmado(fecha, sucursalId, datos) {
    const d = datos || {};
    return mutarMenuDia(fecha, sucursalId, function (doc) {
      const cats = doc.armado.categorias;
      let c = d.id ? buscarCategoriaArmado(doc, d.id) : null;

      if (!c || d.nombre !== undefined) {
        const nombre = textoMenu(d.nombre, 40);
        if (nombre.length < 2) throw new Error('Escribe el nombre de la categoría.');
        if (nombreRepetido(cats, nombre, c && c.id))
          throw new Error('Ya hay una categoría llamada "' + nombre + '".');
        if (c) c.nombre = nombre;
        else {
          c = {
            id: id(),
            nombre: nombre,
            icono: '',
            orden: siguienteOrden(cats),
            obligatoria: true,
            maxSeleccion: maxSeleccionValido(d.maxSeleccion),
            activa: true,
            opciones: [],
          };
          cats.push(c);
        }
      }
      if (d.icono !== undefined) c.icono = textoMenu(d.icono, 8);
      if (d.obligatoria !== undefined) c.obligatoria = !!d.obligatoria;
      if (d.maxSeleccion !== undefined) c.maxSeleccion = maxSeleccionValido(d.maxSeleccion);
      if (d.activa !== undefined) c.activa = !!d.activa;
      return Object.assign({}, c);
    });
  }

  function borrarCategoriaArmado(fecha, sucursalId, catId) {
    return mutarMenuDia(fecha, sucursalId, function (doc) {
      buscarCategoriaArmado(doc, catId);
      doc.armado.categorias = doc.armado.categorias.filter((c) => c.id !== catId);
      doc.armado.categorias.forEach((c, k) => (c.orden = k + 1));
    });
  }

  function moverCategoriaArmado(fecha, sucursalId, catId, delta) {
    return mutarMenuDia(fecha, sucursalId, function (doc) {
      moverEnLista(doc.armado.categorias, catId, delta);
    });
  }

  function guardarOpcionArmado(fecha, sucursalId, catId, datos) {
    const d = datos || {};
    return mutarMenuDia(fecha, sucursalId, function (doc) {
      const c = buscarCategoriaArmado(doc, catId);
      let o = d.id ? c.opciones.find((x) => x.id === d.id) : null;
      if (d.id && !o) throw new Error('Esa opción ya no existe.');

      if (!o || d.nombre !== undefined) {
        const nombre = textoMenu(d.nombre, 60);
        if (nombre.length < 2) throw new Error('Escribe el nombre de la opción.');
        if (nombreRepetido(c.opciones, nombre, o && o.id))
          throw new Error('"' + nombre + '" ya está en ' + c.nombre + '.');
        if (o) o.nombre = nombre;
        else {
          o = { id: id(), nombre: nombre, activa: true, orden: siguienteOrden(c.opciones) };
          c.opciones.push(o);
        }
      }
      if (d.activa !== undefined) o.activa = !!d.activa;
      return Object.assign({}, o);
    });
  }

  function borrarOpcionArmado(fecha, sucursalId, catId, opcionId) {
    return mutarMenuDia(fecha, sucursalId, function (doc) {
      const c = buscarCategoriaArmado(doc, catId);
      if (!c.opciones.some((o) => o.id === opcionId)) throw new Error('Esa opción ya no existe.');
      c.opciones = c.opciones.filter((o) => o.id !== opcionId);
      c.opciones.forEach((o, k) => (o.orden = k + 1));
    });
  }

  function moverOpcionArmado(fecha, sucursalId, catId, opcionId, delta) {
    return mutarMenuDia(fecha, sucursalId, function (doc) {
      moverEnLista(buscarCategoriaArmado(doc, catId).opciones, opcionId, delta);
    });
  }

  /**
   * Copia el menú de una fecha a otra, sucursal por sucursal: la modalidad,
   * el menú armado con sus categorías y opciones, y los platos del chef.
   *
   * Una sucursal que YA tiene algo en la fecha destino no se toca: copiar
   * nunca pisa ni duplica un menú.
   *
   *   → { copiadas: n, omitidas: ['Sede…'], vacias: n }
   */
  function copiarMenuDia(fechaOrigen, fechaDestino, sucursalId) {
    exigirPermisoMenu();
    const eid = empresaActivaId();
    if (!fechaOrigen || !fechaDestino || fechaOrigen === fechaDestino)
      throw new Error('Elige dos fechas distintas.');

    const sucursales = sucursalId
      ? [getSucursal(sucursalId, eid)].filter(Boolean)
      : getSucursales({ todas: true, empresaId: eid });

    const menus = leer(K.menusDia, []); // listas completas
    const platos = leer(K.dia, []);
    const ahora = new Date().toISOString();
    const r = { copiadas: 0, omitidas: [], vacias: 0 };
    let tocaMenus = false;
    let tocaPlatos = false;

    function platosDe(fecha, sid) {
      return platos.filter(
        (p) =>
          (p.empresaId || EMPRESA_DEFECTO) === eid &&
          p.fecha === fecha &&
          Number(p.sucursalId) === Number(sid)
      );
    }

    sucursales.forEach(function (suc) {
      const docOrigen = menus.find((x) => esMenuDe(x, eid, fechaOrigen, suc.id));
      const platosOrigen = platosDe(fechaOrigen, suc.id);
      if (!docOrigen && !platosOrigen.length) {
        r.vacias++;
        return;
      }

      const yaTiene =
        menus.some((x) => esMenuDe(x, eid, fechaDestino, suc.id)) ||
        platosDe(fechaDestino, suc.id).length > 0;
      if (yaTiene) {
        r.omitidas.push(suc.nombre);
        return;
      }

      if (docOrigen) {
        const armado = normalizarArmado(clonar(docOrigen.armado || {}));
        armado.vendidos = 0;
        menus.push(
          conEmpresa(
            {
              id: id(),
              sucursalId: Number(suc.id),
              fecha: fechaDestino,
              tipo: TIPOS_MENU.indexOf(docOrigen.tipo) >= 0 ? docOrigen.tipo : 'chef',
              armado: armado,
              publico: normalizarTextoMenu(docOrigen.publico), // el mensaje del día también se copia
              copiadoDe: fechaOrigen,
              creado: ahora,
              actualizado: ahora,
            },
            eid
          )
        );
        tocaMenus = true;
      }

      platosOrigen.forEach(function (p) {
        // Un plato que se agotó por cupos vuelve a estar disponible al día siguiente
        const agotadoPorCupos =
          typeof p.cupos === 'number' && p.cupos > 0 && (p.vendidos || 0) >= p.cupos;
        platos.push(
          conEmpresa(
            Object.assign({}, p, {
              id: id(),
              fecha: fechaDestino,
              vendidos: 0,
              disponible: agotadoPorCupos ? true : p.disponible,
              creado: ahora,
            }),
            eid
          )
        );
        tocaPlatos = true;
      });

      r.copiadas++;
    });

    if (tocaMenus) escribir(K.menusDia, menus);
    if (tocaPlatos) escribir(K.dia, platos);
    return r;
  }


  /* ===============================================================
     PEDIDOS
     =============================================================== */
  /* Todos los estados posibles, en orden. 'camino' sólo aplica a
     domicilios; los pedidos de mesa saltan de 'listo' a 'entregado'.
     Los pedidos creados antes de que existiera 'camino' siguen siendo
     válidos: nada se rompe. */
  const ESTADOS = ['nuevo', 'preparacion', 'listo', 'camino', 'entregado'];

  const ETIQUETA_ESTADO = {
    nuevo: 'Nuevo',
    preparacion: 'En preparación',
    listo: 'Listo',
    camino: 'En camino',
    entregado: 'Entregado',
    cancelado: 'Cancelado',
    anulado: 'Anulada',
  };

  /* Flujo que le corresponde a un pedido según su tipo. */
  function flujoEstados(tipo) {
    return tipo === 'domicilio'
      ? ['nuevo', 'preparacion', 'listo', 'camino', 'entregado']
      : ['nuevo', 'preparacion', 'listo', 'entregado'];
  }

  function siguienteEstado(pedido) {
    const flujo = flujoEstados(pedido.tipo);
    const i = flujo.indexOf(pedido.estado);
    if (i < 0 || i === flujo.length - 1) return null;
    return flujo[i + 1];
  }

  function getPedidos(filtro) {
    filtro = filtro || {};
    let lista = soloDeEmpresa(leer(K.pedidos, []), empresaDe(filtro));
    if (filtro.sucursalId)
      lista = lista.filter((p) => Number(p.sucursalId) === Number(filtro.sucursalId));
    if (filtro.tipo) lista = lista.filter((p) => p.tipo === filtro.tipo);
    if (filtro.estado) lista = lista.filter((p) => p.estado === filtro.estado);
    if (filtro.fecha) lista = lista.filter((p) => p.fecha === filtro.fecha);
    if (filtro.desde) lista = lista.filter((p) => p.fecha >= filtro.desde);
    if (filtro.hasta) lista = lista.filter((p) => p.fecha <= filtro.hasta);
    if (filtro.activos)
      lista = lista.filter(
        (p) => p.estado !== 'entregado' && p.estado !== 'cancelado' && p.estado !== 'anulado'
      );
    return lista.sort((a, b) => (a.creado < b.creado ? 1 : -1));
  }

  function getPedido(pedidoId) {
    return leer(K.pedidos, []).find((p) => p.id === pedidoId) || null;
  }

  /* Acepta el código como lo escriba el cliente: "27", "#27" o "00027". */
  function getPedidoPorCodigo(codigo) {
    let c = String(codigo || '').trim().toUpperCase().replace(/^#/, '');
    if (/^\d{1,5}$/.test(c)) c = c.padStart(DIGITOS_CODIGO, '0');
    return leer(K.pedidos, []).find((p) => p.codigo === c) || null;
  }

  /* ===============================================================
     BORRAR FACTURAS DE PRUEBA

     Excepción a la regla de no tocar pedidos: sirve para dejar limpio el
     sistema después de las pruebas, antes de operar de verdad. Nunca corre
     sola: la dispara el Admin desde Ajustes, ve cuántas son y confirma
     escribiendo BORRAR.

       alcance 'anteriores' → las del formato viejo (N1-260828-001)
       alcance 'todas'      → todas, y la numeración vuelve a 00001

     Se lleva también lo que sólo existe por esas facturas: las entradas
     de "retorno por anulación" que generaron. Cierres, gastos, bases,
     stock y menús no se tocan. Sólo la empresa activa.
     =============================================================== */
  const CODIGO_CORTO = /^\d{5}(-|$)/;

  function facturasDePrueba(alcance, eid) {
    return leer(K.pedidos, []).filter(function (p) {
      if ((p.empresaId || EMPRESA_DEFECTO) !== eid) return false;
      return alcance === 'todas' || !CODIGO_CORTO.test(String(p.codigo || ''));
    });
  }

  function entradasDeFacturas(pedidos, eid) {
    const ids = {};
    const codigos = pedidos.map((p) => p.codigo);
    pedidos.forEach(function (p) {
      ((p.anulacion && p.anulacion.entradas) || []).forEach((id) => (ids[id] = true));
    });
    return leer(K.entradas, []).filter(function (e) {
      if ((e.empresaId || EMPRESA_DEFECTO) !== eid) return false;
      if (ids[e.id]) return true;
      return (
        e.tipoEntrada === 'retorno_anulacion' &&
        codigos.some((c) => String(e.observacion || '').indexOf('factura ' + c + ' ') >= 0)
      );
    });
  }

  function contarFacturasPrueba(alcance) {
    const eid = empresaActivaId();
    const pedidos = facturasDePrueba(alcance, eid);
    return { pedidos: pedidos.length, entradas: entradasDeFacturas(pedidos, eid).length };
  }

  function borrarFacturasPrueba(alcance, confirmacion) {
    const sesion = getSesion();
    if (sesion && NASCAR.Auth && !NASCAR.Auth.puede('pedidos_anular', sesion))
      throw new Error('Sólo el perfil Admin puede borrar facturas.');
    if (String(confirmacion || '').trim().toUpperCase() !== 'BORRAR')
      throw new Error('Escribe BORRAR para confirmar.');
    if (alcance !== 'todas' && alcance !== 'anteriores') throw new Error('Alcance no válido.');

    const eid = empresaActivaId();
    const pedidos = facturasDePrueba(alcance, eid);
    const fuera = {};
    pedidos.forEach((p) => (fuera[p.id] = true));
    const entradasFuera = {};
    entradasDeFacturas(pedidos, eid).forEach((e) => (entradasFuera[e.id] = true));

    // Listas COMPLETAS: se quita sólo lo de esta empresa
    escribir(K.pedidos, leer(K.pedidos, []).filter((p) => !fuera[p.id]));
    escribir(K.entradas, leer(K.entradas, []).filter((e) => !entradasFuera[e.id]));

    // Consecutivos: los del formato viejo sobran; con 'todas', se vuelve a 00001
    const seq = leer(K.seq, {}) || {};
    Object.keys(seq).forEach(function (k) {
      if (k.indexOf(eid + '|') !== 0) return;
      if (k === eid + '|facturas' && alcance !== 'todas') return;
      delete seq[k];
    });
    escribir(K.seq, seq);

    hidratar();
    return { pedidos: pedidos.length, entradas: Object.keys(entradasFuera).length };
  }

  /**
   * Crea un pedido.
   * datos = {
   *   tipo: 'mesa' | 'domicilio',
   *   sucursalId, mesa,
   *   cliente: { nombre, telefono, direccion, zona, notas },
   *   items: [{ refId, nombre, precio, cantidad, notas, origen }],
   *   metodoPago, costoDomicilio
   * }
   */
  function crearPedido(datos) {
    if (!datos.items || !datos.items.length)
      throw new Error('El pedido no tiene productos.');

    const items = datos.items.map(function (it) {
      const item = {
        refId: it.refId,
        nombre: it.nombre,
        precio: Number(it.precio),
        cantidad: Number(it.cantidad) || 1,
        notas: it.notas || '',
        origen: it.origen || 'carta', // 'carta' | 'dia' | 'armado'
      };
      // Menú armado: lo que eligió el cliente ("Sopa: Sancocho · Proteína: Pollo").
      // Va aparte de las notas para que una nota nunca lo borre.
      if (it.detalle) item.detalle = String(it.detalle).slice(0, 400);
      return item;
    });

    const subtotal = items.reduce((s, it) => s + it.precio * it.cantidad, 0);
    const domicilio = datos.tipo === 'domicilio' ? Number(datos.costoDomicilio) || 0 : 0;
    const ahora = new Date().toISOString();

    const eid = datos.empresaId || empresaActivaId();

    /* Cada pedido es de UNA unidad, y esa unidad tiene que estar activa.
       Lo que viene de la carta tiene que ser de ESA unidad: una venta de
       NASCAR-Comidas nunca puede llevar un producto de otra. */
    exigirUnidadOperativa(datos.sucursalId, eid);
    const cartaEmpresa = soloDeEmpresa(cartaGuardada(), eid);
    items.forEach(function (it) {
      if (it.origen !== 'carta') return;
      const prod = cartaEmpresa.find((p) => p.id === it.refId);
      if (prod && !esDeUnidad(prod, datos.sucursalId))
        throw new Error('"' + it.nombre + '" no se vende en esta unidad.');
    });

    const pedido = {
      id: id(),
      empresaId: eid,
      codigo: siguienteCodigo(datos.sucursalId, eid),
      tipo: datos.tipo,
      sucursalId: Number(datos.sucursalId),
      // Copia del nombre en el momento del pedido: si la sucursal se
      // renombra después, el histórico sigue diciendo la verdad.
      sucursalNombre: (getSucursal(datos.sucursalId, eid) || {}).nombre || '',
      mesa: datos.tipo === 'mesa' ? datos.mesa : null,
      // Quién lo tomó (mesero) — null si lo hizo el cliente.
      usuarioId: datos.usuarioId || null,
      usuarioNombre: datos.usuarioNombre || null,
      cliente: datos.cliente || {},
      items: items,
      subtotal: subtotal,
      domicilio: domicilio,
      total: subtotal + domicilio,
      metodoPago: datos.metodoPago || 'efectivo',
      // Todo pago arranca pendiente y sólo caja lo confirma (Ventas y caja → Pagos)
      estadoPago: 'pendiente',
      comprobante: '',
      estado: 'nuevo',
      fecha: hoy(),
      // Jornada a la que pertenece el pedido para inventario y cierres.
      // Se guarda al crearlo para que no dependa de la configuración futura.
      fechaOperativa: fechaOperativaDe(ahora),
      creado: ahora,
      actualizado: ahora,
      historial: [{ ts: ahora, texto: 'Pedido recibido' }],
    };

    const lista = leer(K.pedidos, []);
    lista.push(pedido);
    escribir(K.pedidos, lista);

    // Descontar cupos si se pidió un plato del día
    items
      .filter((it) => it.origen === 'dia')
      .forEach(function (it) {
        const todos = leer(K.dia, []); // lista completa
        const p = todos.find(
          (x) => x.id === it.refId && (x.empresaId || EMPRESA_DEFECTO) === eid
        );
        if (p) {
          p.vendidos = (p.vendidos || 0) + it.cantidad;
          // cupos 0 o vacío = sin límite (antes 0 lo agotaba con la primera venta)
          if (typeof p.cupos === 'number' && p.cupos > 0 && p.vendidos >= p.cupos) p.disponible = false;
          escribir(K.dia, todos);
        }
      });

    // Menú armado: sólo se cuenta cuántos se vendieron (informativo, sin inventario)
    const armados = items.filter((it) => it.origen === 'armado');
    if (armados.length) {
      const menus = leer(K.menusDia, []); // lista completa
      let toca = false;
      armados.forEach(function (it) {
        const menuId = String(it.refId || '').split(':')[1];
        const m = menus.find((x) => x.id === menuId && (x.empresaId || EMPRESA_DEFECTO) === eid);
        if (!m) return;
        m.armado = m.armado || {};
        m.armado.vendidos = (Number(m.armado.vendidos) || 0) + it.cantidad;
        toca = true;
      });
      if (toca) escribir(K.menusDia, menus);
    }

    return pedido;
  }

  function _mutar(pedidoId, fn) {
    const lista = leer(K.pedidos, []);
    const i = lista.findIndex((p) => p.id === pedidoId);
    if (i < 0) return null;
    fn(lista[i]);
    lista[i].actualizado = new Date().toISOString();
    escribir(K.pedidos, lista);
    return lista[i];
  }

  function cambiarEstado(pedidoId, estado) {
    return _mutar(pedidoId, function (p) {
      p.estado = estado;
      p.historial.push({
        ts: new Date().toISOString(),
        texto: 'Estado: ' + (ETIQUETA_ESTADO[estado] || estado),
      });
      /* Entregar NO cobra, ni siquiera en efectivo: el pedido queda entregado
         para el cliente y pendiente de pago para caja, hasta que la cajera
         reciba el dinero y lo confirme. */
    });
  }

  function avanzarEstado(pedidoId) {
    const p = getPedido(pedidoId);
    if (!p) return null;
    const siguiente = siguienteEstado(p);
    return siguiente ? cambiarEstado(pedidoId, siguiente) : p;
  }

  function cancelarPedido(pedidoId, motivo) {
    return _mutar(pedidoId, function (p) {
      p.estado = 'cancelado';
      p.motivoCancelacion = motivo || '';
      p.historial.push({
        ts: new Date().toISOString(),
        texto: 'Cancelado' + (motivo ? ': ' + motivo : ''),
      });
    });
  }

  /* ===============================================================
     ANULACIÓN DE FACTURA

     Anular NO es cancelar:

       · Cancelar  -> el pedido no llegó a cumplirse. Lo hace quien
                      gestiona pedidos, sobre un pedido en curso.
       · Anular    -> la venta se hizo y después se echa atrás. Sólo el
                      Admin, con motivo obligatorio, y devolviendo al
                      inventario lo que esa venta había consumido.

     Nada se borra: la factura queda con estado 'anulado', su bloque de
     auditoría y su historial. Deja de contar como venta efectiva, pero
     sigue estando.
     =============================================================== */

  /* Qué productos de inventario consumió un pedido, usando la MISMA
     relación que el cruce del cierre: `ventaRefIds`. No hay recetas ni
     un segundo mapeo — si un plato no está asociado a un producto de
     inventario, no consume nada y aquí tampoco devuelve nada. */
  function consumoDePedido(pedido) {
    const porRef = {};
    (NASCAR.INVENTARIO || []).forEach(function (prod) {
      (prod.ventaRefIds || []).forEach(function (ref) {
        porRef[ref] = prod.codigo;
      });
    });

    const mapa = {};
    (pedido.items || []).forEach(function (it) {
      if (it.origen === 'dia') return; // el menú del día no lleva saldo
      const cod = porRef[it.refId];
      if (!cod) return;
      mapa[cod] = (mapa[cod] || 0) + Number(it.cantidad || 0);
    });

    return Object.keys(mapa).map(function (codigo) {
      const prod = getProductoInventario(codigo);
      return {
        codigo: codigo,
        nombre: prod ? prod.nombre : codigo,
        area: prod ? prod.area : null,
        cantidad: mapa[codigo],
      };
    });
  }

  /* ¿La jornada de este pedido ya tiene un cierre hecho para esa área?
     Un borrador no cuenta: todavía se está trabajando. */
  function cierreBloqueante(sucursalId, jornada, area, empresaId) {
    const c = buscarCierre(sucursalId, jornada, area, empresaId);
    if (!c) return null;
    return c.estado === 'completado' || c.estado === 'revisado' ? c : null;
  }

  function sumarDiasISO(iso, n) {
    const d = desdeISO(iso);
    d.setDate(d.getDate() + n);
    return aISO(d);
  }

  /**
   * A qué jornada se imputa un retorno diferido.
   *
   * No puede ser la jornada original, que ya está cerrada: meter ahí la
   * devolución cambiaría el cruce de un día que alguien ya firmó. Y
   * tampoco vale "hoy" sin mirar, porque anular una venta el mismo día
   * en que se cerró el inventario cae otra vez en la jornada cerrada
   * — que es justo lo que hay que evitar.
   *
   * Así que se busca la primera jornada, desde hoy o desde el día
   * siguiente al cierre (lo que sea más tarde), que no tenga cierre
   * hecho en ninguna de las áreas afectadas. Ahí es donde la mercancía
   * vuelve a aparecer, y el cierre de esa jornada la contará como debe.
   */
  function jornadaParaRetorno(sucursalId, jornadaOriginal, areas, empresaId) {
    const hoyOp = hoyOperativo();
    const minima = sumarDiasISO(jornadaOriginal, 1);
    let candidata = hoyOp > minima ? hoyOp : minima;

    // Tope de seguridad: nunca se busca más de un año hacia adelante.
    for (let i = 0; i < 400; i++) {
      const chocada = areas.some((a) => cierreBloqueante(sucursalId, candidata, a, empresaId));
      if (!chocada) return candidata;
      candidata = sumarDiasISO(candidata, 1);
    }
    return candidata;
  }

  /**
   * anularPedido(pedidoId, motivo)
   *
   * Devuelve { pedido, retorno }. Lanza error si no se puede.
   *
   * EL RETORNO DE INVENTARIO va a una jornada u otra según si el cierre
   * de la jornada original ya se hizo, y se decide POR ÁREA:
   *
   *   · Sin cierre de esa área  -> el retorno se imputa a la jornada
   *     original. El pedido deja de contar en la columna Z del cruce y
   *     el saldo calculado sube solo. No hace falta ningún movimiento:
   *     para el inventario, esa venta nunca ocurrió.
   *
   *   · Con cierre completado o revisado -> el histórico NO se toca. El
   *     pedido sigue contando en la Z de aquel día —el cruce de esa
   *     fecha queda exactamente como estaba— y la mercancía vuelve como
   *     una ENTRADA de hoy, de tipo 'retorno_anulacion'.
   *
   * Nunca las dos cosas a la vez: sería devolver el inventario dos
   * veces.
   */
  function anularPedido(pedidoId, motivo, quien) {
    const pedido = getPedido(pedidoId);
    if (!pedido) throw new Error('Esa factura no existe.');

    // Una sola vez. Ni el retorno ni la auditoría se repiten.
    if (pedido.estado === 'anulado')
      throw new Error('Esa factura ya está anulada. No se puede anular dos veces.');
    if (pedido.estado === 'cancelado')
      throw new Error('Ese pedido está cancelado: nunca fue una venta efectiva, no hay nada que anular.');

    if (!motivo || String(motivo).trim().length < 3)
      throw new Error('Hay que escribir el motivo de la anulación.');

    /* Doble barrera. La pantalla ya exige el permiso antes de abrir el
       diálogo, pero anular una venta y devolver mercancía es demasiado
       gordo para dejarlo sólo en la pantalla: si hay sesión, el rol
       tiene que poder. Sin sesión se permite, que es como trabajan la
       consola y las semillas de datos. Mismo criterio que setModulos()
       y guardarEmpresa(). */
    const sesion = getSesion();
    if (sesion && NASCAR.Auth && !NASCAR.Auth.puede('pedidos_anular', sesion))
      throw new Error('Sólo el perfil Admin puede anular facturas.');

    const eid = pedido.empresaId || EMPRESA_DEFECTO;
    const jornadaOriginal = fechaOperativaPedido(pedido);
    const productos = consumoDePedido(pedido);

    /* Se decide área por área: puede estar cerrado el inventario de
       comidas y no el de bar, y cada mitad va a donde le toca. */
    const areasRetornadas = []; // el retorno cuenta en la jornada original
    const areasDiferidas = []; // el retorno se imputa a hoy
    const cierresBloqueantes = [];

    const areas = {};
    productos.forEach(function (x) {
      if (x.area) areas[x.area] = true;
    });

    Object.keys(areas).forEach(function (area) {
      const c = cierreBloqueante(pedido.sucursalId, jornadaOriginal, area, eid);
      if (c) {
        areasDiferidas.push(area);
        cierresBloqueantes.push({ id: c.id, area: area, estado: c.estado, fecha: c.fechaCierre });
      } else {
        areasRetornadas.push(area);
      }
    });

    /* Las entradas SÓLO para lo diferido. Para lo demás basta con que el
       pedido salga de la Z de su jornada. */
    const ahora = new Date();
    const firma = quien || (NASCAR.Auth && NASCAR.Auth.firma()) || {};
    const entradas = [];

    const jornadaRetorno = areasDiferidas.length
      ? jornadaParaRetorno(pedido.sucursalId, jornadaOriginal, areasDiferidas, eid)
      : jornadaOriginal;

    productos.forEach(function (x) {
      if (areasDiferidas.indexOf(x.area) < 0) return;
      const e = guardarEntrada({
        empresaId: eid,
        fecha: jornadaRetorno,
        sucursalId: pedido.sucursalId,
        codigo: x.codigo,
        cantidad: x.cantidad,
        tipoEntrada: 'retorno_anulacion',
        observacion:
          'Retorno por anulación de la factura ' + pedido.codigo +
          ' (jornada ' + jornadaOriginal + '). Motivo: ' + String(motivo).trim(),
        usuarioId: firma.usuarioId || null,
        usuarioNombre: firma.usuarioNombre || 'Administración',
        rolUsuario: firma.rol || null,
      });
      entradas.push(e.id);
    });

    const suc = getSucursal(pedido.sucursalId, eid);

    const auditoria = {
      motivo: String(motivo).trim(),

      // Quién, cuándo y dónde
      usuarioId: firma.usuarioId || null,
      usuarioNombre: firma.usuarioNombre || 'Administración',
      rol: firma.rol || null,
      ts: ahora.toISOString(),
      fecha: aISO(ahora),
      hora: ahora.toTimeString().slice(0, 5),
      empresaId: eid,
      sucursalId: Number(pedido.sucursalId),
      // Copia del nombre: si la sucursal se renombra, el histórico no miente
      sucursalNombre: suc ? suc.nombre : pedido.sucursalNombre || '',

      // Copia de lo que se anuló, para que el registro se explique solo
      total: pedido.total,
      metodoPago: pedido.metodoPago,
      estadoPagoAlAnular: pedido.estadoPago,

      // Retorno de inventario
      jornadaOriginal: jornadaOriginal,
      jornadaRetorno: jornadaRetorno,
      productos: productos,
      areasRetornadas: areasRetornadas,
      areasDiferidas: areasDiferidas,
      cierresBloqueantes: cierresBloqueantes,
      entradas: entradas,
      diferido: areasDiferidas.length > 0,
    };

    const actualizado = _mutar(pedidoId, function (p) {
      p.estado = 'anulado';
      p.anulacion = auditoria;
      p.historial.push({
        ts: auditoria.ts,
        texto:
          'Factura ANULADA por ' + auditoria.usuarioNombre + ': ' + auditoria.motivo +
          (productos.length
            ? ' · Retorno de inventario: ' +
              productos.map((x) => x.codigo + ' +' + x.cantidad).join(', ') +
              (auditoria.diferido
                ? ' (imputado a la jornada ' + jornadaRetorno + ' por haber cierre)'
                : '')
            : ' · Sin impacto en inventario'),
      });
    });

    return { pedido: actualizado, retorno: auditoria };
  }

  /* Las anulaciones de un rango, para consultarlas como historial. */
  function getAnulaciones(filtro) {
    filtro = filtro || {};
    return soloDeEmpresa(leer(K.pedidos, []), empresaDe(filtro))
      .filter(function (p) {
        if (p.estado !== 'anulado' || !p.anulacion) return false;
        if (filtro.sucursalId && Number(p.sucursalId) !== Number(filtro.sucursalId)) return false;
        if (filtro.jornada && fechaOperativaPedido(p) !== filtro.jornada) return false;
        if (filtro.desde && p.anulacion.fecha < filtro.desde) return false;
        if (filtro.hasta && p.anulacion.fecha > filtro.hasta) return false;
        return true;
      })
      .sort((a, b) => (a.anulacion.ts < b.anulacion.ts ? 1 : -1));
  }

  /* --- Pagos ---------------------------------------------------- */
  /* `quien` = { usuarioId, usuarioNombre, rol }. Queda registrado quién
     movió el dinero y cuándo: es lo que después permite auditar la caja. */
  /* Caja confirma el cobro y registra con qué pagó el cliente de verdad
     (`metodo`): un pedido de mesa se toma sin saberlo. Un pago confirmado
     ya no cambia; una factura cancelada o anulada no se cobra. */
  function exigirPagoPorRegistrar(p) {
    if (!p) throw new Error('Ese pedido no existe.');
    if (p.estado === 'cancelado' || p.estado === 'anulado')
      throw new Error('La factura ' + p.codigo + ' está ' + (p.estado === 'anulado' ? 'anulada' : 'cancelada') +
        ': no hay pago que registrar.');
    if (p.estadoPago === 'confirmado')
      throw new Error('El pago de la factura ' + p.codigo + ' ya fue confirmado.');
  }

  function confirmarPago(pedidoId, referencia, quien, metodo) {
    const nombre = quien && quien.usuarioNombre ? quien.usuarioNombre : null;
    const actual = getPedido(pedidoId);
    exigirPagoPorRegistrar(actual);
    if (metodo && metodo !== actual.metodoPago) {
      const m = (getConfig().metodosPago || []).find((x) => x.id === metodo);
      if (!m || !m.activo) throw new Error('El método de pago "' + metodo + '" no está disponible.');
    }
    return _mutar(pedidoId, function (p) {
      if (metodo && metodo !== p.metodoPago) {
        p.historial.push({ ts: new Date().toISOString(), texto: 'Método de pago: ' + p.metodoPago + ' → ' + metodo });
        p.metodoPago = metodo;
      }
      p.estadoPago = 'confirmado';
      p.referenciaPago = referencia || '';
      p.confirmadoEn = new Date().toISOString();
      p.confirmadoPorId = quien ? quien.usuarioId : null;
      p.confirmadoPor = nombre;
      p.historial.push({
        ts: new Date().toISOString(),
        texto:
          'Pago confirmado' +
          (referencia ? ' · ref. ' + referencia : '') +
          (nombre ? ' · por ' + nombre : ''),
      });
    });
  }

  function rechazarPago(pedidoId, motivo, quien) {
    const nombre = quien && quien.usuarioNombre ? quien.usuarioNombre : null;
    exigirPagoPorRegistrar(getPedido(pedidoId));
    return _mutar(pedidoId, function (p) {
      p.estadoPago = 'rechazado';
      p.rechazadoEn = new Date().toISOString();
      p.rechazadoPorId = quien ? quien.usuarioId : null;
      p.rechazadoPor = nombre;
      p.historial.push({
        ts: new Date().toISOString(),
        texto:
          'Pago rechazado' + (motivo ? ': ' + motivo : '') + (nombre ? ' · por ' + nombre : ''),
      });
    });
  }

  /* El cliente reporta que ya transfirió (adjunta referencia) */
  function reportarPago(pedidoId, referencia) {
    return _mutar(pedidoId, function (p) {
      p.comprobante = referencia || '';
      p.estadoPago = 'reportado';
      p.historial.push({
        ts: new Date().toISOString(),
        texto: 'Cliente reportó pago · ref. ' + (referencia || 's/n'),
      });
    });
  }

  /* ===============================================================
     VENTAS  (agregados para el panel de control)
     =============================================================== */
  function ventas(desde, hasta, sucursalId) {
    desde = desde || hoy();
    hasta = hasta || desde;

    /* Ni los cancelados ni los ANULADOS son venta efectiva. La factura
       anulada sigue guardada y se puede consultar, pero no suma. */
    const pedidos = getPedidos({ desde: desde, hasta: hasta, sucursalId: sucursalId }).filter(
      (p) => p.estado !== 'cancelado' && p.estado !== 'anulado'
    );

    const r = {
      desde: desde,
      hasta: hasta,
      pedidos: pedidos.length,
      total: 0,
      subtotal: 0,
      domicilios: 0,
      ticketPromedio: 0,
      porTipo: { mesa: { n: 0, total: 0 }, domicilio: { n: 0, total: 0 } },
      porPago: {},
      porSucursal: {},
      porDia: {},
      topPlatos: [],
      pendientesCobro: 0,
      montoPendiente: 0,
    };

    const conteoPlatos = {};

    pedidos.forEach(function (p) {
      r.total += p.total;
      r.subtotal += p.subtotal;
      r.domicilios += p.domicilio;

      r.porTipo[p.tipo].n += 1;
      r.porTipo[p.tipo].total += p.total;

      /* Por método sólo cuenta lo que caja ya cobró: mientras no se confirme,
         el método no se conoce de verdad (una mesa se toma sin saberlo). */
      const clavePago = p.estadoPago === 'confirmado' ? p.metodoPago : 'por_cobrar';
      r.porPago[clavePago] = r.porPago[clavePago] || { n: 0, total: 0 };
      r.porPago[clavePago].n += 1;
      r.porPago[clavePago].total += p.total;

      r.porSucursal[p.sucursalId] = r.porSucursal[p.sucursalId] || { n: 0, total: 0 };
      r.porSucursal[p.sucursalId].n += 1;
      r.porSucursal[p.sucursalId].total += p.total;

      r.porDia[p.fecha] = r.porDia[p.fecha] || { n: 0, total: 0 };
      r.porDia[p.fecha].n += 1;
      r.porDia[p.fecha].total += p.total;

      if (p.estadoPago !== 'confirmado') {
        r.pendientesCobro += 1;
        r.montoPendiente += p.total;
      }

      p.items.forEach(function (it) {
        const k = it.nombre;
        conteoPlatos[k] = conteoPlatos[k] || { nombre: k, cantidad: 0, total: 0 };
        conteoPlatos[k].cantidad += it.cantidad;
        conteoPlatos[k].total += it.precio * it.cantidad;
      });
    });

    r.ticketPromedio = pedidos.length ? Math.round(r.total / pedidos.length) : 0;
    r.topPlatos = Object.values(conteoPlatos)
      .sort((a, b) => b.cantidad - a.cantidad)
      .slice(0, 10);

    return r;
  }

  /* ===============================================================
     BASE DE CAJA

     Cuánto dinero físico había en el cajón al empezar la jornada. Es el
     único dato que este módulo CREA: todo lo demás lo lee de ventas,
     gastos y cierres, que ya existen.

     Va por sucursal y jornada (fecha operativa), no por área: el cajón
     es uno solo para comidas y bar, y ni las ventas ni los gastos se
     separan por área. El área sigue siendo cosa del Cierre, que cuenta
     inventario y no dinero.
     =============================================================== */
  function getBases(filtro) {
    filtro = filtro || {};
    let lista = soloDeEmpresa(leer(K.bases, []), empresaDe(filtro));
    if (filtro.sucursalId)
      lista = lista.filter((b) => Number(b.sucursalId) === Number(filtro.sucursalId));
    if (filtro.fecha) lista = lista.filter((b) => b.fecha === filtro.fecha);
    if (filtro.desde) lista = lista.filter((b) => b.fecha >= filtro.desde);
    if (filtro.hasta) lista = lista.filter((b) => b.fecha <= filtro.hasta);
    if (filtro.estado) lista = lista.filter((b) => b.estado === filtro.estado);
    return lista.sort((a, b) => (a.registrada < b.registrada ? 1 : -1));
  }

  /* La base vigente de esa jornada, o null. Las corregidas no cuentan:
     siguen guardadas, pero ya no son la buena. */
  function getBaseCaja(sucursalId, fecha, empresaId) {
    const lista = getBases({
      sucursalId: sucursalId,
      fecha: fecha,
      estado: 'activa',
      empresaId: empresaId,
    });
    return lista[0] || null;
  }

  /* Todo lo registrado para esa jornada, incluidas las correcciones.
     Sirve para mostrar el rastro de quién cambió qué. */
  function getHistorialBase(sucursalId, fecha, empresaId) {
    return getBases({ sucursalId: sucursalId, fecha: fecha, empresaId: empresaId });
  }

  function validarBase(datos) {
    if (!datos) throw new Error('Faltan los datos de la base.');
    if (!datos.fecha || !/^\d{4}-\d{2}-\d{2}$/.test(datos.fecha))
      throw new Error('La base necesita una fecha de jornada válida.');
    if (!datos.sucursalId || !getSucursal(datos.sucursalId))
      throw new Error('La base necesita una sucursal válida.');
    exigirUnidadOperativa(datos.sucursalId, datos.empresaId);

    const valor = Number(datos.valor);
    if (!isFinite(valor) || valor < 0)
      throw new Error('El valor de la base debe ser un número mayor o igual que cero.');
  }

  /**
   * Registra la base de la jornada.
   *
   * Si ya hay una, NO se pisa: hay que pedir la corrección a propósito
   * (`{ corregir: true, motivo }`). La anterior queda con estado
   * 'corregida' y sus valores intactos, apuntada desde la nueva. Nunca se
   * modifica un registro histórico, igual que en pedidos, gastos y
   * cierres.
   */
  function registrarBase(datos, opciones) {
    validarBase(datos);
    opciones = opciones || {};

    const eid = datos.empresaId || empresaActivaId();
    const previa = getBaseCaja(datos.sucursalId, datos.fecha, eid);

    if (previa && !opciones.corregir)
      throw new Error(
        'Ya hay una base registrada para esa jornada. Para cambiarla hay que corregirla.'
      );
    if (previa && opciones.corregir) {
      if (!opciones.motivo || String(opciones.motivo).trim().length < 3)
        throw new Error('Para corregir la base hay que escribir el motivo.');
    }

    const ahora = new Date();
    const suc = getSucursal(datos.sucursalId, eid);
    const quien = (NASCAR.Auth && NASCAR.Auth.firma()) || {};

    const base = {
      id: 'b' + id(),
      empresaId: eid,

      sucursalId: Number(datos.sucursalId),
      // Copia del nombre: si la sucursal se renombra, el histórico no miente
      sucursalNombre: suc ? suc.nombre : '',

      fecha: datos.fecha, // jornada (fecha operativa)
      hora: datos.hora || ahora.toTimeString().slice(0, 5),

      valor: Number(datos.valor),
      observaciones: String(datos.observaciones || '').trim(),

      // Quién la registró
      usuarioId: quien.usuarioId || null,
      usuarioNombre: quien.usuarioNombre || 'Sistema',
      rol: quien.rol || null,

      estado: 'activa',
      registrada: ahora.toISOString(),

      /* Rastro de la corrección: a qué base sustituye y por qué. */
      corrigeA: previa ? previa.id : null,
      motivoCorreccion: previa ? String(opciones.motivo).trim() : '',

      /* Arqueo — todavía NO se llena desde ninguna pantalla.
         El hueco queda hecho para cuando exista el conteo físico del
         cajón: entonces el informe podrá comparar esperado contra
         contado sin tocar nada más. */
      efectivoContado: null,
      arqueadaPor: null,
      arqueada: null,
    };

    const todas = leer(K.bases, []);
    if (previa) {
      const i = todas.findIndex((b) => b.id === previa.id);
      if (i >= 0) todas[i] = Object.assign({}, todas[i], { estado: 'corregida' });
    }
    todas.push(base);
    escribir(K.bases, todas);
    return base;
  }

  /* ===============================================================
     CRUCE DE INFORMACIÓN · informe de caja de la jornada

     CAPA DE CONSULTA. No escribe nada, no crea registros y no toca
     ventas, gastos ni cierres: los lee y los consolida.

     Ojo con no confundirlo con el cruce del CIERRE, que es otra cosa:
       · Cierre  -> qué pasó con el INVENTARIO físico (IN + EN − Z = SLDC)
       · Caja    -> qué pasó con el DINERO de la jornada
     =============================================================== */

  /* A qué columna va cada método de pago. Lo que no esté declarado en
     NASCAR.GRUPO_DE_METODO cae en 'otros', que es lo prudente: un método
     nuevo nunca se suma al efectivo por accidente. */
  function grupoDeMetodo(metodoId) {
    return (NASCAR.GRUPO_DE_METODO || {})[metodoId] || 'otros';
  }

  function bolsaVacia() {
    return { efectivo: 0, transferencia: 0, otros: 0, total: 0 };
  }

  function sumarABolsa(bolsa, metodoId, valor) {
    bolsa[grupoDeMetodo(metodoId)] += valor;
    bolsa.total += valor;
  }

  /**
   * informeCaja(fecha, sucursalId)
   *
   * `fecha` es la JORNADA (fecha operativa): un pedido de las 2 a.m.
   * cuenta en el día anterior, igual que en los cierres.
   */
  function informeCaja(fecha, sucursalId, empresaId) {
    const jornada = fecha || hoyOperativo();
    const eid = empresaId || empresaActivaId();
    const suc = sucursalId ? Number(sucursalId) : null;

    /* ---- VENTAS ------------------------------------------------------
       Se recorren los pedidos de la jornada por su fecha OPERATIVA, no
       por la del calendario.

       Se distinguen dos cosas que no son lo mismo:
         · vendido  = lo que se facturó (todo lo no cancelado)
         · cobrado  = el dinero que YA entró (pago confirmado)
       El arqueo del cajón se hace con lo cobrado; si se usara lo vendido,
       un domicilio por confirmar cuadraría plata que nadie ha recibido. */
    const vendido = bolsaVacia();
    const cobrado = bolsaVacia();
    const porCobrar = bolsaVacia();
    const anuladas = bolsaVacia();
    const porMetodo = {};
    let nPedidos = 0;
    let nPorCobrar = 0;
    let nAnuladas = 0;
    let rechazado = 0;

    soloDeEmpresa(leer(K.pedidos, []), eid).forEach(function (p) {
      if (p.estado === 'cancelado') return;
      if (suc && Number(p.sucursalId) !== suc) return;
      if (fechaOperativaPedido(p) !== jornada) return;

      /* Una factura ANULADA no es venta efectiva: no suma a lo vendido
         ni a lo cobrado, y por tanto no mueve el efectivo esperado ni el
         RC. Se cuenta aparte para poder mostrarla — sigue en el
         historial, sólo que ya no cuadra caja. */
      if (p.estado === 'anulado') {
        nAnuladas += 1;
        sumarABolsa(anuladas, p.metodoPago || 'efectivo', p.total);
        return;
      }

      nPedidos += 1;
      const m = p.metodoPago || 'efectivo';
      porMetodo[m] = porMetodo[m] || { n: 0, vendido: 0, cobrado: 0, pendiente: 0 };
      porMetodo[m].n += 1;
      porMetodo[m].vendido += p.total;

      sumarABolsa(vendido, m, p.total);

      if (p.estadoPago === 'confirmado') {
        sumarABolsa(cobrado, m, p.total);
        porMetodo[m].cobrado += p.total;
      } else if (p.estadoPago === 'rechazado') {
        // Pago rechazado: ni entró ni se espera que entre
        rechazado += p.total;
      } else {
        sumarABolsa(porCobrar, m, p.total);
        porMetodo[m].pendiente += p.total;
        nPorCobrar += 1;
      }
    });

    /* ---- GASTOS ------------------------------------------------------
       Los del módulo de Gastos, tal cual están. Los anulados no cuentan:
       ese dinero no salió. */
    const gastado = bolsaVacia();
    const porMetodoGasto = {};
    let nGastos = 0;
    let gastosPendientes = 0;
    let montoPendienteGastos = 0;

    getGastos(
      Object.assign(
        { fecha: jornada, incluirAnulados: false, empresaId: eid },
        suc ? { sucursalId: suc } : {}
      )
    ).forEach(function (g) {
      nGastos += 1;
      const m = g.metodoPago || 'efectivo';
      porMetodoGasto[m] = porMetodoGasto[m] || { n: 0, total: 0 };
      porMetodoGasto[m].n += 1;
      porMetodoGasto[m].total += g.valor;
      sumarABolsa(gastado, m, g.valor);

      if (g.estado === 'registrado') {
        gastosPendientes += 1;
        montoPendienteGastos += g.valor;
      }
    });

    /* ---- BASE --------------------------------------------------------
       Sin sucursal concreta no hay una base sola que valga: se suman las
       de todas las sedes de la jornada, que es lo que corresponde a un
       informe consolidado. */
    let registroBase = null;
    let valorBase = 0;
    if (suc) {
      registroBase = getBaseCaja(suc, jornada, eid);
      valorBase = registroBase ? registroBase.valor : 0;
    } else {
      getBases({ fecha: jornada, estado: 'activa', empresaId: eid }).forEach(
        (b) => (valorBase += b.valor)
      );
    }

    /* ---- FÓRMULAS ----------------------------------------------------
       Efectivo esperado = Base + Ventas en efectivo − Gastos en efectivo

       Sólo entra lo que mueve dinero FÍSICO. Una transferencia sube el
       dinero recibido, pero no el que hay en el cajón, así que se
       informa aparte y nunca se suma aquí.

       RC (reposición de caja) usa exactamente la misma fórmula: es lo que
       debería quedar en el cajón al terminar la jornada, antes de
       cualquier retiro. Se devuelve con su propio nombre porque es lo que
       la administradora busca, pero no es un número distinto. */
    const efectivoEsperado = valorBase + cobrado.efectivo - gastado.efectivo;
    const rc = efectivoEsperado;
    const transferenciasNetas = cobrado.transferencia - gastado.transferencia;
    const otrosNetos = cobrado.otros - gastado.otros;

    /* ---- ARQUEO (estructura preparada, sin proceso todavía) ---------- */
    const contado =
      registroBase && typeof registroBase.efectivoContado === 'number'
        ? registroBase.efectivoContado
        : null;

    /* ---- CIERRES DE LA JORNADA --------------------------------------
       Sólo para ofrecer el acceso rápido. El cruce NO calcula inventario
       ni sustituye al Cierre: son preguntas distintas. */
    const cierres = hasModule('cierre', eid)
      ? getCierres(Object.assign({ empresaId: eid }, suc ? { sucursalId: suc } : {})).filter(
          (c) => c.fechaCierre === jornada
        )
      : [];

    const empresa = getEmpresa(eid);
    const sucursal = suc ? getSucursal(suc, eid) : null;

    return {
      jornada: jornada,
      empresaId: eid,
      empresaNombre: empresa ? empresa.nombre : '',
      sucursalId: suc,
      sucursalNombre: sucursal ? sucursal.nombre : 'Todas las sucursales',

      base: { registro: registroBase, valor: valorBase, unica: !!suc },

      ventas: {
        n: nPedidos,
        vendido: vendido,
        cobrado: cobrado,
        porCobrar: porCobrar,
        nPorCobrar: nPorCobrar,
        rechazado: rechazado,
        porMetodo: porMetodo,
        // Facturas anuladas de la jornada: se informan, no se suman
        anuladas: anuladas,
        nAnuladas: nAnuladas,
      },

      gastos: {
        n: nGastos,
        bolsa: gastado,
        porMetodo: porMetodoGasto,
        pendientes: gastosPendientes,
        montoPendiente: montoPendienteGastos,
      },

      efectivoEsperado: efectivoEsperado,
      rc: rc,
      transferenciasNetas: transferenciasNetas,
      otrosNetos: otrosNetos,

      arqueo: {
        hay: contado !== null,
        contado: contado,
        diferencia: contado === null ? null : contado - efectivoEsperado,
      },

      cierres: cierres,
    };
  }

  /* ===============================================================
     INVENTARIO · CATÁLOGO
     =============================================================== */
  /* El catálogo del cierre ES el módulo Stock: una sola fuente de verdad.
     Se conservan los nombres que ya usaba inventario.js. */
  function getProductosInventario(filtro) {
    filtro = filtro || {};
    return getStock({
      todos: filtro.soloActivos === false,
      area: filtro.area,
      texto: filtro.texto,
      sucursalId: filtro.sucursalId, // el cierre de una unidad cuenta SU catálogo
    });
  }

  /* Busca en TODO el catálogo, incluidos los desactivados: un cierre
     histórico puede referirse a un producto que ya no está activo. */
  function getProductoInventario(codigo) {
    return getStock({ todos: true }).find((p) => p.codigo === codigo) || null;
  }

  /* ===============================================================
     INVENTARIO · CIERRES

     Llave única: sucursal + fechaCierre + área.
     El id es determinista para que sea imposible crear dos cierres
     iguales por accidente, incluso desde dos dispositivos.
     =============================================================== */
  /* Dos empresas pueden tener una sede llamada "Norte", así que el id
     lleva la etiqueta de la empresa para no colisionar. NASCAR mantiene
     el formato de siempre y sus cierres anteriores siguen válidos. */
  function idCierre(sucursalId, fechaCierre, area, empresaId) {
    const eid = empresaId || empresaActivaId();
    const suc = (getSucursal(sucursalId, eid) || {}).corto || sucursalId;
    return (
      'CIERRE-' +
      String(fechaCierre).replace(/-/g, '') +
      '-' +
      String(suc).toUpperCase().replace(/\s+/g, '') +
      '-' +
      String(area).toUpperCase() +
      tagEmpresa(eid)
    );
  }

  function getCierres(filtro) {
    filtro = filtro || {};
    let lista = soloDeEmpresa(leer(K.cierres, []), empresaDe(filtro));
    if (filtro.sucursalId)
      lista = lista.filter((c) => Number(c.sucursalId) === Number(filtro.sucursalId));
    if (filtro.area) lista = lista.filter((c) => c.area === filtro.area);
    if (filtro.estado) lista = lista.filter((c) => c.estado === filtro.estado);
    if (filtro.fechaCierre) lista = lista.filter((c) => c.fechaCierre === filtro.fechaCierre);
    if (filtro.desde) lista = lista.filter((c) => c.fechaCierre >= filtro.desde);
    if (filtro.hasta) lista = lista.filter((c) => c.fechaCierre <= filtro.hasta);
    // Más recientes primero; a igual fecha, primero comidas y luego bar.
    return lista.sort(function (a, b) {
      if (a.fechaCierre !== b.fechaCierre) return a.fechaCierre < b.fechaCierre ? 1 : -1;
      if (a.sucursalId !== b.sucursalId) return a.sucursalId - b.sucursalId;
      return a.area < b.area ? -1 : 1;
    });
  }

  function getCierre(cierreId) {
    return leer(K.cierres, []).find((c) => c.id === cierreId) || null;
  }

  /* Se busca por CAMPOS, no por el id calculado: si una sede se
     renombra, el id que se generaría hoy no coincidiría con el de un
     cierre viejo, y ese cierre "desaparecería". La llave real es
     empresa + sucursal + fecha + área. */
  function buscarCierre(sucursalId, fechaCierre, area, empresaId) {
    const eid = empresaId || empresaActivaId();
    return (
      soloDeEmpresa(leer(K.cierres, []), eid).find(
        (c) =>
          Number(c.sucursalId) === Number(sucursalId) &&
          c.fechaCierre === fechaCierre &&
          c.area === area
      ) || null
    );
  }

  /**
   * Crea un cierre. Lanza error si ya existe uno para la misma
   * combinación sucursal + fecha + área (nunca crea un duplicado silencioso).
   *
   * datos = {
   *   sucursalId, fechaCierre, area, usuarioNombre, estado,
   *   productos: [{ codigo, nombre, saldo }]
   * }
   */
  function guardarCierre(datos) {
    validarCierre(datos);
    const eid = datos.empresaId || empresaActivaId();
    exigirUnidadOperativa(datos.sucursalId, eid);

    // La unicidad se comprueba por campos, que es la llave de verdad
    const existente = buscarCierre(datos.sucursalId, datos.fechaCierre, datos.area, eid);
    if (existente) {
      const e = new Error('YA_EXISTE');
      e.codigo = 'YA_EXISTE';
      e.cierreId = existente.id;
      throw e;
    }
    const cid = idCierre(datos.sucursalId, datos.fechaCierre, datos.area, eid);

    const ahora = new Date().toISOString();
    const cierre = {
      id: cid,
      empresaId: eid,
      sucursalId: Number(datos.sucursalId),
      fechaCierre: datos.fechaCierre, // jornada — la elige la persona
      fechaRegistro: ahora, // instante real del registro
      area: datos.area,
      usuarioId: datos.usuarioId || null,
      usuarioNombre: datos.usuarioNombre || 'Mesera',
      estado: datos.estado || 'completado',
      productos: normalizarProductosCierre(datos.productos),
      observaciones: datos.observaciones || '',
      historial: [
        {
          ts: ahora,
          texto: 'Cierre registrado por ' + (datos.usuarioNombre || 'Mesera'),
        },
      ],
    };

    const lista = leer(K.cierres, []);
    lista.push(cierre);
    escribir(K.cierres, lista);
    return cierre;
  }

  function validarCierre(datos) {
    if (!datos) throw new Error('Faltan los datos del cierre.');
    if (!datos.fechaCierre || !/^\d{4}-\d{2}-\d{2}$/.test(datos.fechaCierre))
      throw new Error('El cierre necesita una fecha válida.');
    if (!datos.sucursalId || !NASCAR.SUCURSALES.some((s) => Number(s.id) === Number(datos.sucursalId)))
      throw new Error('El cierre necesita una sucursal válida.');
    if (!datos.area || !NASCAR.AREAS.some((a) => a.id === datos.area))
      throw new Error('El cierre necesita un área válida (comidas o bar).');
    if (!Array.isArray(datos.productos) || !datos.productos.length)
      throw new Error('El cierre no tiene ningún producto registrado.');
  }

  /* Sólo se aceptan códigos que existan en el catálogo y saldos enteros >= 0. */
  function normalizarProductosCierre(productos) {
    return (productos || [])
      .map(function (p) {
        const cat = getProductoInventario(p.codigo);
        if (!cat) return null; // producto inexistente: se descarta
        const saldo = Number(p.saldo);
        if (!isFinite(saldo) || saldo < 0 || Math.floor(saldo) !== saldo) return null;
        return { codigo: cat.codigo, nombre: cat.nombre, saldo: saldo };
      })
      .filter(Boolean);
  }

  function actualizarCierre(cierreId, cambios) {
    const lista = leer(K.cierres, []);
    const i = lista.findIndex((c) => c.id === cierreId);
    if (i < 0) return null;

    const c = lista[i];
    const ahora = new Date().toISOString();

    if (cambios.productos) c.productos = normalizarProductosCierre(cambios.productos);
    if (cambios.observaciones !== undefined) c.observaciones = cambios.observaciones;
    if (cambios.estado) c.estado = cambios.estado;
    if (cambios.usuarioNombre) c.usuarioNombre = cambios.usuarioNombre;

    c.actualizado = ahora;
    c.historial = c.historial || [];
    c.historial.push({ ts: ahora, texto: cambios.motivo || 'Cierre corregido' });

    escribir(K.cierres, lista);
    return c;
  }

  function cambiarEstadoCierre(cierreId, estado, quien) {
    if (!NASCAR.ESTADOS_CIERRE.some((e) => e.id === estado))
      throw new Error('Estado de cierre no válido.');
    const nombres = {};
    NASCAR.ESTADOS_CIERRE.forEach((e) => (nombres[e.id] = e.nombre));
    return actualizarCierre(cierreId, {
      estado: estado,
      motivo: 'Estado: ' + nombres[estado] + (quien ? ' · ' + quien : ''),
    });
  }

  function borrarCierre(cierreId) {
    const c = getCierre(cierreId);
    if (!c) return false;
    // Un cierre ya revisado es parte de la auditoría: no se borra.
    if (c.estado === 'revisado') throw new Error('Un cierre revisado no se puede eliminar.');
    escribir(
      K.cierres,
      leer(K.cierres, []).filter((x) => x.id !== cierreId)
    );
    return true;
  }

  /* ===============================================================
     INVENTARIO · ENTRADAS (el campo EN del cruce)

     Compras y entradas de mercancía. Mientras no exista un módulo de
     compras real, la administradora las registra a mano. Si no hay
     entradas registradas, EN es 0 — nunca se inventan cantidades.
     =============================================================== */
  function getEntradas(filtro) {
    filtro = filtro || {};
    let lista = soloDeEmpresa(leer(K.entradas, []), empresaDe(filtro));
    if (filtro.sucursalId)
      lista = lista.filter((e) => Number(e.sucursalId) === Number(filtro.sucursalId));
    if (filtro.fecha) lista = lista.filter((e) => e.fecha === filtro.fecha);
    if (filtro.desde) lista = lista.filter((e) => e.fecha >= filtro.desde);
    if (filtro.hasta) lista = lista.filter((e) => e.fecha <= filtro.hasta);
    if (filtro.codigo) lista = lista.filter((e) => e.codigo === filtro.codigo);
    if (filtro.area) {
      lista = lista.filter(function (e) {
        const p = getProductoInventario(e.codigo);
        return p && p.area === filtro.area;
      });
    }
    return lista.sort((a, b) => (a.fecha < b.fecha ? 1 : a.fecha > b.fecha ? -1 : 0));
  }

  function guardarEntrada(datos) {
    const prod = getProductoInventario(datos.codigo);
    if (!prod) throw new Error('El producto no existe en el catálogo de inventario.');
    if (!datos.fecha || !/^\d{4}-\d{2}-\d{2}$/.test(datos.fecha))
      throw new Error('La entrada necesita una fecha válida.');
    if (!datos.sucursalId) throw new Error('La entrada necesita una sucursal.');
    exigirUnidadOperativa(datos.sucursalId);
    if (!esDeUnidad(prod, datos.sucursalId))
      throw new Error('El producto ' + prod.codigo + ' no pertenece a esta unidad.');

    const cantidad = Number(datos.cantidad);
    if (!isFinite(cantidad) || cantidad <= 0 || Math.floor(cantidad) !== cantidad)
      throw new Error('La cantidad debe ser un número entero mayor que cero.');

    const ahora = new Date().toISOString();
    const entrada = {
      id: id(),
      empresaId: datos.empresaId || empresaActivaId(),
      fecha: datos.fecha, // jornada operativa a la que se imputa
      sucursalId: Number(datos.sucursalId),
      codigo: prod.codigo,
      nombre: prod.nombre,
      area: prod.area,
      cantidad: cantidad,
      tipoEntrada: datos.tipoEntrada || 'compra',
      observacion: datos.observacion || '',
      registrado: ahora,
      usuarioId: datos.usuarioId || null,
      usuarioNombre: datos.usuarioNombre || 'Administración',
      rolUsuario: datos.rolUsuario || null,
      historial: [
        { ts: ahora, texto: 'Entrada registrada por ' + (datos.usuarioNombre || 'Administración') },
      ],
    };

    const lista = leer(K.entradas, []);
    lista.push(entrada);
    escribir(K.entradas, lista);
    return entrada;
  }

  /**
   * ¿Se puede tocar todavía esta entrada?
   *
   * Una entrada alimenta el campo EN del cruce de esa jornada. Si el
   * cierre correspondiente ya fue REVISADO por administración, cambiarla
   * alteraría un resultado que alguien ya dio por bueno. A partir de ahí
   * queda congelada.
   */
  function entradaEditable(entrada) {
    if (!entrada) return { editable: false, motivo: 'La entrada no existe.' };
    const prod = getProductoInventario(entrada.codigo);
    const area = prod ? prod.area : entrada.area;
    const cierre = buscarCierre(entrada.sucursalId, entrada.fecha, area);
    if (cierre && cierre.estado === 'revisado') {
      return {
        editable: false,
        motivo:
          'El cierre de ' + area + ' del ' + entrada.fecha +
          ' ya fue revisado: sus entradas quedaron congeladas.',
      };
    }
    return { editable: true, motivo: '' };
  }

  function actualizarEntrada(entradaId, datos, quien) {
    const lista = leer(K.entradas, []);
    const i = lista.findIndex((e) => e.id === entradaId);
    if (i < 0) throw new Error('No se encontró la entrada.');

    const permiso = entradaEditable(lista[i]);
    if (!permiso.editable) throw new Error(permiso.motivo);

    const cantidad = Number(datos.cantidad);
    if (datos.cantidad !== undefined && (!isFinite(cantidad) || cantidad <= 0 || Math.floor(cantidad) !== cantidad))
      throw new Error('La cantidad debe ser un número entero mayor que cero.');

    if (datos.codigo) {
      const prod = getProductoInventario(datos.codigo);
      if (!prod) throw new Error('El producto no existe en el catálogo de inventario.');
      lista[i].codigo = prod.codigo;
      lista[i].nombre = prod.nombre;
      lista[i].area = prod.area;
    }
    if (datos.fecha) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(datos.fecha)) throw new Error('Fecha no válida.');
      lista[i].fecha = datos.fecha;
    }
    if (datos.sucursalId) lista[i].sucursalId = Number(datos.sucursalId);
    if (datos.cantidad !== undefined) lista[i].cantidad = cantidad;
    if (datos.tipoEntrada) lista[i].tipoEntrada = datos.tipoEntrada;
    if (datos.observacion !== undefined) lista[i].observacion = datos.observacion;

    lista[i].historial = lista[i].historial || [];
    lista[i].historial.push({
      ts: new Date().toISOString(),
      texto: 'Entrada corregida por ' + (quien && quien.usuarioNombre ? quien.usuarioNombre : 'Administración'),
    });

    escribir(K.entradas, lista);
    return lista[i];
  }

  function borrarEntrada(entradaId) {
    const e = leer(K.entradas, []).find((x) => x.id === entradaId);
    const permiso = entradaEditable(e);
    if (!permiso.editable) throw new Error(permiso.motivo);
    escribir(
      K.entradas,
      leer(K.entradas, []).filter((x) => x.id !== entradaId)
    );
    return true;
  }

  /* Total de entradas por código para una jornada y sucursal. */
  function getEntradasPorProducto(fechaOperativa, sucursalId) {
    const mapa = {};
    getEntradas({ fecha: fechaOperativa, sucursalId: sucursalId }).forEach(function (e) {
      mapa[e.codigo] = (mapa[e.codigo] || 0) + e.cantidad;
    });
    return mapa;
  }

  /* ===============================================================
     INVENTARIO · VENTAS POR PRODUCTO (el campo Z del cruce)

     Se reutilizan los pedidos que ya existen; no se duplica nada.
     Se filtra por FECHA OPERATIVA, no por fecha calendario: así los
     pedidos de después de medianoche cuentan en la jornada correcta.

     Los platos del día no entran: son preparaciones diarias, no
     productos de inventario con saldo.
     =============================================================== */
  function getVentasProducto(fechaOperativa, sucursalId) {
    // refId de la carta -> código de inventario
    const porRef = {};
    (NASCAR.INVENTARIO || []).forEach(function (p) {
      (p.ventaRefIds || []).forEach(function (ref) {
        porRef[ref] = p.codigo;
      });
    });

    /* Área -> ¿el retorno de una factura anulada se imputa a ESTA
       jornada? Si sí, sus productos dejan de contar como vendidos aquí.
       Si no (porque la jornada ya tenía cierre), el pedido sigue
       contando tal cual y la mercancía volvió como entrada de otro día:
       el histórico no se toca. Ver anularPedido(). */
    function devuelveEnEstaJornada(pedido, area) {
      const a = pedido.anulacion;
      if (!a) return false;
      return (a.areasRetornadas || []).indexOf(area) >= 0;
    }

    const areaDe = {};
    (NASCAR.INVENTARIO || []).forEach((prod) => (areaDe[prod.codigo] = prod.area));

    const mapa = {};
    leer(K.pedidos, []).forEach(function (pedido) {
      if (pedido.estado === 'cancelado') return;
      if (sucursalId && Number(pedido.sucursalId) !== Number(sucursalId)) return;
      if (fechaOperativaPedido(pedido) !== fechaOperativa) return;

      pedido.items.forEach(function (it) {
        if (it.origen === 'dia') return; // el menú del día no lleva saldo
        const cod = porRef[it.refId];
        if (!cod) return; // vendido pero sin producto de inventario asociado
        if (pedido.estado === 'anulado' && devuelveEnEstaJornada(pedido, areaDe[cod])) return;
        mapa[cod] = (mapa[cod] || 0) + Number(it.cantidad || 0);
      });
    });
    return mapa;
  }

  /* ===============================================================
     INVENTARIO · SALDO ANTERIOR (el campo IN del cruce)

     IN sale del saldo físico del último cierre ANTERIOR de la misma
     sucursal y la misma área. No tiene que ser el día inmediatamente
     anterior: si hubo días sin cierre, se toma el último que exista.
     Si no hay ninguno, IN es 0 y se avisa.
     =============================================================== */
  function getCierreAnterior(sucursalId, area, fechaCierre) {
    const previos = getCierres({ sucursalId: sucursalId, area: area }).filter(
      (c) => c.fechaCierre < fechaCierre
    );
    return previos.length ? previos[0] : null; // getCierres ya viene ordenado desc
  }

  function getSaldoAnterior(sucursalId, area, fechaCierre) {
    const anterior = getCierreAnterior(sucursalId, area, fechaCierre);
    const saldos = {};
    if (anterior) {
      anterior.productos.forEach(function (p) {
        saldos[p.codigo] = p.saldo;
      });
    }
    return { cierre: anterior, saldos: saldos };
  }

  /**
   * SALDO INICIAL (IN) de cada producto para una jornada.
   *
   * Antes esto miraba únicamente el último cierre anterior, así que el
   * primer cierre de cada producto arrancaba en 0 aunque el módulo Stock
   * tuviera un saldo configurado: el cruce mostraba un "sobrante"
   * inventado del tamaño de todo lo contado. Ahora hay una cadena de
   * respaldo, por producto:
   *
   *   1. El saldo físico del cierre más reciente en el que ese producto
   *      aparezca. Es el dato bueno: alguien lo contó de verdad. No tiene
   *      que ser el cierre inmediatamente anterior — si un día no se contó
   *      un producto, se busca hacia atrás hasta encontrarlo.
   *   2. Si nunca se ha contado, el `stockActual` del módulo Stock, que es
   *      la línea base que configuró la administración.
   *   3. Si tampoco hay nada, 0.
   *
   * OJO: esto NO copia el stock como saldo físico (SD). SD lo sigue
   * escribiendo únicamente la persona que cuenta. Aquí sólo se resuelve
   * con cuánto se supone que empezó la jornada.
   *
   * Se devuelve además de dónde salió cada número, porque para la
   * administradora no es lo mismo un IN contado que uno heredado del
   * catálogo, y la pantalla tiene que poder decirlo.
   */
  function getSaldoInicial(sucursalId, area, fechaCierre) {
    const previos = getCierres({ sucursalId: sucursalId, area: area }).filter(
      (c) => c.fechaCierre < fechaCierre
    ); // getCierres ya viene del más reciente al más antiguo

    const saldos = {};
    const origen = {}; // 'cierre' | 'stock' | 'sin-dato'
    const fuente = {}; // fecha del cierre del que salió el dato

    previos.forEach(function (c) {
      c.productos.forEach(function (p) {
        // El primero que aparece gana: es el cierre más reciente.
        if (!Object.prototype.hasOwnProperty.call(saldos, p.codigo)) {
          saldos[p.codigo] = p.saldo;
          origen[p.codigo] = 'cierre';
          fuente[p.codigo] = c.fechaCierre;
        }
      });
    });

    // Lo que nunca se ha contado se apoya en el catálogo de Stock.
    getStock({ todos: true }).forEach(function (p) {
      if (Object.prototype.hasOwnProperty.call(saldos, p.codigo)) return;
      saldos[p.codigo] = p.stockActual || 0;
      origen[p.codigo] = p.stockActual > 0 ? 'stock' : 'sin-dato';
    });

    return {
      cierre: previos.length ? previos[0] : null,
      saldos: saldos,
      origen: origen,
      fuente: fuente,
    };
  }

  /* ===============================================================
     ABASTECIMIENTO · alertas de stock bajo y sin stock

     Clasifica el catálogo en tres estados y dice qué toca pedir. Es
     CONSULTA: no escribe nada, no crea órdenes de compra y no toca el
     catálogo. Vive dentro del módulo Stock, no aparte.
     =============================================================== */

  /* Existencias de UNA sucursal.

     El catálogo de stock es de la EMPRESA, no de la sede: `stockActual`
     es uno solo. Lo que sí es por sucursal son los cierres, donde cada
     sede cuenta su inventario físico. Así que para mirar una sede se usa
     el saldo de su último cierre —el dato real de esa sede— y sólo se
     cae al catálogo cuando ese producto nunca se ha contado ahí.

     Es la misma idea de getSaldoInicial(), que ya alimenta el campo IN
     del cruce; aquí se mira hasta hoy inclusive en vez de hasta la
     víspera. No hay un segundo inventario. */
  function existenciasDeSucursal(sucursalId, empresaId) {
    const eid = empresaId || empresaActivaId();
    const saldos = {};
    const origen = {}; // 'cierre' | 'catalogo'
    const fuente = {}; // fecha del cierre del que salió el dato

    // getCierres viene del más reciente al más antiguo: el primero gana.
    getCierres({ sucursalId: sucursalId, empresaId: eid }).forEach(function (c) {
      (c.productos || []).forEach(function (x) {
        if (Object.prototype.hasOwnProperty.call(saldos, x.codigo)) return;
        saldos[x.codigo] = x.saldo;
        origen[x.codigo] = 'cierre';
        fuente[x.codigo] = c.fechaCierre;
      });
    });

    return { saldos: saldos, origen: origen, fuente: fuente };
  }

  /* Los tres estados del enunciado, en un solo sitio.

       🔴 sin     -> existencia = 0
       🟡 bajo    -> existencia > 0 y existencia <= stockMinimo
       🟢 normal  -> el resto

     Un producto sin mínimo configurado (0) nunca puede estar "bajo":
     no hay contra qué comparar. Si además está en cero, sí es "sin
     stock" — eso no depende del mínimo. */
  function estadoDeExistencia(existencia, stockMinimo) {
    if (existencia <= 0) return 'sin';
    if (stockMinimo > 0 && existencia <= stockMinimo) return 'bajo';
    return 'normal';
  }

  /**
   * estadoAbastecimiento({ sucursalId, area, texto, empresaId })
   *
   * Devuelve el catálogo activo clasificado, el resumen para las
   * tarjetas y la lista de lo que toca pedir.
   *
   * Los productos DESACTIVADOS quedan fuera: no se piden. Siguen en el
   * catálogo y en los cierres históricos, que no se tocan.
   */
  function estadoAbastecimiento(opciones) {
    opciones = opciones || {};
    const eid = opciones.empresaId || empresaActivaId();
    const suc = opciones.sucursalId ? Number(opciones.sucursalId) : null;

    const porSede = suc ? existenciasDeSucursal(suc, eid) : null;

    const productos = getStock({
      area: opciones.area || undefined,
      texto: opciones.texto || undefined,
      empresaId: eid,
      sucursalId: suc || undefined,
    }).map(function (p) {
      /* Con sucursal elegida manda lo que esa sede contó; si nunca lo
         contó, el catálogo. Sin sucursal, el catálogo tal cual. */
      const contado =
        porSede && Object.prototype.hasOwnProperty.call(porSede.saldos, p.codigo);
      const existencia = contado ? porSede.saldos[p.codigo] : p.stockActual;
      const estado = estadoDeExistencia(existencia, p.stockMinimo);

      /* Cantidad SUGERIDA, sólo como referencia: lo que falta para
         volver al mínimo. Sin mínimo configurado no hay sugerencia que
         dar, y se devuelve 0 para no inventar un número. */
      const faltante = Math.max(0, p.stockMinimo - existencia);

      return Object.assign({}, p, {
        existencia: existencia,
        origen: contado ? 'cierre' : 'catalogo',
        fuente: contado ? porSede.fuente[p.codigo] : null,
        estado: estado,
        sugerido: p.stockMinimo > 0 ? faltante : 0,
        sinMinimo: p.stockMinimo <= 0,
      });
    });

    const resumen = {
      total: productos.length,
      normal: productos.filter((x) => x.estado === 'normal').length,
      bajo: productos.filter((x) => x.estado === 'bajo').length,
      sin: productos.filter((x) => x.estado === 'sin').length,
      sinMinimo: productos.filter((x) => x.sinMinimo).length,
    };

    /* Lo que toca pedir: primero lo que está en cero, y dentro de cada
       grupo lo más urgente arriba. */
    const orden = { sin: 0, bajo: 1 };
    const porPedir = productos
      .filter((x) => x.estado === 'sin' || x.estado === 'bajo')
      .sort(function (a, b) {
        if (orden[a.estado] !== orden[b.estado]) return orden[a.estado] - orden[b.estado];
        if (b.sugerido !== a.sugerido) return b.sugerido - a.sugerido;
        return a.nombre < b.nombre ? -1 : 1;
      });

    const sucursal = suc ? getSucursal(suc, eid) : null;

    return {
      empresaId: eid,
      sucursalId: suc,
      sucursalNombre: sucursal ? sucursal.nombre : 'Todas las unidades',
      porSucursal: !!suc,
      productos: productos,
      resumen: resumen,
      porPedir: porPedir,
    };
  }

  /* ===============================================================
     INVENTARIO · CRUCE

         SLDC = IN + EN - Z
         DF   = SD - SLDC

     DF = 0  -> coincide
     DF > 0  -> sobrante (hay más producto del esperado)
     DF < 0  -> faltante (hay menos producto del esperado)
     =============================================================== */
  function calcularCruce(sucursalId, fechaCierre, area) {
    const cierre = buscarCierre(sucursalId, fechaCierre, area);
    // IN: cierre anterior si existe, si no el stock configurado (ver arriba)
    const anterior = getSaldoInicial(sucursalId, area, fechaCierre);
    const entradas = getEntradasPorProducto(fechaCierre, sucursalId);
    const ventas = getVentasProducto(fechaCierre, sucursalId);

    // Saldos físicos reportados por la mesera
    const fisico = {};
    if (cierre) cierre.productos.forEach((p) => (fisico[p.codigo] = p.saldo));

    // Se recorre el catálogo del área, más cualquier producto que
    // aparezca en el cierre aunque ya no esté activo en el catálogo.
    // Sólo el catálogo de ESTA unidad: el cruce de un local no lleva productos de otro
    const codigos = getProductosInventario({ area: area, sucursalId: sucursalId }).map((p) => p.codigo);
    if (cierre)
      cierre.productos.forEach(function (p) {
        if (codigos.indexOf(p.codigo) < 0) codigos.push(p.codigo);
      });

    const filas = codigos.map(function (codigo) {
      const prod = getProductoInventario(codigo) || { codigo: codigo, nombre: codigo, categoria: '—', unidad: '' };
      const registrado = Object.prototype.hasOwnProperty.call(fisico, codigo);

      // Un saldo de 0 registrado a propósito es un dato válido, así que se
      // comprueba la presencia de la clave, no si el número es "falsy".
      const IN = Object.prototype.hasOwnProperty.call(anterior.saldos, codigo)
        ? anterior.saldos[codigo]
        : 0;
      const EN = entradas[codigo] || 0;
      const Z = ventas[codigo] || 0;
      const SLDC = IN + EN - Z;
      const SD = registrado ? fisico[codigo] : null;
      const DF = registrado ? SD - SLDC : null;

      return {
        codigo: codigo,
        nombre: prod.nombre,
        categoria: prod.categoria,
        unidad: prod.unidad || '',
        IN: IN,
        // De dónde salió el IN: 'cierre' (alguien lo contó), 'stock'
        // (línea base del catálogo) o 'sin-dato'.
        origenIN: anterior.origen[codigo] || 'sin-dato',
        fuenteIN: anterior.fuente[codigo] || null,
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
      // De dónde vino el saldo inicial, para poder avisar en pantalla
      inDesdeCierre: filas.filter((f) => f.origenIN === 'cierre').length,
      inDesdeStock: filas.filter((f) => f.origenIN === 'stock').length,
      inSinDato: filas.filter((f) => f.origenIN === 'sin-dato').length,
    };
    resumen.sinDiferencias = resumen.revisados > 0 && resumen.sobrantes === 0 && resumen.faltantes === 0;

    return {
      sucursalId: Number(sucursalId),
      fechaCierre: fechaCierre,
      area: area,
      cierre: cierre,
      hayCierre: !!cierre,
      cierreAnterior: anterior.cierre,
      hayCierreAnterior: !!anterior.cierre,
      filas: filas,
      resumen: resumen,
    };
  }

  /* ===============================================================
     GASTOS  (salidas de dinero)

     Deliberadamente SEPARADO de las ventas: `ventas()` no cambia y aquí
     no se toca ningún pedido. Un gasto es una salida de caja, no una
     venta en negativo. Cuando exista el módulo de Caja se cruzarán las
     dos cosas; por ahora conviven sin mezclarse.

     Estados:  registrado → confirmado
               registrado → anulado
     Un gasto anulado NO se borra: conserva quién lo anuló, cuándo y por qué.
     =============================================================== */
  const ESTADOS_GASTO_IDS = ['registrado', 'confirmado', 'anulado'];

  function getCategoriasGasto(opciones) {
    opciones = opciones || {};
    const lista = NASCAR.CATEGORIAS_GASTO || [];
    return opciones.todas ? lista.slice() : lista.filter((c) => c.activa !== false);
  }

  function categoriaGasto(catId) {
    return (NASCAR.CATEGORIAS_GASTO || []).find((c) => c.id === catId) || null;
  }

  /**
   * getGastos({ sucursalId, categoria, estado, metodoPago, fecha,
   *             desde, hasta, texto, incluirAnulados })
   * Por defecto los anulados SÍ vienen (son parte del historial);
   * los totales son los que los excluyen.
   */
  function getGastos(filtro) {
    filtro = filtro || {};
    let lista = soloDeEmpresa(leer(K.gastos, []), empresaDe(filtro));

    if (filtro.sucursalId)
      lista = lista.filter((g) => Number(g.sucursalId) === Number(filtro.sucursalId));
    if (filtro.categoria) lista = lista.filter((g) => g.categoria === filtro.categoria);
    if (filtro.estado) lista = lista.filter((g) => g.estado === filtro.estado);
    if (filtro.metodoPago) lista = lista.filter((g) => g.metodoPago === filtro.metodoPago);
    if (filtro.fecha) lista = lista.filter((g) => g.fecha === filtro.fecha);
    if (filtro.desde) lista = lista.filter((g) => g.fecha >= filtro.desde);
    if (filtro.hasta) lista = lista.filter((g) => g.fecha <= filtro.hasta);
    if (filtro.incluirAnulados === false) lista = lista.filter((g) => g.estado !== 'anulado');

    if (filtro.texto) {
      const q = String(filtro.texto).trim().toLowerCase();
      lista = lista.filter(
        (g) =>
          (g.concepto || '').toLowerCase().includes(q) ||
          (g.tercero || '').toLowerCase().includes(q) ||
          (g.observaciones || '').toLowerCase().includes(q) ||
          (g.consecutivo || '').toLowerCase().includes(q)
      );
    }

    // Más recientes primero; a igual fecha, por hora
    return lista.sort(function (a, b) {
      if (a.fecha !== b.fecha) return a.fecha < b.fecha ? 1 : -1;
      return (a.hora || '') < (b.hora || '') ? 1 : -1;
    });
  }

  function getGasto(gastoId) {
    return leer(K.gastos, []).find((g) => g.id === gastoId) || null;
  }

  /* Consecutivo legible por sucursal:  G1-260828-004 */
  function siguienteConsecutivoGasto(sucursalId, fecha, empresaId) {
    const eid = empresaId || empresaActivaId();
    const delDia = soloDeEmpresa(leer(K.gastos, []), eid).filter(
      (g) => Number(g.sucursalId) === Number(sucursalId) && g.fecha === fecha
    );
    const compacto = String(fecha).slice(2).replace(/-/g, '');
    return (
      'G' + sucursalId + '-' + compacto + '-' +
      String(delDia.length + 1).padStart(3, '0') + tagEmpresa(eid)
    );
  }

  function validarGasto(datos) {
    if (!datos) throw new Error('Faltan los datos del gasto.');
    if (!datos.fecha || !/^\d{4}-\d{2}-\d{2}$/.test(datos.fecha))
      throw new Error('El gasto necesita una fecha válida.');
    if (!datos.sucursalId || !getSucursal(datos.sucursalId))
      throw new Error('El gasto necesita una sucursal válida.');
    exigirUnidadOperativa(datos.sucursalId, datos.empresaId);
    if (!datos.categoria || !categoriaGasto(datos.categoria))
      throw new Error('Elige una categoría para el gasto.');
    if (!datos.concepto || String(datos.concepto).trim().length < 3)
      throw new Error('Escribe en qué se gastó el dinero (mínimo 3 caracteres).');

    const valor = Number(datos.valor);
    if (!isFinite(valor) || valor <= 0)
      throw new Error('El valor debe ser un número mayor que cero.');

    const metodos = (getConfig().metodosPago || []).map((m) => m.id);
    if (!datos.metodoPago || metodos.indexOf(datos.metodoPago) < 0)
      throw new Error('Elige un método de pago válido.');
  }

  function crearGasto(datos) {
    validarGasto(datos);

    const ahora = new Date();
    const iso = ahora.toISOString();
    const eid = datos.empresaId || empresaActivaId();
    const suc = getSucursal(datos.sucursalId, eid);

    const gasto = {
      id: 'g' + id(),
      empresaId: eid,
      consecutivo: siguienteConsecutivoGasto(datos.sucursalId, datos.fecha, eid),

      // Cuándo ocurrió el gasto (lo elige la persona, como en los cierres)
      fecha: datos.fecha,
      hora: datos.hora || ahora.toTimeString().slice(0, 5),

      sucursalId: Number(datos.sucursalId),
      // Copia del nombre: si la sucursal se renombra, el histórico no miente
      sucursalNombre: suc ? suc.nombre : '',

      categoria: datos.categoria,
      concepto: String(datos.concepto).trim(),
      tercero: (datos.tercero || '').trim(), // proveedor o persona
      valor: Number(datos.valor),
      metodoPago: datos.metodoPago,
      observaciones: (datos.observaciones || '').trim(),

      estado: 'registrado',

      // Auditoría: quién lo creó, quién lo confirmó, quién lo anuló
      usuarioId: datos.usuarioId || null,
      usuarioNombre: datos.usuarioNombre || 'Sistema',
      rolUsuario: datos.rolUsuario || null,
      creado: iso,

      confirmadoPorId: null,
      confirmadoPor: null,
      confirmado: null,

      anuladoPorId: null,
      anuladoPor: null,
      anulado: null,
      motivoAnulacion: '',

      historial: [
        { ts: iso, texto: 'Gasto registrado por ' + (datos.usuarioNombre || 'Sistema') },
      ],
    };

    const lista = leer(K.gastos, []);
    lista.push(gasto);
    escribir(K.gastos, lista);
    return gasto;
  }

  function _mutarGasto(gastoId, fn) {
    const lista = leer(K.gastos, []);
    const i = lista.findIndex((g) => g.id === gastoId);
    if (i < 0) return null;
    fn(lista[i]);
    escribir(K.gastos, lista);
    return lista[i];
  }

  /* Editar sólo tiene sentido mientras nadie lo ha confirmado ni anulado. */
  function actualizarGasto(gastoId, datos, quien) {
    const g = getGasto(gastoId);
    if (!g) throw new Error('No se encontró el gasto.');
    if (g.estado !== 'registrado')
      throw new Error('Un gasto ' + g.estado + ' ya no se puede editar.');

    validarGasto(Object.assign({}, g, datos));

    return _mutarGasto(gastoId, function (x) {
      ['fecha', 'hora', 'categoria', 'concepto', 'tercero', 'metodoPago', 'observaciones'].forEach(
        function (campo) {
          if (datos[campo] !== undefined) x[campo] = datos[campo];
        }
      );
      if (datos.valor !== undefined) x.valor = Number(datos.valor);
      if (datos.sucursalId !== undefined) {
        x.sucursalId = Number(datos.sucursalId);
        const s = getSucursal(datos.sucursalId);
        x.sucursalNombre = s ? s.nombre : '';
      }
      x.historial.push({
        ts: new Date().toISOString(),
        texto: 'Gasto corregido' + (quien ? ' por ' + quien.usuarioNombre : ''),
      });
    });
  }

  function confirmarGasto(gastoId, quien) {
    const g = getGasto(gastoId);
    if (!g) throw new Error('No se encontró el gasto.');
    if (g.estado === 'anulado') throw new Error('Un gasto anulado no se puede confirmar.');
    if (g.estado === 'confirmado') return g;

    const iso = new Date().toISOString();
    return _mutarGasto(gastoId, function (x) {
      x.estado = 'confirmado';
      x.confirmadoPorId = quien ? quien.usuarioId : null;
      x.confirmadoPor = quien ? quien.usuarioNombre : 'Administración';
      x.confirmado = iso;
      x.historial.push({
        ts: iso,
        texto: 'Gasto confirmado por ' + (quien ? quien.usuarioNombre : 'Administración'),
      });
    });
  }

  /* Anular NO borra: el registro se queda con su motivo y su autor. */
  function anularGasto(gastoId, motivo, quien) {
    const g = getGasto(gastoId);
    if (!g) throw new Error('No se encontró el gasto.');
    if (g.estado === 'anulado') return g;
    if (!motivo || String(motivo).trim().length < 4)
      throw new Error('Escribe por qué se anula el gasto.');

    const iso = new Date().toISOString();
    return _mutarGasto(gastoId, function (x) {
      x.estado = 'anulado';
      x.anuladoPorId = quien ? quien.usuarioId : null;
      x.anuladoPor = quien ? quien.usuarioNombre : 'Administración';
      x.anulado = iso;
      x.motivoAnulacion = String(motivo).trim();
      x.historial.push({
        ts: iso,
        texto: 'Anulado por ' + (quien ? quien.usuarioNombre : 'Administración') + ': ' + x.motivoAnulacion,
      });
    });
  }

  /**
   * Resumen de gastos. Los ANULADOS no suman en ningún total: siguen en
   * el historial pero no son dinero que salió.
   */
  function resumenGastos(desde, hasta, sucursalId) {
    const hoyISO = hoy();
    desde = desde || hoyISO;
    hasta = hasta || desde;

    const filtro = { desde: desde, hasta: hasta, incluirAnulados: false };
    if (sucursalId) filtro.sucursalId = sucursalId;
    const lista = getGastos(filtro);

    const mesDesde = hoyISO.slice(0, 8) + '01';
    const delMes = getGastos(
      Object.assign({ desde: mesDesde, hasta: hoyISO, incluirAnulados: false },
        sucursalId ? { sucursalId: sucursalId } : {})
    );
    const delDia = lista.filter((g) => g.fecha === hoyISO);

    const r = {
      desde: desde,
      hasta: hasta,
      n: lista.length,
      total: lista.reduce((s, g) => s + g.valor, 0),
      totalDia: delDia.reduce((s, g) => s + g.valor, 0),
      nDia: delDia.length,
      totalMes: delMes.reduce((s, g) => s + g.valor, 0),
      nMes: delMes.length,
      porCategoria: {},
      porSucursal: {},
      porMetodo: {},
      porEstado: { registrado: 0, confirmado: 0, anulado: 0 },
      pendientes: 0,
      montoPendiente: 0,
    };

    lista.forEach(function (g) {
      r.porCategoria[g.categoria] = r.porCategoria[g.categoria] || { n: 0, total: 0 };
      r.porCategoria[g.categoria].n += 1;
      r.porCategoria[g.categoria].total += g.valor;

      r.porSucursal[g.sucursalId] = r.porSucursal[g.sucursalId] || { n: 0, total: 0 };
      r.porSucursal[g.sucursalId].n += 1;
      r.porSucursal[g.sucursalId].total += g.valor;

      r.porMetodo[g.metodoPago] = r.porMetodo[g.metodoPago] || { n: 0, total: 0 };
      r.porMetodo[g.metodoPago].n += 1;
      r.porMetodo[g.metodoPago].total += g.valor;

      if (g.estado === 'registrado') {
        r.pendientes += 1;
        r.montoPendiente += g.valor;
      }
    });

    // Los anulados se cuentan aparte, sólo para informar
    const conAnulados = getGastos(
      Object.assign({ desde: desde, hasta: hasta }, sucursalId ? { sucursalId: sucursalId } : {})
    );
    conAnulados.forEach((g) => (r.porEstado[g.estado] = (r.porEstado[g.estado] || 0) + 1));
    r.anulados = r.porEstado.anulado;
    r.montoAnulado = conAnulados
      .filter((g) => g.estado === 'anulado')
      .reduce((s, g) => s + g.valor, 0);

    return r;
  }

  /* ===============================================================
     SESIÓN DEL PANEL
     =============================================================== */
  let sesionEnMemoria = null; // { usuarioId, nombre, rol, sucursalId }

  function guardarSesion(s) {
    sesionEnMemoria = s;
    try {
      if (s) {
        sessionStorage.setItem(K.sesion, '1');
        sessionStorage.setItem(K.sesionUsuario, JSON.stringify(s));
      } else {
        sessionStorage.removeItem(K.sesion);
        sessionStorage.removeItem(K.sesionUsuario);
      }
    } catch (e) {
      /* la sesión vive sólo en memoria mientras dure la página */
    }
  }

  /**
   * login(pin)            → compatibilidad: entra con el PIN de admin.
   * login(usuario, pin)   → entra como ese usuario, con su rol.
   */
  function login(a, b) {
    if (b === undefined) {
      // Forma antigua: sólo PIN. Se resuelve contra el usuario admin,
      // y si no coincide, contra el PIN general de configuración.
      const porPin = getUsuarios().find((u) => String(u.pin) === String(a));
      if (porPin) return login(porPin.usuario, a);
      if (String(a) !== String(getConfig().pinAdmin)) return false;
      guardarSesion({
        usuarioId: null, nombre: 'Administración', rol: 'admin',
        scope: SCOPE_EMPRESA, sucursalId: null,
      });
      return true;
    }

    const u = autenticar(a, b);
    if (!u) return false;

    /* NIVEL 1 · PLATAFORMA.
       El SuperAdmin de Taseca no pertenece a ninguna empresa: entra sin
       empresa (`empresaId: null`) y sin contexto. Desde su panel elige
       a cuál entrar, y esa elección vive en la sesión — no lo convierte
       en usuario de esa empresa. */
    if (esUsuarioPlataforma(u)) {
      guardarSesion({
        usuarioId: u.id,
        nombre: u.nombre,
        rol: u.rol,
        scope: SCOPE_PLATAFORMA,
        empresaId: null,
        empresaContext: null,
        sucursalId: null,
      });
      return true;
    }

    /* Entrar como alguien cambia a la empresa de esa persona: es su
       empresa la que va a ver. */
    const suEmpresa = u.empresaId || EMPRESA_DEFECTO;
    if (suEmpresa !== empresaActivaId()) {
      try {
        setEmpresaActual(suEmpresa);
      } catch (e) {
        return false; // su empresa está desactivada
      }
    }

    // NIVEL 2 · EMPRESA CLIENTE
    guardarSesion({
      usuarioId: u.id,
      nombre: u.nombre,
      rol: u.rol,
      scope: SCOPE_EMPRESA,
      empresaId: suEmpresa,
      sucursalId: u.sucursalId,
    });
    return true;
  }

  function logout() {
    guardarSesion(null);
  }

  function estaAutenticado() {
    return !!getSesion();
  }

  function getSesion() {
    if (sesionEnMemoria) return sesionEnMemoria;
    try {
      const raw = sessionStorage.getItem(K.sesionUsuario);
      if (raw) {
        sesionEnMemoria = JSON.parse(raw);
        return sesionEnMemoria;
      }
      // Sesión creada antes de que existieran los roles
      if (sessionStorage.getItem(K.sesion) === '1') {
        sesionEnMemoria = {
          usuarioId: null, nombre: 'Administración', rol: 'admin',
          scope: SCOPE_EMPRESA, sucursalId: null,
        };
        return sesionEnMemoria;
      }
    } catch (e) {}
    return null;
  }

  /* ===============================================================
     MANTENIMIENTO
     =============================================================== */
  function exportar() {
    return JSON.stringify(
      {
        version: VERSION_DATOS,
        exportado: new Date().toISOString(),
        empresas: leer(K.empresas, null),
        empresaActual: leer(K.empresaActual, null),
        pedidos: leer(K.pedidos, []),
        platosDia: leer(K.dia, []),
        menusDia: leer(K.menusDia, []),
        cartaOverrides: leer(K.carta, {}),
        consecutivo: leer(K.seq, {}),
        cierres: leer(K.cierres, []),
        entradas: leer(K.entradas, []),
        // --- configuración administrable ---
        config: leer(K.config, {}),
        sucursales: leer(K.sucursales, null),
        categorias: leer(K.categorias, null),
        cartaV2: leer(K.cartaV2, null),
        stock: leer(K.stock, null),
        usuarios: leer(K.usuarios, null),
        comprobantes: leer(K.comprobantes, {}),
        gastos: leer(K.gastos, []),
        bases: leer(K.bases, []),
        unidadActiva: leer(K.unidadActiva, {}),
      },
      null,
      2
    );
  }

  function importar(json) {
    const d = JSON.parse(json);
    if (!d || typeof d !== 'object') throw new Error('Archivo inválido');
    if (d.pedidos) escribir(K.pedidos, d.pedidos);
    if (d.platosDia) escribir(K.dia, d.platosDia);
    if (d.menusDia) escribir(K.menusDia, d.menusDia);
    if (d.cartaOverrides) escribir(K.carta, d.cartaOverrides);
    if (d.consecutivo) escribir(K.seq, d.consecutivo);
    if (d.cierres) escribir(K.cierres, d.cierres);
    if (d.entradas) escribir(K.entradas, d.entradas);
    // configuración administrable (los respaldos antiguos no la traen)
    if (d.config) escribir(K.config, d.config);
    if (d.sucursales) escribir(K.sucursales, d.sucursales);
    if (d.categorias) escribir(K.categorias, d.categorias);
    if (d.cartaV2) escribir(K.cartaV2, d.cartaV2);
    if (d.stock) escribir(K.stock, d.stock);
    if (d.usuarios) escribir(K.usuarios, d.usuarios);
    if (d.comprobantes) escribir(K.comprobantes, d.comprobantes);
    if (d.gastos) escribir(K.gastos, d.gastos);
    if (d.bases) escribir(K.bases, d.bases);
    if (d.unidadActiva) escribir(K.unidadActiva, d.unidadActiva);
    if (d.empresas) escribir(K.empresas, d.empresas);
    if (d.empresaActual) escribir(K.empresaActual, d.empresaActual);

    /* Un respaldo anterior a multiempresa no trae `empresas` ni
       `empresaId`: se le aplica la misma migración que a los datos
       locales, así se puede restaurar sin problema. */
    if (!d.empresas || !d.version || d.version < 3) {
      migrarAMultiempresa(null);
    }
    /* Y lo mismo con los módulos: un respaldo v3 trae el mapa de cuatro
       módulos de la versión anterior. */
    if (!d.version || d.version < 4) {
      migrarModulos(null);
    }
    /* Un respaldo anterior al panel de plataforma no trae al SuperAdmin:
       se agrega, o quien restaure se quedaría sin poder entrar. */
    migrarPlataforma();
    migrarScope(null);
    migrarTemas(null);
    migrarUnidades();
    ajustarUnidadesReales(null);
    cargarCatalogoReal(null);

    hidratar();
    return true;
  }

  function borrarTodo() {
    Object.values(K).forEach(function (k) {
      delete memoria[k];
      try {
        localStorage.removeItem(k);
      } catch (e) {
        /* sin almacenamiento: basta con haber limpiado la memoria */
      }
    });
    emitir();
  }

  /* Arranque: copia los valores de data.js a localStorage si es la
     primera vez, y siembra el menú del día para que no salga vacío. */
  function sembrar() {
    migrar();
    if (leer(K.seed, null) === 1) return;
    /* La semilla se siembra para la empresa por defecto, que es la que
       trae los datos de fábrica. Se estampa explícitamente para que no
       queden registros sin dueño. */
    if (getPlatosDia(hoy(), null, EMPRESA_DEFECTO).length === 0) {
      /* La semilla habla de las unidades de data.js; aquí se traducen a
         las guardadas (ver mapaSemillaUnidades). */
      const mapa = mapaSemillaUnidades(EMPRESA_DEFECTO);
      NASCAR.SEMILLA_DIA.forEach(function (p) {
        const suc = mapa[Number(p.sucursalId)];
        if (!suc) return;
        guardarPlatoDiaInterno(
          Object.assign({}, p, { sucursalId: suc, fecha: hoy(), vendidos: 0 }),
          EMPRESA_DEFECTO
        );
      });
    }
    escribir(K.seed, 1);
  }

  /* Al cargar el archivo se deja todo listo: si es la primera vez se
     copian los valores de data.js, y los globales NASCAR.* quedan con
     la configuración vigente antes de que se pinte cualquier pantalla. */
  try {
    migrar();
  } catch (e) {
    console.error('[Store] Falló la migración inicial; se usan los valores de data.js.', e);
  }

  /* --------------------------------------------------------------- */
  return {
    // fechas
    hoy: hoy,
    aISO: aISO,
    desdeISO: desdeISO,
    // jornada operativa (el día cierra de madrugada)
    horaCorte: horaCorte,
    fechaOperativaDe: fechaOperativaDe,
    hoyOperativo: hoyOperativo,
    fechaOperativaPedido: fechaOperativaPedido,
    // empresas (multiempresa)
    EMPRESA_DEFECTO: EMPRESA_DEFECTO,
    getEmpresas: getEmpresas,
    getEmpresa: getEmpresa,
    getEmpresaActual: getEmpresaActual,
    setEmpresaActual: setEmpresaActual,
    guardarEmpresa: guardarEmpresa,
    activarEmpresa: activarEmpresa,
    moduloActivo: moduloActivo, // alias histórico de hasModule
    hasModule: hasModule,
    getTheme: getTheme,
    setTheme: setTheme,
    altaEmpresa: altaEmpresa,
    familiaTipografica: familiaTipografica,
    tipografia: tipografia,

    // --- Cruce de información / caja de la jornada ---
    getBases: getBases,
    getBaseCaja: getBaseCaja,
    getHistorialBase: getHistorialBase,
    registrarBase: registrarBase,
    informeCaja: informeCaja,
    grupoDeMetodo: grupoDeMetodo,
    PLATAFORMA: PLATAFORMA,
    SCOPE_PLATAFORMA: SCOPE_PLATAFORMA,
    SCOPE_EMPRESA: SCOPE_EMPRESA,
    esUsuarioPlataforma: esUsuarioPlataforma,
    getUsuariosPlataforma: getUsuariosPlataforma,
    getEmpresaContexto: getEmpresaContexto,
    setEmpresaContexto: setEmpresaContexto,
    salirDeEmpresa: salirDeEmpresa,
    getModulos: getModulos,
    setModulos: setModulos,
    catalogoModulos: catalogoModulos,
    definicionModulo: definicionModulo,

    // configuración administrable
    getConfig: getConfig,
    guardarConfig: guardarConfig,
    restablecerConfig: restablecerConfig,
    getSucursales: getSucursales,
    getSucursal: getSucursal,
    guardarSucursal: guardarSucursal,
    activarSucursal: activarSucursal,
    // unidades / locales (la sucursal ES la unidad)
    getUnidades: getSucursales,
    getUnidad: getSucursal,
    guardarUnidad: guardarSucursal,
    activarUnidad: activarSucursal,
    getTipoNegocio: getTipoNegocio,
    unidadActivaId: unidadActivaId,
    getUnidadActiva: getUnidadActiva,
    setUnidadActiva: setUnidadActiva,
    getCategorias: getCategorias,
    guardarCategoria: guardarCategoria,
    borrarCategoria: borrarCategoria,
    hidratar: hidratar,
    migrar: migrar,

    // carta
    getCarta: getCarta,
    getCartaDisponible: getCartaDisponible,
    getPlatoCarta: getPlatoCarta,
    guardarPlatoCarta: guardarPlatoCarta,
    borrarPlatoCarta: borrarPlatoCarta,
    ajustarPlatoCarta: ajustarPlatoCarta,
    resetCarta: resetCarta,

    // stock (catálogo de inventario)
    getStock: getStock,
    guardarProductoStock: guardarProductoStock,
    activarProductoStock: activarProductoStock,
    ajustarStockActual: ajustarStockActual,
    aplicarCierreAStock: aplicarCierreAStock,
    resetStock: resetStock,

    // usuarios
    getUsuarios: getUsuarios,
    getUsuario: getUsuario,
    guardarUsuario: guardarUsuario,
    activarUsuario: activarUsuario,
    autenticar: autenticar,

    // comprobantes de pago
    getComprobante: getComprobante,
    guardarComprobante: guardarComprobante,
    borrarComprobante: borrarComprobante,
    pesoComprobantesKB: pesoComprobantesKB,
    // platos del día
    getPlatosDia: getPlatosDia,
    guardarPlatoDia: guardarPlatoDia,
    borrarPlatoDia: borrarPlatoDia,
    copiarPlatosDia: copiarPlatosDia,
    moverPlatoDia: moverPlatoDia,
    getPlatosChef: getPlatosChef,
    // menú del día · modalidad (armado / chef)
    TIPOS_MENU: TIPOS_MENU,
    getMenuDia: getMenuDia,
    tipoMenuDia: tipoMenuDia,
    getMenuPublico: getMenuPublico,
    setTipoMenuDia: setTipoMenuDia,
    guardarDatosArmado: guardarDatosArmado,
    guardarCategoriaArmado: guardarCategoriaArmado,
    borrarCategoriaArmado: borrarCategoriaArmado,
    moverCategoriaArmado: moverCategoriaArmado,
    guardarOpcionArmado: guardarOpcionArmado,
    borrarOpcionArmado: borrarOpcionArmado,
    moverOpcionArmado: moverOpcionArmado,
    copiarMenuDia: copiarMenuDia,
    getTextoMenuDia: getTextoMenuDia,
    guardarTextoMenuDia: guardarTextoMenuDia,
    // pedidos
    ESTADOS: ESTADOS,
    ETIQUETA_ESTADO: ETIQUETA_ESTADO,
    flujoEstados: flujoEstados,
    siguienteEstado: siguienteEstado,
    getPedidos: getPedidos,
    getPedido: getPedido,
    getPedidoPorCodigo: getPedidoPorCodigo,
    crearPedido: crearPedido,
    cambiarEstado: cambiarEstado,
    avanzarEstado: avanzarEstado,
    cancelarPedido: cancelarPedido,
    anularPedido: anularPedido,
    getAnulaciones: getAnulaciones,
    consumoDePedido: consumoDePedido,
    estadoAbastecimiento: estadoAbastecimiento,
    estadoDeExistencia: estadoDeExistencia,
    existenciasDeSucursal: existenciasDeSucursal,
    confirmarPago: confirmarPago,
    rechazarPago: rechazarPago,
    reportarPago: reportarPago,
    // ventas
    ventas: ventas,

    // ---- inventario y cierre de caja ----
    getProductosInventario: getProductosInventario,
    getProductoInventario: getProductoInventario,

    idCierre: idCierre,
    getCierres: getCierres,
    getCierre: getCierre,
    buscarCierre: buscarCierre,
    guardarCierre: guardarCierre,
    actualizarCierre: actualizarCierre,
    cambiarEstadoCierre: cambiarEstadoCierre,
    borrarCierre: borrarCierre,

    getEntradas: getEntradas,
    guardarEntrada: guardarEntrada,
    actualizarEntrada: actualizarEntrada,
    entradaEditable: entradaEditable,
    borrarEntrada: borrarEntrada,
    getEntradasPorProducto: getEntradasPorProducto,

    // gastos (salidas de dinero — separado de las ventas)
    ESTADOS_GASTO: ESTADOS_GASTO_IDS,
    getCategoriasGasto: getCategoriasGasto,
    categoriaGasto: categoriaGasto,
    getGastos: getGastos,
    getGasto: getGasto,
    crearGasto: crearGasto,
    actualizarGasto: actualizarGasto,
    confirmarGasto: confirmarGasto,
    anularGasto: anularGasto,
    resumenGastos: resumenGastos,

    getVentasProducto: getVentasProducto,
    getCierreAnterior: getCierreAnterior,
    getSaldoAnterior: getSaldoAnterior,
    getSaldoInicial: getSaldoInicial,
    calcularCruce: calcularCruce,

    // sesión
    login: login,
    logout: logout,
    establecerSesion: guardarSesion,
    usarClavesRemotas: usarClavesRemotas,
    cargarRemoto: cargarRemoto,
    leerRemoto: leerRemoto,
    estaAutenticado: estaAutenticado,
    getSesion: getSesion,
    // mantenimiento
    exportar: exportar,
    contarFacturasPrueba: contarFacturasPrueba,
    borrarFacturasPrueba: borrarFacturasPrueba,
    importar: importar,
    borrarTodo: borrarTodo,
    sembrar: sembrar,
    onChange: onChange,
    almacenamientoEsTemporal: almacenamientoEsTemporal,
  };
})();
