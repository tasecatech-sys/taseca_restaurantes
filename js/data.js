/* ==========================================================================
   NASCAR · data.js
   Datos ESTÁTICOS del negocio: sucursales, carta a la carta y configuración.
   Este archivo se edita a mano cuando el restaurante cambia la carta fija.
   Los platos del día NO viven aquí (son dinámicos) -> ver store.js / admin.
   ========================================================================== */

window.NASCAR = window.NASCAR || {};

/* -------------------------------------------------------------------------
   Configuración general
   ------------------------------------------------------------------------- */
NASCAR.CONFIG = {
  marca: 'NASCAR',
  eslogan: 'Cocina de alta velocidad',
  descripcion:
    'Cuatro locales en la misma zona: dos restaurantes con menú del día, el bar y la arepera.',

  // PIN del panel administrativo.
  // OJO: esto es una barrera de conveniencia, NO seguridad real (el código
  // viaja al navegador). Para seguridad de verdad hace falta un backend.
  pinAdmin: '2580',

  /* Contacto general del restaurante.
     Todo esto se edita desde Panel → ⚙️ Configuración; aquí sólo están
     los valores con los que arranca el sistema la primera vez. */
  contacto: {
    telefono: '320 212 0632',
    whatsapp: '573202120632', // sin +, con indicativo de país
    email: 'contacto@nascar.com.co',
    direccion: 'Av. Calle 80 # 102-52, Local 14, Bogotá D.C.',
    horarioGeneral: 'Lunes a Domingo · 11:00 a.m. – 10:00 p.m.',
  },

  // Datos de pago para domicilios
  pago: {
    nequi: '300 415 8890',
    daviplata: '301 227 6644',
    bancolombia: 'Ahorros 512-000998-77 · NASCAR S.A.S.',
    titular: 'NASCAR Restaurante S.A.S.',
    nit: '901.554.221-3',
  },

  /* Métodos de pago que se le ofrecen al cliente en el domicilio.
     Se activan/desactivan desde el panel (sólo el rol admin). */
  metodosPago: [
    { id: 'efectivo', nombre: 'Efectivo contra entrega', activo: true,
      descripcion: 'Le pagas al domiciliario cuando recibas.' },
    { id: 'datafono', nombre: 'Datáfono en la puerta', activo: true,
      descripcion: 'El domiciliario lleva datáfono. Tarjeta débito o crédito.' },
    { id: 'transferencia', nombre: 'Transferencia · Nequi, Daviplata o Bancolombia', activo: true,
      descripcion: 'Transfieres ahora y despachamos apenas confirmemos el pago.' },
  ],

  /* Comprobantes de pago que el cliente adjunta (MVP local).
     La imagen se reduce y se guarda como dataURL en localStorage, que es
     pequeño: por eso los límites son conservadores. */
  comprobantes: {
    ladoMaximoPx: 1000, // se redimensiona a este lado mayor
    calidadJpeg: 0.72,
    pesoMaximoKB: 600, // peso del archivo original que se acepta
    pesoGuardadoMaximoKB: 450, // si tras comprimir supera esto, se rechaza
    formatos: ['image/jpeg', 'image/jpg', 'image/png', 'image/webp'],
  },

  redes: {
    instagram: 'https://instagram.com',
    facebook: 'https://facebook.com',
  },

  // Tiempos estimados que se muestran al cliente
  tiempos: {
    mesa: '15 - 25 min',
    domicilio: '35 - 50 min',
  },

  /* --- Jornada operativa -------------------------------------------
     El restaurante cierra de madrugada. Un pedido tomado a la 1:30 a.m.
     del 29 pertenece, para efectos de inventario y cierre, al día 28.

     horaCorteOperativa = hora a la que se considera que empieza un día
     nuevo. Con 6, todo lo ocurrido entre las 00:00 y las 05:59 cuenta
     para el día anterior.

     Subir este número si el restaurante cierra más tarde. */
  horaCorteOperativa: 6,
};

/* -------------------------------------------------------------------------
   Áreas de inventario
   ------------------------------------------------------------------------- */
NASCAR.AREAS = [
  { id: 'comidas', nombre: 'Comidas', icono: '🍽️' },
  { id: 'bar', nombre: 'Bar', icono: '🍺' },
];

/* Estados por los que pasa un cierre.
   La mesera registra -> completado. La administradora revisa -> revisado.
   Un cierre revisado ya no lo puede tocar la mesera. */
NASCAR.ESTADOS_CIERRE = [
  { id: 'borrador', nombre: 'Borrador', badge: 'badge--gris' },
  { id: 'completado', nombre: 'Completado', badge: 'badge--azul' },
  { id: 'revisado', nombre: 'Revisado', badge: 'badge--verde' },
];

/* Tipos de entrada de inventario (el campo EN del cruce). */
NASCAR.TIPOS_ENTRADA = [
  { id: 'compra', nombre: 'Compra a proveedor' },
  { id: 'traslado', nombre: 'Traslado entre sucursales' },
  { id: 'devolucion', nombre: 'Devolución de cliente' },
  { id: 'ajuste', nombre: 'Ajuste de inventario' },

  /* Lo genera el sistema al anular una factura cuya jornada YA tenía
     cierre: como el histórico no se toca, la mercancía vuelve como
     movimiento de la jornada de hoy. No se registra a mano — por eso
     `automatico`, que lo saca del desplegable de Entradas. */
  { id: 'retorno_anulacion', nombre: 'Retorno por anulación de factura', automatico: true },
];

/* =========================================================================
   EMPRESAS

   El sistema se preparó para atender varias empresas con los mismos
   archivos. Cada registro (pedido, gasto, cierre…) lleva un `empresaId`,
   y las consultas de store.js filtran por la empresa activa.

   Aquí sólo está la empresa con la que arranca el sistema. Las demás se
   crean desde código o, más adelante, desde el panel de SuperAdmin.

   El id debe ser ESTABLE: no se deriva del nombre, porque el nombre
   comercial puede cambiar y los datos históricos apuntan a este id.
   ========================================================================= */
/* =========================================================================
   LOS TRES PORTALES

   El sistema se entra por tres puertas distintas, y no se cruzan:

     PORTAL CLIENTE     index.html · mesa.html
       Quien viene a pedir. Ve la carta, arma su pedido y lo manda. No
       tiene —ni debe tener— ninguna forma de llegar a los otros dos.

     PORTAL OPERATIVO   empleados.html · cierre.html
       Quien trabaja en el negocio: admin, administrador, caja, mesero,
       cocinero y domiciliario. Cada uno ve lo suyo según su rol.

     PORTAL TASECA      taseca-admin.html
       El administrador de la plataforma. Está por encima de todas las
       empresas y no se llega a él pasando por ninguna.

   Aquí viven las direcciones, en un solo sitio. Hoy son archivos porque
   el MVP es local; el día del despliegue se cambian aquí y nada más:

     PORTAL_CLIENTE   -> cliente.tienda.com
     PORTAL_OPERATIVO -> cliente.tienda.com/empleados
     PORTAL_TASECA    -> platform.taseca.tech

   Fíjate en que ninguna constante enlaza hacia arriba: desde el mapa de
   rutas no hay forma de que el portal del cliente conozca los otros.
   ========================================================================= */
NASCAR.PORTALES = {
  cliente: { inicio: 'index.html', mesa: 'mesa.html' },
  operativo: { panel: 'empleados.html', cierre: 'cierre.html' },
  plataforma: { panel: 'taseca-admin.html' },
};

NASCAR.EMPRESA_POR_DEFECTO = 'empresa_nascar';

/* Empresa "de mentiras" a la que pertenecen los usuarios de la
   PLATAFORMA (el SuperAdmin). No es un restaurante: es la marca que
   los deja fuera de todas las empresas de verdad.

   Gracias a esto el SuperAdmin no aparece en la lista de usuarios de
   NASCAR ni de ninguna otra, y el Admin de una empresa no puede verlo,
   editarlo ni desactivarlo: para él, sencillamente no está. */
NASCAR.EMPRESA_PLATAFORMA = '*plataforma*';

