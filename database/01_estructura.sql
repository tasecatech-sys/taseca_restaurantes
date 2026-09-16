/* ============================================================================
   TASECA · 01 · ESTRUCTURA (esquemas, tablas, llaves, índices)
   ----------------------------------------------------------------------------
   Ejecutar conectado a taseca_db.

   DOS ESQUEMAS
     core  → las TABLAS y la lógica interna. La aplicación no las toca.
     api   → lo que consume la aplicación: VISTAS para leer, PROCEDIMIENTOS
             y FUNCIONES para escribir. Es el contrato con el front.

   REGLAS DEL MODELO
     · Toda PK es un único campo `id` SERIAL (catálogos y configuración) o
       BIGSERIAL (tablas transaccionales que crecen sin límite: pedidos,
       ítems, historial, movimientos). BIGSERIAL es SERIAL de 64 bits.
     · No hay llaves compuestas. Lo que debe ser único en conjunto
       (p. ej. empresa + código) se garantiza con UNIQUE, no con la PK.
     · 3FN: cada dato vive en un solo lugar. Los nombres de estados, tipos,
       roles… están en catálogos y se referencian por id.
     · Multiempresa: todo cuelga de core.empresas, directa o indirectamente
       (a través de la unidad). Una empresa nunca ve datos de otra.
     · Nada histórico se borra: FK con ON DELETE RESTRICT y estados
       (activa/inactiva, anulado) en lugar de DELETE.

   DATOS QUE PARECEN REPETIDOS Y NO LO SON
     · pedido_items.nombre y precio_unitario: son la FOTO de la factura en el
       momento de la venta. Si mañana cambia el precio de la carta, la
       factura de ayer no puede cambiar. Es un hecho histórico, no una copia.
     · pedidos.costo_domicilio: igual, el costo de la zona puede cambiar.
     · pedidos.fecha_operativa: depende de la hora de corte vigente al
       vender; si la empresa la cambia, la jornada de una venta ya hecha no.
     · pedidos.empresa_id: la unidad ya dice la empresa, pero el código de
       factura (00027) es único POR EMPRESA y eso sólo se puede garantizar
       con la columna. Un trigger impide que no coincida con la unidad.
   ============================================================================ */

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- hash de los PIN (crypt / gen_salt)

CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS api;

COMMENT ON SCHEMA core IS 'Tablas y lógica interna. La aplicación no accede directamente.';
COMMENT ON SCHEMA api  IS 'Contrato con la aplicación: vistas (lectura) y procedimientos/funciones (escritura).';

SET search_path = core, public;


/* ============================================================================
   1. CATÁLOGOS DEL SISTEMA (iguales para todas las empresas)
   ============================================================================ */

CREATE TABLE core.modulos (
    id           SERIAL PRIMARY KEY,
    codigo       VARCHAR(30)  NOT NULL UNIQUE,
    nombre       VARCHAR(60)  NOT NULL,
    descripcion  VARCHAR(250),
    obligatorio  BOOLEAN      NOT NULL DEFAULT FALSE
);
COMMENT ON TABLE core.modulos IS 'Módulos que una empresa puede contratar: básico, stock, cierre.';

CREATE TABLE core.tipos_negocio (
    id      SERIAL PRIMARY KEY,
    codigo  VARCHAR(30) NOT NULL UNIQUE,
    nombre  VARCHAR(60) NOT NULL,
    icono   VARCHAR(8)
);
COMMENT ON TABLE core.tipos_negocio IS 'Atributo de la unidad (restaurante, bar, arepera…). No enciende ni apaga funciones.';

CREATE TABLE core.roles (
    id           SERIAL PRIMARY KEY,
    codigo       VARCHAR(30)  NOT NULL UNIQUE,
    nombre       VARCHAR(60)  NOT NULL,
    descripcion  VARCHAR(250),
    alcance      VARCHAR(12)  NOT NULL CHECK (alcance IN ('plataforma', 'empresa')),
    icono        VARCHAR(8)
);
COMMENT ON COLUMN core.roles.alcance IS 'plataforma = Taseca (sin empresa); empresa = usuario de un cliente.';

CREATE TABLE core.permisos (
    id           SERIAL PRIMARY KEY,
    codigo       VARCHAR(40)  NOT NULL UNIQUE,
    descripcion  VARCHAR(250) NOT NULL,
    modulo_id    INTEGER      REFERENCES core.modulos (id) ON DELETE RESTRICT
);
COMMENT ON COLUMN core.permisos.modulo_id IS 'Módulo que debe tener contratado la empresa para que el permiso aplique. NULL = ninguno.';

CREATE TABLE core.rol_permisos (
    id          SERIAL PRIMARY KEY,
    rol_id      INTEGER NOT NULL REFERENCES core.roles (id)    ON DELETE CASCADE,
    permiso_id  INTEGER NOT NULL REFERENCES core.permisos (id) ON DELETE CASCADE,
    CONSTRAINT uq_rol_permisos UNIQUE (rol_id, permiso_id)
);

CREATE TABLE core.metodos_pago (
    id          SERIAL PRIMARY KEY,
    codigo      VARCHAR(30) NOT NULL UNIQUE,
    nombre      VARCHAR(80) NOT NULL,
    grupo_caja  VARCHAR(15) NOT NULL DEFAULT 'otros'
                CHECK (grupo_caja IN ('efectivo', 'transferencia', 'otros'))
);
COMMENT ON COLUMN core.metodos_pago.grupo_caja IS 'A qué columna del cruce de caja va el dinero. Sólo efectivo cambia el cajón.';