NASCAR.EMPRESAS = [
  {
    id: 'empresa_nascar',
    nombre: 'NASCAR', // nombre comercial
    razonSocial: 'NASCAR Restaurante S.A.S.',
    nit: '901.554.221-3',
    telefono: '(601) 742 1180',
    whatsapp: '573001112233',
    email: 'contacto@nascar.com.co',
    activa: true,
    creada: '2026-01-01T00:00:00.000Z',

    /* Qué módulos contrató esta empresa. Ver NASCAR.MODULOS abajo.
       NASCAR es la instalación original: tiene el paquete completo. */
    modulos: { basico: true, stock: true, cierre: true },

    /* Su identidad visual. Son EXACTAMENTE los colores y la tipografía
       con los que NASCAR ha funcionado siempre, sólo que ahora escritos
       como dato en vez de estar clavados en el CSS. Al aplicarse, la
       página queda igual que antes — ver js/tema.js.

       `theme` y `modulos` son cosas distintas y no se mezclan: uno es
       cómo se ve la empresa, el otro qué partes del sistema contrató. */
    theme: {
      logo: '', // sin imagen: se usa el logotipo de texto
      favicon: '',
      logoTexto: 'NAS', // NAS + CAR, con CAR en el color de acento
      logoAcento: 'CAR',
      primary: '#0b5fff', // el azul de siempre
      secondary: '#e4002b', // el rojo de siempre
      accent: '#4d8cff',
      background: '#06080c',
      fontFamily: 'barlow',
      iniciales: 'NA',
      lema: 'Parrilla, tradicional y domicilios',
    },
  },
];

/* =========================================================================
   MÓDULOS DE LA PLATAFORMA

   El sistema se vende por partes. Cada empresa contrata uno, dos o los
   tres módulos, y lo que no contrató simplemente no existe para ella:
   ni pestaña, ni botón, ni acceso por URL, ni acción ejecutable.

   Quién decide qué módulos tiene una empresa: el SuperAdmin (fase
   siguiente). El Admin de la empresa NO puede tocarlos — por eso
   store.guardarEmpresa() ignora el campo `modulos` y sólo lo escribe
   store.setModulos(), que exige la marca de superadmin.
   ========================================================================= */
NASCAR.MODULOS = [
  {
    id: 'basico',
    nombre: 'Básico',
    icono: '🧾',
    /* Siempre encendido: es el sistema mismo. Sin él no queda nada que
       mostrar, así que no se puede apagar. */
    obligatorio: true,
    requiere: [],
    descripcion: 'La operación del restaurante de punta a punta.',
    incluye: [
      'Configuración', 'Sucursales', 'Carta', 'Categorías', 'Menú del día',
      'Pedidos', 'Mesas', 'Cocina', 'Domicilios', 'Pagos', 'Comprobantes',
      'Ventas', 'Usuarios y roles', 'Gastos',
    ],
  },
  {
    id: 'stock',
    nombre: 'Stock',
    icono: '📦',
    obligatorio: false,
    requiere: ['basico'],
    descripcion: 'Catálogo de inventario y entradas de mercancía.',
    incluye: [
      'Stock', 'Productos de inventario', 'Unidades', 'Stock actual',
      'Stock mínimo', 'Entradas', 'Movimientos de inventario',
    ],
  },
  {
    id: 'cierre',
    nombre: 'Cierre',
    icono: '🔄',
    obligatorio: false,
    /* Depende de Básico, no de Stock: el cruce necesita las VENTAS.
       De Stock se aprovecha el saldo inicial y el catálogo de productos
       cuando está disponible; si no lo está, el cierre sigue
       funcionando con lo que haya en cierres anteriores. */
    requiere: ['basico'],
    descripcion: 'Cierre de inventario diario y cruce contra las ventas.',
    incluye: [
      'Cierres', 'Inventario físico', 'Saldo inicial', 'Entradas', 'Ventas',
      'Saldo calculado', 'Diferencias', 'Histórico', 'Auditoría',
    ],
  },
];

/* Con qué módulos arranca una empresa nueva: sólo lo básico. Lo demás
   se contrata. */
NASCAR.MODULOS_POR_DEFECTO = { basico: true, stock: false, cierre: false };

/* =========================================================================
   TEMAS DE EMPRESA

   `theme` es CÓMO SE VE una empresa. `modulos` es QUÉ CONTRATÓ. Son dos
   cosas distintas y se guardan aparte:

     empresa = {
       id, nombre,
       modulos: { basico, stock, cierre },
       theme:   { logo, favicon, primary, secondary, accent, background,
                  fontFamily, … }
     }

   Ojo con no confundirlo tampoco con el tema del PANEL TASECA, que vive
   en css/taseca.css con variables --platform-*. Aquél es de la
   plataforma y ninguna empresa lo toca; éste es del cliente.
   ========================================================================= */

/* Tipografías que se pueden elegir. Es una lista CERRADA a propósito: la
   personalización tiene que ser controlada, así que no se admite CSS ni
   fuentes arbitrarias. Cada entrada dice qué familia usar y, si hace
   falta, de dónde cargarla. */
NASCAR.TIPOGRAFIAS = [
  {
    id: 'barlow',
    nombre: 'Barlow',
    muestra: 'Deportiva y compacta',
    familia: "'Barlow', system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif",
    google: 'Barlow:wght@400;500;600',
  },
  {
    id: 'inter',
    nombre: 'Inter',
    muestra: 'Neutra y muy legible',
    familia: "'Inter', system-ui, -apple-system, 'Segoe UI', sans-serif",
    google: 'Inter:wght@400;500;600;700',
  },
  {
    id: 'poppins',
    nombre: 'Poppins',
    muestra: 'Redonda y amable',
    familia: "'Poppins', system-ui, 'Segoe UI', sans-serif",
    google: 'Poppins:wght@400;500;600;700',
  },
  {
    id: 'lora',
    nombre: 'Lora',
    muestra: 'Con serifa, más clásica',
    familia: "'Lora', Georgia, 'Times New Roman', serif",
    google: 'Lora:wght@400;500;600',
  },
  {
    id: 'sistema',
    nombre: 'Del sistema',
    muestra: 'La del dispositivo, sin descargar nada',
    familia: "system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif",
    google: '',
  },
];

/* El tema con el que Taseca entrega una empresa nueva. Sobrio y neutro:
   es un punto de partida, no la identidad definitiva del cliente. Desde
   el panel se personaliza después. */
NASCAR.TEMA_BASE = {
  logo: '',
  favicon: '',
  logoTexto: '',
  logoAcento: '',
  primary: '#2563eb',
  secondary: '#64748b',
  accent: '#38bdf8',
  background: '#0b0f16',
  fontFamily: 'inter',
  iniciales: '',
  lema: '',
};

/* -------------------------------------------------------------------------
   PLANTILLAS DE ALTA

   Sólo son un punto de partida: tema + módulos iniciales. NO traen
   funcionalidad propia de cada sector — no hay lógica de bar ni de
   comercio en ninguna parte. Si mañana la hubiera, se colgaría de aquí.
   ------------------------------------------------------------------------- */
NASCAR.PLANTILLAS_EMPRESA = [
  {
    id: 'restaurante',
    nombre: 'Restaurante',
    icono: '🍽️',
    descripcion: 'Carta, mesas y domicilios, con inventario y cierre diario.',
    modulos: { basico: true, stock: true, cierre: true },
    theme: { primary: '#c0392b', secondary: '#e67e22', accent: '#f1c40f', fontFamily: 'poppins' },
  },
  {
    id: 'bar',
    nombre: 'Bar',
    icono: '🍺',
    descripcion: 'Barra y mesas, con control de existencias y cierre de caja.',
    modulos: { basico: true, stock: true, cierre: true },
    theme: { primary: '#6d28d9', secondary: '#a855f7', accent: '#22d3ee', fontFamily: 'inter' },
  },
  {
    id: 'cafeteria',
    nombre: 'Cafetería',
    icono: '☕',
    descripcion: 'Rotación rápida y carta corta, con inventario.',
    modulos: { basico: true, stock: true, cierre: false },
    theme: { primary: '#92400e', secondary: '#b45309', accent: '#f59e0b', fontFamily: 'lora' },
  },
  {
    id: 'comercio',
    nombre: 'Comercio',
    icono: '🛍️',
    descripcion: 'Venta de producto con existencias, sin cierre de cocina.',
    modulos: { basico: true, stock: true, cierre: false },
    theme: { primary: '#0f766e', secondary: '#14b8a6', accent: '#5eead4', fontFamily: 'inter' },
  },
  {
    id: 'servicios',
    nombre: 'Servicios',
    icono: '🧰',
    descripcion: 'Sin inventario: sólo la operación, los pagos y los gastos.',
    modulos: { basico: true, stock: false, cierre: false },
    theme: { primary: '#1d4ed8', secondary: '#475569', accent: '#60a5fa', fontFamily: 'inter' },
  },
  {
    id: 'personalizado',
    nombre: 'Personalizado',
    icono: '🎛️',
    descripcion: 'Empieza con el tema base de Taseca y configúralo a mano.',
    modulos: null, // null = los de por defecto
    theme: null, // null = el tema base
  },
];

/* Qué módulo necesita cada pestaña del panel. Lo usa auth.js junto con
   los permisos: una pestaña se ve si el rol la permite Y el módulo está
   habilitado para la empresa.

   Un arreglo significa "cualquiera de estos": Entradas alimenta tanto el
   stock como la columna EN del cruce, así que basta con tener uno de los
   dos módulos para que tenga sentido registrarlas. */
NASCAR.MODULO_DE_TAB = {
  pedidos: 'basico',
  pagos: 'basico',
  dia: 'basico',
  carta: 'basico',
  ventas: 'basico',
  mesero: 'basico',
  cocina: 'basico',
  entregas: 'basico',
  gastos: 'basico',
  informe: 'basico',
  usuarios: 'basico',
  config: 'basico',
  ajustes: 'basico',
  stock: 'stock',
  entradas: ['stock', 'cierre'],
  cierre: 'cierre',
  inventario: 'cierre',
};

/* -------------------------------------------------------------------------
   GASTOS · categorías

   Ojo: "Compra a proveedor" también aparece en NASCAR.TIPOS_ENTRADA, pero
   son cosas distintas y ninguna sustituye a la otra:
     · TIPOS_ENTRADA  = movimiento de INVENTARIO (entra mercancía)
     · CATEGORIAS_GASTO = salida de DINERO
   Una compra suele generar las dos, pero se registran por separado.

   Los métodos de pago NO se definen aquí: se reutilizan los de
   NASCAR.CONFIG.metodosPago, que ya administra el panel.
   ------------------------------------------------------------------------- */
NASCAR.CATEGORIAS_GASTO = [
  { id: 'proveedor', nombre: 'Compra a proveedor', icono: '🚚', activa: true },
  { id: 'nomina', nombre: 'Nómina', icono: '👥', activa: true },
  { id: 'vale', nombre: 'Vale', icono: '🧾', activa: true },
  { id: 'servicios', nombre: 'Servicios', icono: '💡', activa: true },
  { id: 'operacion', nombre: 'Operación', icono: '🔧', activa: true },
  { id: 'otros', nombre: 'Otros', icono: '📌', activa: true },
];

/* Estados por los que pasa un gasto.
   Un gasto anulado NO se borra: queda con su motivo y quién lo anuló. */
NASCAR.ESTADOS_GASTO = [
  { id: 'registrado', nombre: 'Registrado', badge: 'badge--ambar' },
  { id: 'confirmado', nombre: 'Confirmado', badge: 'badge--verde' },
  { id: 'anulado', nombre: 'Anulado', badge: 'badge--rojo' },
];

/* =========================================================================
   CRUCE DE INFORMACIÓN · agrupación de los métodos de pago

   El cruce de caja necesita saber qué entra al cajón y qué no. Un pago en
   efectivo cambia el dinero físico; una transferencia y un datáfono, no.

   La agrupación se declara aquí en vez de adivinarse por el nombre del
   método, que el administrador puede cambiar cuando quiera. Lo que no
   esté en esta lista cuenta como "otros": ni efectivo ni transferencia,
   así que no altera el arqueo. Es la opción prudente — un método nuevo
   nunca se suma al efectivo por accidente.

   NO es un catálogo paralelo: los métodos siguen siendo los de
   NASCAR.CONFIG.metodosPago. Esto sólo dice a qué columna va cada uno.
   ========================================================================= */
NASCAR.GRUPO_DE_METODO = {
  efectivo: 'efectivo',
  transferencia: 'transferencia',
  // datafono -> otros (es dinero electrónico, pero no llega por transferencia)
};

NASCAR.GRUPOS_PAGO = [
  { id: 'efectivo', nombre: 'Efectivo', icono: '💵' },
  { id: 'transferencia', nombre: 'Transferencia', icono: '🏦' },
  { id: 'otros', nombre: 'Otros', icono: '💳' },
];

/* -------------------------------------------------------------------------
   Base de caja · estados

   La base no se edita: si estaba mal, se registra una corrección y la
   anterior queda marcada. Así el histórico nunca miente sobre lo que se
   dijo en su momento.
   ------------------------------------------------------------------------- */
NASCAR.ESTADOS_BASE = [
  { id: 'activa', nombre: 'Activa', badge: 'badge--verde' },
  { id: 'corregida', nombre: 'Corregida', badge: 'badge--linea' },
];

/* -------------------------------------------------------------------------
   Usuarios con los que arranca el sistema.

   ⚠️  MVP LOCAL — esto NO es autenticación real. El PIN viaja al navegador
   y cualquiera que sepa mirar el código lo encuentra. Sirve para separar
   perfiles y poder demostrar el sistema, no para proteger información.
   La estructura ya está lista para conectar un login real: cada usuario
   tiene id, usuario, rol y sucursal.
   ------------------------------------------------------------------------- */
NASCAR.USUARIOS_INICIALES = [
  { id: 'u-admin', nombre: 'Dueño', usuario: 'admin', pin: '2580', rol: 'admin', sucursalId: null, activo: true },
  { id: 'u-gerente', nombre: 'Administradora', usuario: 'gerencia', pin: '1234', rol: 'administrador', sucursalId: null, activo: true },
  { id: 'u-mesero', nombre: 'Mesero Norte', usuario: 'mesero', pin: '1111', rol: 'mesero', sucursalId: 1, activo: true },
  { id: 'u-cocina', nombre: 'Cocina Norte', usuario: 'cocina', pin: '2222', rol: 'cocinero', sucursalId: 1, activo: true },
  { id: 'u-domi', nombre: 'Domiciliario', usuario: 'domicilios', pin: '3333', rol: 'domiciliario', sucursalId: null, activo: true },
  { id: 'u-caja', nombre: 'Caja Norte', usuario: 'caja', pin: '4444', rol: 'caja', sucursalId: 1, activo: true },
];

/* -------------------------------------------------------------------------
   Usuarios de la PLATAFORMA (Taseca)

   Taseca es la empresa dueña de la plataforma; NASCAR es uno de sus
   clientes. El SuperAdmin administra la plataforma, no un restaurante:
   no pertenece a ninguna empresa y se marca con `scope: 'platform'`.

   Vive en la misma lista que los demás usuarios —no hay un almacén
   paralelo— pero getUsuarios() excluye siempre a los de plataforma, así
   que no aparece dentro de NASCAR ni de ninguna otra empresa.

   ⚠️  MVP LOCAL: igual que el resto de PIN, este viaja al navegador
   dentro del código. Cámbialo antes de enseñarle esto a nadie.
   ------------------------------------------------------------------------- */
NASCAR.USUARIOS_PLATAFORMA = [
  {
    id: 'u-super',
    nombre: 'Plataforma',
    usuario: 'super',
    pin: '9000',
    rol: 'superadmin',

    /* NIVEL 1 · PLATAFORMA. No pertenece a ninguna empresa cliente:
       por eso `empresaId` es null y la pertenencia se marca con
       `scope`. Ninguna consulta por empresa lo devuelve. */
    scope: 'platform',
    empresaId: null,

    sucursalId: null,
    activo: true,
  },
];