CREATE TABLE core.tipos_pedido (
    id      SERIAL PRIMARY KEY,
    codigo  VARCHAR(20) NOT NULL UNIQUE,
    nombre  VARCHAR(40) NOT NULL
);

CREATE TABLE core.estados_pedido (
    id                 SERIAL PRIMARY KEY,
    codigo             VARCHAR(20) NOT NULL UNIQUE,
    nombre             VARCHAR(40) NOT NULL,
    orden              SMALLINT    NOT NULL,
    solo_domicilio     BOOLEAN     NOT NULL DEFAULT FALSE,
    es_final           BOOLEAN     NOT NULL DEFAULT FALSE,
    cuenta_como_venta  BOOLEAN     NOT NULL DEFAULT TRUE
);
COMMENT ON COLUMN core.estados_pedido.orden IS 'Posición en el flujo. Cancelado y anulado no forman parte del flujo (orden 90+).';
COMMENT ON COLUMN core.estados_pedido.cuenta_como_venta IS 'Cancelado y anulado no son venta efectiva.';

CREATE TABLE core.estados_pago (
    id      SERIAL PRIMARY KEY,
    codigo  VARCHAR(20) NOT NULL UNIQUE,
    nombre  VARCHAR(40) NOT NULL
);

CREATE TABLE core.estados_gasto (
    id      SERIAL PRIMARY KEY,
    codigo  VARCHAR(20) NOT NULL UNIQUE,
    nombre  VARCHAR(40) NOT NULL
);

CREATE TABLE core.estados_cierre (
    id      SERIAL PRIMARY KEY,
    codigo  VARCHAR(20) NOT NULL UNIQUE,
    nombre  VARCHAR(40) NOT NULL,
    orden   SMALLINT    NOT NULL
);

CREATE TABLE core.tipos_entrada (
    id          SERIAL PRIMARY KEY,
    codigo      VARCHAR(30) NOT NULL UNIQUE,
    nombre      VARCHAR(80) NOT NULL,
    automatico  BOOLEAN     NOT NULL DEFAULT FALSE
);
COMMENT ON COLUMN core.tipos_entrada.automatico IS 'Lo genera el sistema (retorno por anulación); no se registra a mano.';

CREATE TABLE core.areas_inventario (
    id      SERIAL PRIMARY KEY,
    codigo  VARCHAR(20) NOT NULL UNIQUE,
    nombre  VARCHAR(40) NOT NULL,
    icono   VARCHAR(8)
);

CREATE TABLE core.unidades_medida (
    id      SERIAL PRIMARY KEY,
    codigo  VARCHAR(20) NOT NULL UNIQUE,
    nombre  VARCHAR(40) NOT NULL
);

CREATE TABLE core.etiquetas_producto (
    id      SERIAL PRIMARY KEY,
    codigo  VARCHAR(20) NOT NULL UNIQUE,
    nombre  VARCHAR(40) NOT NULL
);

CREATE TABLE core.tipos_menu (
    id           SERIAL PRIMARY KEY,
    codigo       VARCHAR(20)  NOT NULL UNIQUE,
    nombre       VARCHAR(40)  NOT NULL,
    descripcion  VARCHAR(250)
);


/* ============================================================================
   2. EMPRESAS (los clientes de Taseca)
   ============================================================================ */