/* -------------------------------------------------------------------------
   Sucursales
   ------------------------------------------------------------------------- */
/* -------------------------------------------------------------------------
   Tipos de negocio de una UNIDAD / LOCAL

   Es un ATRIBUTO de la unidad, no un módulo: no enciende ni apaga
   funciones. Una arepera usa la misma carta, pedidos, stock y cierre que
   un restaurante; qué funciones tiene lo decide el plan de la EMPRESA.
   Sirve para identificar la operación y para adaptar la experiencia más
   adelante.
   ------------------------------------------------------------------------- */
NASCAR.TIPOS_NEGOCIO = [
  { id: 'restaurante', nombre: 'Restaurante', icono: '🍽️' },
  { id: 'bar', nombre: 'Bar', icono: '🍺' },
  { id: 'arepera', nombre: 'Arepera / Comidas', icono: '🫓' },
  { id: 'cafeteria', nombre: 'Cafetería', icono: '☕' },
  { id: 'fruteria', nombre: 'Frutería', icono: '🍓' },
  { id: 'comidas_rapidas', nombre: 'Comidas rápidas', icono: '🍔' },
  { id: 'heladeria', nombre: 'Heladería', icono: '🍦' },
  { id: 'otro', nombre: 'Otro', icono: '🏪' },
];
NASCAR.TIPO_NEGOCIO_DEFECTO = 'restaurante';

/* -------------------------------------------------------------------------
   Sucursales = UNIDADES / LOCALES de la empresa
   (el nombre técnico sigue siendo "sucursal" para no reescribir los
   registros históricos, que apuntan a ellas con `sucursalId`)
   ------------------------------------------------------------------------- */
/* Sucursales de la demostración con la que arrancó el sistema. Si un
   navegador todavía las tiene guardadas, la migración 10 las DESACTIVA
   (no las borra: conservan sus pedidos y cierres de prueba). */
NASCAR.UNIDADES_RETIRADAS = ['NASCAR Circuito Norte', 'NASCAR Box Sur'];

NASCAR.SUCURSALES = [
  {
    id: 1,
    nombre: 'NASCAR-Comidas',
    corto: 'Comidas',
    direccion: 'Av. Calle 80 # 102-52, Local 14',
    ciudad: 'Bogotá D.C.',
    telefono: '320 212 0632',
    whatsapp: '573202120632',
    horario: 'Lunes a Domingo · 11:00 a.m. – 10:00 p.m.',
    mapa: 'https://maps.app.goo.gl/p4XjmGHuxHqEPfzo8',
    mesas: 12,
    tipoNegocio: 'restaurante',
    color: 'rojo',
    zonas: [],
  },
  {
    id: 2,
    nombre: 'Chicharrón Mental',
    corto: 'Chicharrón',
    direccion: 'Av. Calle 80 # 102-52, Local 14',
    ciudad: 'Bogotá D.C.',
    telefono: '320 212 0632',
    whatsapp: '573202120632',
    horario: 'Lunes a Domingo · 11:00 a.m. – 10:00 p.m.',
    mapa: 'https://maps.app.goo.gl/p4XjmGHuxHqEPfzo8',
    mesas: 10,
    tipoNegocio: 'restaurante',
    color: 'ambar',
    zonas: [],
  },
  {
    id: 3,
    nombre: 'NASCAR Bar VIP',
    corto: 'Bar VIP',
    direccion: 'Av. Calle 80 # 102-52, Local 14',
    ciudad: 'Bogotá D.C.',
    telefono: '320 212 0632',
    whatsapp: '573202120632',
    horario: 'Jueves a Domingo · 6:00 p.m. – 2:00 a.m.',
    mapa: 'https://maps.app.goo.gl/p4XjmGHuxHqEPfzo8',
    mesas: 14,
    tipoNegocio: 'bar',
    color: 'azul',
    zonas: [],
  },
  {
    id: 4,
    nombre: "COMIC'ENDO AREPA",
    corto: "COMIC'ENDO",
    direccion: 'Av. Calle 80 # 102-52, Local 14',
    ciudad: 'Bogotá D.C.',
    telefono: '320 212 0632',
    whatsapp: '573202120632',
    horario: 'Lunes a Domingo · 4:00 p.m. – 11:00 p.m.',
    mapa: 'https://maps.app.goo.gl/p4XjmGHuxHqEPfzo8',
    mesas: 8,
    tipoNegocio: 'arepera',
    color: 'verde',
    zonas: [],
  },
];

/* -------------------------------------------------------------------------
   Categorías de la carta (define el orden de aparición)
   ------------------------------------------------------------------------- */
NASCAR.CATEGORIAS = [
  // ---- COMIC'ENDO AREPA (unidad 4)
  { id: 'ce-tradicionales', nombre: 'Arepas tradicionales', icono: '🫓', sucursales: [4] },
  { id: 'ce-especiales', nombre: 'Arepas especiales', icono: '⭐', sucursales: [4] },
  { id: 'ce-mazorcadas', nombre: 'Mazorcada y pataconazo', icono: '🌽', sucursales: [4] },
  { id: 'ce-hamburguesas', nombre: 'Hamburguesas', icono: '🍔', sucursales: [4] },
  { id: 'ce-perros', nombre: 'Perros', icono: '🌭', sucursales: [4] },
  { id: 'ce-salchipapas', nombre: 'Salchipapas', icono: '🍟', sucursales: [4] },
  { id: 'ce-platos', nombre: 'Platos a la carta', icono: '🍽️', sucursales: [4] },
  { id: 'ce-porciones', nombre: 'Porciones y adiciones', icono: '➕', sucursales: [4] },
  { id: 'ce-bebidas', nombre: 'Bebidas', icono: '🥤', sucursales: [4] },

  // ---- NASCAR Bar VIP (unidad 3)
  { id: 'bar-cervezas', nombre: 'Cervezas', icono: '🍺', sucursales: [3] },
  { id: 'bar-licores', nombre: 'Licores', icono: '🥃', sucursales: [3] },
  { id: 'bar-snacks', nombre: 'Snacks y dulces', icono: '🍿', sucursales: [3] },
  { id: 'bar-varios', nombre: 'Cigarrillos y varios', icono: '🚬', sucursales: [3] },
  { id: 'bar-sinalcohol', nombre: 'Sin alcohol', icono: '🥤', sucursales: [3] },
];

/* -------------------------------------------------------------------------
   CARTA (estática)
   precio en pesos colombianos, sin separadores.
   tag opcional: 'popular' | 'nuevo' | 'picante' | 'compartir'
   ------------------------------------------------------------------------- */
NASCAR.CARTA = [
  /* ---------- COMIC'ENDO AREPA (unidad 4) ---------- */

  { id: 'ce01', cat: 'ce-tradicionales', nombre: "Chorizo queso", desc: "", precio: 9000, sucursales: [4] },
  { id: 'ce02', cat: 'ce-tradicionales', nombre: "Jamón queso", desc: "", precio: 9000, sucursales: [4] },
  { id: 'ce03', cat: 'ce-tradicionales', nombre: "Huevos al gusto", desc: "", precio: 10000, sucursales: [4] },
  { id: 'ce04', cat: 'ce-tradicionales', nombre: "Hawallana", desc: "", precio: 10000, sucursales: [4] },
  { id: 'ce05', cat: 'ce-tradicionales', nombre: "Carne o pollo · Mixta", desc: "", precio: 14000, tag: 'popular', sucursales: [4] },
  { id: 'ce06', cat: 'ce-tradicionales', nombre: "Vegetariana", desc: "", precio: 12000, sucursales: [4] },

  { id: 'ce07', cat: 'ce-especiales', nombre: "Arepa Norteña", desc: "Maíz tierno · Chorizo · Champiñones · Queso · Carne desmechada · Huevo de codorniz", precio: 17000, sucursales: [4] },
  { id: 'ce08', cat: 'ce-especiales', nombre: "Arepa Avengers", desc: "Chicharrón · Tocineta · Chorizo · Champiñones · Queso · Carne · Pollo · Jamón · Huevo de codorniz", precio: 17000, tag: 'popular', sucursales: [4] },
  { id: 'ce09', cat: 'ce-especiales', nombre: "Arepa Paisa", desc: "Frijol · Chicharrón · Plátano · Chorizo · Carne desmechada · Aguacate · Huevo de codorniz", precio: 17000, sucursales: [4] },
  { id: 'ce10', cat: 'ce-especiales', nombre: "Arepa Ranchera", desc: "Tocineta · Salchicha · Chorizo · Carne desmechada · Champiñones · Queso · Huevo de codorniz", precio: 17000, sucursales: [4] },
  { id: 'ce11', cat: 'ce-especiales', nombre: "Arepa Criolla", desc: "Carne desmechada · Maíz tierno · Plátano · Hogado · Chicharrón · Queso · Huevo de codorniz", precio: 17000, sucursales: [4] },
  { id: 'ce12', cat: 'ce-especiales', nombre: "Arepa Mexicana", desc: "Frijol · Carne desmechada · Pico de gallo · Nachos · Queso · Aguacate · Huevo de codorniz", precio: 17000, sucursales: [4] },

  { id: 'ce13', cat: 'ce-mazorcadas', nombre: "Mazorcada", desc: "Maíz tierno · Chorizo · Salchicha · Pollo y carne desmechada · Queso · Papá chip · Huevo de codorniz", precio: 18000, sucursales: [4] },
  { id: 'ce14', cat: 'ce-mazorcadas', nombre: "Pataconazo", desc: "Maíz tierno · Chorizo · Salchicha · Pollo · Carne desmechada · Queso · Hogado · Huevo de codorniz", precio: 18000, sucursales: [4] },

  { id: 'ce15', cat: 'ce-hamburguesas', nombre: "Hamburguesa 100% res", desc: "Lechuga · Cebolla · Tomate · Queso · Papá chip · Salsas · Huevo de codorniz", precio: 13000, sucursales: [4] },
  { id: 'ce16', cat: 'ce-hamburguesas', nombre: "Hamburguesa de pollo apanada", desc: "Lechuga · Cebolla · Tomate · Queso · Papá chip · Salsas · Huevo de codorniz", precio: 14000, sucursales: [4] },
  { id: 'ce17', cat: 'ce-hamburguesas', nombre: "Hamburguesa doble carne", desc: "Lechuga · Cebolla · Tomate · Queso · Papá chip · Salsas · Huevo de codorniz", precio: 18000, tag: 'popular', sucursales: [4] },
  { id: 'ce18', cat: 'ce-hamburguesas', nombre: "Hamburguesa mixta", desc: "Lechuga · Cebolla · Tomate · Queso · Papá chip · Salsas · Huevo de codorniz", precio: 20000, sucursales: [4] },
  { id: 'ce19', cat: 'ce-hamburguesas', nombre: "Hamburguesa especial Mexicana", desc: "Frijol · Carne desmechada · Pico de gallo · Nachos · Queso · Aguacate · Huevo de codorniz. Pídela de res o de pollo apanado.", precio: 25000, sucursales: [4] },
  { id: 'ce20', cat: 'ce-hamburguesas', nombre: "Hamburguesa especial Norteña", desc: "Maíz tierno · Chorizo · Champiñones · Queso · Carne desmechada · Huevo de codorniz. Pídela de res o de pollo apanado.", precio: 25000, sucursales: [4] },
  { id: 'ce21', cat: 'ce-hamburguesas', nombre: "Hamburguesa especial Paisa", desc: "Frijol · Chicharrón · Plátano · Chorizo · Carne · Aguacate · Huevo frito. Pídela de res o de pollo apanado.", precio: 25000, sucursales: [4] },
  { id: 'ce22', cat: 'ce-hamburguesas', nombre: "Hamburguesa especial Comic'", desc: "Chicharrón · Tocineta · Chorizo · Champiñones · Carne y pollo desmechado · Jamón · Queso · Huevo frito. Pídela de res o de pollo apanado.", precio: 25000, sucursales: [4] },
  { id: 'ce23', cat: 'ce-hamburguesas', nombre: "Hamburguesa especial Ranchera", desc: "Tocineta · Salchicha · Chorizo · Carne desmechada · Champiñones · Queso · Huevo de codorniz. Pídela de res o de pollo apanado.", precio: 25000, sucursales: [4] },
  { id: 'ce24', cat: 'ce-hamburguesas', nombre: "Hamburguesa especial Criolla", desc: "Carne desmechada · Maíz tierno · Plátano · Hogado · Chicharrón · Queso · Huevo frito. Pídela de res o de pollo apanado.", precio: 25000, sucursales: [4] },

  { id: 'ce25', cat: 'ce-perros', nombre: "Perro sencillo", desc: "Salchicha americana · Jamón · Queso · Cebolla · Papá chip · Salsas · Huevo de codorniz", precio: 14000, sucursales: [4] },
  { id: 'ce26', cat: 'ce-perros', nombre: "Perro especial", desc: "Pollo y carne · Salchicha americana · Jamón · Queso · Cebolla · Papá chip · Salsas · Huevo de codorniz", precio: 18000, sucursales: [4] },
  { id: 'ce27', cat: 'ce-perros', nombre: "Perro de la casa", desc: "Salchicha americana · Chicharrón · Tocineta · Chorizo · Champiñones · Carne y pollo desmechado · Jamón · Queso · Huevo frito", precio: 22000, tag: 'popular', sucursales: [4] },

  { id: 'ce28', cat: 'ce-salchipapas', nombre: "Salchipapa Comic'", desc: "Salchicha · Chicharrón · Tocineta · Chorizo · Champiñones · Carne y pollo desmechado · Huevo de codorniz", precio: 22000, tag: 'popular', sucursales: [4] },
  { id: 'ce29', cat: 'ce-salchipapas', nombre: "Salchipapa Ranchera", desc: "Tocineta · Salchicha · Chorizo · Carne desmechada · Champiñones · Huevo de codorniz", precio: 22000, sucursales: [4] },
  { id: 'ce30', cat: 'ce-salchipapas', nombre: "Salchipapa Norteña", desc: "Salchicha · Maíz tierno · Chorizo · Champiñones · Carne desmechada · Huevo de codorniz", precio: 22000, sucursales: [4] },
  { id: 'ce31', cat: 'ce-salchipapas', nombre: "Salchipapa Criolla", desc: "Carne desmechada · Maíz tierno · Plátano · Chicharrón · Queso · Huevo de codorniz", precio: 22000, sucursales: [4] },

  { id: 'ce32', cat: 'ce-platos', nombre: "Bandeja de carne asada", desc: "Arroz · Papá francesa · Aguacate · Gaseosa o limonada natural", precio: 18000, sucursales: [4] },
  { id: 'ce33', cat: 'ce-platos', nombre: "Bandeja de lomo de cerdo", desc: "Arroz · Papá francesa · Aguacate · Gaseosa o limonada natural", precio: 18000, sucursales: [4] },
  { id: 'ce34', cat: 'ce-platos', nombre: "Bandeja de pechuga", desc: "Arroz · Papá francesa · Aguacate · Gaseosa o limonada natural", precio: 18000, sucursales: [4] },
  { id: 'ce35', cat: 'ce-platos', nombre: "Encebollado de carne asada", desc: "Arroz · Papá francesa · Gaseosa o limonada natural", precio: 29000, sucursales: [4] },
  { id: 'ce36', cat: 'ce-platos', nombre: "Encebollado de lomo de cerdo", desc: "Arroz · Papá francesa · Gaseosa o limonada natural", precio: 29000, sucursales: [4] },
  { id: 'ce37', cat: 'ce-platos', nombre: "Encebollado de pechuga", desc: "Arroz · Papá francesa · Gaseosa o limonada natural", precio: 29000, sucursales: [4] },
  { id: 'ce38', cat: 'ce-platos', nombre: "Churrasco a lo grande", desc: "Arroz · Papá francesa · Plátano · Gaseosa o limonada natural", precio: 29000, sucursales: [4] },
  { id: 'ce39', cat: 'ce-platos', nombre: "Churrasco ranchero", desc: "Arroz · Papá francesa · Plátano · Gaseosa o limonada natural", precio: 29000, sucursales: [4] },
  { id: 'ce40', cat: 'ce-platos', nombre: "Costillas BBQ", desc: "Arroz · Papá francesa · Plátano · Gaseosa o limonada natural", precio: 29000, sucursales: [4] },
  { id: 'ce41', cat: 'ce-platos', nombre: "Trimixta", desc: "Arroz · Papá francesa · Plátano · Gaseosa o limonada natural", precio: 29000, sucursales: [4] },
  { id: 'ce42', cat: 'ce-platos', nombre: "Picada", desc: "Carne · Pechuga · Lomo · Chorizo · Francesa · Plátano · Arepa", precio: 42000, tag: 'compartir', sucursales: [4] },

  { id: 'ce43', cat: 'ce-porciones', nombre: "Papá francesa", desc: "", precio: 8000, sucursales: [4] },
  { id: 'ce44', cat: 'ce-porciones', nombre: "Huevos de codorniz", desc: "", precio: 5000, sucursales: [4] },
  { id: 'ce45', cat: 'ce-porciones', nombre: "Adición de su preferencia", desc: "", precio: 4000, sucursales: [4] },

  { id: 'ce46', cat: 'ce-bebidas', nombre: "Limonada natural", desc: "", precio: 6000, sucursales: [4] },
  { id: 'ce47', cat: 'ce-bebidas', nombre: "Limonada de coco", desc: "", precio: 8000, sucursales: [4] },
  { id: 'ce48', cat: 'ce-bebidas', nombre: "Limonada cerezada", desc: "", precio: 8000, sucursales: [4] },
  { id: 'ce49', cat: 'ce-bebidas', nombre: "Jugo en agua", desc: "", precio: 7000, sucursales: [4] },
  { id: 'ce50', cat: 'ce-bebidas', nombre: "Jugo en leche", desc: "", precio: 9000, sucursales: [4] },
  { id: 'ce51', cat: 'ce-bebidas', nombre: "Gaseosa personal", desc: "", precio: 4500, sucursales: [4] },
  { id: 'ce52', cat: 'ce-bebidas', nombre: "Gaseosa 250", desc: "", precio: 3000, sucursales: [4] },
  { id: 'ce53', cat: 'ce-bebidas', nombre: "Gaseosa 1.5", desc: "", precio: 8000, sucursales: [4] },
  { id: 'ce54', cat: 'ce-bebidas', nombre: "Agua botella", desc: "", precio: 4000, sucursales: [4] },
  { id: 'ce55', cat: 'ce-bebidas', nombre: "Gatorade", desc: "", precio: 5000, sucursales: [4] },
  { id: 'ce56', cat: 'ce-bebidas', nombre: "Vive Cien", desc: "", precio: 4000, sucursales: [4] },
  { id: 'ce57', cat: 'ce-bebidas', nombre: "Jugo Hit", desc: "", precio: 4000, sucursales: [4] },
  { id: 'ce58', cat: 'ce-bebidas', nombre: "Bretaña", desc: "", precio: 4000, sucursales: [4] },

  /* ---------- NASCAR Bar VIP (unidad 3) ----------
     Los nombres salen de la planilla de inventario del bar. El PRECIO
     está en 0 a propósito: lo pone el administrador desde Panel → Carta.
     Un producto en 0 se vende como gratis, así que revísalos antes de
     abrir la venta del bar. ---------------------------------------- */

  { id: 'br01', cat: 'bar-cervezas', nombre: "Cerveza", desc: '', precio: 0, sucursales: [3] },
  { id: 'br02', cat: 'bar-cervezas', nombre: "Águila Light", desc: '', precio: 0, sucursales: [3] },
  { id: 'br03', cat: 'bar-cervezas', nombre: "Club Colombia", desc: '', precio: 0, sucursales: [3] },
  { id: 'br04', cat: 'bar-cervezas', nombre: "Corona", desc: '', precio: 0, sucursales: [3] },
  { id: 'br05', cat: 'bar-cervezas', nombre: "Coronita", desc: '', precio: 0, sucursales: [3] },

  { id: 'br06', cat: 'bar-licores', nombre: "Smirnoff", desc: '', precio: 0, sucursales: [3] },
  { id: 'br07', cat: 'bar-licores', nombre: "Media de verde", desc: '', precio: 0, sucursales: [3] },
  { id: 'br08', cat: 'bar-licores', nombre: "Caja verde", desc: '', precio: 0, sucursales: [3] },
  { id: 'br09', cat: 'bar-licores', nombre: "Media de Antioqueño", desc: '', precio: 0, sucursales: [3] },
  { id: 'br10', cat: 'bar-licores', nombre: "Botella de Antioqueño", desc: '', precio: 0, sucursales: [3] },
  { id: 'br11', cat: 'bar-licores', nombre: "Botella de whisky", desc: '', precio: 0, sucursales: [3] },
  { id: 'br12', cat: 'bar-licores', nombre: "Botella de ron", desc: '', precio: 0, sucursales: [3] },
  { id: 'br13', cat: 'bar-licores', nombre: "Media de ron", desc: '', precio: 0, sucursales: [3] },
  { id: 'br14', cat: 'bar-licores', nombre: "Old Parr", desc: '', precio: 0, sucursales: [3] },
  { id: 'br15', cat: 'bar-licores', nombre: "Botella de tequila", desc: '', precio: 0, sucursales: [3] },
  { id: 'br16', cat: 'bar-licores', nombre: "Media de tequila", desc: '', precio: 0, sucursales: [3] },
  { id: 'br17', cat: 'bar-licores', nombre: "Media de amarillo", desc: '', precio: 0, sucursales: [3] },
  { id: 'br18', cat: 'bar-licores', nombre: "Amarillo y rosado", desc: '', precio: 0, sucursales: [3] },

  { id: 'br19', cat: 'bar-varios', nombre: "Cigarrillos", desc: '', precio: 0, sucursales: [3] },
  { id: 'br20', cat: 'bar-varios', nombre: "Encendedores", desc: '', precio: 0, sucursales: [3] },

  { id: 'br21', cat: 'bar-snacks', nombre: "Traiden grande", desc: '', precio: 0, sucursales: [3] },
  { id: 'br22', cat: 'bar-snacks', nombre: "Traiden mediano", desc: '', precio: 0, sucursales: [3] },
  { id: 'br23', cat: 'bar-snacks', nombre: "Traiden personal", desc: '', precio: 0, sucursales: [3] },
  { id: 'br24', cat: 'bar-snacks', nombre: "Papas grandes", desc: '', precio: 0, sucursales: [3] },
  { id: 'br25', cat: 'bar-snacks', nombre: "Papas pequeñas", desc: '', precio: 0, sucursales: [3] },
  { id: 'br26', cat: 'bar-snacks', nombre: "Chokis", desc: '', precio: 0, sucursales: [3] },
  { id: 'br27', cat: 'bar-snacks', nombre: "Bombombum", desc: '', precio: 0, sucursales: [3] },
  { id: 'br28', cat: 'bar-snacks', nombre: "Dulces", desc: '', precio: 0, sucursales: [3] },

  { id: 'br29', cat: 'bar-sinalcohol', nombre: "Gatorade, agua y jugos", desc: '', precio: 0, sucursales: [3] },
];