CREATE TABLE core.empresas (
    id                    SERIAL PRIMARY KEY,
    codigo                VARCHAR(40)  NOT NULL UNIQUE,
    nombre_comercial      VARCHAR(120) NOT NULL,
    razon_social          VARCHAR(160),
    nit                   VARCHAR(20)  UNIQUE,
    eslogan               VARCHAR(120),
    descripcion           VARCHAR(400),
    estado                VARCHAR(12)  NOT NULL DEFAULT 'activa'
                          CHECK (estado IN ('activa', 'suspendida', 'inactiva')),
    zona_horaria          VARCHAR(40)  NOT NULL DEFAULT 'America/Bogota',
    hora_corte_operativa  SMALLINT     NOT NULL DEFAULT 6 CHECK (hora_corte_operativa BETWEEN 0 AND 23),
    telefono              VARCHAR(20),
    whatsapp              VARCHAR(20),
    email                 VARCHAR(120),
    direccion             VARCHAR(160),
    horario_general       VARCHAR(120),
    instagram_url         VARCHAR(250),
    facebook_url          VARCHAR(250),
    tiempo_mesa           VARCHAR(30),
    tiempo_domicilio      VARCHAR(30),
    color_primario        VARCHAR(7)   CHECK (color_primario   ~ '^#[0-9A-Fa-f]{6}$'),
    color_secundario      VARCHAR(7)   CHECK (color_secundario ~ '^#[0-9A-Fa-f]{6}$'),
    color_acento          VARCHAR(7)   CHECK (color_acento     ~ '^#[0-9A-Fa-f]{6}$'),
    color_fondo           VARCHAR(7)   CHECK (color_fondo      ~ '^#[0-9A-Fa-f]{6}$'),
    logo_url              VARCHAR(500),
    creado_en             TIMESTAMPTZ  NOT NULL DEFAULT now(),
    actualizado_en        TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE core.empresas IS 'Cliente de Taseca. Raíz del aislamiento multiempresa.';
COMMENT ON COLUMN core.empresas.hora_corte_operativa IS 'Hora a la que empieza la jornada. Con 6, lo ocurrido a las 01:30 cuenta para el día anterior.';

CREATE TABLE core.empresa_modulos (
    id          SERIAL PRIMARY KEY,
    empresa_id  INTEGER NOT NULL REFERENCES core.empresas (id) ON DELETE CASCADE,
    modulo_id   INTEGER NOT NULL REFERENCES core.modulos (id)  ON DELETE RESTRICT,
    activo      BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_empresa_modulos UNIQUE (empresa_id, modulo_id)
);

CREATE TABLE core.empresa_metodos_pago (
    id              SERIAL PRIMARY KEY,
    empresa_id      INTEGER      NOT NULL REFERENCES core.empresas (id)     ON DELETE CASCADE,
    metodo_pago_id  INTEGER      NOT NULL REFERENCES core.metodos_pago (id) ON DELETE RESTRICT,
    activo          BOOLEAN      NOT NULL DEFAULT TRUE,
    descripcion     VARCHAR(250),
    orden           SMALLINT     NOT NULL DEFAULT 0,
    CONSTRAINT uq_empresa_metodos_pago UNIQUE (empresa_id, metodo_pago_id)
);

CREATE TABLE core.cuentas_recaudo (
    id           SERIAL PRIMARY KEY,
    empresa_id   INTEGER      NOT NULL REFERENCES core.empresas (id) ON DELETE CASCADE,
    entidad      VARCHAR(60)  NOT NULL,
    tipo_cuenta  VARCHAR(30),
    numero       VARCHAR(40)  NOT NULL,
    titular      VARCHAR(160),
    activa       BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_cuentas_recaudo UNIQUE (empresa_id, entidad, numero)
);
COMMENT ON TABLE core.cuentas_recaudo IS 'Cuentas donde el cliente transfiere (Nequi, Daviplata, Bancolombia…).';

CREATE TABLE core.consecutivos (
    id             SERIAL PRIMARY KEY,
    empresa_id     INTEGER     NOT NULL REFERENCES core.empresas (id) ON DELETE CASCADE,
    tipo           VARCHAR(20) NOT NULL DEFAULT 'pedido',
    ultimo_numero  INTEGER     NOT NULL DEFAULT 0 CHECK (ultimo_numero >= 0),
    digitos        SMALLINT    NOT NULL DEFAULT 5 CHECK (digitos BETWEEN 3 AND 10),
    CONSTRAINT uq_consecutivos UNIQUE (empresa_id, tipo)
);
COMMENT ON TABLE core.consecutivos IS 'Numeración de facturas por empresa (00001, 00002…), compartida por todas sus unidades.';


/* ============================================================================
   3. UNIDADES / LOCALES
   ============================================================================ */

CREATE TABLE core.unidades (
    id               SERIAL PRIMARY KEY,
    empresa_id       INTEGER      NOT NULL REFERENCES core.empresas (id)      ON DELETE RESTRICT,
    tipo_negocio_id  INTEGER      NOT NULL REFERENCES core.tipos_negocio (id) ON DELETE RESTRICT,
    nombre           VARCHAR(120) NOT NULL,
    nombre_corto     VARCHAR(40)  NOT NULL,
    estado           VARCHAR(10)  NOT NULL DEFAULT 'activa' CHECK (estado IN ('activa', 'inactiva')),
    direccion        VARCHAR(160),
    ciudad           VARCHAR(80),
    telefono         VARCHAR(20),
    whatsapp         VARCHAR(20),
    horario          VARCHAR(120),
    mapa_url         VARCHAR(500),
    color            VARCHAR(20),
    logo_url         VARCHAR(500),
    creado_en        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    actualizado_en   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT uq_unidades_nombre UNIQUE (empresa_id, nombre),
    CONSTRAINT uq_unidades_corto  UNIQUE (empresa_id, nombre_corto)
);
COMMENT ON TABLE core.unidades IS 'Punto de operación de una empresa. Inactiva = conserva su historia pero no admite operación nueva.';

CREATE TABLE core.mesas (
    id         SERIAL PRIMARY KEY,
    unidad_id  INTEGER     NOT NULL REFERENCES core.unidades (id) ON DELETE RESTRICT,
    numero     VARCHAR(10) NOT NULL,
    activa     BOOLEAN     NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_mesas UNIQUE (unidad_id, numero)
);

CREATE TABLE core.zonas_domicilio (
    id             SERIAL PRIMARY KEY,
    unidad_id      INTEGER       NOT NULL REFERENCES core.unidades (id) ON DELETE RESTRICT,
    nombre         VARCHAR(80)   NOT NULL,
    costo          NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (costo >= 0),
    pedido_minimo  NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (pedido_minimo >= 0),
    activa         BOOLEAN       NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_zonas_domicilio UNIQUE (unidad_id, nombre)
);
COMMENT ON TABLE core.zonas_domicilio IS 'Una unidad sin zonas atiende domicilios sin costo ni pedido mínimo.';


/* ============================================================================
   4. USUARIOS
   ============================================================================ */

CREATE TABLE core.usuarios (
    id              SERIAL PRIMARY KEY,
    empresa_id      INTEGER      REFERENCES core.empresas (id) ON DELETE RESTRICT,
    rol_id          INTEGER      NOT NULL REFERENCES core.roles (id) ON DELETE RESTRICT,
    nombre          VARCHAR(120) NOT NULL,
    usuario         VARCHAR(40)  NOT NULL,
    pin_hash        TEXT         NOT NULL,
    activo          BOOLEAN      NOT NULL DEFAULT TRUE,
    ultimo_acceso   TIMESTAMPTZ,
    creado_en       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    actualizado_en  TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_usuarios_usuario ON core.usuarios (lower(usuario));
COMMENT ON COLUMN core.usuarios.empresa_id IS 'NULL sólo para usuarios de plataforma (Taseca). Lo valida un trigger según el rol.';
COMMENT ON COLUMN core.usuarios.pin_hash IS 'bcrypt (pgcrypto). Nunca se guarda el PIN en claro.';

CREATE TABLE core.usuario_unidades (
    id          SERIAL PRIMARY KEY,
    usuario_id  INTEGER NOT NULL REFERENCES core.usuarios (id) ON DELETE CASCADE,
    unidad_id   INTEGER NOT NULL REFERENCES core.unidades (id) ON DELETE RESTRICT,
    CONSTRAINT uq_usuario_unidades UNIQUE (usuario_id, unidad_id)
);
COMMENT ON TABLE core.usuario_unidades IS 'Unidades asignadas. Un usuario sin filas aquí trabaja en todas las de su empresa.';


/* ============================================================================
   5. CARTA (productos de VENTA)
   ============================================================================ */

CREATE TABLE core.categorias (
    id              SERIAL PRIMARY KEY,
    empresa_id      INTEGER     NOT NULL REFERENCES core.empresas (id) ON DELETE RESTRICT,
    nombre          VARCHAR(80) NOT NULL,
    icono           VARCHAR(8),
    orden           SMALLINT    NOT NULL DEFAULT 0,
    activa          BOOLEAN     NOT NULL DEFAULT TRUE,
    creado_en       TIMESTAMPTZ NOT NULL DEFAULT now(),
    actualizado_en  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_categorias UNIQUE (empresa_id, nombre)
);

CREATE TABLE core.categoria_unidades (
    id            SERIAL PRIMARY KEY,
    categoria_id  INTEGER NOT NULL REFERENCES core.categorias (id) ON DELETE CASCADE,
    unidad_id     INTEGER NOT NULL REFERENCES core.unidades (id)   ON DELETE RESTRICT,
    CONSTRAINT uq_categoria_unidades UNIQUE (categoria_id, unidad_id)
);

CREATE TABLE core.productos (
    id              SERIAL PRIMARY KEY,
    empresa_id      INTEGER       NOT NULL REFERENCES core.empresas (id)           ON DELETE RESTRICT,
    categoria_id    INTEGER       NOT NULL REFERENCES core.categorias (id)         ON DELETE RESTRICT,
    etiqueta_id     INTEGER       REFERENCES core.etiquetas_producto (id)          ON DELETE SET NULL,
    codigo          VARCHAR(30)   NOT NULL,
    nombre          VARCHAR(120)  NOT NULL,
    descripcion     VARCHAR(400),
    precio          NUMERIC(12,2) NOT NULL CHECK (precio >= 0),
    imagen_url      VARCHAR(500),
    orden           INTEGER       NOT NULL DEFAULT 0,
    activo          BOOLEAN       NOT NULL DEFAULT TRUE,
    creado_en       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    actualizado_en  TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT uq_productos_codigo UNIQUE (empresa_id, codigo)
);
COMMENT ON TABLE core.productos IS 'Lo que se VENDE (Hamburguesa doble carne). No es lo que se cuenta en inventario.';

CREATE TABLE core.producto_unidades (
    id           SERIAL PRIMARY KEY,
    producto_id  INTEGER NOT NULL REFERENCES core.productos (id) ON DELETE CASCADE,
    unidad_id    INTEGER NOT NULL REFERENCES core.unidades (id)  ON DELETE RESTRICT,
    agotado      BOOLEAN NOT NULL DEFAULT FALSE,
    CONSTRAINT uq_producto_unidades UNIQUE (producto_id, unidad_id)
);
COMMENT ON COLUMN core.producto_unidades.agotado IS 'Sin existencias temporalmente en ESA unidad.';


/* ============================================================================
   6. INVENTARIO (productos que se CUENTAN)
   ============================================================================ */

CREATE TABLE core.categorias_insumo (
    id          SERIAL PRIMARY KEY,
    empresa_id  INTEGER     NOT NULL REFERENCES core.empresas (id) ON DELETE RESTRICT,
    nombre      VARCHAR(80) NOT NULL,
    CONSTRAINT uq_categorias_insumo UNIQUE (empresa_id, nombre)
);

CREATE TABLE core.insumos (
    id                   SERIAL PRIMARY KEY,
    empresa_id           INTEGER      NOT NULL REFERENCES core.empresas (id)          ON DELETE RESTRICT,
    categoria_insumo_id  INTEGER      NOT NULL REFERENCES core.categorias_insumo (id) ON DELETE RESTRICT,
    area_id              INTEGER      NOT NULL REFERENCES core.areas_inventario (id)  ON DELETE RESTRICT,
    unidad_medida_id     INTEGER      NOT NULL REFERENCES core.unidades_medida (id)   ON DELETE RESTRICT,
    codigo               VARCHAR(20)  NOT NULL,
    nombre               VARCHAR(120) NOT NULL,
    activo               BOOLEAN      NOT NULL DEFAULT TRUE,
    creado_en            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    actualizado_en       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT uq_insumos_codigo UNIQUE (empresa_id, codigo)
);
COMMENT ON TABLE core.insumos IS 'Producto de inventario (pan, carne, botella). El código es el de la planilla de papel.';

CREATE TABLE core.insumo_unidades (
    id              SERIAL PRIMARY KEY,
    insumo_id       INTEGER       NOT NULL REFERENCES core.insumos (id)  ON DELETE RESTRICT,
    unidad_id       INTEGER       NOT NULL REFERENCES core.unidades (id) ON DELETE RESTRICT,
    stock_actual    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (stock_actual >= 0),
    stock_minimo    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (stock_minimo >= 0),
    actualizado_en  TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT uq_insumo_unidades UNIQUE (insumo_id, unidad_id)
);
COMMENT ON TABLE core.insumo_unidades IS 'El stock es de la UNIDAD: el mismo insumo tiene un saldo distinto en cada local.';

CREATE TABLE core.producto_insumos (
    id           SERIAL PRIMARY KEY,
    producto_id  INTEGER       NOT NULL REFERENCES core.productos (id) ON DELETE CASCADE,
    insumo_id    INTEGER       NOT NULL REFERENCES core.insumos (id)   ON DELETE RESTRICT,
    cantidad     NUMERIC(12,3) NOT NULL DEFAULT 1 CHECK (cantidad > 0),
    CONSTRAINT uq_producto_insumos UNIQUE (producto_id, insumo_id)
);
COMMENT ON TABLE core.producto_insumos IS 'Cuánto insumo descuenta cada venta (columna Z del cruce). Base del futuro módulo de recetas.';

CREATE TABLE core.cierres_inventario (
    id                 BIGSERIAL PRIMARY KEY,
    unidad_id          INTEGER      NOT NULL REFERENCES core.unidades (id)         ON DELETE RESTRICT,
    area_id            INTEGER      NOT NULL REFERENCES core.areas_inventario (id) ON DELETE RESTRICT,
    estado_cierre_id   INTEGER      NOT NULL REFERENCES core.estados_cierre (id)   ON DELETE RESTRICT,
    fecha_operativa    DATE         NOT NULL,
    observacion        VARCHAR(400),
    registrado_por_id  INTEGER      REFERENCES core.usuarios (id) ON DELETE RESTRICT,
    revisado_por_id    INTEGER      REFERENCES core.usuarios (id) ON DELETE RESTRICT,
    revisado_en        TIMESTAMPTZ,
    aplicado_a_stock   BOOLEAN      NOT NULL DEFAULT FALSE,
    creado_en          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    actualizado_en     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT uq_cierres_inventario UNIQUE (unidad_id, area_id, fecha_operativa)
);

CREATE TABLE core.cierre_detalles (
    id                 BIGSERIAL PRIMARY KEY,
    cierre_id          BIGINT        NOT NULL REFERENCES core.cierres_inventario (id) ON DELETE CASCADE,
    insumo_unidad_id   INTEGER       NOT NULL REFERENCES core.insumo_unidades (id)    ON DELETE RESTRICT,
    saldo_fisico       NUMERIC(12,2) NOT NULL CHECK (saldo_fisico >= 0),
    CONSTRAINT uq_cierre_detalles UNIQUE (cierre_id, insumo_unidad_id)
);
COMMENT ON COLUMN core.cierre_detalles.saldo_fisico IS 'SD: lo que se contó. IN, EN y Z se calculan en api.v_cruce_inventario.';

CREATE TABLE core.entradas_inventario (
    id                BIGSERIAL PRIMARY KEY,
    insumo_unidad_id  INTEGER       NOT NULL REFERENCES core.insumo_unidades (id) ON DELETE RESTRICT,
    tipo_entrada_id   INTEGER       NOT NULL REFERENCES core.tipos_entrada (id)   ON DELETE RESTRICT,
    fecha_operativa   DATE          NOT NULL,
    cantidad          NUMERIC(12,2) NOT NULL CHECK (cantidad > 0),
    observacion       VARCHAR(400),
    pedido_id         BIGINT,       -- FK al final: pedidos se crea después
    usuario_id        INTEGER       REFERENCES core.usuarios (id) ON DELETE RESTRICT,
    creado_en         TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON COLUMN core.entradas_inventario.pedido_id IS 'Sólo en los retornos por anulación: la factura que devolvió la mercancía.';


/* ============================================================================
   7. MENÚ DEL DÍA
   ============================================================================ */

CREATE TABLE core.textos_menu_unidad (
    id              SERIAL PRIMARY KEY,
    unidad_id       INTEGER      NOT NULL UNIQUE REFERENCES core.unidades (id) ON DELETE RESTRICT,
    titulo          VARCHAR(60),
    mensaje         VARCHAR(400),
    actualizado_en  TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE core.textos_menu_unidad IS 'Título y mensaje públicos de la unidad para todos los días. Un menú puede sobreescribirlos.';

CREATE TABLE core.menus_dia (
    id               BIGSERIAL PRIMARY KEY,
    unidad_id        INTEGER       NOT NULL REFERENCES core.unidades (id)   ON DELETE RESTRICT,
    tipo_menu_id     INTEGER       NOT NULL REFERENCES core.tipos_menu (id) ON DELETE RESTRICT,
    fecha            DATE          NOT NULL,
    nombre           VARCHAR(60),
    descripcion      VARCHAR(240),
    precio           NUMERIC(12,2) CHECK (precio > 0),
    disponible       BOOLEAN       NOT NULL DEFAULT TRUE,
    titulo_publico   VARCHAR(60),
    mensaje_publico  VARCHAR(400),
    creado_por_id    INTEGER       REFERENCES core.usuarios (id) ON DELETE RESTRICT,
    creado_en        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    actualizado_en   TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT uq_menus_dia UNIQUE (unidad_id, fecha)
);
COMMENT ON TABLE core.menus_dia IS 'Una sola modalidad por unidad y fecha. nombre/descripcion/precio aplican al menú ARMADO.';

CREATE TABLE core.menu_categorias (
    id             BIGSERIAL PRIMARY KEY,
    menu_dia_id    BIGINT      NOT NULL REFERENCES core.menus_dia (id) ON DELETE CASCADE,
    nombre         VARCHAR(40) NOT NULL,
    icono          VARCHAR(8),
    orden          SMALLINT    NOT NULL DEFAULT 0,
    obligatoria    BOOLEAN     NOT NULL DEFAULT TRUE,
    max_seleccion  SMALLINT    NOT NULL DEFAULT 1 CHECK (max_seleccion BETWEEN 1 AND 10),
    activa         BOOLEAN     NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_menu_categorias UNIQUE (menu_dia_id, nombre)
);
COMMENT ON COLUMN core.menu_categorias.max_seleccion IS 'Cuántas opciones puede elegir el cliente (Principio = 2).';

CREATE TABLE core.menu_opciones (
    id                 BIGSERIAL PRIMARY KEY,
    menu_categoria_id  BIGINT      NOT NULL REFERENCES core.menu_categorias (id) ON DELETE CASCADE,
    nombre             VARCHAR(60) NOT NULL,
    orden              SMALLINT    NOT NULL DEFAULT 0,
    activa             BOOLEAN     NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_menu_opciones UNIQUE (menu_categoria_id, nombre)
);

CREATE TABLE core.platos_dia (
    id           BIGSERIAL PRIMARY KEY,
    menu_dia_id  BIGINT        NOT NULL REFERENCES core.menus_dia (id) ON DELETE CASCADE,
    nombre       VARCHAR(80)   NOT NULL,
    descripcion  VARCHAR(240),
    emoji        VARCHAR(8),
    precio       NUMERIC(12,2) NOT NULL CHECK (precio > 0),
    cupos        INTEGER       CHECK (cupos > 0),
    disponible   BOOLEAN       NOT NULL DEFAULT TRUE,
    orden        SMALLINT      NOT NULL DEFAULT 0
);
COMMENT ON COLUMN core.platos_dia.cupos IS 'NULL = sin límite. Los vendidos se calculan de pedido_items, no se guardan.';


/* ============================================================================
   8. CLIENTES Y PEDIDOS / FACTURAS
   ============================================================================ */

CREATE TABLE core.clientes (
    id          BIGSERIAL PRIMARY KEY,
    empresa_id  INTEGER      NOT NULL REFERENCES core.empresas (id) ON DELETE RESTRICT,
    nombre      VARCHAR(120) NOT NULL,
    telefono    VARCHAR(20)  NOT NULL,
    creado_en   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT uq_clientes UNIQUE (empresa_id, telefono)
);

CREATE TABLE core.pedidos (
    id                  BIGSERIAL PRIMARY KEY,
    empresa_id          INTEGER       NOT NULL REFERENCES core.empresas (id)        ON DELETE RESTRICT,
    unidad_id           INTEGER       NOT NULL REFERENCES core.unidades (id)        ON DELETE RESTRICT,
    codigo              VARCHAR(12)   NOT NULL,
    tipo_pedido_id      INTEGER       NOT NULL REFERENCES core.tipos_pedido (id)    ON DELETE RESTRICT,
    estado_pedido_id    INTEGER       NOT NULL REFERENCES core.estados_pedido (id)  ON DELETE RESTRICT,
    estado_pago_id      INTEGER       NOT NULL REFERENCES core.estados_pago (id)    ON DELETE RESTRICT,
    metodo_pago_id      INTEGER       NOT NULL REFERENCES core.metodos_pago (id)    ON DELETE RESTRICT,
    mesa_id             INTEGER       REFERENCES core.mesas (id)                    ON DELETE RESTRICT,
    cliente_id          BIGINT        REFERENCES core.clientes (id)                 ON DELETE RESTRICT,
    zona_domicilio_id   INTEGER       REFERENCES core.zonas_domicilio (id)          ON DELETE RESTRICT,
    direccion_entrega   VARCHAR(200),
    indicaciones        VARCHAR(300),
    costo_domicilio     NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (costo_domicilio >= 0),
    paga_con            NUMERIC(12,2) CHECK (paga_con >= 0),
    fecha_operativa     DATE          NOT NULL,
    motivo_cancelacion  VARCHAR(300),
    tomado_por_id       INTEGER       REFERENCES core.usuarios (id) ON DELETE RESTRICT,
    creado_en           TIMESTAMPTZ   NOT NULL DEFAULT now(),
    actualizado_en      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT uq_pedidos_codigo UNIQUE (empresa_id, codigo)
);
COMMENT ON TABLE core.pedidos IS 'Pedido y factura. Subtotal y total NO se guardan: se calculan de sus ítems (api.v_pedidos).';
COMMENT ON COLUMN core.pedidos.codigo IS 'Consecutivo corto por empresa (00027). Lo asigna un trigger.';

CREATE TABLE core.pedido_items (
    id               BIGSERIAL PRIMARY KEY,
    pedido_id        BIGINT        NOT NULL REFERENCES core.pedidos (id)    ON DELETE CASCADE,
    producto_id      INTEGER       REFERENCES core.productos (id)           ON DELETE RESTRICT,
    plato_dia_id     BIGINT        REFERENCES core.platos_dia (id)          ON DELETE RESTRICT,
    menu_dia_id      BIGINT        REFERENCES core.menus_dia (id)           ON DELETE RESTRICT,
    nombre           VARCHAR(120)  NOT NULL,
    precio_unitario  NUMERIC(12,2) NOT NULL CHECK (precio_unitario >= 0),
    cantidad         INTEGER       NOT NULL CHECK (cantidad > 0),
    notas            VARCHAR(200),
    CONSTRAINT ck_pedido_items_origen CHECK (num_nonnulls(producto_id, plato_dia_id, menu_dia_id) = 1)
);
COMMENT ON TABLE core.pedido_items IS 'Una línea por producto de carta, plato del chef o combinación de menú armado.';
COMMENT ON COLUMN core.pedido_items.menu_dia_id IS 'Menú ARMADO: la combinación elegida está en pedido_item_opciones.';

CREATE TABLE core.pedido_item_opciones (
    id              BIGSERIAL PRIMARY KEY,
    pedido_item_id  BIGINT NOT NULL REFERENCES core.pedido_items (id)  ON DELETE CASCADE,
    menu_opcion_id  BIGINT NOT NULL REFERENCES core.menu_opciones (id) ON DELETE RESTRICT,
    CONSTRAINT uq_pedido_item_opciones UNIQUE (pedido_item_id, menu_opcion_id)
);

CREATE TABLE core.pedido_historial (
    id                BIGSERIAL PRIMARY KEY,
    pedido_id         BIGINT       NOT NULL REFERENCES core.pedidos (id)        ON DELETE CASCADE,
    estado_pedido_id  INTEGER      REFERENCES core.estados_pedido (id)          ON DELETE RESTRICT,
    descripcion       VARCHAR(400) NOT NULL,
    usuario_id        INTEGER      REFERENCES core.usuarios (id)                ON DELETE RESTRICT,
    creado_en         TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE core.comprobantes_pago (
    id               BIGSERIAL PRIMARY KEY,
    pedido_id        BIGINT       NOT NULL REFERENCES core.pedidos (id)      ON DELETE CASCADE,
    archivo_url      VARCHAR(500) NOT NULL,
    estado_pago_id   INTEGER      NOT NULL REFERENCES core.estados_pago (id) ON DELETE RESTRICT,
    revisado_por_id  INTEGER      REFERENCES core.usuarios (id)              ON DELETE RESTRICT,
    revisado_en      TIMESTAMPTZ,
    creado_en        TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE core.anulaciones (
    id                BIGSERIAL PRIMARY KEY,
    pedido_id         BIGINT       NOT NULL UNIQUE REFERENCES core.pedidos (id) ON DELETE RESTRICT,
    motivo            VARCHAR(300) NOT NULL CHECK (length(trim(motivo)) >= 3),
    usuario_id        INTEGER      REFERENCES core.usuarios (id) ON DELETE RESTRICT,
    jornada_original  DATE         NOT NULL,
    jornada_retorno   DATE         NOT NULL,
    creado_en         TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE core.anulaciones IS 'Auditoría de la anulación de una factura. Una sola por pedido.';

ALTER TABLE core.entradas_inventario
    ADD CONSTRAINT fk_entradas_pedido FOREIGN KEY (pedido_id)
        REFERENCES core.pedidos (id) ON DELETE RESTRICT;


/* ============================================================================
   9. CAJA Y GASTOS
   ============================================================================ */

CREATE TABLE core.bases_caja (
    id               BIGSERIAL PRIMARY KEY,
    unidad_id        INTEGER       NOT NULL REFERENCES core.unidades (id) ON DELETE RESTRICT,
    fecha_operativa  DATE          NOT NULL,
    monto            NUMERIC(12,2) NOT NULL CHECK (monto >= 0),
    vigente          BOOLEAN       NOT NULL DEFAULT TRUE,
    reemplaza_a_id   BIGINT        REFERENCES core.bases_caja (id) ON DELETE RESTRICT,
    observacion      VARCHAR(300),
    usuario_id       INTEGER       REFERENCES core.usuarios (id) ON DELETE RESTRICT,
    creado_en        TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE core.bases_caja IS 'La base no se edita: una corrección crea otra fila y la anterior deja de estar vigente.';
CREATE UNIQUE INDEX uq_bases_caja_vigente ON core.bases_caja (unidad_id, fecha_operativa) WHERE vigente;

CREATE TABLE core.categorias_gasto (
    id          SERIAL PRIMARY KEY,
    empresa_id  INTEGER     NOT NULL REFERENCES core.empresas (id) ON DELETE RESTRICT,
    nombre      VARCHAR(80) NOT NULL,
    icono       VARCHAR(8),
    activa      BOOLEAN     NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_categorias_gasto UNIQUE (empresa_id, nombre)
);

CREATE TABLE core.gastos (
    id                  BIGSERIAL PRIMARY KEY,
    unidad_id           INTEGER       NOT NULL REFERENCES core.unidades (id)         ON DELETE RESTRICT,
    categoria_gasto_id  INTEGER       NOT NULL REFERENCES core.categorias_gasto (id) ON DELETE RESTRICT,
    metodo_pago_id      INTEGER       NOT NULL REFERENCES core.metodos_pago (id)     ON DELETE RESTRICT,
    estado_gasto_id     INTEGER       NOT NULL REFERENCES core.estados_gasto (id)    ON DELETE RESTRICT,
    fecha_operativa     DATE          NOT NULL,
    descripcion         VARCHAR(300)  NOT NULL,
    monto               NUMERIC(12,2) NOT NULL CHECK (monto > 0),
    motivo_anulacion    VARCHAR(300),
    registrado_por_id   INTEGER       REFERENCES core.usuarios (id) ON DELETE RESTRICT,
    confirmado_por_id   INTEGER       REFERENCES core.usuarios (id) ON DELETE RESTRICT,
    anulado_por_id      INTEGER       REFERENCES core.usuarios (id) ON DELETE RESTRICT,
    creado_en           TIMESTAMPTZ   NOT NULL DEFAULT now(),
    actualizado_en      TIMESTAMPTZ   NOT NULL DEFAULT now()
);


/* ============================================================================
   10. AUDITORÍA
   ============================================================================ */

CREATE TABLE core.auditoria (
    id             BIGSERIAL PRIMARY KEY,
    tabla          VARCHAR(63)  NOT NULL,
    registro_id    BIGINT,
    accion         VARCHAR(10)  NOT NULL CHECK (accion IN ('INSERT', 'UPDATE', 'DELETE')),
    datos_antes    JSONB,
    datos_despues  JSONB,
    usuario_id     INTEGER,
    usuario_db     VARCHAR(63)  NOT NULL DEFAULT current_user,
    creado_en      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE core.auditoria IS 'Quién cambió qué y cuándo en las tablas sensibles. Sin FK a usuarios a propósito: la auditoría sobrevive a todo.';


/* ============================================================================
   11. ÍNDICES
   Las UNIQUE ya crean su índice. Aquí van las FK y los filtros frecuentes.
   ============================================================================ */

CREATE INDEX ix_permisos_modulo            ON core.permisos (modulo_id);
CREATE INDEX ix_rol_permisos_permiso       ON core.rol_permisos (permiso_id);
CREATE INDEX ix_empresa_modulos_modulo     ON core.empresa_modulos (modulo_id);
CREATE INDEX ix_empresa_metodos_metodo     ON core.empresa_metodos_pago (metodo_pago_id);
CREATE INDEX ix_unidades_tipo              ON core.unidades (tipo_negocio_id);
CREATE INDEX ix_unidades_empresa_estado    ON core.unidades (empresa_id, estado);
CREATE INDEX ix_usuarios_empresa           ON core.usuarios (empresa_id);
CREATE INDEX ix_usuarios_rol               ON core.usuarios (rol_id);
CREATE INDEX ix_usuario_unidades_unidad    ON core.usuario_unidades (unidad_id);
CREATE INDEX ix_categoria_unidades_unidad  ON core.categoria_unidades (unidad_id);
CREATE INDEX ix_productos_categoria        ON core.productos (categoria_id);
CREATE INDEX ix_productos_etiqueta         ON core.productos (etiqueta_id);
CREATE INDEX ix_producto_unidades_unidad   ON core.producto_unidades (unidad_id);
CREATE INDEX ix_insumos_categoria          ON core.insumos (categoria_insumo_id);
CREATE INDEX ix_insumos_area               ON core.insumos (area_id);
CREATE INDEX ix_insumos_medida             ON core.insumos (unidad_medida_id);
CREATE INDEX ix_insumo_unidades_unidad     ON core.insumo_unidades (unidad_id);
CREATE INDEX ix_producto_insumos_insumo    ON core.producto_insumos (insumo_id);
CREATE INDEX ix_cierres_estado             ON core.cierres_inventario (estado_cierre_id);
CREATE INDEX ix_cierres_area               ON core.cierres_inventario (area_id);
CREATE INDEX ix_cierre_detalles_insumo     ON core.cierre_detalles (insumo_unidad_id);
CREATE INDEX ix_entradas_insumo_fecha      ON core.entradas_inventario (insumo_unidad_id, fecha_operativa);
CREATE INDEX ix_entradas_tipo              ON core.entradas_inventario (tipo_entrada_id);
CREATE INDEX ix_entradas_pedido            ON core.entradas_inventario (pedido_id) WHERE pedido_id IS NOT NULL;
CREATE INDEX ix_menus_dia_tipo             ON core.menus_dia (tipo_menu_id);
CREATE INDEX ix_menu_categorias_menu       ON core.menu_categorias (menu_dia_id);
CREATE INDEX ix_menu_opciones_categoria    ON core.menu_opciones (menu_categoria_id);
CREATE INDEX ix_platos_dia_menu            ON core.platos_dia (menu_dia_id);
CREATE INDEX ix_pedidos_unidad_fecha       ON core.pedidos (unidad_id, fecha_operativa);
CREATE INDEX ix_pedidos_estado             ON core.pedidos (estado_pedido_id);
CREATE INDEX ix_pedidos_estado_pago        ON core.pedidos (estado_pago_id);
CREATE INDEX ix_pedidos_metodo             ON core.pedidos (metodo_pago_id);
CREATE INDEX ix_pedidos_tipo               ON core.pedidos (tipo_pedido_id);
CREATE INDEX ix_pedidos_cliente            ON core.pedidos (cliente_id);
CREATE INDEX ix_pedidos_mesa               ON core.pedidos (mesa_id);
CREATE INDEX ix_pedidos_zona               ON core.pedidos (zona_domicilio_id);
CREATE INDEX ix_pedidos_empresa_fecha      ON core.pedidos (empresa_id, fecha_operativa);
CREATE INDEX ix_pedido_items_pedido        ON core.pedido_items (pedido_id);
CREATE INDEX ix_pedido_items_producto      ON core.pedido_items (producto_id) WHERE producto_id IS NOT NULL;
CREATE INDEX ix_pedido_items_plato         ON core.pedido_items (plato_dia_id) WHERE plato_dia_id IS NOT NULL;
CREATE INDEX ix_pedido_items_menu          ON core.pedido_items (menu_dia_id) WHERE menu_dia_id IS NOT NULL;
CREATE INDEX ix_item_opciones_opcion       ON core.pedido_item_opciones (menu_opcion_id);
CREATE INDEX ix_historial_pedido           ON core.pedido_historial (pedido_id, creado_en);
CREATE INDEX ix_comprobantes_pedido        ON core.comprobantes_pago (pedido_id);
CREATE INDEX ix_bases_caja_unidad_fecha    ON core.bases_caja (unidad_id, fecha_operativa);
CREATE INDEX ix_gastos_unidad_fecha        ON core.gastos (unidad_id, fecha_operativa);
CREATE INDEX ix_gastos_categoria           ON core.gastos (categoria_gasto_id);
CREATE INDEX ix_gastos_estado              ON core.gastos (estado_gasto_id);
CREATE INDEX ix_gastos_metodo              ON core.gastos (metodo_pago_id);
CREATE INDEX ix_auditoria_tabla_registro   ON core.auditoria (tabla, registro_id);
CREATE INDEX ix_auditoria_fecha            ON core.auditoria (creado_en);