/* =========================================================================
   CATÁLOGO DE INVENTARIO
   =========================================================================

   ⚠️  ESTRUCTURA DERIVADA — REEMPLAZAR POR EL CATÁLOGO REAL

   El restaurante todavía no tiene un catálogo de inventario con códigos
   propios. Esta lista NO inventa productos: sale de NASCAR.CARTA (los
   platos que el restaurante realmente vende), a la que sólo se le asignó
   un código correlativo y un área.

       C001 … C027  ->  Comidas
       B001 … B006  ->  Bar (la categoría "bebidas" de la carta)

   Cuando exista el catálogo real (con los códigos que ya usan las meseras
   en las plantillas de papel), se reemplaza esta lista completa. Nada más
   del sistema depende de estos códigos concretos.

   Campos:
     codigo       Identificador principal. Es la llave del inventario.
     nombre       Nombre que ve la mesera.
     categoria    Agrupación para ordenar la pantalla.
     area         'comidas' | 'bar'
     unidad       Unidad de medida del conteo físico.
     activo       false => no aparece en los cierres nuevos.
     ventaRefIds  Qué se descuenta del inventario cuando esto se vende.
                  Son ids de NASCAR.CARTA. Sirve para calcular Z (ventas).
                  Un producto que no se vende directamente (una botella que
                  sólo se usa para preparar cócteles, por ejemplo) lleva
                  ventaRefIds: [] y su Z queda en 0 hasta que exista un
                  módulo de recetas.
   ========================================================================= */
NASCAR.INVENTARIO = [
  /* ---------- COMIC'ENDO AREPA · planilla INVENTARIO DIARIO (unidad 4)
     Son INSUMOS, no platos: el pan y la carne se cuentan, la hamburguesa
     se vende. Sólo las gaseosas se venden tal cual, y por eso son las
     únicas con `ventaRefIds`. ------------------------------------- */

  { codigo: 'CE-01', nombre: "Pan hamburguesa", categoria: 'Panes y arepas', area: 'comidas', unidad: 'unidad', activo: true, ventaRefIds: [], sucursales: [4] },
  { codigo: 'CE-02', nombre: "Pan perro", categoria: 'Panes y arepas', area: 'comidas', unidad: 'unidad', activo: true, ventaRefIds: [], sucursales: [4] },
  { codigo: 'CE-03', nombre: "Arepas", categoria: 'Panes y arepas', area: 'comidas', unidad: 'unidad', activo: true, ventaRefIds: [], sucursales: [4] },

  { codigo: 'CE-04', nombre: "Francesa", categoria: 'Insumos', area: 'comidas', unidad: 'unidad', activo: true, ventaRefIds: [], sucursales: [4] },
  { codigo: 'CE-05', nombre: "Maíz", categoria: 'Insumos', area: 'comidas', unidad: 'unidad', activo: true, ventaRefIds: [], sucursales: [4] },
  { codigo: 'CE-06', nombre: "Quesos", categoria: 'Insumos', area: 'comidas', unidad: 'unidad', activo: true, ventaRefIds: [], sucursales: [4] },

  { codigo: 'CE-07', nombre: "Jamón", categoria: 'Carnes y embutidos', area: 'comidas', unidad: 'unidad', activo: true, ventaRefIds: [], sucursales: [4] },
  { codigo: 'CE-08', nombre: "Tocineta", categoria: 'Carnes y embutidos', area: 'comidas', unidad: 'unidad', activo: true, ventaRefIds: [], sucursales: [4] },
  { codigo: 'CE-09', nombre: "Salchichas", categoria: 'Carnes y embutidos', area: 'comidas', unidad: 'unidad', activo: true, ventaRefIds: [], sucursales: [4] },
  { codigo: 'CE-10', nombre: "Chorizos", categoria: 'Carnes y embutidos', area: 'comidas', unidad: 'unidad', activo: true, ventaRefIds: [], sucursales: [4] },
  { codigo: 'CE-11', nombre: "Carne hamburguesa", categoria: 'Carnes y embutidos', area: 'comidas', unidad: 'unidad', activo: true, ventaRefIds: [], sucursales: [4] },
  { codigo: 'CE-12', nombre: "Carne pollo", categoria: 'Carnes y embutidos', area: 'comidas', unidad: 'unidad', activo: true, ventaRefIds: [], sucursales: [4] },
  { codigo: 'CE-13', nombre: "Churrascos", categoria: 'Carnes y embutidos', area: 'comidas', unidad: 'unidad', activo: true, ventaRefIds: [], sucursales: [4] },
  { codigo: 'CE-14', nombre: "Costillas", categoria: 'Carnes y embutidos', area: 'comidas', unidad: 'unidad', activo: true, ventaRefIds: [], sucursales: [4] },
  { codigo: 'CE-15', nombre: "Tocino", categoria: 'Carnes y embutidos', area: 'comidas', unidad: 'unidad', activo: true, ventaRefIds: [], sucursales: [4] },

  { codigo: 'CE-16', nombre: "Gaseosa 1.5", categoria: 'Bebidas', area: 'comidas', unidad: 'botella', activo: true, ventaRefIds: ['ce53'], sucursales: [4] },
  { codigo: 'CE-17', nombre: "Gaseosa 400", categoria: 'Bebidas', area: 'comidas', unidad: 'botella', activo: true, ventaRefIds: ['ce51'], sucursales: [4] },
  { codigo: 'CE-18', nombre: "Gaseosa 250", categoria: 'Bebidas', area: 'comidas', unidad: 'botella', activo: true, ventaRefIds: ['ce52'], sucursales: [4] },

  /* ---------- NASCAR Bar VIP · planilla del bar (unidad 3)
     El código conserva el número (CD) de la planilla de papel: el 18 y el
     21 no existen allí y aquí tampoco. Cada uno se vende tal cual, así
     que todos apuntan a su producto de la carta. ------------------ */

  { codigo: 'BAR-01', nombre: "Cerveza", categoria: 'Cervezas', area: 'bar', unidad: 'botella', activo: true, ventaRefIds: ['br01'], sucursales: [3] },
  { codigo: 'BAR-02', nombre: "Águila Light", categoria: 'Cervezas', area: 'bar', unidad: 'botella', activo: true, ventaRefIds: ['br02'], sucursales: [3] },
  { codigo: 'BAR-03', nombre: "Club Colombia", categoria: 'Cervezas', area: 'bar', unidad: 'botella', activo: true, ventaRefIds: ['br03'], sucursales: [3] },
  { codigo: 'BAR-04', nombre: "Corona", categoria: 'Cervezas', area: 'bar', unidad: 'botella', activo: true, ventaRefIds: ['br04'], sucursales: [3] },
  { codigo: 'BAR-05', nombre: "Coronita", categoria: 'Cervezas', area: 'bar', unidad: 'botella', activo: true, ventaRefIds: ['br05'], sucursales: [3] },

  { codigo: 'BAR-06', nombre: "Smirnoff", categoria: 'Licores', area: 'bar', unidad: 'botella', activo: true, ventaRefIds: ['br06'], sucursales: [3] },
  { codigo: 'BAR-07', nombre: "Media de verde", categoria: 'Licores', area: 'bar', unidad: 'media', activo: true, ventaRefIds: ['br07'], sucursales: [3] },
  { codigo: 'BAR-08', nombre: "Caja verde", categoria: 'Licores', area: 'bar', unidad: 'caja', activo: true, ventaRefIds: ['br08'], sucursales: [3] },
  { codigo: 'BAR-09', nombre: "Media de Antioqueño", categoria: 'Licores', area: 'bar', unidad: 'media', activo: true, ventaRefIds: ['br09'], sucursales: [3] },
  { codigo: 'BAR-10', nombre: "Botella de Antioqueño", categoria: 'Licores', area: 'bar', unidad: 'botella', activo: true, ventaRefIds: ['br10'], sucursales: [3] },
  { codigo: 'BAR-11', nombre: "Botella de whisky", categoria: 'Licores', area: 'bar', unidad: 'botella', activo: true, ventaRefIds: ['br11'], sucursales: [3] },
  { codigo: 'BAR-12', nombre: "Botella de ron", categoria: 'Licores', area: 'bar', unidad: 'botella', activo: true, ventaRefIds: ['br12'], sucursales: [3] },
  { codigo: 'BAR-13', nombre: "Media de ron", categoria: 'Licores', area: 'bar', unidad: 'media', activo: true, ventaRefIds: ['br13'], sucursales: [3] },
  { codigo: 'BAR-14', nombre: "Old Parr", categoria: 'Licores', area: 'bar', unidad: 'botella', activo: true, ventaRefIds: ['br14'], sucursales: [3] },
  { codigo: 'BAR-15', nombre: "Botella de tequila", categoria: 'Licores', area: 'bar', unidad: 'botella', activo: true, ventaRefIds: ['br15'], sucursales: [3] },
  { codigo: 'BAR-16', nombre: "Media de tequila", categoria: 'Licores', area: 'bar', unidad: 'media', activo: true, ventaRefIds: ['br16'], sucursales: [3] },
  { codigo: 'BAR-17', nombre: "Media de amarillo", categoria: 'Licores', area: 'bar', unidad: 'media', activo: true, ventaRefIds: ['br17'], sucursales: [3] },

  { codigo: 'BAR-19', nombre: "Cigarrillos", categoria: 'Cigarrillos y varios', area: 'bar', unidad: 'unidad', activo: true, ventaRefIds: ['br19'], sucursales: [3] },

  { codigo: 'BAR-20', nombre: "Traiden grande", categoria: 'Snacks y dulces', area: 'bar', unidad: 'unidad', activo: true, ventaRefIds: ['br21'], sucursales: [3] },
  { codigo: 'BAR-22', nombre: "Traiden mediano", categoria: 'Snacks y dulces', area: 'bar', unidad: 'unidad', activo: true, ventaRefIds: ['br22'], sucursales: [3] },
  { codigo: 'BAR-23', nombre: "Traiden personal", categoria: 'Snacks y dulces', area: 'bar', unidad: 'unidad', activo: true, ventaRefIds: ['br23'], sucursales: [3] },

  { codigo: 'BAR-24', nombre: "Encendedores", categoria: 'Cigarrillos y varios', area: 'bar', unidad: 'unidad', activo: true, ventaRefIds: ['br20'], sucursales: [3] },

  { codigo: 'BAR-25', nombre: "Papas grandes", categoria: 'Snacks y dulces', area: 'bar', unidad: 'paquete', activo: true, ventaRefIds: ['br24'], sucursales: [3] },
  { codigo: 'BAR-26', nombre: "Papas pequeñas", categoria: 'Snacks y dulces', area: 'bar', unidad: 'paquete', activo: true, ventaRefIds: ['br25'], sucursales: [3] },
  { codigo: 'BAR-27', nombre: "Chokis", categoria: 'Snacks y dulces', area: 'bar', unidad: 'unidad', activo: true, ventaRefIds: ['br26'], sucursales: [3] },
  { codigo: 'BAR-28', nombre: "Bombombum", categoria: 'Snacks y dulces', area: 'bar', unidad: 'unidad', activo: true, ventaRefIds: ['br27'], sucursales: [3] },
  { codigo: 'BAR-29', nombre: "Dulces", categoria: 'Snacks y dulces', area: 'bar', unidad: 'unidad', activo: true, ventaRefIds: ['br28'], sucursales: [3] },

  { codigo: 'BAR-30', nombre: "Gatorade, agua y jugos", categoria: 'Sin alcohol', area: 'bar', unidad: 'unidad', activo: true, ventaRefIds: ['br29'], sucursales: [3] },

  { codigo: 'BAR-31', nombre: "Amarillo y rosado", categoria: 'Licores', area: 'bar', unidad: 'botella', activo: true, ventaRefIds: ['br18'], sucursales: [3] },
];

/* -------------------------------------------------------------------------
   Plantilla para los platos del día (lo que el admin llena cada mañana)
   ------------------------------------------------------------------------- */
/* ==========================================================================
   MENÚ DEL DÍA · MODALIDADES
   Cada sucursal, en cada fecha, publica UNA de las dos:
     · armado → el cliente elige una opción por categoría (un solo precio)
     · chef   → platos completos, cada uno con su nombre, descripción y precio
   ========================================================================== */
NASCAR.TIPOS_MENU_DIA = [
  {
    id: 'armado',
    nombre: 'Menú armado',
    icono: '🥣',
    desc: 'El cliente arma su menú eligiendo una opción de cada categoría: sopa, principio, proteína, jugo… Un solo precio.',
  },
  {
    id: 'chef',
    nombre: 'Menú del chef',
    icono: '👨‍🍳',
    desc: 'Platos completos, cada uno con su nombre, descripción, precio y emoji.',
  },
];

/* Categorías con que arranca un menú armado nuevo. Son sólo el punto de
   partida: desde el panel se renombran, se reordenan, se desactivan o se
   crean otras, sin tocar código. */
/* `maxSeleccion` = cuántas opciones puede elegir el cliente en esa
   categoría. El principio admite dos (arroz + ensalada, por ejemplo); el
   resto, una. Es configurable por categoría desde el panel: la regla no
   está atada al nombre de la categoría. */
NASCAR.CATEGORIAS_ARMADO = [
  { nombre: 'Sopa', icono: '🥣', obligatoria: true, maxSeleccion: 1 },
  { nombre: 'Principio', icono: '🍛', obligatoria: true, maxSeleccion: 2 },
  { nombre: 'Proteína', icono: '🍗', obligatoria: true, maxSeleccion: 1 },
  { nombre: 'Jugos', icono: '🥤', obligatoria: true, maxSeleccion: 1 },
];

/* Encabezado del menú del día en el portal público cuando la unidad no
   ha escrito el suyo. Único sitio donde vive este texto: ni index.html ni
   mesa.html lo llevan escrito. */
NASCAR.TEXTO_MENU_DIA = {
  titulo: 'Menú del día',
  mensaje: 'Consulta las opciones disponibles para hoy.',
};

/* Emojis que se ofrecen con un toque al crear un plato del chef. */
NASCAR.EMOJIS_PLATO = ['🍖', '🥩', '🍗', '🐟', '🍤', '🫘', '🍲', '🥗', '🍝', '🌮', '🍔', '🔥'];

/* Plato del chef nuevo (y el formato de los platos del día de siempre). */
NASCAR.PLANTILLA_DIA = {
  nombre: '',
  desc: '',
  sopa: '',
  principio: '',
  proteina: '',
  bebida: '',
  precio: 18000,
  cupos: 30,
  disponible: true,
};

/* Semilla: si no hay platos del día guardados, se crean estos para hoy
   para que la página no aparezca vacía en la primera visita. */
NASCAR.SEMILLA_DIA = [
  {
    sucursalId: 1,
    nombre: 'Almuerzo ejecutivo',
    desc: 'Ejemplo: cámbialo cada mañana desde Panel → Menú del día.',
    sopa: 'Sancocho de costilla',
    principio: 'Arroz + fríjol',
    proteina: 'Carne asada',
    bebida: 'Limonada natural',
    precio: 18000,
    cupos: 40,
    disponible: true,
  },
  {
    sucursalId: 1,
    nombre: 'Almuerzo del día',
    desc: 'Ejemplo: cámbialo cada mañana desde Panel → Menú del día.',
    sopa: 'Crema de ahuyama',
    principio: 'Arroz + papa a la francesa',
    proteina: 'Pollo apanado',
    bebida: 'Jugo de mora en agua',
    precio: 16000,
    cupos: 40,
    disponible: true,
  },
  {
    sucursalId: 1,
    nombre: 'Almuerzo especial',
    desc: 'Ejemplo: cámbialo cada mañana desde Panel → Menú del día.',
    sopa: 'Sopa de pasta',
    principio: 'Arroz + ensalada',
    proteina: 'Churrasco 200 g',
    bebida: 'Limonada de panela',
    precio: 24000,
    cupos: 20,
    disponible: true,
  },
  {
    sucursalId: 2,
    nombre: 'Corrientazo',
    desc: 'Ejemplo: cámbialo cada mañana desde Panel → Menú del día.',
    sopa: 'Consomé de pollo',
    principio: 'Arroz + plátano',
    proteina: 'Chicharrón',
    bebida: 'Refresco de panela',
    precio: 15000,
    cupos: 50,
    disponible: true,
  },
  {
    sucursalId: 2,
    nombre: 'Bandeja del día',
    desc: 'Ejemplo: cámbialo cada mañana desde Panel → Menú del día.',
    sopa: 'Crema de verduras',
    principio: 'Arroz + fríjol + plátano',
    proteina: 'Chicharrón y carne molida',
    bebida: 'Limonada natural',
    precio: 22000,
    cupos: 25,
    disponible: true,
  },
];
