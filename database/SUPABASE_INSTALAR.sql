/* ============================================================================
   TASECA · LA BASE COMPLETA, EN UN SOLO ARCHIVO (para Supabase)
   ----------------------------------------------------------------------------
   Crea todo: tablas, funciones, triggers, procedimientos, vistas, catálogos,
   la estructura de ejemplo de NASCAR, la capa REST, la fase 2 completa, el
   chequeo de integridad y la seguridad a nivel de fila.

   GENERADO, NO SE EDITA A MANO. Sale de pegar los scripts 01 … 19 con
   `py database/generar_supabase.py`. Si hay que corregir algo, se corrige en
   el script original y se vuelve a generar.

   CÓMO EJECUTARLO

     Opción A · editor SQL de Supabase
       Pega el contenido y dale a RUN. Tarda un par de minutos. Cuando
       pregunte por RLS, responde «Ejecuta y habilita RLS» (este archivo la
       enciende igual al final).

     Opción B · desde tu computador, más cómodo para un archivo grande
       psql "postgresql://postgres:TU-CONTRASEÑA@db.TU-PROYECTO.supabase.co:5432/postgres" \
            -v ON_ERROR_STOP=1 -f database/SUPABASE_INSTALAR.sql

   SOBRE UNA BASE VACÍA. Si ya instalaste antes, primero hay que borrar:

       DROP SCHEMA IF EXISTS rest CASCADE;
       DROP SCHEMA IF EXISTS api  CASCADE;
       DROP SCHEMA IF EXISTS core CASCADE;

   QUÉ QUEDA PENDIENTE, A MANO, DESPUÉS

     · Si vas a usar NUESTRO PostgREST (recomendado, ver postgrest-nube/):
         ALTER ROLE taseca_rest LOGIN PASSWORD 'una-contraseña-larga';
       y nada más: la base firma sus tokens y PostgREST los valida con el
       secreto que ella misma guarda.

     · Si en cambio vas a usar el Data API de Supabase:
         1. Settings → API → Exposed schemas: agregar «rest».
         2. Pegar el JWT secret del proyecto en core.jwt_config (al final de
            este archivo está la sentencia, comentada).
       Ojo: en los proyectos nuevos las claves son asimétricas (ES256) y
       PostgreSQL no puede firmar así, de modo que el ingreso no funcionará.
       Está explicado en database/README.md.

   Los datos de ejemplo de NASCAR están marcados dentro del bloque 06 por si
   quieres una plataforma vacía: se borra ese tramo y los catálogos se quedan.
   ============================================================================ */

/* ---- Que no se ejecute dos veces por accidente ---- */
DO $arranque$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'core') THEN
        RAISE EXCEPTION 'Ya hay una instalación de Taseca en esta base. Para empezar de cero, borra los esquemas rest, api y core (ver la cabecera de este archivo).';
    END IF;
    RAISE NOTICE 'Instalando Taseca…';
END;
$arranque$;



/* ============================================================================
   0 · FUNCIONES DE CIFRADO
   pgcrypto vive en otro esquema en Supabase: se deja un atajo en public
   ============================================================================ */

/* ============================================================================
   1. FUNCIONES DE CIFRADO (pgcrypto)

   En una instalación normal pgcrypto vive en `public`. Supabase lo instala en
   `extensions`, así que `public.crypt(...)` no existiría y el login fallaría.
   En vez de mover la extensión —de la que dependen cosas internas de
   Supabase— se dejan en `public` atajos que llaman a donde esté: los tres
   del PIN (crypt, gen_salt, gen_random_bytes) y los dos de la firma de los
   tokens (hmac, digest).
   ============================================================================ */

DO $$
DECLARE
    v_esquema TEXT;
BEGIN
    SELECT n.nspname INTO v_esquema
      FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
     WHERE e.extname = 'pgcrypto';

    IF v_esquema IS NULL THEN
        -- Aún no está instalada: se instala en public y no hacen falta atajos
        CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;
        RAISE NOTICE 'pgcrypto instalada en public.';
        RETURN;
    END IF;

    IF v_esquema = 'public' THEN
        RAISE NOTICE 'pgcrypto ya está en public: no hacen falta atajos.';
        RETURN;
    END IF;

    EXECUTE format($f$
        CREATE OR REPLACE FUNCTION public.crypt(TEXT, TEXT) RETURNS TEXT
        LANGUAGE sql IMMUTABLE STRICT AS 'SELECT %I.crypt($1, $2)';
    $f$, v_esquema);

    EXECUTE format($f$
        CREATE OR REPLACE FUNCTION public.gen_salt(TEXT, INTEGER) RETURNS TEXT
        LANGUAGE sql VOLATILE STRICT AS 'SELECT %I.gen_salt($1, $2)';
    $f$, v_esquema);

    EXECUTE format($f$
        CREATE OR REPLACE FUNCTION public.gen_random_bytes(INTEGER) RETURNS BYTEA
        LANGUAGE sql VOLATILE STRICT AS 'SELECT %I.gen_random_bytes($1)';
    $f$, v_esquema);

    -- Firma de los tokens (core.fn_jwt_firmar)
    EXECUTE format($f$
        CREATE OR REPLACE FUNCTION public.hmac(BYTEA, BYTEA, TEXT) RETURNS BYTEA
        LANGUAGE sql IMMUTABLE STRICT AS 'SELECT %I.hmac($1, $2, $3)';
    $f$, v_esquema);

    EXECUTE format($f$
        CREATE OR REPLACE FUNCTION public.digest(BYTEA, TEXT) RETURNS BYTEA
        LANGUAGE sql IMMUTABLE STRICT AS 'SELECT %I.digest($1, $2)';
    $f$, v_esquema);

    RAISE NOTICE 'Atajos de pgcrypto creados en public (la extensión vive en %).', v_esquema;
END;
$$;




/* ============================================================================
   01_ESTRUCTURA
   Esquemas, tablas, llaves e índices
   ============================================================================ */

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


/* ============================================================================
   02_FUNCIONES
   Funciones internas: jornada, consecutivos, permisos, PIN
   ============================================================================ */

/* ============================================================================
   TASECA · 02 · FUNCIONES INTERNAS (esquema core)
   ----------------------------------------------------------------------------
   Piezas pequeñas que usan los triggers, los procedimientos y las vistas.
   La aplicación no las llama directamente.
   ============================================================================ */

SET search_path = core, public;


/* ---------------------------------------------------------------------------
   Usuario de la operación en curso
   Los procedimientos de api fijan `taseca.usuario_id` para la transacción;
   así los triggers de auditoría e historial saben quién hizo el cambio sin
   pedirlo en cada tabla.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.fn_usuario_actual()
RETURNS INTEGER
LANGUAGE sql STABLE
AS $$
    SELECT NULLIF(current_setting('taseca.usuario_id', TRUE), '')::INTEGER;
$$;

CREATE OR REPLACE FUNCTION core.fn_fijar_usuario(p_usuario_id INTEGER)
RETURNS VOID
LANGUAGE sql
AS $$
    SELECT set_config('taseca.usuario_id', COALESCE(p_usuario_id::TEXT, ''), TRUE);
$$;


/* ---------------------------------------------------------------------------
   Búsqueda de ids de catálogo por código
   Los procedimientos reciben códigos legibles ('entregado', 'efectivo') y
   las tablas guardan ids. Si el código no existe, error claro.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.fn_id_catalogo(p_tabla TEXT, p_codigo TEXT)
RETURNS INTEGER
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_id INTEGER;
BEGIN
    IF p_tabla NOT IN ('modulos', 'tipos_negocio', 'roles', 'permisos', 'metodos_pago',
                       'tipos_pedido', 'estados_pedido', 'estados_pago', 'estados_gasto',
                       'estados_cierre', 'tipos_entrada', 'areas_inventario',
                       'unidades_medida', 'etiquetas_producto', 'tipos_menu') THEN
        RAISE EXCEPTION 'Catálogo no permitido: %', p_tabla;
    END IF;

    EXECUTE format('SELECT id FROM core.%I WHERE codigo = $1', p_tabla)
       INTO v_id USING p_codigo;

    IF v_id IS NULL THEN
        RAISE EXCEPTION 'No existe "%" en el catálogo %.', p_codigo, p_tabla
              USING ERRCODE = 'no_data_found';
    END IF;
    RETURN v_id;
END;
$$;


/* ---------------------------------------------------------------------------
   Jornada operativa
   La jornada empieza a la hora de corte de la empresa: con corte a las 6,
   una venta a la 01:30 del 29 pertenece al día 28.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.fn_fecha_operativa(p_empresa_id INTEGER, p_momento TIMESTAMPTZ DEFAULT now())
RETURNS DATE
LANGUAGE sql STABLE
AS $$
    SELECT ((p_momento AT TIME ZONE e.zona_horaria) - make_interval(hours => e.hora_corte_operativa))::DATE
      FROM core.empresas e
     WHERE e.id = p_empresa_id;
$$;


/* ---------------------------------------------------------------------------
   Consecutivo de facturas: 00001, 00002…
   UPDATE … RETURNING bloquea la fila de la empresa: dos pedidos simultáneos
   nunca reciben el mismo número. Si el número ya existiera (datos migrados)
   se salta al siguiente libre.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.fn_siguiente_codigo_pedido(p_empresa_id INTEGER)
RETURNS VARCHAR
LANGUAGE plpgsql
AS $$
DECLARE
    v_numero  INTEGER;
    v_digitos SMALLINT;
    v_codigo  VARCHAR;
BEGIN
    INSERT INTO core.consecutivos (empresa_id, tipo)
    VALUES (p_empresa_id, 'pedido')
    ON CONFLICT (empresa_id, tipo) DO NOTHING;

    LOOP
        UPDATE core.consecutivos
           SET ultimo_numero = ultimo_numero + 1
         WHERE empresa_id = p_empresa_id AND tipo = 'pedido'
        RETURNING ultimo_numero, digitos INTO v_numero, v_digitos;

        v_codigo := lpad(v_numero::TEXT, GREATEST(v_digitos, length(v_numero::TEXT)), '0');

        EXIT WHEN NOT EXISTS (
            SELECT 1 FROM core.pedidos WHERE empresa_id = p_empresa_id AND codigo = v_codigo
        );
    END LOOP;

    RETURN v_codigo;
END;
$$;

/* El cliente escribe "27", "#27" o "00027": todos son la factura 00027. */
CREATE OR REPLACE FUNCTION core.fn_normalizar_codigo_pedido(p_empresa_id INTEGER, p_codigo TEXT)
RETURNS VARCHAR
LANGUAGE sql STABLE
AS $$
    SELECT CASE
             WHEN regexp_replace(upper(trim(p_codigo)), '^#', '') ~ '^[0-9]+$'
             THEN lpad(regexp_replace(trim(p_codigo), '^#', ''),
                       COALESCE((SELECT digitos FROM core.consecutivos
                                  WHERE empresa_id = p_empresa_id AND tipo = 'pedido'), 5),
                       '0')
             ELSE regexp_replace(upper(trim(p_codigo)), '^#', '')
           END;
$$;


/* ---------------------------------------------------------------------------
   PIN
   bcrypt con sal propia. La comparación se hace re-cifrando con el hash
   guardado: el PIN nunca se desencripta porque no se puede.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.fn_hash_pin(p_pin TEXT)
RETURNS TEXT
LANGUAGE plpgsql VOLATILE
AS $$
BEGIN
    IF p_pin IS NULL OR p_pin !~ '^[0-9]{4,8}$' THEN
        RAISE EXCEPTION 'El PIN debe tener entre 4 y 8 dígitos.';
    END IF;
    RETURN public.crypt(p_pin, public.gen_salt('bf', 8));
END;
$$;

CREATE OR REPLACE FUNCTION core.fn_pin_valido(p_pin TEXT, p_hash TEXT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT p_hash IS NOT NULL AND public.crypt(p_pin, p_hash) = p_hash;
$$;


/* ---------------------------------------------------------------------------
   Módulos y permisos
   Una persona puede hacer algo si su ROL tiene el permiso Y su EMPRESA
   contrató el módulo del que depende. Los usuarios de plataforma no
   dependen de módulos.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.fn_empresa_tiene_modulo(p_empresa_id INTEGER, p_modulo TEXT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
          FROM core.empresa_modulos em
          JOIN core.modulos m ON m.id = em.modulo_id
         WHERE em.empresa_id = p_empresa_id
           AND m.codigo = p_modulo
           AND (em.activo OR m.obligatorio)
    );
$$;

CREATE OR REPLACE FUNCTION core.fn_tiene_permiso(p_usuario_id INTEGER, p_permiso TEXT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
          FROM core.usuarios u
          JOIN core.roles r         ON r.id = u.rol_id
          JOIN core.rol_permisos rp ON rp.rol_id = r.id
          JOIN core.permisos p      ON p.id = rp.permiso_id
          LEFT JOIN core.modulos m  ON m.id = p.modulo_id
         WHERE u.id = p_usuario_id
           AND u.activo
           AND p.codigo = p_permiso
           AND (
                 r.alcance = 'plataforma'
              OR m.id IS NULL
              OR core.fn_empresa_tiene_modulo(u.empresa_id, m.codigo)
           )
    );
$$;

/* Lanza un error si el usuario no puede. Sin usuario (NULL) se permite:
   es la carga de datos inicial y la consola del DBA, igual que en el MVP. */
CREATE OR REPLACE FUNCTION core.fn_exigir_permiso(p_usuario_id INTEGER, p_permiso TEXT)
RETURNS VOID
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    IF p_usuario_id IS NOT NULL AND NOT core.fn_tiene_permiso(p_usuario_id, p_permiso) THEN
        RAISE EXCEPTION 'El usuario % no tiene el permiso "%".', p_usuario_id, p_permiso
              USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$$;

/* ¿El usuario trabaja en esta unidad? Sin unidades asignadas = todas las de
   su empresa. Los usuarios de plataforma, todas. */
CREATE OR REPLACE FUNCTION core.fn_usuario_en_unidad(p_usuario_id INTEGER, p_unidad_id INTEGER)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT p_usuario_id IS NULL
        OR EXISTS (
            SELECT 1
              FROM core.usuarios u
              JOIN core.roles r    ON r.id = u.rol_id
              JOIN core.unidades d ON d.id = p_unidad_id
             WHERE u.id = p_usuario_id
               AND (   r.alcance = 'plataforma'
                    OR (u.empresa_id = d.empresa_id
                        AND (NOT EXISTS (SELECT 1 FROM core.usuario_unidades x WHERE x.usuario_id = u.id)
                             OR EXISTS (SELECT 1 FROM core.usuario_unidades x
                                         WHERE x.usuario_id = u.id AND x.unidad_id = p_unidad_id))))
        );
$$;


/* ---------------------------------------------------------------------------
   Unidades
   --------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.fn_empresa_de_unidad(p_unidad_id INTEGER)
RETURNS INTEGER
LANGUAGE sql STABLE
AS $$
    SELECT empresa_id FROM core.unidades WHERE id = p_unidad_id;
$$;

/* Una unidad inactiva conserva su historia pero no admite operación nueva. */
CREATE OR REPLACE FUNCTION core.fn_exigir_unidad_operativa(p_unidad_id INTEGER)
RETURNS VOID
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_nombre  VARCHAR;
    v_estado  VARCHAR;
    v_empresa VARCHAR;
BEGIN
    SELECT u.nombre, u.estado, e.estado
      INTO v_nombre, v_estado, v_empresa
      FROM core.unidades u
      JOIN core.empresas e ON e.id = u.empresa_id
     WHERE u.id = p_unidad_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La unidad % no existe.', p_unidad_id;
    ELSIF v_estado <> 'activa' THEN
        RAISE EXCEPTION 'La unidad "%" está inactiva: no admite operación nueva. Su información histórica se conserva.', v_nombre;
    ELSIF v_empresa <> 'activa' THEN
        RAISE EXCEPTION 'La empresa de la unidad "%" no está activa.', v_nombre;
    END IF;
END;
$$;


/* ---------------------------------------------------------------------------
   Pedidos: cálculos
   --------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.fn_subtotal_pedido(p_pedido_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(SUM(precio_unitario * cantidad), 0)
      FROM core.pedido_items
     WHERE pedido_id = p_pedido_id;
$$;

/* Cuántas unidades de un plato del chef ya se vendieron (sin cancelados ni
   anulados). Los cupos restantes salen de aquí: no se guarda un contador
   que pueda desincronizarse. */
CREATE OR REPLACE FUNCTION core.fn_vendidos_plato(p_plato_dia_id BIGINT)
RETURNS INTEGER
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(SUM(i.cantidad), 0)::INTEGER
      FROM core.pedido_items i
      JOIN core.pedidos p        ON p.id = i.pedido_id
      JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
     WHERE i.plato_dia_id = p_plato_dia_id
       AND e.cuenta_como_venta;
$$;

/* Siguiente estado del flujo según el tipo de pedido: una mesa no pasa por
   «en camino». NULL si ya está en el último. */
CREATE OR REPLACE FUNCTION core.fn_siguiente_estado(p_pedido_id BIGINT)
RETURNS INTEGER
LANGUAGE sql STABLE
AS $$
    SELECT sig.id
      FROM core.pedidos p
      JOIN core.tipos_pedido t   ON t.id = p.tipo_pedido_id
      JOIN core.estados_pedido a ON a.id = p.estado_pedido_id
      JOIN LATERAL (
            SELECT e.id
              FROM core.estados_pedido e
             WHERE e.orden > a.orden
               AND e.orden < 90
               AND (NOT e.solo_domicilio OR t.codigo = 'domicilio')
             ORDER BY e.orden
             LIMIT 1
      ) sig ON TRUE
     WHERE p.id = p_pedido_id
       AND a.orden < 90;
$$;


/* ============================================================================
   03_TRIGGERS
   Reglas del negocio que la base hace cumplir sola
   ============================================================================ */

/* ============================================================================
   TASECA · 03 · TRIGGERS
   ----------------------------------------------------------------------------
   Las reglas del negocio viven en la base, no sólo en la pantalla: aunque
   alguien escriba directo en la tabla, la regla se cumple.

     · actualizado_en automático
     · auditoría de las tablas sensibles
     · aislamiento multiempresa (nada se cruza entre empresas)
     · unidad inactiva = sin operación nueva; nunca sin unidades activas
     · pedidos: código, jornada, flujo de estados, historial, inmutabilidad
     · ítems: producto de la unidad, cupos, menú armado con su máximo
     · cierres revisados intocables; entradas que suman al stock
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. GENÉRICOS
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.tg_actualizado_en()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.actualizado_en := now();
    RETURN NEW;
END;
$$;

DO $$
DECLARE
    t RECORD;
BEGIN
    FOR t IN
        SELECT c.table_name
          FROM information_schema.columns c
          JOIN information_schema.tables tb
            ON tb.table_schema = c.table_schema AND tb.table_name = c.table_name
         WHERE c.table_schema = 'core'
           AND c.column_name = 'actualizado_en'
           AND tb.table_type = 'BASE TABLE'
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%1$s_actualizado_en BEFORE UPDATE ON core.%1$I
                 FOR EACH ROW EXECUTE FUNCTION core.tg_actualizado_en()', t.table_name);
    END LOOP;
END;
$$;


/* Auditoría: guarda la fila antes y después. Del usuario nunca se guarda el
   hash del PIN. */
CREATE OR REPLACE FUNCTION core.tg_auditoria()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_antes   JSONB;
    v_despues JSONB;
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN v_antes   := to_jsonb(OLD) - 'pin_hash'; END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN v_despues := to_jsonb(NEW) - 'pin_hash'; END IF;

    IF TG_OP = 'UPDATE' AND v_antes - 'actualizado_en' = v_despues - 'actualizado_en' THEN
        RETURN NEW; -- nada cambió de verdad
    END IF;

    INSERT INTO core.auditoria (tabla, registro_id, accion, datos_antes, datos_despues, usuario_id)
    VALUES (TG_TABLE_NAME,
            COALESCE((v_despues ->> 'id'), (v_antes ->> 'id'))::BIGINT,
            TG_OP, v_antes, v_despues, core.fn_usuario_actual());

    RETURN COALESCE(NEW, OLD);
END;
$$;

DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['empresas', 'empresa_modulos', 'unidades', 'usuarios', 'productos',
                             'insumo_unidades', 'pedidos', 'anulaciones', 'gastos', 'bases_caja',
                             'cierres_inventario', 'entradas_inventario', 'rol_permisos']
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%1$s_auditoria AFTER INSERT OR UPDATE OR DELETE ON core.%1$I
                 FOR EACH ROW EXECUTE FUNCTION core.tg_auditoria()', t);
    END LOOP;
END;
$$;


/* ============================================================================
   2. AISLAMIENTO MULTIEMPRESA
   Las tablas de relación unen cosas que deben ser de la MISMA empresa: una
   categoría de NASCAR no puede asignarse a una unidad de otra empresa.
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.tg_misma_empresa()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_a INTEGER;
    v_b INTEGER;
BEGIN
    CASE TG_TABLE_NAME
        WHEN 'categoria_unidades' THEN
            SELECT empresa_id INTO v_a FROM core.categorias WHERE id = NEW.categoria_id;
            v_b := core.fn_empresa_de_unidad(NEW.unidad_id);
        WHEN 'producto_unidades' THEN
            SELECT empresa_id INTO v_a FROM core.productos WHERE id = NEW.producto_id;
            v_b := core.fn_empresa_de_unidad(NEW.unidad_id);
        WHEN 'insumo_unidades' THEN
            SELECT empresa_id INTO v_a FROM core.insumos WHERE id = NEW.insumo_id;
            v_b := core.fn_empresa_de_unidad(NEW.unidad_id);
        WHEN 'usuario_unidades' THEN
            SELECT empresa_id INTO v_a FROM core.usuarios WHERE id = NEW.usuario_id;
            v_b := core.fn_empresa_de_unidad(NEW.unidad_id);
        WHEN 'productos' THEN
            v_a := NEW.empresa_id;
            SELECT empresa_id INTO v_b FROM core.categorias WHERE id = NEW.categoria_id;
        WHEN 'insumos' THEN
            v_a := NEW.empresa_id;
            SELECT empresa_id INTO v_b FROM core.categorias_insumo WHERE id = NEW.categoria_insumo_id;
        WHEN 'producto_insumos' THEN
            SELECT empresa_id INTO v_a FROM core.productos WHERE id = NEW.producto_id;
            SELECT empresa_id INTO v_b FROM core.insumos   WHERE id = NEW.insumo_id;
        WHEN 'gastos' THEN
            v_a := core.fn_empresa_de_unidad(NEW.unidad_id);
            SELECT empresa_id INTO v_b FROM core.categorias_gasto WHERE id = NEW.categoria_gasto_id;
        ELSE
            RAISE EXCEPTION 'tg_misma_empresa no está preparado para %', TG_TABLE_NAME;
    END CASE;

    IF v_a IS DISTINCT FROM v_b THEN
        RAISE EXCEPTION 'En % se intentó unir registros de empresas distintas (% y %).',
                        TG_TABLE_NAME, v_a, v_b
              USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END;
$$;

DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['categoria_unidades', 'producto_unidades', 'insumo_unidades',
                             'usuario_unidades', 'productos', 'insumos', 'producto_insumos', 'gastos']
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%1$s_misma_empresa BEFORE INSERT OR UPDATE ON core.%1$I
                 FOR EACH ROW EXECUTE FUNCTION core.tg_misma_empresa()', t);
    END LOOP;
END;
$$;


/* ============================================================================
   3. USUARIOS Y UNIDADES
   ============================================================================ */

/* Un usuario de plataforma no pertenece a ninguna empresa; uno de empresa
   siempre pertenece a una. */
CREATE OR REPLACE FUNCTION core.tg_usuarios_alcance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_alcance VARCHAR;
BEGIN
    SELECT alcance INTO v_alcance FROM core.roles WHERE id = NEW.rol_id;
    IF v_alcance = 'plataforma' AND NEW.empresa_id IS NOT NULL THEN
        RAISE EXCEPTION 'Un usuario de plataforma no pertenece a ninguna empresa.';
    ELSIF v_alcance = 'empresa' AND NEW.empresa_id IS NULL THEN
        RAISE EXCEPTION 'El usuario "%" necesita una empresa.', NEW.usuario;
    END IF;
    NEW.usuario := lower(trim(NEW.usuario));
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_usuarios_alcance
    BEFORE INSERT OR UPDATE OF rol_id, empresa_id, usuario ON core.usuarios
    FOR EACH ROW EXECUTE FUNCTION core.tg_usuarios_alcance();

/* Siempre debe quedar al menos una unidad activa en una empresa activa. */
CREATE OR REPLACE FUNCTION core.tg_unidades_minimo_activa()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.estado = 'activa' AND NEW.estado = 'inactiva'
       AND NOT EXISTS (SELECT 1 FROM core.unidades
                        WHERE empresa_id = NEW.empresa_id AND estado = 'activa' AND id <> NEW.id) THEN
        RAISE EXCEPTION 'Debe quedar al menos una unidad activa en la empresa.';
    END IF;
    IF NEW.empresa_id <> OLD.empresa_id THEN
        RAISE EXCEPTION 'Una unidad no puede cambiar de empresa.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_unidades_minimo_activa
    BEFORE UPDATE ON core.unidades
    FOR EACH ROW EXECUTE FUNCTION core.tg_unidades_minimo_activa();


/* ============================================================================
   4. PEDIDOS
   ============================================================================ */

/* Antes de crear: empresa de la unidad, código, jornada, estados iniciales y
   coherencia de mesa / zona según el tipo. */
CREATE OR REPLACE FUNCTION core.tg_pedidos_antes_insertar()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_tipo    VARCHAR;
    v_empresa INTEGER;
BEGIN
    PERFORM core.fn_exigir_unidad_operativa(NEW.unidad_id);   -- inactiva = sin pedidos nuevos
    v_empresa := core.fn_empresa_de_unidad(NEW.unidad_id);

    IF NEW.empresa_id IS NULL THEN
        NEW.empresa_id := v_empresa;
    ELSIF NEW.empresa_id <> v_empresa THEN
        RAISE EXCEPTION 'La unidad % no pertenece a la empresa %.', NEW.unidad_id, NEW.empresa_id;
    END IF;

    NEW.codigo           := COALESCE(NEW.codigo, core.fn_siguiente_codigo_pedido(NEW.empresa_id));
    NEW.fecha_operativa  := COALESCE(NEW.fecha_operativa, core.fn_fecha_operativa(NEW.empresa_id, now()));
    NEW.estado_pedido_id := COALESCE(NEW.estado_pedido_id, core.fn_id_catalogo('estados_pedido', 'nuevo'));
    NEW.estado_pago_id   := COALESCE(NEW.estado_pago_id,   core.fn_id_catalogo('estados_pago', 'pendiente'));

    SELECT codigo INTO v_tipo FROM core.tipos_pedido WHERE id = NEW.tipo_pedido_id;

    IF v_tipo = 'mesa' THEN
        IF NEW.mesa_id IS NULL THEN
            RAISE EXCEPTION 'Un pedido de mesa necesita la mesa.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM core.mesas WHERE id = NEW.mesa_id AND unidad_id = NEW.unidad_id) THEN
            RAISE EXCEPTION 'La mesa % no es de la unidad %.', NEW.mesa_id, NEW.unidad_id;
        END IF;
        NEW.zona_domicilio_id := NULL;
        NEW.costo_domicilio   := 0;
    ELSIF v_tipo = 'domicilio' THEN
        IF NEW.cliente_id IS NULL OR NEW.direccion_entrega IS NULL OR length(trim(NEW.direccion_entrega)) < 8 THEN
            RAISE EXCEPTION 'Un domicilio necesita cliente y dirección completa.';
        END IF;
        NEW.mesa_id := NULL;

        -- Zona: obligatoria sólo si la unidad tiene zonas activas
        IF NEW.zona_domicilio_id IS NULL THEN
            IF EXISTS (SELECT 1 FROM core.zonas_domicilio WHERE unidad_id = NEW.unidad_id AND activa) THEN
                RAISE EXCEPTION 'Selecciona la zona de entrega.';
            END IF;
            NEW.costo_domicilio := 0;
        ELSE
            SELECT z.costo INTO NEW.costo_domicilio
              FROM core.zonas_domicilio z
             WHERE z.id = NEW.zona_domicilio_id AND z.unidad_id = NEW.unidad_id AND z.activa;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'La zona % no es una zona activa de la unidad %.', NEW.zona_domicilio_id, NEW.unidad_id;
            END IF;
        END IF;
    END IF;

    IF NEW.cliente_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM core.clientes WHERE id = NEW.cliente_id AND empresa_id = NEW.empresa_id) THEN
        RAISE EXCEPTION 'El cliente no es de esta empresa.';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pedidos_antes_insertar
    BEFORE INSERT ON core.pedidos
    FOR EACH ROW EXECUTE FUNCTION core.tg_pedidos_antes_insertar();


/* Historial al crear. */
CREATE OR REPLACE FUNCTION core.tg_pedidos_despues_insertar()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO core.pedido_historial (pedido_id, estado_pedido_id, descripcion, usuario_id)
    VALUES (NEW.id, NEW.estado_pedido_id, 'Pedido recibido', core.fn_usuario_actual());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pedidos_despues_insertar
    AFTER INSERT ON core.pedidos
    FOR EACH ROW EXECUTE FUNCTION core.tg_pedidos_despues_insertar();


/* Antes de modificar:
     · los datos de identidad de la factura no cambian nunca
     · cancelado y anulado son finales: ya no se toca nada
     · el flujo sólo avanza (no se devuelve), «en camino» sólo en domicilio
     · entregado sólo admite pasar a anulado o cambiar el estado del pago
     · al entregar en efectivo, el pago queda confirmado */
CREATE OR REPLACE FUNCTION core.tg_pedidos_antes_actualizar()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_ant   core.estados_pedido;
    v_nuevo core.estados_pedido;
    v_tipo  VARCHAR;
BEGIN
    IF NEW.empresa_id <> OLD.empresa_id OR NEW.unidad_id <> OLD.unidad_id
       OR NEW.codigo <> OLD.codigo OR NEW.fecha_operativa <> OLD.fecha_operativa
       OR NEW.tipo_pedido_id <> OLD.tipo_pedido_id OR NEW.creado_en <> OLD.creado_en THEN
        RAISE EXCEPTION 'La factura % no puede cambiar de empresa, unidad, código, tipo ni jornada.', OLD.codigo;
    END IF;

    SELECT * INTO v_ant   FROM core.estados_pedido WHERE id = OLD.estado_pedido_id;
    SELECT * INTO v_nuevo FROM core.estados_pedido WHERE id = NEW.estado_pedido_id;
    SELECT codigo INTO v_tipo FROM core.tipos_pedido WHERE id = NEW.tipo_pedido_id;

    IF v_ant.codigo IN ('cancelado', 'anulado') THEN
        RAISE EXCEPTION 'La factura % está % y ya no se puede modificar.', OLD.codigo, lower(v_ant.nombre);
    END IF;

    IF NEW.estado_pedido_id <> OLD.estado_pedido_id THEN
        IF v_nuevo.codigo = 'anulado' AND NOT EXISTS (SELECT 1 FROM core.anulaciones WHERE pedido_id = OLD.id) THEN
            RAISE EXCEPTION 'Una factura sólo se anula con api.sp_anular_pedido (motivo y retorno de inventario).';
        END IF;
        IF v_nuevo.solo_domicilio AND v_tipo <> 'domicilio' THEN
            RAISE EXCEPTION 'El estado "%" sólo aplica a domicilios.', v_nuevo.nombre;
        END IF;
        IF v_nuevo.orden < 90 AND v_nuevo.orden <= v_ant.orden THEN
            RAISE EXCEPTION 'El pedido % no puede volver de "%" a "%".', OLD.codigo, v_ant.nombre, v_nuevo.nombre;
        END IF;
        IF v_ant.codigo = 'entregado' AND v_nuevo.codigo <> 'anulado' THEN
            RAISE EXCEPTION 'Un pedido entregado sólo puede anularse.';
        END IF;
        IF v_nuevo.codigo = 'cancelado' AND (NEW.motivo_cancelacion IS NULL OR length(trim(NEW.motivo_cancelacion)) < 3) THEN
            RAISE EXCEPTION 'Para cancelar hay que escribir el motivo.';
        END IF;
        IF v_nuevo.codigo = 'entregado'
           AND (SELECT codigo FROM core.metodos_pago WHERE id = NEW.metodo_pago_id) = 'efectivo' THEN
            NEW.estado_pago_id := core.fn_id_catalogo('estados_pago', 'confirmado');
        END IF;
    ELSIF v_ant.codigo = 'entregado'
          AND (NEW.metodo_pago_id <> OLD.metodo_pago_id
               OR NEW.cliente_id IS DISTINCT FROM OLD.cliente_id
               OR NEW.direccion_entrega IS DISTINCT FROM OLD.direccion_entrega
               OR NEW.costo_domicilio <> OLD.costo_domicilio) THEN
        RAISE EXCEPTION 'La factura % ya fue entregada: sólo puede cambiar el estado del pago.', OLD.codigo;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pedidos_antes_actualizar
    BEFORE UPDATE ON core.pedidos
    FOR EACH ROW EXECUTE FUNCTION core.tg_pedidos_antes_actualizar();

/* Las facturas no se borran (salvo la limpieza de pruebas, que usa su
   procedimiento y lo declara en la sesión). */
CREATE OR REPLACE FUNCTION core.tg_pedidos_no_borrar()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF current_setting('taseca.borrado_pruebas', TRUE) = 'si' THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'Las facturas no se borran: se cancelan o se anulan (factura %).', OLD.codigo;
END;
$$;

CREATE TRIGGER trg_pedidos_no_borrar
    BEFORE DELETE ON core.pedidos
    FOR EACH ROW EXECUTE FUNCTION core.tg_pedidos_no_borrar();

/* Historial en cada cambio de estado o de pago. */
CREATE OR REPLACE FUNCTION core.tg_pedidos_historial()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.estado_pedido_id <> OLD.estado_pedido_id THEN
        INSERT INTO core.pedido_historial (pedido_id, estado_pedido_id, descripcion, usuario_id)
        SELECT NEW.id, NEW.estado_pedido_id,
               'Estado: ' || e.nombre ||
               CASE WHEN e.codigo = 'cancelado' THEN ' · ' || NEW.motivo_cancelacion ELSE '' END,
               core.fn_usuario_actual()
          FROM core.estados_pedido e WHERE e.id = NEW.estado_pedido_id;
    END IF;
    IF NEW.estado_pago_id <> OLD.estado_pago_id THEN
        INSERT INTO core.pedido_historial (pedido_id, descripcion, usuario_id)
        SELECT NEW.id, 'Pago: ' || p.nombre, core.fn_usuario_actual()
          FROM core.estados_pago p WHERE p.id = NEW.estado_pago_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pedidos_historial
    AFTER UPDATE ON core.pedidos
    FOR EACH ROW EXECUTE FUNCTION core.tg_pedidos_historial();


/* ============================================================================
   5. ÍTEMS DEL PEDIDO
   ============================================================================ */

/* Al agregar un ítem:
     · el pedido sigue siendo editable (estado nuevo)
     · producto de carta: de la unidad, activo y no agotado
     · plato del chef: del menú de la unidad, disponible y con cupo
     · menú armado: de la unidad, armado, disponible y con precio
   Nombre y precio se toman de la fuente si no vienen: es la foto de la
   factura. */
CREATE OR REPLACE FUNCTION core.tg_pedido_items_antes()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_pedido  core.pedidos;
    v_estado  VARCHAR;
    v_nombre  VARCHAR;
    v_precio  NUMERIC;
    v_ok      BOOLEAN;
    v_cupos   INTEGER;
    v_otros   INTEGER := 0;
BEGIN
    SELECT * INTO v_pedido FROM core.pedidos WHERE id = COALESCE(NEW.pedido_id, OLD.pedido_id);
    SELECT codigo INTO v_estado FROM core.estados_pedido WHERE id = v_pedido.estado_pedido_id;

    IF v_estado <> 'nuevo' AND current_setting('taseca.borrado_pruebas', TRUE) IS DISTINCT FROM 'si' THEN
        RAISE EXCEPTION 'La factura % ya está en "%": sus productos no se pueden cambiar.', v_pedido.codigo, v_estado;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    IF NEW.producto_id IS NOT NULL THEN
        SELECT p.nombre, p.precio, (p.activo AND c.activa AND NOT pu.agotado)
          INTO v_nombre, v_precio, v_ok
          FROM core.productos p
          JOIN core.categorias c         ON c.id = p.categoria_id
          JOIN core.producto_unidades pu ON pu.producto_id = p.id AND pu.unidad_id = v_pedido.unidad_id
         WHERE p.id = NEW.producto_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El producto % no se vende en la unidad del pedido.', NEW.producto_id;
        ELSIF NOT v_ok THEN
            RAISE EXCEPTION '"%" no está disponible en este momento.', v_nombre;
        END IF;

    ELSIF NEW.plato_dia_id IS NOT NULL THEN
        SELECT pd.nombre, pd.precio, (pd.disponible AND m.disponible), pd.cupos
          INTO v_nombre, v_precio, v_ok, v_cupos
          FROM core.platos_dia pd
          JOIN core.menus_dia m ON m.id = pd.menu_dia_id
          JOIN core.tipos_menu t ON t.id = m.tipo_menu_id
         WHERE pd.id = NEW.plato_dia_id
           AND m.unidad_id = v_pedido.unidad_id
           AND t.codigo = 'chef';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El plato del día % no es del menú del chef de esta unidad.', NEW.plato_dia_id;
        ELSIF NOT v_ok THEN
            RAISE EXCEPTION '"%" ya no está disponible.', v_nombre;
        END IF;
        IF v_cupos IS NOT NULL THEN
            IF TG_OP = 'UPDATE' AND OLD.plato_dia_id = NEW.plato_dia_id THEN
                v_otros := OLD.cantidad;
            END IF;
            IF core.fn_vendidos_plato(NEW.plato_dia_id) - v_otros + NEW.cantidad > v_cupos THEN
                RAISE EXCEPTION 'No quedan cupos suficientes de "%".', v_nombre;
            END IF;
        END IF;

    ELSE
        SELECT COALESCE(m.nombre, 'Menú del día'), m.precio, m.disponible
          INTO v_nombre, v_precio, v_ok
          FROM core.menus_dia m
          JOIN core.tipos_menu t ON t.id = m.tipo_menu_id
         WHERE m.id = NEW.menu_dia_id
           AND m.unidad_id = v_pedido.unidad_id
           AND t.codigo = 'armado';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El menú % no es un menú armado de esta unidad.', NEW.menu_dia_id;
        ELSIF NOT v_ok OR v_precio IS NULL THEN
            RAISE EXCEPTION 'El menú armado no está disponible o no tiene precio.';
        END IF;
    END IF;

    NEW.nombre          := COALESCE(NEW.nombre, v_nombre);
    NEW.precio_unitario := COALESCE(NEW.precio_unitario, v_precio);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pedido_items_antes
    BEFORE INSERT OR UPDATE OR DELETE ON core.pedido_items
    FOR EACH ROW EXECUTE FUNCTION core.tg_pedido_items_antes();


/* Opciones del menú armado: la opción es del menú del ítem y la categoría no
   supera su máximo (Principio = 2). */
CREATE OR REPLACE FUNCTION core.tg_item_opciones_antes()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_menu_item  BIGINT;
    v_menu_op    BIGINT;
    v_categoria  BIGINT;
    v_max        SMALLINT;
    v_nombre_cat VARCHAR;
    v_activa     BOOLEAN;
BEGIN
    SELECT menu_dia_id INTO v_menu_item FROM core.pedido_items WHERE id = NEW.pedido_item_id;

    SELECT c.menu_dia_id, c.id, c.max_seleccion, c.nombre, (o.activa AND c.activa)
      INTO v_menu_op, v_categoria, v_max, v_nombre_cat, v_activa
      FROM core.menu_opciones o
      JOIN core.menu_categorias c ON c.id = o.menu_categoria_id
     WHERE o.id = NEW.menu_opcion_id;

    IF v_menu_item IS NULL THEN
        RAISE EXCEPTION 'Sólo un ítem de menú armado lleva opciones.';
    ELSIF v_menu_item <> v_menu_op THEN
        RAISE EXCEPTION 'La opción % no pertenece al menú del ítem.', NEW.menu_opcion_id;
    ELSIF NOT v_activa THEN
        RAISE EXCEPTION 'La opción elegida ya no está disponible.';
    END IF;

    IF (SELECT count(*)
          FROM core.pedido_item_opciones x
          JOIN core.menu_opciones o ON o.id = x.menu_opcion_id
         WHERE x.pedido_item_id = NEW.pedido_item_id
           AND o.menu_categoria_id = v_categoria
           AND x.id IS DISTINCT FROM NEW.id) >= v_max THEN
        RAISE EXCEPTION 'Puedes elegir máximo % opción(es) de %.', v_max, v_nombre_cat;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_item_opciones_antes
    BEFORE INSERT OR UPDATE ON core.pedido_item_opciones
    FOR EACH ROW EXECUTE FUNCTION core.tg_item_opciones_antes();

/* Una opción ya vendida no cambia de nombre: la factura de ese día debe
   seguir diciendo lo que el cliente pidió. */
CREATE OR REPLACE FUNCTION core.tg_menu_opciones_vendidas()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.nombre <> OLD.nombre
       AND EXISTS (SELECT 1 FROM core.pedido_item_opciones WHERE menu_opcion_id = OLD.id) THEN
        RAISE EXCEPTION '"%" ya se vendió: no se puede renombrar. Desactívala y crea otra.', OLD.nombre;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_menu_opciones_vendidas
    BEFORE UPDATE OF nombre ON core.menu_opciones
    FOR EACH ROW EXECUTE FUNCTION core.tg_menu_opciones_vendidas();


/* ============================================================================
   6. OPERACIÓN DE LA UNIDAD (menú, caja, gastos, inventario)
   ============================================================================ */

/* Registros nuevos sólo en unidades activas, y con su jornada si no viene. */
CREATE OR REPLACE FUNCTION core.tg_operacion_unidad_activa()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_unidad INTEGER;
BEGIN
    IF TG_TABLE_NAME = 'entradas_inventario' THEN
        SELECT unidad_id INTO v_unidad FROM core.insumo_unidades WHERE id = NEW.insumo_unidad_id;
    ELSE
        v_unidad := NEW.unidad_id;
    END IF;

    PERFORM core.fn_exigir_unidad_operativa(v_unidad);

    IF TG_TABLE_NAME IN ('bases_caja', 'gastos', 'cierres_inventario', 'entradas_inventario') THEN
        NEW.fecha_operativa := COALESCE(NEW.fecha_operativa,
                                        core.fn_fecha_operativa(core.fn_empresa_de_unidad(v_unidad), now()));
    END IF;
    RETURN NEW;
END;
$$;

DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['menus_dia', 'bases_caja', 'gastos', 'cierres_inventario', 'entradas_inventario']
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%1$s_unidad_activa BEFORE INSERT ON core.%1$I
                 FOR EACH ROW EXECUTE FUNCTION core.tg_operacion_unidad_activa()', t);
    END LOOP;
END;
$$;

/* La entrada suma al stock de la unidad. */
CREATE OR REPLACE FUNCTION core.tg_entradas_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.insumo_unidades
       SET stock_actual = stock_actual + NEW.cantidad
     WHERE id = NEW.insumo_unidad_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_entradas_stock
    AFTER INSERT ON core.entradas_inventario
    FOR EACH ROW EXECUTE FUNCTION core.tg_entradas_stock();

/* Las entradas son movimientos: no se editan ni se borran. Si una estuvo
   mal, se registra un ajuste. */
CREATE OR REPLACE FUNCTION core.tg_inmutable()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF current_setting('taseca.borrado_pruebas', TRUE) = 'si' THEN
        RETURN COALESCE(OLD, NEW);
    END IF;
    RAISE EXCEPTION 'Los registros de % no se modifican ni se borran: registra un ajuste.', TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER trg_entradas_inmutable
    BEFORE UPDATE OR DELETE ON core.entradas_inventario
    FOR EACH ROW EXECUTE FUNCTION core.tg_inmutable();

CREATE TRIGGER trg_anulaciones_inmutable
    BEFORE UPDATE OR DELETE ON core.anulaciones
    FOR EACH ROW EXECUTE FUNCTION core.tg_inmutable();

/* La base de caja no se edita: se corrige con una nueva. Sólo se permite
   marcarla como no vigente. */
CREATE OR REPLACE FUNCTION core.tg_bases_caja_antes_actualizar()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.monto <> OLD.monto OR NEW.unidad_id <> OLD.unidad_id OR NEW.fecha_operativa <> OLD.fecha_operativa THEN
        RAISE EXCEPTION 'La base de caja no se edita: registra una corrección.';
    END IF;
    IF OLD.vigente = FALSE AND NEW.vigente = TRUE THEN
        RAISE EXCEPTION 'Una base reemplazada no vuelve a quedar vigente.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_bases_caja_antes_actualizar
    BEFORE UPDATE ON core.bases_caja
    FOR EACH ROW EXECUTE FUNCTION core.tg_bases_caja_antes_actualizar();

/* Un gasto anulado ya no cambia. */
CREATE OR REPLACE FUNCTION core.tg_gastos_antes_actualizar()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF (SELECT codigo FROM core.estados_gasto WHERE id = OLD.estado_gasto_id) = 'anulado' THEN
        RAISE EXCEPTION 'El gasto % está anulado y no se puede modificar.', OLD.id;
    END IF;
    IF (SELECT codigo FROM core.estados_gasto WHERE id = NEW.estado_gasto_id) = 'anulado'
       AND (NEW.motivo_anulacion IS NULL OR length(trim(NEW.motivo_anulacion)) < 3) THEN
        RAISE EXCEPTION 'Para anular un gasto hay que escribir el motivo.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_gastos_antes_actualizar
    BEFORE UPDATE ON core.gastos
    FOR EACH ROW EXECUTE FUNCTION core.tg_gastos_antes_actualizar();


/* ============================================================================
   7. CIERRES DE INVENTARIO
   ============================================================================ */

/* Un cierre revisado ya no lo toca nadie (salvo marcarlo como aplicado al
   stock). */
CREATE OR REPLACE FUNCTION core.tg_cierres_antes_actualizar()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF (SELECT codigo FROM core.estados_cierre WHERE id = OLD.estado_cierre_id) = 'revisado' THEN
            RAISE EXCEPTION 'El cierre % está revisado: no se puede borrar.', OLD.id;
        END IF;
        RETURN OLD;
    END IF;

    IF (SELECT codigo FROM core.estados_cierre WHERE id = OLD.estado_cierre_id) = 'revisado'
       AND (NEW.estado_cierre_id <> OLD.estado_cierre_id
            OR NEW.observacion IS DISTINCT FROM OLD.observacion
            OR NEW.fecha_operativa <> OLD.fecha_operativa
            OR NEW.aplicado_a_stock = OLD.aplicado_a_stock) THEN
        RAISE EXCEPTION 'El cierre % está revisado y ya no se puede modificar.', OLD.id;
    END IF;
    IF NEW.unidad_id <> OLD.unidad_id OR NEW.area_id <> OLD.area_id THEN
        RAISE EXCEPTION 'Un cierre no cambia de unidad ni de área.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cierres_antes_actualizar
    BEFORE UPDATE OR DELETE ON core.cierres_inventario
    FOR EACH ROW EXECUTE FUNCTION core.tg_cierres_antes_actualizar();

/* Detalle: el insumo es de la unidad y del área del cierre, y el cierre no
   está revisado. */
CREATE OR REPLACE FUNCTION core.tg_cierre_detalles_antes()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cierre  core.cierres_inventario;
    v_estado  VARCHAR;
BEGIN
    SELECT * INTO v_cierre FROM core.cierres_inventario WHERE id = COALESCE(NEW.cierre_id, OLD.cierre_id);
    SELECT codigo INTO v_estado FROM core.estados_cierre WHERE id = v_cierre.estado_cierre_id;

    IF v_estado = 'revisado' THEN
        RAISE EXCEPTION 'El cierre % está revisado: su conteo no se puede cambiar.', v_cierre.id;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM core.insumo_unidades iu
          JOIN core.insumos i ON i.id = iu.insumo_id
         WHERE iu.id = NEW.insumo_unidad_id
           AND iu.unidad_id = v_cierre.unidad_id
           AND i.area_id = v_cierre.area_id
    ) THEN
        RAISE EXCEPTION 'El insumo % no es de la unidad ni del área de este cierre.', NEW.insumo_unidad_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cierre_detalles_antes
    BEFORE INSERT OR UPDATE OR DELETE ON core.cierre_detalles
    FOR EACH ROW EXECUTE FUNCTION core.tg_cierre_detalles_antes();


/* ============================================================================
   04_PROCEDIMIENTOS
   Todo lo que escribe pasa por aquí
   ============================================================================ */

/* ============================================================================
   TASECA · 04 · PROCEDIMIENTOS Y FUNCIONES DE LA API (esquema api)
   ----------------------------------------------------------------------------
   Toda escritura de la aplicación pasa por aquí. Cada procedimiento:
     1. fija el usuario de la operación (auditoría e historial),
     2. comprueba el permiso del rol y el módulo de la empresa,
     3. comprueba que el usuario trabaje en esa unidad,
     4. escribe; los triggers de 03 garantizan el resto de reglas.

   SECURITY DEFINER: se ejecutan con los privilegios del dueño. Así el rol
   de la aplicación sólo necesita EXECUTE sobre api, nunca acceso a core.
   `SET search_path` fijo evita que alguien los engañe con otro esquema.

   Llamada desde DBeaver o la aplicación (parámetros por nombre):
     CALL api.sp_crear_pedido(p_unidad_id => 4, p_tipo => 'domicilio', ...);
   Los parámetros INOUT devuelven el resultado (id, código).

   p_usuario_id NULL = operación sin sesión: el cliente del portal público
   (crear pedido) o la carga de datos del DBA.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   0. APOYO
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.fn_preparar_operacion(p_usuario_id INTEGER, p_permiso TEXT, p_unidad_id INTEGER DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_usuario_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM core.usuarios WHERE id = p_usuario_id AND activo) THEN
        RAISE EXCEPTION 'El usuario % no existe o está inactivo.', p_usuario_id
              USING ERRCODE = 'insufficient_privilege';
    END IF;

    PERFORM core.fn_fijar_usuario(p_usuario_id);

    IF p_permiso IS NOT NULL THEN
        PERFORM core.fn_exigir_permiso(p_usuario_id, p_permiso);
    END IF;

    IF p_unidad_id IS NOT NULL AND NOT core.fn_usuario_en_unidad(p_usuario_id, p_unidad_id) THEN
        RAISE EXCEPTION 'El usuario % no trabaja en la unidad %.', p_usuario_id, p_unidad_id
              USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$$;

/* Para las acciones que admiten varios permisos (el cocinero avanza su
   pedido, el domiciliario el suyo…). */
CREATE OR REPLACE FUNCTION core.fn_exigir_alguno(p_usuario_id INTEGER, p_permisos TEXT[])
RETURNS VOID
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    IF p_usuario_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM unnest(p_permisos) p WHERE core.fn_tiene_permiso(p_usuario_id, p)) THEN
        RAISE EXCEPTION 'El usuario % no tiene ninguno de los permisos: %.', p_usuario_id, array_to_string(p_permisos, ', ')
              USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$$;


/* ============================================================================
   1. ACCESO
   ============================================================================ */

/* Devuelve el usuario si el PIN es correcto; ninguna fila si no. No dice
   cuál de los dos datos falló, a propósito. */
CREATE OR REPLACE FUNCTION api.fn_login(p_usuario VARCHAR, p_pin VARCHAR)
RETURNS TABLE (usuario_id INTEGER, nombre VARCHAR, usuario VARCHAR, rol VARCHAR,
               alcance VARCHAR, empresa_id INTEGER, empresa VARCHAR)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_id INTEGER;
BEGIN
    SELECT u.id INTO v_id
      FROM core.usuarios u
      LEFT JOIN core.empresas e ON e.id = u.empresa_id
     WHERE lower(u.usuario) = lower(trim(p_usuario))
       AND u.activo
       AND (e.id IS NULL OR e.estado = 'activa')
       AND core.fn_pin_valido(p_pin, u.pin_hash);

    IF v_id IS NULL THEN
        RETURN;
    END IF;

    UPDATE core.usuarios SET ultimo_acceso = now() WHERE id = v_id;

    RETURN QUERY
    SELECT u.id, u.nombre, u.usuario, r.codigo, r.alcance, u.empresa_id, e.nombre_comercial
      FROM core.usuarios u
      JOIN core.roles r ON r.id = u.rol_id
      LEFT JOIN core.empresas e ON e.id = u.empresa_id
     WHERE u.id = v_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.fn_tiene_permiso(p_usuario_id INTEGER, p_permiso VARCHAR)
RETURNS BOOLEAN
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT core.fn_tiene_permiso(p_usuario_id, p_permiso);
$$;

CREATE OR REPLACE PROCEDURE api.sp_guardar_usuario(
    p_empresa_id      INTEGER,
    p_rol             VARCHAR,
    p_nombre          VARCHAR,
    p_usuario         VARCHAR,
    p_admin_id        INTEGER,
    p_pin             VARCHAR   DEFAULT NULL,
    p_unidades        INTEGER[] DEFAULT NULL,
    p_activo          BOOLEAN   DEFAULT TRUE,
    INOUT p_usuario_id INTEGER  DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_rol     core.roles;
BEGIN
    SELECT * INTO v_rol FROM core.roles WHERE codigo = p_rol;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El rol "%" no existe.', p_rol;
    END IF;

    PERFORM core.fn_preparar_operacion(p_admin_id, CASE WHEN v_rol.alcance = 'plataforma' THEN 'plataforma' ELSE 'usuarios' END);

    -- El admin de una empresa sólo crea usuarios de SU empresa
    IF p_admin_id IS NOT NULL AND NOT core.fn_tiene_permiso(p_admin_id, 'plataforma')
       AND p_empresa_id IS DISTINCT FROM (SELECT empresa_id FROM core.usuarios WHERE id = p_admin_id) THEN
        RAISE EXCEPTION 'No puedes administrar usuarios de otra empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF p_usuario_id IS NULL THEN
        IF p_pin IS NULL THEN
            RAISE EXCEPTION 'Un usuario nuevo necesita PIN.';
        END IF;
        INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash, activo)
        VALUES (CASE WHEN v_rol.alcance = 'plataforma' THEN NULL ELSE p_empresa_id END,
                v_rol.id, trim(p_nombre), p_usuario, core.fn_hash_pin(p_pin), p_activo)
        RETURNING id INTO p_usuario_id;
    ELSE
        UPDATE core.usuarios
           SET rol_id   = v_rol.id,
               nombre   = trim(p_nombre),
               usuario  = p_usuario,
               activo   = p_activo,
               pin_hash = CASE WHEN p_pin IS NULL THEN pin_hash ELSE core.fn_hash_pin(p_pin) END
         WHERE id = p_usuario_id
           AND (empresa_id = p_empresa_id OR (empresa_id IS NULL AND v_rol.alcance = 'plataforma'));
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El usuario % no existe en esa empresa.', p_usuario_id;
        END IF;
    END IF;

    IF p_unidades IS NOT NULL THEN
        DELETE FROM core.usuario_unidades WHERE usuario_id = p_usuario_id AND unidad_id <> ALL (p_unidades);
        INSERT INTO core.usuario_unidades (usuario_id, unidad_id)
        SELECT p_usuario_id, x FROM unnest(p_unidades) x
        ON CONFLICT (usuario_id, unidad_id) DO NOTHING;
    END IF;
END;
$$;


/* ============================================================================
   2. UNIDADES / LOCALES
   ============================================================================ */

CREATE OR REPLACE PROCEDURE api.sp_guardar_unidad(
    p_empresa_id     INTEGER,
    p_nombre         VARCHAR,
    p_tipo_negocio   VARCHAR,
    p_usuario_id     INTEGER,
    p_nombre_corto   VARCHAR DEFAULT NULL,
    p_direccion      VARCHAR DEFAULT NULL,
    p_ciudad         VARCHAR DEFAULT NULL,
    p_telefono       VARCHAR DEFAULT NULL,
    p_whatsapp       VARCHAR DEFAULT NULL,
    p_horario        VARCHAR DEFAULT NULL,
    p_mapa_url       VARCHAR DEFAULT NULL,
    p_mesas          INTEGER DEFAULT NULL,
    INOUT p_unidad_id INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_corto VARCHAR := COALESCE(NULLIF(trim(p_nombre_corto), ''), left(trim(p_nombre), 40));
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'config_sucursales');

    IF length(trim(COALESCE(p_nombre, ''))) < 2 THEN
        RAISE EXCEPTION 'La unidad necesita un nombre.';
    END IF;

    IF p_unidad_id IS NULL THEN
        INSERT INTO core.unidades (empresa_id, tipo_negocio_id, nombre, nombre_corto, direccion, ciudad,
                                   telefono, whatsapp, horario, mapa_url)
        VALUES (p_empresa_id, core.fn_id_catalogo('tipos_negocio', p_tipo_negocio), trim(p_nombre), v_corto,
                p_direccion, p_ciudad, p_telefono, p_whatsapp, p_horario, p_mapa_url)
        RETURNING id INTO p_unidad_id;
    ELSE
        UPDATE core.unidades
           SET tipo_negocio_id = core.fn_id_catalogo('tipos_negocio', p_tipo_negocio),
               nombre = trim(p_nombre), nombre_corto = v_corto, direccion = p_direccion,
               ciudad = p_ciudad, telefono = p_telefono, whatsapp = p_whatsapp,
               horario = p_horario, mapa_url = p_mapa_url
         WHERE id = p_unidad_id AND empresa_id = p_empresa_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'La unidad % no existe en la empresa %.', p_unidad_id, p_empresa_id;
        END IF;
    END IF;

    -- Mesas numeradas 1..N (nunca se borran las que ya tienen pedidos: se desactivan)
    IF p_mesas IS NOT NULL THEN
        INSERT INTO core.mesas (unidad_id, numero)
        SELECT p_unidad_id, g::TEXT FROM generate_series(1, p_mesas) g
        ON CONFLICT (unidad_id, numero) DO UPDATE SET activa = TRUE;
        UPDATE core.mesas SET activa = FALSE
         WHERE unidad_id = p_unidad_id AND numero ~ '^[0-9]+$' AND numero::INTEGER > p_mesas;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_cambiar_estado_unidad(p_unidad_id INTEGER, p_activa BOOLEAN, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'config_sucursales');
    UPDATE core.unidades SET estado = CASE WHEN p_activa THEN 'activa' ELSE 'inactiva' END
     WHERE id = p_unidad_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La unidad % no existe.', p_unidad_id;
    END IF;
END;
$$;


/* ============================================================================
   3. CARTA
   ============================================================================ */

CREATE OR REPLACE PROCEDURE api.sp_guardar_producto(
    p_empresa_id    INTEGER,
    p_categoria_id  INTEGER,
    p_codigo        VARCHAR,
    p_nombre        VARCHAR,
    p_precio        NUMERIC,
    p_unidades      INTEGER[],
    p_usuario_id    INTEGER,
    p_descripcion   VARCHAR DEFAULT NULL,
    p_etiqueta      VARCHAR DEFAULT NULL,
    p_activo        BOOLEAN DEFAULT TRUE,
    p_orden         INTEGER DEFAULT NULL,
    INOUT p_producto_id INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_etiqueta INTEGER := CASE WHEN p_etiqueta IS NULL THEN NULL
                               ELSE core.fn_id_catalogo('etiquetas_producto', p_etiqueta) END;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'carta');

    IF p_unidades IS NULL OR cardinality(p_unidades) = 0 THEN
        RAISE EXCEPTION 'El producto debe venderse al menos en una unidad.';
    END IF;

    IF p_producto_id IS NULL THEN
        INSERT INTO core.productos (empresa_id, categoria_id, etiqueta_id, codigo, nombre, descripcion,
                                    precio, activo, orden)
        VALUES (p_empresa_id, p_categoria_id, v_etiqueta, upper(trim(p_codigo)), trim(p_nombre), p_descripcion,
                p_precio, p_activo,
                COALESCE(p_orden, (SELECT COALESCE(max(orden), 0) + 10 FROM core.productos WHERE empresa_id = p_empresa_id)))
        RETURNING id INTO p_producto_id;
    ELSE
        UPDATE core.productos
           SET categoria_id = p_categoria_id, etiqueta_id = v_etiqueta, codigo = upper(trim(p_codigo)),
               nombre = trim(p_nombre), descripcion = p_descripcion, precio = p_precio,
               activo = p_activo, orden = COALESCE(p_orden, orden)
         WHERE id = p_producto_id AND empresa_id = p_empresa_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El producto % no existe en la empresa %.', p_producto_id, p_empresa_id;
        END IF;
    END IF;

    DELETE FROM core.producto_unidades WHERE producto_id = p_producto_id AND unidad_id <> ALL (p_unidades);
    INSERT INTO core.producto_unidades (producto_id, unidad_id)
    SELECT p_producto_id, x FROM unnest(p_unidades) x
    ON CONFLICT (producto_id, unidad_id) DO NOTHING;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_marcar_agotado(p_producto_id INTEGER, p_unidad_id INTEGER, p_agotado BOOLEAN, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'carta', p_unidad_id);
    UPDATE core.producto_unidades SET agotado = p_agotado
     WHERE producto_id = p_producto_id AND unidad_id = p_unidad_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El producto % no se vende en la unidad %.', p_producto_id, p_unidad_id;
    END IF;
END;
$$;


/* ============================================================================
   4. MENÚ DEL DÍA
   ============================================================================ */

CREATE OR REPLACE PROCEDURE api.sp_guardar_menu_dia(
    p_unidad_id    INTEGER,
    p_fecha        DATE,
    p_tipo         VARCHAR,
    p_usuario_id   INTEGER,
    p_nombre       VARCHAR DEFAULT NULL,
    p_descripcion  VARCHAR DEFAULT NULL,
    p_precio       NUMERIC DEFAULT NULL,
    p_disponible   BOOLEAN DEFAULT TRUE,
    p_titulo       VARCHAR DEFAULT NULL,
    p_mensaje      VARCHAR DEFAULT NULL,
    INOUT p_menu_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu', p_unidad_id);

    INSERT INTO core.menus_dia (unidad_id, fecha, tipo_menu_id, nombre, descripcion, precio, disponible,
                                titulo_publico, mensaje_publico, creado_por_id)
    VALUES (p_unidad_id, p_fecha, core.fn_id_catalogo('tipos_menu', p_tipo), p_nombre, p_descripcion,
            p_precio, p_disponible, NULLIF(trim(p_titulo), ''), NULLIF(trim(p_mensaje), ''), p_usuario_id)
    ON CONFLICT (unidad_id, fecha) DO UPDATE
       SET tipo_menu_id    = EXCLUDED.tipo_menu_id,
           nombre          = EXCLUDED.nombre,
           descripcion     = EXCLUDED.descripcion,
           precio          = EXCLUDED.precio,
           disponible      = EXCLUDED.disponible,
           titulo_publico  = EXCLUDED.titulo_publico,
           mensaje_publico = EXCLUDED.mensaje_publico
    RETURNING id INTO p_menu_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_guardar_menu_categoria(
    p_menu_dia_id    BIGINT,
    p_nombre         VARCHAR,
    p_usuario_id     INTEGER,
    p_max_seleccion  INTEGER  DEFAULT 1,
    p_obligatoria    BOOLEAN  DEFAULT TRUE,
    p_icono          VARCHAR  DEFAULT NULL,
    p_activa         BOOLEAN  DEFAULT TRUE,
    INOUT p_categoria_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu',
            (SELECT unidad_id FROM core.menus_dia WHERE id = p_menu_dia_id));

    IF p_categoria_id IS NULL THEN
        INSERT INTO core.menu_categorias (menu_dia_id, nombre, icono, orden, obligatoria, max_seleccion, activa)
        VALUES (p_menu_dia_id, trim(p_nombre), p_icono,
                (SELECT COALESCE(max(orden), 0) + 1 FROM core.menu_categorias WHERE menu_dia_id = p_menu_dia_id),
                p_obligatoria, p_max_seleccion, p_activa)
        RETURNING id INTO p_categoria_id;
    ELSE
        UPDATE core.menu_categorias
           SET nombre = trim(p_nombre), icono = p_icono, obligatoria = p_obligatoria,
               max_seleccion = p_max_seleccion, activa = p_activa
         WHERE id = p_categoria_id AND menu_dia_id = p_menu_dia_id;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_guardar_menu_opcion(
    p_menu_categoria_id BIGINT,
    p_nombre            VARCHAR,
    p_usuario_id        INTEGER,
    p_activa            BOOLEAN DEFAULT TRUE,
    INOUT p_opcion_id   BIGINT  DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu',
            (SELECT m.unidad_id FROM core.menu_categorias c JOIN core.menus_dia m ON m.id = c.menu_dia_id
              WHERE c.id = p_menu_categoria_id));

    IF p_opcion_id IS NULL THEN
        INSERT INTO core.menu_opciones (menu_categoria_id, nombre, orden, activa)
        VALUES (p_menu_categoria_id, trim(p_nombre),
                (SELECT COALESCE(max(orden), 0) + 1 FROM core.menu_opciones WHERE menu_categoria_id = p_menu_categoria_id),
                p_activa)
        RETURNING id INTO p_opcion_id;
    ELSE
        UPDATE core.menu_opciones SET nombre = trim(p_nombre), activa = p_activa
         WHERE id = p_opcion_id AND menu_categoria_id = p_menu_categoria_id;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_guardar_plato_dia(
    p_menu_dia_id  BIGINT,
    p_nombre       VARCHAR,
    p_precio       NUMERIC,
    p_usuario_id   INTEGER,
    p_descripcion  VARCHAR DEFAULT NULL,
    p_emoji        VARCHAR DEFAULT NULL,
    p_cupos        INTEGER DEFAULT NULL,
    p_disponible   BOOLEAN DEFAULT TRUE,
    INOUT p_plato_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu',
            (SELECT unidad_id FROM core.menus_dia WHERE id = p_menu_dia_id));

    IF p_plato_id IS NULL THEN
        INSERT INTO core.platos_dia (menu_dia_id, nombre, descripcion, emoji, precio, cupos, disponible, orden)
        VALUES (p_menu_dia_id, trim(p_nombre), p_descripcion, p_emoji, p_precio, p_cupos, p_disponible,
                (SELECT COALESCE(max(orden), 0) + 1 FROM core.platos_dia WHERE menu_dia_id = p_menu_dia_id))
        RETURNING id INTO p_plato_id;
    ELSE
        UPDATE core.platos_dia
           SET nombre = trim(p_nombre), descripcion = p_descripcion, emoji = p_emoji,
               precio = p_precio, cupos = p_cupos, disponible = p_disponible
         WHERE id = p_plato_id AND menu_dia_id = p_menu_dia_id;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_guardar_texto_menu_unidad(p_unidad_id INTEGER, p_titulo VARCHAR, p_mensaje VARCHAR, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu', p_unidad_id);
    INSERT INTO core.textos_menu_unidad (unidad_id, titulo, mensaje)
    VALUES (p_unidad_id, NULLIF(trim(p_titulo), ''), NULLIF(trim(p_mensaje), ''))
    ON CONFLICT (unidad_id) DO UPDATE
       SET titulo = EXCLUDED.titulo, mensaje = EXCLUDED.mensaje, actualizado_en = now();
END;
$$;

/* Copia el menú de una fecha a otra: modalidad, textos, categorías con sus
   opciones y platos del chef. Si el destino ya tiene menú, no lo pisa. */
CREATE OR REPLACE PROCEDURE api.sp_copiar_menu_dia(
    p_unidad_id      INTEGER,
    p_fecha_origen   DATE,
    p_fecha_destino  DATE,
    p_usuario_id     INTEGER,
    INOUT p_menu_id  BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_origen core.menus_dia;
    v_cat    RECORD;
    v_nueva  BIGINT;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu', p_unidad_id);

    SELECT * INTO v_origen FROM core.menus_dia WHERE unidad_id = p_unidad_id AND fecha = p_fecha_origen;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No hay menú el % en esta unidad.', p_fecha_origen;
    END IF;
    IF EXISTS (SELECT 1 FROM core.menus_dia WHERE unidad_id = p_unidad_id AND fecha = p_fecha_destino) THEN
        RAISE EXCEPTION 'El % ya tiene menú: copiar nunca lo reemplaza.', p_fecha_destino;
    END IF;

    INSERT INTO core.menus_dia (unidad_id, fecha, tipo_menu_id, nombre, descripcion, precio, disponible,
                                titulo_publico, mensaje_publico, creado_por_id)
    VALUES (p_unidad_id, p_fecha_destino, v_origen.tipo_menu_id, v_origen.nombre, v_origen.descripcion,
            v_origen.precio, v_origen.disponible, v_origen.titulo_publico, v_origen.mensaje_publico, p_usuario_id)
    RETURNING id INTO p_menu_id;

    FOR v_cat IN SELECT * FROM core.menu_categorias WHERE menu_dia_id = v_origen.id ORDER BY orden LOOP
        INSERT INTO core.menu_categorias (menu_dia_id, nombre, icono, orden, obligatoria, max_seleccion, activa)
        VALUES (p_menu_id, v_cat.nombre, v_cat.icono, v_cat.orden, v_cat.obligatoria, v_cat.max_seleccion, v_cat.activa)
        RETURNING id INTO v_nueva;

        INSERT INTO core.menu_opciones (menu_categoria_id, nombre, orden, activa)
        SELECT v_nueva, nombre, orden, activa FROM core.menu_opciones WHERE menu_categoria_id = v_cat.id;
    END LOOP;

    INSERT INTO core.platos_dia (menu_dia_id, nombre, descripcion, emoji, precio, cupos, disponible, orden)
    SELECT p_menu_id, nombre, descripcion, emoji, precio, cupos, disponible, orden
      FROM core.platos_dia WHERE menu_dia_id = v_origen.id;
END;
$$;


/* ============================================================================
   5. PEDIDOS / FACTURAS
   ============================================================================ */

/* Crea el pedido con sus ítems en una sola transacción.

   p_items (jsonb), una línea por elemento:
     [ {"producto_id": 12, "cantidad": 2, "notas": "sin cebolla"},
       {"plato_dia_id": 5, "cantidad": 1},
       {"menu_dia_id": 3, "cantidad": 1, "opciones": [10, 14, 15, 19]} ]

   El cliente del portal no tiene sesión: p_usuario_id NULL. */
CREATE OR REPLACE PROCEDURE api.sp_crear_pedido(
    p_unidad_id         INTEGER,
    p_tipo              VARCHAR,
    p_metodo_pago       VARCHAR,
    p_items             JSONB,
    p_usuario_id        INTEGER DEFAULT NULL,
    p_mesa              VARCHAR DEFAULT NULL,
    p_cliente_nombre    VARCHAR DEFAULT NULL,
    p_cliente_telefono  VARCHAR DEFAULT NULL,
    p_direccion         VARCHAR DEFAULT NULL,
    p_indicaciones      VARCHAR DEFAULT NULL,
    p_zona_id           INTEGER DEFAULT NULL,
    p_paga_con          NUMERIC DEFAULT NULL,
    INOUT p_pedido_id   BIGINT  DEFAULT NULL,
    INOUT p_codigo      VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_empresa   INTEGER := core.fn_empresa_de_unidad(p_unidad_id);
    v_metodo    INTEGER := core.fn_id_catalogo('metodos_pago', p_metodo_pago);
    v_tipo      INTEGER := core.fn_id_catalogo('tipos_pedido', p_tipo);
    v_cliente   BIGINT;
    v_mesa      INTEGER;
    v_linea     JSONB;
    v_item      BIGINT;
    v_minimo    NUMERIC;
    v_falta     TEXT;
BEGIN
    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'La unidad % no existe.', p_unidad_id;
    END IF;

    PERFORM core.fn_preparar_operacion(p_usuario_id, NULL, p_unidad_id);
    IF p_usuario_id IS NOT NULL THEN
        PERFORM core.fn_exigir_alguno(p_usuario_id, ARRAY['pedidos_mesa', 'pedidos_gestionar']);
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'El pedido está vacío.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM core.empresa_metodos_pago
                    WHERE empresa_id = v_empresa AND metodo_pago_id = v_metodo AND activo) THEN
        RAISE EXCEPTION 'El método de pago "%" no está disponible.', p_metodo_pago;
    END IF;

    IF p_tipo = 'domicilio' THEN
        IF length(trim(COALESCE(p_cliente_nombre, ''))) < 3 THEN
            RAISE EXCEPTION 'Escribe tu nombre completo.';
        END IF;
        IF regexp_replace(COALESCE(p_cliente_telefono, ''), '\D', '', 'g') !~ '^[0-9]{7,10}$' THEN
            RAISE EXCEPTION 'El celular debe tener entre 7 y 10 dígitos.';
        END IF;
        INSERT INTO core.clientes (empresa_id, nombre, telefono)
        VALUES (v_empresa, trim(p_cliente_nombre), regexp_replace(p_cliente_telefono, '\D', '', 'g'))
        ON CONFLICT (empresa_id, telefono) DO UPDATE SET nombre = EXCLUDED.nombre
        RETURNING id INTO v_cliente;
    ELSIF p_tipo = 'mesa' THEN
        SELECT id INTO v_mesa FROM core.mesas
         WHERE unidad_id = p_unidad_id AND numero = trim(p_mesa) AND activa;
        IF v_mesa IS NULL THEN
            RAISE EXCEPTION 'La mesa "%" no existe en esta unidad.', p_mesa;
        END IF;
    END IF;

    INSERT INTO core.pedidos (unidad_id, tipo_pedido_id, metodo_pago_id, mesa_id, cliente_id,
                              zona_domicilio_id, direccion_entrega, indicaciones, paga_con, tomado_por_id)
    VALUES (p_unidad_id, v_tipo, v_metodo, v_mesa, v_cliente, p_zona_id,
            NULLIF(trim(p_direccion), ''), NULLIF(trim(p_indicaciones), ''), p_paga_con, p_usuario_id)
    RETURNING id, codigo INTO p_pedido_id, p_codigo;

    FOR v_linea IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        INSERT INTO core.pedido_items (pedido_id, producto_id, plato_dia_id, menu_dia_id, cantidad, notas)
        VALUES (p_pedido_id,
                (v_linea ->> 'producto_id')::INTEGER,
                (v_linea ->> 'plato_dia_id')::BIGINT,
                (v_linea ->> 'menu_dia_id')::BIGINT,
                COALESCE((v_linea ->> 'cantidad')::INTEGER, 1),
                NULLIF(trim(v_linea ->> 'notas'), ''))
        RETURNING id INTO v_item;

        IF v_linea ? 'menu_dia_id' THEN
            INSERT INTO core.pedido_item_opciones (pedido_item_id, menu_opcion_id)
            SELECT v_item, x::BIGINT FROM jsonb_array_elements_text(COALESCE(v_linea -> 'opciones', '[]')) x;

            -- Toda categoría obligatoria con opciones activas debe tener al menos una elegida
            SELECT string_agg(c.nombre, ', ' ORDER BY c.orden) INTO v_falta
              FROM core.menu_categorias c
             WHERE c.menu_dia_id = (v_linea ->> 'menu_dia_id')::BIGINT
               AND c.activa AND c.obligatoria
               AND EXISTS (SELECT 1 FROM core.menu_opciones o WHERE o.menu_categoria_id = c.id AND o.activa)
               AND NOT EXISTS (SELECT 1 FROM core.pedido_item_opciones x
                                 JOIN core.menu_opciones o ON o.id = x.menu_opcion_id
                                WHERE x.pedido_item_id = v_item AND o.menu_categoria_id = c.id);
            IF v_falta IS NOT NULL THEN
                RAISE EXCEPTION 'Te falta elegir: %.', v_falta;
            END IF;
        END IF;
    END LOOP;

    SELECT pedido_minimo INTO v_minimo FROM core.zonas_domicilio WHERE id = p_zona_id;
    IF v_minimo IS NOT NULL AND core.fn_subtotal_pedido(p_pedido_id) < v_minimo THEN
        RAISE EXCEPTION 'El pedido mínimo para esta zona es %.', v_minimo;
    END IF;
END;
$$;

/* Pasa al siguiente estado del flujo (una mesa no pasa por «en camino»). */
CREATE OR REPLACE PROCEDURE api.sp_avanzar_estado_pedido(p_pedido_id BIGINT, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_siguiente INTEGER := core.fn_siguiente_estado(p_pedido_id);
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, NULL,
            (SELECT unidad_id FROM core.pedidos WHERE id = p_pedido_id));
    PERFORM core.fn_exigir_alguno(p_usuario_id,
            ARRAY['pedidos_gestionar', 'pedidos_cocina', 'pedidos_listos', 'pedidos_domicilio']);

    IF v_siguiente IS NULL THEN
        RAISE EXCEPTION 'El pedido % ya no tiene un estado siguiente.', p_pedido_id;
    END IF;
    UPDATE core.pedidos SET estado_pedido_id = v_siguiente WHERE id = p_pedido_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_cambiar_estado_pedido(p_pedido_id BIGINT, p_estado VARCHAR, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    IF p_estado IN ('cancelado', 'anulado') THEN
        RAISE EXCEPTION 'Para cancelar usa api.sp_cancelar_pedido y para anular api.sp_anular_pedido.';
    END IF;
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'pedidos_gestionar',
            (SELECT unidad_id FROM core.pedidos WHERE id = p_pedido_id));
    UPDATE core.pedidos SET estado_pedido_id = core.fn_id_catalogo('estados_pedido', p_estado)
     WHERE id = p_pedido_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido % no existe.', p_pedido_id;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_cancelar_pedido(p_pedido_id BIGINT, p_motivo VARCHAR, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'pedidos_cancelar',
            (SELECT unidad_id FROM core.pedidos WHERE id = p_pedido_id));
    IF (SELECT e.codigo FROM core.pedidos p JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
         WHERE p.id = p_pedido_id) = 'entregado' THEN
        RAISE EXCEPTION 'Un pedido entregado ya es una venta: no se cancela, se anula.';
    END IF;
    UPDATE core.pedidos
       SET estado_pedido_id   = core.fn_id_catalogo('estados_pedido', 'cancelado'),
           motivo_cancelacion = trim(p_motivo)
     WHERE id = p_pedido_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido % no existe.', p_pedido_id;
    END IF;
END;
$$;

/* ANULAR una factura: la venta se hizo y se echa atrás.
     · queda con motivo, quién y cuándo (core.anulaciones)
     · lo que consumió vuelve al inventario como entrada 'retorno_anulacion'
     · área por área: si esa jornada YA tiene cierre de inventario, el
       retorno se imputa a la jornada de hoy para no alterar un cierre hecho
     · nada se borra */
CREATE OR REPLACE PROCEDURE api.sp_anular_pedido(p_pedido_id BIGINT, p_motivo VARCHAR, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_pedido     core.pedidos;
    v_estado     VARCHAR;
    v_hoy        DATE;
    v_retorno    DATE;
    v_diferido   BOOLEAN := FALSE;
    v_consumo    RECORD;
BEGIN
    SELECT * INTO v_pedido FROM core.pedidos WHERE id = p_pedido_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Esa factura no existe.';
    END IF;

    PERFORM core.fn_preparar_operacion(p_usuario_id, 'pedidos_anular', v_pedido.unidad_id);

    SELECT codigo INTO v_estado FROM core.estados_pedido WHERE id = v_pedido.estado_pedido_id;
    IF v_estado = 'anulado' THEN
        RAISE EXCEPTION 'Esa factura ya está anulada. No se puede anular dos veces.';
    ELSIF v_estado = 'cancelado' THEN
        RAISE EXCEPTION 'Ese pedido está cancelado: nunca fue una venta efectiva, no hay nada que anular.';
    ELSIF length(trim(COALESCE(p_motivo, ''))) < 3 THEN
        RAISE EXCEPTION 'Hay que escribir el motivo de la anulación.';
    END IF;

    v_hoy := core.fn_fecha_operativa(v_pedido.empresa_id, now());

    -- ¿Alguna área consumida ya tiene cierre en la jornada original?
    SELECT EXISTS (
        SELECT 1
          FROM core.pedido_items i
          JOIN core.producto_insumos pi ON pi.producto_id = i.producto_id
          JOIN core.insumos s           ON s.id = pi.insumo_id
          JOIN core.cierres_inventario c
            ON c.unidad_id = v_pedido.unidad_id AND c.area_id = s.area_id
           AND c.fecha_operativa = v_pedido.fecha_operativa
         WHERE i.pedido_id = p_pedido_id
    ) INTO v_diferido;

    /* El retorno nunca cae en la jornada ya cerrada: si se anula el mismo
       día del cierre, va a la jornada siguiente. */
    v_hoy     := GREATEST(v_hoy, v_pedido.fecha_operativa + 1);
    v_retorno := CASE WHEN v_diferido THEN v_hoy ELSE v_pedido.fecha_operativa END;

    INSERT INTO core.anulaciones (pedido_id, motivo, usuario_id, jornada_original, jornada_retorno)
    VALUES (p_pedido_id, trim(p_motivo), p_usuario_id, v_pedido.fecha_operativa, v_retorno);

    FOR v_consumo IN
        SELECT iu.id AS insumo_unidad_id, s.area_id,
               SUM(i.cantidad * pi.cantidad) AS cantidad,
               EXISTS (SELECT 1 FROM core.cierres_inventario c
                        WHERE c.unidad_id = v_pedido.unidad_id AND c.area_id = s.area_id
                          AND c.fecha_operativa = v_pedido.fecha_operativa) AS area_cerrada
          FROM core.pedido_items i
          JOIN core.producto_insumos pi ON pi.producto_id = i.producto_id
          JOIN core.insumos s           ON s.id = pi.insumo_id
          JOIN core.insumo_unidades iu  ON iu.insumo_id = s.id AND iu.unidad_id = v_pedido.unidad_id
         WHERE i.pedido_id = p_pedido_id
         GROUP BY iu.id, s.area_id
    LOOP
        /* Nunca las dos cosas a la vez, o el inventario vuelve dos veces:
             · área SIN cierre en esa jornada → basta con que la factura
               anulada deje de contar en las ventas (Z) de su jornada
             · área YA cerrada → ese cierre no se toca; la mercancía vuelve
               como entrada de la jornada de hoy */
        CONTINUE WHEN NOT v_consumo.area_cerrada;

        INSERT INTO core.entradas_inventario (insumo_unidad_id, tipo_entrada_id, fecha_operativa, cantidad,
                                              observacion, pedido_id, usuario_id)
        VALUES (v_consumo.insumo_unidad_id, core.fn_id_catalogo('tipos_entrada', 'retorno_anulacion'),
                v_hoy, v_consumo.cantidad,
                'Retorno por anulación de la factura ' || v_pedido.codigo ||
                ' (jornada ' || v_pedido.fecha_operativa || '). Motivo: ' || trim(p_motivo),
                p_pedido_id, p_usuario_id);
    END LOOP;

    UPDATE core.pedidos SET estado_pedido_id = core.fn_id_catalogo('estados_pedido', 'anulado')
     WHERE id = p_pedido_id;

    INSERT INTO core.pedido_historial (pedido_id, descripcion, usuario_id)
    VALUES (p_pedido_id, 'Factura ANULADA: ' || trim(p_motivo) ||
            CASE WHEN v_diferido THEN ' · retorno imputado a la jornada ' || v_retorno ELSE '' END,
            p_usuario_id);
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_actualizar_pago(p_pedido_id BIGINT, p_estado_pago VARCHAR, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'pagos',
            (SELECT unidad_id FROM core.pedidos WHERE id = p_pedido_id));
    UPDATE core.pedidos SET estado_pago_id = core.fn_id_catalogo('estados_pago', p_estado_pago)
     WHERE id = p_pedido_id;
    UPDATE core.comprobantes_pago
       SET estado_pago_id = core.fn_id_catalogo('estados_pago', p_estado_pago),
           revisado_por_id = p_usuario_id, revisado_en = now()
     WHERE pedido_id = p_pedido_id AND revisado_en IS NULL;
END;
$$;

/* El cliente adjunta el comprobante de su transferencia: el pago queda
   «reportado» hasta que caja lo confirme o lo rechace. */
CREATE OR REPLACE PROCEDURE api.sp_registrar_comprobante(p_pedido_id BIGINT, p_archivo_url VARCHAR, INOUT p_comprobante_id BIGINT DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_fijar_usuario(NULL);
    INSERT INTO core.comprobantes_pago (pedido_id, archivo_url, estado_pago_id)
    VALUES (p_pedido_id, p_archivo_url, core.fn_id_catalogo('estados_pago', 'reportado'))
    RETURNING id INTO p_comprobante_id;
    UPDATE core.pedidos SET estado_pago_id = core.fn_id_catalogo('estados_pago', 'reportado')
     WHERE id = p_pedido_id;
END;
$$;


/* ============================================================================
   6. INVENTARIO
   ============================================================================ */

CREATE OR REPLACE PROCEDURE api.sp_registrar_entrada(
    p_unidad_id    INTEGER,
    p_insumo_id    INTEGER,
    p_tipo         VARCHAR,
    p_cantidad     NUMERIC,
    p_usuario_id   INTEGER,
    p_observacion  VARCHAR DEFAULT NULL,
    p_fecha        DATE    DEFAULT NULL,
    INOUT p_entrada_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_insumo_unidad INTEGER;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'entradas', p_unidad_id);

    IF (SELECT automatico FROM core.tipos_entrada WHERE codigo = p_tipo) THEN
        RAISE EXCEPTION 'Las entradas de tipo "%" las genera el sistema.', p_tipo;
    END IF;

    SELECT iu.id INTO v_insumo_unidad
      FROM core.insumo_unidades iu JOIN core.insumos i ON i.id = iu.insumo_id
     WHERE iu.insumo_id = p_insumo_id AND iu.unidad_id = p_unidad_id AND i.activo;
    IF v_insumo_unidad IS NULL THEN
        RAISE EXCEPTION 'El insumo % no está activo en la unidad %.', p_insumo_id, p_unidad_id;
    END IF;

    INSERT INTO core.entradas_inventario (insumo_unidad_id, tipo_entrada_id, fecha_operativa, cantidad, observacion, usuario_id)
    VALUES (v_insumo_unidad, core.fn_id_catalogo('tipos_entrada', p_tipo), p_fecha, p_cantidad,
            NULLIF(trim(p_observacion), ''), p_usuario_id)
    RETURNING id INTO p_entrada_id;
END;
$$;

/* Registra (o corrige, si no está revisado) el conteo físico de un área.
   p_detalle: [ {"insumo_id": 7, "saldo": 24}, … ] */
CREATE OR REPLACE PROCEDURE api.sp_registrar_cierre(
    p_unidad_id    INTEGER,
    p_area         VARCHAR,
    p_detalle      JSONB,
    p_usuario_id   INTEGER,
    p_fecha        DATE    DEFAULT NULL,
    p_observacion  VARCHAR DEFAULT NULL,
    INOUT p_cierre_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_area   INTEGER := core.fn_id_catalogo('areas_inventario', p_area);
    v_fecha  DATE    := COALESCE(p_fecha, core.fn_fecha_operativa(core.fn_empresa_de_unidad(p_unidad_id), now()));
    v_linea  JSONB;
    v_iu     INTEGER;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'cierres_registrar', p_unidad_id);

    IF p_detalle IS NULL OR jsonb_array_length(p_detalle) = 0 THEN
        RAISE EXCEPTION 'El cierre no tiene productos contados.';
    END IF;

    INSERT INTO core.cierres_inventario (unidad_id, area_id, estado_cierre_id, fecha_operativa, observacion, registrado_por_id)
    VALUES (p_unidad_id, v_area, core.fn_id_catalogo('estados_cierre', 'completado'), v_fecha,
            NULLIF(trim(p_observacion), ''), p_usuario_id)
    ON CONFLICT (unidad_id, area_id, fecha_operativa) DO UPDATE
       SET observacion = EXCLUDED.observacion, registrado_por_id = EXCLUDED.registrado_por_id,
           estado_cierre_id = EXCLUDED.estado_cierre_id
    RETURNING id INTO p_cierre_id;

    FOR v_linea IN SELECT * FROM jsonb_array_elements(p_detalle) LOOP
        SELECT id INTO v_iu FROM core.insumo_unidades
         WHERE insumo_id = (v_linea ->> 'insumo_id')::INTEGER AND unidad_id = p_unidad_id;
        IF v_iu IS NULL THEN
            RAISE EXCEPTION 'El insumo % no es de esta unidad.', v_linea ->> 'insumo_id';
        END IF;

        INSERT INTO core.cierre_detalles (cierre_id, insumo_unidad_id, saldo_fisico)
        VALUES (p_cierre_id, v_iu, (v_linea ->> 'saldo')::NUMERIC)
        ON CONFLICT (cierre_id, insumo_unidad_id) DO UPDATE SET saldo_fisico = EXCLUDED.saldo_fisico;
    END LOOP;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_revisar_cierre(p_cierre_id BIGINT, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'cierres_revisar',
            (SELECT unidad_id FROM core.cierres_inventario WHERE id = p_cierre_id));
    UPDATE core.cierres_inventario
       SET estado_cierre_id = core.fn_id_catalogo('estados_cierre', 'revisado'),
           revisado_por_id = p_usuario_id, revisado_en = now()
     WHERE id = p_cierre_id
       AND estado_cierre_id <> core.fn_id_catalogo('estados_cierre', 'revisado');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El cierre % no existe o ya estaba revisado.', p_cierre_id;
    END IF;
END;
$$;

/* Lleva el stock actual al saldo físico contado. Es explícito a propósito:
   el sistema no descuenta stock por ventas porque aún no hay recetas. */
CREATE OR REPLACE PROCEDURE api.sp_aplicar_cierre_a_stock(p_cierre_id BIGINT, p_usuario_id INTEGER, INOUT p_aplicados INTEGER DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'stock',
            (SELECT unidad_id FROM core.cierres_inventario WHERE id = p_cierre_id));

    UPDATE core.insumo_unidades iu
       SET stock_actual = d.saldo_fisico, actualizado_en = now()
      FROM core.cierre_detalles d
     WHERE d.cierre_id = p_cierre_id AND d.insumo_unidad_id = iu.id;
    GET DIAGNOSTICS p_aplicados = ROW_COUNT;

    UPDATE core.cierres_inventario SET aplicado_a_stock = TRUE WHERE id = p_cierre_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_ajustar_stock_minimo(p_unidad_id INTEGER, p_insumo_id INTEGER, p_minimo NUMERIC, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'stock', p_unidad_id);
    UPDATE core.insumo_unidades SET stock_minimo = p_minimo
     WHERE unidad_id = p_unidad_id AND insumo_id = p_insumo_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El insumo % no está en la unidad %.', p_insumo_id, p_unidad_id;
    END IF;
END;
$$;


/* ============================================================================
   7. CAJA Y GASTOS
   ============================================================================ */

/* Registra la base de la jornada. Si ya había una, la nueva la REEMPLAZA y la
   anterior queda guardada como no vigente. */
CREATE OR REPLACE PROCEDURE api.sp_registrar_base_caja(
    p_unidad_id    INTEGER,
    p_monto        NUMERIC,
    p_usuario_id   INTEGER,
    p_fecha        DATE    DEFAULT NULL,
    p_observacion  VARCHAR DEFAULT NULL,
    INOUT p_base_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_fecha    DATE := COALESCE(p_fecha, core.fn_fecha_operativa(core.fn_empresa_de_unidad(p_unidad_id), now()));
    v_anterior BIGINT;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'base_caja', p_unidad_id);

    UPDATE core.bases_caja SET vigente = FALSE
     WHERE unidad_id = p_unidad_id AND fecha_operativa = v_fecha AND vigente
    RETURNING id INTO v_anterior;

    IF v_anterior IS NOT NULL AND length(trim(COALESCE(p_observacion, ''))) < 3 THEN
        RAISE EXCEPTION 'Corregir la base exige escribir el motivo.';
    END IF;

    INSERT INTO core.bases_caja (unidad_id, fecha_operativa, monto, reemplaza_a_id, observacion, usuario_id)
    VALUES (p_unidad_id, v_fecha, p_monto, v_anterior, NULLIF(trim(p_observacion), ''), p_usuario_id)
    RETURNING id INTO p_base_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_registrar_gasto(
    p_unidad_id           INTEGER,
    p_categoria_gasto_id  INTEGER,
    p_metodo_pago         VARCHAR,
    p_descripcion         VARCHAR,
    p_monto               NUMERIC,
    p_usuario_id          INTEGER,
    p_fecha               DATE DEFAULT NULL,
    INOUT p_gasto_id      BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'gastos', p_unidad_id);
    INSERT INTO core.gastos (unidad_id, categoria_gasto_id, metodo_pago_id, estado_gasto_id,
                             fecha_operativa, descripcion, monto, registrado_por_id)
    VALUES (p_unidad_id, p_categoria_gasto_id, core.fn_id_catalogo('metodos_pago', p_metodo_pago),
            core.fn_id_catalogo('estados_gasto', 'registrado'), p_fecha, trim(p_descripcion), p_monto, p_usuario_id)
    RETURNING id INTO p_gasto_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_confirmar_gasto(p_gasto_id BIGINT, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'gastos_confirmar',
            (SELECT unidad_id FROM core.gastos WHERE id = p_gasto_id));
    UPDATE core.gastos
       SET estado_gasto_id = core.fn_id_catalogo('estados_gasto', 'confirmado'), confirmado_por_id = p_usuario_id
     WHERE id = p_gasto_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_anular_gasto(p_gasto_id BIGINT, p_motivo VARCHAR, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'gastos_anular',
            (SELECT unidad_id FROM core.gastos WHERE id = p_gasto_id));
    UPDATE core.gastos
       SET estado_gasto_id = core.fn_id_catalogo('estados_gasto', 'anulado'),
           motivo_anulacion = trim(p_motivo), anulado_por_id = p_usuario_id
     WHERE id = p_gasto_id;
END;
$$;


/* ============================================================================
   8. LIMPIEZA DE PRUEBAS
   Única excepción a «las facturas no se borran». Sólo Admin, escribiendo
   BORRAR, y sólo la empresa indicada. La numeración vuelve a 00001.
   Se lleva también los retornos por anulación de esas facturas (y descuenta
   del stock lo que habían devuelto). Cierres, gastos y menús no se tocan.
   ============================================================================ */
CREATE OR REPLACE PROCEDURE api.sp_borrar_facturas_prueba(
    p_empresa_id    INTEGER,
    p_confirmacion  VARCHAR,
    p_usuario_id    INTEGER,
    INOUT p_borradas INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'pedidos_anular');

    IF upper(trim(COALESCE(p_confirmacion, ''))) <> 'BORRAR' THEN
        RAISE EXCEPTION 'Escribe BORRAR para confirmar.';
    END IF;
    IF p_usuario_id IS NOT NULL
       AND p_empresa_id IS DISTINCT FROM (SELECT empresa_id FROM core.usuarios WHERE id = p_usuario_id)
       AND NOT core.fn_tiene_permiso(p_usuario_id, 'plataforma') THEN
        RAISE EXCEPTION 'No puedes borrar facturas de otra empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;

    PERFORM set_config('taseca.borrado_pruebas', 'si', TRUE);

    UPDATE core.insumo_unidades iu
       SET stock_actual = GREATEST(iu.stock_actual - e.total, 0)
      FROM (SELECT en.insumo_unidad_id, SUM(en.cantidad) AS total
              FROM core.entradas_inventario en
              JOIN core.pedidos p ON p.id = en.pedido_id
             WHERE p.empresa_id = p_empresa_id
             GROUP BY en.insumo_unidad_id) e
     WHERE iu.id = e.insumo_unidad_id;

    DELETE FROM core.entradas_inventario en USING core.pedidos p
     WHERE p.id = en.pedido_id AND p.empresa_id = p_empresa_id;
    DELETE FROM core.anulaciones a USING core.pedidos p
     WHERE p.id = a.pedido_id AND p.empresa_id = p_empresa_id;
    DELETE FROM core.pedidos WHERE empresa_id = p_empresa_id;
    GET DIAGNOSTICS p_borradas = ROW_COUNT;

    DELETE FROM core.clientes c
     WHERE c.empresa_id = p_empresa_id
       AND NOT EXISTS (SELECT 1 FROM core.pedidos p WHERE p.cliente_id = c.id);

    UPDATE core.consecutivos SET ultimo_numero = 0 WHERE empresa_id = p_empresa_id AND tipo = 'pedido';

    PERFORM set_config('taseca.borrado_pruebas', '', TRUE);
END;
$$;


/* ============================================================================
   05_VISTAS
   Lo que la aplicación lee
   ============================================================================ */

/* ============================================================================
   TASECA · 05 · VISTAS (esquema api)
   ----------------------------------------------------------------------------
   Toda lectura de la aplicación sale de aquí. La vista resuelve los joins,
   los nombres de catálogo y los cálculos (subtotal, total, vendidos, cruce):
   la aplicación sólo filtra por empresa_id / unidad_id / fecha.

   · Lo calculado NO se guarda (3FN): subtotal, total, cupos restantes, IN,
     EN y Z del cruce se derivan cada vez de los datos fuente.
   · Los reportes pesados tienen además una VISTA MATERIALIZADA que se
     refresca con api.sp_refrescar_reportes() (p. ej. cada noche).
   · Ninguna vista expone el hash del PIN.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. EMPRESA Y CONFIGURACIÓN
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_empresas AS
SELECT e.id AS empresa_id, e.codigo, e.nombre_comercial, e.razon_social, e.nit, e.eslogan,
       e.descripcion, e.estado, e.zona_horaria, e.hora_corte_operativa,
       e.telefono, e.whatsapp, e.email, e.direccion, e.horario_general,
       e.instagram_url, e.facebook_url, e.tiempo_mesa, e.tiempo_domicilio,
       e.color_primario, e.color_secundario, e.color_acento, e.color_fondo, e.logo_url,
       core.fn_fecha_operativa(e.id, now()) AS jornada_actual,
       (SELECT count(*) FROM core.unidades u WHERE u.empresa_id = e.id AND u.estado = 'activa') AS unidades_activas,
       e.creado_en, e.actualizado_en
  FROM core.empresas e;

CREATE OR REPLACE VIEW api.v_empresa_modulos AS
SELECT e.id AS empresa_id, e.nombre_comercial AS empresa, m.id AS modulo_id, m.codigo AS modulo,
       m.nombre, m.obligatorio,
       COALESCE(em.activo, FALSE) OR m.obligatorio AS activo
  FROM core.empresas e
 CROSS JOIN core.modulos m
  LEFT JOIN core.empresa_modulos em ON em.empresa_id = e.id AND em.modulo_id = m.id;

CREATE OR REPLACE VIEW api.v_metodos_pago AS
SELECT emp.empresa_id, mp.id AS metodo_pago_id, mp.codigo, mp.nombre, mp.grupo_caja,
       emp.descripcion, emp.activo, emp.orden
  FROM core.empresa_metodos_pago emp
  JOIN core.metodos_pago mp ON mp.id = emp.metodo_pago_id;

CREATE OR REPLACE VIEW api.v_cuentas_recaudo AS
SELECT id AS cuenta_id, empresa_id, entidad, tipo_cuenta, numero, titular, activa
  FROM core.cuentas_recaudo;


/* ============================================================================
   2. UNIDADES, MESAS, ZONAS
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_unidades AS
SELECT u.id AS unidad_id, u.empresa_id, e.nombre_comercial AS empresa,
       u.nombre, u.nombre_corto, u.estado, (u.estado = 'activa') AS activa,
       t.codigo AS tipo_negocio, t.nombre AS tipo_negocio_nombre, t.icono AS tipo_negocio_icono,
       u.direccion, u.ciudad, u.telefono, u.whatsapp, u.horario, u.mapa_url, u.color, u.logo_url,
       (SELECT count(*) FROM core.mesas m WHERE m.unidad_id = u.id AND m.activa)                AS mesas,
       (SELECT count(*) FROM core.producto_unidades pu WHERE pu.unidad_id = u.id)               AS productos_carta,
       (SELECT count(*) FROM core.insumo_unidades iu WHERE iu.unidad_id = u.id)                 AS insumos_inventario,
       EXISTS (SELECT 1 FROM core.zonas_domicilio z WHERE z.unidad_id = u.id AND z.activa)      AS tiene_zonas,
       u.creado_en, u.actualizado_en
  FROM core.unidades u
  JOIN core.empresas e      ON e.id = u.empresa_id
  JOIN core.tipos_negocio t ON t.id = u.tipo_negocio_id;

CREATE OR REPLACE VIEW api.v_mesas AS
SELECT m.id AS mesa_id, m.unidad_id, u.empresa_id, u.nombre AS unidad, m.numero, m.activa
  FROM core.mesas m
  JOIN core.unidades u ON u.id = m.unidad_id;

CREATE OR REPLACE VIEW api.v_zonas_domicilio AS
SELECT z.id AS zona_id, z.unidad_id, u.empresa_id, z.nombre, z.costo, z.pedido_minimo, z.activa
  FROM core.zonas_domicilio z
  JOIN core.unidades u ON u.id = z.unidad_id;


/* ============================================================================
   3. USUARIOS Y PERMISOS
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_usuarios AS
SELECT us.id AS usuario_id, us.empresa_id, e.nombre_comercial AS empresa,
       us.nombre, us.usuario, r.codigo AS rol, r.nombre AS rol_nombre, r.alcance,
       us.activo, us.ultimo_acceso,
       COALESCE((SELECT array_agg(uu.unidad_id ORDER BY uu.unidad_id)
                   FROM core.usuario_unidades uu WHERE uu.usuario_id = us.id), '{}') AS unidades_asignadas,
       NOT EXISTS (SELECT 1 FROM core.usuario_unidades uu WHERE uu.usuario_id = us.id) AS todas_las_unidades,
       us.creado_en
  FROM core.usuarios us
  JOIN core.roles r ON r.id = us.rol_id
  LEFT JOIN core.empresas e ON e.id = us.empresa_id;

/* Los permisos EFECTIVOS: los del rol, filtrados por los módulos que tiene
   la empresa. Es lo que la aplicación consulta para mostrar u ocultar. */
CREATE OR REPLACE VIEW api.v_permisos_usuario AS
SELECT us.id AS usuario_id, us.empresa_id, p.codigo AS permiso, p.descripcion, m.codigo AS modulo
  FROM core.usuarios us
  JOIN core.roles r         ON r.id = us.rol_id
  JOIN core.rol_permisos rp ON rp.rol_id = r.id
  JOIN core.permisos p      ON p.id = rp.permiso_id
  LEFT JOIN core.modulos m  ON m.id = p.modulo_id
 WHERE us.activo
   AND (r.alcance = 'plataforma' OR m.id IS NULL OR core.fn_empresa_tiene_modulo(us.empresa_id, m.codigo));

CREATE OR REPLACE VIEW api.v_roles AS
SELECT r.id AS rol_id, r.codigo, r.nombre, r.descripcion, r.alcance, r.icono,
       array_agg(p.codigo ORDER BY p.codigo) FILTER (WHERE p.id IS NOT NULL) AS permisos
  FROM core.roles r
  LEFT JOIN core.rol_permisos rp ON rp.rol_id = r.id
  LEFT JOIN core.permisos p      ON p.id = rp.permiso_id
 GROUP BY r.id;


/* ============================================================================
   4. CARTA
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_categorias AS
SELECT c.id AS categoria_id, cu.unidad_id, c.empresa_id, c.nombre, c.icono, c.orden, c.activa,
       (SELECT count(*) FROM core.productos p
          JOIN core.producto_unidades pu ON pu.producto_id = p.id AND pu.unidad_id = cu.unidad_id
         WHERE p.categoria_id = c.id AND p.activo) AS productos_activos
  FROM core.categorias c
  JOIN core.categoria_unidades cu ON cu.categoria_id = c.id;

/* Una fila por producto y unidad que lo vende. `disponible` es lo que el
   portal usa para mostrar "+ Agregar" o "Agotado". */
CREATE OR REPLACE VIEW api.v_carta AS
SELECT p.id AS producto_id, pu.unidad_id, p.empresa_id, u.nombre AS unidad,
       c.id AS categoria_id, c.nombre AS categoria, c.icono AS categoria_icono, c.orden AS categoria_orden,
       p.codigo, p.nombre, p.descripcion, p.precio, p.imagen_url, p.orden,
       et.codigo AS etiqueta, et.nombre AS etiqueta_nombre,
       p.activo, pu.agotado,
       (p.activo AND c.activa AND NOT pu.agotado AND u.estado = 'activa') AS disponible,
       (p.precio = 0) AS sin_precio
  FROM core.productos p
  JOIN core.producto_unidades pu ON pu.producto_id = p.id
  JOIN core.unidades u           ON u.id = pu.unidad_id
  JOIN core.categorias c         ON c.id = p.categoria_id
  LEFT JOIN core.etiquetas_producto et ON et.id = p.etiqueta_id;


/* ============================================================================
   5. MENÚ DEL DÍA
   ============================================================================ */

/* Cabecera del menú con el texto público ya resuelto:
   el de la fecha → el de la unidad → el de fábrica. */
CREATE OR REPLACE VIEW api.v_menu_dia AS
SELECT m.id AS menu_dia_id, m.unidad_id, u.empresa_id, u.nombre AS unidad, m.fecha,
       t.codigo AS tipo, t.nombre AS tipo_nombre,
       m.nombre, m.descripcion, m.precio, m.disponible,
       COALESCE(m.titulo_publico, tx.titulo, 'Menú del día')                          AS titulo_publico,
       COALESCE(m.mensaje_publico, tx.mensaje, 'Consulta las opciones disponibles para hoy.') AS mensaje_publico,
       CASE WHEN m.titulo_publico IS NOT NULL THEN 'fecha'
            WHEN tx.titulo IS NOT NULL THEN 'unidad' ELSE 'defecto' END                AS origen_texto,
       CASE
           WHEN NOT m.disponible THEN FALSE
           WHEN t.codigo = 'armado' THEN m.precio IS NOT NULL AND EXISTS (
                SELECT 1 FROM core.menu_categorias c JOIN core.menu_opciones o ON o.menu_categoria_id = c.id
                 WHERE c.menu_dia_id = m.id AND c.activa AND o.activa)
           ELSE EXISTS (SELECT 1 FROM core.platos_dia pd WHERE pd.menu_dia_id = m.id AND pd.disponible)
       END AS publicado,
       m.creado_en, m.actualizado_en
  FROM core.menus_dia m
  JOIN core.unidades u   ON u.id = m.unidad_id
  JOIN core.tipos_menu t ON t.id = m.tipo_menu_id
  LEFT JOIN core.textos_menu_unidad tx ON tx.unidad_id = m.unidad_id;

CREATE OR REPLACE VIEW api.v_menu_opciones AS
SELECT c.menu_dia_id, m.unidad_id, m.fecha,
       c.id AS categoria_id, c.nombre AS categoria, c.icono, c.orden AS categoria_orden,
       c.obligatoria, c.max_seleccion, c.activa AS categoria_activa,
       CASE WHEN c.max_seleccion > 1 THEN 'Elige hasta ' || c.max_seleccion ELSE 'Elige 1' END ||
       CASE WHEN c.obligatoria THEN ' · Obligatorio' ELSE ' · Opcional' END AS regla,
       o.id AS opcion_id, o.nombre AS opcion, o.orden AS opcion_orden, o.activa AS opcion_activa
  FROM core.menu_categorias c
  JOIN core.menus_dia m ON m.id = c.menu_dia_id
  LEFT JOIN core.menu_opciones o ON o.menu_categoria_id = c.id;

CREATE OR REPLACE VIEW api.v_platos_dia AS
SELECT pd.id AS plato_dia_id, pd.menu_dia_id, m.unidad_id, m.fecha,
       pd.nombre, pd.descripcion, pd.emoji, pd.precio, pd.cupos, pd.disponible, pd.orden,
       core.fn_vendidos_plato(pd.id) AS vendidos,
       CASE WHEN pd.cupos IS NULL THEN NULL ELSE GREATEST(pd.cupos - core.fn_vendidos_plato(pd.id), 0) END AS cupos_restantes,
       (pd.disponible AND m.disponible
        AND (pd.cupos IS NULL OR core.fn_vendidos_plato(pd.id) < pd.cupos)) AS se_puede_pedir
  FROM core.platos_dia pd
  JOIN core.menus_dia m ON m.id = pd.menu_dia_id;

/* El menú completo de una unidad y fecha en UN documento JSON: lo que el
   portal necesita para pintar en una sola consulta. */
CREATE OR REPLACE VIEW api.v_menu_publico AS
SELECT md.unidad_id, md.unidad, md.empresa_id, md.fecha, md.tipo, md.publicado,
       md.titulo_publico, md.mensaje_publico,
       jsonb_build_object(
           'menu_dia_id', md.menu_dia_id,
           'tipo', md.tipo,
           'nombre', md.nombre,
           'descripcion', md.descripcion,
           'precio', md.precio,
           'categorias', COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'categoria_id', c.id, 'nombre', c.nombre, 'icono', c.icono,
                          'obligatoria', c.obligatoria, 'max_seleccion', c.max_seleccion,
                          'opciones', (SELECT COALESCE(jsonb_agg(jsonb_build_object('opcion_id', o.id, 'nombre', o.nombre)
                                                                 ORDER BY o.orden), '[]')
                                         FROM core.menu_opciones o WHERE o.menu_categoria_id = c.id AND o.activa))
                      ORDER BY c.orden)
                 FROM core.menu_categorias c
                WHERE c.menu_dia_id = md.menu_dia_id AND c.activa
                  AND EXISTS (SELECT 1 FROM core.menu_opciones o WHERE o.menu_categoria_id = c.id AND o.activa)
           ), '[]'),
           'platos', COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'plato_dia_id', p.plato_dia_id, 'nombre', p.nombre, 'descripcion', p.descripcion,
                          'emoji', p.emoji, 'precio', p.precio, 'cupos_restantes', p.cupos_restantes,
                          'se_puede_pedir', p.se_puede_pedir)
                      ORDER BY p.orden)
                 FROM api.v_platos_dia p
                WHERE p.menu_dia_id = md.menu_dia_id AND p.disponible
           ), '[]')
       ) AS menu
  FROM api.v_menu_dia md;


/* ============================================================================
   6. PEDIDOS / FACTURAS
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_pedidos AS
SELECT p.id AS pedido_id, p.empresa_id, p.unidad_id, u.nombre AS unidad, p.codigo,
       tp.codigo AS tipo, tp.nombre AS tipo_nombre,
       ep.codigo AS estado, ep.nombre AS estado_nombre, ep.orden AS estado_orden, ep.es_final,
       ep.cuenta_como_venta,
       pg.codigo AS estado_pago, pg.nombre AS estado_pago_nombre,
       mp.codigo AS metodo_pago, mp.nombre AS metodo_pago_nombre, mp.grupo_caja,
       me.numero AS mesa,
       cl.nombre AS cliente, cl.telefono AS cliente_telefono,
       p.direccion_entrega, p.indicaciones, z.nombre AS zona,
       COALESCE(it.subtotal, 0)                     AS subtotal,
       p.costo_domicilio,
       COALESCE(it.subtotal, 0) + p.costo_domicilio AS total,
       COALESCE(it.unidades, 0)                     AS productos,
       p.paga_con,
       CASE WHEN p.paga_con IS NOT NULL THEN p.paga_con - (COALESCE(it.subtotal, 0) + p.costo_domicilio) END AS cambio,
       p.fecha_operativa, p.motivo_cancelacion,
       us.nombre AS tomado_por,
       p.creado_en, p.actualizado_en
  FROM core.pedidos p
  JOIN core.unidades u        ON u.id = p.unidad_id
  JOIN core.tipos_pedido tp   ON tp.id = p.tipo_pedido_id
  JOIN core.estados_pedido ep ON ep.id = p.estado_pedido_id
  JOIN core.estados_pago pg   ON pg.id = p.estado_pago_id
  JOIN core.metodos_pago mp   ON mp.id = p.metodo_pago_id
  LEFT JOIN core.mesas me           ON me.id = p.mesa_id
  LEFT JOIN core.clientes cl        ON cl.id = p.cliente_id
  LEFT JOIN core.zonas_domicilio z  ON z.id = p.zona_domicilio_id
  LEFT JOIN core.usuarios us        ON us.id = p.tomado_por_id
  LEFT JOIN LATERAL (
        SELECT SUM(i.precio_unitario * i.cantidad) AS subtotal, SUM(i.cantidad) AS unidades
          FROM core.pedido_items i WHERE i.pedido_id = p.id
  ) it ON TRUE;

/* Líneas de la factura con el detalle del menú armado ya escrito:
   "Sopa: Sancocho · Principio: Arroz, Ensalada · Proteína: Pollo". */
CREATE OR REPLACE VIEW api.v_pedido_items AS
SELECT i.id AS pedido_item_id, i.pedido_id, p.codigo, p.unidad_id, p.fecha_operativa,
       CASE WHEN i.producto_id  IS NOT NULL THEN 'carta'
            WHEN i.plato_dia_id IS NOT NULL THEN 'chef'
            ELSE 'armado' END AS origen,
       i.producto_id, i.plato_dia_id, i.menu_dia_id,
       i.nombre, i.precio_unitario, i.cantidad, i.precio_unitario * i.cantidad AS total_linea,
       i.notas,
       (SELECT string_agg(g.categoria || ': ' || g.opciones, ' · ' ORDER BY g.orden)
          FROM (SELECT c.nombre AS categoria, c.orden,
                       string_agg(o.nombre, ', ' ORDER BY o.orden) AS opciones
                  FROM core.pedido_item_opciones x
                  JOIN core.menu_opciones o   ON o.id = x.menu_opcion_id
                  JOIN core.menu_categorias c ON c.id = o.menu_categoria_id
                 WHERE x.pedido_item_id = i.id
                 GROUP BY c.nombre, c.orden) g) AS detalle
  FROM core.pedido_items i
  JOIN core.pedidos p ON p.id = i.pedido_id;

CREATE OR REPLACE VIEW api.v_pedido_historial AS
SELECT h.id AS historial_id, h.pedido_id, p.codigo, h.descripcion,
       e.codigo AS estado, us.nombre AS usuario, h.creado_en
  FROM core.pedido_historial h
  JOIN core.pedidos p ON p.id = h.pedido_id
  LEFT JOIN core.estados_pedido e ON e.id = h.estado_pedido_id
  LEFT JOIN core.usuarios us      ON us.id = h.usuario_id;

/* Lo que ve el CLIENTE al seguir su pedido: sin teléfono, sin dirección, sin
   nada que no sea suyo de mostrar. Pasos ya calculados según el tipo. */
CREATE OR REPLACE VIEW api.v_seguimiento_pedido AS
SELECT vp.empresa_id, e.codigo AS empresa_codigo, vp.pedido_id, vp.codigo, vp.unidad,
       vp.tipo, vp.estado, vp.estado_nombre, vp.total, vp.estado_pago_nombre, vp.metodo_pago_nombre,
       (SELECT count(*) FROM core.estados_pedido x
         WHERE x.orden < 90 AND (NOT x.solo_domicilio OR vp.tipo = 'domicilio'))             AS pasos_totales,
       CASE WHEN vp.estado_orden >= 90 THEN NULL ELSE
       (SELECT count(*) FROM core.estados_pedido x
         WHERE x.orden <= vp.estado_orden AND (NOT x.solo_domicilio OR vp.tipo = 'domicilio')) END AS paso_actual,
       (SELECT jsonb_agg(jsonb_build_object('estado', x.codigo, 'nombre', x.nombre,
                                            'hecho', x.orden <= vp.estado_orden AND vp.estado_orden < 90)
                         ORDER BY x.orden)
          FROM core.estados_pedido x
         WHERE x.orden < 90 AND (NOT x.solo_domicilio OR vp.tipo = 'domicilio'))              AS pasos,
       (SELECT max(h.creado_en) FROM core.pedido_historial h WHERE h.pedido_id = vp.pedido_id) AS ultimo_cambio,
       vp.creado_en
  FROM api.v_pedidos vp
  JOIN core.empresas e ON e.id = vp.empresa_id;

/* Tablero de cocina: pedidos vivos de la unidad, del más antiguo al más
   nuevo, con sus líneas listas para imprimir. */
CREATE OR REPLACE VIEW api.v_cocina AS
SELECT vp.unidad_id, vp.pedido_id, vp.codigo, vp.tipo, vp.mesa, vp.estado, vp.estado_nombre,
       vp.creado_en,
       floor(EXTRACT(EPOCH FROM (now() - vp.creado_en)) / 60)::INTEGER AS minutos_espera,
       (SELECT jsonb_agg(jsonb_build_object('cantidad', i.cantidad, 'nombre', i.nombre,
                                            'detalle', i.detalle, 'notas', i.notas) ORDER BY i.pedido_item_id)
          FROM api.v_pedido_items i WHERE i.pedido_id = vp.pedido_id) AS items
  FROM api.v_pedidos vp
 WHERE vp.estado IN ('nuevo', 'preparacion', 'listo');


/* ============================================================================
   7. VENTAS Y CAJA
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_ventas_diarias AS
SELECT vp.empresa_id, vp.unidad_id, vp.unidad, vp.fecha_operativa,
       vp.metodo_pago, vp.metodo_pago_nombre, vp.grupo_caja,
       count(*)                   AS pedidos,
       SUM(vp.subtotal)           AS subtotal,
       SUM(vp.costo_domicilio)    AS domicilios,
       SUM(vp.total)              AS total
  FROM api.v_pedidos vp
 WHERE vp.cuenta_como_venta
 GROUP BY vp.empresa_id, vp.unidad_id, vp.unidad, vp.fecha_operativa,
          vp.metodo_pago, vp.metodo_pago_nombre, vp.grupo_caja;

CREATE OR REPLACE VIEW api.v_ventas_producto AS
SELECT p.empresa_id, p.unidad_id, p.fecha_operativa, i.origen, i.nombre,
       SUM(i.cantidad)    AS cantidad,
       SUM(i.total_linea) AS total
  FROM api.v_pedido_items i
  JOIN core.pedidos p        ON p.id = i.pedido_id
  JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
 WHERE e.cuenta_como_venta
 GROUP BY p.empresa_id, p.unidad_id, p.fecha_operativa, i.origen, i.nombre;

CREATE OR REPLACE VIEW api.v_gastos AS
SELECT g.id AS gasto_id, g.unidad_id, u.empresa_id, u.nombre AS unidad, g.fecha_operativa,
       cg.nombre AS categoria, cg.icono AS categoria_icono,
       mp.codigo AS metodo_pago, mp.nombre AS metodo_pago_nombre, mp.grupo_caja,
       eg.codigo AS estado, eg.nombre AS estado_nombre,
       g.descripcion, g.monto, g.motivo_anulacion,
       ur.nombre AS registrado_por, uc.nombre AS confirmado_por, ua.nombre AS anulado_por,
       g.creado_en
  FROM core.gastos g
  JOIN core.unidades u          ON u.id = g.unidad_id
  JOIN core.categorias_gasto cg ON cg.id = g.categoria_gasto_id
  JOIN core.metodos_pago mp     ON mp.id = g.metodo_pago_id
  JOIN core.estados_gasto eg    ON eg.id = g.estado_gasto_id
  LEFT JOIN core.usuarios ur ON ur.id = g.registrado_por_id
  LEFT JOIN core.usuarios uc ON uc.id = g.confirmado_por_id
  LEFT JOIN core.usuarios ua ON ua.id = g.anulado_por_id;

CREATE OR REPLACE VIEW api.v_categorias_gasto AS
SELECT id AS categoria_gasto_id, empresa_id, nombre, icono, activa
  FROM core.categorias_gasto;

CREATE OR REPLACE VIEW api.v_bases_caja AS
SELECT b.id AS base_id, b.unidad_id, u.empresa_id, b.fecha_operativa, b.monto, b.vigente,
       b.reemplaza_a_id, b.observacion, us.nombre AS registrada_por, b.creado_en
  FROM core.bases_caja b
  JOIN core.unidades u ON u.id = b.unidad_id
  LEFT JOIN core.usuarios us ON us.id = b.usuario_id;

/* Cruce de caja de la jornada: con qué se abrió, qué entró por cada grupo de
   pago, qué salió en efectivo y cuánto efectivo debería haber en el cajón. */
CREATE OR REPLACE VIEW api.v_cruce_caja AS
WITH jornadas AS (
    SELECT unidad_id, fecha_operativa FROM core.bases_caja WHERE vigente
    UNION
    SELECT unidad_id, fecha_operativa FROM core.pedidos
    UNION
    SELECT unidad_id, fecha_operativa FROM core.gastos
),
ventas AS (
    SELECT unidad_id, fecha_operativa,
           SUM(total) FILTER (WHERE grupo_caja = 'efectivo')      AS efectivo,
           SUM(total) FILTER (WHERE grupo_caja = 'transferencia') AS transferencia,
           SUM(total) FILTER (WHERE grupo_caja = 'otros')         AS otros,
           SUM(total)                                             AS total,
           SUM(pedidos)                                           AS pedidos
      FROM api.v_ventas_diarias
     GROUP BY unidad_id, fecha_operativa
),
gastos AS (
    SELECT unidad_id, fecha_operativa,
           SUM(monto) FILTER (WHERE grupo_caja = 'efectivo') AS efectivo,
           SUM(monto)                                        AS total
      FROM api.v_gastos
     WHERE estado <> 'anulado'
     GROUP BY unidad_id, fecha_operativa
)
SELECT j.unidad_id, u.empresa_id, u.nombre AS unidad, j.fecha_operativa,
       COALESCE(b.monto, 0)             AS base,
       COALESCE(v.pedidos, 0)           AS pedidos,
       COALESCE(v.efectivo, 0)          AS ventas_efectivo,
       COALESCE(v.transferencia, 0)     AS ventas_transferencia,
       COALESCE(v.otros, 0)             AS ventas_otros,
       COALESCE(v.total, 0)             AS ventas_total,
       COALESCE(g.efectivo, 0)          AS gastos_efectivo,
       COALESCE(g.total, 0)             AS gastos_total,
       COALESCE(b.monto, 0) + COALESCE(v.efectivo, 0) - COALESCE(g.efectivo, 0) AS efectivo_esperado
  FROM jornadas j
  JOIN core.unidades u ON u.id = j.unidad_id
  LEFT JOIN core.bases_caja b ON b.unidad_id = j.unidad_id AND b.fecha_operativa = j.fecha_operativa AND b.vigente
  LEFT JOIN ventas v ON v.unidad_id = j.unidad_id AND v.fecha_operativa = j.fecha_operativa
  LEFT JOIN gastos g ON g.unidad_id = j.unidad_id AND g.fecha_operativa = j.fecha_operativa;

CREATE OR REPLACE VIEW api.v_anulaciones AS
SELECT a.id AS anulacion_id, p.empresa_id, p.unidad_id, p.codigo, a.motivo,
       us.nombre AS anulada_por, a.jornada_original, a.jornada_retorno,
       (a.jornada_retorno <> a.jornada_original) AS retorno_diferido,
       vp.total, vp.metodo_pago_nombre, a.creado_en
  FROM core.anulaciones a
  JOIN core.pedidos p    ON p.id = a.pedido_id
  JOIN api.v_pedidos vp  ON vp.pedido_id = p.id
  LEFT JOIN core.usuarios us ON us.id = a.usuario_id;


/* ============================================================================
   8. INVENTARIO
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_stock AS
SELECT iu.id AS insumo_unidad_id, iu.unidad_id, u.nombre AS unidad, i.empresa_id,
       i.id AS insumo_id, i.codigo, i.nombre,
       ci.nombre AS categoria, a.codigo AS area, a.nombre AS area_nombre,
       um.codigo AS unidad_medida, um.nombre AS unidad_medida_nombre,
       iu.stock_actual, iu.stock_minimo,
       (iu.stock_minimo > 0 AND iu.stock_actual <= iu.stock_minimo) AS bajo_minimo,
       i.activo,
       COALESCE((SELECT array_agg(pr.nombre ORDER BY pr.nombre)
                   FROM core.producto_insumos pi JOIN core.productos pr ON pr.id = pi.producto_id
                  WHERE pi.insumo_id = i.id), '{}') AS se_vende_como
  FROM core.insumo_unidades iu
  JOIN core.insumos i            ON i.id = iu.insumo_id
  JOIN core.unidades u           ON u.id = iu.unidad_id
  JOIN core.categorias_insumo ci ON ci.id = i.categoria_insumo_id
  JOIN core.areas_inventario a   ON a.id = i.area_id
  JOIN core.unidades_medida um   ON um.id = i.unidad_medida_id;

CREATE OR REPLACE VIEW api.v_entradas AS
SELECT en.id AS entrada_id, s.unidad_id, s.empresa_id, s.codigo, s.nombre AS insumo, s.area,
       te.codigo AS tipo, te.nombre AS tipo_nombre, te.automatico,
       en.fecha_operativa, en.cantidad, en.observacion,
       p.codigo AS factura, us.nombre AS registrada_por, en.creado_en
  FROM core.entradas_inventario en
  JOIN api.v_stock s          ON s.insumo_unidad_id = en.insumo_unidad_id
  JOIN core.tipos_entrada te  ON te.id = en.tipo_entrada_id
  LEFT JOIN core.pedidos p    ON p.id = en.pedido_id
  LEFT JOIN core.usuarios us  ON us.id = en.usuario_id;

CREATE OR REPLACE VIEW api.v_cierres AS
SELECT c.id AS cierre_id, c.unidad_id, u.empresa_id, u.nombre AS unidad, u.nombre_corto,
       u.nombre_corto || '-' || a.codigo || '-' || to_char(c.fecha_operativa, 'YYMMDD') AS codigo,
       a.codigo AS area, a.nombre AS area_nombre, c.fecha_operativa,
       ec.codigo AS estado, ec.nombre AS estado_nombre, c.observacion, c.aplicado_a_stock,
       ur.nombre AS registrado_por, uv.nombre AS revisado_por, c.revisado_en,
       (SELECT count(*) FROM core.cierre_detalles d WHERE d.cierre_id = c.id) AS productos_contados,
       c.creado_en, c.actualizado_en
  FROM core.cierres_inventario c
  JOIN core.unidades u         ON u.id = c.unidad_id
  JOIN core.areas_inventario a ON a.id = c.area_id
  JOIN core.estados_cierre ec  ON ec.id = c.estado_cierre_id
  LEFT JOIN core.usuarios ur ON ur.id = c.registrado_por_id
  LEFT JOIN core.usuarios uv ON uv.id = c.revisado_por_id;

/* CRUCE DE INVENTARIO — la planilla IN · EN · Z · SD de las meseras.

     IN  saldo físico del cierre ANTERIOR de ese insumo en la unidad
     EN  entradas desde el día siguiente a ese cierre hasta este
     Z   lo vendido en ese mismo tramo (ventas efectivas × insumo por venta)
     SD  el saldo contado en este cierre
     DIFERENCIA = IN + EN − Z − SD   (positivo = falta mercancía)

   Una factura anulada no cuenta en Z. Si su jornada ya estaba cerrada, la
   mercancía vuelve como entrada de hoy (tipo retorno_anulacion). */
CREATE OR REPLACE VIEW api.v_cruce_inventario AS
WITH base AS (
    SELECT d.id AS cierre_detalle_id, c.id AS cierre_id, c.unidad_id, c.area_id, c.fecha_operativa,
           d.insumo_unidad_id, iu.insumo_id, d.saldo_fisico,
           ant.saldo_fisico    AS saldo_anterior,
           ant.fecha_operativa AS fecha_anterior
      FROM core.cierre_detalles d
      JOIN core.cierres_inventario c ON c.id = d.cierre_id
      JOIN core.insumo_unidades iu   ON iu.id = d.insumo_unidad_id
      LEFT JOIN LATERAL (
            SELECT d2.saldo_fisico, c2.fecha_operativa
              FROM core.cierre_detalles d2
              JOIN core.cierres_inventario c2 ON c2.id = d2.cierre_id
             WHERE d2.insumo_unidad_id = d.insumo_unidad_id
               AND c2.fecha_operativa < c.fecha_operativa
             ORDER BY c2.fecha_operativa DESC
             LIMIT 1
      ) ant ON TRUE
)
SELECT b.cierre_id, b.cierre_detalle_id, b.unidad_id, u.empresa_id, u.nombre AS unidad,
       a.codigo AS area, b.fecha_operativa, b.fecha_anterior,
       i.codigo, i.nombre AS insumo,
       COALESCE(b.saldo_anterior, 0) AS inicial,
       (b.saldo_anterior IS NULL)    AS sin_cierre_anterior,
       COALESCE(en.cantidad, 0)      AS entradas,
       COALESCE(z.cantidad, 0)       AS ventas,
       b.saldo_fisico                AS saldo_fisico,
       COALESCE(b.saldo_anterior, 0) + COALESCE(en.cantidad, 0) - COALESCE(z.cantidad, 0) AS saldo_esperado,
       COALESCE(b.saldo_anterior, 0) + COALESCE(en.cantidad, 0) - COALESCE(z.cantidad, 0) - b.saldo_fisico AS diferencia
  FROM base b
  JOIN core.unidades u         ON u.id = b.unidad_id
  JOIN core.areas_inventario a ON a.id = b.area_id
  JOIN core.insumos i          ON i.id = b.insumo_id
  LEFT JOIN LATERAL (
        SELECT SUM(e.cantidad) AS cantidad
          FROM core.entradas_inventario e
         WHERE e.insumo_unidad_id = b.insumo_unidad_id
           AND e.fecha_operativa <= b.fecha_operativa
           AND e.fecha_operativa >  COALESCE(b.fecha_anterior, b.fecha_operativa - 1)
  ) en ON TRUE
  LEFT JOIN LATERAL (
        SELECT SUM(it.cantidad * pi.cantidad) AS cantidad
          FROM core.pedido_items it
          JOIN core.pedidos p           ON p.id = it.pedido_id
          JOIN core.estados_pedido ep   ON ep.id = p.estado_pedido_id
          JOIN core.producto_insumos pi ON pi.producto_id = it.producto_id
         WHERE pi.insumo_id = b.insumo_id
           AND p.unidad_id = b.unidad_id
           AND ep.cuenta_como_venta
           AND p.fecha_operativa <= b.fecha_operativa
           AND p.fecha_operativa >  COALESCE(b.fecha_anterior, b.fecha_operativa - 1)
  ) z ON TRUE;


/* ============================================================================
   9. AUDITORÍA
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_auditoria AS
SELECT a.id AS auditoria_id, a.tabla, a.registro_id, a.accion,
       us.nombre AS usuario, us.empresa_id, a.usuario_db,
       a.datos_antes, a.datos_despues, a.creado_en
  FROM core.auditoria a
  LEFT JOIN core.usuarios us ON us.id = a.usuario_id;


/* ============================================================================
   10. REPORTES MATERIALIZADOS
   ============================================================================ */

CREATE MATERIALIZED VIEW IF NOT EXISTS api.mv_ventas_mensuales AS
SELECT empresa_id, unidad_id, unidad,
       date_trunc('month', fecha_operativa)::DATE AS mes,
       SUM(pedidos) AS pedidos, SUM(subtotal) AS subtotal, SUM(domicilios) AS domicilios, SUM(total) AS total
  FROM api.v_ventas_diarias
 GROUP BY empresa_id, unidad_id, unidad, date_trunc('month', fecha_operativa)
WITH DATA;

CREATE UNIQUE INDEX IF NOT EXISTS uq_mv_ventas_mensuales ON api.mv_ventas_mensuales (unidad_id, mes);

CREATE OR REPLACE PROCEDURE api.sp_refrescar_reportes()
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    -- CONCURRENTLY: los reportes siguen consultables mientras se recalculan
    REFRESH MATERIALIZED VIEW CONCURRENTLY api.mv_ventas_mensuales;
END;
$$;


/* ============================================================================
   11. FUNCIONES DE CONSULTA
   ============================================================================ */

/* Seguimiento público: el cliente escribe "27" y ve la factura 00027 de SU
   empresa. Nunca devuelve pedidos de otra empresa. */
CREATE OR REPLACE FUNCTION api.fn_seguimiento_pedido(p_empresa_codigo VARCHAR, p_codigo VARCHAR)
RETURNS SETOF api.v_seguimiento_pedido
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT s.*
      FROM api.v_seguimiento_pedido s
      JOIN core.empresas e ON e.id = s.empresa_id
     WHERE e.codigo = p_empresa_codigo
       AND s.codigo = core.fn_normalizar_codigo_pedido(e.id, p_codigo);
$$;

/* Carta disponible de una unidad, lista para el portal. */
CREATE OR REPLACE FUNCTION api.fn_carta_unidad(p_unidad_id INTEGER)
RETURNS SETOF api.v_carta
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT * FROM api.v_carta
     WHERE unidad_id = p_unidad_id AND activo
     ORDER BY categoria_orden, orden, nombre;
$$;

/* Menú de hoy (jornada operativa) de una unidad. */
CREATE OR REPLACE FUNCTION api.fn_menu_hoy(p_unidad_id INTEGER)
RETURNS SETOF api.v_menu_publico
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT * FROM api.v_menu_publico
     WHERE unidad_id = p_unidad_id
       AND fecha = core.fn_fecha_operativa(core.fn_empresa_de_unidad(p_unidad_id), now());
$$;


/* ============================================================================
   06_DATOS_INICIALES
   Catálogos y la estructura de ejemplo (NASCAR)
   ============================================================================ */

/* ============================================================================
   TASECA · 06 · DATOS INICIALES
   ----------------------------------------------------------------------------
   Catálogos del sistema + la estructura REAL de NASCAR:

     NASCAR-Comidas       Restaurante  · sólo menú del día (3 platos de ejemplo)
     Chicharrón Mental    Restaurante  · sólo menú del día (2 platos de ejemplo)
     NASCAR Bar VIP       Bar          · carta de 29 productos (precio 0) + 29 insumos
     COMIC'ENDO AREPA     Arepera      · carta de 58 productos + 18 insumos

   Generado desde el catálogo de la aplicación (js/data.js). Todo se
   referencia por códigos, nunca por ids fijos: los SERIAL asignan los ids.

   Usuarios de prueba (PIN guardado con bcrypt):
     super / 9000       SuperAdmin de Taseca (sin empresa)
     admin / 2580       Admin de NASCAR
     gerencia / 1234    Administrador
     mesero / 1111      Mesero        · NASCAR-Comidas
     cocina / 2222      Cocinero      · NASCAR-Comidas
     domicilios / 3333  Domiciliario
     caja / 4444        Caja          · NASCAR-Comidas
   ⚠️ Son PIN de prueba: cámbialos antes de producción.
   ============================================================================ */

SET search_path = core, public;

BEGIN;

/* ---------------------------------------------------------------- CATÁLOGOS */

INSERT INTO core.modulos (codigo, nombre, descripcion, obligatorio) VALUES
    ('basico', 'Básico', 'La operación de punta a punta: carta, menú del día, pedidos, pagos, ventas, usuarios y gastos.', TRUE),
    ('stock', 'Stock', 'Catálogo de inventario y entradas de mercancía.', FALSE),
    ('cierre', 'Cierre', 'Cierre de inventario diario y cruce IN · EN · Z · SD.', FALSE);

INSERT INTO core.tipos_negocio (codigo, nombre, icono) VALUES
    ('restaurante', 'Restaurante', '🍽️'),
    ('bar', 'Bar', '🍺'),
    ('arepera', 'Arepera / Comidas', '🫓'),
    ('cafeteria', 'Cafetería', '☕'),
    ('fruteria', 'Frutería', '🍓'),
    ('comidas_rapidas', 'Comidas rápidas', '🍔'),
    ('heladeria', 'Heladería', '🍦'),
    ('otro', 'Otro', '🏪');

INSERT INTO core.roles (codigo, nombre, descripcion, alcance, icono) VALUES
    ('superadmin', 'SuperAdmin', 'Administra la plataforma Taseca: empresas, módulos y accesos.', 'plataforma', '🛠️'),
    ('admin', 'Admin', 'Control total del sistema y su configuración.', 'empresa', '👑'),
    ('administrador', 'Administrador', 'Opera el restaurante completo, sin tocar la configuración sensible.', 'empresa', '📋'),
    ('caja', 'Caja', 'Maneja el dinero del punto: confirma pagos, registra gastos y recibe mercancía.', 'empresa', '💵'),
    ('mesero', 'Mesero', 'Toma pedidos de mesa, lleva los que están listos y registra el cierre de inventario.', 'empresa', '🍽️'),
    ('cocinero', 'Cocinero', 'Prepara los pedidos y marca cuándo están listos.', 'empresa', '👨‍🍳'),
    ('domiciliario', 'Domiciliario', 'Ve los pedidos listos para entregar y los cierra.', 'empresa', '🛵');

INSERT INTO core.permisos (codigo, descripcion, modulo_id) VALUES
    ('pedidos_ver', 'Ver el tablero de pedidos', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('pedidos_gestionar', 'Cambiar el estado de cualquier pedido', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('pedidos_cocina', 'Trabajar los pedidos en cocina', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('pedidos_domicilio', 'Entregar domicilios', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('pedidos_mesa', 'Tomar pedidos de mesa', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('pedidos_listos', 'Ver y entregar los pedidos listos', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('pedidos_cancelar', 'Cancelar pedidos', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('pedidos_anular', 'Anular facturas ya vendidas, con retorno de inventario', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('cierres_registrar', 'Registrar el inventario del cierre', (SELECT id FROM core.modulos WHERE codigo = 'cierre')),
    ('cierres', 'Consultar los cierres y el cruce', (SELECT id FROM core.modulos WHERE codigo = 'cierre')),
    ('cierres_revisar', 'Dar un cierre por revisado', (SELECT id FROM core.modulos WHERE codigo = 'cierre')),
    ('entradas', 'Registrar y consultar entradas de mercancía', (SELECT id FROM core.modulos WHERE codigo = 'stock')),
    ('gastos', 'Registrar y consultar gastos', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('gastos_confirmar', 'Confirmar gastos', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('gastos_anular', 'Anular gastos', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('informe', 'Ver el cruce de información y la caja del día', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('base_caja', 'Registrar la base de caja de la jornada', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('pagos', 'Confirmar y rechazar pagos', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('menu', 'Publicar el menú del día', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('carta', 'Administrar la carta y las categorías', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('stock', 'Administrar el stock', (SELECT id FROM core.modulos WHERE codigo = 'stock')),
    ('ventas', 'Ver los reportes de ventas', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('ajustes', 'Respaldos y enlaces de mesa', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('usuarios', 'Crear y editar usuarios', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('config_local', 'Cambiar los datos del restaurante', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('config_sucursales', 'Configurar las unidades / locales', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('config_pagos', 'Configurar los métodos de pago', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('plataforma', 'Administrar la plataforma y sus empresas', NULL);

-- superadmin: todo · admin: todo menos 'plataforma' (el comodín del MVP no la concede)
INSERT INTO core.rol_permisos (rol_id, permiso_id)
SELECT r.id, p.id FROM core.roles r CROSS JOIN core.permisos p
 WHERE r.codigo = 'superadmin' OR (r.codigo = 'admin' AND p.codigo <> 'plataforma');

INSERT INTO core.rol_permisos (rol_id, permiso_id)
SELECT r.id, p.id
  FROM (VALUES
        ('administrador', 'pedidos_ver'),
        ('administrador', 'pedidos_gestionar'),
        ('administrador', 'pedidos_cancelar'),
        ('administrador', 'pagos'),
        ('administrador', 'menu'),
        ('administrador', 'carta'),
        ('administrador', 'stock'),
        ('administrador', 'ventas'),
        ('administrador', 'ajustes'),
        ('administrador', 'cierres_registrar'),
        ('administrador', 'cierres'),
        ('administrador', 'cierres_revisar'),
        ('administrador', 'entradas'),
        ('administrador', 'gastos'),
        ('administrador', 'gastos_confirmar'),
        ('administrador', 'gastos_anular'),
        ('administrador', 'informe'),
        ('administrador', 'base_caja'),
        ('caja', 'pagos'),
        ('caja', 'gastos'),
        ('caja', 'gastos_confirmar'),
        ('caja', 'entradas'),
        ('caja', 'informe'),
        ('caja', 'base_caja'),
        ('mesero', 'pedidos_mesa'),
        ('mesero', 'pedidos_listos'),
        ('mesero', 'cierres_registrar'),
        ('cocinero', 'pedidos_cocina'),
        ('domiciliario', 'pedidos_domicilio')
  ) AS x (rol, permiso)
  JOIN core.roles r    ON r.codigo = x.rol
  JOIN core.permisos p ON p.codigo = x.permiso;

INSERT INTO core.metodos_pago (codigo, nombre, grupo_caja) VALUES
    ('efectivo', 'Efectivo contra entrega', 'efectivo'),
    ('datafono', 'Datáfono en la puerta', 'otros'),
    ('transferencia', 'Transferencia · Nequi, Daviplata o Bancolombia', 'transferencia');

INSERT INTO core.tipos_pedido (codigo, nombre) VALUES
    ('mesa', 'Mesa'),
    ('domicilio', 'Domicilio');

INSERT INTO core.estados_pedido (codigo, nombre, orden, solo_domicilio, es_final, cuenta_como_venta) VALUES
    ('nuevo', 'Nuevo', 10, FALSE, FALSE, TRUE),
    ('preparacion', 'En preparación', 20, FALSE, FALSE, TRUE),
    ('listo', 'Listo', 30, FALSE, FALSE, TRUE),
    ('camino', 'En camino', 40, TRUE, FALSE, TRUE),
    ('entregado', 'Entregado', 50, FALSE, TRUE, TRUE),
    ('cancelado', 'Cancelado', 90, FALSE, TRUE, FALSE),
    ('anulado', 'Anulada', 91, FALSE, TRUE, FALSE);

INSERT INTO core.estados_pago (codigo, nombre) VALUES
    ('pendiente', 'Pendiente'),
    ('reportado', 'Reportado, por confirmar'),
    ('confirmado', 'Confirmado'),
    ('rechazado', 'Rechazado');

INSERT INTO core.estados_gasto (codigo, nombre) VALUES
    ('registrado', 'Registrado'),
    ('confirmado', 'Confirmado'),
    ('anulado', 'Anulado');

INSERT INTO core.estados_cierre (codigo, nombre, orden) VALUES
    ('borrador', 'Borrador', 1),
    ('completado', 'Completado', 2),
    ('revisado', 'Revisado', 3);

INSERT INTO core.tipos_entrada (codigo, nombre, automatico) VALUES
    ('compra', 'Compra a proveedor', FALSE),
    ('traslado', 'Traslado entre unidades', FALSE),
    ('devolucion', 'Devolución de cliente', FALSE),
    ('ajuste', 'Ajuste de inventario', FALSE),
    ('retorno_anulacion', 'Retorno por anulación de factura', TRUE);

INSERT INTO core.areas_inventario (codigo, nombre, icono) VALUES
    ('comidas', 'Comidas', '🍽️'),
    ('bar', 'Bar', '🍺');

INSERT INTO core.unidades_medida (codigo, nombre) VALUES
    ('unidad', 'Unidad'),
    ('botella', 'Botella'),
    ('media', 'Media'),
    ('caja', 'Caja'),
    ('paquete', 'Paquete'),
    ('porcion', 'Porción'),
    ('vaso', 'Vaso');

INSERT INTO core.etiquetas_producto (codigo, nombre) VALUES
    ('popular', '★ El más pedido'),
    ('nuevo', 'Nuevo'),
    ('picante', '🌶 Picante'),
    ('compartir', 'Para compartir');

INSERT INTO core.tipos_menu (codigo, nombre, descripcion) VALUES
    ('armado', 'Menú armado', 'El cliente arma su menú eligiendo opciones de cada categoría: sopa, principio, proteína, jugo… Un solo precio.'),
    ('chef', 'Menú del chef', 'Platos completos, cada uno con su nombre, descripción, precio y emoji.');



/* ▼▼▼ DATOS DE EJEMPLO ▼▼▼  Desde aquí hasta el final de este bloque está
   la estructura de NASCAR (empresa, locales, usuarios, carta, inventario y
   menús). Para arrancar con la plataforma vacía, borra desde esta línea
   hasta donde dice «FIN DE LOS DATOS DE EJEMPLO». Los catálogos de arriba
   (estados, roles, permisos, métodos de pago…) SÍ hacen falta siempre. */

/* ---------------------------------------------------------------- EMPRESA NASCAR */
INSERT INTO core.empresas (codigo, nombre_comercial, razon_social, eslogan, descripcion, estado,
                           zona_horaria, hora_corte_operativa, telefono, whatsapp, email, direccion,
                           horario_general, tiempo_mesa, tiempo_domicilio,
                           color_primario, color_secundario, color_acento, color_fondo)
VALUES ('empresa_nascar', 'NASCAR', 'NASCAR Restaurante S.A.S.', 'Cocina de alta velocidad',
        'Cuatro locales en la misma zona: dos restaurantes con menú del día, el bar y la arepera.',
        'activa', 'America/Bogota', 6, '320 212 0632', '573202120632', 'contacto@nascar.com.co',
        'Av. Calle 80 # 102-52, Local 14, Bogotá D.C.', 'Lunes a Domingo · 11:00 a.m. – 10:00 p.m.',
        '15 - 25 min', '35 - 50 min', '#0b5fff', '#e4002b', '#4d8cff', '#06080c');

INSERT INTO core.empresa_modulos (empresa_id, modulo_id, activo)
SELECT e.id, m.id, TRUE FROM core.empresas e CROSS JOIN core.modulos m WHERE e.codigo = 'empresa_nascar';

INSERT INTO core.empresa_metodos_pago (empresa_id, metodo_pago_id, activo, descripcion, orden)
SELECT e.id, mp.id, TRUE, x.descripcion, x.orden
  FROM core.empresas e
 CROSS JOIN (VALUES ('efectivo', 'Le pagas al domiciliario cuando recibas.', 1),
                    ('datafono', 'El domiciliario lleva datáfono. Tarjeta débito o crédito.', 2),
                    ('transferencia', 'Transfieres ahora y despachamos apenas confirmemos el pago.', 3)
           ) AS x (metodo, descripcion, orden)
  JOIN core.metodos_pago mp ON mp.codigo = x.metodo
 WHERE e.codigo = 'empresa_nascar';

INSERT INTO core.consecutivos (empresa_id, tipo, ultimo_numero, digitos)
SELECT id, 'pedido', 0, 5 FROM core.empresas WHERE codigo = 'empresa_nascar';

INSERT INTO core.categorias_gasto (empresa_id, nombre, icono)
SELECT e.id, x.nombre, x.icono
  FROM core.empresas e
 CROSS JOIN (VALUES ('Compra a proveedor', '🚚'), ('Nómina', '👥'), ('Vale', '🧾'),
                    ('Servicios', '💡'), ('Operación', '🔧'), ('Otros', '📌')) AS x (nombre, icono)
 WHERE e.codigo = 'empresa_nascar';


/* ---------------------------------------------------------------- UNIDADES / LOCALES
   Sin zonas de domicilio: los domicilios salen sin costo ni pedido mínimo. */
INSERT INTO core.unidades (empresa_id, tipo_negocio_id, nombre, nombre_corto, estado, direccion, ciudad,
                           telefono, whatsapp, horario, mapa_url, color)
SELECT e.id, t.id, x.nombre, x.corto, 'activa', 'Av. Calle 80 # 102-52, Local 14', 'Bogotá D.C.', '320 212 0632', '573202120632',
       x.horario, 'https://maps.app.goo.gl/p4XjmGHuxHqEPfzo8', x.color
  FROM core.empresas e
 CROSS JOIN (VALUES
        ('NASCAR-Comidas', 'Comidas', 'restaurante', 'Lunes a Domingo · 11:00 a.m. – 10:00 p.m.', 'rojo', 12),
        ('Chicharrón Mental', 'Chicharrón', 'restaurante', 'Lunes a Domingo · 11:00 a.m. – 10:00 p.m.', 'ambar', 10),
        ('NASCAR Bar VIP', 'Bar VIP', 'bar', 'Jueves a Domingo · 6:00 p.m. – 2:00 a.m.', 'azul', 14),
        ('COMIC''ENDO AREPA', 'COMIC''ENDO', 'arepera', 'Lunes a Domingo · 4:00 p.m. – 11:00 p.m.', 'verde', 8)
  ) AS x (nombre, corto, tipo, horario, color, mesas)
  JOIN core.tipos_negocio t ON t.codigo = x.tipo
 WHERE e.codigo = 'empresa_nascar';

INSERT INTO core.mesas (unidad_id, numero)
SELECT u.id, g::TEXT
  FROM (VALUES
        ('NASCAR-Comidas', 12),
        ('Chicharrón Mental', 10),
        ('NASCAR Bar VIP', 14),
        ('COMIC''ENDO AREPA', 8)
  ) AS x (nombre, mesas)
  JOIN core.unidades u ON u.nombre = x.nombre
 CROSS JOIN LATERAL generate_series(1, x.mesas) g;


/* ---------------------------------------------------------------- USUARIOS */
INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash)
SELECT NULL, r.id, 'Plataforma', 'super', core.fn_hash_pin('9000')
  FROM core.roles r WHERE r.codigo = 'superadmin';

INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash)
SELECT e.id, r.id, x.nombre, x.usuario, core.fn_hash_pin(x.pin)
  FROM core.empresas e
 CROSS JOIN (VALUES
        ('Dueño', 'admin', 'admin', '2580'),
        ('Administradora', 'gerencia', 'administrador', '1234'),
        ('Mesero Comidas', 'mesero', 'mesero', '1111'),
        ('Cocina Comidas', 'cocina', 'cocinero', '2222'),
        ('Domiciliario', 'domicilios', 'domiciliario', '3333'),
        ('Caja Comidas', 'caja', 'caja', '4444')
  ) AS x (nombre, usuario, rol, pin)
  JOIN core.roles r ON r.codigo = x.rol
 WHERE e.codigo = 'empresa_nascar';

INSERT INTO core.usuario_unidades (usuario_id, unidad_id)
SELECT us.id, un.id
  FROM core.usuarios us
  JOIN core.unidades un ON un.nombre = 'NASCAR-Comidas'
 WHERE us.usuario IN ('mesero', 'cocina', 'caja');


/* ---------------------------------------------------------------- CARTA */
INSERT INTO core.categorias (empresa_id, nombre, icono, orden)
SELECT e.id, x.nombre, x.icono, x.orden
  FROM core.empresas e
 CROSS JOIN (VALUES
        ('Arepas tradicionales', '🫓', 10),
        ('Arepas especiales', '⭐', 20),
        ('Mazorcada y pataconazo', '🌽', 30),
        ('Hamburguesas', '🍔', 40),
        ('Perros', '🌭', 50),
        ('Salchipapas', '🍟', 60),
        ('Platos a la carta', '🍽️', 70),
        ('Porciones y adiciones', '➕', 80),
        ('Bebidas', '🥤', 90),
        ('Cervezas', '🍺', 110),
        ('Licores', '🥃', 120),
        ('Snacks y dulces', '🍿', 130),
        ('Cigarrillos y varios', '🚬', 140),
        ('Sin alcohol', '🥤', 150)
  ) AS x (nombre, icono, orden)
 WHERE e.codigo = 'empresa_nascar';

INSERT INTO core.categoria_unidades (categoria_id, unidad_id)
SELECT c.id, u.id
  FROM (VALUES
        ('Arepas tradicionales', 'COMIC''ENDO AREPA'),
        ('Arepas especiales', 'COMIC''ENDO AREPA'),
        ('Mazorcada y pataconazo', 'COMIC''ENDO AREPA'),
        ('Hamburguesas', 'COMIC''ENDO AREPA'),
        ('Perros', 'COMIC''ENDO AREPA'),
        ('Salchipapas', 'COMIC''ENDO AREPA'),
        ('Platos a la carta', 'COMIC''ENDO AREPA'),
        ('Porciones y adiciones', 'COMIC''ENDO AREPA'),
        ('Bebidas', 'COMIC''ENDO AREPA'),
        ('Cervezas', 'NASCAR Bar VIP'),
        ('Licores', 'NASCAR Bar VIP'),
        ('Snacks y dulces', 'NASCAR Bar VIP'),
        ('Cigarrillos y varios', 'NASCAR Bar VIP'),
        ('Sin alcohol', 'NASCAR Bar VIP')
  ) AS x (categoria, unidad)
  JOIN core.categorias c ON c.nombre = x.categoria
  JOIN core.unidades u   ON u.nombre = x.unidad;

-- COMIC'ENDO: carta 2025-2026. Bar: nombres de la planilla, PRECIO 0 hasta que el admin lo ponga.
INSERT INTO core.productos (empresa_id, categoria_id, etiqueta_id, codigo, nombre, descripcion, precio, orden)
SELECT e.id, c.id, et.id, x.codigo, x.nombre, x.descripcion, x.precio, x.orden
  FROM core.empresas e
 CROSS JOIN (VALUES
        ('CE01', 'Arepas tradicionales', 'Chorizo queso', NULL, 9000, NULL, 10, 'COMIC''ENDO AREPA'),
        ('CE02', 'Arepas tradicionales', 'Jamón queso', NULL, 9000, NULL, 20, 'COMIC''ENDO AREPA'),
        ('CE03', 'Arepas tradicionales', 'Huevos al gusto', NULL, 10000, NULL, 30, 'COMIC''ENDO AREPA'),
        ('CE04', 'Arepas tradicionales', 'Hawallana', NULL, 10000, NULL, 40, 'COMIC''ENDO AREPA'),
        ('CE05', 'Arepas tradicionales', 'Carne o pollo · Mixta', NULL, 14000, 'popular', 50, 'COMIC''ENDO AREPA'),
        ('CE06', 'Arepas tradicionales', 'Vegetariana', NULL, 12000, NULL, 60, 'COMIC''ENDO AREPA'),
        ('CE07', 'Arepas especiales', 'Arepa Norteña', 'Maíz tierno · Chorizo · Champiñones · Queso · Carne desmechada · Huevo de codorniz', 17000, NULL, 70, 'COMIC''ENDO AREPA'),
        ('CE08', 'Arepas especiales', 'Arepa Avengers', 'Chicharrón · Tocineta · Chorizo · Champiñones · Queso · Carne · Pollo · Jamón · Huevo de codorniz', 17000, 'popular', 80, 'COMIC''ENDO AREPA'),
        ('CE09', 'Arepas especiales', 'Arepa Paisa', 'Frijol · Chicharrón · Plátano · Chorizo · Carne desmechada · Aguacate · Huevo de codorniz', 17000, NULL, 90, 'COMIC''ENDO AREPA'),
        ('CE10', 'Arepas especiales', 'Arepa Ranchera', 'Tocineta · Salchicha · Chorizo · Carne desmechada · Champiñones · Queso · Huevo de codorniz', 17000, NULL, 100, 'COMIC''ENDO AREPA'),
        ('CE11', 'Arepas especiales', 'Arepa Criolla', 'Carne desmechada · Maíz tierno · Plátano · Hogado · Chicharrón · Queso · Huevo de codorniz', 17000, NULL, 110, 'COMIC''ENDO AREPA'),
        ('CE12', 'Arepas especiales', 'Arepa Mexicana', 'Frijol · Carne desmechada · Pico de gallo · Nachos · Queso · Aguacate · Huevo de codorniz', 17000, NULL, 120, 'COMIC''ENDO AREPA'),
        ('CE13', 'Mazorcada y pataconazo', 'Mazorcada', 'Maíz tierno · Chorizo · Salchicha · Pollo y carne desmechada · Queso · Papá chip · Huevo de codorniz', 18000, NULL, 130, 'COMIC''ENDO AREPA'),
        ('CE14', 'Mazorcada y pataconazo', 'Pataconazo', 'Maíz tierno · Chorizo · Salchicha · Pollo · Carne desmechada · Queso · Hogado · Huevo de codorniz', 18000, NULL, 140, 'COMIC''ENDO AREPA'),
        ('CE15', 'Hamburguesas', 'Hamburguesa 100% res', 'Lechuga · Cebolla · Tomate · Queso · Papá chip · Salsas · Huevo de codorniz', 13000, NULL, 150, 'COMIC''ENDO AREPA'),
        ('CE16', 'Hamburguesas', 'Hamburguesa de pollo apanada', 'Lechuga · Cebolla · Tomate · Queso · Papá chip · Salsas · Huevo de codorniz', 14000, NULL, 160, 'COMIC''ENDO AREPA'),
        ('CE17', 'Hamburguesas', 'Hamburguesa doble carne', 'Lechuga · Cebolla · Tomate · Queso · Papá chip · Salsas · Huevo de codorniz', 18000, 'popular', 170, 'COMIC''ENDO AREPA'),
        ('CE18', 'Hamburguesas', 'Hamburguesa mixta', 'Lechuga · Cebolla · Tomate · Queso · Papá chip · Salsas · Huevo de codorniz', 20000, NULL, 180, 'COMIC''ENDO AREPA'),
        ('CE19', 'Hamburguesas', 'Hamburguesa especial Mexicana', 'Frijol · Carne desmechada · Pico de gallo · Nachos · Queso · Aguacate · Huevo de codorniz. Pídela de res o de pollo apanado.', 25000, NULL, 190, 'COMIC''ENDO AREPA'),
        ('CE20', 'Hamburguesas', 'Hamburguesa especial Norteña', 'Maíz tierno · Chorizo · Champiñones · Queso · Carne desmechada · Huevo de codorniz. Pídela de res o de pollo apanado.', 25000, NULL, 200, 'COMIC''ENDO AREPA'),
        ('CE21', 'Hamburguesas', 'Hamburguesa especial Paisa', 'Frijol · Chicharrón · Plátano · Chorizo · Carne · Aguacate · Huevo frito. Pídela de res o de pollo apanado.', 25000, NULL, 210, 'COMIC''ENDO AREPA'),
        ('CE22', 'Hamburguesas', 'Hamburguesa especial Comic''', 'Chicharrón · Tocineta · Chorizo · Champiñones · Carne y pollo desmechado · Jamón · Queso · Huevo frito. Pídela de res o de pollo apanado.', 25000, NULL, 220, 'COMIC''ENDO AREPA'),
        ('CE23', 'Hamburguesas', 'Hamburguesa especial Ranchera', 'Tocineta · Salchicha · Chorizo · Carne desmechada · Champiñones · Queso · Huevo de codorniz. Pídela de res o de pollo apanado.', 25000, NULL, 230, 'COMIC''ENDO AREPA'),
        ('CE24', 'Hamburguesas', 'Hamburguesa especial Criolla', 'Carne desmechada · Maíz tierno · Plátano · Hogado · Chicharrón · Queso · Huevo frito. Pídela de res o de pollo apanado.', 25000, NULL, 240, 'COMIC''ENDO AREPA'),
        ('CE25', 'Perros', 'Perro sencillo', 'Salchicha americana · Jamón · Queso · Cebolla · Papá chip · Salsas · Huevo de codorniz', 14000, NULL, 250, 'COMIC''ENDO AREPA'),
        ('CE26', 'Perros', 'Perro especial', 'Pollo y carne · Salchicha americana · Jamón · Queso · Cebolla · Papá chip · Salsas · Huevo de codorniz', 18000, NULL, 260, 'COMIC''ENDO AREPA'),
        ('CE27', 'Perros', 'Perro de la casa', 'Salchicha americana · Chicharrón · Tocineta · Chorizo · Champiñones · Carne y pollo desmechado · Jamón · Queso · Huevo frito', 22000, 'popular', 270, 'COMIC''ENDO AREPA'),
        ('CE28', 'Salchipapas', 'Salchipapa Comic''', 'Salchicha · Chicharrón · Tocineta · Chorizo · Champiñones · Carne y pollo desmechado · Huevo de codorniz', 22000, 'popular', 280, 'COMIC''ENDO AREPA'),
        ('CE29', 'Salchipapas', 'Salchipapa Ranchera', 'Tocineta · Salchicha · Chorizo · Carne desmechada · Champiñones · Huevo de codorniz', 22000, NULL, 290, 'COMIC''ENDO AREPA'),
        ('CE30', 'Salchipapas', 'Salchipapa Norteña', 'Salchicha · Maíz tierno · Chorizo · Champiñones · Carne desmechada · Huevo de codorniz', 22000, NULL, 300, 'COMIC''ENDO AREPA'),
        ('CE31', 'Salchipapas', 'Salchipapa Criolla', 'Carne desmechada · Maíz tierno · Plátano · Chicharrón · Queso · Huevo de codorniz', 22000, NULL, 310, 'COMIC''ENDO AREPA'),
        ('CE32', 'Platos a la carta', 'Bandeja de carne asada', 'Arroz · Papá francesa · Aguacate · Gaseosa o limonada natural', 18000, NULL, 320, 'COMIC''ENDO AREPA'),
        ('CE33', 'Platos a la carta', 'Bandeja de lomo de cerdo', 'Arroz · Papá francesa · Aguacate · Gaseosa o limonada natural', 18000, NULL, 330, 'COMIC''ENDO AREPA'),
        ('CE34', 'Platos a la carta', 'Bandeja de pechuga', 'Arroz · Papá francesa · Aguacate · Gaseosa o limonada natural', 18000, NULL, 340, 'COMIC''ENDO AREPA'),
        ('CE35', 'Platos a la carta', 'Encebollado de carne asada', 'Arroz · Papá francesa · Gaseosa o limonada natural', 29000, NULL, 350, 'COMIC''ENDO AREPA'),
        ('CE36', 'Platos a la carta', 'Encebollado de lomo de cerdo', 'Arroz · Papá francesa · Gaseosa o limonada natural', 29000, NULL, 360, 'COMIC''ENDO AREPA'),
        ('CE37', 'Platos a la carta', 'Encebollado de pechuga', 'Arroz · Papá francesa · Gaseosa o limonada natural', 29000, NULL, 370, 'COMIC''ENDO AREPA'),
        ('CE38', 'Platos a la carta', 'Churrasco a lo grande', 'Arroz · Papá francesa · Plátano · Gaseosa o limonada natural', 29000, NULL, 380, 'COMIC''ENDO AREPA'),
        ('CE39', 'Platos a la carta', 'Churrasco ranchero', 'Arroz · Papá francesa · Plátano · Gaseosa o limonada natural', 29000, NULL, 390, 'COMIC''ENDO AREPA'),
        ('CE40', 'Platos a la carta', 'Costillas BBQ', 'Arroz · Papá francesa · Plátano · Gaseosa o limonada natural', 29000, NULL, 400, 'COMIC''ENDO AREPA'),
        ('CE41', 'Platos a la carta', 'Trimixta', 'Arroz · Papá francesa · Plátano · Gaseosa o limonada natural', 29000, NULL, 410, 'COMIC''ENDO AREPA'),
        ('CE42', 'Platos a la carta', 'Picada', 'Carne · Pechuga · Lomo · Chorizo · Francesa · Plátano · Arepa', 42000, 'compartir', 420, 'COMIC''ENDO AREPA'),
        ('CE43', 'Porciones y adiciones', 'Papá francesa', NULL, 8000, NULL, 430, 'COMIC''ENDO AREPA'),
        ('CE44', 'Porciones y adiciones', 'Huevos de codorniz', NULL, 5000, NULL, 440, 'COMIC''ENDO AREPA'),
        ('CE45', 'Porciones y adiciones', 'Adición de su preferencia', NULL, 4000, NULL, 450, 'COMIC''ENDO AREPA'),
        ('CE46', 'Bebidas', 'Limonada natural', NULL, 6000, NULL, 460, 'COMIC''ENDO AREPA'),
        ('CE47', 'Bebidas', 'Limonada de coco', NULL, 8000, NULL, 470, 'COMIC''ENDO AREPA'),
        ('CE48', 'Bebidas', 'Limonada cerezada', NULL, 8000, NULL, 480, 'COMIC''ENDO AREPA'),
        ('CE49', 'Bebidas', 'Jugo en agua', NULL, 7000, NULL, 490, 'COMIC''ENDO AREPA'),
        ('CE50', 'Bebidas', 'Jugo en leche', NULL, 9000, NULL, 500, 'COMIC''ENDO AREPA'),
        ('CE51', 'Bebidas', 'Gaseosa personal', NULL, 4500, NULL, 510, 'COMIC''ENDO AREPA'),
        ('CE52', 'Bebidas', 'Gaseosa 250', NULL, 3000, NULL, 520, 'COMIC''ENDO AREPA'),
        ('CE53', 'Bebidas', 'Gaseosa 1.5', NULL, 8000, NULL, 530, 'COMIC''ENDO AREPA'),
        ('CE54', 'Bebidas', 'Agua botella', NULL, 4000, NULL, 540, 'COMIC''ENDO AREPA'),
        ('CE55', 'Bebidas', 'Gatorade', NULL, 5000, NULL, 550, 'COMIC''ENDO AREPA'),
        ('CE56', 'Bebidas', 'Vive Cien', NULL, 4000, NULL, 560, 'COMIC''ENDO AREPA'),
        ('CE57', 'Bebidas', 'Jugo Hit', NULL, 4000, NULL, 570, 'COMIC''ENDO AREPA'),
        ('CE58', 'Bebidas', 'Bretaña', NULL, 4000, NULL, 580, 'COMIC''ENDO AREPA'),
        ('BR01', 'Cervezas', 'Cerveza', NULL, 0, NULL, 10, 'NASCAR Bar VIP'),
        ('BR02', 'Cervezas', 'Águila Light', NULL, 0, NULL, 20, 'NASCAR Bar VIP'),
        ('BR03', 'Cervezas', 'Club Colombia', NULL, 0, NULL, 30, 'NASCAR Bar VIP'),
        ('BR04', 'Cervezas', 'Corona', NULL, 0, NULL, 40, 'NASCAR Bar VIP'),
        ('BR05', 'Cervezas', 'Coronita', NULL, 0, NULL, 50, 'NASCAR Bar VIP'),
        ('BR06', 'Licores', 'Smirnoff', NULL, 0, NULL, 60, 'NASCAR Bar VIP'),
        ('BR07', 'Licores', 'Media de verde', NULL, 0, NULL, 70, 'NASCAR Bar VIP'),
        ('BR08', 'Licores', 'Caja verde', NULL, 0, NULL, 80, 'NASCAR Bar VIP'),
        ('BR09', 'Licores', 'Media de Antioqueño', NULL, 0, NULL, 90, 'NASCAR Bar VIP'),
        ('BR10', 'Licores', 'Botella de Antioqueño', NULL, 0, NULL, 100, 'NASCAR Bar VIP'),
        ('BR11', 'Licores', 'Botella de whisky', NULL, 0, NULL, 110, 'NASCAR Bar VIP'),
        ('BR12', 'Licores', 'Botella de ron', NULL, 0, NULL, 120, 'NASCAR Bar VIP'),
        ('BR13', 'Licores', 'Media de ron', NULL, 0, NULL, 130, 'NASCAR Bar VIP'),
        ('BR14', 'Licores', 'Old Parr', NULL, 0, NULL, 140, 'NASCAR Bar VIP'),
        ('BR15', 'Licores', 'Botella de tequila', NULL, 0, NULL, 150, 'NASCAR Bar VIP'),
        ('BR16', 'Licores', 'Media de tequila', NULL, 0, NULL, 160, 'NASCAR Bar VIP'),
        ('BR17', 'Licores', 'Media de amarillo', NULL, 0, NULL, 170, 'NASCAR Bar VIP'),
        ('BR18', 'Licores', 'Amarillo y rosado', NULL, 0, NULL, 180, 'NASCAR Bar VIP'),
        ('BR19', 'Cigarrillos y varios', 'Cigarrillos', NULL, 0, NULL, 190, 'NASCAR Bar VIP'),
        ('BR20', 'Cigarrillos y varios', 'Encendedores', NULL, 0, NULL, 200, 'NASCAR Bar VIP'),
        ('BR21', 'Snacks y dulces', 'Traiden grande', NULL, 0, NULL, 210, 'NASCAR Bar VIP'),
        ('BR22', 'Snacks y dulces', 'Traiden mediano', NULL, 0, NULL, 220, 'NASCAR Bar VIP'),
        ('BR23', 'Snacks y dulces', 'Traiden personal', NULL, 0, NULL, 230, 'NASCAR Bar VIP'),
        ('BR24', 'Snacks y dulces', 'Papas grandes', NULL, 0, NULL, 240, 'NASCAR Bar VIP'),
        ('BR25', 'Snacks y dulces', 'Papas pequeñas', NULL, 0, NULL, 250, 'NASCAR Bar VIP'),
        ('BR26', 'Snacks y dulces', 'Chokis', NULL, 0, NULL, 260, 'NASCAR Bar VIP'),
        ('BR27', 'Snacks y dulces', 'Bombombum', NULL, 0, NULL, 270, 'NASCAR Bar VIP'),
        ('BR28', 'Snacks y dulces', 'Dulces', NULL, 0, NULL, 280, 'NASCAR Bar VIP'),
        ('BR29', 'Sin alcohol', 'Gatorade, agua y jugos', NULL, 0, NULL, 290, 'NASCAR Bar VIP')
  ) AS x (codigo, categoria, nombre, descripcion, precio, etiqueta, orden, unidad)
  JOIN core.categorias c ON c.empresa_id = e.id AND c.nombre = x.categoria
  LEFT JOIN core.etiquetas_producto et ON et.codigo = x.etiqueta
 WHERE e.codigo = 'empresa_nascar';

INSERT INTO core.producto_unidades (producto_id, unidad_id)
SELECT p.id, u.id
  FROM (VALUES
        ('CE01', 'COMIC''ENDO AREPA'),
        ('CE02', 'COMIC''ENDO AREPA'),
        ('CE03', 'COMIC''ENDO AREPA'),
        ('CE04', 'COMIC''ENDO AREPA'),
        ('CE05', 'COMIC''ENDO AREPA'),
        ('CE06', 'COMIC''ENDO AREPA'),
        ('CE07', 'COMIC''ENDO AREPA'),
        ('CE08', 'COMIC''ENDO AREPA'),
        ('CE09', 'COMIC''ENDO AREPA'),
        ('CE10', 'COMIC''ENDO AREPA'),
        ('CE11', 'COMIC''ENDO AREPA'),
        ('CE12', 'COMIC''ENDO AREPA'),
        ('CE13', 'COMIC''ENDO AREPA'),
        ('CE14', 'COMIC''ENDO AREPA'),
        ('CE15', 'COMIC''ENDO AREPA'),
        ('CE16', 'COMIC''ENDO AREPA'),
        ('CE17', 'COMIC''ENDO AREPA'),
        ('CE18', 'COMIC''ENDO AREPA'),
        ('CE19', 'COMIC''ENDO AREPA'),
        ('CE20', 'COMIC''ENDO AREPA'),
        ('CE21', 'COMIC''ENDO AREPA'),
        ('CE22', 'COMIC''ENDO AREPA'),
        ('CE23', 'COMIC''ENDO AREPA'),
        ('CE24', 'COMIC''ENDO AREPA'),
        ('CE25', 'COMIC''ENDO AREPA'),
        ('CE26', 'COMIC''ENDO AREPA'),
        ('CE27', 'COMIC''ENDO AREPA'),
        ('CE28', 'COMIC''ENDO AREPA'),
        ('CE29', 'COMIC''ENDO AREPA'),
        ('CE30', 'COMIC''ENDO AREPA'),
        ('CE31', 'COMIC''ENDO AREPA'),
        ('CE32', 'COMIC''ENDO AREPA'),
        ('CE33', 'COMIC''ENDO AREPA'),
        ('CE34', 'COMIC''ENDO AREPA'),
        ('CE35', 'COMIC''ENDO AREPA'),
        ('CE36', 'COMIC''ENDO AREPA'),
        ('CE37', 'COMIC''ENDO AREPA'),
        ('CE38', 'COMIC''ENDO AREPA'),
        ('CE39', 'COMIC''ENDO AREPA'),
        ('CE40', 'COMIC''ENDO AREPA'),
        ('CE41', 'COMIC''ENDO AREPA'),
        ('CE42', 'COMIC''ENDO AREPA'),
        ('CE43', 'COMIC''ENDO AREPA'),
        ('CE44', 'COMIC''ENDO AREPA'),
        ('CE45', 'COMIC''ENDO AREPA'),
        ('CE46', 'COMIC''ENDO AREPA'),
        ('CE47', 'COMIC''ENDO AREPA'),
        ('CE48', 'COMIC''ENDO AREPA'),
        ('CE49', 'COMIC''ENDO AREPA'),
        ('CE50', 'COMIC''ENDO AREPA'),
        ('CE51', 'COMIC''ENDO AREPA'),
        ('CE52', 'COMIC''ENDO AREPA'),
        ('CE53', 'COMIC''ENDO AREPA'),
        ('CE54', 'COMIC''ENDO AREPA'),
        ('CE55', 'COMIC''ENDO AREPA'),
        ('CE56', 'COMIC''ENDO AREPA'),
        ('CE57', 'COMIC''ENDO AREPA'),
        ('CE58', 'COMIC''ENDO AREPA'),
        ('BR01', 'NASCAR Bar VIP'),
        ('BR02', 'NASCAR Bar VIP'),
        ('BR03', 'NASCAR Bar VIP'),
        ('BR04', 'NASCAR Bar VIP'),
        ('BR05', 'NASCAR Bar VIP'),
        ('BR06', 'NASCAR Bar VIP'),
        ('BR07', 'NASCAR Bar VIP'),
        ('BR08', 'NASCAR Bar VIP'),
        ('BR09', 'NASCAR Bar VIP'),
        ('BR10', 'NASCAR Bar VIP'),
        ('BR11', 'NASCAR Bar VIP'),
        ('BR12', 'NASCAR Bar VIP'),
        ('BR13', 'NASCAR Bar VIP'),
        ('BR14', 'NASCAR Bar VIP'),
        ('BR15', 'NASCAR Bar VIP'),
        ('BR16', 'NASCAR Bar VIP'),
        ('BR17', 'NASCAR Bar VIP'),
        ('BR18', 'NASCAR Bar VIP'),
        ('BR19', 'NASCAR Bar VIP'),
        ('BR20', 'NASCAR Bar VIP'),
        ('BR21', 'NASCAR Bar VIP'),
        ('BR22', 'NASCAR Bar VIP'),
        ('BR23', 'NASCAR Bar VIP'),
        ('BR24', 'NASCAR Bar VIP'),
        ('BR25', 'NASCAR Bar VIP'),
        ('BR26', 'NASCAR Bar VIP'),
        ('BR27', 'NASCAR Bar VIP'),
        ('BR28', 'NASCAR Bar VIP'),
        ('BR29', 'NASCAR Bar VIP')
  ) AS x (codigo, unidad)
  JOIN core.productos p ON p.codigo = x.codigo
  JOIN core.unidades u  ON u.nombre = x.unidad;


/* ---------------------------------------------------------------- INVENTARIO
   Los códigos son los de las planillas de papel (CD). En el bar el 18 y el 21
   no existen en la planilla y aquí tampoco. Los insumos de cocina no se
   venden tal cual (no tienen producto_insumos); las bebidas y todo el bar sí. */
INSERT INTO core.categorias_insumo (empresa_id, nombre)
SELECT e.id, x.nombre
  FROM core.empresas e
 CROSS JOIN (VALUES
        ('Panes y arepas'),
        ('Insumos'),
        ('Carnes y embutidos'),
        ('Bebidas'),
        ('Cervezas'),
        ('Licores'),
        ('Cigarrillos y varios'),
        ('Snacks y dulces'),
        ('Sin alcohol')
  ) AS x (nombre)
 WHERE e.codigo = 'empresa_nascar';

INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre)
SELECT e.id, ci.id, a.id, um.id, x.codigo, x.nombre
  FROM core.empresas e
 CROSS JOIN (VALUES
        ('CE-01', 'Pan hamburguesa', 'Panes y arepas', 'comidas', 'unidad'),
        ('CE-02', 'Pan perro', 'Panes y arepas', 'comidas', 'unidad'),
        ('CE-03', 'Arepas', 'Panes y arepas', 'comidas', 'unidad'),
        ('CE-04', 'Francesa', 'Insumos', 'comidas', 'unidad'),
        ('CE-05', 'Maíz', 'Insumos', 'comidas', 'unidad'),
        ('CE-06', 'Quesos', 'Insumos', 'comidas', 'unidad'),
        ('CE-07', 'Jamón', 'Carnes y embutidos', 'comidas', 'unidad'),
        ('CE-08', 'Tocineta', 'Carnes y embutidos', 'comidas', 'unidad'),
        ('CE-09', 'Salchichas', 'Carnes y embutidos', 'comidas', 'unidad'),
        ('CE-10', 'Chorizos', 'Carnes y embutidos', 'comidas', 'unidad'),
        ('CE-11', 'Carne hamburguesa', 'Carnes y embutidos', 'comidas', 'unidad'),
        ('CE-12', 'Carne pollo', 'Carnes y embutidos', 'comidas', 'unidad'),
        ('CE-13', 'Churrascos', 'Carnes y embutidos', 'comidas', 'unidad'),
        ('CE-14', 'Costillas', 'Carnes y embutidos', 'comidas', 'unidad'),
        ('CE-15', 'Tocino', 'Carnes y embutidos', 'comidas', 'unidad'),
        ('CE-16', 'Gaseosa 1.5', 'Bebidas', 'comidas', 'botella'),
        ('CE-17', 'Gaseosa 400', 'Bebidas', 'comidas', 'botella'),
        ('CE-18', 'Gaseosa 250', 'Bebidas', 'comidas', 'botella'),
        ('BAR-01', 'Cerveza', 'Cervezas', 'bar', 'botella'),
        ('BAR-02', 'Águila Light', 'Cervezas', 'bar', 'botella'),
        ('BAR-03', 'Club Colombia', 'Cervezas', 'bar', 'botella'),
        ('BAR-04', 'Corona', 'Cervezas', 'bar', 'botella'),
        ('BAR-05', 'Coronita', 'Cervezas', 'bar', 'botella'),
        ('BAR-06', 'Smirnoff', 'Licores', 'bar', 'botella'),
        ('BAR-07', 'Media de verde', 'Licores', 'bar', 'media'),
        ('BAR-08', 'Caja verde', 'Licores', 'bar', 'caja'),
        ('BAR-09', 'Media de Antioqueño', 'Licores', 'bar', 'media'),
        ('BAR-10', 'Botella de Antioqueño', 'Licores', 'bar', 'botella'),
        ('BAR-11', 'Botella de whisky', 'Licores', 'bar', 'botella'),
        ('BAR-12', 'Botella de ron', 'Licores', 'bar', 'botella'),
        ('BAR-13', 'Media de ron', 'Licores', 'bar', 'media'),
        ('BAR-14', 'Old Parr', 'Licores', 'bar', 'botella'),
        ('BAR-15', 'Botella de tequila', 'Licores', 'bar', 'botella'),
        ('BAR-16', 'Media de tequila', 'Licores', 'bar', 'media'),
        ('BAR-17', 'Media de amarillo', 'Licores', 'bar', 'media'),
        ('BAR-19', 'Cigarrillos', 'Cigarrillos y varios', 'bar', 'unidad'),
        ('BAR-20', 'Traiden grande', 'Snacks y dulces', 'bar', 'unidad'),
        ('BAR-22', 'Traiden mediano', 'Snacks y dulces', 'bar', 'unidad'),
        ('BAR-23', 'Traiden personal', 'Snacks y dulces', 'bar', 'unidad'),
        ('BAR-24', 'Encendedores', 'Cigarrillos y varios', 'bar', 'unidad'),
        ('BAR-25', 'Papas grandes', 'Snacks y dulces', 'bar', 'paquete'),
        ('BAR-26', 'Papas pequeñas', 'Snacks y dulces', 'bar', 'paquete'),
        ('BAR-27', 'Chokis', 'Snacks y dulces', 'bar', 'unidad'),
        ('BAR-28', 'Bombombum', 'Snacks y dulces', 'bar', 'unidad'),
        ('BAR-29', 'Dulces', 'Snacks y dulces', 'bar', 'unidad'),
        ('BAR-30', 'Gatorade, agua y jugos', 'Sin alcohol', 'bar', 'unidad'),
        ('BAR-31', 'Amarillo y rosado', 'Licores', 'bar', 'botella')
  ) AS x (codigo, nombre, categoria, area, medida)
  JOIN core.categorias_insumo ci ON ci.empresa_id = e.id AND ci.nombre = x.categoria
  JOIN core.areas_inventario a   ON a.codigo = x.area
  JOIN core.unidades_medida um   ON um.codigo = x.medida
 WHERE e.codigo = 'empresa_nascar';

INSERT INTO core.insumo_unidades (insumo_id, unidad_id)
SELECT i.id, u.id
  FROM (VALUES
        ('CE-01', 'COMIC''ENDO AREPA'),
        ('CE-02', 'COMIC''ENDO AREPA'),
        ('CE-03', 'COMIC''ENDO AREPA'),
        ('CE-04', 'COMIC''ENDO AREPA'),
        ('CE-05', 'COMIC''ENDO AREPA'),
        ('CE-06', 'COMIC''ENDO AREPA'),
        ('CE-07', 'COMIC''ENDO AREPA'),
        ('CE-08', 'COMIC''ENDO AREPA'),
        ('CE-09', 'COMIC''ENDO AREPA'),
        ('CE-10', 'COMIC''ENDO AREPA'),
        ('CE-11', 'COMIC''ENDO AREPA'),
        ('CE-12', 'COMIC''ENDO AREPA'),
        ('CE-13', 'COMIC''ENDO AREPA'),
        ('CE-14', 'COMIC''ENDO AREPA'),
        ('CE-15', 'COMIC''ENDO AREPA'),
        ('CE-16', 'COMIC''ENDO AREPA'),
        ('CE-17', 'COMIC''ENDO AREPA'),
        ('CE-18', 'COMIC''ENDO AREPA'),
        ('BAR-01', 'NASCAR Bar VIP'),
        ('BAR-02', 'NASCAR Bar VIP'),
        ('BAR-03', 'NASCAR Bar VIP'),
        ('BAR-04', 'NASCAR Bar VIP'),
        ('BAR-05', 'NASCAR Bar VIP'),
        ('BAR-06', 'NASCAR Bar VIP'),
        ('BAR-07', 'NASCAR Bar VIP'),
        ('BAR-08', 'NASCAR Bar VIP'),
        ('BAR-09', 'NASCAR Bar VIP'),
        ('BAR-10', 'NASCAR Bar VIP'),
        ('BAR-11', 'NASCAR Bar VIP'),
        ('BAR-12', 'NASCAR Bar VIP'),
        ('BAR-13', 'NASCAR Bar VIP'),
        ('BAR-14', 'NASCAR Bar VIP'),
        ('BAR-15', 'NASCAR Bar VIP'),
        ('BAR-16', 'NASCAR Bar VIP'),
        ('BAR-17', 'NASCAR Bar VIP'),
        ('BAR-19', 'NASCAR Bar VIP'),
        ('BAR-20', 'NASCAR Bar VIP'),
        ('BAR-22', 'NASCAR Bar VIP'),
        ('BAR-23', 'NASCAR Bar VIP'),
        ('BAR-24', 'NASCAR Bar VIP'),
        ('BAR-25', 'NASCAR Bar VIP'),
        ('BAR-26', 'NASCAR Bar VIP'),
        ('BAR-27', 'NASCAR Bar VIP'),
        ('BAR-28', 'NASCAR Bar VIP'),
        ('BAR-29', 'NASCAR Bar VIP'),
        ('BAR-30', 'NASCAR Bar VIP'),
        ('BAR-31', 'NASCAR Bar VIP')
  ) AS x (codigo, unidad)
  JOIN core.insumos i  ON i.codigo = x.codigo
  JOIN core.unidades u ON u.nombre = x.unidad;

INSERT INTO core.producto_insumos (producto_id, insumo_id, cantidad)
SELECT p.id, i.id, 1
  FROM (VALUES
        ('CE-16', 'CE53'),
        ('CE-17', 'CE51'),
        ('CE-18', 'CE52'),
        ('BAR-01', 'BR01'),
        ('BAR-02', 'BR02'),
        ('BAR-03', 'BR03'),
        ('BAR-04', 'BR04'),
        ('BAR-05', 'BR05'),
        ('BAR-06', 'BR06'),
        ('BAR-07', 'BR07'),
        ('BAR-08', 'BR08'),
        ('BAR-09', 'BR09'),
        ('BAR-10', 'BR10'),
        ('BAR-11', 'BR11'),
        ('BAR-12', 'BR12'),
        ('BAR-13', 'BR13'),
        ('BAR-14', 'BR14'),
        ('BAR-15', 'BR15'),
        ('BAR-16', 'BR16'),
        ('BAR-17', 'BR17'),
        ('BAR-19', 'BR19'),
        ('BAR-20', 'BR21'),
        ('BAR-22', 'BR22'),
        ('BAR-23', 'BR23'),
        ('BAR-24', 'BR20'),
        ('BAR-25', 'BR24'),
        ('BAR-26', 'BR25'),
        ('BAR-27', 'BR26'),
        ('BAR-28', 'BR27'),
        ('BAR-29', 'BR28'),
        ('BAR-30', 'BR29'),
        ('BAR-31', 'BR18')
  ) AS x (insumo, producto)
  JOIN core.insumos i   ON i.codigo = x.insumo
  JOIN core.productos p ON p.codigo = x.producto;


/* ---------------------------------------------------------------- MENÚ DEL DÍA
   Los restaurantes trabajan sólo con menú del día. Cinco platos del chef de
   EJEMPLO para la jornada de hoy: se cambian cada mañana desde la aplicación. */
INSERT INTO core.menus_dia (unidad_id, tipo_menu_id, fecha)
SELECT u.id, t.id, core.fn_fecha_operativa(u.empresa_id, now())
  FROM core.unidades u
  JOIN core.tipos_menu t ON t.codigo = 'chef'
 WHERE u.nombre IN ('NASCAR-Comidas', 'Chicharrón Mental');

INSERT INTO core.platos_dia (menu_dia_id, nombre, descripcion, emoji, precio, cupos, orden)
SELECT m.id, x.nombre, x.descripcion, x.emoji, x.precio, x.cupos, x.orden
  FROM (VALUES
        ('NASCAR-Comidas', 'Almuerzo ejecutivo', 'Sancocho de costilla · Arroz + fríjol · Carne asada · Limonada natural', '🥩', 18000, 40, 1),
        ('NASCAR-Comidas', 'Almuerzo del día', 'Crema de ahuyama · Arroz + papa a la francesa · Pollo apanado · Jugo de mora en agua', '🍗', 16000, 40, 2),
        ('NASCAR-Comidas', 'Almuerzo especial', 'Sopa de pasta · Arroz + ensalada · Churrasco 200 g · Limonada de panela', '🔥', 24000, 20, 3),
        ('Chicharrón Mental', 'Corrientazo', 'Consomé de pollo · Arroz + plátano · Chicharrón · Refresco de panela', '🍲', 15000, 50, 1),
        ('Chicharrón Mental', 'Bandeja del día', 'Crema de verduras · Arroz + fríjol + plátano · Chicharrón y carne molida · Limonada natural', '🫘', 22000, 25, 2)
  ) AS x (unidad, nombre, descripcion, emoji, precio, cupos, orden)
  JOIN core.unidades u  ON u.nombre = x.unidad
  JOIN core.menus_dia m ON m.unidad_id = u.id AND m.fecha = core.fn_fecha_operativa(u.empresa_id, now());

COMMIT;

/* Resumen de lo cargado */
SELECT u.nombre AS unidad, t.nombre AS tipo,
       (SELECT count(*) FROM core.producto_unidades pu WHERE pu.unidad_id = u.id) AS carta,
       (SELECT count(*) FROM core.insumo_unidades iu WHERE iu.unidad_id = u.id)   AS inventario,
       (SELECT count(*) FROM core.platos_dia pd JOIN core.menus_dia m ON m.id = pd.menu_dia_id
         WHERE m.unidad_id = u.id) AS platos_dia
  FROM core.unidades u JOIN core.tipos_negocio t ON t.id = u.tipo_negocio_id
 ORDER BY u.id;

/* ▲▲▲ FIN DE LOS DATOS DE EJEMPLO ▲▲▲ */


/* ============================================================================
   07_SEGURIDAD
   Roles taseca_app y taseca_lectura
   ============================================================================ */

/* ============================================================================
   TASECA · 07 · SEGURIDAD (roles y permisos de base de datos)
   ----------------------------------------------------------------------------
   Principio: la aplicación NUNCA toca las tablas.

     taseca_app      rol de la aplicación: lee las vistas de api y ejecuta
                     sus procedimientos y funciones. Sin acceso a core.
     taseca_lectura  reportes / analistas: sólo SELECT sobre las vistas.

   Ambos son NOLOGIN (grupos). El usuario real con contraseña se crea aparte
   y se mete en el grupo (ver el final del archivo). Las contraseñas no se
   dejan escritas en los scripts.

   Los procedimientos y las funciones de core que usan las vistas son
   SECURITY DEFINER: corren con los privilegios de su dueño, por eso el rol
   de la aplicación no necesita permisos sobre las tablas.
   ============================================================================ */

SET search_path = core, public;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'taseca_app') THEN
        CREATE ROLE taseca_app NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'taseca_lectura') THEN
        CREATE ROLE taseca_lectura NOLOGIN;
    END IF;
END;
$$;

COMMENT ON ROLE taseca_app     IS 'Aplicación Taseca: vistas y procedimientos del esquema api. Sin acceso a core.';
COMMENT ON ROLE taseca_lectura IS 'Reportes: sólo lectura de las vistas del esquema api.';


/* ---------------------------------------------------------------------------
   1. Nadie accede a core por defecto
   --------------------------------------------------------------------------- */
REVOKE ALL ON SCHEMA core FROM PUBLIC;
REVOKE ALL ON ALL TABLES    IN SCHEMA core FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA core FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA core FROM PUBLIC;
REVOKE ALL ON SCHEMA api FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS  IN SCHEMA api FROM PUBLIC;
REVOKE ALL ON ALL PROCEDURES IN SCHEMA api FROM PUBLIC;


/* ---------------------------------------------------------------------------
   2. Las funciones de core que usan las vistas corren como su dueño
   Una vista consulta las tablas con los permisos de su dueño, pero una
   función llamada dentro de la vista corre con los del que consulta. Sin
   esto, taseca_app no podría leer ni una vista que calcule la jornada.
   Las funciones de trigger se excluyen: corren dentro de procedimientos que
   ya son SECURITY DEFINER.
   --------------------------------------------------------------------------- */
DO $$
DECLARE
    f RECORD;
BEGIN
    FOR f IN
        SELECT p.oid::regprocedure AS firma
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'core'
           AND p.prokind = 'f'
           AND p.prorettype <> 'trigger'::regtype
    LOOP
        EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER SET search_path = core, public', f.firma);
    END LOOP;
END;
$$;


/* ---------------------------------------------------------------------------
   3. Rol de la aplicación
   --------------------------------------------------------------------------- */
GRANT USAGE   ON SCHEMA api TO taseca_app, taseca_lectura;
GRANT SELECT  ON ALL TABLES IN SCHEMA api TO taseca_app, taseca_lectura;   -- vistas y vistas materializadas
GRANT EXECUTE ON ALL FUNCTIONS  IN SCHEMA api TO taseca_app;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA api TO taseca_app;

/* Las vistas llaman funciones de cálculo de core, y PostgreSQL revisa el
   permiso de EJECUTAR contra quien consulta. Se conceden sólo esas, de
   solo lectura. USAGE sobre core permite nombrarlas; no da acceso a
   ninguna tabla (siguen revocadas). */
GRANT USAGE ON SCHEMA core TO taseca_app, taseca_lectura;
GRANT EXECUTE ON FUNCTION
    core.fn_fecha_operativa(INTEGER, TIMESTAMPTZ),
    core.fn_empresa_tiene_modulo(INTEGER, TEXT),
    core.fn_vendidos_plato(BIGINT),
    core.fn_normalizar_codigo_pedido(INTEGER, TEXT),
    core.fn_empresa_de_unidad(INTEGER)
TO taseca_app, taseca_lectura;

-- Lo que se cree después en api hereda los mismos permisos
ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT SELECT  ON TABLES     TO taseca_app, taseca_lectura;
ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT EXECUTE ON FUNCTIONS  TO taseca_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT EXECUTE ON ROUTINES   TO taseca_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA api REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA core REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Refrescar reportes es tarea programada, no de la aplicación ni de los analistas
REVOKE EXECUTE ON PROCEDURE api.sp_refrescar_reportes() FROM taseca_app;


/* ---------------------------------------------------------------------------
   4. Usuario con contraseña para conectar la aplicación
   Descomenta, pon una contraseña fuerte y ejecútalo a mano. No lo guardes
   con la contraseña escrita en el repositorio.
   --------------------------------------------------------------------------- */
-- CREATE ROLE app_taseca LOGIN PASSWORD 'CAMBIA_ESTA_CONTRASEÑA' IN ROLE taseca_app;
-- CREATE ROLE reportes_taseca LOGIN PASSWORD 'CAMBIA_ESTA_CONTRASEÑA' IN ROLE taseca_lectura;


/* ============================================================================
   09_POSTGREST
   Capa REST, roles de la API y tokens
   ============================================================================ */

/* ============================================================================
   TASECA · 09 · API REST CON POSTGREST (fase 1)
   ----------------------------------------------------------------------------
   Ejecutar conectado a taseca_db, después de 01 … 07. Se puede volver a
   ejecutar: todo es idempotente.

   PostgREST publica SÓLO el esquema `rest`. Es una capa delgada sobre `api`:

     · vistas públicas  → carta, unidades, menú del día (cliente sin sesión)
     · vistas privadas  → pedidos de la empresa y unidades del usuario del JWT
     · funciones RPC    → envuelven los procedimientos de `api`

   PostgREST no ejecuta PROCEDURES (CALL), sólo funciones: por eso cada
   escritura tiene aquí su función. Y lo más importante: el usuario NUNCA
   llega como parámetro. Sale del token JWT firmado por la base, así que el
   navegador no puede hacerse pasar por otro.

   ROLES
     taseca_rest   usuario con el que se conecta PostgREST (LOGIN, NOINHERIT).
                   La contraseña la pones tú: ALTER ROLE taseca_rest PASSWORD '…';
     taseca_anon   quien no ha iniciado sesión (el cliente del portal)
     taseca_app    quien entró con usuario y PIN (el JWT dice role = taseca_app)

   FASE 1: login, portal, mesa, carta, menú del día, crear pedido, seguimiento,
   cocina, estados, cancelar, anular y pagos. Inventario, cierres, caja,
   gastos, usuarios y configuración siguen en la fase 2.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. AJUSTES AL MODELO QUE NECESITA LA API
   ============================================================================ */

-- El comprobante guarda la imagen (data URL) y la referencia que escribe el
-- cliente: la caja lo revisa desde otro equipo.
ALTER TABLE core.comprobantes_pago ALTER COLUMN archivo_url TYPE TEXT;
ALTER TABLE core.comprobantes_pago ALTER COLUMN archivo_url DROP NOT NULL;
ALTER TABLE core.comprobantes_pago ADD COLUMN IF NOT EXISTS referencia VARCHAR(120);
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_comprobantes_contenido') THEN
        ALTER TABLE core.comprobantes_pago
            ADD CONSTRAINT ck_comprobantes_contenido CHECK (archivo_url IS NOT NULL OR referencia IS NOT NULL);
    END IF;
END;
$$;

DROP PROCEDURE IF EXISTS api.sp_registrar_comprobante(BIGINT, VARCHAR, BIGINT);
CREATE OR REPLACE PROCEDURE api.sp_registrar_comprobante(
    p_pedido_id      BIGINT,
    p_archivo_url    TEXT    DEFAULT NULL,
    p_referencia     VARCHAR DEFAULT NULL,
    INOUT p_comprobante_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_pago VARCHAR;
BEGIN
    PERFORM core.fn_fijar_usuario(NULL);

    SELECT ep.codigo INTO v_pago
      FROM core.pedidos p JOIN core.estados_pago ep ON ep.id = p.estado_pago_id
     WHERE p.id = p_pedido_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Esa factura no existe.';
    ELSIF v_pago = 'confirmado' THEN
        RAISE EXCEPTION 'El pago de esta factura ya fue confirmado.';
    END IF;
    IF p_archivo_url IS NULL AND NULLIF(trim(p_referencia), '') IS NULL THEN
        RAISE EXCEPTION 'Adjunta el comprobante o escribe la referencia de la transferencia.';
    END IF;
    IF length(p_archivo_url) > 900000 THEN
        RAISE EXCEPTION 'La imagen del comprobante es demasiado grande.';
    END IF;

    INSERT INTO core.comprobantes_pago (pedido_id, archivo_url, referencia, estado_pago_id)
    VALUES (p_pedido_id, p_archivo_url, left(NULLIF(trim(p_referencia), ''), 120),
            core.fn_id_catalogo('estados_pago', 'reportado'))
    RETURNING id INTO p_comprobante_id;

    UPDATE core.pedidos SET estado_pago_id = core.fn_id_catalogo('estados_pago', 'reportado')
     WHERE id = p_pedido_id;
END;
$$;

-- Confirmar / rechazar el pago con la referencia o el motivo en el historial
DROP PROCEDURE IF EXISTS api.sp_actualizar_pago(BIGINT, VARCHAR, INTEGER);
CREATE OR REPLACE PROCEDURE api.sp_actualizar_pago(
    p_pedido_id    BIGINT,
    p_estado_pago  VARCHAR,
    p_usuario_id   INTEGER,
    p_nota         VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'pagos',
            (SELECT unidad_id FROM core.pedidos WHERE id = p_pedido_id));
    UPDATE core.pedidos SET estado_pago_id = core.fn_id_catalogo('estados_pago', p_estado_pago)
     WHERE id = p_pedido_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido % no existe.', p_pedido_id;
    END IF;
    UPDATE core.comprobantes_pago
       SET estado_pago_id = core.fn_id_catalogo('estados_pago', p_estado_pago),
           revisado_por_id = p_usuario_id, revisado_en = now()
     WHERE pedido_id = p_pedido_id AND revisado_en IS NULL;
    IF NULLIF(trim(p_nota), '') IS NOT NULL THEN
        INSERT INTO core.pedido_historial (pedido_id, descripcion, usuario_id)
        VALUES (p_pedido_id,
                CASE WHEN p_estado_pago = 'confirmado' THEN 'Referencia del pago: ' ELSE 'Motivo: ' END || trim(p_nota),
                p_usuario_id);
    END IF;
END;
$$;


/* ============================================================================
   2. ROLES DE POSTGREST
   ============================================================================ */

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'taseca_anon') THEN
        CREATE ROLE taseca_anon NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'taseca_rest') THEN
        CREATE ROLE taseca_rest LOGIN NOINHERIT;
    END IF;
END;
$$;

COMMENT ON ROLE taseca_anon IS 'PostgREST sin sesión: el cliente del portal. Sólo lo público de rest.';
COMMENT ON ROLE taseca_rest IS 'Usuario de conexión de PostgREST. Cambia al rol del JWT en cada petición.';

GRANT taseca_anon TO taseca_rest;
GRANT taseca_app  TO taseca_rest;


/* ============================================================================
   3. JWT
   El secreto vive en la base, no en un archivo: PostgREST lo lee al arrancar
   con core.fn_postgrest_pre_config() y la base lo usa para firmar el login.
   ============================================================================ */

CREATE TABLE IF NOT EXISTS core.jwt_config (
    id              SERIAL PRIMARY KEY,
    secreto         TEXT        NOT NULL CHECK (length(secreto) >= 32),
    duracion_horas  SMALLINT    NOT NULL DEFAULT 12 CHECK (duracion_horas BETWEEN 1 AND 72),
    creado_en       TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE core.jwt_config IS 'Secreto con el que se firman los tokens. Para invalidar todas las sesiones: inserta un secreto nuevo y reinicia PostgREST.';

INSERT INTO core.jwt_config (secreto)
SELECT encode(public.gen_random_bytes(32), 'hex')
 WHERE NOT EXISTS (SELECT 1 FROM core.jwt_config);

REVOKE ALL ON core.jwt_config FROM PUBLIC;

CREATE OR REPLACE FUNCTION core.fn_base64url(p_datos BYTEA)
RETURNS TEXT
LANGUAGE sql IMMUTABLE
AS $$
    SELECT translate(encode(p_datos, 'base64'), E'+/=\n', '-_');
$$;

CREATE OR REPLACE FUNCTION core.fn_jwt_secreto()
RETURNS TEXT
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT secreto FROM core.jwt_config ORDER BY id DESC LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION core.fn_jwt_firmar(p_payload JSONB)
RETURNS TEXT
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_datos TEXT;
BEGIN
    v_datos := core.fn_base64url(convert_to('{"alg":"HS256","typ":"JWT"}', 'UTF8')) || '.' ||
               core.fn_base64url(convert_to(p_payload::TEXT, 'UTF8'));
    RETURN v_datos || '.' ||
           core.fn_base64url(public.hmac(convert_to(v_datos, 'UTF8'), convert_to(core.fn_jwt_secreto(), 'UTF8'), 'sha256'));
END;
$$;

/* Lo que dice el token de la petición en curso (PostgREST ya verificó la
   firma y la expiración antes de llegar aquí). */
CREATE OR REPLACE FUNCTION core.fn_jwt_claims()
RETURNS JSONB
LANGUAGE sql STABLE
AS $$
    SELECT NULLIF(current_setting('request.jwt.claims', TRUE), '')::JSONB;
$$;

/* Usuario del token. Si el usuario fue desactivado después de entrar, su
   token deja de servir aunque no haya vencido. */
CREATE OR REPLACE FUNCTION core.fn_jwt_usuario()
RETURNS INTEGER
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_id INTEGER := (core.fn_jwt_claims() ->> 'usuario_id')::INTEGER;
BEGIN
    IF v_id IS NULL THEN
        RETURN NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.usuarios WHERE id = v_id AND activo) THEN
        RAISE EXCEPTION 'Tu sesión ya no es válida. Vuelve a entrar.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION core.fn_jwt_empresa()
RETURNS INTEGER
LANGUAGE sql STABLE
AS $$
    SELECT (core.fn_jwt_claims() ->> 'empresa_id')::INTEGER;
$$;

CREATE OR REPLACE FUNCTION core.fn_exigir_sesion()
RETURNS INTEGER
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_id INTEGER := core.fn_jwt_usuario();
BEGIN
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'Tienes que iniciar sesión.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN v_id;
END;
$$;

/* PostgREST la ejecuta al arrancar y al recargar la configuración
   (db-pre-config). Deja el secreto sólo en la memoria del servidor. */
CREATE OR REPLACE FUNCTION core.fn_postgrest_pre_config()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM set_config('pgrst.jwt_secret', core.fn_jwt_secreto(), TRUE);
END;
$$;


/* ============================================================================
   4. ARMADO DE UN PEDIDO COMPLETO EN JSON
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.fn_pedido_json(p_pedido_id BIGINT)
RETURNS JSONB
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT to_jsonb(vp)
        || jsonb_build_object(
               'empresa_codigo', e.codigo,
               'mesa_id', p.mesa_id,
               'zona_id', p.zona_domicilio_id,
               'tomado_por_id', p.tomado_por_id,
               'items', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                               'pedido_item_id', i.pedido_item_id, 'origen', i.origen,
                               'producto_id', i.producto_id, 'plato_dia_id', i.plato_dia_id,
                               'menu_dia_id', i.menu_dia_id, 'nombre', i.nombre,
                               'precio_unitario', i.precio_unitario, 'cantidad', i.cantidad,
                               'notas', i.notas, 'detalle', i.detalle,
                               'opciones', COALESCE((SELECT jsonb_agg(x.menu_opcion_id ORDER BY x.menu_opcion_id)
                                                       FROM core.pedido_item_opciones x
                                                      WHERE x.pedido_item_id = i.pedido_item_id), '[]'))
                           ORDER BY i.pedido_item_id)
                      FROM api.v_pedido_items i WHERE i.pedido_id = vp.pedido_id), '[]'),
               'historial', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object('ts', h.creado_en, 'texto', h.descripcion) ORDER BY h.id)
                      FROM core.pedido_historial h WHERE h.pedido_id = vp.pedido_id), '[]'),
               'tiene_comprobante', EXISTS (SELECT 1 FROM core.comprobantes_pago c
                                             WHERE c.pedido_id = vp.pedido_id AND c.archivo_url IS NOT NULL),
               'referencia_pago', (SELECT c.referencia FROM core.comprobantes_pago c
                                    WHERE c.pedido_id = vp.pedido_id ORDER BY c.id DESC LIMIT 1),
               'anulacion', (SELECT jsonb_build_object('motivo', a.motivo, 'jornada_original', a.jornada_original,
                                                       'jornada_retorno', a.jornada_retorno,
                                                       'diferido', a.jornada_retorno <> a.jornada_original,
                                                       'creado_en', a.creado_en)
                               FROM core.anulaciones a WHERE a.pedido_id = vp.pedido_id)
           )
      FROM api.v_pedidos vp
      JOIN core.pedidos p  ON p.id = vp.pedido_id
      JOIN core.empresas e ON e.id = vp.empresa_id
     WHERE vp.pedido_id = p_pedido_id;
$$;

/* Pedido de la empresa y unidades del usuario de la sesión; si no, error. */
CREATE OR REPLACE FUNCTION core.fn_pedido_de_sesion(p_pedido_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.pedidos p
                    WHERE p.id = p_pedido_id
                      AND p.empresa_id = core.fn_jwt_empresa()
                      AND core.fn_usuario_en_unidad(v_usuario, p.unidad_id)) THEN
        RAISE EXCEPTION 'Esa factura no existe.' USING ERRCODE = 'no_data_found';
    END IF;
    RETURN core.fn_pedido_json(p_pedido_id);
END;
$$;


/* ============================================================================
   5. ESQUEMA REST · LECTURA PÚBLICA (con o sin sesión)
   ============================================================================ */

CREATE SCHEMA IF NOT EXISTS rest;
COMMENT ON SCHEMA rest IS 'Lo que publica PostgREST. Capa delgada sobre api; el usuario sale siempre del JWT.';

CREATE OR REPLACE VIEW rest.empresas AS
SELECT empresa_id, codigo, nombre_comercial, eslogan, telefono, whatsapp, email, direccion, horario_general,
       tiempo_mesa, tiempo_domicilio, color_primario, color_secundario, color_acento, color_fondo, logo_url,
       hora_corte_operativa, jornada_actual
  FROM api.v_empresas
 WHERE estado = 'activa';

CREATE OR REPLACE VIEW rest.unidades AS
SELECT u.unidad_id, u.empresa_id, e.codigo AS empresa_codigo, u.nombre, u.nombre_corto, u.estado, u.activa,
       u.tipo_negocio, u.direccion, u.ciudad, u.telefono, u.whatsapp, u.horario, u.mapa_url, u.color,
       u.logo_url, u.mesas, u.creado_en,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('zona_id', z.id, 'nombre', z.nombre, 'costo', z.costo,
                                                     'pedido_minimo', z.pedido_minimo) ORDER BY z.nombre)
                   FROM core.zonas_domicilio z WHERE z.unidad_id = u.unidad_id AND z.activa), '[]') AS zonas
  FROM api.v_unidades u
  JOIN core.empresas e ON e.id = u.empresa_id;

CREATE OR REPLACE VIEW rest.categorias AS
SELECT c.id AS categoria_id, c.empresa_id, c.nombre, c.icono, c.orden, c.activa,
       COALESCE(array_agg(cu.unidad_id ORDER BY cu.unidad_id) FILTER (WHERE cu.unidad_id IS NOT NULL), '{}') AS unidades
  FROM core.categorias c
  LEFT JOIN core.categoria_unidades cu ON cu.categoria_id = c.id
 GROUP BY c.id;

CREATE OR REPLACE VIEW rest.carta AS
SELECT p.id AS producto_id, p.empresa_id, p.codigo, p.categoria_id, p.nombre, p.descripcion, p.precio,
       et.codigo AS etiqueta, p.imagen_url, p.orden, p.activo,
       COALESCE(jsonb_agg(jsonb_build_object('unidad_id', pu.unidad_id, 'agotado', pu.agotado)
                          ORDER BY pu.unidad_id) FILTER (WHERE pu.id IS NOT NULL), '[]') AS unidades
  FROM core.productos p
  LEFT JOIN core.etiquetas_producto et ON et.id = p.etiqueta_id
  LEFT JOIN core.producto_unidades pu  ON pu.producto_id = p.id
 GROUP BY p.id, et.codigo;

/* Menús de una semana atrás a dos adelante, cada uno con sus categorías,
   opciones y platos del chef ya armados. */
CREATE OR REPLACE VIEW rest.menus_dia AS
SELECT m.id AS menu_dia_id, u.empresa_id, m.unidad_id, m.fecha, t.codigo AS tipo,
       m.nombre, m.descripcion, m.precio, m.disponible,
       m.titulo_publico AS titulo_fecha, m.mensaje_publico AS mensaje_fecha,
       COALESCE((SELECT jsonb_agg(jsonb_build_object(
                          'categoria_id', c.id, 'nombre', c.nombre, 'icono', c.icono, 'orden', c.orden,
                          'obligatoria', c.obligatoria, 'max_seleccion', c.max_seleccion, 'activa', c.activa,
                          'opciones', COALESCE((SELECT jsonb_agg(jsonb_build_object('opcion_id', o.id, 'nombre', o.nombre,
                                                                                    'orden', o.orden, 'activa', o.activa)
                                                                 ORDER BY o.orden)
                                                  FROM core.menu_opciones o WHERE o.menu_categoria_id = c.id), '[]'))
                      ORDER BY c.orden)
                   FROM core.menu_categorias c WHERE c.menu_dia_id = m.id), '[]') AS categorias,
       COALESCE((SELECT jsonb_agg(jsonb_build_object(
                          'plato_dia_id', p.plato_dia_id, 'nombre', p.nombre, 'descripcion', p.descripcion,
                          'emoji', p.emoji, 'precio', p.precio, 'cupos', p.cupos, 'vendidos', p.vendidos,
                          'disponible', p.disponible, 'orden', p.orden)
                      ORDER BY p.orden)
                   FROM api.v_platos_dia p WHERE p.menu_dia_id = m.id), '[]') AS platos
  FROM core.menus_dia m
  JOIN core.unidades u   ON u.id = m.unidad_id
  JOIN core.tipos_menu t ON t.id = m.tipo_menu_id
 WHERE m.fecha BETWEEN core.fn_fecha_operativa(u.empresa_id, now()) - 7
                   AND core.fn_fecha_operativa(u.empresa_id, now()) + 14;

CREATE OR REPLACE VIEW rest.textos_menu AS
SELECT t.unidad_id, u.empresa_id, t.titulo, t.mensaje
  FROM core.textos_menu_unidad t
  JOIN core.unidades u ON u.id = t.unidad_id;

CREATE OR REPLACE VIEW rest.metodos_pago AS
SELECT empresa_id, codigo, nombre, grupo_caja, descripcion, activo, orden
  FROM api.v_metodos_pago;


/* ============================================================================
   6. ESQUEMA REST · LECTURA CON SESIÓN
   ============================================================================ */

/* Pedidos de los últimos 31 días de la empresa del token, sólo de las
   unidades en las que trabaja el usuario. `pedido` trae todo armado. */
CREATE OR REPLACE VIEW rest.pedidos AS
SELECT vp.pedido_id, vp.empresa_id, vp.unidad_id, vp.codigo, vp.estado, vp.fecha_operativa,
       vp.actualizado_en, core.fn_pedido_json(vp.pedido_id) AS pedido
  FROM api.v_pedidos vp
 WHERE vp.empresa_id = core.fn_jwt_empresa()
   AND core.fn_usuario_en_unidad(core.fn_jwt_usuario(), vp.unidad_id)
   AND vp.fecha_operativa >= core.fn_fecha_operativa(vp.empresa_id, now()) - 31;


/* ============================================================================
   7. ESQUEMA REST · FUNCIONES (RPC)
   POST /rpc/<nombre> con un JSON de parámetros.
   ============================================================================ */

/* Login: si el PIN es correcto devuelve el token y los datos de la sesión;
   si no, null (después de una pausa corta, para frenar la fuerza bruta). */
CREATE OR REPLACE FUNCTION rest.login(p_usuario TEXT, p_pin TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v      RECORD;
    v_exp  BIGINT;
    v_uni  INTEGER[];
BEGIN
    SELECT * INTO v FROM api.fn_login(p_usuario, p_pin) LIMIT 1;
    IF v.usuario_id IS NULL THEN
        PERFORM pg_sleep(0.6);
        RETURN NULL;
    END IF;

    v_exp := extract(epoch FROM now() + make_interval(hours => (SELECT duracion_horas FROM core.jwt_config ORDER BY id DESC LIMIT 1)))::BIGINT;
    SELECT COALESCE(array_agg(unidad_id ORDER BY unidad_id), '{}') INTO v_uni
      FROM core.usuario_unidades WHERE usuario_id = v.usuario_id;

    RETURN jsonb_build_object(
        'token', core.fn_jwt_firmar(jsonb_build_object(
                     'role', 'taseca_app', 'usuario_id', v.usuario_id, 'empresa_id', v.empresa_id,
                     'rol', v.rol, 'exp', v_exp)),
        'expira', to_timestamp(v_exp),
        'usuario_id', v.usuario_id, 'nombre', v.nombre, 'usuario', v.usuario,
        'rol', v.rol, 'alcance', v.alcance,
        'empresa_id', v.empresa_id,
        'empresa_codigo', (SELECT codigo FROM core.empresas WHERE id = v.empresa_id),
        'unidades', to_jsonb(v_uni));
END;
$$;

/* ¿Sigue siendo válida mi sesión? */
CREATE OR REPLACE FUNCTION rest.sesion()
RETURNS JSONB
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_id INTEGER := core.fn_exigir_sesion();
BEGIN
    RETURN (SELECT jsonb_build_object('usuario_id', u.usuario_id, 'nombre', u.nombre, 'rol', u.rol,
                                      'empresa_id', u.empresa_id, 'unidades', to_jsonb(u.unidades_asignadas))
              FROM api.v_usuarios u WHERE u.usuario_id = v_id);
END;
$$;

/* Crear pedido. Sin sesión = cliente del portal; con sesión = mesero. */
CREATE OR REPLACE FUNCTION rest.crear_pedido(
    p_unidad_id         INTEGER,
    p_tipo              TEXT,
    p_metodo_pago       TEXT,
    p_items             JSONB,
    p_mesa              TEXT    DEFAULT NULL,
    p_cliente_nombre    TEXT    DEFAULT NULL,
    p_cliente_telefono  TEXT    DEFAULT NULL,
    p_direccion         TEXT    DEFAULT NULL,
    p_indicaciones      TEXT    DEFAULT NULL,
    p_zona_id           INTEGER DEFAULT NULL,
    p_paga_con          NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_id     BIGINT;
    v_codigo VARCHAR;
BEGIN
    CALL api.sp_crear_pedido(
        p_unidad_id => p_unidad_id, p_tipo => p_tipo, p_metodo_pago => p_metodo_pago, p_items => p_items,
        p_usuario_id => core.fn_jwt_usuario(), p_mesa => p_mesa,
        p_cliente_nombre => p_cliente_nombre, p_cliente_telefono => p_cliente_telefono,
        p_direccion => p_direccion, p_indicaciones => p_indicaciones, p_zona_id => p_zona_id,
        p_paga_con => p_paga_con, p_pedido_id => v_id, p_codigo => v_codigo);
    RETURN core.fn_pedido_json(v_id);
END;
$$;

/* Seguimiento público: sin teléfono ni dirección del cliente. */
CREATE OR REPLACE FUNCTION rest.seguimiento(p_codigo TEXT, p_empresa TEXT DEFAULT 'empresa_nascar')
RETURNS JSONB
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_id BIGINT;
BEGIN
    SELECT s.pedido_id INTO v_id FROM api.fn_seguimiento_pedido(p_empresa, p_codigo) s;
    IF v_id IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN core.fn_pedido_json(v_id)
           - ARRAY['cliente', 'cliente_telefono', 'direccion_entrega', 'indicaciones', 'paga_con', 'cambio',
                   'tomado_por', 'tomado_por_id', 'referencia_pago'];
END;
$$;

/* El cliente reporta su transferencia (referencia y/o foto). Sólo pedidos
   por transferencia de las últimas 24 horas y sin pago confirmado. */
CREATE OR REPLACE FUNCTION rest.reportar_pago(p_codigo TEXT, p_referencia TEXT DEFAULT NULL,
                                              p_imagen TEXT DEFAULT NULL, p_empresa TEXT DEFAULT 'empresa_nascar')
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_id   BIGINT;
    v_comp BIGINT;
BEGIN
    SELECT p.id INTO v_id
      FROM core.pedidos p
      JOIN core.empresas e     ON e.id = p.empresa_id
      JOIN core.metodos_pago m ON m.id = p.metodo_pago_id
     WHERE e.codigo = p_empresa
       AND p.codigo = core.fn_normalizar_codigo_pedido(e.id, p_codigo)
       AND m.codigo = 'transferencia'
       AND p.creado_en > now() - INTERVAL '24 hours';
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'No se encontró un pedido por transferencia reciente con ese número.';
    END IF;
    CALL api.sp_registrar_comprobante(p_pedido_id => v_id, p_archivo_url => p_imagen, p_referencia => p_referencia,
                                      p_comprobante_id => v_comp);
    RETURN rest.seguimiento(p_codigo, p_empresa);
END;
$$;

CREATE OR REPLACE FUNCTION rest.pedido(p_pedido_id BIGINT)
RETURNS JSONB
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT core.fn_pedido_de_sesion(p_pedido_id);
$$;

CREATE OR REPLACE FUNCTION rest.avanzar_estado(p_pedido_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    CALL api.sp_avanzar_estado_pedido(p_pedido_id, core.fn_exigir_sesion());
    RETURN core.fn_pedido_de_sesion(p_pedido_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.cambiar_estado(p_pedido_id BIGINT, p_estado TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
BEGIN
    /* El panel usa "cambiar estado" también para lo que sólo avanza un paso
       (cocina marca listo, domiciliario entrega). Si el estado pedido es el
       siguiente del flujo, basta con uno de los permisos de piso. */
    IF core.fn_id_catalogo('estados_pedido', p_estado) = core.fn_siguiente_estado(p_pedido_id) THEN
        CALL api.sp_avanzar_estado_pedido(p_pedido_id, v_usuario);
    ELSE
        CALL api.sp_cambiar_estado_pedido(p_pedido_id, p_estado, v_usuario);
    END IF;
    RETURN core.fn_pedido_de_sesion(p_pedido_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.cancelar_pedido(p_pedido_id BIGINT, p_motivo TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    CALL api.sp_cancelar_pedido(p_pedido_id, p_motivo, core.fn_exigir_sesion());
    RETURN core.fn_pedido_de_sesion(p_pedido_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.anular_pedido(p_pedido_id BIGINT, p_motivo TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_json JSONB;
BEGIN
    CALL api.sp_anular_pedido(p_pedido_id, p_motivo, core.fn_exigir_sesion());
    v_json := core.fn_pedido_de_sesion(p_pedido_id);
    RETURN jsonb_build_object(
        'pedido', v_json,
        'retorno', jsonb_build_object(
            'diferido', COALESCE((v_json -> 'anulacion' ->> 'diferido')::BOOLEAN, FALSE),
            'jornada_retorno', v_json -> 'anulacion' ->> 'jornada_retorno',
            'productos', COALESCE((SELECT jsonb_agg(jsonb_build_object('codigo', s.codigo, 'cantidad', e.cantidad))
                                     FROM core.entradas_inventario e
                                     JOIN core.insumo_unidades iu ON iu.id = e.insumo_unidad_id
                                     JOIN core.insumos s ON s.id = iu.insumo_id
                                    WHERE e.pedido_id = p_pedido_id), '[]')));
END;
$$;

CREATE OR REPLACE FUNCTION rest.confirmar_pago(p_pedido_id BIGINT, p_referencia TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    CALL api.sp_actualizar_pago(p_pedido_id, 'confirmado', core.fn_exigir_sesion(), p_referencia);
    RETURN core.fn_pedido_de_sesion(p_pedido_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.rechazar_pago(p_pedido_id BIGINT, p_motivo TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    CALL api.sp_actualizar_pago(p_pedido_id, 'rechazado', core.fn_exigir_sesion(), p_motivo);
    RETURN core.fn_pedido_de_sesion(p_pedido_id);
END;
$$;

/* La imagen del comprobante, sólo para quien puede revisar pagos. */
CREATE OR REPLACE FUNCTION rest.comprobante(p_pedido_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
BEGIN
    PERFORM core.fn_pedido_de_sesion(p_pedido_id);
    PERFORM core.fn_exigir_permiso(v_usuario, 'pagos');
    RETURN (SELECT jsonb_build_object('imagen', c.archivo_url, 'referencia', c.referencia, 'creado_en', c.creado_en,
                                      'peso_kb', round(length(c.archivo_url) / 1024.0))
              FROM core.comprobantes_pago c
             WHERE c.pedido_id = p_pedido_id AND c.archivo_url IS NOT NULL
             ORDER BY c.id DESC LIMIT 1);
END;
$$;


/* ============================================================================
   8. PERMISOS
   ============================================================================ */

REVOKE ALL ON SCHEMA rest FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA rest FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA rest FROM PUBLIC;

GRANT USAGE ON SCHEMA rest TO taseca_anon, taseca_app;

-- Lectura pública
GRANT SELECT ON rest.empresas, rest.unidades, rest.categorias, rest.carta,
                rest.menus_dia, rest.textos_menu, rest.metodos_pago
      TO taseca_anon, taseca_app;
-- Lectura con sesión
GRANT SELECT ON rest.pedidos TO taseca_app;

-- Funciones públicas
GRANT EXECUTE ON FUNCTION rest.login(TEXT, TEXT),
                          rest.crear_pedido(INTEGER, TEXT, TEXT, JSONB, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, NUMERIC),
                          rest.seguimiento(TEXT, TEXT),
                          rest.reportar_pago(TEXT, TEXT, TEXT, TEXT)
      TO taseca_anon, taseca_app;
-- Funciones con sesión
GRANT EXECUTE ON FUNCTION rest.sesion(), rest.pedido(BIGINT), rest.avanzar_estado(BIGINT),
                          rest.cambiar_estado(BIGINT, TEXT), rest.cancelar_pedido(BIGINT, TEXT),
                          rest.anular_pedido(BIGINT, TEXT), rest.confirmar_pago(BIGINT, TEXT),
                          rest.rechazar_pago(BIGINT, TEXT), rest.comprobante(BIGINT)
      TO taseca_app;

-- Las vistas llaman funciones de core: se revisan contra quien consulta
GRANT USAGE ON SCHEMA core TO taseca_anon, taseca_rest;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA core FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    core.fn_fecha_operativa(INTEGER, TIMESTAMPTZ),
    core.fn_empresa_tiene_modulo(INTEGER, TEXT),
    core.fn_vendidos_plato(BIGINT),
    core.fn_normalizar_codigo_pedido(INTEGER, TEXT),
    core.fn_empresa_de_unidad(INTEGER),
    core.fn_jwt_claims(),
    core.fn_jwt_empresa()
TO taseca_anon, taseca_app;
GRANT EXECUTE ON FUNCTION core.fn_jwt_usuario(), core.fn_usuario_en_unidad(INTEGER, INTEGER), core.fn_pedido_json(BIGINT)
      TO taseca_app;

-- PostgREST lee el secreto al arrancar
GRANT EXECUTE ON FUNCTION core.fn_postgrest_pre_config() TO taseca_rest;

-- Los procedimientos nuevos o recreados en este archivo
GRANT EXECUTE ON PROCEDURE api.sp_registrar_comprobante(BIGINT, TEXT, VARCHAR, BIGINT),
                           api.sp_actualizar_pago(BIGINT, VARCHAR, INTEGER, VARCHAR)
      TO taseca_app;
REVOKE EXECUTE ON PROCEDURE api.sp_registrar_comprobante(BIGINT, TEXT, VARCHAR, BIGINT),
                            api.sp_actualizar_pago(BIGINT, VARCHAR, INTEGER, VARCHAR)
      FROM PUBLIC;

-- Que PostgREST recargue su caché de esquema si ya estaba corriendo
NOTIFY pgrst, 'reload schema';


/* ============================================================================
   10_OPTIMIZACION
   Auditoría liviana, índices y reportes
   ============================================================================ */

/* ============================================================================
   TASECA · 10 · OPTIMIZACIÓN PARA PRODUCCIÓN (Supabase)
   ----------------------------------------------------------------------------
   Ejecutar conectado a taseca_db, después de 01 … 09. Idempotente.

   Medido con una operación simulada de 30 días (260 pedidos/día en los 4
   locales, ver database/COSTOS_SUPABASE.md). Antes de este archivo:

       auditoria          42 MB   68 % de toda la base
       pedidos            7,8 MB  inflada por los cambios de estado
       total              61 MB por mes  ·  8,2 KB por pedido

   Qué hace:
     1. AUDITORÍA LIVIANA
        · guarda sólo las columnas que cambiaron, no la fila entera dos veces
        · deja de auditar lo que ya tiene su propio historial (pedidos →
          pedido_historial) y lo que no se modifica nunca (entradas,
          anulaciones): el registro mismo ES la auditoría
        · el INSERT de las tablas operativas no se audita: la fila ya dice
          quién y cuándo; se audita cuando alguien la CAMBIA
        · retención: api.sp_purgar_auditoria borra por lotes lo antiguo
        · índice BRIN por fecha (ocupa ~1 % de un B-tree)
     2. ÍNDICES
        · se quitan los índices de llaves hacia catálogos pequeños en tablas
          grandes (estado, método de pago, tipo…). Los catálogos nunca se
          borran, así que esos índices sólo costaban escritura y disco, y
          además impedían las actualizaciones HOT de pedidos.
     3. TABLAS QUE SE ACTUALIZAN MUCHO
        · fillfactor 85: deja espacio en la página para que el cambio de
          estado reescriba la fila en el mismo sitio (HOT) sin inflar índices
     4. VISTAS MÁS BARATAS
        · api.v_platos_dia calcula los vendidos una sola vez por plato
        · rest.pedidos resuelve la sesión y las unidades UNA vez por consulta
          y arma el JSON sólo de las filas que pasan el filtro (clave para el
          refresco incremental de la aplicación)
     5. MANTENIMIENTO PROGRAMADO (pg_cron, disponible en Supabase)
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. AUDITORÍA LIVIANA
   ============================================================================ */

-- 1.1 Una sola columna con los cambios: {"columna": {"de": …, "a": …}}
ALTER TABLE core.auditoria ADD COLUMN IF NOT EXISTS cambios JSONB;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'core' AND table_name = 'auditoria' AND column_name = 'datos_antes') THEN
        -- Lo ya registrado se convierte, no se pierde
        UPDATE core.auditoria a
           SET cambios = CASE
                   WHEN a.accion = 'INSERT' THEN a.datos_despues
                   WHEN a.accion = 'DELETE' THEN a.datos_antes
                   ELSE (SELECT jsonb_object_agg(k, jsonb_build_object('de', a.datos_antes -> k, 'a', a.datos_despues -> k))
                           FROM jsonb_object_keys(a.datos_despues) AS k
                          WHERE (a.datos_antes -> k) IS DISTINCT FROM (a.datos_despues -> k)
                            AND k <> 'actualizado_en')
               END
         WHERE a.cambios IS NULL;

        DROP VIEW IF EXISTS api.v_auditoria;
        ALTER TABLE core.auditoria DROP COLUMN datos_antes, DROP COLUMN datos_despues;
    END IF;
END;
$$;

COMMENT ON COLUMN core.auditoria.cambios IS
    'UPDATE: sólo lo que cambió {"col": {"de": x, "a": y}}. INSERT/DELETE: la fila. Nunca el hash del PIN ni imágenes.';

-- 1.2 El trigger guarda la diferencia
CREATE OR REPLACE FUNCTION core.tg_auditoria()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    c_fuera   CONSTANT TEXT[] := ARRAY['actualizado_en', 'pin_hash', 'archivo_url'];
    v_antes   JSONB;
    v_despues JSONB;
    v_cambios JSONB;
BEGIN
    IF TG_OP <> 'INSERT' THEN v_antes   := to_jsonb(OLD); END IF;
    IF TG_OP <> 'DELETE' THEN v_despues := to_jsonb(NEW); END IF;

    IF TG_OP = 'UPDATE' THEN
        SELECT jsonb_object_agg(k, jsonb_build_object('de', v_antes -> k, 'a', v_despues -> k))
          INTO v_cambios
          FROM jsonb_object_keys(v_despues - c_fuera) AS k
         WHERE (v_antes -> k) IS DISTINCT FROM (v_despues -> k);

        -- Cambió el PIN: se registra el hecho, jamás el valor
        IF (v_antes ->> 'pin_hash') IS DISTINCT FROM (v_despues ->> 'pin_hash') THEN
            v_cambios := COALESCE(v_cambios, '{}'::JSONB) || '{"pin": "cambiado"}'::JSONB;
        END IF;

        IF v_cambios IS NULL THEN
            RETURN NEW; -- nada relevante cambió
        END IF;
    ELSE
        v_cambios := COALESCE(v_despues, v_antes) - c_fuera;
    END IF;

    INSERT INTO core.auditoria (tabla, registro_id, accion, cambios, usuario_id)
    VALUES (TG_TABLE_NAME,
            (COALESCE(v_despues, v_antes) ->> 'id')::BIGINT,
            TG_OP, v_cambios, core.fn_usuario_actual());

    RETURN COALESCE(NEW, OLD);
END;
$$;

-- 1.3 Qué se audita y cómo
DO $$
DECLARE
    t TEXT;
BEGIN
    -- Fuera todos los triggers de auditoría anteriores
    FOR t IN SELECT c.relname
               FROM pg_trigger g JOIN pg_class c ON c.oid = g.tgrelid
              WHERE g.tgname LIKE 'trg\_%\_auditoria' ESCAPE '\'
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%1$s_auditoria ON core.%1$I', t);
    END LOOP;

    -- Configuración: pocas filas, se audita todo (alta, cambio y baja)
    FOREACH t IN ARRAY ARRAY['empresas', 'empresa_modulos', 'empresa_metodos_pago', 'unidades', 'zonas_domicilio',
                             'usuarios', 'usuario_unidades', 'rol_permisos', 'productos']
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%1$s_auditoria AFTER INSERT OR UPDATE OR DELETE ON core.%1$I
                 FOR EACH ROW EXECUTE FUNCTION core.tg_auditoria()', t);
    END LOOP;

    -- Operación: la fila nueva ya dice quién y cuándo; se audita si alguien la cambia
    FOREACH t IN ARRAY ARRAY['gastos', 'bases_caja', 'cierres_inventario', 'cierre_detalles']
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%1$s_auditoria AFTER UPDATE OR DELETE ON core.%1$I
                 FOR EACH ROW EXECUTE FUNCTION core.tg_auditoria()', t);
    END LOOP;

    /* Sin trigger, a propósito:
         pedidos, pedido_items    → pedido_historial registra cada cambio
         entradas_inventario      → inmutables: la fila es la auditoría
         anulaciones              → inmutables: la fila es la auditoría
         insumo_unidades          → el stock se deriva de entradas y cierres */
END;
$$;

-- 1.4 Índices: el de fecha pasa a BRIN (la tabla sólo crece en orden de fecha)
DROP INDEX IF EXISTS core.ix_auditoria_fecha;
CREATE INDEX IF NOT EXISTS ix_auditoria_fecha_brin ON core.auditoria USING BRIN (creado_en) WITH (pages_per_range = 32);

ALTER TABLE core.auditoria SET (autovacuum_vacuum_scale_factor = 0.05, autovacuum_analyze_scale_factor = 0.05);

-- 1.5 La vista con la nueva forma
CREATE OR REPLACE VIEW api.v_auditoria AS
SELECT a.id AS auditoria_id, a.tabla, a.registro_id, a.accion,
       us.nombre AS usuario, us.empresa_id, a.usuario_db, a.cambios, a.creado_en
  FROM core.auditoria a
  LEFT JOIN core.usuarios us ON us.id = a.usuario_id;

/* Una fila por columna cambiada: lo mismo que `cambios`, pero en columnas,
   para filtrar y hacer JOIN sin tocar JSON. */
CREATE OR REPLACE VIEW api.v_auditoria_detalle AS
SELECT a.id AS auditoria_id, a.tabla, a.registro_id, a.accion, a.usuario_id,
       us.nombre AS usuario, us.empresa_id, a.creado_en,
       c.key AS columna,
       CASE WHEN a.accion = 'UPDATE' THEN c.value ->> 'de' END AS valor_anterior,
       CASE WHEN a.accion = 'UPDATE' THEN c.value ->> 'a' ELSE c.value #>> '{}' END AS valor_nuevo
  FROM core.auditoria a
  CROSS JOIN LATERAL jsonb_each(a.cambios) c
  LEFT JOIN core.usuarios us ON us.id = a.usuario_id;

-- 1.6 Retención por lotes (no bloquea la tabla ni infla el WAL de golpe)
CREATE OR REPLACE PROCEDURE api.sp_purgar_auditoria(p_conservar_dias INTEGER DEFAULT 365, INOUT p_borradas BIGINT DEFAULT 0)
LANGUAGE plpgsql
SET search_path = core, public
AS $$
DECLARE
    v_limite TIMESTAMPTZ;
    v_n      BIGINT;
BEGIN
    IF p_conservar_dias IS NULL OR p_conservar_dias < 30 THEN
        RAISE EXCEPTION 'Conserva al menos 30 días de auditoría.';
    END IF;
    v_limite := now() - make_interval(days => p_conservar_dias);
    p_borradas := 0;
    LOOP
        DELETE FROM core.auditoria
         WHERE id IN (SELECT id FROM core.auditoria WHERE creado_en < v_limite ORDER BY id LIMIT 5000);
        GET DIAGNOSTICS v_n = ROW_COUNT;
        p_borradas := p_borradas + v_n;
        EXIT WHEN v_n = 0;
        COMMIT; -- cada lote en su transacción
    END LOOP;
END;
$$;

COMMENT ON PROCEDURE api.sp_purgar_auditoria(INTEGER, BIGINT) IS
    'Borra la auditoría más antigua que p_conservar_dias, de a 5.000 filas. Programar con pg_cron (ver sección 5).';


/* ============================================================================
   2. ÍNDICES QUE SOBRAN
   Llaves hacia catálogos que nunca se borran, en tablas que crecen. Se
   conservan los que sí usan las consultas (unidad + fecha, cliente,
   producto, plato, menú, historial).
   ============================================================================ */
DROP INDEX IF EXISTS core.ix_pedidos_estado;
DROP INDEX IF EXISTS core.ix_pedidos_estado_pago;
DROP INDEX IF EXISTS core.ix_pedidos_metodo;
DROP INDEX IF EXISTS core.ix_pedidos_tipo;
DROP INDEX IF EXISTS core.ix_pedidos_mesa;
DROP INDEX IF EXISTS core.ix_pedidos_zona;
DROP INDEX IF EXISTS core.ix_gastos_estado;
DROP INDEX IF EXISTS core.ix_gastos_metodo;
DROP INDEX IF EXISTS core.ix_gastos_categoria;
DROP INDEX IF EXISTS core.ix_entradas_tipo;
DROP INDEX IF EXISTS core.ix_cierres_estado;
DROP INDEX IF EXISTS core.ix_cierres_area;
DROP INDEX IF EXISTS core.ix_menus_dia_tipo;
DROP INDEX IF EXISTS core.ix_bases_caja_unidad_fecha;   -- lo cubre uq_bases_caja_vigente
DROP INDEX IF EXISTS core.ix_pedidos_empresa_fecha;     -- lo cubren uq_pedidos_codigo + ix_pedidos_unidad_fecha

-- El filtro de rest.pedidos: empresa + jornada
CREATE INDEX IF NOT EXISTS ix_pedidos_empresa_jornada ON core.pedidos (empresa_id, fecha_operativa);


/* ============================================================================
   3. TABLAS QUE SE ACTUALIZAN MUCHO: espacio para actualizaciones HOT
   ============================================================================ */
ALTER TABLE core.pedidos            SET (fillfactor = 85);
ALTER TABLE core.consecutivos       SET (fillfactor = 50);
ALTER TABLE core.insumo_unidades    SET (fillfactor = 80);
ALTER TABLE core.cierres_inventario SET (fillfactor = 85);
ALTER TABLE core.gastos             SET (fillfactor = 90);
ALTER TABLE core.pedido_historial   SET (autovacuum_vacuum_scale_factor = 0.05, autovacuum_analyze_scale_factor = 0.05);


/* ============================================================================
   4. VISTAS MÁS BARATAS
   ============================================================================ */

-- Vendidos calculados UNA vez por plato (antes: tres llamadas por fila)
CREATE OR REPLACE VIEW api.v_platos_dia AS
SELECT pd.id AS plato_dia_id, pd.menu_dia_id, m.unidad_id, m.fecha,
       pd.nombre, pd.descripcion, pd.emoji, pd.precio, pd.cupos, pd.disponible, pd.orden,
       v.vendidos,
       CASE WHEN pd.cupos IS NULL THEN NULL ELSE GREATEST(pd.cupos - v.vendidos, 0) END AS cupos_restantes,
       (pd.disponible AND m.disponible AND (pd.cupos IS NULL OR v.vendidos < pd.cupos)) AS se_puede_pedir
  FROM core.platos_dia pd
  JOIN core.menus_dia m ON m.id = pd.menu_dia_id
  CROSS JOIN LATERAL (SELECT core.fn_vendidos_plato(pd.id) AS vendidos) v;

/* Sesión y unidades permitidas resueltas una sola vez; el JSON se arma
   después de filtrar. Con ?actualizado_en=gt.… sólo viajan los cambios. */
CREATE OR REPLACE VIEW rest.pedidos AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_usuario() AS usuario_id, core.fn_jwt_empresa() AS empresa_id
),
unidades AS MATERIALIZED (
    SELECT u.id
      FROM core.unidades u, sesion s
     WHERE u.empresa_id = s.empresa_id
       AND core.fn_usuario_en_unidad(s.usuario_id, u.id)
)
SELECT p.id AS pedido_id, p.empresa_id, p.unidad_id, p.codigo, e.codigo AS estado, p.fecha_operativa,
       p.actualizado_en, core.fn_pedido_json(p.id) AS pedido
  FROM core.pedidos p
  JOIN sesion s             ON s.empresa_id = p.empresa_id
  JOIN unidades un          ON un.id = p.unidad_id
  JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
 WHERE p.fecha_operativa >= core.fn_fecha_operativa(p.empresa_id, now()) - 31;


/* ============================================================================
   5. PERMISOS Y MANTENIMIENTO
   ============================================================================ */
REVOKE ALL ON PROCEDURE api.sp_purgar_auditoria(INTEGER, BIGINT) FROM PUBLIC, taseca_app;
GRANT SELECT ON api.v_auditoria, api.v_auditoria_detalle TO taseca_lectura;
GRANT SELECT ON rest.pedidos TO taseca_app;
GRANT SELECT ON api.v_platos_dia TO taseca_app, taseca_lectura;

/* En Supabase (Database → Extensions → pg_cron), programa el mantenimiento:

   SELECT cron.schedule('purgar-auditoria', '30 3 * * *',
                        $$CALL api.sp_purgar_auditoria(365)$$);
   SELECT cron.schedule('reportes-mensuales', '0 4 * * *',
                        $$CALL api.sp_refrescar_reportes()$$);
*/

ANALYZE core.auditoria;
ANALYZE core.pedidos;
NOTIFY pgrst, 'reload schema';


/* ============================================================================
   11_FASE2_CARTA_MENU
   Fase 2 · carta y menú del día
   ============================================================================ */

/* ============================================================================
   TASECA · 11 · FASE 2 · BLOQUE 1: CARTA Y MENÚ DEL DÍA DESDE LA APLICACIÓN
   ----------------------------------------------------------------------------
   Ejecutar conectado a taseca_db, después de 01 … 10. Se puede volver a
   ejecutar: todo es idempotente.

   QUÉ AGREGA
     · Los procedimientos que faltaban para administrar la carta y el menú:
       categorías de la carta, borrar (producto, categoría, plato, categoría
       y opción del menú armado) y el ORDEN de categorías, opciones y platos.
     · rest.sincronizar_catalogo: la aplicación manda en UNA petición lo que
       cambió una acción del panel (guardar, mover, copiar, borrar…) y la
       base lo aplica en UNA transacción llamando a esos procedimientos. Si
       algo falla no queda nada a medias.

   REGLAS QUE PROTEGEN LA HISTORIA
     · Un producto que ya se vendió no se borra: se oculta de la carta.
     · Un plato del chef, o una opción del menú armado, que ya se vendió no
       se borra ni se renombra: se marca como no disponible / inactiva.
     · Una categoría de la carta con productos no se borra.

   SEGURIDAD
     El usuario y la empresa salen SIEMPRE del token. Cada procedimiento
     vuelve a exigir el permiso ('carta' o 'menu'), que el usuario trabaje en
     la unidad y que todo sea de su empresa: el navegador no puede tocar la
     carta de otra empresa aunque cambie los ids de la petición.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. APOYO
   ============================================================================ */

/* La aplicación escribe los ids con prefijo (p12, c3, mc5…). Devuelve el
   número si el texto tiene ESE prefijo; si no (un registro nuevo creado en
   el navegador, con id propio), NULL. */
CREATE OR REPLACE FUNCTION core.fn_id_de_app(p_id TEXT, p_prefijo TEXT)
RETURNS BIGINT
LANGUAGE sql IMMUTABLE
AS $$
    SELECT CASE WHEN p_id ~ ('^' || p_prefijo || '[0-9]{1,18}$')
                THEN substr(p_id, length(p_prefijo) + 1)::BIGINT END;
$$;

/* Cada unidad de la lista debe ser de la empresa y el usuario debe trabajar
   en ella. */
CREATE OR REPLACE FUNCTION core.fn_exigir_unidades(p_usuario_id INTEGER, p_empresa_id INTEGER, p_unidades INTEGER[])
RETURNS VOID
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_u INTEGER;
BEGIN
    IF p_unidades IS NULL OR cardinality(p_unidades) = 0 THEN
        RAISE EXCEPTION 'Elige al menos una unidad.';
    END IF;
    FOREACH v_u IN ARRAY p_unidades LOOP
        IF core.fn_empresa_de_unidad(v_u) IS DISTINCT FROM p_empresa_id THEN
            RAISE EXCEPTION 'La unidad % no es de esta empresa.', v_u USING ERRCODE = 'insufficient_privilege';
        END IF;
        IF NOT core.fn_usuario_en_unidad(p_usuario_id, v_u) THEN
            RAISE EXCEPTION 'No trabajas en la unidad "%".', (SELECT nombre FROM core.unidades WHERE id = v_u)
                  USING ERRCODE = 'insufficient_privilege';
        END IF;
    END LOOP;
END;
$$;


/* ============================================================================
   2. CARTA
   ============================================================================ */

/* Categoría de la carta. Una categoría NUEVA con el nombre de otra que ya
   existe en la empresa no se duplica: la existente pasa a ser también de
   estas unidades (así "Bebidas" puede estar en el bar y en la arepera). */
CREATE OR REPLACE PROCEDURE api.sp_guardar_categoria(
    p_empresa_id  INTEGER,
    p_nombre      VARCHAR,
    p_unidades    INTEGER[],
    p_usuario_id  INTEGER,
    p_icono       VARCHAR DEFAULT NULL,
    p_orden       INTEGER DEFAULT NULL,
    p_activa      BOOLEAN DEFAULT TRUE,
    INOUT p_categoria_id INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre VARCHAR := regexp_replace(trim(COALESCE(p_nombre, '')), '\s+', ' ', 'g');
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'carta');
    PERFORM core.fn_exigir_unidades(p_usuario_id, p_empresa_id, p_unidades);

    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'Escribe el nombre de la categoría.';
    END IF;

    IF p_categoria_id IS NULL THEN
        SELECT id INTO p_categoria_id
          FROM core.categorias
         WHERE empresa_id = p_empresa_id AND lower(nombre) = lower(v_nombre);

        IF p_categoria_id IS NULL THEN
            INSERT INTO core.categorias (empresa_id, nombre, icono, orden, activa)
            VALUES (p_empresa_id, v_nombre, NULLIF(trim(p_icono), ''),
                    COALESCE(p_orden, (SELECT COALESCE(max(orden), 0) + 10 FROM core.categorias WHERE empresa_id = p_empresa_id)),
                    COALESCE(p_activa, TRUE))
            RETURNING id INTO p_categoria_id;
        END IF;

        INSERT INTO core.categoria_unidades (categoria_id, unidad_id)
        SELECT p_categoria_id, x FROM unnest(p_unidades) x
        ON CONFLICT (categoria_id, unidad_id) DO NOTHING;
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM core.categorias
                WHERE empresa_id = p_empresa_id AND lower(nombre) = lower(v_nombre) AND id <> p_categoria_id) THEN
        RAISE EXCEPTION 'Ya hay otra categoría llamada "%".', v_nombre;
    END IF;

    UPDATE core.categorias
       SET nombre = v_nombre, icono = NULLIF(trim(p_icono), ''), orden = COALESCE(p_orden, orden),
           activa = COALESCE(p_activa, activa)
     WHERE id = p_categoria_id AND empresa_id = p_empresa_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Esa categoría ya no existe. Recarga la página.';
    END IF;

    -- Sólo se retiran las unidades en las que trabaja el usuario
    DELETE FROM core.categoria_unidades
     WHERE categoria_id = p_categoria_id
       AND unidad_id <> ALL (p_unidades)
       AND core.fn_usuario_en_unidad(p_usuario_id, unidad_id);
    INSERT INTO core.categoria_unidades (categoria_id, unidad_id)
    SELECT p_categoria_id, x FROM unnest(p_unidades) x
    ON CONFLICT (categoria_id, unidad_id) DO NOTHING;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_borrar_categoria(p_categoria_id INTEGER, p_usuario_id INTEGER, p_empresa_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_productos INTEGER;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'carta');

    IF NOT EXISTS (SELECT 1 FROM core.categorias WHERE id = p_categoria_id AND empresa_id = p_empresa_id) THEN
        RAISE EXCEPTION 'Esa categoría ya no existe. Recarga la página.';
    END IF;

    SELECT count(*) INTO v_productos FROM core.productos WHERE categoria_id = p_categoria_id;
    IF v_productos > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: hay % productos en esta categoría. Muévelos a otra o desactiva la categoría.', v_productos;
    END IF;

    DELETE FROM core.categorias WHERE id = p_categoria_id;
END;
$$;

/* Se reemplaza la versión de 04: agrega la imagen, genera el código si
   viene vacío, da mensajes claros y no retira unidades ajenas al usuario. */
DROP PROCEDURE IF EXISTS api.sp_guardar_producto(INTEGER, INTEGER, VARCHAR, VARCHAR, NUMERIC, INTEGER[], INTEGER,
                                                 VARCHAR, VARCHAR, BOOLEAN, INTEGER, INTEGER);

CREATE OR REPLACE PROCEDURE api.sp_guardar_producto(
    p_empresa_id    INTEGER,
    p_categoria_id  INTEGER,
    p_codigo        VARCHAR,
    p_nombre        VARCHAR,
    p_precio        NUMERIC,
    p_unidades      INTEGER[],
    p_usuario_id    INTEGER,
    p_descripcion   VARCHAR DEFAULT NULL,
    p_etiqueta      VARCHAR DEFAULT NULL,
    p_activo        BOOLEAN DEFAULT TRUE,
    p_orden         INTEGER DEFAULT NULL,
    p_imagen_url    VARCHAR DEFAULT NULL,
    INOUT p_producto_id INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_etiqueta INTEGER := CASE WHEN NULLIF(trim(p_etiqueta), '') IS NULL THEN NULL
                               ELSE core.fn_id_catalogo('etiquetas_producto', trim(p_etiqueta)) END;
    v_codigo   VARCHAR := NULLIF(upper(trim(COALESCE(p_codigo, ''))), '');
    v_nombre   VARCHAR := trim(COALESCE(p_nombre, ''));
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'carta');
    PERFORM core.fn_exigir_unidades(p_usuario_id, p_empresa_id, p_unidades);

    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'El producto necesita un nombre.';
    END IF;
    IF p_precio IS NULL OR p_precio < 0 THEN
        RAISE EXCEPTION 'El precio de "%" no es válido.', v_nombre;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.categorias WHERE id = p_categoria_id AND empresa_id = p_empresa_id) THEN
        RAISE EXCEPTION 'El producto "%" necesita una categoría de esta empresa.', v_nombre;
    END IF;
    IF v_codigo IS NOT NULL AND EXISTS (SELECT 1 FROM core.productos
                                         WHERE empresa_id = p_empresa_id AND codigo = v_codigo
                                           AND id IS DISTINCT FROM p_producto_id) THEN
        RAISE EXCEPTION 'Ya hay otro producto con el código %.', v_codigo;
    END IF;

    IF p_producto_id IS NULL THEN
        INSERT INTO core.productos (empresa_id, categoria_id, etiqueta_id, codigo, nombre, descripcion,
                                    precio, imagen_url, activo, orden)
        VALUES (p_empresa_id, p_categoria_id, v_etiqueta,
                COALESCE(v_codigo, 'TMP-' || left(md5(random()::TEXT || clock_timestamp()::TEXT), 24)),
                v_nombre, NULLIF(trim(p_descripcion), ''), p_precio, NULLIF(trim(p_imagen_url), ''),
                COALESCE(p_activo, TRUE),
                COALESCE(p_orden, (SELECT COALESCE(max(orden), 0) + 10 FROM core.productos WHERE empresa_id = p_empresa_id)))
        RETURNING id INTO p_producto_id;

        IF v_codigo IS NULL THEN
            UPDATE core.productos SET codigo = 'P' || lpad(p_producto_id::TEXT, 4, '0') WHERE id = p_producto_id;
        END IF;
    ELSE
        UPDATE core.productos
           SET categoria_id = p_categoria_id, etiqueta_id = v_etiqueta, codigo = COALESCE(v_codigo, codigo),
               nombre = v_nombre, descripcion = NULLIF(trim(p_descripcion), ''), precio = p_precio,
               imagen_url = NULLIF(trim(p_imagen_url), ''), activo = COALESCE(p_activo, activo),
               orden = COALESCE(p_orden, orden)
         WHERE id = p_producto_id AND empresa_id = p_empresa_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Ese producto ya no existe. Recarga la página.';
        END IF;
    END IF;

    DELETE FROM core.producto_unidades
     WHERE producto_id = p_producto_id
       AND unidad_id <> ALL (p_unidades)
       AND core.fn_usuario_en_unidad(p_usuario_id, unidad_id);
    INSERT INTO core.producto_unidades (producto_id, unidad_id)
    SELECT p_producto_id, x FROM unnest(p_unidades) x
    ON CONFLICT (producto_id, unidad_id) DO NOTHING;
END;
$$;

/* Si ya se vendió se oculta (p_desactivado = TRUE); si no, se elimina. */
CREATE OR REPLACE PROCEDURE api.sp_borrar_producto(
    p_producto_id  INTEGER,
    p_usuario_id   INTEGER,
    p_empresa_id   INTEGER,
    INOUT p_desactivado BOOLEAN DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'carta');

    IF NOT EXISTS (SELECT 1 FROM core.productos WHERE id = p_producto_id AND empresa_id = p_empresa_id) THEN
        RAISE EXCEPTION 'Ese producto ya no existe. Recarga la página.';
    END IF;

    IF EXISTS (SELECT 1 FROM core.pedido_items WHERE producto_id = p_producto_id) THEN
        UPDATE core.productos SET activo = FALSE WHERE id = p_producto_id;
        p_desactivado := TRUE;
    ELSE
        DELETE FROM core.productos WHERE id = p_producto_id;
        p_desactivado := FALSE;
    END IF;
END;
$$;


/* ============================================================================
   3. MENÚ DEL DÍA
   Se reemplazan tres procedimientos de 04 para agregar el ORDEN y avisar
   cuando el registro que se edita no existe (antes no hacían nada).
   ============================================================================ */

/* "Qué incluye" el plato del chef (opcional). El portal lo muestra debajo
   del plato; en el MVP local ya existía. */
ALTER TABLE core.platos_dia ADD COLUMN IF NOT EXISTS incluye_sopa      VARCHAR(80);
ALTER TABLE core.platos_dia ADD COLUMN IF NOT EXISTS incluye_principio VARCHAR(80);
ALTER TABLE core.platos_dia ADD COLUMN IF NOT EXISTS incluye_proteina  VARCHAR(80);
ALTER TABLE core.platos_dia ADD COLUMN IF NOT EXISTS incluye_bebida    VARCHAR(80);

CREATE OR REPLACE VIEW api.v_platos_dia AS
SELECT pd.id AS plato_dia_id, pd.menu_dia_id, m.unidad_id, m.fecha,
       pd.nombre, pd.descripcion, pd.emoji, pd.precio, pd.cupos, pd.disponible, pd.orden,
       v.vendidos,
       CASE WHEN pd.cupos IS NULL THEN NULL ELSE GREATEST(pd.cupos - v.vendidos, 0) END AS cupos_restantes,
       (pd.disponible AND m.disponible AND (pd.cupos IS NULL OR v.vendidos < pd.cupos)) AS se_puede_pedir,
       pd.incluye_sopa, pd.incluye_principio, pd.incluye_proteina, pd.incluye_bebida
  FROM core.platos_dia pd
  JOIN core.menus_dia m ON m.id = pd.menu_dia_id
  CROSS JOIN LATERAL (SELECT core.fn_vendidos_plato(pd.id) AS vendidos) v;

CREATE OR REPLACE VIEW rest.menus_dia AS
SELECT m.id AS menu_dia_id, u.empresa_id, m.unidad_id, m.fecha, t.codigo AS tipo,
       m.nombre, m.descripcion, m.precio, m.disponible,
       m.titulo_publico AS titulo_fecha, m.mensaje_publico AS mensaje_fecha,
       COALESCE((SELECT jsonb_agg(jsonb_build_object(
                          'categoria_id', c.id, 'nombre', c.nombre, 'icono', c.icono, 'orden', c.orden,
                          'obligatoria', c.obligatoria, 'max_seleccion', c.max_seleccion, 'activa', c.activa,
                          'opciones', COALESCE((SELECT jsonb_agg(jsonb_build_object('opcion_id', o.id, 'nombre', o.nombre,
                                                                                    'orden', o.orden, 'activa', o.activa)
                                                                 ORDER BY o.orden)
                                                  FROM core.menu_opciones o WHERE o.menu_categoria_id = c.id), '[]'))
                      ORDER BY c.orden)
                   FROM core.menu_categorias c WHERE c.menu_dia_id = m.id), '[]') AS categorias,
       COALESCE((SELECT jsonb_agg(jsonb_build_object(
                          'plato_dia_id', p.plato_dia_id, 'nombre', p.nombre, 'descripcion', p.descripcion,
                          'emoji', p.emoji, 'precio', p.precio, 'cupos', p.cupos, 'vendidos', p.vendidos,
                          'disponible', p.disponible, 'orden', p.orden,
                          'sopa', p.incluye_sopa, 'principio', p.incluye_principio,
                          'proteina', p.incluye_proteina, 'bebida', p.incluye_bebida)
                      ORDER BY p.orden)
                   FROM api.v_platos_dia p WHERE p.menu_dia_id = m.id), '[]') AS platos
  FROM core.menus_dia m
  JOIN core.unidades u   ON u.id = m.unidad_id
  JOIN core.tipos_menu t ON t.id = m.tipo_menu_id
 WHERE m.fecha BETWEEN core.fn_fecha_operativa(u.empresa_id, now()) - 7
                   AND core.fn_fecha_operativa(u.empresa_id, now()) + 14;

DROP PROCEDURE IF EXISTS api.sp_guardar_menu_categoria(BIGINT, VARCHAR, INTEGER, INTEGER, BOOLEAN, VARCHAR, BOOLEAN, BIGINT);
DROP PROCEDURE IF EXISTS api.sp_guardar_menu_opcion(BIGINT, VARCHAR, INTEGER, BOOLEAN, BIGINT);
DROP PROCEDURE IF EXISTS api.sp_guardar_plato_dia(BIGINT, VARCHAR, NUMERIC, INTEGER, VARCHAR, VARCHAR, INTEGER, BOOLEAN, BIGINT);
DROP PROCEDURE IF EXISTS api.sp_guardar_plato_dia(BIGINT, VARCHAR, NUMERIC, INTEGER, VARCHAR, VARCHAR, INTEGER, BOOLEAN, INTEGER, BIGINT);

CREATE OR REPLACE PROCEDURE api.sp_guardar_menu_categoria(
    p_menu_dia_id    BIGINT,
    p_nombre         VARCHAR,
    p_usuario_id     INTEGER,
    p_max_seleccion  INTEGER  DEFAULT 1,
    p_obligatoria    BOOLEAN  DEFAULT TRUE,
    p_icono          VARCHAR  DEFAULT NULL,
    p_activa         BOOLEAN  DEFAULT TRUE,
    p_orden          INTEGER  DEFAULT NULL,
    INOUT p_categoria_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre VARCHAR := regexp_replace(trim(COALESCE(p_nombre, '')), '\s+', ' ', 'g');
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu',
            (SELECT unidad_id FROM core.menus_dia WHERE id = p_menu_dia_id));

    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'Escribe el nombre de la categoría.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.menu_categorias
                WHERE menu_dia_id = p_menu_dia_id AND lower(nombre) = lower(v_nombre)
                  AND id IS DISTINCT FROM p_categoria_id) THEN
        RAISE EXCEPTION 'Ya hay una categoría llamada "%".', v_nombre;
    END IF;

    IF p_categoria_id IS NULL THEN
        INSERT INTO core.menu_categorias (menu_dia_id, nombre, icono, orden, obligatoria, max_seleccion, activa)
        VALUES (p_menu_dia_id, v_nombre, NULLIF(trim(p_icono), ''),
                COALESCE(p_orden, (SELECT COALESCE(max(orden), 0) + 1 FROM core.menu_categorias WHERE menu_dia_id = p_menu_dia_id)),
                COALESCE(p_obligatoria, TRUE), LEAST(GREATEST(COALESCE(p_max_seleccion, 1), 1), 10), COALESCE(p_activa, TRUE))
        RETURNING id INTO p_categoria_id;
    ELSE
        UPDATE core.menu_categorias
           SET nombre = v_nombre, icono = NULLIF(trim(p_icono), ''), obligatoria = COALESCE(p_obligatoria, obligatoria),
               max_seleccion = LEAST(GREATEST(COALESCE(p_max_seleccion, max_seleccion), 1), 10),
               activa = COALESCE(p_activa, activa), orden = COALESCE(p_orden, orden)
         WHERE id = p_categoria_id AND menu_dia_id = p_menu_dia_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Esa categoría ya no existe. Recarga la página.';
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_guardar_menu_opcion(
    p_menu_categoria_id BIGINT,
    p_nombre            VARCHAR,
    p_usuario_id        INTEGER,
    p_activa            BOOLEAN DEFAULT TRUE,
    p_orden             INTEGER DEFAULT NULL,
    INOUT p_opcion_id   BIGINT  DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre VARCHAR := regexp_replace(trim(COALESCE(p_nombre, '')), '\s+', ' ', 'g');
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu',
            (SELECT m.unidad_id FROM core.menu_categorias c JOIN core.menus_dia m ON m.id = c.menu_dia_id
              WHERE c.id = p_menu_categoria_id));

    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'Escribe el nombre de la opción.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.menu_opciones
                WHERE menu_categoria_id = p_menu_categoria_id AND lower(nombre) = lower(v_nombre)
                  AND id IS DISTINCT FROM p_opcion_id) THEN
        RAISE EXCEPTION '"%" ya está en esta categoría.', v_nombre;
    END IF;

    IF p_opcion_id IS NULL THEN
        INSERT INTO core.menu_opciones (menu_categoria_id, nombre, orden, activa)
        VALUES (p_menu_categoria_id, v_nombre,
                COALESCE(p_orden, (SELECT COALESCE(max(orden), 0) + 1 FROM core.menu_opciones WHERE menu_categoria_id = p_menu_categoria_id)),
                COALESCE(p_activa, TRUE))
        RETURNING id INTO p_opcion_id;
    ELSE
        UPDATE core.menu_opciones
           SET nombre = v_nombre, activa = COALESCE(p_activa, activa), orden = COALESCE(p_orden, orden)
         WHERE id = p_opcion_id AND menu_categoria_id = p_menu_categoria_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Esa opción ya no existe. Recarga la página.';
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_guardar_plato_dia(
    p_menu_dia_id  BIGINT,
    p_nombre       VARCHAR,
    p_precio       NUMERIC,
    p_usuario_id   INTEGER,
    p_descripcion  VARCHAR DEFAULT NULL,
    p_emoji        VARCHAR DEFAULT NULL,
    p_cupos        INTEGER DEFAULT NULL,
    p_disponible   BOOLEAN DEFAULT TRUE,
    p_orden        INTEGER DEFAULT NULL,
    p_sopa         VARCHAR DEFAULT NULL,
    p_principio    VARCHAR DEFAULT NULL,
    p_proteina     VARCHAR DEFAULT NULL,
    p_bebida       VARCHAR DEFAULT NULL,
    INOUT p_plato_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre VARCHAR := trim(COALESCE(p_nombre, ''));
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu',
            (SELECT unidad_id FROM core.menus_dia WHERE id = p_menu_dia_id));

    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'El plato necesita un nombre.';
    END IF;
    IF p_precio IS NULL OR p_precio <= 0 THEN
        RAISE EXCEPTION 'El plato "%" necesita un precio mayor a cero.', v_nombre;
    END IF;
    IF p_cupos IS NOT NULL AND p_cupos <= 0 THEN
        RAISE EXCEPTION 'Los cupos de "%" deben ser mayores a cero, o dejarse vacíos para no tener límite.', v_nombre;
    END IF;

    IF p_plato_id IS NULL THEN
        INSERT INTO core.platos_dia (menu_dia_id, nombre, descripcion, emoji, precio, cupos, disponible, orden,
                                     incluye_sopa, incluye_principio, incluye_proteina, incluye_bebida)
        VALUES (p_menu_dia_id, v_nombre, NULLIF(trim(p_descripcion), ''), NULLIF(trim(p_emoji), ''), p_precio,
                p_cupos, COALESCE(p_disponible, TRUE),
                COALESCE(p_orden, (SELECT COALESCE(max(orden), 0) + 1 FROM core.platos_dia WHERE menu_dia_id = p_menu_dia_id)),
                NULLIF(trim(p_sopa), ''), NULLIF(trim(p_principio), ''), NULLIF(trim(p_proteina), ''), NULLIF(trim(p_bebida), ''))
        RETURNING id INTO p_plato_id;
    ELSE
        UPDATE core.platos_dia
           SET nombre = v_nombre, descripcion = NULLIF(trim(p_descripcion), ''), emoji = NULLIF(trim(p_emoji), ''),
               precio = p_precio, cupos = p_cupos, disponible = COALESCE(p_disponible, disponible),
               orden = COALESCE(p_orden, orden),
               incluye_sopa = NULLIF(trim(p_sopa), ''), incluye_principio = NULLIF(trim(p_principio), ''),
               incluye_proteina = NULLIF(trim(p_proteina), ''), incluye_bebida = NULLIF(trim(p_bebida), '')
         WHERE id = p_plato_id AND menu_dia_id = p_menu_dia_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Ese plato ya no existe. Recarga la página.';
        END IF;
    END IF;
END;
$$;

/* Igual que en 04, pero también copia "qué incluye" de cada plato. */
CREATE OR REPLACE PROCEDURE api.sp_copiar_menu_dia(
    p_unidad_id      INTEGER,
    p_fecha_origen   DATE,
    p_fecha_destino  DATE,
    p_usuario_id     INTEGER,
    INOUT p_menu_id  BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_origen core.menus_dia;
    v_cat    RECORD;
    v_nueva  BIGINT;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu', p_unidad_id);

    SELECT * INTO v_origen FROM core.menus_dia WHERE unidad_id = p_unidad_id AND fecha = p_fecha_origen;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No hay menú el % en esta unidad.', p_fecha_origen;
    END IF;
    IF EXISTS (SELECT 1 FROM core.menus_dia WHERE unidad_id = p_unidad_id AND fecha = p_fecha_destino) THEN
        RAISE EXCEPTION 'El % ya tiene menú: copiar nunca lo reemplaza.', p_fecha_destino;
    END IF;

    INSERT INTO core.menus_dia (unidad_id, fecha, tipo_menu_id, nombre, descripcion, precio, disponible,
                                titulo_publico, mensaje_publico, creado_por_id)
    VALUES (p_unidad_id, p_fecha_destino, v_origen.tipo_menu_id, v_origen.nombre, v_origen.descripcion,
            v_origen.precio, v_origen.disponible, v_origen.titulo_publico, v_origen.mensaje_publico, p_usuario_id)
    RETURNING id INTO p_menu_id;

    FOR v_cat IN SELECT * FROM core.menu_categorias WHERE menu_dia_id = v_origen.id ORDER BY orden LOOP
        INSERT INTO core.menu_categorias (menu_dia_id, nombre, icono, orden, obligatoria, max_seleccion, activa)
        VALUES (p_menu_id, v_cat.nombre, v_cat.icono, v_cat.orden, v_cat.obligatoria, v_cat.max_seleccion, v_cat.activa)
        RETURNING id INTO v_nueva;

        INSERT INTO core.menu_opciones (menu_categoria_id, nombre, orden, activa)
        SELECT v_nueva, nombre, orden, activa FROM core.menu_opciones WHERE menu_categoria_id = v_cat.id;
    END LOOP;

    INSERT INTO core.platos_dia (menu_dia_id, nombre, descripcion, emoji, precio, cupos, disponible, orden,
                                 incluye_sopa, incluye_principio, incluye_proteina, incluye_bebida)
    SELECT p_menu_id, nombre, descripcion, emoji, precio, cupos, disponible, orden,
           incluye_sopa, incluye_principio, incluye_proteina, incluye_bebida
      FROM core.platos_dia WHERE menu_dia_id = v_origen.id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_borrar_plato_dia(p_plato_id BIGINT, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre VARCHAR;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu',
            (SELECT m.unidad_id FROM core.platos_dia p JOIN core.menus_dia m ON m.id = p.menu_dia_id
              WHERE p.id = p_plato_id));

    SELECT nombre INTO v_nombre FROM core.platos_dia WHERE id = p_plato_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese plato ya no existe. Recarga la página.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.pedido_items WHERE plato_dia_id = p_plato_id) THEN
        RAISE EXCEPTION '"%" ya se vendió: no se puede eliminar. Márcalo como no disponible.', v_nombre;
    END IF;

    DELETE FROM core.platos_dia WHERE id = p_plato_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_borrar_menu_opcion(p_opcion_id BIGINT, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre VARCHAR;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu',
            (SELECT m.unidad_id FROM core.menu_opciones o
               JOIN core.menu_categorias c ON c.id = o.menu_categoria_id
               JOIN core.menus_dia m       ON m.id = c.menu_dia_id
              WHERE o.id = p_opcion_id));

    SELECT nombre INTO v_nombre FROM core.menu_opciones WHERE id = p_opcion_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Esa opción ya no existe. Recarga la página.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.pedido_item_opciones WHERE menu_opcion_id = p_opcion_id) THEN
        RAISE EXCEPTION '"%" ya se vendió: no se puede eliminar. Desactívala.', v_nombre;
    END IF;

    DELETE FROM core.menu_opciones WHERE id = p_opcion_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_borrar_menu_categoria(p_categoria_id BIGINT, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre VARCHAR;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu',
            (SELECT m.unidad_id FROM core.menu_categorias c JOIN core.menus_dia m ON m.id = c.menu_dia_id
              WHERE c.id = p_categoria_id));

    SELECT nombre INTO v_nombre FROM core.menu_categorias WHERE id = p_categoria_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Esa categoría ya no existe. Recarga la página.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.menu_opciones o
                 JOIN core.pedido_item_opciones x ON x.menu_opcion_id = o.id
                WHERE o.menu_categoria_id = p_categoria_id) THEN
        RAISE EXCEPTION 'La categoría "%" ya tiene opciones vendidas: no se puede eliminar. Desactívala.', v_nombre;
    END IF;

    DELETE FROM core.menu_categorias WHERE id = p_categoria_id;
END;
$$;


/* ============================================================================
   4. API REST · SINCRONIZAR LO QUE CAMBIÓ EN EL PANEL
   ----------------------------------------------------------------------------
   POST /rpc/sincronizar_catalogo  { "p_cambios": { … } }

   p_cambios trae sólo lo que cambió, con la forma que usa la aplicación:
     categorias           [{ id, nombre, icono, orden, activa, sucursales }]
     productos            [{ id, codigo, cat, nombre, desc, precio, tag, orden,
                             activo, agotado, sucursales, imagen }]
     productos_borrados   ["p12", …]
     categorias_borradas  ["c3", …]
     menus                [{ id, sucursalId, fecha, tipo, publico,
                             armado: { nombre, descripcion, precio, disponible,
                                       categorias: [{ id, nombre, icono, obligatoria,
                                                      maxSeleccion, activa,
                                                      opciones: [{ id, nombre, activa }] }] } }]
                          (fecha "*" = título y mensaje de la unidad)
     platos_borrados      ["d8", …]
     platos               [{ id, sucursalId, fecha, nombre, desc, emoji, precio,
                             cupos, disponible, orden }]

   Un id sin el prefijo de la base (p, c, m, mc, mo, d) es un registro nuevo.
   Devuelve { "desactivados": ["p12"] }: productos que se ocultaron en vez
   de borrarse porque ya tenían ventas.
   ============================================================================ */

CREATE OR REPLACE FUNCTION rest.sincronizar_catalogo(p_cambios JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario      INTEGER := core.fn_exigir_sesion();
    v_empresa      INTEGER := core.fn_jwt_empresa();
    r              JSONB;
    a              JSONB;
    c              JSONB;
    o              JSONB;
    k              INTEGER;
    k2             INTEGER;
    v_txt          TEXT;
    v_int          INTEGER;
    v_big          BIGINT;
    v_flag         BOOLEAN;
    v_unidades     INTEGER[];
    v_unidad       INTEGER;
    v_fecha        DATE;
    v_menu         BIGINT;
    v_existente    BIGINT;
    v_cat_menu     BIGINT;
    v_mapa_cat     JSONB := '{}';
    v_desactivados JSONB := '[]';
BEGIN
    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'Tu sesión no pertenece a una empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    p_cambios := COALESCE(p_cambios, '{}');

    /* ---- 1. Categorías de la carta ---- */
    FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_cambios -> 'categorias', '[]')) LOOP
        v_int := core.fn_id_de_app(r ->> 'id', 'c');
        v_unidades := ARRAY(SELECT x::INTEGER FROM jsonb_array_elements_text(COALESCE(r -> 'sucursales', '[]')) x);
        CALL api.sp_guardar_categoria(
            p_empresa_id => v_empresa, p_nombre => r ->> 'nombre', p_unidades => v_unidades,
            p_usuario_id => v_usuario, p_icono => r ->> 'icono',
            p_orden => round(NULLIF(r ->> 'orden', '')::NUMERIC)::INTEGER,
            p_activa => COALESCE((r ->> 'activa')::BOOLEAN, TRUE), p_categoria_id => v_int);
        v_mapa_cat := v_mapa_cat || jsonb_build_object(r ->> 'id', v_int);
    END LOOP;

    /* ---- 2. Productos ---- */
    FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_cambios -> 'productos', '[]')) LOOP
        v_int := core.fn_id_de_app(r ->> 'id', 'p');
        v_unidades := ARRAY(SELECT x::INTEGER FROM jsonb_array_elements_text(COALESCE(r -> 'sucursales', '[]')) x);
        CALL api.sp_guardar_producto(
            p_empresa_id   => v_empresa,
            p_categoria_id => COALESCE((v_mapa_cat ->> (r ->> 'cat'))::INTEGER, core.fn_id_de_app(r ->> 'cat', 'c')::INTEGER),
            p_codigo       => r ->> 'codigo',
            p_nombre       => r ->> 'nombre',
            p_precio       => NULLIF(r ->> 'precio', '')::NUMERIC,
            p_unidades     => v_unidades,
            p_usuario_id   => v_usuario,
            p_descripcion  => r ->> 'desc',
            p_etiqueta     => r ->> 'tag',
            p_activo       => COALESCE((r ->> 'activo')::BOOLEAN, TRUE),
            p_orden        => round(NULLIF(r ->> 'orden', '')::NUMERIC)::INTEGER,
            p_imagen_url   => r ->> 'imagen',
            p_producto_id  => v_int);

        -- En la aplicación "agotado" es del producto: se aplica en sus unidades
        UPDATE core.producto_unidades
           SET agotado = COALESCE((r ->> 'agotado')::BOOLEAN, FALSE)
         WHERE producto_id = v_int
           AND agotado IS DISTINCT FROM COALESCE((r ->> 'agotado')::BOOLEAN, FALSE)
           AND core.fn_usuario_en_unidad(v_usuario, unidad_id);
    END LOOP;

    /* ---- 3. Borrados de la carta (productos antes que categorías) ---- */
    FOR v_txt IN SELECT jsonb_array_elements_text(COALESCE(p_cambios -> 'productos_borrados', '[]')) LOOP
        v_int := core.fn_id_de_app(v_txt, 'p');
        CONTINUE WHEN v_int IS NULL;
        v_flag := NULL;
        CALL api.sp_borrar_producto(v_int, v_usuario, v_empresa, v_flag);
        IF v_flag THEN
            v_desactivados := v_desactivados || to_jsonb(v_txt);
        END IF;
    END LOOP;

    FOR v_txt IN SELECT jsonb_array_elements_text(COALESCE(p_cambios -> 'categorias_borradas', '[]')) LOOP
        v_int := core.fn_id_de_app(v_txt, 'c');
        CONTINUE WHEN v_int IS NULL;
        CALL api.sp_borrar_categoria(v_int, v_usuario, v_empresa);
    END LOOP;

    /* ---- 4. Menús (modalidad, datos del armado, textos, categorías y opciones) ---- */
    FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_cambios -> 'menus', '[]')) LOOP
        v_unidad := (r ->> 'sucursalId')::INTEGER;
        IF core.fn_empresa_de_unidad(v_unidad) IS DISTINCT FROM v_empresa THEN
            RAISE EXCEPTION 'La unidad % no es de esta empresa.', v_unidad USING ERRCODE = 'insufficient_privilege';
        END IF;

        -- Título y mensaje de la unidad para todos los días
        IF r ->> 'fecha' = '*' THEN
            CALL api.sp_guardar_texto_menu_unidad(v_unidad, r -> 'publico' ->> 'titulo', r -> 'publico' ->> 'mensaje', v_usuario);
            CONTINUE;
        END IF;

        v_fecha := (r ->> 'fecha')::DATE;
        v_menu  := core.fn_id_de_app(r ->> 'id', 'm');
        SELECT id INTO v_existente FROM core.menus_dia WHERE unidad_id = v_unidad AND fecha = v_fecha;

        /* Un menú nuevo en el navegador para un día que ya tiene menú en la
           base (lo guardó otra persona, o está fuera de las fechas cargadas):
           si se siguiera, se borrarían sus categorías. */
        IF v_menu IS NULL AND v_existente IS NOT NULL THEN
            RAISE EXCEPTION 'El % ya tiene un menú guardado. Recarga la página para verlo.', to_char(v_fecha, 'DD/MM/YYYY');
        END IF;
        IF v_menu IS NOT NULL AND v_menu IS DISTINCT FROM v_existente THEN
            RAISE EXCEPTION 'Ese menú ya no existe. Recarga la página.';
        END IF;

        a := COALESCE(r -> 'armado', '{}');
        CALL api.sp_guardar_menu_dia(
            p_unidad_id   => v_unidad,
            p_fecha       => v_fecha,
            p_tipo        => CASE WHEN r ->> 'tipo' IN ('armado', 'chef') THEN r ->> 'tipo' ELSE 'chef' END,
            p_usuario_id  => v_usuario,
            p_nombre      => NULLIF(trim(a ->> 'nombre'), ''),
            p_descripcion => NULLIF(trim(a ->> 'descripcion'), ''),
            p_precio      => NULLIF(NULLIF(a ->> 'precio', '')::NUMERIC, 0),
            p_disponible  => COALESCE((a ->> 'disponible')::BOOLEAN, TRUE),
            p_titulo      => r -> 'publico' ->> 'titulo',
            p_mensaje     => r -> 'publico' ->> 'mensaje',
            p_menu_id     => v_menu);

        -- Categorías que ya no están (los ids ajenos a este menú no cuentan)
        FOR v_big IN
            SELECT mc.id FROM core.menu_categorias mc
             WHERE mc.menu_dia_id = v_menu
               AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(a -> 'categorias', '[]')) x
                                WHERE core.fn_id_de_app(x ->> 'id', 'mc') = mc.id)
        LOOP
            CALL api.sp_borrar_menu_categoria(v_big, v_usuario);
        END LOOP;

        FOR c, k IN SELECT x.value, x.ordinality::INTEGER
                      FROM jsonb_array_elements(COALESCE(a -> 'categorias', '[]')) WITH ORDINALITY x
        LOOP
            SELECT mc.id INTO v_cat_menu FROM core.menu_categorias mc
             WHERE mc.id = core.fn_id_de_app(c ->> 'id', 'mc') AND mc.menu_dia_id = v_menu;
            IF NOT FOUND THEN
                v_cat_menu := NULL; -- nueva (o copiada de otro día)
            END IF;

            CALL api.sp_guardar_menu_categoria(
                p_menu_dia_id   => v_menu,
                p_nombre        => c ->> 'nombre',
                p_usuario_id    => v_usuario,
                p_max_seleccion => COALESCE(NULLIF(c ->> 'maxSeleccion', '')::NUMERIC::INTEGER, 1),
                p_obligatoria   => COALESCE((c ->> 'obligatoria')::BOOLEAN, TRUE),
                p_icono         => c ->> 'icono',
                p_activa        => COALESCE((c ->> 'activa')::BOOLEAN, TRUE),
                p_orden         => k,
                p_categoria_id  => v_cat_menu);

            FOR v_big IN
                SELECT mo.id FROM core.menu_opciones mo
                 WHERE mo.menu_categoria_id = v_cat_menu
                   AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(c -> 'opciones', '[]')) x
                                    WHERE core.fn_id_de_app(x ->> 'id', 'mo') = mo.id)
            LOOP
                CALL api.sp_borrar_menu_opcion(v_big, v_usuario);
            END LOOP;

            FOR o, k2 IN SELECT x.value, x.ordinality::INTEGER
                           FROM jsonb_array_elements(COALESCE(c -> 'opciones', '[]')) WITH ORDINALITY x
            LOOP
                SELECT mo.id INTO v_big FROM core.menu_opciones mo
                 WHERE mo.id = core.fn_id_de_app(o ->> 'id', 'mo') AND mo.menu_categoria_id = v_cat_menu;
                IF NOT FOUND THEN
                    v_big := NULL;
                END IF;
                CALL api.sp_guardar_menu_opcion(
                    p_menu_categoria_id => v_cat_menu,
                    p_nombre            => o ->> 'nombre',
                    p_usuario_id        => v_usuario,
                    p_activa            => COALESCE((o ->> 'activa')::BOOLEAN, TRUE),
                    p_orden             => k2,
                    p_opcion_id         => v_big);
            END LOOP;
        END LOOP;
    END LOOP;

    /* ---- 5. Platos del chef ---- */
    FOR v_txt IN SELECT jsonb_array_elements_text(COALESCE(p_cambios -> 'platos_borrados', '[]')) LOOP
        v_big := core.fn_id_de_app(v_txt, 'd');
        CONTINUE WHEN v_big IS NULL;
        IF NOT EXISTS (SELECT 1 FROM core.platos_dia p JOIN core.menus_dia m ON m.id = p.menu_dia_id
                        WHERE p.id = v_big AND core.fn_empresa_de_unidad(m.unidad_id) = v_empresa) THEN
            RAISE EXCEPTION 'Ese plato ya no existe. Recarga la página.';
        END IF;
        CALL api.sp_borrar_plato_dia(v_big, v_usuario);
    END LOOP;

    FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_cambios -> 'platos', '[]')) LOOP
        v_unidad := (r ->> 'sucursalId')::INTEGER;
        v_fecha  := (r ->> 'fecha')::DATE;
        IF core.fn_empresa_de_unidad(v_unidad) IS DISTINCT FROM v_empresa THEN
            RAISE EXCEPTION 'La unidad % no es de esta empresa.', v_unidad USING ERRCODE = 'insufficient_privilege';
        END IF;

        v_menu := NULL;
        SELECT id INTO v_menu FROM core.menus_dia WHERE unidad_id = v_unidad AND fecha = v_fecha;
        IF v_menu IS NULL THEN
            -- Primer plato del día: el menú se crea como menú del chef
            CALL api.sp_guardar_menu_dia(p_unidad_id => v_unidad, p_fecha => v_fecha, p_tipo => 'chef',
                                         p_usuario_id => v_usuario, p_menu_id => v_menu);
        END IF;

        SELECT p.id INTO v_big FROM core.platos_dia p
         WHERE p.id = core.fn_id_de_app(r ->> 'id', 'd') AND p.menu_dia_id = v_menu;
        IF NOT FOUND THEN
            IF core.fn_id_de_app(r ->> 'id', 'd') IS NOT NULL THEN
                RAISE EXCEPTION 'Ese plato ya no existe. Recarga la página.';
            END IF;
            v_big := NULL;
        END IF;

        CALL api.sp_guardar_plato_dia(
            p_menu_dia_id => v_menu,
            p_nombre      => r ->> 'nombre',
            p_precio      => NULLIF(r ->> 'precio', '')::NUMERIC,
            p_usuario_id  => v_usuario,
            p_descripcion => r ->> 'desc',
            p_emoji       => r ->> 'emoji',
            p_cupos       => NULLIF(NULLIF(r ->> 'cupos', '')::NUMERIC::INTEGER, 0),
            p_disponible  => COALESCE((r ->> 'disponible')::BOOLEAN, TRUE),
            p_orden       => round(NULLIF(r ->> 'orden', '')::NUMERIC)::INTEGER,
            p_sopa        => r ->> 'sopa',
            p_principio   => r ->> 'principio',
            p_proteina    => r ->> 'proteina',
            p_bebida      => r ->> 'bebida',
            p_plato_id    => v_big);
    END LOOP;

    RETURN jsonb_build_object('desactivados', v_desactivados);
END;
$$;


/* ============================================================================
   5. PERMISOS
   ============================================================================ */

REVOKE ALL ON FUNCTION core.fn_id_de_app(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION core.fn_exigir_unidades(INTEGER, INTEGER, INTEGER[]) FROM PUBLIC;

REVOKE ALL ON PROCEDURE api.sp_guardar_categoria(INTEGER, VARCHAR, INTEGER[], INTEGER, VARCHAR, INTEGER, BOOLEAN, INTEGER),
                        api.sp_borrar_categoria(INTEGER, INTEGER, INTEGER),
                        api.sp_guardar_producto(INTEGER, INTEGER, VARCHAR, VARCHAR, NUMERIC, INTEGER[], INTEGER, VARCHAR,
                                                VARCHAR, BOOLEAN, INTEGER, VARCHAR, INTEGER),
                        api.sp_borrar_producto(INTEGER, INTEGER, INTEGER, BOOLEAN),
                        api.sp_guardar_menu_categoria(BIGINT, VARCHAR, INTEGER, INTEGER, BOOLEAN, VARCHAR, BOOLEAN, INTEGER, BIGINT),
                        api.sp_guardar_menu_opcion(BIGINT, VARCHAR, INTEGER, BOOLEAN, INTEGER, BIGINT),
                        api.sp_guardar_plato_dia(BIGINT, VARCHAR, NUMERIC, INTEGER, VARCHAR, VARCHAR, INTEGER, BOOLEAN, INTEGER,
                                                 VARCHAR, VARCHAR, VARCHAR, VARCHAR, BIGINT),
                        api.sp_borrar_plato_dia(BIGINT, INTEGER),
                        api.sp_borrar_menu_opcion(BIGINT, INTEGER),
                        api.sp_borrar_menu_categoria(BIGINT, INTEGER)
       FROM PUBLIC;

GRANT EXECUTE ON PROCEDURE api.sp_guardar_categoria(INTEGER, VARCHAR, INTEGER[], INTEGER, VARCHAR, INTEGER, BOOLEAN, INTEGER),
                           api.sp_borrar_categoria(INTEGER, INTEGER, INTEGER),
                           api.sp_guardar_producto(INTEGER, INTEGER, VARCHAR, VARCHAR, NUMERIC, INTEGER[], INTEGER, VARCHAR,
                                                   VARCHAR, BOOLEAN, INTEGER, VARCHAR, INTEGER),
                           api.sp_borrar_producto(INTEGER, INTEGER, INTEGER, BOOLEAN),
                           api.sp_guardar_menu_categoria(BIGINT, VARCHAR, INTEGER, INTEGER, BOOLEAN, VARCHAR, BOOLEAN, INTEGER, BIGINT),
                           api.sp_guardar_menu_opcion(BIGINT, VARCHAR, INTEGER, BOOLEAN, INTEGER, BIGINT),
                           api.sp_guardar_plato_dia(BIGINT, VARCHAR, NUMERIC, INTEGER, VARCHAR, VARCHAR, INTEGER, BOOLEAN, INTEGER,
                                                 VARCHAR, VARCHAR, VARCHAR, VARCHAR, BIGINT),
                           api.sp_borrar_plato_dia(BIGINT, INTEGER),
                           api.sp_borrar_menu_opcion(BIGINT, INTEGER),
                           api.sp_borrar_menu_categoria(BIGINT, INTEGER)
      TO taseca_app;

-- Las funciones nuevas de rest nacen ejecutables por PUBLIC: se cierra
REVOKE ALL ON FUNCTION rest.sincronizar_catalogo(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rest.sincronizar_catalogo(JSONB) TO taseca_app;

-- PostgREST vuelve a leer el esquema sin reiniciarlo
NOTIFY pgrst, 'reload schema';


/* ============================================================================
   12_FASE2_USUARIOS_UNIDADES
   Fase 2 · usuarios y unidades
   ============================================================================ */

/* ============================================================================
   TASECA · 12 · FASE 2 · BLOQUE 2: USUARIOS Y UNIDADES / LOCALES
   ----------------------------------------------------------------------------
   Ejecutar conectado a taseca_db, después de 01 … 11. Se puede volver a
   ejecutar: todo es idempotente.

   QUÉ AGREGA
     · Usuarios: validaciones completas en la base (acceso único, PIN de 4 a
       6 dígitos, nadie se desactiva ni se cambia el rol a sí mismo y la
       empresa nunca se queda sin un Admin activo).
     · Unidades: color propio, logo, zonas de domicilio y mesas desde la
       aplicación. El logo vive en su propia tabla y se descarga aparte, sólo
       cuando cambia: no viaja en cada refresco del catálogo.
     · rest.usuarios (sólo para quien administra usuarios), rest.logos_unidad,
       rest.guardar_usuario y rest.guardar_unidad.

   CORRIGE
     · api.sp_cambiar_estado_unidad y api.sp_guardar_unidad no comprobaban que
       la unidad fuera de la empresa del usuario.

   SEGURIDAD
     El usuario y la empresa salen SIEMPRE del token. El PIN nunca se guarda en
     claro (bcrypt) ni sale de la base: rest.usuarios no lo publica.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. MODELO
   ============================================================================ */

-- Color propio de la unidad (#RRGGBB). `color` sigue siendo el acento del portal.
ALTER TABLE core.unidades ADD COLUMN IF NOT EXISTS color_marca VARCHAR(7);
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_unidades_color_marca') THEN
        ALTER TABLE core.unidades
            ADD CONSTRAINT ck_unidades_color_marca CHECK (color_marca IS NULL OR color_marca ~ '^#[0-9a-f]{6}$');
    END IF;
END;
$$;

/* Logo de la unidad (1 a 1). Separado de core.unidades para que la fila de la
   unidad siga siendo liviana y el logo sólo viaje cuando cambia. Al pasar a
   Supabase, `imagen` se reemplaza por la ruta en Storage. */
CREATE TABLE IF NOT EXISTS core.unidad_logos (
    id              SERIAL PRIMARY KEY,
    unidad_id       INTEGER     NOT NULL UNIQUE REFERENCES core.unidades (id) ON DELETE CASCADE,
    imagen          TEXT        NOT NULL,
    actualizado_en  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_unidad_logos_imagen CHECK (imagen LIKE 'data:image/%' AND length(imagen) <= 200000)
);
COMMENT ON TABLE core.unidad_logos IS 'Logo propio de la unidad (data URL de hasta ~150 KB). Sin fila = identidad de la empresa.';

REVOKE ALL ON core.unidad_logos FROM PUBLIC;


/* ============================================================================
   2. USUARIOS
   ============================================================================ */

/* Misma firma que en 04; ahora valida todo lo que antes sólo validaba la
   pantalla. p_unidades: NULL = no cambiar · '{}' = todas las unidades. */
CREATE OR REPLACE PROCEDURE api.sp_guardar_usuario(
    p_empresa_id      INTEGER,
    p_rol             VARCHAR,
    p_nombre          VARCHAR,
    p_usuario         VARCHAR,
    p_admin_id        INTEGER,
    p_pin             VARCHAR   DEFAULT NULL,
    p_unidades        INTEGER[] DEFAULT NULL,
    p_activo          BOOLEAN   DEFAULT TRUE,
    INOUT p_usuario_id INTEGER  DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_rol      core.roles;
    v_nombre   VARCHAR := regexp_replace(trim(COALESCE(p_nombre, '')), '\s+', ' ', 'g');
    v_acceso   VARCHAR := lower(trim(COALESCE(p_usuario, '')));
    v_pin      VARCHAR := NULLIF(trim(COALESCE(p_pin, '')), '');
    v_actual   core.usuarios;
    v_rol_act  VARCHAR;
    v_u        INTEGER;
BEGIN
    SELECT * INTO v_rol FROM core.roles WHERE codigo = p_rol;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El rol "%" no existe.', p_rol;
    END IF;

    PERFORM core.fn_preparar_operacion(p_admin_id, CASE WHEN v_rol.alcance = 'plataforma' THEN 'plataforma' ELSE 'usuarios' END);

    -- El admin de una empresa sólo administra usuarios de SU empresa
    IF p_admin_id IS NOT NULL AND NOT core.fn_tiene_permiso(p_admin_id, 'plataforma')
       AND p_empresa_id IS DISTINCT FROM (SELECT empresa_id FROM core.usuarios WHERE id = p_admin_id) THEN
        RAISE EXCEPTION 'No puedes administrar usuarios de otra empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'El usuario necesita un nombre.';
    END IF;
    IF v_acceso !~ '^[a-z0-9._-]{3,40}$' THEN
        RAISE EXCEPTION 'El acceso debe tener entre 3 y 40 caracteres: letras sin tildes, números, punto, guion o guion bajo.';
    END IF;
    IF v_pin IS NOT NULL AND v_pin !~ '^[0-9]{4,6}$' THEN
        RAISE EXCEPTION 'El PIN debe tener entre 4 y 6 dígitos.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.usuarios WHERE lower(usuario) = v_acceso AND id IS DISTINCT FROM p_usuario_id) THEN
        RAISE EXCEPTION 'Ya existe otro usuario con el acceso "%" (puede ser de otra empresa).', v_acceso;
    END IF;

    IF p_unidades IS NOT NULL THEN
        FOREACH v_u IN ARRAY p_unidades LOOP
            IF core.fn_empresa_de_unidad(v_u) IS DISTINCT FROM p_empresa_id THEN
                RAISE EXCEPTION 'La unidad % no es de esta empresa.', v_u USING ERRCODE = 'insufficient_privilege';
            END IF;
        END LOOP;
    END IF;

    IF p_usuario_id IS NULL THEN
        IF v_pin IS NULL THEN
            RAISE EXCEPTION 'Un usuario nuevo necesita PIN.';
        END IF;
        INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash, activo)
        VALUES (CASE WHEN v_rol.alcance = 'plataforma' THEN NULL ELSE p_empresa_id END,
                v_rol.id, v_nombre, v_acceso, core.fn_hash_pin(v_pin), COALESCE(p_activo, TRUE))
        RETURNING id INTO p_usuario_id;
    ELSE
        SELECT * INTO v_actual FROM core.usuarios
         WHERE id = p_usuario_id
           AND (empresa_id = p_empresa_id OR (empresa_id IS NULL AND v_rol.alcance = 'plataforma'));
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Ese usuario no existe en esta empresa.';
        END IF;
        SELECT codigo INTO v_rol_act FROM core.roles WHERE id = v_actual.rol_id;

        -- Nadie se deja por fuera a sí mismo
        IF p_usuario_id = p_admin_id THEN
            IF NOT COALESCE(p_activo, TRUE) THEN
                RAISE EXCEPTION 'No puedes desactivar tu propio usuario.';
            END IF;
            IF v_rol.id <> v_actual.rol_id THEN
                RAISE EXCEPTION 'No puedes cambiar tu propio rol.';
            END IF;
        END IF;

        -- La empresa nunca se queda sin un Admin activo
        IF v_rol_act = 'admin' AND v_actual.activo AND (p_rol <> 'admin' OR NOT COALESCE(p_activo, TRUE))
           AND NOT EXISTS (SELECT 1 FROM core.usuarios x JOIN core.roles r ON r.id = x.rol_id
                            WHERE x.empresa_id = v_actual.empresa_id AND r.codigo = 'admin'
                              AND x.activo AND x.id <> p_usuario_id) THEN
            RAISE EXCEPTION 'Debe quedar al menos un Admin activo en la empresa.';
        END IF;

        UPDATE core.usuarios
           SET rol_id   = v_rol.id,
               nombre   = v_nombre,
               usuario  = v_acceso,
               activo   = COALESCE(p_activo, activo),
               pin_hash = CASE WHEN v_pin IS NULL THEN pin_hash ELSE core.fn_hash_pin(v_pin) END
         WHERE id = p_usuario_id;
    END IF;

    IF p_unidades IS NOT NULL THEN
        DELETE FROM core.usuario_unidades WHERE usuario_id = p_usuario_id AND unidad_id <> ALL (p_unidades);
        INSERT INTO core.usuario_unidades (usuario_id, unidad_id)
        SELECT p_usuario_id, x FROM unnest(p_unidades) x
        ON CONFLICT (usuario_id, unidad_id) DO NOTHING;
    END IF;
END;
$$;


/* ============================================================================
   3. UNIDADES / LOCALES
   ============================================================================ */

/* ¿Puede este usuario administrar las unidades de esta empresa? */
CREATE OR REPLACE FUNCTION core.fn_exigir_empresa_propia(p_usuario_id INTEGER, p_empresa_id INTEGER)
RETURNS VOID
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    IF p_usuario_id IS NOT NULL AND NOT core.fn_tiene_permiso(p_usuario_id, 'plataforma')
       AND p_empresa_id IS DISTINCT FROM (SELECT empresa_id FROM core.usuarios WHERE id = p_usuario_id) THEN
        RAISE EXCEPTION 'No puedes administrar otra empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$$;

/* Se reemplaza la versión de 04: color acento y color propio, nombre corto
   que no se pierde al editar, mensajes claros y control de empresa. */
DROP PROCEDURE IF EXISTS api.sp_guardar_unidad(INTEGER, VARCHAR, VARCHAR, INTEGER, VARCHAR, VARCHAR, VARCHAR, VARCHAR,
                                               VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER);

CREATE OR REPLACE PROCEDURE api.sp_guardar_unidad(
    p_empresa_id     INTEGER,
    p_nombre         VARCHAR,
    p_tipo_negocio   VARCHAR,
    p_usuario_id     INTEGER,
    p_nombre_corto   VARCHAR DEFAULT NULL,
    p_direccion      VARCHAR DEFAULT NULL,
    p_ciudad         VARCHAR DEFAULT NULL,
    p_telefono       VARCHAR DEFAULT NULL,
    p_whatsapp       VARCHAR DEFAULT NULL,
    p_horario        VARCHAR DEFAULT NULL,
    p_mapa_url       VARCHAR DEFAULT NULL,
    p_mesas          INTEGER DEFAULT NULL,
    p_color          VARCHAR DEFAULT NULL,
    p_color_marca    VARCHAR DEFAULT NULL,
    INOUT p_unidad_id INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre VARCHAR := regexp_replace(trim(COALESCE(p_nombre, '')), '\s+', ' ', 'g');
    v_corto  VARCHAR := NULLIF(regexp_replace(trim(COALESCE(p_nombre_corto, '')), '\s+', ' ', 'g'), '');
    v_marca  VARCHAR := NULLIF(lower(trim(COALESCE(p_color_marca, ''))), '');
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'config_sucursales');
    PERFORM core.fn_exigir_empresa_propia(p_usuario_id, p_empresa_id);

    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'La unidad necesita un nombre.';
    END IF;
    IF v_marca IS NOT NULL AND v_marca !~ '^#[0-9a-f]{6}$' THEN
        RAISE EXCEPTION 'El color propio debe tener el formato #RRGGBB.';
    END IF;
    IF p_mesas IS NOT NULL AND (p_mesas < 0 OR p_mesas > 200) THEN
        RAISE EXCEPTION 'El número de mesas debe estar entre 0 y 200.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.unidades WHERE empresa_id = p_empresa_id AND lower(nombre) = lower(v_nombre)
                                             AND id IS DISTINCT FROM p_unidad_id) THEN
        RAISE EXCEPTION 'Ya hay otra unidad llamada "%".', v_nombre;
    END IF;

    -- Sin nombre corto: el que ya tenía, o el nombre recortado
    v_corto := COALESCE(v_corto, (SELECT nombre_corto FROM core.unidades WHERE id = p_unidad_id), left(v_nombre, 40));
    IF EXISTS (SELECT 1 FROM core.unidades WHERE empresa_id = p_empresa_id AND lower(nombre_corto) = lower(v_corto)
                                             AND id IS DISTINCT FROM p_unidad_id) THEN
        RAISE EXCEPTION 'Ya hay otra unidad con el nombre corto "%".', v_corto;
    END IF;

    IF p_unidad_id IS NULL THEN
        INSERT INTO core.unidades (empresa_id, tipo_negocio_id, nombre, nombre_corto, direccion, ciudad,
                                   telefono, whatsapp, horario, mapa_url, color, color_marca)
        VALUES (p_empresa_id, core.fn_id_catalogo('tipos_negocio', p_tipo_negocio), v_nombre, v_corto,
                NULLIF(trim(p_direccion), ''), NULLIF(trim(p_ciudad), ''), NULLIF(trim(p_telefono), ''),
                NULLIF(trim(p_whatsapp), ''), NULLIF(trim(p_horario), ''), NULLIF(trim(p_mapa_url), ''),
                COALESCE(NULLIF(trim(p_color), ''), 'azul'), v_marca)
        RETURNING id INTO p_unidad_id;
    ELSE
        UPDATE core.unidades
           SET tipo_negocio_id = core.fn_id_catalogo('tipos_negocio', p_tipo_negocio),
               nombre = v_nombre, nombre_corto = v_corto,
               direccion = NULLIF(trim(p_direccion), ''), ciudad = NULLIF(trim(p_ciudad), ''),
               telefono = NULLIF(trim(p_telefono), ''), whatsapp = NULLIF(trim(p_whatsapp), ''),
               horario = NULLIF(trim(p_horario), ''), mapa_url = NULLIF(trim(p_mapa_url), ''),
               color = COALESCE(NULLIF(trim(p_color), ''), color), color_marca = v_marca
         WHERE id = p_unidad_id AND empresa_id = p_empresa_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Esa unidad no existe en esta empresa. Recarga la página.';
        END IF;
    END IF;

    -- Mesas numeradas 1..N (las que sobran se desactivan: pueden tener pedidos)
    IF p_mesas IS NOT NULL THEN
        INSERT INTO core.mesas (unidad_id, numero)
        SELECT p_unidad_id, g::TEXT FROM generate_series(1, p_mesas) g
        ON CONFLICT (unidad_id, numero) DO UPDATE SET activa = TRUE;
        UPDATE core.mesas SET activa = FALSE
         WHERE unidad_id = p_unidad_id AND activa AND numero ~ '^[0-9]+$' AND numero::INTEGER > p_mesas;
    END IF;
END;
$$;

/* Misma firma que en 04; ahora exige que la unidad sea de la empresa del usuario. */
CREATE OR REPLACE PROCEDURE api.sp_cambiar_estado_unidad(p_unidad_id INTEGER, p_activa BOOLEAN, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_empresa INTEGER := core.fn_empresa_de_unidad(p_unidad_id);
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'config_sucursales');
    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'La unidad % no existe.', p_unidad_id;
    END IF;
    PERFORM core.fn_exigir_empresa_propia(p_usuario_id, v_empresa);

    UPDATE core.unidades SET estado = CASE WHEN p_activa THEN 'activa' ELSE 'inactiva' END
     WHERE id = p_unidad_id
       AND estado IS DISTINCT FROM CASE WHEN p_activa THEN 'activa' ELSE 'inactiva' END;
END;
$$;

/* Zona de domicilio. Si existe una con ese nombre (activa o no) se actualiza
   y queda activa. */
CREATE OR REPLACE PROCEDURE api.sp_guardar_zona(
    p_unidad_id      INTEGER,
    p_nombre         VARCHAR,
    p_costo          NUMERIC,
    p_pedido_minimo  NUMERIC,
    p_usuario_id     INTEGER,
    INOUT p_zona_id  INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre VARCHAR := regexp_replace(trim(COALESCE(p_nombre, '')), '\s+', ' ', 'g');
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'config_sucursales');
    PERFORM core.fn_exigir_empresa_propia(p_usuario_id, core.fn_empresa_de_unidad(p_unidad_id));

    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'Cada zona necesita un nombre.';
    END IF;
    IF COALESCE(p_costo, 0) < 0 OR COALESCE(p_pedido_minimo, 0) < 0 THEN
        RAISE EXCEPTION 'El costo y el pedido mínimo de "%" no pueden ser negativos.', v_nombre;
    END IF;

    INSERT INTO core.zonas_domicilio (unidad_id, nombre, costo, pedido_minimo, activa)
    VALUES (p_unidad_id, v_nombre, COALESCE(p_costo, 0), COALESCE(p_pedido_minimo, 0), TRUE)
    ON CONFLICT (unidad_id, nombre) DO UPDATE
       SET costo = EXCLUDED.costo, pedido_minimo = EXCLUDED.pedido_minimo, activa = TRUE
    RETURNING id INTO p_zona_id;
END;
$$;

/* Quita una zona: se borra si ningún pedido la usó; si no, se desactiva. */
CREATE OR REPLACE PROCEDURE api.sp_retirar_zona(p_zona_id INTEGER, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_unidad INTEGER := (SELECT unidad_id FROM core.zonas_domicilio WHERE id = p_zona_id);
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'config_sucursales');
    IF v_unidad IS NULL THEN
        RETURN;
    END IF;
    PERFORM core.fn_exigir_empresa_propia(p_usuario_id, core.fn_empresa_de_unidad(v_unidad));

    IF EXISTS (SELECT 1 FROM core.pedidos WHERE zona_domicilio_id = p_zona_id) THEN
        UPDATE core.zonas_domicilio SET activa = FALSE WHERE id = p_zona_id;
    ELSE
        DELETE FROM core.zonas_domicilio WHERE id = p_zona_id;
    END IF;
END;
$$;

/* Logo: NULL o vacío lo quita. */
CREATE OR REPLACE PROCEDURE api.sp_guardar_logo_unidad(p_unidad_id INTEGER, p_imagen TEXT, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'config_sucursales');
    PERFORM core.fn_exigir_empresa_propia(p_usuario_id, core.fn_empresa_de_unidad(p_unidad_id));

    IF NULLIF(p_imagen, '') IS NULL THEN
        DELETE FROM core.unidad_logos WHERE unidad_id = p_unidad_id;
        RETURN;
    END IF;
    IF p_imagen NOT LIKE 'data:image/%' THEN
        RAISE EXCEPTION 'El logo debe ser una imagen.';
    END IF;
    IF length(p_imagen) > 200000 THEN
        RAISE EXCEPTION 'El logo es demasiado pesado (máximo unos 150 KB). Usa una imagen más pequeña.';
    END IF;

    INSERT INTO core.unidad_logos (unidad_id, imagen)
    VALUES (p_unidad_id, p_imagen)
    ON CONFLICT (unidad_id) DO UPDATE SET imagen = EXCLUDED.imagen, actualizado_en = now();
END;
$$;


/* ============================================================================
   4. API REST · LECTURA
   ============================================================================ */

/* Unidades: se agregan al final el color propio y la versión del logo (la
   imagen NO va aquí; ver rest.logos_unidad). */
CREATE OR REPLACE VIEW rest.unidades AS
SELECT u.unidad_id, u.empresa_id, e.codigo AS empresa_codigo, u.nombre, u.nombre_corto, u.estado, u.activa,
       u.tipo_negocio, u.direccion, u.ciudad, u.telefono, u.whatsapp, u.horario, u.mapa_url, u.color,
       u.logo_url, u.mesas, u.creado_en,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('zona_id', z.id, 'nombre', z.nombre, 'costo', z.costo,
                                                     'pedido_minimo', z.pedido_minimo) ORDER BY z.nombre)
                   FROM core.zonas_domicilio z WHERE z.unidad_id = u.unidad_id AND z.activa), '[]') AS zonas,
       cu.color_marca,
       (SELECT l.actualizado_en FROM core.unidad_logos l WHERE l.unidad_id = u.unidad_id) AS logo_version
  FROM api.v_unidades u
  JOIN core.empresas e  ON e.id = u.empresa_id
  JOIN core.unidades cu ON cu.id = u.unidad_id;

/* Los logos, aparte: la aplicación los pide sólo cuando logo_version cambia. */
CREATE OR REPLACE VIEW rest.logos_unidad AS
SELECT l.unidad_id, u.empresa_id, l.imagen, l.actualizado_en AS logo_version
  FROM core.unidad_logos l
  JOIN core.unidades u ON u.id = l.unidad_id;

/* Usuarios de la empresa del token, sólo para quien puede administrarlos.
   Nunca el PIN. */
CREATE OR REPLACE VIEW rest.usuarios AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_usuario() AS usuario_id, core.fn_jwt_empresa() AS empresa_id
)
SELECT u.usuario_id, u.empresa_id, u.nombre, u.usuario, u.rol, u.activo,
       u.unidades_asignadas AS unidades, u.ultimo_acceso, u.creado_en
  FROM api.v_usuarios u
  JOIN sesion s ON s.empresa_id = u.empresa_id
 WHERE u.alcance = 'empresa'
   AND api.fn_tiene_permiso(s.usuario_id, 'usuarios');


/* ============================================================================
   5. API REST · ESCRITURA
   ============================================================================ */

/* POST /rpc/guardar_usuario  { "p_usuario": { usuario_id|null, nombre, usuario,
   pin (opcional: vacío = no cambia), rol, unidades: [..] | null, activo } } */
CREATE OR REPLACE FUNCTION rest.guardar_usuario(p_usuario JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_admin    INTEGER := core.fn_exigir_sesion();
    v_empresa  INTEGER := core.fn_jwt_empresa();
    v_id       INTEGER := NULLIF(p_usuario ->> 'usuario_id', '')::INTEGER;
    v_unidades INTEGER[];
BEGIN
    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'Tu sesión no pertenece a una empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF jsonb_typeof(p_usuario -> 'unidades') = 'array' THEN
        v_unidades := ARRAY(SELECT x::INTEGER FROM jsonb_array_elements_text(p_usuario -> 'unidades') x);
    END IF;

    CALL api.sp_guardar_usuario(
        p_empresa_id => v_empresa,
        p_rol        => p_usuario ->> 'rol',
        p_nombre     => p_usuario ->> 'nombre',
        p_usuario    => p_usuario ->> 'usuario',
        p_admin_id   => v_admin,
        p_pin        => p_usuario ->> 'pin',
        p_unidades   => v_unidades,
        p_activo     => COALESCE((p_usuario ->> 'activo')::BOOLEAN, TRUE),
        p_usuario_id => v_id);

    RETURN jsonb_build_object('usuario_id', v_id);
END;
$$;

/* POST /rpc/guardar_unidad  { "p_unidad": { unidad_id|null, nombre, corto,
   tipoNegocio, activa, direccion, ciudad, telefono, whatsapp, horario, mapa,
   mesas, color, colorMarca, zonas: [{ nombre, costo, min }],
   logo (sólo si cambió: data URL, o "" para quitarlo) } } */
CREATE OR REPLACE FUNCTION rest.guardar_unidad(p_unidad JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario  INTEGER := core.fn_exigir_sesion();
    v_empresa  INTEGER := core.fn_jwt_empresa();
    v_id       INTEGER := NULLIF(p_unidad ->> 'unidad_id', '')::INTEGER;
    v_zona     INTEGER;
    z          JSONB;
BEGIN
    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'Tu sesión no pertenece a una empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;

    CALL api.sp_guardar_unidad(
        p_empresa_id   => v_empresa,
        p_nombre       => p_unidad ->> 'nombre',
        p_tipo_negocio => COALESCE(NULLIF(p_unidad ->> 'tipoNegocio', ''), 'restaurante'),
        p_usuario_id   => v_usuario,
        p_nombre_corto => p_unidad ->> 'corto',
        p_direccion    => p_unidad ->> 'direccion',
        p_ciudad       => p_unidad ->> 'ciudad',
        p_telefono     => p_unidad ->> 'telefono',
        p_whatsapp     => regexp_replace(COALESCE(p_unidad ->> 'whatsapp', ''), '\D', '', 'g'),
        p_horario      => p_unidad ->> 'horario',
        p_mapa_url     => p_unidad ->> 'mapa',
        p_mesas        => NULLIF(p_unidad ->> 'mesas', '')::NUMERIC::INTEGER,
        p_color        => p_unidad ->> 'color',
        p_color_marca  => p_unidad ->> 'colorMarca',
        p_unidad_id    => v_id);

    IF p_unidad ? 'activa' THEN
        CALL api.sp_cambiar_estado_unidad(v_id, COALESCE((p_unidad ->> 'activa')::BOOLEAN, TRUE), v_usuario);
    END IF;

    -- Zonas: las que no vienen se retiran; las que vienen se guardan por nombre
    IF jsonb_typeof(p_unidad -> 'zonas') = 'array' THEN
        FOR v_zona IN
            SELECT zd.id FROM core.zonas_domicilio zd
             WHERE zd.unidad_id = v_id AND zd.activa
               AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_unidad -> 'zonas') x
                                WHERE lower(regexp_replace(trim(x ->> 'nombre'), '\s+', ' ', 'g')) = lower(zd.nombre))
        LOOP
            CALL api.sp_retirar_zona(v_zona, v_usuario);
        END LOOP;

        FOR z IN SELECT * FROM jsonb_array_elements(p_unidad -> 'zonas') LOOP
            v_zona := NULL;
            CALL api.sp_guardar_zona(v_id, z ->> 'nombre', NULLIF(z ->> 'costo', '')::NUMERIC,
                                     NULLIF(z ->> 'min', '')::NUMERIC, v_usuario, v_zona);
        END LOOP;
    END IF;

    IF p_unidad ? 'logo' THEN
        CALL api.sp_guardar_logo_unidad(v_id, p_unidad ->> 'logo', v_usuario);
    END IF;

    RETURN jsonb_build_object('unidad_id', v_id);
END;
$$;


/* ============================================================================
   6. PERMISOS
   ============================================================================ */

REVOKE ALL ON FUNCTION core.fn_exigir_empresa_propia(INTEGER, INTEGER) FROM PUBLIC;

REVOKE ALL ON PROCEDURE api.sp_guardar_usuario(INTEGER, VARCHAR, VARCHAR, VARCHAR, INTEGER, VARCHAR, INTEGER[], BOOLEAN, INTEGER),
                        api.sp_guardar_unidad(INTEGER, VARCHAR, VARCHAR, INTEGER, VARCHAR, VARCHAR, VARCHAR, VARCHAR,
                                              VARCHAR, VARCHAR, VARCHAR, INTEGER, VARCHAR, VARCHAR, INTEGER),
                        api.sp_cambiar_estado_unidad(INTEGER, BOOLEAN, INTEGER),
                        api.sp_guardar_zona(INTEGER, VARCHAR, NUMERIC, NUMERIC, INTEGER, INTEGER),
                        api.sp_retirar_zona(INTEGER, INTEGER),
                        api.sp_guardar_logo_unidad(INTEGER, TEXT, INTEGER)
       FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE api.sp_guardar_usuario(INTEGER, VARCHAR, VARCHAR, VARCHAR, INTEGER, VARCHAR, INTEGER[], BOOLEAN, INTEGER),
                           api.sp_guardar_unidad(INTEGER, VARCHAR, VARCHAR, INTEGER, VARCHAR, VARCHAR, VARCHAR, VARCHAR,
                                                 VARCHAR, VARCHAR, VARCHAR, INTEGER, VARCHAR, VARCHAR, INTEGER),
                           api.sp_cambiar_estado_unidad(INTEGER, BOOLEAN, INTEGER),
                           api.sp_guardar_zona(INTEGER, VARCHAR, NUMERIC, NUMERIC, INTEGER, INTEGER),
                           api.sp_retirar_zona(INTEGER, INTEGER),
                           api.sp_guardar_logo_unidad(INTEGER, TEXT, INTEGER)
      TO taseca_app;

GRANT SELECT ON rest.unidades, rest.logos_unidad TO taseca_anon, taseca_app;
GRANT SELECT ON rest.usuarios TO taseca_app;
GRANT EXECUTE ON FUNCTION api.fn_tiene_permiso(INTEGER, VARCHAR) TO taseca_app;

REVOKE ALL ON FUNCTION rest.guardar_usuario(JSONB), rest.guardar_unidad(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rest.guardar_usuario(JSONB), rest.guardar_unidad(JSONB) TO taseca_app;

NOTIFY pgrst, 'reload schema';


/* ============================================================================
   13_FASE2_INVENTARIO
   Fase 2 · stock, entradas y cierres
   ============================================================================ */

/* ============================================================================
   TASECA · 13 · FASE 2 · BLOQUE 3: STOCK, ENTRADAS Y CIERRES DE INVENTARIO
   ----------------------------------------------------------------------------
   Ejecutar conectado a taseca_db, después de 01 … 12. Se puede volver a
   ejecutar: todo es idempotente.

   QUÉ AGREGA
     · Stock: crear y editar productos de inventario (código, categoría,
       área, unidad de conteo, mínimo, qué producto de la carta lo descuenta)
       y ajustar el stock actual a mano.
     · Entradas: se pueden ELIMINAR o CORREGIR mientras el cierre de esa
       jornada no esté revisado. No se borran: quedan ANULADAS con quién,
       cuándo y por qué, y dejan de contar. Corregir = anular + registrar la
       correcta, en una transacción.
     · Cierres: borrador, corrección (el conteo nuevo reemplaza al anterior),
       revisión y aplicar los saldos al stock.
     · rest.cruce_inventario: el cruce IN · EN · Z · SD de TODO el catálogo
       del área, calculado en la base.

   CORRIGE
     · Anular una factura cuya jornada YA tenía cierre cambiaba el cruce de ese
       día (la venta dejaba de contar) y además devolvía la mercancía como
       entrada del día siguiente. Ahora el día cerrado no cambia: esa venta
       sigue contando allí y la mercancía vuelve sólo por la entrada.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. ENTRADAS ANULABLES
   ============================================================================ */

ALTER TABLE core.entradas_inventario ADD COLUMN IF NOT EXISTS anulada_en       TIMESTAMPTZ;
ALTER TABLE core.entradas_inventario ADD COLUMN IF NOT EXISTS anulada_por_id   INTEGER REFERENCES core.usuarios (id) ON DELETE RESTRICT;
ALTER TABLE core.entradas_inventario ADD COLUMN IF NOT EXISTS motivo_anulacion VARCHAR(300);
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_entradas_anulacion') THEN
        ALTER TABLE core.entradas_inventario
            ADD CONSTRAINT ck_entradas_anulacion
            CHECK (anulada_en IS NULL OR length(trim(COALESCE(motivo_anulacion, ''))) >= 3);
    END IF;
END;
$$;
COMMENT ON COLUMN core.entradas_inventario.anulada_en IS 'Entrada eliminada o corregida: no se borra, deja de contar en stock y cruce.';

/* Una entrada sigue sin editarse. Lo único permitido es anularla UNA vez. */
CREATE OR REPLACE FUNCTION core.tg_entradas_inmutable()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF current_setting('taseca.borrado_pruebas', TRUE) = 'si' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    IF TG_OP = 'UPDATE'
       AND OLD.anulada_en IS NULL AND NEW.anulada_en IS NOT NULL
       AND (NEW.insumo_unidad_id, NEW.tipo_entrada_id, NEW.fecha_operativa, NEW.cantidad, NEW.pedido_id, NEW.usuario_id, NEW.creado_en)
           IS NOT DISTINCT FROM
           (OLD.insumo_unidad_id, OLD.tipo_entrada_id, OLD.fecha_operativa, OLD.cantidad, OLD.pedido_id, OLD.usuario_id, OLD.creado_en)
       AND NEW.observacion IS NOT DISTINCT FROM OLD.observacion THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'Los registros de entradas_inventario no se modifican ni se borran: se anulan y se registra la correcta.';
END;
$$;

DROP TRIGGER IF EXISTS trg_entradas_inmutable ON core.entradas_inventario;
CREATE TRIGGER trg_entradas_inmutable
    BEFORE UPDATE OR DELETE ON core.entradas_inventario
    FOR EACH ROW EXECUTE FUNCTION core.tg_entradas_inmutable();

/* Al anular, lo que había sumado sale del stock (sin bajar de cero). */
CREATE OR REPLACE FUNCTION core.tg_entradas_anular_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.insumo_unidades
       SET stock_actual = GREATEST(stock_actual - OLD.cantidad, 0), actualizado_en = now()
     WHERE id = OLD.insumo_unidad_id;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_entradas_anular_stock ON core.entradas_inventario;
CREATE TRIGGER trg_entradas_anular_stock
    AFTER UPDATE OF anulada_en ON core.entradas_inventario
    FOR EACH ROW WHEN (OLD.anulada_en IS NULL AND NEW.anulada_en IS NOT NULL)
    EXECUTE FUNCTION core.tg_entradas_anular_stock();

-- Una entrada nueva también marca el stock como actualizado (refresco de la app)
CREATE OR REPLACE FUNCTION core.tg_entradas_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.insumo_unidades
       SET stock_actual = stock_actual + NEW.cantidad, actualizado_en = now()
     WHERE id = NEW.insumo_unidad_id;
    RETURN NEW;
END;
$$;

CREATE INDEX IF NOT EXISTS ix_entradas_vigentes ON core.entradas_inventario (insumo_unidad_id, fecha_operativa)
    WHERE anulada_en IS NULL;

-- La lista de entradas dice si están anuladas (columnas nuevas al final)
CREATE OR REPLACE VIEW api.v_entradas AS
SELECT en.id AS entrada_id, s.unidad_id, s.empresa_id, s.codigo, s.nombre AS insumo, s.area,
       te.codigo AS tipo, te.nombre AS tipo_nombre, te.automatico,
       en.fecha_operativa, en.cantidad, en.observacion,
       p.codigo AS factura, us.nombre AS registrada_por, en.creado_en,
       en.anulada_en, ua.nombre AS anulada_por, en.motivo_anulacion
  FROM core.entradas_inventario en
  JOIN api.v_stock s          ON s.insumo_unidad_id = en.insumo_unidad_id
  JOIN core.tipos_entrada te  ON te.id = en.tipo_entrada_id
  LEFT JOIN core.pedidos p    ON p.id = en.pedido_id
  LEFT JOIN core.usuarios us  ON us.id = en.usuario_id
  LEFT JOIN core.usuarios ua  ON ua.id = en.anulada_por_id;


/* ============================================================================
   2. VENTAS QUE CUENTAN EN Z (una sola regla para vista y API)
   ----------------------------------------------------------------------------
   Cuenta la venta efectiva. Una factura ANULADA deja de contar… salvo para
   los insumos cuya mercancía volvió como entrada de retorno: eso significa
   que su jornada ya estaba cerrada, y ese cierre no se toca.
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.fn_z_insumo(p_insumo_unidad_id INTEGER, p_desde_excl DATE, p_hasta DATE)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(SUM(it.cantidad * pi.cantidad), 0)
      FROM core.insumo_unidades iu
      JOIN core.producto_insumos pi ON pi.insumo_id = iu.insumo_id
      JOIN core.pedido_items it     ON it.producto_id = pi.producto_id
      JOIN core.pedidos p           ON p.id = it.pedido_id AND p.unidad_id = iu.unidad_id
      JOIN core.estados_pedido ep   ON ep.id = p.estado_pedido_id
     WHERE iu.id = p_insumo_unidad_id
       AND p.fecha_operativa >  p_desde_excl
       AND p.fecha_operativa <= p_hasta
       AND (ep.cuenta_como_venta
            OR (ep.codigo = 'anulado'
                AND EXISTS (SELECT 1 FROM core.entradas_inventario e
                             WHERE e.pedido_id = p.id AND e.insumo_unidad_id = iu.id)));
$$;

CREATE OR REPLACE FUNCTION core.fn_en_insumo(p_insumo_unidad_id INTEGER, p_desde_excl DATE, p_hasta DATE)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(SUM(e.cantidad), 0)
      FROM core.entradas_inventario e
     WHERE e.insumo_unidad_id = p_insumo_unidad_id
       AND e.anulada_en IS NULL
       AND e.fecha_operativa >  p_desde_excl
       AND e.fecha_operativa <= p_hasta;
$$;

-- Mismas columnas que en 05: sin entradas anuladas y con la regla de Z de arriba
CREATE OR REPLACE VIEW api.v_cruce_inventario AS
WITH base AS (
    SELECT d.id AS cierre_detalle_id, c.id AS cierre_id, c.unidad_id, c.area_id, c.fecha_operativa,
           d.insumo_unidad_id, iu.insumo_id, d.saldo_fisico,
           ant.saldo_fisico    AS saldo_anterior,
           ant.fecha_operativa AS fecha_anterior
      FROM core.cierre_detalles d
      JOIN core.cierres_inventario c ON c.id = d.cierre_id
      JOIN core.insumo_unidades iu   ON iu.id = d.insumo_unidad_id
      LEFT JOIN LATERAL (
            SELECT d2.saldo_fisico, c2.fecha_operativa
              FROM core.cierre_detalles d2
              JOIN core.cierres_inventario c2 ON c2.id = d2.cierre_id
             WHERE d2.insumo_unidad_id = d.insumo_unidad_id
               AND c2.fecha_operativa < c.fecha_operativa
             ORDER BY c2.fecha_operativa DESC
             LIMIT 1
      ) ant ON TRUE
)
SELECT b.cierre_id, b.cierre_detalle_id, b.unidad_id, u.empresa_id, u.nombre AS unidad,
       a.codigo AS area, b.fecha_operativa, b.fecha_anterior,
       i.codigo, i.nombre AS insumo,
       COALESCE(b.saldo_anterior, 0) AS inicial,
       (b.saldo_anterior IS NULL)    AS sin_cierre_anterior,
       x.en                          AS entradas,
       x.z                           AS ventas,
       b.saldo_fisico                AS saldo_fisico,
       COALESCE(b.saldo_anterior, 0) + x.en - x.z                  AS saldo_esperado,
       COALESCE(b.saldo_anterior, 0) + x.en - x.z - b.saldo_fisico AS diferencia
  FROM base b
  JOIN core.unidades u         ON u.id = b.unidad_id
  JOIN core.areas_inventario a ON a.id = b.area_id
  JOIN core.insumos i          ON i.id = b.insumo_id
  /* La misma regla que core.fn_en_insumo y core.fn_z_insumo, escrita aquí
     porque una vista lee las tablas con los permisos de su dueño y una
     función con los de quien consulta (la app no lee core). */
  CROSS JOIN LATERAL (
        SELECT (SELECT COALESCE(SUM(e.cantidad), 0)
                  FROM core.entradas_inventario e
                 WHERE e.insumo_unidad_id = b.insumo_unidad_id
                   AND e.anulada_en IS NULL
                   AND e.fecha_operativa >  COALESCE(b.fecha_anterior, b.fecha_operativa - 1)
                   AND e.fecha_operativa <= b.fecha_operativa) AS en,
               (SELECT COALESCE(SUM(it.cantidad * pi.cantidad), 0)
                  FROM core.producto_insumos pi
                  JOIN core.pedido_items it   ON it.producto_id = pi.producto_id
                  JOIN core.pedidos p         ON p.id = it.pedido_id AND p.unidad_id = b.unidad_id
                  JOIN core.estados_pedido ep ON ep.id = p.estado_pedido_id
                 WHERE pi.insumo_id = b.insumo_id
                   AND p.fecha_operativa >  COALESCE(b.fecha_anterior, b.fecha_operativa - 1)
                   AND p.fecha_operativa <= b.fecha_operativa
                   AND (ep.cuenta_como_venta
                        OR (ep.codigo = 'anulado'
                            AND EXISTS (SELECT 1 FROM core.entradas_inventario e2
                                         WHERE e2.pedido_id = p.id AND e2.insumo_unidad_id = b.insumo_unidad_id)))) AS z
  ) x;

/* Borrar facturas de prueba: igual que en 04, pero sin descontar dos veces lo
   que devolvió una entrada que ya estaba anulada. */
CREATE OR REPLACE PROCEDURE api.sp_borrar_facturas_prueba(
    p_empresa_id    INTEGER,
    p_confirmacion  VARCHAR,
    p_usuario_id    INTEGER,
    INOUT p_borradas INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'pedidos_anular');

    IF upper(trim(COALESCE(p_confirmacion, ''))) <> 'BORRAR' THEN
        RAISE EXCEPTION 'Escribe BORRAR para confirmar.';
    END IF;
    IF p_usuario_id IS NOT NULL
       AND p_empresa_id IS DISTINCT FROM (SELECT empresa_id FROM core.usuarios WHERE id = p_usuario_id)
       AND NOT core.fn_tiene_permiso(p_usuario_id, 'plataforma') THEN
        RAISE EXCEPTION 'No puedes borrar facturas de otra empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;

    PERFORM set_config('taseca.borrado_pruebas', 'si', TRUE);

    UPDATE core.insumo_unidades iu
       SET stock_actual = GREATEST(iu.stock_actual - e.total, 0)
      FROM (SELECT en.insumo_unidad_id, SUM(en.cantidad) AS total
              FROM core.entradas_inventario en
              JOIN core.pedidos p ON p.id = en.pedido_id
             WHERE p.empresa_id = p_empresa_id AND en.anulada_en IS NULL
             GROUP BY en.insumo_unidad_id) e
     WHERE iu.id = e.insumo_unidad_id;

    DELETE FROM core.entradas_inventario en USING core.pedidos p
     WHERE p.id = en.pedido_id AND p.empresa_id = p_empresa_id;
    DELETE FROM core.anulaciones a USING core.pedidos p
     WHERE p.id = a.pedido_id AND p.empresa_id = p_empresa_id;
    DELETE FROM core.pedidos WHERE empresa_id = p_empresa_id;
    GET DIAGNOSTICS p_borradas = ROW_COUNT;

    DELETE FROM core.clientes c
     WHERE c.empresa_id = p_empresa_id
       AND NOT EXISTS (SELECT 1 FROM core.pedidos p WHERE p.cliente_id = c.id);

    UPDATE core.consecutivos SET ultimo_numero = 0 WHERE empresa_id = p_empresa_id AND tipo = 'pedido';

    PERFORM set_config('taseca.borrado_pruebas', '', TRUE);
END;
$$;


/* ============================================================================
   3. STOCK (catálogo de inventario)
   ============================================================================ */

/* La unidad de conteo se escribe a mano en la pantalla ("botella",
   "Porción"…): se busca por código o nombre y, si no existe, se crea. */
CREATE OR REPLACE FUNCTION core.fn_unidad_medida(p_texto TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_txt TEXT := lower(regexp_replace(trim(COALESCE(p_texto, '')), '\s+', ' ', 'g'));
    v_id  INTEGER;
BEGIN
    IF v_txt = '' THEN
        v_txt := 'unidad';
    END IF;
    IF length(v_txt) > 20 THEN
        RAISE EXCEPTION 'La unidad de conteo "%" es demasiado larga (máximo 20 letras).', v_txt;
    END IF;
    SELECT id INTO v_id FROM core.unidades_medida WHERE lower(codigo) = v_txt OR lower(nombre) = v_txt LIMIT 1;
    IF v_id IS NULL THEN
        INSERT INTO core.unidades_medida (codigo, nombre)
        VALUES (v_txt, upper(left(v_txt, 1)) || substr(v_txt, 2))
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END;
$$;

/* Categoría de inventario por nombre; si no existe en la empresa, se crea. */
CREATE OR REPLACE FUNCTION core.fn_categoria_insumo(p_empresa_id INTEGER, p_nombre TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_nombre TEXT := COALESCE(NULLIF(regexp_replace(trim(COALESCE(p_nombre, '')), '\s+', ' ', 'g'), ''), 'General');
    v_id     INTEGER;
BEGIN
    SELECT id INTO v_id FROM core.categorias_insumo WHERE empresa_id = p_empresa_id AND lower(nombre) = lower(v_nombre);
    IF v_id IS NULL THEN
        INSERT INTO core.categorias_insumo (empresa_id, nombre) VALUES (p_empresa_id, left(v_nombre, 80))
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION core.fn_cantidad_entera(p_valor NUMERIC, p_que TEXT, p_permitir_cero BOOLEAN)
RETURNS NUMERIC
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    IF p_valor IS NULL OR p_valor <> trunc(p_valor) OR p_valor < 0 OR (p_valor = 0 AND NOT p_permitir_cero) THEN
        RAISE EXCEPTION '% debe ser un número entero %.', p_que,
              CASE WHEN p_permitir_cero THEN 'mayor o igual a cero' ELSE 'mayor que cero' END;
    END IF;
    RETURN p_valor;
END;
$$;

/* Crea o edita un producto de inventario.
   p_stock_actual / p_stock_minimo NULL = no cambiar.
   p_productos NULL = no cambiar qué producto de la carta lo descuenta. */
CREATE OR REPLACE PROCEDURE api.sp_guardar_insumo(
    p_empresa_id     INTEGER,
    p_codigo         VARCHAR,
    p_nombre         VARCHAR,
    p_categoria      VARCHAR,
    p_area           VARCHAR,
    p_unidad_medida  VARCHAR,
    p_unidades       INTEGER[],
    p_usuario_id     INTEGER,
    p_activo         BOOLEAN   DEFAULT TRUE,
    p_stock_actual   NUMERIC   DEFAULT NULL,
    p_stock_minimo   NUMERIC   DEFAULT NULL,
    p_productos      INTEGER[] DEFAULT NULL,
    INOUT p_insumo_id INTEGER  DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_codigo VARCHAR := upper(regexp_replace(trim(COALESCE(p_codigo, '')), '\s+', '', 'g'));
    v_nombre VARCHAR := regexp_replace(trim(COALESCE(p_nombre, '')), '\s+', ' ', 'g');
    v_area   INTEGER := (SELECT id FROM core.areas_inventario WHERE codigo = p_area);
    v_p      INTEGER;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'stock');
    PERFORM core.fn_exigir_unidades(p_usuario_id, p_empresa_id, p_unidades);

    IF v_codigo = '' OR length(v_codigo) > 20 THEN
        RAISE EXCEPTION 'El producto necesita un código de hasta 20 caracteres.';
    END IF;
    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'El producto necesita un nombre.';
    END IF;
    IF v_area IS NULL THEN
        RAISE EXCEPTION 'Elige el área del producto (comidas o bar).';
    END IF;
    IF EXISTS (SELECT 1 FROM core.insumos WHERE empresa_id = p_empresa_id AND codigo = v_codigo
                                            AND id IS DISTINCT FROM p_insumo_id) THEN
        RAISE EXCEPTION 'Ya existe otro producto con el código % (puede ser de otra unidad de la empresa).', v_codigo;
    END IF;
    IF p_stock_actual IS NOT NULL THEN
        PERFORM core.fn_cantidad_entera(p_stock_actual, 'El stock actual', TRUE);
    END IF;
    IF p_stock_minimo IS NOT NULL THEN
        PERFORM core.fn_cantidad_entera(p_stock_minimo, 'El stock mínimo', TRUE);
    END IF;

    IF p_insumo_id IS NULL THEN
        INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre, activo)
        VALUES (p_empresa_id, core.fn_categoria_insumo(p_empresa_id, p_categoria), v_area,
                core.fn_unidad_medida(p_unidad_medida), v_codigo, v_nombre, COALESCE(p_activo, TRUE))
        RETURNING id INTO p_insumo_id;
    ELSE
        -- Cambiar de área rompería los cierres ya contados de este producto
        IF EXISTS (SELECT 1 FROM core.insumos i WHERE i.id = p_insumo_id AND i.area_id <> v_area)
           AND EXISTS (SELECT 1 FROM core.cierre_detalles d JOIN core.insumo_unidades iu ON iu.id = d.insumo_unidad_id
                        WHERE iu.insumo_id = p_insumo_id) THEN
            RAISE EXCEPTION 'El producto ya aparece en cierres de su área: no puede cambiar de área. Crea uno nuevo.';
        END IF;
        UPDATE core.insumos
           SET codigo = v_codigo, nombre = v_nombre, area_id = v_area,
               categoria_insumo_id = core.fn_categoria_insumo(p_empresa_id, p_categoria),
               unidad_medida_id = core.fn_unidad_medida(p_unidad_medida),
               activo = COALESCE(p_activo, activo)
         WHERE id = p_insumo_id AND empresa_id = p_empresa_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Ese producto de inventario ya no existe. Recarga la página.';
        END IF;
    END IF;

    -- Unidades: se agregan; las que ya tenían movimientos no se quitan desde aquí
    INSERT INTO core.insumo_unidades (insumo_id, unidad_id)
    SELECT p_insumo_id, x FROM unnest(p_unidades) x
    ON CONFLICT (insumo_id, unidad_id) DO NOTHING;

    UPDATE core.insumo_unidades
       SET stock_actual = COALESCE(p_stock_actual, stock_actual),
           stock_minimo = COALESCE(p_stock_minimo, stock_minimo),
           actualizado_en = now()
     WHERE insumo_id = p_insumo_id AND unidad_id = ANY (p_unidades)
       AND (p_stock_actual IS NOT NULL OR p_stock_minimo IS NOT NULL);

    IF p_productos IS NOT NULL THEN
        FOREACH v_p IN ARRAY p_productos LOOP
            IF NOT EXISTS (SELECT 1 FROM core.productos WHERE id = v_p AND empresa_id = p_empresa_id) THEN
                RAISE EXCEPTION 'El producto de la carta % no es de esta empresa.', v_p USING ERRCODE = 'insufficient_privilege';
            END IF;
        END LOOP;
        DELETE FROM core.producto_insumos WHERE insumo_id = p_insumo_id AND producto_id <> ALL (p_productos);
        INSERT INTO core.producto_insumos (producto_id, insumo_id)
        SELECT x, p_insumo_id FROM unnest(p_productos) x
        ON CONFLICT (producto_id, insumo_id) DO NOTHING;
    END IF;

    UPDATE core.insumos SET actualizado_en = now() WHERE id = p_insumo_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_ajustar_stock_actual(p_unidad_id INTEGER, p_insumo_id INTEGER, p_cantidad NUMERIC, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'stock', p_unidad_id);
    PERFORM core.fn_cantidad_entera(p_cantidad, 'El stock', TRUE);
    UPDATE core.insumo_unidades SET stock_actual = p_cantidad, actualizado_en = now()
     WHERE unidad_id = p_unidad_id AND insumo_id = p_insumo_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese producto no está en esta unidad.';
    END IF;
END;
$$;


/* ============================================================================
   4. ENTRADAS
   ============================================================================ */

CREATE OR REPLACE PROCEDURE api.sp_anular_entrada(p_entrada_id BIGINT, p_motivo VARCHAR, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v RECORD;
BEGIN
    SELECT e.id, e.anulada_en, e.fecha_operativa, iu.unidad_id, i.area_id, a.nombre AS area, te.automatico
      INTO v
      FROM core.entradas_inventario e
      JOIN core.insumo_unidades iu ON iu.id = e.insumo_unidad_id
      JOIN core.insumos i          ON i.id = iu.insumo_id
      JOIN core.areas_inventario a ON a.id = i.area_id
      JOIN core.tipos_entrada te   ON te.id = e.tipo_entrada_id
     WHERE e.id = p_entrada_id
       FOR UPDATE OF e;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontró la entrada.';
    END IF;

    PERFORM core.fn_preparar_operacion(p_usuario_id, 'entradas', v.unidad_id);

    IF v.anulada_en IS NOT NULL THEN
        RAISE EXCEPTION 'Esa entrada ya estaba eliminada.';
    END IF;
    IF v.automatico THEN
        RAISE EXCEPTION 'Los retornos por anulación de factura los genera el sistema: no se eliminan a mano.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.cierres_inventario c JOIN core.estados_cierre ec ON ec.id = c.estado_cierre_id
                WHERE c.unidad_id = v.unidad_id AND c.area_id = v.area_id
                  AND c.fecha_operativa = v.fecha_operativa AND ec.codigo = 'revisado') THEN
        RAISE EXCEPTION 'El cierre de % del % ya fue revisado: sus entradas quedaron congeladas.',
              lower(v.area), to_char(v.fecha_operativa, 'DD/MM/YYYY');
    END IF;
    IF length(trim(COALESCE(p_motivo, ''))) < 3 THEN
        RAISE EXCEPTION 'Escribe por qué se elimina la entrada.';
    END IF;

    UPDATE core.entradas_inventario
       SET anulada_en = now(), anulada_por_id = p_usuario_id, motivo_anulacion = left(trim(p_motivo), 300)
     WHERE id = p_entrada_id;
END;
$$;


/* ============================================================================
   5. CIERRES
   ============================================================================ */

/* Se reemplaza la versión de 04:
     · estado 'borrador' o 'completado' (un completado no vuelve a borrador)
     · p_nuevo = TRUE: si ya hay cierre para esa unidad, área y fecha, avisa
       (YA_EXISTE) en vez de mezclarlo
     · al corregir, el conteo nuevo REEMPLAZA al anterior: lo que no se contó
       esta vez sale del cierre
     · saldos enteros ≥ 0 y nunca una jornada futura
   p_detalle: [{"insumo_id": 7, "saldo": 24}] o [{"codigo": "BAR-01", "saldo": 24}] */
DROP PROCEDURE IF EXISTS api.sp_registrar_cierre(INTEGER, VARCHAR, JSONB, INTEGER, DATE, VARCHAR, BIGINT);

CREATE OR REPLACE PROCEDURE api.sp_registrar_cierre(
    p_unidad_id    INTEGER,
    p_area         VARCHAR,
    p_detalle      JSONB,
    p_usuario_id   INTEGER,
    p_fecha        DATE    DEFAULT NULL,
    p_observacion  VARCHAR DEFAULT NULL,
    p_estado       VARCHAR DEFAULT 'completado',
    p_nuevo        BOOLEAN DEFAULT FALSE,
    INOUT p_cierre_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_empresa  INTEGER := core.fn_empresa_de_unidad(p_unidad_id);
    v_area     INTEGER := (SELECT id FROM core.areas_inventario WHERE codigo = p_area);
    v_hoy      DATE;
    v_fecha    DATE;
    v_estado   VARCHAR := COALESCE(NULLIF(p_estado, ''), 'completado');
    v_actual   VARCHAR;
    v_linea    JSONB;
    v_iu       INTEGER;
    v_contados INTEGER[] := '{}';
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'cierres_registrar', p_unidad_id);

    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'La unidad % no existe.', p_unidad_id;
    END IF;
    IF v_area IS NULL THEN
        RAISE EXCEPTION 'El cierre necesita un área válida (comidas o bar).';
    END IF;
    IF v_estado NOT IN ('borrador', 'completado') THEN
        RAISE EXCEPTION 'Un cierre se guarda como borrador o completado; la revisión es aparte.';
    END IF;
    IF p_detalle IS NULL OR jsonb_typeof(p_detalle) <> 'array' OR jsonb_array_length(p_detalle) = 0 THEN
        RAISE EXCEPTION 'El cierre no tiene productos contados.';
    END IF;

    v_hoy   := core.fn_fecha_operativa(v_empresa, now());
    v_fecha := COALESCE(p_fecha, v_hoy);
    IF v_fecha > v_hoy THEN
        RAISE EXCEPTION 'No se puede cerrar una jornada que todavía no llega (%).', to_char(v_fecha, 'DD/MM/YYYY');
    END IF;

    SELECT c.id, ec.codigo INTO p_cierre_id, v_actual
      FROM core.cierres_inventario c JOIN core.estados_cierre ec ON ec.id = c.estado_cierre_id
     WHERE c.unidad_id = p_unidad_id AND c.area_id = v_area AND c.fecha_operativa = v_fecha
       FOR UPDATE OF c;

    IF p_cierre_id IS NOT NULL AND p_nuevo THEN
        RAISE EXCEPTION 'YA_EXISTE: ya hay un cierre de % para esa unidad y fecha. Vuelve atrás para corregirlo.', p_area;
    END IF;
    IF v_actual = 'revisado' THEN
        RAISE EXCEPTION 'El cierre de % del % ya fue revisado: no se puede corregir.', p_area, to_char(v_fecha, 'DD/MM/YYYY');
    END IF;
    IF v_actual = 'completado' THEN
        v_estado := 'completado'; -- lo completado no vuelve a borrador
    END IF;

    IF p_cierre_id IS NULL THEN
        INSERT INTO core.cierres_inventario (unidad_id, area_id, estado_cierre_id, fecha_operativa, observacion, registrado_por_id)
        VALUES (p_unidad_id, v_area, core.fn_id_catalogo('estados_cierre', v_estado), v_fecha,
                NULLIF(trim(p_observacion), ''), p_usuario_id)
        RETURNING id INTO p_cierre_id;
    ELSE
        UPDATE core.cierres_inventario
           SET estado_cierre_id = core.fn_id_catalogo('estados_cierre', v_estado),
               observacion = COALESCE(NULLIF(trim(p_observacion), ''), observacion),
               registrado_por_id = p_usuario_id, actualizado_en = now()
         WHERE id = p_cierre_id;
    END IF;

    FOR v_linea IN SELECT * FROM jsonb_array_elements(p_detalle) LOOP
        SELECT iu.id INTO v_iu
          FROM core.insumo_unidades iu JOIN core.insumos i ON i.id = iu.insumo_id
         WHERE iu.unidad_id = p_unidad_id AND i.area_id = v_area
           AND (i.id = NULLIF(v_linea ->> 'insumo_id', '')::INTEGER
                OR (v_linea ? 'codigo' AND i.codigo = upper(trim(v_linea ->> 'codigo'))));
        IF v_iu IS NULL THEN
            RAISE EXCEPTION 'El producto % no es de esta unidad ni de esta área.', COALESCE(v_linea ->> 'codigo', v_linea ->> 'insumo_id');
        END IF;
        PERFORM core.fn_cantidad_entera(NULLIF(v_linea ->> 'saldo', '')::NUMERIC,
                                        'El saldo de ' || COALESCE(v_linea ->> 'codigo', v_linea ->> 'insumo_id'), TRUE);

        INSERT INTO core.cierre_detalles (cierre_id, insumo_unidad_id, saldo_fisico)
        VALUES (p_cierre_id, v_iu, (v_linea ->> 'saldo')::NUMERIC)
        ON CONFLICT (cierre_id, insumo_unidad_id) DO UPDATE SET saldo_fisico = EXCLUDED.saldo_fisico;
        v_contados := v_contados || v_iu;
    END LOOP;

    -- El conteo nuevo reemplaza al anterior
    DELETE FROM core.cierre_detalles WHERE cierre_id = p_cierre_id AND insumo_unidad_id <> ALL (v_contados);
END;
$$;

/* Igual que en 04, pero exige que el cierre esté completado (no un borrador). */
CREATE OR REPLACE PROCEDURE api.sp_revisar_cierre(p_cierre_id BIGINT, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_estado VARCHAR;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'cierres_revisar',
            (SELECT unidad_id FROM core.cierres_inventario WHERE id = p_cierre_id));
    SELECT ec.codigo INTO v_estado
      FROM core.cierres_inventario c JOIN core.estados_cierre ec ON ec.id = c.estado_cierre_id
     WHERE c.id = p_cierre_id;
    IF v_estado IS NULL OR v_estado = 'revisado' THEN
        RAISE EXCEPTION 'El cierre % no existe o ya estaba revisado.', p_cierre_id;
    END IF;
    IF v_estado = 'borrador' THEN
        RAISE EXCEPTION 'Ese cierre es un borrador: primero hay que completarlo.';
    END IF;
    UPDATE core.cierres_inventario
       SET estado_cierre_id = core.fn_id_catalogo('estados_cierre', 'revisado'),
           revisado_por_id = p_usuario_id, revisado_en = now(), actualizado_en = now()
     WHERE id = p_cierre_id;
END;
$$;

/* Igual que en 04; se puede aplicar más de una vez (antes fallaba en un
   cierre revisado que ya estaba aplicado). */
CREATE OR REPLACE PROCEDURE api.sp_aplicar_cierre_a_stock(p_cierre_id BIGINT, p_usuario_id INTEGER, INOUT p_aplicados INTEGER DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'stock',
            (SELECT unidad_id FROM core.cierres_inventario WHERE id = p_cierre_id));
    IF NOT EXISTS (SELECT 1 FROM core.cierres_inventario WHERE id = p_cierre_id) THEN
        RAISE EXCEPTION 'No se encontró el cierre.';
    END IF;

    UPDATE core.insumo_unidades iu
       SET stock_actual = d.saldo_fisico, actualizado_en = now()
      FROM core.cierre_detalles d
     WHERE d.cierre_id = p_cierre_id AND d.insumo_unidad_id = iu.id;
    GET DIAGNOSTICS p_aplicados = ROW_COUNT;

    UPDATE core.cierres_inventario SET aplicado_a_stock = TRUE, actualizado_en = now()
     WHERE id = p_cierre_id AND NOT aplicado_a_stock;
END;
$$;


/* ============================================================================
   6. API REST · LECTURA
   Todo filtrado por la empresa del token, las unidades del usuario y sus
   permisos. Cierres y entradas: los últimos 62 días.
   ============================================================================ */

CREATE OR REPLACE VIEW rest.stock AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_usuario() AS usuario_id, core.fn_jwt_empresa() AS empresa_id
)
SELECT i.id AS insumo_id, i.empresa_id, i.codigo, i.nombre, ci.nombre AS categoria, a.codigo AS area,
       um.codigo AS unidad_medida, i.activo,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('unidad_id', iu.unidad_id, 'stock_actual', iu.stock_actual,
                                                     'stock_minimo', iu.stock_minimo) ORDER BY iu.unidad_id)
                   FROM core.insumo_unidades iu WHERE iu.insumo_id = i.id), '[]') AS unidades,
       COALESCE((SELECT jsonb_agg(pi.producto_id ORDER BY pi.producto_id)
                   FROM core.producto_insumos pi WHERE pi.insumo_id = i.id), '[]') AS productos,
       GREATEST(i.actualizado_en, (SELECT max(iu.actualizado_en) FROM core.insumo_unidades iu WHERE iu.insumo_id = i.id)) AS actualizado_en
  FROM core.insumos i
  JOIN sesion s                  ON s.empresa_id = i.empresa_id
  JOIN core.categorias_insumo ci ON ci.id = i.categoria_insumo_id
  JOIN core.areas_inventario a   ON a.id = i.area_id
  JOIN core.unidades_medida um   ON um.id = i.unidad_medida_id
 WHERE EXISTS (SELECT 1 FROM unnest(ARRAY['stock', 'entradas', 'cierres', 'cierres_registrar']) p
                WHERE api.fn_tiene_permiso(s.usuario_id, p))
   AND EXISTS (SELECT 1 FROM core.insumo_unidades iu
                WHERE iu.insumo_id = i.id AND core.fn_usuario_en_unidad(s.usuario_id, iu.unidad_id));

CREATE OR REPLACE VIEW rest.cierres AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_usuario() AS usuario_id, core.fn_jwt_empresa() AS empresa_id
)
SELECT c.id AS cierre_id, u.empresa_id, c.unidad_id, a.codigo AS area, c.fecha_operativa, ec.codigo AS estado,
       c.observacion, c.aplicado_a_stock, c.registrado_por_id, ur.nombre AS registrado_por,
       uv.nombre AS revisado_por, c.revisado_en, c.creado_en, c.actualizado_en,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('codigo', i.codigo, 'nombre', i.nombre, 'saldo', d.saldo_fisico)
                                  ORDER BY i.codigo)
                   FROM core.cierre_detalles d
                   JOIN core.insumo_unidades iu ON iu.id = d.insumo_unidad_id
                   JOIN core.insumos i          ON i.id = iu.insumo_id
                  WHERE d.cierre_id = c.id), '[]') AS productos
  FROM core.cierres_inventario c
  JOIN core.unidades u         ON u.id = c.unidad_id
  JOIN sesion s                ON s.empresa_id = u.empresa_id
  JOIN core.areas_inventario a ON a.id = c.area_id
  JOIN core.estados_cierre ec  ON ec.id = c.estado_cierre_id
  LEFT JOIN core.usuarios ur   ON ur.id = c.registrado_por_id
  LEFT JOIN core.usuarios uv   ON uv.id = c.revisado_por_id
 WHERE c.fecha_operativa >= core.fn_fecha_operativa(u.empresa_id, now()) - 62
   AND core.fn_usuario_en_unidad(s.usuario_id, c.unidad_id)
   AND EXISTS (SELECT 1 FROM unnest(ARRAY['stock', 'cierres', 'cierres_registrar']) p
                WHERE api.fn_tiene_permiso(s.usuario_id, p));

CREATE OR REPLACE VIEW rest.entradas AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_usuario() AS usuario_id, core.fn_jwt_empresa() AS empresa_id
)
SELECT e.id AS entrada_id, i.empresa_id, iu.unidad_id, i.codigo, i.nombre, a.codigo AS area,
       e.cantidad, te.codigo AS tipo, e.observacion, e.fecha_operativa, e.usuario_id,
       us.nombre AS registrada_por, e.creado_en, p.codigo AS factura
  FROM core.entradas_inventario e
  JOIN core.insumo_unidades iu ON iu.id = e.insumo_unidad_id
  JOIN core.insumos i          ON i.id = iu.insumo_id
  JOIN sesion s                ON s.empresa_id = i.empresa_id
  JOIN core.areas_inventario a ON a.id = i.area_id
  JOIN core.tipos_entrada te   ON te.id = e.tipo_entrada_id
  LEFT JOIN core.usuarios us   ON us.id = e.usuario_id
  LEFT JOIN core.pedidos p     ON p.id = e.pedido_id
 WHERE e.anulada_en IS NULL
   AND e.fecha_operativa >= core.fn_fecha_operativa(i.empresa_id, now()) - 62
   AND core.fn_usuario_en_unidad(s.usuario_id, iu.unidad_id)
   AND EXISTS (SELECT 1 FROM unnest(ARRAY['stock', 'entradas', 'cierres']) p2
                WHERE api.fn_tiene_permiso(s.usuario_id, p2));

/* Una sola fila con la última modificación del inventario de la empresa.
   La aplicación la consulta (unos bytes) y sólo recarga si cambió. */
CREATE OR REPLACE VIEW rest.inventario_marca AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_empresa() AS empresa_id
)
SELECT s.empresa_id,
       GREATEST(
           (SELECT max(i.actualizado_en) FROM core.insumos i WHERE i.empresa_id = s.empresa_id),
           (SELECT max(iu.actualizado_en) FROM core.insumo_unidades iu JOIN core.unidades u ON u.id = iu.unidad_id
             WHERE u.empresa_id = s.empresa_id),
           (SELECT max(c.actualizado_en) FROM core.cierres_inventario c JOIN core.unidades u ON u.id = c.unidad_id
             WHERE u.empresa_id = s.empresa_id),
           (SELECT max(GREATEST(e.creado_en, COALESCE(e.anulada_en, e.creado_en)))
              FROM core.entradas_inventario e JOIN core.insumo_unidades iu ON iu.id = e.insumo_unidad_id
              JOIN core.unidades u ON u.id = iu.unidad_id
             WHERE u.empresa_id = s.empresa_id)
       ) AS marca
  FROM sesion s
 WHERE s.empresa_id IS NOT NULL;


/* ============================================================================
   7. API REST · FUNCIONES
   ============================================================================ */

/* El cierre como lo usa la aplicación. */
CREATE OR REPLACE FUNCTION core.fn_cierre_json(p_cierre_id BIGINT)
RETURNS JSONB
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT to_jsonb(c) FROM rest.cierres c WHERE c.cierre_id = p_cierre_id;
$$;

/* POST /rpc/guardar_insumo { "p_insumo": { insumo_id|null, codigo, nombre, categoria,
   area, unidad, activo, stock_actual?, stock_minimo?, unidades: [..], productos?: [..] } } */
CREATE OR REPLACE FUNCTION rest.guardar_insumo(p_insumo JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_empresa INTEGER := core.fn_jwt_empresa();
    v_id      INTEGER := NULLIF(p_insumo ->> 'insumo_id', '')::INTEGER;
    v_unidades  INTEGER[];
    v_productos INTEGER[];
BEGIN
    v_unidades := ARRAY(SELECT x::INTEGER FROM jsonb_array_elements_text(COALESCE(p_insumo -> 'unidades', '[]')) x);
    IF jsonb_typeof(p_insumo -> 'productos') = 'array' THEN
        v_productos := ARRAY(SELECT x::INTEGER FROM jsonb_array_elements_text(p_insumo -> 'productos') x);
    END IF;

    CALL api.sp_guardar_insumo(
        p_empresa_id    => v_empresa,
        p_codigo        => p_insumo ->> 'codigo',
        p_nombre        => p_insumo ->> 'nombre',
        p_categoria     => p_insumo ->> 'categoria',
        p_area          => p_insumo ->> 'area',
        p_unidad_medida => p_insumo ->> 'unidad',
        p_unidades      => v_unidades,
        p_usuario_id    => v_usuario,
        p_activo        => COALESCE((p_insumo ->> 'activo')::BOOLEAN, TRUE),
        p_stock_actual  => NULLIF(p_insumo ->> 'stock_actual', '')::NUMERIC,
        p_stock_minimo  => NULLIF(p_insumo ->> 'stock_minimo', '')::NUMERIC,
        p_productos     => v_productos,
        p_insumo_id     => v_id);
    RETURN jsonb_build_object('insumo_id', v_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.ajustar_stock(p_unidad_id INTEGER, p_codigo TEXT, p_cantidad NUMERIC)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_insumo  INTEGER := (SELECT id FROM core.insumos WHERE empresa_id = core.fn_jwt_empresa() AND codigo = upper(trim(p_codigo)));
BEGIN
    IF v_insumo IS NULL THEN
        RAISE EXCEPTION 'El producto % no existe en el inventario.', p_codigo;
    END IF;
    CALL api.sp_ajustar_stock_actual(p_unidad_id, v_insumo, p_cantidad, v_usuario);
    RETURN jsonb_build_object('codigo', upper(trim(p_codigo)), 'stock_actual', p_cantidad);
END;
$$;

/* POST /rpc/registrar_entrada { "p_entrada": { unidad_id, codigo, tipo, cantidad, observacion, fecha } } */
CREATE OR REPLACE FUNCTION rest.registrar_entrada(p_entrada JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_empresa INTEGER := core.fn_jwt_empresa();
    v_unidad  INTEGER := NULLIF(p_entrada ->> 'unidad_id', '')::INTEGER;
    v_insumo  INTEGER;
    v_fecha   DATE    := NULLIF(p_entrada ->> 'fecha', '')::DATE;
    v_id      BIGINT;
BEGIN
    SELECT id INTO v_insumo FROM core.insumos WHERE empresa_id = v_empresa AND codigo = upper(trim(p_entrada ->> 'codigo'));
    IF v_insumo IS NULL THEN
        RAISE EXCEPTION 'El producto no existe en el catálogo de inventario.';
    END IF;
    IF v_fecha IS NULL THEN
        RAISE EXCEPTION 'La entrada necesita una fecha válida.';
    END IF;
    IF v_fecha > core.fn_fecha_operativa(v_empresa, now()) THEN
        RAISE EXCEPTION 'La entrada no puede ser de una jornada futura.';
    END IF;
    PERFORM core.fn_cantidad_entera(NULLIF(p_entrada ->> 'cantidad', '')::NUMERIC, 'La cantidad', FALSE);

    CALL api.sp_registrar_entrada(
        p_unidad_id   => v_unidad,
        p_insumo_id   => v_insumo,
        p_tipo        => COALESCE(NULLIF(p_entrada ->> 'tipo', ''), 'compra'),
        p_cantidad    => (p_entrada ->> 'cantidad')::NUMERIC,
        p_usuario_id  => v_usuario,
        p_observacion => p_entrada ->> 'observacion',
        p_fecha       => v_fecha,
        p_entrada_id  => v_id);

    RETURN (SELECT to_jsonb(e) FROM rest.entradas e WHERE e.entrada_id = v_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.anular_entrada(p_entrada_id BIGINT, p_motivo TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.entradas_inventario e
                     JOIN core.insumo_unidades iu ON iu.id = e.insumo_unidad_id
                     JOIN core.insumos i ON i.id = iu.insumo_id
                    WHERE e.id = p_entrada_id AND i.empresa_id = core.fn_jwt_empresa()) THEN
        RAISE EXCEPTION 'No se encontró la entrada.';
    END IF;
    CALL api.sp_anular_entrada(p_entrada_id, COALESCE(NULLIF(trim(p_motivo), ''), 'Eliminada desde el panel'), v_usuario);
    RETURN jsonb_build_object('entrada_id', p_entrada_id, 'anulada', TRUE);
END;
$$;

/* Corregir = anular la entrada y registrar la correcta, todo o nada.
   p_datos: los campos que cambian (unidad_id, codigo, tipo, cantidad, observacion, fecha). */
CREATE OR REPLACE FUNCTION rest.corregir_entrada(p_entrada_id BIGINT, p_datos JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_actual JSONB;
BEGIN
    SELECT to_jsonb(e) INTO v_actual FROM rest.entradas e WHERE e.entrada_id = p_entrada_id;
    IF v_actual IS NULL THEN
        RAISE EXCEPTION 'No se encontró la entrada (o ya no se puede corregir).';
    END IF;

    PERFORM rest.anular_entrada(p_entrada_id, 'Corregida desde el panel');
    RETURN rest.registrar_entrada(
        jsonb_build_object('unidad_id', v_actual -> 'unidad_id', 'codigo', v_actual -> 'codigo',
                           'tipo', v_actual -> 'tipo', 'cantidad', v_actual -> 'cantidad',
                           'observacion', v_actual -> 'observacion', 'fecha', v_actual -> 'fecha_operativa')
        || jsonb_strip_nulls(COALESCE(p_datos, '{}')));
END;
$$;

/* POST /rpc/registrar_cierre { "p_cierre": { unidad_id, area, fecha, estado, observacion,
   productos: [{ codigo, saldo }], nuevo } } */
CREATE OR REPLACE FUNCTION rest.registrar_cierre(p_cierre JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_unidad  INTEGER := NULLIF(p_cierre ->> 'unidad_id', '')::INTEGER;
    v_id      BIGINT;
BEGIN
    IF core.fn_empresa_de_unidad(v_unidad) IS DISTINCT FROM core.fn_jwt_empresa() THEN
        RAISE EXCEPTION 'La unidad % no es de esta empresa.', v_unidad USING ERRCODE = 'insufficient_privilege';
    END IF;
    CALL api.sp_registrar_cierre(
        p_unidad_id   => v_unidad,
        p_area        => p_cierre ->> 'area',
        p_detalle     => p_cierre -> 'productos',
        p_usuario_id  => v_usuario,
        p_fecha       => NULLIF(p_cierre ->> 'fecha', '')::DATE,
        p_observacion => p_cierre ->> 'observacion',
        p_estado      => p_cierre ->> 'estado',
        p_nuevo       => COALESCE((p_cierre ->> 'nuevo')::BOOLEAN, FALSE),
        p_cierre_id   => v_id);
    RETURN core.fn_cierre_json(v_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.revisar_cierre(p_cierre_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.cierres_inventario c JOIN core.unidades u ON u.id = c.unidad_id
                    WHERE c.id = p_cierre_id AND u.empresa_id = core.fn_jwt_empresa()) THEN
        RAISE EXCEPTION 'No se encontró el cierre.';
    END IF;
    CALL api.sp_revisar_cierre(p_cierre_id, core.fn_exigir_sesion());
    RETURN core.fn_cierre_json(p_cierre_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.aplicar_cierre_a_stock(p_cierre_id BIGINT)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_n INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.cierres_inventario c JOIN core.unidades u ON u.id = c.unidad_id
                    WHERE c.id = p_cierre_id AND u.empresa_id = core.fn_jwt_empresa()) THEN
        RAISE EXCEPTION 'No se encontró el cierre.';
    END IF;
    CALL api.sp_aplicar_cierre_a_stock(p_cierre_id, core.fn_exigir_sesion(), v_n);
    RETURN v_n;
END;
$$;

/* EL CRUCE de una unidad, jornada y área, para TODO el catálogo del área
   (lo contado y lo que falta por contar):

     IN  saldo del último cierre anterior en que se contó el producto; si
         nunca se contó, el stock registrado antes de esa jornada ('stock')
     EN  entradas vigentes desde ese cierre hasta esta jornada
     Z   ventas en el mismo tramo (ver core.fn_z_insumo)
     SD  lo contado en el cierre de esta jornada (null = sin registrar) */
CREATE OR REPLACE FUNCTION rest.cruce_inventario(p_unidad_id INTEGER, p_fecha DATE, p_area TEXT)
RETURNS JSONB
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_area    INTEGER := (SELECT id FROM core.areas_inventario WHERE codigo = p_area);
    v_cierre  BIGINT;
    v_filas   JSONB;
    v_ant     JSONB;
BEGIN
    IF core.fn_empresa_de_unidad(p_unidad_id) IS DISTINCT FROM core.fn_jwt_empresa()
       OR NOT core.fn_usuario_en_unidad(v_usuario, p_unidad_id) THEN
        RAISE EXCEPTION 'No trabajas en esa unidad.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NOT (core.fn_tiene_permiso(v_usuario, 'cierres') OR core.fn_tiene_permiso(v_usuario, 'stock')) THEN
        RAISE EXCEPTION 'Tu perfil no puede ver el cruce de inventario.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF v_area IS NULL OR p_fecha IS NULL THEN
        RAISE EXCEPTION 'Elige la fecha y el área del cruce.';
    END IF;

    SELECT id INTO v_cierre FROM core.cierres_inventario
     WHERE unidad_id = p_unidad_id AND area_id = v_area AND fecha_operativa = p_fecha;

    SELECT jsonb_build_object('cierre_id', c.id, 'fecha', c.fecha_operativa) INTO v_ant
      FROM core.cierres_inventario c
     WHERE c.unidad_id = p_unidad_id AND c.area_id = v_area AND c.fecha_operativa < p_fecha
     ORDER BY c.fecha_operativa DESC LIMIT 1;

    WITH items AS (
        SELECT iu.id AS iu_id, i.codigo, i.nombre, ci.nombre AS categoria, um.codigo AS unidad, iu.stock_actual,
               (SELECT d.saldo_fisico FROM core.cierre_detalles d WHERE d.cierre_id = v_cierre AND d.insumo_unidad_id = iu.id) AS sd,
               EXISTS (SELECT 1 FROM core.cierre_detalles d WHERE d.cierre_id = v_cierre AND d.insumo_unidad_id = iu.id) AS registrado,
               ant.saldo_fisico AS saldo_ant, ant.fecha_operativa AS fecha_ant
          FROM core.insumo_unidades iu
          JOIN core.insumos i            ON i.id = iu.insumo_id
          JOIN core.categorias_insumo ci ON ci.id = i.categoria_insumo_id
          JOIN core.unidades_medida um   ON um.id = i.unidad_medida_id
          LEFT JOIN LATERAL (
                SELECT d2.saldo_fisico, c2.fecha_operativa
                  FROM core.cierre_detalles d2
                  JOIN core.cierres_inventario c2 ON c2.id = d2.cierre_id
                 WHERE d2.insumo_unidad_id = iu.id AND c2.fecha_operativa < p_fecha
                 ORDER BY c2.fecha_operativa DESC LIMIT 1
          ) ant ON TRUE
         WHERE iu.unidad_id = p_unidad_id AND i.area_id = v_area
           AND (i.activo OR EXISTS (SELECT 1 FROM core.cierre_detalles d WHERE d.cierre_id = v_cierre AND d.insumo_unidad_id = iu.id))
    ),
    calc AS (
        SELECT it.*,
               core.fn_en_insumo(it.iu_id, COALESCE(it.fecha_ant, p_fecha - 1), p_fecha) AS en,
               core.fn_z_insumo(it.iu_id, COALESCE(it.fecha_ant, p_fecha - 1), p_fecha)  AS z,
               -- Sin conteo previo: el stock registrado, menos lo que entró desde esa jornada
               GREATEST(it.stock_actual - core.fn_en_insumo(it.iu_id, p_fecha - 1, 'infinity'::DATE), 0) AS stock_base
          FROM items it
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'codigo', codigo, 'nombre', nombre, 'categoria', categoria, 'unidad', unidad,
               'IN', CASE WHEN fecha_ant IS NOT NULL THEN saldo_ant ELSE stock_base END,
               'origenIN', CASE WHEN fecha_ant IS NOT NULL THEN 'cierre' WHEN stock_base > 0 THEN 'stock' ELSE 'sin-dato' END,
               'fuenteIN', fecha_ant,
               'EN', en, 'Z', z,
               'SD', CASE WHEN registrado THEN sd END,
               'registrado', registrado)
           ORDER BY codigo), '[]')
      INTO v_filas
      FROM calc;

    RETURN jsonb_build_object('unidad_id', p_unidad_id, 'fecha', p_fecha, 'area', p_area,
                              'cierre', CASE WHEN v_cierre IS NOT NULL THEN core.fn_cierre_json(v_cierre) END,
                              'cierre_anterior', v_ant, 'filas', v_filas);
END;
$$;


/* ============================================================================
   8. PERMISOS
   ============================================================================ */

REVOKE ALL ON FUNCTION core.fn_unidad_medida(TEXT), core.fn_categoria_insumo(INTEGER, TEXT),
                       core.fn_cantidad_entera(NUMERIC, TEXT, BOOLEAN), core.fn_cierre_json(BIGINT),
                       core.fn_z_insumo(INTEGER, DATE, DATE), core.fn_en_insumo(INTEGER, DATE, DATE)
       FROM PUBLIC;
REVOKE ALL ON FUNCTION core.fn_z_insumo(INTEGER, DATE, DATE), core.fn_en_insumo(INTEGER, DATE, DATE)
       FROM taseca_app, taseca_lectura;

REVOKE ALL ON PROCEDURE api.sp_guardar_insumo(INTEGER, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER[], INTEGER,
                                              BOOLEAN, NUMERIC, NUMERIC, INTEGER[], INTEGER),
                        api.sp_ajustar_stock_actual(INTEGER, INTEGER, NUMERIC, INTEGER),
                        api.sp_anular_entrada(BIGINT, VARCHAR, INTEGER),
                        api.sp_registrar_cierre(INTEGER, VARCHAR, JSONB, INTEGER, DATE, VARCHAR, VARCHAR, BOOLEAN, BIGINT),
                        api.sp_revisar_cierre(BIGINT, INTEGER),
                        api.sp_aplicar_cierre_a_stock(BIGINT, INTEGER, INTEGER),
                        api.sp_borrar_facturas_prueba(INTEGER, VARCHAR, INTEGER, INTEGER)
       FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE api.sp_guardar_insumo(INTEGER, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER[], INTEGER,
                                                 BOOLEAN, NUMERIC, NUMERIC, INTEGER[], INTEGER),
                           api.sp_ajustar_stock_actual(INTEGER, INTEGER, NUMERIC, INTEGER),
                           api.sp_anular_entrada(BIGINT, VARCHAR, INTEGER),
                           api.sp_registrar_cierre(INTEGER, VARCHAR, JSONB, INTEGER, DATE, VARCHAR, VARCHAR, BOOLEAN, BIGINT),
                           api.sp_revisar_cierre(BIGINT, INTEGER),
                           api.sp_aplicar_cierre_a_stock(BIGINT, INTEGER, INTEGER),
                           api.sp_borrar_facturas_prueba(INTEGER, VARCHAR, INTEGER, INTEGER)
      TO taseca_app;
GRANT SELECT ON api.v_entradas, api.v_cruce_inventario TO taseca_app, taseca_lectura;

GRANT SELECT ON rest.stock, rest.cierres, rest.entradas, rest.inventario_marca TO taseca_app;

REVOKE ALL ON FUNCTION rest.guardar_insumo(JSONB), rest.ajustar_stock(INTEGER, TEXT, NUMERIC),
                       rest.registrar_entrada(JSONB), rest.anular_entrada(BIGINT, TEXT), rest.corregir_entrada(BIGINT, JSONB),
                       rest.registrar_cierre(JSONB), rest.revisar_cierre(BIGINT), rest.aplicar_cierre_a_stock(BIGINT),
                       rest.cruce_inventario(INTEGER, DATE, TEXT)
       FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rest.guardar_insumo(JSONB), rest.ajustar_stock(INTEGER, TEXT, NUMERIC),
                          rest.registrar_entrada(JSONB), rest.anular_entrada(BIGINT, TEXT), rest.corregir_entrada(BIGINT, JSONB),
                          rest.registrar_cierre(JSONB), rest.revisar_cierre(BIGINT), rest.aplicar_cierre_a_stock(BIGINT),
                          rest.cruce_inventario(INTEGER, DATE, TEXT)
      TO taseca_app;

NOTIFY pgrst, 'reload schema';


/* ============================================================================
   14_FASE2_CAJA_GASTOS
   Fase 2 · base de caja, gastos y cruce
   ============================================================================ */

/* ============================================================================
   TASECA · 14 · FASE 2 · BLOQUE 4: BASE DE CAJA, GASTOS Y CRUCE DE CAJA
   ----------------------------------------------------------------------------
   Ejecutar conectado a taseca_db, después de 01 … 13. Se puede volver a
   ejecutar: todo es idempotente.

   QUÉ AGREGA
     · Gastos con todo lo que tiene la pantalla: concepto, proveedor o
       persona, observaciones, hora y consecutivo (G3-260915-001). Se editan
       mientras están registrados; confirmar y anular dejan quién y cuándo.
     · Base de caja con hora y motivo de corrección. Si ya hay una, no se
       reemplaza en silencio: hay que pedir la corrección y escribir el motivo.
     · rest.informe_caja: el cruce de caja de una jornada, calculado en la base.

   CORRIGE
     · El efectivo esperado (y el RC) se calculaba con lo VENDIDO. Ahora usa
       lo COBRADO, como la aplicación: un domicilio por transferencia sin
       confirmar no es plata que haya entrado. Lo vendido, lo cobrado, lo que
       falta por cobrar y las facturas anuladas se informan por separado.
     · Confirmar o anular un gasto no exigía que fuera de la empresa del
       usuario ni revisaba su estado.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. MODELO
   ============================================================================ */

ALTER TABLE core.gastos ADD COLUMN IF NOT EXISTS tercero         VARCHAR(160);
ALTER TABLE core.gastos ADD COLUMN IF NOT EXISTS observaciones   VARCHAR(400);
ALTER TABLE core.gastos ADD COLUMN IF NOT EXISTS hora            TIME;
ALTER TABLE core.gastos ADD COLUMN IF NOT EXISTS consecutivo_dia SMALLINT;
ALTER TABLE core.gastos ADD COLUMN IF NOT EXISTS confirmado_en   TIMESTAMPTZ;
ALTER TABLE core.gastos ADD COLUMN IF NOT EXISTS anulado_en      TIMESTAMPTZ;
COMMENT ON COLUMN core.gastos.descripcion IS 'El concepto del gasto (Carne de res 20 kg).';
COMMENT ON COLUMN core.gastos.consecutivo_dia IS 'Número del gasto en su unidad y jornada. El código G<unidad>-<AAMMDD>-<nnn> se arma en la vista.';

-- Los gastos anteriores reciben su número en el orden en que se crearon
UPDATE core.gastos g
   SET consecutivo_dia = x.n
  FROM (SELECT id, row_number() OVER (PARTITION BY unidad_id, fecha_operativa ORDER BY creado_en, id) AS n
          FROM core.gastos) x
 WHERE x.id = g.id AND g.consecutivo_dia IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_gastos_consecutivo ON core.gastos (unidad_id, fecha_operativa, consecutivo_dia);

ALTER TABLE core.bases_caja ADD COLUMN IF NOT EXISTS hora              TIME;
ALTER TABLE core.bases_caja ADD COLUMN IF NOT EXISTS motivo_correccion VARCHAR(300);
COMMENT ON COLUMN core.bases_caja.motivo_correccion IS 'Por qué esta base reemplaza a la anterior (reemplaza_a_id).';

-- Antes el motivo de la corrección se guardaba en observacion
UPDATE core.bases_caja
   SET motivo_correccion = observacion, observacion = NULL
 WHERE reemplaza_a_id IS NOT NULL AND motivo_correccion IS NULL;


/* ============================================================================
   2. VISTAS DE CAJA
   ============================================================================ */

-- Columnas nuevas al final (CREATE OR REPLACE no permite reordenar)
CREATE OR REPLACE VIEW api.v_gastos AS
SELECT g.id AS gasto_id, g.unidad_id, u.empresa_id, u.nombre AS unidad, g.fecha_operativa,
       cg.nombre AS categoria, cg.icono AS categoria_icono,
       mp.codigo AS metodo_pago, mp.nombre AS metodo_pago_nombre, mp.grupo_caja,
       eg.codigo AS estado, eg.nombre AS estado_nombre,
       g.descripcion, g.monto, g.motivo_anulacion,
       ur.nombre AS registrado_por, uc.nombre AS confirmado_por, ua.nombre AS anulado_por,
       g.creado_en,
       g.categoria_gasto_id, g.tercero, g.observaciones, g.hora,
       'G' || g.unidad_id || '-' || to_char(g.fecha_operativa, 'YYMMDD') || '-' || lpad(COALESCE(g.consecutivo_dia, 0)::TEXT, 3, '0') AS consecutivo,
       g.registrado_por_id, rr.codigo AS registrado_rol, g.confirmado_en, g.anulado_en, g.actualizado_en
  FROM core.gastos g
  JOIN core.unidades u          ON u.id = g.unidad_id
  JOIN core.categorias_gasto cg ON cg.id = g.categoria_gasto_id
  JOIN core.metodos_pago mp     ON mp.id = g.metodo_pago_id
  JOIN core.estados_gasto eg    ON eg.id = g.estado_gasto_id
  LEFT JOIN core.usuarios ur ON ur.id = g.registrado_por_id
  LEFT JOIN core.roles rr    ON rr.id = ur.rol_id
  LEFT JOIN core.usuarios uc ON uc.id = g.confirmado_por_id
  LEFT JOIN core.usuarios ua ON ua.id = g.anulado_por_id;

CREATE OR REPLACE VIEW api.v_bases_caja AS
SELECT b.id AS base_id, b.unidad_id, u.empresa_id, b.fecha_operativa, b.monto, b.vigente,
       b.reemplaza_a_id, b.observacion, us.nombre AS registrada_por, b.creado_en,
       b.hora, b.motivo_correccion, b.usuario_id, r.codigo AS rol, u.nombre AS unidad
  FROM core.bases_caja b
  JOIN core.unidades u ON u.id = b.unidad_id
  LEFT JOIN core.usuarios us ON us.id = b.usuario_id
  LEFT JOIN core.roles r     ON r.id = us.rol_id;

/* Cruce de caja de la jornada.

     efectivo_esperado = base + lo COBRADO en efectivo − gastos en efectivo
     (= RC, reposición de caja)

   Las columnas de antes conservan su nombre; ventas_* sigue siendo lo
   vendido (facturado). Lo cobrado, lo pendiente y lo anulado van al final. */
CREATE OR REPLACE VIEW api.v_cruce_caja AS
WITH jornadas AS (
    SELECT unidad_id, fecha_operativa FROM core.bases_caja WHERE vigente
    UNION
    SELECT unidad_id, fecha_operativa FROM core.pedidos
    UNION
    SELECT unidad_id, fecha_operativa FROM core.gastos
),
ventas AS (
    SELECT unidad_id, fecha_operativa,
           count(*)::NUMERIC                                                              AS pedidos,
           SUM(total) FILTER (WHERE grupo_caja = 'efectivo')                              AS efectivo,
           SUM(total) FILTER (WHERE grupo_caja = 'transferencia')                         AS transferencia,
           SUM(total) FILTER (WHERE grupo_caja = 'otros')                                 AS otros,
           SUM(total)                                                                     AS total,
           SUM(total) FILTER (WHERE estado_pago = 'confirmado' AND grupo_caja = 'efectivo')      AS cob_efectivo,
           SUM(total) FILTER (WHERE estado_pago = 'confirmado' AND grupo_caja = 'transferencia') AS cob_transferencia,
           SUM(total) FILTER (WHERE estado_pago = 'confirmado' AND grupo_caja = 'otros')         AS cob_otros,
           SUM(total) FILTER (WHERE estado_pago NOT IN ('confirmado', 'rechazado'))              AS por_cobrar,
           count(*)   FILTER (WHERE estado_pago NOT IN ('confirmado', 'rechazado'))              AS n_por_cobrar,
           SUM(total) FILTER (WHERE estado_pago = 'rechazado')                                   AS rechazado
      FROM api.v_pedidos
     WHERE cuenta_como_venta
     GROUP BY unidad_id, fecha_operativa
),
anuladas AS (
    SELECT unidad_id, fecha_operativa, count(*) AS n, SUM(total) AS total
      FROM api.v_pedidos
     WHERE estado = 'anulado'
     GROUP BY unidad_id, fecha_operativa
),
gastos AS (
    SELECT unidad_id, fecha_operativa,
           SUM(monto) FILTER (WHERE grupo_caja = 'efectivo')      AS efectivo,
           SUM(monto) FILTER (WHERE grupo_caja = 'transferencia') AS transferencia,
           SUM(monto) FILTER (WHERE grupo_caja = 'otros')         AS otros,
           SUM(monto)                                             AS total,
           count(*)   FILTER (WHERE estado = 'registrado')        AS pendientes
      FROM api.v_gastos
     WHERE estado <> 'anulado'
     GROUP BY unidad_id, fecha_operativa
)
SELECT j.unidad_id, u.empresa_id, u.nombre AS unidad, j.fecha_operativa,
       COALESCE(b.monto, 0)             AS base,
       COALESCE(v.pedidos, 0)           AS pedidos,
       COALESCE(v.efectivo, 0)          AS ventas_efectivo,
       COALESCE(v.transferencia, 0)     AS ventas_transferencia,
       COALESCE(v.otros, 0)             AS ventas_otros,
       COALESCE(v.total, 0)             AS ventas_total,
       COALESCE(g.efectivo, 0)          AS gastos_efectivo,
       COALESCE(g.total, 0)             AS gastos_total,
       COALESCE(b.monto, 0) + COALESCE(v.cob_efectivo, 0) - COALESCE(g.efectivo, 0) AS efectivo_esperado,
       COALESCE(v.cob_efectivo, 0)      AS cobrado_efectivo,
       COALESCE(v.cob_transferencia, 0) AS cobrado_transferencia,
       COALESCE(v.cob_otros, 0)         AS cobrado_otros,
       COALESCE(v.por_cobrar, 0)        AS por_cobrar,
       COALESCE(v.n_por_cobrar, 0)      AS pedidos_por_cobrar,
       COALESCE(v.rechazado, 0)         AS rechazado,
       COALESCE(a.n, 0)                 AS anuladas,
       COALESCE(a.total, 0)             AS anuladas_total,
       COALESCE(g.transferencia, 0)     AS gastos_transferencia,
       COALESCE(g.otros, 0)             AS gastos_otros,
       COALESCE(g.pendientes, 0)        AS gastos_pendientes,
       COALESCE(v.cob_transferencia, 0) - COALESCE(g.transferencia, 0) AS transferencias_netas,
       COALESCE(v.cob_otros, 0) - COALESCE(g.otros, 0)                 AS otros_netos
  FROM jornadas j
  JOIN core.unidades u ON u.id = j.unidad_id
  LEFT JOIN core.bases_caja b ON b.unidad_id = j.unidad_id AND b.fecha_operativa = j.fecha_operativa AND b.vigente
  LEFT JOIN ventas v   ON v.unidad_id = j.unidad_id AND v.fecha_operativa = j.fecha_operativa
  LEFT JOIN anuladas a ON a.unidad_id = j.unidad_id AND a.fecha_operativa = j.fecha_operativa
  LEFT JOIN gastos g   ON g.unidad_id = j.unidad_id AND g.fecha_operativa = j.fecha_operativa;


/* ============================================================================
   3. BASE DE CAJA
   ============================================================================ */

/* Se reemplaza la versión de 04.
     p_corregir NULL  → como antes: si ya hay base, p_observacion es el motivo
     p_corregir FALSE → si ya hay base, error (no se pisa sin querer)
     p_corregir TRUE  → corrección: exige p_motivo */
DROP PROCEDURE IF EXISTS api.sp_registrar_base_caja(INTEGER, NUMERIC, INTEGER, DATE, VARCHAR, BIGINT);

CREATE OR REPLACE PROCEDURE api.sp_registrar_base_caja(
    p_unidad_id    INTEGER,
    p_monto        NUMERIC,
    p_usuario_id   INTEGER,
    p_fecha        DATE    DEFAULT NULL,
    p_observacion  VARCHAR DEFAULT NULL,
    p_hora         TIME    DEFAULT NULL,
    p_corregir     BOOLEAN DEFAULT NULL,
    p_motivo       VARCHAR DEFAULT NULL,
    INOUT p_base_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_hoy      DATE := core.fn_fecha_operativa(core.fn_empresa_de_unidad(p_unidad_id), now());
    v_fecha    DATE := COALESCE(p_fecha, v_hoy);
    v_anterior BIGINT;
    v_motivo   VARCHAR;
    v_obs      VARCHAR := NULLIF(trim(COALESCE(p_observacion, '')), '');
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'base_caja', p_unidad_id);
    PERFORM core.fn_exigir_unidad_operativa(p_unidad_id);

    IF p_monto IS NULL OR p_monto < 0 THEN
        RAISE EXCEPTION 'El valor de la base debe ser un número mayor o igual que cero.';
    END IF;
    IF v_fecha > v_hoy THEN
        RAISE EXCEPTION 'No se puede registrar la base de una jornada que todavía no llega.';
    END IF;

    SELECT id INTO v_anterior FROM core.bases_caja
     WHERE unidad_id = p_unidad_id AND fecha_operativa = v_fecha AND vigente
       FOR UPDATE;

    IF v_anterior IS NOT NULL THEN
        IF p_corregir IS FALSE THEN
            RAISE EXCEPTION 'Ya hay una base registrada para esa jornada. Para cambiarla hay que corregirla.';
        END IF;
        v_motivo := trim(COALESCE(CASE WHEN p_corregir THEN p_motivo ELSE p_observacion END, ''));
        IF length(v_motivo) < 3 THEN
            RAISE EXCEPTION 'Para corregir la base hay que escribir el motivo.';
        END IF;
        IF p_corregir IS NULL THEN
            v_obs := NULL; -- en la forma antigua la observación ERA el motivo
        END IF;
        UPDATE core.bases_caja SET vigente = FALSE WHERE id = v_anterior;
    ELSIF p_corregir THEN
        RAISE EXCEPTION 'No hay una base que corregir en esa jornada.';
    END IF;

    INSERT INTO core.bases_caja (unidad_id, fecha_operativa, monto, reemplaza_a_id, observacion, usuario_id,
                                 hora, motivo_correccion)
    VALUES (p_unidad_id, v_fecha, p_monto, v_anterior, left(v_obs, 300), p_usuario_id,
            COALESCE(p_hora, (now() AT TIME ZONE COALESCE((SELECT zona_horaria FROM core.empresas
                                                              WHERE id = core.fn_empresa_de_unidad(p_unidad_id)), 'America/Bogota'))::TIME(0)),
            left(v_motivo, 300))
    RETURNING id INTO p_base_id;
END;
$$;


/* ============================================================================
   4. GASTOS
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.fn_validar_gasto(p_unidad_id INTEGER, p_categoria_gasto_id INTEGER, p_metodo_pago VARCHAR,
                                                 p_descripcion VARCHAR, p_monto NUMERIC, p_fecha DATE)
RETURNS VOID
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    PERFORM core.fn_exigir_unidad_operativa(p_unidad_id);
    IF p_fecha IS NULL THEN
        RAISE EXCEPTION 'El gasto necesita una fecha válida.';
    END IF;
    IF p_fecha > core.fn_fecha_operativa(core.fn_empresa_de_unidad(p_unidad_id), now()) THEN
        RAISE EXCEPTION 'El gasto no puede ser de una jornada futura.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.categorias_gasto
                    WHERE id = p_categoria_gasto_id AND empresa_id = core.fn_empresa_de_unidad(p_unidad_id)) THEN
        RAISE EXCEPTION 'Elige una categoría para el gasto.';
    END IF;
    IF length(trim(COALESCE(p_descripcion, ''))) < 3 THEN
        RAISE EXCEPTION 'Escribe en qué se gastó el dinero (mínimo 3 caracteres).';
    END IF;
    IF p_monto IS NULL OR p_monto <= 0 THEN
        RAISE EXCEPTION 'El valor debe ser un número mayor que cero.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.metodos_pago WHERE codigo = p_metodo_pago) THEN
        RAISE EXCEPTION 'Elige un método de pago válido.';
    END IF;
END;
$$;

/* Se reemplaza la versión de 04: más datos, validaciones y consecutivo. */
DROP PROCEDURE IF EXISTS api.sp_registrar_gasto(INTEGER, INTEGER, VARCHAR, VARCHAR, NUMERIC, INTEGER, DATE, BIGINT);

CREATE OR REPLACE PROCEDURE api.sp_registrar_gasto(
    p_unidad_id           INTEGER,
    p_categoria_gasto_id  INTEGER,
    p_metodo_pago         VARCHAR,
    p_descripcion         VARCHAR,
    p_monto               NUMERIC,
    p_usuario_id          INTEGER,
    p_fecha               DATE    DEFAULT NULL,
    p_hora                TIME    DEFAULT NULL,
    p_tercero             VARCHAR DEFAULT NULL,
    p_observaciones       VARCHAR DEFAULT NULL,
    INOUT p_gasto_id      BIGINT  DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_fecha DATE := COALESCE(p_fecha, core.fn_fecha_operativa(core.fn_empresa_de_unidad(p_unidad_id), now()));
    v_n     SMALLINT;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'gastos', p_unidad_id);
    PERFORM core.fn_validar_gasto(p_unidad_id, p_categoria_gasto_id, p_metodo_pago, p_descripcion, p_monto, v_fecha);

    -- Consecutivo del día en la unidad (el bloqueo evita dos iguales a la vez)
    PERFORM pg_advisory_xact_lock(hashtext('gasto|' || p_unidad_id || '|' || v_fecha));
    SELECT COALESCE(max(consecutivo_dia), 0) + 1 INTO v_n
      FROM core.gastos WHERE unidad_id = p_unidad_id AND fecha_operativa = v_fecha;

    INSERT INTO core.gastos (unidad_id, categoria_gasto_id, metodo_pago_id, estado_gasto_id, fecha_operativa,
                             descripcion, monto, registrado_por_id, hora, tercero, observaciones, consecutivo_dia)
    VALUES (p_unidad_id, p_categoria_gasto_id, core.fn_id_catalogo('metodos_pago', p_metodo_pago),
            core.fn_id_catalogo('estados_gasto', 'registrado'), v_fecha, left(trim(p_descripcion), 300), p_monto,
            p_usuario_id, p_hora, NULLIF(left(trim(COALESCE(p_tercero, '')), 160), ''),
            NULLIF(left(trim(COALESCE(p_observaciones, '')), 400), ''), v_n)
    RETURNING id INTO p_gasto_id;
END;
$$;

/* Editar: sólo mientras el gasto está registrado. No cambia de unidad. */
CREATE OR REPLACE PROCEDURE api.sp_actualizar_gasto(
    p_gasto_id            BIGINT,
    p_categoria_gasto_id  INTEGER,
    p_metodo_pago         VARCHAR,
    p_descripcion         VARCHAR,
    p_monto               NUMERIC,
    p_usuario_id          INTEGER,
    p_fecha               DATE    DEFAULT NULL,
    p_hora                TIME    DEFAULT NULL,
    p_tercero             VARCHAR DEFAULT NULL,
    p_observaciones       VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_gasto  core.gastos;
    v_estado VARCHAR;
    v_fecha  DATE;
    v_n      SMALLINT;
BEGIN
    SELECT * INTO v_gasto FROM core.gastos WHERE id = p_gasto_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontró el gasto.';
    END IF;
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'gastos', v_gasto.unidad_id);

    SELECT codigo INTO v_estado FROM core.estados_gasto WHERE id = v_gasto.estado_gasto_id;
    IF v_estado <> 'registrado' THEN
        RAISE EXCEPTION 'Un gasto % ya no se puede editar.', v_estado;
    END IF;

    v_fecha := COALESCE(p_fecha, v_gasto.fecha_operativa);
    PERFORM core.fn_validar_gasto(v_gasto.unidad_id, p_categoria_gasto_id, p_metodo_pago, p_descripcion, p_monto, v_fecha);

    v_n := v_gasto.consecutivo_dia;
    IF v_fecha <> v_gasto.fecha_operativa THEN
        PERFORM pg_advisory_xact_lock(hashtext('gasto|' || v_gasto.unidad_id || '|' || v_fecha));
        SELECT COALESCE(max(consecutivo_dia), 0) + 1 INTO v_n
          FROM core.gastos WHERE unidad_id = v_gasto.unidad_id AND fecha_operativa = v_fecha;
    END IF;

    UPDATE core.gastos
       SET categoria_gasto_id = p_categoria_gasto_id,
           metodo_pago_id     = core.fn_id_catalogo('metodos_pago', p_metodo_pago),
           descripcion        = left(trim(p_descripcion), 300),
           monto              = p_monto,
           fecha_operativa    = v_fecha,
           consecutivo_dia    = v_n,
           hora               = COALESCE(p_hora, hora),
           tercero            = NULLIF(left(trim(COALESCE(p_tercero, '')), 160), ''),
           observaciones      = NULLIF(left(trim(COALESCE(p_observaciones, '')), 400), ''),
           actualizado_en     = now()
     WHERE id = p_gasto_id;
END;
$$;

/* Misma firma que en 04; ahora revisa el estado y deja la fecha. */
CREATE OR REPLACE PROCEDURE api.sp_confirmar_gasto(p_gasto_id BIGINT, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_estado VARCHAR;
    v_unidad INTEGER;
BEGIN
    SELECT eg.codigo, g.unidad_id INTO v_estado, v_unidad
      FROM core.gastos g JOIN core.estados_gasto eg ON eg.id = g.estado_gasto_id
     WHERE g.id = p_gasto_id FOR UPDATE OF g;
    IF v_unidad IS NULL THEN
        RAISE EXCEPTION 'No se encontró el gasto.';
    END IF;
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'gastos_confirmar', v_unidad);

    IF v_estado = 'anulado' THEN
        RAISE EXCEPTION 'Un gasto anulado no se puede confirmar.';
    ELSIF v_estado = 'confirmado' THEN
        RETURN;
    END IF;
    UPDATE core.gastos
       SET estado_gasto_id = core.fn_id_catalogo('estados_gasto', 'confirmado'),
           confirmado_por_id = p_usuario_id, confirmado_en = now(), actualizado_en = now()
     WHERE id = p_gasto_id;
END;
$$;

/* Misma firma que en 04; ahora revisa el estado, el motivo y deja la fecha. */
CREATE OR REPLACE PROCEDURE api.sp_anular_gasto(p_gasto_id BIGINT, p_motivo VARCHAR, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_estado VARCHAR;
    v_unidad INTEGER;
BEGIN
    SELECT eg.codigo, g.unidad_id INTO v_estado, v_unidad
      FROM core.gastos g JOIN core.estados_gasto eg ON eg.id = g.estado_gasto_id
     WHERE g.id = p_gasto_id FOR UPDATE OF g;
    IF v_unidad IS NULL THEN
        RAISE EXCEPTION 'No se encontró el gasto.';
    END IF;
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'gastos_anular', v_unidad);

    IF v_estado = 'anulado' THEN
        RETURN;
    END IF;
    IF length(trim(COALESCE(p_motivo, ''))) < 4 THEN
        RAISE EXCEPTION 'Escribe por qué se anula el gasto.';
    END IF;
    UPDATE core.gastos
       SET estado_gasto_id = core.fn_id_catalogo('estados_gasto', 'anulado'),
           motivo_anulacion = left(trim(p_motivo), 300), anulado_por_id = p_usuario_id,
           anulado_en = now(), actualizado_en = now()
     WHERE id = p_gasto_id;
END;
$$;


/* ============================================================================
   5. API REST · LECTURA
   Todo filtrado por la empresa del token, las unidades del usuario y sus
   permisos. Gastos y bases: los últimos 93 días (lo anterior, con ?desde).
   ============================================================================ */

CREATE OR REPLACE VIEW rest.categorias_gasto AS
SELECT c.id AS categoria_gasto_id, c.empresa_id, c.nombre, c.icono, c.activa
  FROM core.categorias_gasto c
 WHERE c.empresa_id = core.fn_jwt_empresa();

CREATE OR REPLACE VIEW rest.gastos AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_usuario() AS usuario_id, core.fn_jwt_empresa() AS empresa_id
)
SELECT g.gasto_id, g.empresa_id, g.unidad_id, g.fecha_operativa, g.hora, g.consecutivo,
       g.categoria_gasto_id, g.metodo_pago, g.estado, g.descripcion, g.tercero, g.observaciones, g.monto,
       g.registrado_por_id, g.registrado_por, g.registrado_rol, g.confirmado_por, g.confirmado_en,
       g.anulado_por, g.anulado_en, g.motivo_anulacion, g.creado_en, g.actualizado_en
  FROM api.v_gastos g
  JOIN sesion s ON s.empresa_id = g.empresa_id
 WHERE core.fn_usuario_en_unidad(s.usuario_id, g.unidad_id)
   AND EXISTS (SELECT 1 FROM unnest(ARRAY['gastos', 'gastos_confirmar', 'gastos_anular', 'informe']) p
                WHERE api.fn_tiene_permiso(s.usuario_id, p));

CREATE OR REPLACE VIEW rest.bases_caja AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_usuario() AS usuario_id, core.fn_jwt_empresa() AS empresa_id
)
SELECT b.base_id, b.empresa_id, b.unidad_id, b.unidad, b.fecha_operativa, b.hora, b.monto, b.vigente,
       b.reemplaza_a_id, b.observacion, b.motivo_correccion, b.usuario_id, b.registrada_por, b.rol, b.creado_en
  FROM api.v_bases_caja b
  JOIN sesion s ON s.empresa_id = b.empresa_id
 WHERE core.fn_usuario_en_unidad(s.usuario_id, b.unidad_id)
   AND EXISTS (SELECT 1 FROM unnest(ARRAY['base_caja', 'informe']) p
                WHERE api.fn_tiene_permiso(s.usuario_id, p));

/* Última modificación de gastos y bases de la empresa: la app recarga sólo si cambió. */
CREATE OR REPLACE VIEW rest.caja_marca AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_empresa() AS empresa_id
)
SELECT s.empresa_id,
       GREATEST(
           (SELECT max(g.actualizado_en) FROM core.gastos g JOIN core.unidades u ON u.id = g.unidad_id
             WHERE u.empresa_id = s.empresa_id),
           (SELECT max(b.creado_en) FROM core.bases_caja b JOIN core.unidades u ON u.id = b.unidad_id
             WHERE u.empresa_id = s.empresa_id)
       ) AS marca
  FROM sesion s
 WHERE s.empresa_id IS NOT NULL;


/* ============================================================================
   6. API REST · FUNCIONES
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.fn_gasto_json(p_gasto_id BIGINT)
RETURNS JSONB
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT to_jsonb(g) FROM rest.gastos g WHERE g.gasto_id = p_gasto_id;
$$;

CREATE OR REPLACE FUNCTION core.fn_unidad_de_sesion(p_unidad_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    IF core.fn_empresa_de_unidad(p_unidad_id) IS DISTINCT FROM core.fn_jwt_empresa() THEN
        RAISE EXCEPTION 'La unidad % no es de esta empresa.', p_unidad_id USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN p_unidad_id;
END;
$$;

CREATE OR REPLACE FUNCTION core.fn_gasto_de_sesion(p_gasto_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.gastos g JOIN core.unidades u ON u.id = g.unidad_id
                    WHERE g.id = p_gasto_id AND u.empresa_id = core.fn_jwt_empresa()) THEN
        RAISE EXCEPTION 'No se encontró el gasto.';
    END IF;
    RETURN p_gasto_id;
END;
$$;

/* POST /rpc/registrar_base { "p_base": { unidad_id, fecha, monto, hora, observaciones, corregir, motivo } } */
CREATE OR REPLACE FUNCTION rest.registrar_base(p_base JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_unidad  INTEGER := core.fn_unidad_de_sesion(NULLIF(p_base ->> 'unidad_id', '')::INTEGER);
    v_id      BIGINT;
BEGIN
    CALL api.sp_registrar_base_caja(
        p_unidad_id   => v_unidad,
        p_monto       => NULLIF(p_base ->> 'monto', '')::NUMERIC,
        p_usuario_id  => v_usuario,
        p_fecha       => NULLIF(p_base ->> 'fecha', '')::DATE,
        p_observacion => p_base ->> 'observaciones',
        p_hora        => NULLIF(p_base ->> 'hora', '')::TIME,
        p_corregir    => COALESCE((p_base ->> 'corregir')::BOOLEAN, FALSE),
        p_motivo      => p_base ->> 'motivo',
        p_base_id     => v_id);
    RETURN (SELECT to_jsonb(b) FROM rest.bases_caja b WHERE b.base_id = v_id);
END;
$$;

/* POST /rpc/guardar_gasto { "p_gasto": { gasto_id|null, unidad_id, fecha, hora, categoria_gasto_id,
   metodo_pago, descripcion, tercero, observaciones, monto } } */
CREATE OR REPLACE FUNCTION rest.guardar_gasto(p_gasto JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_id      BIGINT  := NULLIF(p_gasto ->> 'gasto_id', '')::BIGINT;
    v_unidad  INTEGER;
BEGIN
    IF v_id IS NULL THEN
        v_unidad := core.fn_unidad_de_sesion(NULLIF(p_gasto ->> 'unidad_id', '')::INTEGER);
        CALL api.sp_registrar_gasto(
            p_unidad_id          => v_unidad,
            p_categoria_gasto_id => NULLIF(p_gasto ->> 'categoria_gasto_id', '')::INTEGER,
            p_metodo_pago        => p_gasto ->> 'metodo_pago',
            p_descripcion        => p_gasto ->> 'descripcion',
            p_monto              => NULLIF(p_gasto ->> 'monto', '')::NUMERIC,
            p_usuario_id         => v_usuario,
            p_fecha              => NULLIF(p_gasto ->> 'fecha', '')::DATE,
            p_hora               => NULLIF(p_gasto ->> 'hora', '')::TIME,
            p_tercero            => p_gasto ->> 'tercero',
            p_observaciones      => p_gasto ->> 'observaciones',
            p_gasto_id           => v_id);
    ELSE
        PERFORM core.fn_gasto_de_sesion(v_id);
        CALL api.sp_actualizar_gasto(
            p_gasto_id           => v_id,
            p_categoria_gasto_id => NULLIF(p_gasto ->> 'categoria_gasto_id', '')::INTEGER,
            p_metodo_pago        => p_gasto ->> 'metodo_pago',
            p_descripcion        => p_gasto ->> 'descripcion',
            p_monto              => NULLIF(p_gasto ->> 'monto', '')::NUMERIC,
            p_usuario_id         => v_usuario,
            p_fecha              => NULLIF(p_gasto ->> 'fecha', '')::DATE,
            p_hora               => NULLIF(p_gasto ->> 'hora', '')::TIME,
            p_tercero            => p_gasto ->> 'tercero',
            p_observaciones      => p_gasto ->> 'observaciones');
    END IF;
    RETURN core.fn_gasto_json(v_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.confirmar_gasto(p_gasto_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    CALL api.sp_confirmar_gasto(core.fn_gasto_de_sesion(p_gasto_id), core.fn_exigir_sesion());
    RETURN core.fn_gasto_json(p_gasto_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.anular_gasto(p_gasto_id BIGINT, p_motivo TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    CALL api.sp_anular_gasto(core.fn_gasto_de_sesion(p_gasto_id), p_motivo, core.fn_exigir_sesion());
    RETURN core.fn_gasto_json(p_gasto_id);
END;
$$;

/* EL CRUCE DE CAJA de una jornada, en la forma que usa la aplicación.
   p_unidad_id NULL = todas las unidades del usuario (la base es la suma). */
CREATE OR REPLACE FUNCTION rest.informe_caja(p_fecha DATE, p_unidad_id INTEGER DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario  INTEGER := core.fn_exigir_sesion();
    v_empresa  INTEGER := core.fn_jwt_empresa();
    v_unidades INTEGER[];
    v_ventas   JSONB;
    v_anuladas JSONB;
    v_gastos   JSONB;
    v_base     JSONB;
    v_valor    NUMERIC;
BEGIN
    IF NOT (core.fn_tiene_permiso(v_usuario, 'informe') OR core.fn_tiene_permiso(v_usuario, 'base_caja')) THEN
        RAISE EXCEPTION 'Tu perfil no puede ver el cruce de caja.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF p_unidad_id IS NOT NULL THEN
        PERFORM core.fn_unidad_de_sesion(p_unidad_id);
        IF NOT core.fn_usuario_en_unidad(v_usuario, p_unidad_id) THEN
            RAISE EXCEPTION 'No trabajas en esa unidad.' USING ERRCODE = 'insufficient_privilege';
        END IF;
    END IF;

    SELECT array_agg(u.id) INTO v_unidades
      FROM core.unidades u
     WHERE u.empresa_id = v_empresa
       AND (p_unidad_id IS NULL OR u.id = p_unidad_id)
       AND core.fn_usuario_en_unidad(v_usuario, u.id);

    -- Ventas efectivas por método: vendido, cobrado, pendiente y rechazado
    SELECT COALESCE(jsonb_object_agg(metodo_pago, jsonb_build_object(
               'grupo', grupo_caja, 'n', n, 'vendido', vendido, 'cobrado', cobrado,
               'pendiente', pendiente, 'nPendiente', n_pendiente, 'rechazado', rechazado)), '{}')
      INTO v_ventas
      FROM (SELECT metodo_pago, grupo_caja, count(*) AS n, SUM(total) AS vendido,
                   COALESCE(SUM(total) FILTER (WHERE estado_pago = 'confirmado'), 0) AS cobrado,
                   COALESCE(SUM(total) FILTER (WHERE estado_pago NOT IN ('confirmado', 'rechazado')), 0) AS pendiente,
                   count(*) FILTER (WHERE estado_pago NOT IN ('confirmado', 'rechazado')) AS n_pendiente,
                   COALESCE(SUM(total) FILTER (WHERE estado_pago = 'rechazado'), 0) AS rechazado
              FROM api.v_pedidos
             WHERE unidad_id = ANY (v_unidades) AND fecha_operativa = p_fecha AND cuenta_como_venta
             GROUP BY metodo_pago, grupo_caja) x;

    SELECT COALESCE(jsonb_object_agg(metodo_pago, jsonb_build_object('grupo', grupo_caja, 'n', n, 'total', total)), '{}')
      INTO v_anuladas
      FROM (SELECT metodo_pago, grupo_caja, count(*) AS n, SUM(total) AS total
              FROM api.v_pedidos
             WHERE unidad_id = ANY (v_unidades) AND fecha_operativa = p_fecha AND estado = 'anulado'
             GROUP BY metodo_pago, grupo_caja) x;

    SELECT COALESCE(jsonb_object_agg(metodo_pago, jsonb_build_object(
               'grupo', grupo_caja, 'n', n, 'total', total, 'pendientes', pendientes, 'montoPendiente', monto_pendiente)), '{}')
      INTO v_gastos
      FROM (SELECT metodo_pago, grupo_caja, count(*) AS n, SUM(monto) AS total,
                   count(*) FILTER (WHERE estado = 'registrado') AS pendientes,
                   COALESCE(SUM(monto) FILTER (WHERE estado = 'registrado'), 0) AS monto_pendiente
              FROM api.v_gastos
             WHERE unidad_id = ANY (v_unidades) AND fecha_operativa = p_fecha AND estado <> 'anulado'
             GROUP BY metodo_pago, grupo_caja) x;

    SELECT COALESCE(SUM(monto), 0) INTO v_valor
      FROM core.bases_caja WHERE unidad_id = ANY (v_unidades) AND fecha_operativa = p_fecha AND vigente;
    IF p_unidad_id IS NOT NULL THEN
        SELECT to_jsonb(b) INTO v_base FROM rest.bases_caja b
         WHERE b.unidad_id = p_unidad_id AND b.fecha_operativa = p_fecha AND b.vigente;
    END IF;

    RETURN jsonb_build_object(
        'jornada', p_fecha, 'unidad_id', p_unidad_id,
        'base', jsonb_build_object('valor', v_valor, 'registro', v_base),
        'ventas', v_ventas, 'anuladas', v_anuladas, 'gastos', v_gastos);
END;
$$;


/* ============================================================================
   7. PERMISOS
   ============================================================================ */

REVOKE ALL ON FUNCTION core.fn_validar_gasto(INTEGER, INTEGER, VARCHAR, VARCHAR, NUMERIC, DATE),
                       core.fn_gasto_json(BIGINT), core.fn_unidad_de_sesion(INTEGER), core.fn_gasto_de_sesion(BIGINT)
       FROM PUBLIC;

REVOKE ALL ON PROCEDURE api.sp_registrar_base_caja(INTEGER, NUMERIC, INTEGER, DATE, VARCHAR, TIME, BOOLEAN, VARCHAR, BIGINT),
                        api.sp_registrar_gasto(INTEGER, INTEGER, VARCHAR, VARCHAR, NUMERIC, INTEGER, DATE, TIME, VARCHAR, VARCHAR, BIGINT),
                        api.sp_actualizar_gasto(BIGINT, INTEGER, VARCHAR, VARCHAR, NUMERIC, INTEGER, DATE, TIME, VARCHAR, VARCHAR),
                        api.sp_confirmar_gasto(BIGINT, INTEGER),
                        api.sp_anular_gasto(BIGINT, VARCHAR, INTEGER)
       FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE api.sp_registrar_base_caja(INTEGER, NUMERIC, INTEGER, DATE, VARCHAR, TIME, BOOLEAN, VARCHAR, BIGINT),
                           api.sp_registrar_gasto(INTEGER, INTEGER, VARCHAR, VARCHAR, NUMERIC, INTEGER, DATE, TIME, VARCHAR, VARCHAR, BIGINT),
                           api.sp_actualizar_gasto(BIGINT, INTEGER, VARCHAR, VARCHAR, NUMERIC, INTEGER, DATE, TIME, VARCHAR, VARCHAR),
                           api.sp_confirmar_gasto(BIGINT, INTEGER),
                           api.sp_anular_gasto(BIGINT, VARCHAR, INTEGER)
      TO taseca_app;
GRANT SELECT ON api.v_gastos, api.v_bases_caja, api.v_cruce_caja TO taseca_app, taseca_lectura;

GRANT SELECT ON rest.categorias_gasto, rest.gastos, rest.bases_caja, rest.caja_marca TO taseca_app;

REVOKE ALL ON FUNCTION rest.registrar_base(JSONB), rest.guardar_gasto(JSONB), rest.confirmar_gasto(BIGINT),
                       rest.anular_gasto(BIGINT, TEXT), rest.informe_caja(DATE, INTEGER)
       FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rest.registrar_base(JSONB), rest.guardar_gasto(JSONB), rest.confirmar_gasto(BIGINT),
                          rest.anular_gasto(BIGINT, TEXT), rest.informe_caja(DATE, INTEGER)
      TO taseca_app;

NOTIFY pgrst, 'reload schema';


/* ============================================================================
   15_FASE2_CONFIGURACION_PLATAFORMA
   Fase 2 · configuración, ajustes y plataforma
   ============================================================================ */

/* ============================================================================
   TASECA · 15 · FASE 2 · BLOQUE 5: CONFIGURACIÓN, AJUSTES Y PANEL DE TASECA
   ----------------------------------------------------------------------------
   Ejecutar conectado a taseca_db, después de 01 … 14. Se puede volver a
   ejecutar: todo es idempotente.

   QUÉ AGREGA
     · La EMPRESA completa para la aplicación: ficha, módulos, tema (colores,
       tipografía, logotipo, iniciales, lema, logo e ícono), contacto, cuentas
       para transferir, tiempos, hora de corte, redes y métodos de pago. Antes
       el portal y el panel los tomaban del navegador.
     · Configuración del Admin de la empresa: datos del negocio y métodos de
       pago (siempre al menos uno activo).
     · Facturas de prueba: contarlas y borrarlas desde Ajustes.
     · PANEL DE TASECA sobre la base: lista de empresas, alta completa en una
       transacción (ficha, primera unidad, módulos, tema, métodos de pago,
       categorías de gasto, numeración y administrador), edición, tema,
       módulos, activar/desactivar y ENTRAR a una empresa (token nuevo con esa
       empresa; el SuperAdmin sigue siendo SuperAdmin).

   SEGURIDAD
     Todo lo de plataforma exige el permiso 'plataforma' del usuario del token.
     El Admin de una empresa sólo cambia SU configuración, nunca módulos ni
     tema. Las imágenes van en su propia tabla y viajan sólo cuando cambian.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. MODELO
   ============================================================================ */

ALTER TABLE core.empresas ADD COLUMN IF NOT EXISTS tipografia  VARCHAR(30);
ALTER TABLE core.empresas ADD COLUMN IF NOT EXISTS logo_texto  VARCHAR(24);
ALTER TABLE core.empresas ADD COLUMN IF NOT EXISTS logo_acento VARCHAR(24);
ALTER TABLE core.empresas ADD COLUMN IF NOT EXISTS iniciales   VARCHAR(3);
ALTER TABLE core.empresas ADD COLUMN IF NOT EXISTS lema        VARCHAR(80);
ALTER TABLE core.empresas ADD COLUMN IF NOT EXISTS plantilla   VARCHAR(30);
COMMENT ON COLUMN core.empresas.tipografia IS 'Id de la lista cerrada de tipografías de la aplicación (NASCAR.TIPOGRAFIAS).';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_empresas_tipografia') THEN
        ALTER TABLE core.empresas
            ADD CONSTRAINT ck_empresas_tipografia CHECK (tipografia IS NULL OR tipografia ~ '^[a-z0-9_-]{1,30}$');
    END IF;
END;
$$;

/* Logo e ícono de la empresa (1 a 1). Aparte, como los logos de unidad: la
   ficha de la empresa se consulta a menudo y las imágenes pesan. */
CREATE TABLE IF NOT EXISTS core.empresa_imagenes (
    id              SERIAL PRIMARY KEY,
    empresa_id      INTEGER     NOT NULL UNIQUE REFERENCES core.empresas (id) ON DELETE CASCADE,
    logo            TEXT,
    favicon         TEXT,
    actualizado_en  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_empresa_imagenes_logo    CHECK (logo    IS NULL OR (logo    ~ '^data:image/(png|jpeg|jpg|webp|gif);base64,' AND length(logo)    <= 200000)),
    CONSTRAINT ck_empresa_imagenes_favicon CHECK (favicon IS NULL OR (favicon ~ '^data:image/(png|jpeg|jpg|webp|gif);base64,' AND length(favicon) <= 60000))
);
REVOKE ALL ON core.empresa_imagenes FROM PUBLIC;

-- El tema con el que NASCAR ha funcionado siempre (antes vivía en data.js)
UPDATE core.empresas
   SET tipografia = 'barlow', logo_texto = 'NAS', logo_acento = 'CAR', iniciales = 'NA',
       lema = 'Parrilla, tradicional y domicilios'
 WHERE codigo = 'empresa_nascar' AND tipografia IS NULL;


/* ============================================================================
   2. LA EMPRESA COMO LA USA LA APLICACIÓN
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_empresa_ficha AS
SELECT e.id AS empresa_id, e.codigo, e.nombre_comercial, e.razon_social, e.nit, e.eslogan, e.descripcion,
       e.estado, e.hora_corte_operativa, e.telefono, e.whatsapp, e.email, e.direccion, e.horario_general,
       e.instagram_url, e.facebook_url, e.tiempo_mesa, e.tiempo_domicilio,
       e.color_primario, e.color_secundario, e.color_acento, e.color_fondo,
       e.tipografia, e.logo_texto, e.logo_acento, e.iniciales, e.lema, e.plantilla, e.creado_en,
       core.fn_fecha_operativa(e.id, now()) AS jornada_actual,
       (SELECT i.actualizado_en FROM core.empresa_imagenes i WHERE i.empresa_id = e.id) AS imagenes_version,
       (SELECT jsonb_object_agg(m.modulo, m.activo) FROM api.v_empresa_modulos m WHERE m.empresa_id = e.id) AS modulos,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('codigo', mp.codigo, 'nombre', mp.nombre, 'grupo', mp.grupo_caja,
                                                     'descripcion', emp.descripcion, 'activo', emp.activo)
                                  ORDER BY emp.orden, mp.id)
                   FROM core.empresa_metodos_pago emp
                   JOIN core.metodos_pago mp ON mp.id = emp.metodo_pago_id
                  WHERE emp.empresa_id = e.id), '[]') AS metodos_pago,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('entidad', c.entidad, 'numero', c.numero, 'titular', c.titular)
                                  ORDER BY c.id)
                   FROM core.cuentas_recaudo c
                  WHERE c.empresa_id = e.id AND c.activa), '[]') AS cuentas,
       (SELECT count(*) FROM core.unidades u WHERE u.empresa_id = e.id) AS n_unidades,
       (SELECT count(*) FROM core.usuarios us WHERE us.empresa_id = e.id) AS n_usuarios
  FROM core.empresas e;

/* Portal y panel: sólo empresas activas. Columnas nuevas al final. */
CREATE OR REPLACE VIEW rest.empresas AS
SELECT v.empresa_id, v.codigo, v.nombre_comercial, v.eslogan, v.telefono, v.whatsapp, v.email, v.direccion,
       v.horario_general, v.tiempo_mesa, v.tiempo_domicilio, v.color_primario, v.color_secundario, v.color_acento,
       v.color_fondo, e.logo_url, v.hora_corte_operativa, v.jornada_actual,
       v.razon_social, v.nit, v.descripcion, v.instagram_url, v.facebook_url, v.tipografia, v.logo_texto,
       v.logo_acento, v.iniciales, v.lema, v.plantilla, v.estado, v.creado_en, v.imagenes_version,
       v.modulos, v.metodos_pago, v.cuentas
  FROM api.v_empresa_ficha v
  JOIN core.empresas e ON e.id = v.empresa_id
 WHERE v.estado = 'activa';

CREATE OR REPLACE VIEW rest.empresa_imagenes AS
SELECT i.empresa_id, i.logo, i.favicon, i.actualizado_en AS imagenes_version
  FROM core.empresa_imagenes i
  JOIN core.empresas e ON e.id = i.empresa_id;

/* Panel de Taseca: TODAS las empresas, con cuántas unidades y usuarios. */
CREATE OR REPLACE VIEW rest.plataforma_empresas AS
SELECT v.*
  FROM api.v_empresa_ficha v
 WHERE api.fn_tiene_permiso(core.fn_jwt_usuario(), 'plataforma');

CREATE OR REPLACE VIEW rest.plataforma_usuarios AS
SELECT u.usuario_id, u.empresa_id, e.codigo AS empresa_codigo, u.nombre, u.usuario, u.rol, u.activo,
       u.unidades_asignadas AS unidades
  FROM api.v_usuarios u
  JOIN core.empresas e ON e.id = u.empresa_id
 WHERE u.alcance = 'empresa'
   AND api.fn_tiene_permiso(core.fn_jwt_usuario(), 'plataforma');


/* ============================================================================
   3. CONFIGURACIÓN DE LA EMPRESA (Admin)
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.fn_texto(p_valor TEXT, p_max INTEGER)
RETURNS TEXT
LANGUAGE sql IMMUTABLE
AS $$
    SELECT NULLIF(left(regexp_replace(trim(COALESCE(p_valor, '')), '\s+', ' ', 'g'), p_max), '');
$$;

/* Datos del negocio. p_cuentas: [{"entidad": "Nequi", "numero": "300…", "titular": "…"}]
   reemplaza las cuentas activas (las que no vienen quedan inactivas). */
CREATE OR REPLACE PROCEDURE api.sp_guardar_configuracion(
    p_empresa_id    INTEGER,
    p_usuario_id    INTEGER,
    p_datos         JSONB,
    p_cuentas       JSONB DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre  TEXT := core.fn_texto(p_datos ->> 'nombre_comercial', 120);
    v_corte   INTEGER;
    v_wa      TEXT := NULLIF(regexp_replace(COALESCE(p_datos ->> 'whatsapp', ''), '\D', '', 'g'), '');
    v_nit     TEXT := core.fn_texto(p_datos ->> 'nit', 20);
    v_cuenta  JSONB;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'config_local');
    PERFORM core.fn_exigir_empresa_propia(p_usuario_id, p_empresa_id);

    IF v_nombre IS NULL OR length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'La empresa necesita un nombre comercial.';
    END IF;
    IF v_wa IS NOT NULL AND length(v_wa) < 10 THEN
        RAISE EXCEPTION 'El WhatsApp debe incluir el indicativo del país. Ej. 573001112233';
    END IF;
    v_corte := COALESCE(NULLIF(p_datos ->> 'hora_corte_operativa', '')::NUMERIC::INTEGER,
                        (SELECT hora_corte_operativa FROM core.empresas WHERE id = p_empresa_id));
    IF v_corte NOT BETWEEN 0 AND 23 THEN
        RAISE EXCEPTION 'La hora en que empieza el día siguiente debe estar entre 0 y 23.';
    END IF;
    IF v_nit IS NOT NULL AND EXISTS (SELECT 1 FROM core.empresas WHERE nit = v_nit AND id <> p_empresa_id) THEN
        RAISE EXCEPTION 'Ya hay otra empresa con el NIT %.', v_nit;
    END IF;

    UPDATE core.empresas
       SET nombre_comercial     = v_nombre,
           eslogan              = core.fn_texto(p_datos ->> 'eslogan', 120),
           descripcion          = core.fn_texto(p_datos ->> 'descripcion', 400),
           nit                  = v_nit,
           telefono             = core.fn_texto(p_datos ->> 'telefono', 20),
           whatsapp             = v_wa,
           email                = core.fn_texto(p_datos ->> 'email', 120),
           direccion            = core.fn_texto(p_datos ->> 'direccion', 160),
           horario_general      = core.fn_texto(p_datos ->> 'horario_general', 120),
           tiempo_mesa          = core.fn_texto(p_datos ->> 'tiempo_mesa', 30),
           tiempo_domicilio     = core.fn_texto(p_datos ->> 'tiempo_domicilio', 30),
           instagram_url        = CASE WHEN p_datos ? 'instagram_url' THEN core.fn_texto(p_datos ->> 'instagram_url', 250) ELSE instagram_url END,
           facebook_url         = CASE WHEN p_datos ? 'facebook_url'  THEN core.fn_texto(p_datos ->> 'facebook_url', 250)  ELSE facebook_url END,
           hora_corte_operativa = v_corte,
           actualizado_en       = now()
     WHERE id = p_empresa_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Esa empresa no existe.';
    END IF;

    IF p_cuentas IS NOT NULL THEN
        UPDATE core.cuentas_recaudo SET activa = FALSE WHERE empresa_id = p_empresa_id;
        FOR v_cuenta IN SELECT * FROM jsonb_array_elements(p_cuentas) LOOP
            CONTINUE WHEN core.fn_texto(v_cuenta ->> 'numero', 40) IS NULL;
            IF length(trim(v_cuenta ->> 'numero')) > 40 THEN
                RAISE EXCEPTION 'Los datos de % son demasiado largos (máximo 40 caracteres).', v_cuenta ->> 'entidad';
            END IF;
            INSERT INTO core.cuentas_recaudo (empresa_id, entidad, numero, titular, activa)
            VALUES (p_empresa_id, core.fn_texto(v_cuenta ->> 'entidad', 60), core.fn_texto(v_cuenta ->> 'numero', 40),
                    core.fn_texto(v_cuenta ->> 'titular', 160), TRUE)
            ON CONFLICT (empresa_id, entidad, numero) DO UPDATE SET titular = EXCLUDED.titular, activa = TRUE;
        END LOOP;
    END IF;
END;
$$;

/* Métodos de pago que se ofrecen. p_metodos: [{"codigo": "datafono", "activo": false}] */
CREATE OR REPLACE PROCEDURE api.sp_guardar_metodos_pago(p_empresa_id INTEGER, p_usuario_id INTEGER, p_metodos JSONB)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v JSONB;
    v_orden SMALLINT := 0;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'config_pagos');
    PERFORM core.fn_exigir_empresa_propia(p_usuario_id, p_empresa_id);

    FOR v IN SELECT * FROM jsonb_array_elements(COALESCE(p_metodos, '[]')) LOOP
        v_orden := v_orden + 1;
        IF NOT EXISTS (SELECT 1 FROM core.metodos_pago WHERE codigo = v ->> 'codigo') THEN
            RAISE EXCEPTION 'El método de pago "%" no existe.', v ->> 'codigo';
        END IF;
        INSERT INTO core.empresa_metodos_pago (empresa_id, metodo_pago_id, activo, descripcion, orden)
        VALUES (p_empresa_id, core.fn_id_catalogo('metodos_pago', v ->> 'codigo'),
                COALESCE((v ->> 'activo')::BOOLEAN, TRUE), core.fn_texto(v ->> 'descripcion', 250), v_orden)
        ON CONFLICT (empresa_id, metodo_pago_id) DO UPDATE
           SET activo = EXCLUDED.activo,
               descripcion = COALESCE(EXCLUDED.descripcion, core.empresa_metodos_pago.descripcion);
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM core.empresa_metodos_pago WHERE empresa_id = p_empresa_id AND activo) THEN
        RAISE EXCEPTION 'Tiene que quedar al menos un método de pago activo.';
    END IF;
END;
$$;


/* ============================================================================
   4. PLATAFORMA (SuperAdmin)
   ============================================================================ */

/* Ficha de una empresa. p_empresa_id NULL = nueva (código estable a partir
   del nombre, que después puede cambiar sin tocar el código). */
CREATE OR REPLACE PROCEDURE api.sp_guardar_empresa(
    p_usuario_id  INTEGER,
    p_datos       JSONB,
    INOUT p_empresa_id INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre TEXT := core.fn_texto(p_datos ->> 'nombre_comercial', 120);
    v_nit    TEXT := core.fn_texto(p_datos ->> 'nit', 20);
    v_wa     TEXT := NULLIF(regexp_replace(COALESCE(p_datos ->> 'whatsapp', ''), '\D', '', 'g'), '');
    v_estado TEXT := CASE WHEN COALESCE((p_datos ->> 'activa')::BOOLEAN, TRUE) THEN 'activa' ELSE 'inactiva' END;
    v_codigo TEXT;
    v_n      INTEGER := 1;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'plataforma');

    IF v_nombre IS NULL OR length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'La empresa necesita un nombre comercial.';
    END IF;
    IF v_nit IS NOT NULL AND EXISTS (SELECT 1 FROM core.empresas WHERE nit = v_nit AND id IS DISTINCT FROM p_empresa_id) THEN
        RAISE EXCEPTION 'Ya hay otra empresa con el NIT %.', v_nit;
    END IF;
    IF v_wa IS NOT NULL AND length(v_wa) < 10 THEN
        RAISE EXCEPTION 'El WhatsApp debe incluir el indicativo del país. Ej. 573001112233';
    END IF;

    IF p_empresa_id IS NULL THEN
        v_codigo := 'empresa_' || left(trim(BOTH '_' FROM regexp_replace(lower(translate(v_nombre,
                        'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun')), '[^a-z0-9]+', '_', 'g')), 28);
        IF v_codigo = 'empresa_' THEN
            v_codigo := 'empresa_' || substr(md5(random()::TEXT), 1, 8);
        END IF;
        WHILE EXISTS (SELECT 1 FROM core.empresas WHERE codigo = v_codigo || CASE WHEN v_n > 1 THEN '_' || v_n ELSE '' END) LOOP
            v_n := v_n + 1;
        END LOOP;
        IF v_n > 1 THEN
            v_codigo := v_codigo || '_' || v_n;
        END IF;

        INSERT INTO core.empresas (codigo, nombre_comercial, razon_social, nit, telefono, whatsapp, email, direccion,
                                   estado, plantilla)
        VALUES (v_codigo, v_nombre, core.fn_texto(p_datos ->> 'razon_social', 160), v_nit,
                core.fn_texto(p_datos ->> 'telefono', 20), v_wa, core.fn_texto(p_datos ->> 'email', 120),
                core.fn_texto(p_datos ->> 'direccion', 160), v_estado, core.fn_texto(p_datos ->> 'plantilla', 30))
        RETURNING id INTO p_empresa_id;
    ELSE
        UPDATE core.empresas
           SET nombre_comercial = v_nombre,
               razon_social     = core.fn_texto(p_datos ->> 'razon_social', 160),
               nit              = v_nit,
               telefono         = core.fn_texto(p_datos ->> 'telefono', 20),
               whatsapp         = v_wa,
               email            = core.fn_texto(p_datos ->> 'email', 120),
               estado           = CASE WHEN p_datos ? 'activa' THEN v_estado ELSE estado END,
               actualizado_en   = now()
         WHERE id = p_empresa_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Esa empresa no existe.';
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_guardar_tema_empresa(p_empresa_id INTEGER, p_usuario_id INTEGER, p_tema JSONB)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    c TEXT;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'plataforma');
    IF NOT EXISTS (SELECT 1 FROM core.empresas WHERE id = p_empresa_id) THEN
        RAISE EXCEPTION 'Esa empresa no existe.';
    END IF;
    FOREACH c IN ARRAY ARRAY['primary', 'secondary', 'accent', 'background'] LOOP
        IF NULLIF(p_tema ->> c, '') IS NOT NULL AND (p_tema ->> c) !~ '^#[0-9A-Fa-f]{6}$' THEN
            RAISE EXCEPTION 'Los colores deben tener el formato #RRGGBB.';
        END IF;
    END LOOP;
    IF NULLIF(p_tema ->> 'fontFamily', '') IS NOT NULL AND (p_tema ->> 'fontFamily') !~ '^[a-z0-9_-]{1,30}$' THEN
        RAISE EXCEPTION 'Tipografía no válida.';
    END IF;

    UPDATE core.empresas
       SET color_primario   = COALESCE(NULLIF(p_tema ->> 'primary', ''), color_primario),
           color_secundario = COALESCE(NULLIF(p_tema ->> 'secondary', ''), color_secundario),
           color_acento     = COALESCE(NULLIF(p_tema ->> 'accent', ''), color_acento),
           color_fondo      = COALESCE(NULLIF(p_tema ->> 'background', ''), color_fondo),
           tipografia       = COALESCE(NULLIF(p_tema ->> 'fontFamily', ''), tipografia),
           logo_texto       = core.fn_texto(p_tema ->> 'logoTexto', 24),
           logo_acento      = core.fn_texto(p_tema ->> 'logoAcento', 24),
           iniciales        = upper(core.fn_texto(p_tema ->> 'iniciales', 3)),
           lema             = core.fn_texto(p_tema ->> 'lema', 80),
           actualizado_en   = now()
     WHERE id = p_empresa_id;

    -- Imágenes: sólo si vienen ("" = quitar)
    IF p_tema ? 'logo' OR p_tema ? 'favicon' THEN
        INSERT INTO core.empresa_imagenes (empresa_id) VALUES (p_empresa_id) ON CONFLICT (empresa_id) DO NOTHING;
        UPDATE core.empresa_imagenes
           SET logo    = CASE WHEN p_tema ? 'logo'    THEN NULLIF(p_tema ->> 'logo', '')    ELSE logo END,
               favicon = CASE WHEN p_tema ? 'favicon' THEN NULLIF(p_tema ->> 'favicon', '') ELSE favicon END,
               actualizado_en = now()
         WHERE empresa_id = p_empresa_id;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_modulo_empresa(p_empresa_id INTEGER, p_modulo VARCHAR, p_activo BOOLEAN, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_mod core.modulos;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'plataforma');
    SELECT * INTO v_mod FROM core.modulos WHERE codigo = p_modulo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El módulo "%" no existe.', p_modulo;
    END IF;
    IF v_mod.obligatorio AND NOT p_activo THEN
        RAISE EXCEPTION 'El módulo % siempre está incluido: no se puede apagar.', v_mod.nombre;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.empresas WHERE id = p_empresa_id) THEN
        RAISE EXCEPTION 'Esa empresa no existe.';
    END IF;
    INSERT INTO core.empresa_modulos (empresa_id, modulo_id, activo)
    VALUES (p_empresa_id, v_mod.id, p_activo)
    ON CONFLICT (empresa_id, modulo_id) DO UPDATE SET activo = EXCLUDED.activo;
END;
$$;

/* ALTA COMPLETA, todo o nada. p_datos: ficha + direccion, ciudad, tipo_negocio,
   modulos {stock, cierre}, tema {...}, admin {nombre, usuario, pin} (opcional). */
CREATE OR REPLACE PROCEDURE api.sp_alta_empresa(p_usuario_id INTEGER, p_datos JSONB, INOUT p_empresa_id INTEGER DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_unidad  INTEGER;
    v_admin   INTEGER;
    v_mod     RECORD;
    v_nombre  TEXT := core.fn_texto(p_datos ->> 'nombre_comercial', 120);
    v_tipo    TEXT := COALESCE(NULLIF(p_datos ->> 'tipo_negocio', ''), 'restaurante');
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'plataforma');

    CALL api.sp_guardar_empresa(p_usuario_id, p_datos, p_empresa_id);

    -- Primera unidad, con los datos del alta
    IF NOT EXISTS (SELECT 1 FROM core.tipos_negocio WHERE codigo = v_tipo) THEN
        v_tipo := 'otro';
    END IF;
    CALL api.sp_guardar_unidad(
        p_empresa_id => p_empresa_id, p_nombre => left(v_nombre || ' · Sede principal', 120), p_tipo_negocio => v_tipo,
        p_usuario_id => p_usuario_id, p_nombre_corto => 'Principal',
        p_direccion => p_datos ->> 'direccion', p_ciudad => p_datos ->> 'ciudad',
        p_telefono => p_datos ->> 'telefono',
        p_whatsapp => regexp_replace(COALESCE(p_datos ->> 'whatsapp', ''), '\D', '', 'g'),
        p_mesas => 10, p_unidad_id => v_unidad);

    -- Módulos: los obligatorios siempre; los demás según el alta (por defecto, apagados)
    FOR v_mod IN SELECT * FROM core.modulos LOOP
        CALL api.sp_modulo_empresa(p_empresa_id, v_mod.codigo,
                                   v_mod.obligatorio OR COALESCE((p_datos -> 'modulos' ->> v_mod.codigo)::BOOLEAN, FALSE),
                                   p_usuario_id);
    END LOOP;

    IF jsonb_typeof(p_datos -> 'tema') = 'object' THEN
        CALL api.sp_guardar_tema_empresa(p_empresa_id, p_usuario_id, p_datos -> 'tema');
    END IF;

    -- Lo que toda empresa necesita para operar desde el primer día
    INSERT INTO core.empresa_metodos_pago (empresa_id, metodo_pago_id, activo, descripcion, orden)
    SELECT p_empresa_id, mp.id, TRUE, x.descripcion, x.orden
      FROM (VALUES ('efectivo', 'Le pagas al domiciliario cuando recibas.', 1),
                   ('datafono', 'El domiciliario lleva datáfono. Tarjeta débito o crédito.', 2),
                   ('transferencia', 'Transfieres ahora y despachamos apenas confirmemos el pago.', 3)) AS x (metodo, descripcion, orden)
      JOIN core.metodos_pago mp ON mp.codigo = x.metodo
    ON CONFLICT (empresa_id, metodo_pago_id) DO NOTHING;

    INSERT INTO core.categorias_gasto (empresa_id, nombre, icono)
    SELECT p_empresa_id, x.nombre, x.icono
      FROM (VALUES ('Compra a proveedor', '🚚'), ('Nómina', '👥'), ('Vale', '🧾'),
                   ('Servicios', '💡'), ('Operación', '🔧'), ('Otros', '📌')) AS x (nombre, icono)
    ON CONFLICT (empresa_id, nombre) DO NOTHING;

    INSERT INTO core.consecutivos (empresa_id, tipo, ultimo_numero, digitos)
    VALUES (p_empresa_id, 'pedido', 0, 5)
    ON CONFLICT (empresa_id, tipo) DO NOTHING;

    -- Administrador inicial (siempre rol de empresa, nunca SuperAdmin)
    IF jsonb_typeof(p_datos -> 'admin') = 'object' AND NULLIF(p_datos -> 'admin' ->> 'usuario', '') IS NOT NULL THEN
        CALL api.sp_guardar_usuario(
            p_empresa_id => p_empresa_id, p_rol => 'admin',
            p_nombre => p_datos -> 'admin' ->> 'nombre', p_usuario => p_datos -> 'admin' ->> 'usuario',
            p_admin_id => p_usuario_id, p_pin => p_datos -> 'admin' ->> 'pin',
            p_unidades => '{}', p_activo => TRUE, p_usuario_id => v_admin);
    END IF;
END;
$$;


/* ============================================================================
   5. API REST
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.fn_exigir_plataforma()
RETURNS INTEGER
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
BEGIN
    IF NOT core.fn_tiene_permiso(v_usuario, 'plataforma') THEN
        RAISE EXCEPTION 'Sólo la plataforma Taseca puede hacer esto.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN v_usuario;
END;
$$;

CREATE OR REPLACE FUNCTION core.fn_empresa_por_codigo(p_codigo TEXT)
RETURNS INTEGER
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_id INTEGER := (SELECT id FROM core.empresas WHERE codigo = p_codigo);
BEGIN
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'La empresa "%" no existe.', p_codigo;
    END IF;
    RETURN v_id;
END;
$$;

/* ---- Configuración (Admin de la empresa) ---- */
CREATE OR REPLACE FUNCTION rest.guardar_configuracion(p_datos JSONB, p_cuentas JSONB DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_empresa INTEGER := core.fn_jwt_empresa();
BEGIN
    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'Tu sesión no pertenece a una empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    CALL api.sp_guardar_configuracion(v_empresa, v_usuario, p_datos, p_cuentas);
    RETURN (SELECT to_jsonb(v) FROM api.v_empresa_ficha v WHERE v.empresa_id = v_empresa);
END;
$$;

CREATE OR REPLACE FUNCTION rest.guardar_metodos_pago(p_metodos JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_empresa INTEGER := core.fn_jwt_empresa();
BEGIN
    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'Tu sesión no pertenece a una empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    CALL api.sp_guardar_metodos_pago(v_empresa, v_usuario, p_metodos);
    RETURN (SELECT metodos_pago FROM api.v_empresa_ficha WHERE empresa_id = v_empresa);
END;
$$;

/* ---- Facturas de prueba (Ajustes) ---- */
CREATE OR REPLACE FUNCTION rest.facturas_prueba()
RETURNS JSONB
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_empresa INTEGER := core.fn_jwt_empresa();
BEGIN
    IF NOT core.fn_tiene_permiso(v_usuario, 'pedidos_anular') THEN
        RETURN jsonb_build_object('pedidos', 0, 'entradas', 0);
    END IF;
    RETURN jsonb_build_object(
        'pedidos', (SELECT count(*) FROM core.pedidos WHERE empresa_id = v_empresa),
        'entradas', (SELECT count(*) FROM core.entradas_inventario e JOIN core.pedidos p ON p.id = e.pedido_id
                      WHERE p.empresa_id = v_empresa));
END;
$$;

CREATE OR REPLACE FUNCTION rest.borrar_facturas_prueba(p_confirmacion TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario  INTEGER := core.fn_exigir_sesion();
    v_empresa  INTEGER := core.fn_jwt_empresa();
    v_antes    JSONB   := rest.facturas_prueba();
    v_borradas INTEGER;
BEGIN
    CALL api.sp_borrar_facturas_prueba(v_empresa, p_confirmacion, v_usuario, v_borradas);
    RETURN jsonb_build_object('pedidos', v_borradas, 'entradas', (v_antes ->> 'entradas')::INTEGER);
END;
$$;

/* ---- Plataforma ---- */
CREATE OR REPLACE FUNCTION rest.guardar_empresa(p_empresa TEXT, p_datos JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_plataforma();
    v_id      INTEGER := core.fn_empresa_por_codigo(p_empresa);
BEGIN
    CALL api.sp_guardar_empresa(v_usuario, p_datos, v_id);
    RETURN (SELECT to_jsonb(v) FROM api.v_empresa_ficha v WHERE v.empresa_id = v_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.guardar_tema_empresa(p_empresa TEXT, p_tema JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_plataforma();
    v_id      INTEGER := core.fn_empresa_por_codigo(p_empresa);
BEGIN
    CALL api.sp_guardar_tema_empresa(v_id, v_usuario, p_tema);
    RETURN (SELECT to_jsonb(v) FROM api.v_empresa_ficha v WHERE v.empresa_id = v_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.modulo_empresa(p_empresa TEXT, p_modulo TEXT, p_activo BOOLEAN)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_plataforma();
    v_id      INTEGER := core.fn_empresa_por_codigo(p_empresa);
BEGIN
    CALL api.sp_modulo_empresa(v_id, p_modulo, p_activo, v_usuario);
    RETURN (SELECT modulos FROM api.v_empresa_ficha WHERE empresa_id = v_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.alta_empresa(p_datos JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_plataforma();
    v_id      INTEGER;
BEGIN
    CALL api.sp_alta_empresa(v_usuario, p_datos, v_id);
    RETURN (SELECT to_jsonb(v) FROM api.v_empresa_ficha v WHERE v.empresa_id = v_id);
END;
$$;

/* Entrar a administrar una empresa: token nuevo con esa empresa. El usuario
   sigue siendo SuperAdmin; sólo cambia qué empresa está mirando. */
CREATE OR REPLACE FUNCTION rest.entrar_empresa(p_empresa TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_plataforma();
    v_id      INTEGER;
    v_exp     BIGINT;
BEGIN
    IF p_empresa IS NOT NULL THEN
        v_id := core.fn_empresa_por_codigo(p_empresa);
        IF (SELECT estado FROM core.empresas WHERE id = v_id) <> 'activa' THEN
            RAISE EXCEPTION 'Esa empresa está desactivada: actívala primero.';
        END IF;
    END IF;
    v_exp := extract(epoch FROM now() + make_interval(hours => (SELECT duracion_horas FROM core.jwt_config ORDER BY id DESC LIMIT 1)))::BIGINT;
    RETURN jsonb_build_object(
        'token', core.fn_jwt_firmar(jsonb_build_object('role', 'taseca_app', 'usuario_id', v_usuario,
                                                      'empresa_id', v_id, 'rol', 'superadmin', 'exp', v_exp)),
        'expira', to_timestamp(v_exp),
        'empresa_codigo', p_empresa);
END;
$$;


/* ============================================================================
   6. PERMISOS
   ============================================================================ */

REVOKE ALL ON FUNCTION core.fn_texto(TEXT, INTEGER), core.fn_exigir_plataforma(), core.fn_empresa_por_codigo(TEXT) FROM PUBLIC;

REVOKE ALL ON PROCEDURE api.sp_guardar_configuracion(INTEGER, INTEGER, JSONB, JSONB),
                        api.sp_guardar_metodos_pago(INTEGER, INTEGER, JSONB),
                        api.sp_guardar_empresa(INTEGER, JSONB, INTEGER),
                        api.sp_guardar_tema_empresa(INTEGER, INTEGER, JSONB),
                        api.sp_modulo_empresa(INTEGER, VARCHAR, BOOLEAN, INTEGER),
                        api.sp_alta_empresa(INTEGER, JSONB, INTEGER)
       FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE api.sp_guardar_configuracion(INTEGER, INTEGER, JSONB, JSONB),
                           api.sp_guardar_metodos_pago(INTEGER, INTEGER, JSONB),
                           api.sp_guardar_empresa(INTEGER, JSONB, INTEGER),
                           api.sp_guardar_tema_empresa(INTEGER, INTEGER, JSONB),
                           api.sp_modulo_empresa(INTEGER, VARCHAR, BOOLEAN, INTEGER),
                           api.sp_alta_empresa(INTEGER, JSONB, INTEGER)
      TO taseca_app;

GRANT SELECT ON api.v_empresa_ficha TO taseca_app, taseca_lectura;
GRANT SELECT ON rest.empresas, rest.empresa_imagenes TO taseca_anon, taseca_app;
GRANT SELECT ON rest.plataforma_empresas, rest.plataforma_usuarios TO taseca_app;

REVOKE ALL ON FUNCTION rest.guardar_configuracion(JSONB, JSONB), rest.guardar_metodos_pago(JSONB),
                       rest.facturas_prueba(), rest.borrar_facturas_prueba(TEXT),
                       rest.guardar_empresa(TEXT, JSONB), rest.guardar_tema_empresa(TEXT, JSONB),
                       rest.modulo_empresa(TEXT, TEXT, BOOLEAN), rest.alta_empresa(JSONB), rest.entrar_empresa(TEXT)
       FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rest.guardar_configuracion(JSONB, JSONB), rest.guardar_metodos_pago(JSONB),
                          rest.facturas_prueba(), rest.borrar_facturas_prueba(TEXT),
                          rest.guardar_empresa(TEXT, JSONB), rest.guardar_tema_empresa(TEXT, JSONB),
                          rest.modulo_empresa(TEXT, TEXT, BOOLEAN), rest.alta_empresa(JSONB), rest.entrar_empresa(TEXT)
      TO taseca_app;

NOTIFY pgrst, 'reload schema';


/* ============================================================================
   16_PAGOS_EN_CAJA
   Todos los pagos se confirman en caja
   ============================================================================ */

/* ============================================================================
   TASECA · 16 · TODOS LOS PAGOS SE CONFIRMAN EN CAJA
   ----------------------------------------------------------------------------
   Antes: al entregar un pedido en efectivo (en la mesa o el domiciliario) el
   pago quedaba confirmado solo, y contaba como dinero cobrado aunque la
   cajera no lo hubiera recibido. Además, un pedido de mesa se toma sin saber
   con qué va a pagar el cliente.

   Ahora:
     · "Entregado" es sólo el estado de la operación (para el cliente, el
       mesero y el domiciliario). El pago queda PENDIENTE.
     · Caja confirma cada pago —mesa o domicilio, cualquier método— y en ese
       momento registra el método real (efectivo, datáfono, transferencia).
     · Un pago confirmado ya no cambia: ni de estado ni de método. Si hubo un
       error, se anula la factura (queda la auditoría).
     · Una factura cancelada o anulada no se cobra.

   Lo que ya estaba confirmado en la base NO se toca.

   Requiere: 00 … 15 instalados. Se puede ejecutar más de una vez.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. TRIGGER: entregar ya no confirma el pago
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.tg_pedidos_antes_actualizar()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_ant       core.estados_pedido;
    v_nuevo     core.estados_pedido;
    v_tipo      VARCHAR;
    v_pago_ant  VARCHAR;
    v_pago_nvo  VARCHAR;
BEGIN
    IF NEW.empresa_id <> OLD.empresa_id OR NEW.unidad_id <> OLD.unidad_id
       OR NEW.codigo <> OLD.codigo OR NEW.fecha_operativa <> OLD.fecha_operativa
       OR NEW.tipo_pedido_id <> OLD.tipo_pedido_id OR NEW.creado_en <> OLD.creado_en THEN
        RAISE EXCEPTION 'La factura % no puede cambiar de empresa, unidad, código, tipo ni jornada.', OLD.codigo;
    END IF;

    SELECT * INTO v_ant   FROM core.estados_pedido WHERE id = OLD.estado_pedido_id;
    SELECT * INTO v_nuevo FROM core.estados_pedido WHERE id = NEW.estado_pedido_id;
    SELECT codigo INTO v_tipo     FROM core.tipos_pedido WHERE id = NEW.tipo_pedido_id;
    SELECT codigo INTO v_pago_ant FROM core.estados_pago WHERE id = OLD.estado_pago_id;
    SELECT codigo INTO v_pago_nvo FROM core.estados_pago WHERE id = NEW.estado_pago_id;

    IF v_ant.codigo IN ('cancelado', 'anulado') THEN
        RAISE EXCEPTION 'La factura % está % y ya no se puede modificar.', OLD.codigo, lower(v_ant.nombre);
    END IF;

    -- Un pago confirmado es definitivo: ni se "desconfirma" ni cambia de método
    IF v_pago_ant = 'confirmado'
       AND (NEW.estado_pago_id <> OLD.estado_pago_id OR NEW.metodo_pago_id <> OLD.metodo_pago_id) THEN
        RAISE EXCEPTION 'El pago de la factura % ya fue confirmado y no se puede cambiar.', OLD.codigo;
    END IF;

    IF NEW.estado_pedido_id <> OLD.estado_pedido_id THEN
        IF v_nuevo.codigo = 'anulado' AND NOT EXISTS (SELECT 1 FROM core.anulaciones WHERE pedido_id = OLD.id) THEN
            RAISE EXCEPTION 'Una factura sólo se anula con api.sp_anular_pedido (motivo y retorno de inventario).';
        END IF;
        IF v_nuevo.solo_domicilio AND v_tipo <> 'domicilio' THEN
            RAISE EXCEPTION 'El estado "%" sólo aplica a domicilios.', v_nuevo.nombre;
        END IF;
        IF v_nuevo.orden < 90 AND v_nuevo.orden <= v_ant.orden THEN
            RAISE EXCEPTION 'El pedido % no puede volver de "%" a "%".', OLD.codigo, v_ant.nombre, v_nuevo.nombre;
        END IF;
        IF v_ant.codigo = 'entregado' AND v_nuevo.codigo <> 'anulado' THEN
            RAISE EXCEPTION 'Un pedido entregado sólo puede anularse.';
        END IF;
        IF v_nuevo.codigo = 'cancelado' AND (NEW.motivo_cancelacion IS NULL OR length(trim(NEW.motivo_cancelacion)) < 3) THEN
            RAISE EXCEPTION 'Para cancelar hay que escribir el motivo.';
        END IF;
        -- (Antes: entregado en efectivo = pago confirmado. Ya no: lo confirma caja.)
    ELSIF v_ant.codigo = 'entregado'
          AND (NEW.cliente_id IS DISTINCT FROM OLD.cliente_id
               OR NEW.direccion_entrega IS DISTINCT FROM OLD.direccion_entrega
               OR NEW.costo_domicilio <> OLD.costo_domicilio
               -- el método sólo lo fija caja al confirmar el cobro
               OR (NEW.metodo_pago_id <> OLD.metodo_pago_id AND v_pago_nvo <> 'confirmado')) THEN
        RAISE EXCEPTION 'La factura % ya fue entregada: sólo caja puede registrar su pago.', OLD.codigo;
    END IF;

    RETURN NEW;
END;
$$;


/* ============================================================================
   2. HISTORIAL: el cambio de método queda escrito
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.tg_pedidos_historial()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.estado_pedido_id <> OLD.estado_pedido_id THEN
        INSERT INTO core.pedido_historial (pedido_id, estado_pedido_id, descripcion, usuario_id)
        SELECT NEW.id, NEW.estado_pedido_id,
               'Estado: ' || e.nombre ||
               CASE WHEN e.codigo = 'cancelado' THEN ' · ' || NEW.motivo_cancelacion ELSE '' END,
               core.fn_usuario_actual()
          FROM core.estados_pedido e WHERE e.id = NEW.estado_pedido_id;
    END IF;
    IF NEW.metodo_pago_id <> OLD.metodo_pago_id THEN
        INSERT INTO core.pedido_historial (pedido_id, descripcion, usuario_id)
        SELECT NEW.id, 'Método de pago: ' || a.nombre || ' → ' || n.nombre, core.fn_usuario_actual()
          FROM core.metodos_pago a, core.metodos_pago n
         WHERE a.id = OLD.metodo_pago_id AND n.id = NEW.metodo_pago_id;
    END IF;
    IF NEW.estado_pago_id <> OLD.estado_pago_id THEN
        INSERT INTO core.pedido_historial (pedido_id, descripcion, usuario_id)
        SELECT NEW.id, 'Pago: ' || p.nombre, core.fn_usuario_actual()
          FROM core.estados_pago p WHERE p.id = NEW.estado_pago_id;
    END IF;
    RETURN NEW;
END;
$$;


/* ============================================================================
   3. PROCEDIMIENTO: caja confirma (con el método real) o rechaza
   ============================================================================ */

DROP PROCEDURE IF EXISTS api.sp_actualizar_pago(BIGINT, VARCHAR, INTEGER, VARCHAR);

CREATE OR REPLACE PROCEDURE api.sp_actualizar_pago(
    p_pedido_id    BIGINT,
    p_estado_pago  VARCHAR,
    p_usuario_id   INTEGER,
    p_nota         VARCHAR DEFAULT NULL,
    p_metodo_pago  VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_empresa  INTEGER;
    v_estado   VARCHAR;
    v_pago     VARCHAR;
    v_codigo   VARCHAR;
    v_metodo   INTEGER;
BEGIN
    SELECT p.empresa_id, e.codigo, ep.codigo, p.codigo, p.metodo_pago_id
      INTO v_empresa, v_estado, v_pago, v_codigo, v_metodo
      FROM core.pedidos p
      JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
      JOIN core.estados_pago ep  ON ep.id = p.estado_pago_id
     WHERE p.id = p_pedido_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido % no existe.', p_pedido_id;
    END IF;

    PERFORM core.fn_preparar_operacion(p_usuario_id, 'pagos',
            (SELECT unidad_id FROM core.pedidos WHERE id = p_pedido_id));

    IF p_estado_pago NOT IN ('confirmado', 'rechazado') THEN
        RAISE EXCEPTION 'Caja sólo confirma o rechaza pagos.';
    END IF;
    IF v_estado IN ('cancelado', 'anulado') THEN
        RAISE EXCEPTION 'La factura % está %: no hay pago que registrar.', v_codigo, v_estado;
    END IF;
    IF v_pago = 'confirmado' THEN
        RAISE EXCEPTION 'El pago de la factura % ya fue confirmado.', v_codigo;
    END IF;

    IF NULLIF(trim(p_metodo_pago), '') IS NOT NULL THEN
        IF p_estado_pago <> 'confirmado' THEN
            RAISE EXCEPTION 'El método de pago se registra al confirmar el cobro.';
        END IF;
        v_metodo := core.fn_id_catalogo('metodos_pago', trim(p_metodo_pago));
        IF NOT EXISTS (SELECT 1 FROM core.empresa_metodos_pago
                        WHERE empresa_id = v_empresa AND metodo_pago_id = v_metodo AND activo) THEN
            RAISE EXCEPTION 'El método de pago "%" no está disponible.', p_metodo_pago;
        END IF;
    END IF;

    UPDATE core.pedidos
       SET estado_pago_id = core.fn_id_catalogo('estados_pago', p_estado_pago),
           metodo_pago_id = v_metodo
     WHERE id = p_pedido_id;

    UPDATE core.comprobantes_pago
       SET estado_pago_id = core.fn_id_catalogo('estados_pago', p_estado_pago),
           revisado_por_id = p_usuario_id, revisado_en = now()
     WHERE pedido_id = p_pedido_id AND revisado_en IS NULL;

    IF NULLIF(trim(p_nota), '') IS NOT NULL THEN
        INSERT INTO core.pedido_historial (pedido_id, descripcion, usuario_id)
        VALUES (p_pedido_id,
                CASE WHEN p_estado_pago = 'confirmado' THEN 'Referencia del pago: ' ELSE 'Motivo: ' END || trim(p_nota),
                p_usuario_id);
    END IF;
END;
$$;


/* ============================================================================
   4. API REST
   ============================================================================ */

DROP FUNCTION IF EXISTS rest.confirmar_pago(BIGINT, TEXT);

CREATE OR REPLACE FUNCTION rest.confirmar_pago(p_pedido_id BIGINT, p_referencia TEXT DEFAULT NULL, p_metodo TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    CALL api.sp_actualizar_pago(p_pedido_id, 'confirmado', core.fn_exigir_sesion(), p_referencia, p_metodo);
    RETURN core.fn_pedido_de_sesion(p_pedido_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.rechazar_pago(p_pedido_id BIGINT, p_motivo TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    CALL api.sp_actualizar_pago(p_pedido_id, 'rechazado', core.fn_exigir_sesion(), p_motivo);
    RETURN core.fn_pedido_de_sesion(p_pedido_id);
END;
$$;


/* ============================================================================
   5. PERMISOS
   ============================================================================ */

REVOKE ALL ON PROCEDURE api.sp_actualizar_pago(BIGINT, VARCHAR, INTEGER, VARCHAR, VARCHAR) FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE api.sp_actualizar_pago(BIGINT, VARCHAR, INTEGER, VARCHAR, VARCHAR) TO taseca_app;

REVOKE ALL ON FUNCTION rest.confirmar_pago(BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rest.confirmar_pago(BIGINT, TEXT, TEXT) TO taseca_app;

NOTIFY pgrst, 'reload schema';


/* ============================================================================
   17_INTEGRIDAD_MULTIEMPRESA
   Chequeo de relaciones y red de seguridad
   ============================================================================ */

/* ============================================================================
   TASECA · 17 · INTEGRIDAD MULTIEMPRESA
   ----------------------------------------------------------------------------
   Dos cosas:

     1. api.fn_chequeo_integridad() revisa TODA la base y dice, para cada
        relación, si hay filas mal enlazadas o sueltas:
          · ERROR = datos que se cruzan entre empresas o unidades, o registros
            incompletos. No debería haber ninguno.
          · AVISO = datos que no están mal, pero que no ve nadie (un producto
            que no está en ninguna unidad, un cliente sin pedidos…). Sirven
            para limpiar; no son un fallo.

     2. Triggers que impiden que eso vuelva a pasar en las tablas que aún no
        los tenían (pedidos, ítems, entradas, cierres y bases). Los
        procedimientos ya validaban casi todo; esto es la red de seguridad de
        la base, que se cumple venga el dato de donde venga.

   Cómo se usa el chequeo (en DBeaver, Alt+X):

       SELECT * FROM api.fn_chequeo_integridad();                  -- todo
       SELECT * FROM api.fn_chequeo_integridad() WHERE filas > 0;  -- sólo lo que hay que mirar

   No modifica datos. Se puede ejecutar más de una vez.
   Requiere: 00 … 16 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. CHEQUEO
   ============================================================================ */

CREATE OR REPLACE FUNCTION api.fn_chequeo_integridad()
RETURNS TABLE (gravedad TEXT, tabla TEXT, chequeo TEXT, filas BIGINT, ejemplo TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $funcion$
DECLARE
    c    RECORD;
    v_n  BIGINT;
    v_ej TEXT;
BEGIN
    FOR c IN
        SELECT * FROM (VALUES
        /* ---------- PEDIDOS: de qué empresa y de qué unidad es cada factura ---------- */
        ('ERROR', 'pedidos', 'La empresa de la factura no es la de su unidad',
         $q$SELECT p.id FROM core.pedidos p JOIN core.unidades u ON u.id = p.unidad_id
             WHERE p.empresa_id <> u.empresa_id$q$),
        ('ERROR', 'pedidos', 'La mesa es de otra unidad',
         $q$SELECT p.id FROM core.pedidos p JOIN core.mesas m ON m.id = p.mesa_id
             WHERE m.unidad_id <> p.unidad_id$q$),
        ('ERROR', 'pedidos', 'La zona de domicilio es de otra unidad',
         $q$SELECT p.id FROM core.pedidos p JOIN core.zonas_domicilio z ON z.id = p.zona_domicilio_id
             WHERE z.unidad_id <> p.unidad_id$q$),
        ('ERROR', 'pedidos', 'El cliente es de otra empresa',
         $q$SELECT p.id FROM core.pedidos p JOIN core.clientes cl ON cl.id = p.cliente_id
             WHERE cl.empresa_id <> p.empresa_id$q$),
        ('ERROR', 'pedidos', 'Lo tomó un usuario de otra empresa',
         $q$SELECT p.id FROM core.pedidos p JOIN core.usuarios us ON us.id = p.tomado_por_id
             WHERE us.empresa_id IS NOT NULL AND us.empresa_id <> p.empresa_id$q$),
        ('ERROR', 'pedidos', 'El método de pago no está habilitado en esa empresa',
         $q$SELECT p.id FROM core.pedidos p
             WHERE NOT EXISTS (SELECT 1 FROM core.empresa_metodos_pago emp
                                WHERE emp.empresa_id = p.empresa_id AND emp.metodo_pago_id = p.metodo_pago_id)$q$),
        ('ERROR', 'pedidos', 'Factura anulada sin registro de anulación',
         $q$SELECT p.id FROM core.pedidos p JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
             WHERE e.codigo = 'anulado'
               AND NOT EXISTS (SELECT 1 FROM core.anulaciones a WHERE a.pedido_id = p.id)$q$),
        ('ERROR', 'pedidos', 'Factura sin ningún ítem',
         $q$SELECT p.id FROM core.pedidos p
             WHERE NOT EXISTS (SELECT 1 FROM core.pedido_items i WHERE i.pedido_id = p.id)$q$),

        /* ---------- ÍTEMS: lo vendido existe en esa empresa y esa unidad ---------- */
        ('ERROR', 'pedido_items', 'El producto es de otra empresa',
         $q$SELECT i.id FROM core.pedido_items i JOIN core.pedidos p ON p.id = i.pedido_id
             JOIN core.productos pr ON pr.id = i.producto_id
             WHERE pr.empresa_id <> p.empresa_id$q$),
        ('ERROR', 'pedido_items', 'El plato del día es de otra unidad',
         $q$SELECT i.id FROM core.pedido_items i JOIN core.pedidos p ON p.id = i.pedido_id
             JOIN core.platos_dia pd ON pd.id = i.plato_dia_id
             JOIN core.menus_dia md ON md.id = pd.menu_dia_id
             WHERE md.unidad_id <> p.unidad_id$q$),
        ('ERROR', 'pedido_items', 'El menú armado es de otra unidad',
         $q$SELECT i.id FROM core.pedido_items i JOIN core.pedidos p ON p.id = i.pedido_id
             JOIN core.menus_dia md ON md.id = i.menu_dia_id
             WHERE md.unidad_id <> p.unidad_id$q$),
        ('ERROR', 'pedido_item_opciones', 'La opción elegida no es del menú de ese ítem',
         $q$SELECT o.id FROM core.pedido_item_opciones o
             JOIN core.pedido_items i ON i.id = o.pedido_item_id
             JOIN core.menu_opciones mo ON mo.id = o.menu_opcion_id
             JOIN core.menu_categorias mc ON mc.id = mo.menu_categoria_id
             WHERE mc.menu_dia_id IS DISTINCT FROM i.menu_dia_id$q$),
        ('AVISO', 'pedido_items', 'Producto que hoy ya no está en esa unidad (histórico: normal si se retiró)',
         $q$SELECT i.id FROM core.pedido_items i JOIN core.pedidos p ON p.id = i.pedido_id
             WHERE i.producto_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM core.producto_unidades pu
                                WHERE pu.producto_id = i.producto_id AND pu.unidad_id = p.unidad_id)$q$),

        /* ---------- PAGOS, HISTORIAL Y ANULACIONES ---------- */
        ('ERROR', 'pedido_historial', 'Movimiento escrito por un usuario de otra empresa',
         $q$SELECT h.id FROM core.pedido_historial h JOIN core.pedidos p ON p.id = h.pedido_id
             JOIN core.usuarios u ON u.id = h.usuario_id
             WHERE u.empresa_id IS NOT NULL AND u.empresa_id <> p.empresa_id$q$),
        ('ERROR', 'comprobantes_pago', 'Comprobante revisado por un usuario de otra empresa',
         $q$SELECT cp.id FROM core.comprobantes_pago cp JOIN core.pedidos p ON p.id = cp.pedido_id
             JOIN core.usuarios u ON u.id = cp.revisado_por_id
             WHERE u.empresa_id IS NOT NULL AND u.empresa_id <> p.empresa_id$q$),
        ('ERROR', 'anulaciones', 'Anulación firmada por un usuario de otra empresa',
         $q$SELECT a.id FROM core.anulaciones a JOIN core.pedidos p ON p.id = a.pedido_id
             JOIN core.usuarios u ON u.id = a.usuario_id
             WHERE u.empresa_id IS NOT NULL AND u.empresa_id <> p.empresa_id$q$),

        /* ---------- INVENTARIO ---------- */
        ('ERROR', 'insumo_unidades', 'Insumo de una empresa en la unidad de otra',
         $q$SELECT iu.id FROM core.insumo_unidades iu JOIN core.insumos s ON s.id = iu.insumo_id
             WHERE s.empresa_id <> core.fn_empresa_de_unidad(iu.unidad_id)$q$),
        ('ERROR', 'entradas_inventario', 'Entrada registrada por un usuario de otra empresa',
         $q$SELECT e.id FROM core.entradas_inventario e
             JOIN core.insumo_unidades iu ON iu.id = e.insumo_unidad_id
             JOIN core.usuarios u ON u.id = e.usuario_id
             WHERE u.empresa_id IS NOT NULL AND u.empresa_id <> core.fn_empresa_de_unidad(iu.unidad_id)$q$),
        ('ERROR', 'entradas_inventario', 'Retorno de una factura de otra unidad',
         $q$SELECT e.id FROM core.entradas_inventario e
             JOIN core.insumo_unidades iu ON iu.id = e.insumo_unidad_id
             JOIN core.pedidos p ON p.id = e.pedido_id
             WHERE p.unidad_id <> iu.unidad_id$q$),
        ('ERROR', 'cierres_inventario', 'Cierre firmado por un usuario de otra empresa',
         $q$SELECT ci.id FROM core.cierres_inventario ci
             JOIN core.usuarios u ON u.id IN (ci.registrado_por_id, ci.revisado_por_id)
             WHERE u.empresa_id IS NOT NULL AND u.empresa_id <> core.fn_empresa_de_unidad(ci.unidad_id)$q$),
        ('ERROR', 'cierre_detalles', 'Producto contado que no es de la unidad del cierre',
         $q$SELECT d.id FROM core.cierre_detalles d
             JOIN core.cierres_inventario ci ON ci.id = d.cierre_id
             JOIN core.insumo_unidades iu ON iu.id = d.insumo_unidad_id
             WHERE iu.unidad_id <> ci.unidad_id$q$),
        ('AVISO', 'cierre_detalles', 'Producto contado de un área distinta a la del cierre',
         $q$SELECT d.id FROM core.cierre_detalles d
             JOIN core.cierres_inventario ci ON ci.id = d.cierre_id
             JOIN core.insumo_unidades iu ON iu.id = d.insumo_unidad_id
             JOIN core.insumos s ON s.id = iu.insumo_id
             WHERE s.area_id <> ci.area_id$q$),

        /* ---------- CAJA Y GASTOS ---------- */
        ('ERROR', 'bases_caja', 'Base registrada por un usuario de otra empresa',
         $q$SELECT b.id FROM core.bases_caja b JOIN core.usuarios u ON u.id = b.usuario_id
             WHERE u.empresa_id IS NOT NULL AND u.empresa_id <> core.fn_empresa_de_unidad(b.unidad_id)$q$),
        ('ERROR', 'gastos', 'La categoría del gasto es de otra empresa',
         $q$SELECT g.id FROM core.gastos g JOIN core.categorias_gasto cg ON cg.id = g.categoria_gasto_id
             WHERE cg.empresa_id <> core.fn_empresa_de_unidad(g.unidad_id)$q$),
        ('ERROR', 'gastos', 'Gasto movido por un usuario de otra empresa',
         $q$SELECT g.id FROM core.gastos g
             JOIN core.usuarios u ON u.id IN (g.registrado_por_id, g.confirmado_por_id, g.anulado_por_id)
             WHERE u.empresa_id IS NOT NULL AND u.empresa_id <> core.fn_empresa_de_unidad(g.unidad_id)$q$),
        ('ERROR', 'gastos', 'El método de pago no está habilitado en esa empresa',
         $q$SELECT g.id FROM core.gastos g
             WHERE NOT EXISTS (SELECT 1 FROM core.empresa_metodos_pago emp
                                WHERE emp.empresa_id = core.fn_empresa_de_unidad(g.unidad_id)
                                  AND emp.metodo_pago_id = g.metodo_pago_id)$q$),

        /* ---------- CARTA, MENÚ Y CATÁLOGOS ---------- */
        ('ERROR', 'productos', 'La categoría del producto es de otra empresa',
         $q$SELECT pr.id FROM core.productos pr JOIN core.categorias ca ON ca.id = pr.categoria_id
             WHERE ca.empresa_id <> pr.empresa_id$q$),
        ('ERROR', 'producto_unidades', 'Producto de una empresa en la unidad de otra',
         $q$SELECT pu.id FROM core.producto_unidades pu JOIN core.productos pr ON pr.id = pu.producto_id
             WHERE pr.empresa_id <> core.fn_empresa_de_unidad(pu.unidad_id)$q$),
        ('ERROR', 'categoria_unidades', 'Categoría de una empresa en la unidad de otra',
         $q$SELECT cu.id FROM core.categoria_unidades cu JOIN core.categorias ca ON ca.id = cu.categoria_id
             WHERE ca.empresa_id <> core.fn_empresa_de_unidad(cu.unidad_id)$q$),
        ('ERROR', 'insumos', 'La categoría del insumo es de otra empresa',
         $q$SELECT s.id FROM core.insumos s JOIN core.categorias_insumo ci ON ci.id = s.categoria_insumo_id
             WHERE ci.empresa_id <> s.empresa_id$q$),
        ('ERROR', 'producto_insumos', 'Receta que une producto e insumo de empresas distintas',
         $q$SELECT pi.id FROM core.producto_insumos pi
             JOIN core.productos pr ON pr.id = pi.producto_id
             JOIN core.insumos s ON s.id = pi.insumo_id
             WHERE pr.empresa_id <> s.empresa_id$q$),
        ('ERROR', 'menus_dia', 'Menú creado por un usuario de otra empresa',
         $q$SELECT md.id FROM core.menus_dia md JOIN core.usuarios u ON u.id = md.creado_por_id
             WHERE u.empresa_id IS NOT NULL AND u.empresa_id <> core.fn_empresa_de_unidad(md.unidad_id)$q$),

        /* ---------- USUARIOS Y EMPRESAS ---------- */
        ('ERROR', 'usuarios', 'Usuario de empresa sin empresa, o de plataforma con empresa',
         $q$SELECT u.id FROM core.usuarios u
             WHERE (u.empresa_id IS NULL) <> EXISTS (SELECT 1 FROM core.rol_permisos rp
                                                       JOIN core.permisos pe ON pe.id = rp.permiso_id
                                                      WHERE rp.rol_id = u.rol_id AND pe.codigo = 'plataforma')$q$),
        ('ERROR', 'usuario_unidades', 'Usuario asignado a la unidad de otra empresa',
         $q$SELECT uu.id FROM core.usuario_unidades uu JOIN core.usuarios u ON u.id = uu.usuario_id
             WHERE u.empresa_id IS DISTINCT FROM core.fn_empresa_de_unidad(uu.unidad_id)$q$),
        ('ERROR', 'empresas', 'Empresa sin ninguna unidad',
         $q$SELECT e.id FROM core.empresas e
             WHERE NOT EXISTS (SELECT 1 FROM core.unidades un WHERE un.empresa_id = e.id)$q$),
        ('ERROR', 'empresas', 'Empresa sin ningún método de pago activo',
         $q$SELECT e.id FROM core.empresas e
             WHERE NOT EXISTS (SELECT 1 FROM core.empresa_metodos_pago emp
                                WHERE emp.empresa_id = e.id AND emp.activo)$q$),
        ('ERROR', 'empresas', 'Empresa sin numeración de facturas',
         $q$SELECT e.id FROM core.empresas e
             WHERE NOT EXISTS (SELECT 1 FROM core.consecutivos co
                                WHERE co.empresa_id = e.id AND co.tipo = 'pedido')$q$),

        /* ---------- DATOS SUELTOS: no es un fallo, es limpieza ---------- */
        ('AVISO', 'empresas', 'Empresa activa sin ningún administrador activo',
         $q$SELECT e.id FROM core.empresas e
             WHERE e.estado = 'activa'
               AND NOT EXISTS (SELECT 1 FROM core.usuarios u JOIN core.roles r ON r.id = u.rol_id
                                WHERE u.empresa_id = e.id AND u.activo
                                  AND r.codigo IN ('admin', 'administrador'))$q$),
        ('AVISO', 'unidades', 'Unidad activa sin ningún usuario asignado',
         $q$SELECT un.id FROM core.unidades un
             WHERE un.estado = 'activa'
               AND NOT EXISTS (SELECT 1 FROM core.usuario_unidades uu WHERE uu.unidad_id = un.id)$q$),
        ('AVISO', 'productos', 'Producto que no está en ninguna unidad: no lo ve nadie',
         $q$SELECT pr.id FROM core.productos pr
             WHERE NOT EXISTS (SELECT 1 FROM core.producto_unidades pu WHERE pu.producto_id = pr.id)$q$),
        ('AVISO', 'categorias', 'Categoría que no está en ninguna unidad',
         $q$SELECT ca.id FROM core.categorias ca
             WHERE NOT EXISTS (SELECT 1 FROM core.categoria_unidades cu WHERE cu.categoria_id = ca.id)$q$),
        ('AVISO', 'insumos', 'Insumo que no está en ninguna unidad',
         $q$SELECT s.id FROM core.insumos s
             WHERE NOT EXISTS (SELECT 1 FROM core.insumo_unidades iu WHERE iu.insumo_id = s.id)$q$),
        ('AVISO', 'insumos', 'Insumo activo sin enlace con la carta: su Z siempre será 0',
         $q$SELECT s.id FROM core.insumos s
             WHERE s.activo
               AND NOT EXISTS (SELECT 1 FROM core.producto_insumos pi WHERE pi.insumo_id = s.id)$q$),
        ('AVISO', 'menus_dia', 'Menú del día sin platos ni categorías',
         $q$SELECT md.id FROM core.menus_dia md
             WHERE NOT EXISTS (SELECT 1 FROM core.platos_dia pd WHERE pd.menu_dia_id = md.id)
               AND NOT EXISTS (SELECT 1 FROM core.menu_categorias mc WHERE mc.menu_dia_id = md.id)$q$),
        ('AVISO', 'menu_categorias', 'Categoría del menú armado sin opciones',
         $q$SELECT mc.id FROM core.menu_categorias mc
             WHERE NOT EXISTS (SELECT 1 FROM core.menu_opciones mo WHERE mo.menu_categoria_id = mc.id)$q$),
        ('AVISO', 'clientes', 'Cliente sin ninguna factura',
         $q$SELECT cl.id FROM core.clientes cl
             WHERE NOT EXISTS (SELECT 1 FROM core.pedidos p WHERE p.cliente_id = cl.id)$q$),
        ('AVISO', 'unidades', 'Unidad activa sin mesas configuradas (sólo importa si atiende en mesa)',
         $q$SELECT un.id FROM core.unidades un
             WHERE un.estado = 'activa'
               AND NOT EXISTS (SELECT 1 FROM core.mesas m WHERE m.unidad_id = un.id)$q$)
        ) AS x (g, t, ch, q)
    LOOP
        EXECUTE format('SELECT count(*) FROM (%s) AS z', c.q) INTO v_n;
        v_ej := NULL;
        IF v_n > 0 THEN
            EXECUTE format('SELECT string_agg(z.id::TEXT, '', '') FROM (%s LIMIT 5) AS z', c.q) INTO v_ej;
            IF v_n > 5 THEN
                v_ej := v_ej || ', …';
            END IF;
        END IF;
        gravedad := c.g;
        tabla    := c.t;
        chequeo  := c.ch;
        filas    := v_n;
        ejemplo  := v_ej;
        RETURN NEXT;
    END LOOP;
END;
$funcion$;

COMMENT ON FUNCTION api.fn_chequeo_integridad() IS
    'Revisión de relaciones: ERROR = datos cruzados entre empresas o unidades; AVISO = datos sueltos que no ve nadie. No modifica nada.';

REVOKE ALL ON FUNCTION api.fn_chequeo_integridad() FROM PUBLIC;


/* ============================================================================
   2. RED DE SEGURIDAD: LO QUE YA NO PODRÁ CRUZARSE

   Un usuario de plataforma (empresa NULL) sí puede operar dentro de la
   empresa que está administrando: por eso sus comparaciones se saltan.
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.tg_relaciones_empresa()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_empresa INTEGER;   -- empresa a la que pertenece la fila
    v_unidad  INTEGER;   -- unidad a la que pertenece la fila
    v_otra    INTEGER;
BEGIN
    CASE TG_TABLE_NAME

    WHEN 'pedidos' THEN
        IF NEW.empresa_id <> core.fn_empresa_de_unidad(NEW.unidad_id) THEN
            RAISE EXCEPTION 'La factura % sería de una empresa distinta a la de su unidad.', NEW.codigo
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF NEW.mesa_id IS NOT NULL
           AND (SELECT unidad_id FROM core.mesas WHERE id = NEW.mesa_id) <> NEW.unidad_id THEN
            RAISE EXCEPTION 'Esa mesa es de otra unidad.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF NEW.zona_domicilio_id IS NOT NULL
           AND (SELECT unidad_id FROM core.zonas_domicilio WHERE id = NEW.zona_domicilio_id) <> NEW.unidad_id THEN
            RAISE EXCEPTION 'Esa zona de domicilio es de otra unidad.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF NEW.cliente_id IS NOT NULL
           AND (SELECT empresa_id FROM core.clientes WHERE id = NEW.cliente_id) <> NEW.empresa_id THEN
            RAISE EXCEPTION 'Ese cliente es de otra empresa.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        SELECT empresa_id INTO v_otra FROM core.usuarios WHERE id = NEW.tomado_por_id;
        IF v_otra IS NOT NULL AND v_otra <> NEW.empresa_id THEN
            RAISE EXCEPTION 'Ese usuario no es de la empresa de la factura.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'pedido_items' THEN
        SELECT p.empresa_id, p.unidad_id INTO v_empresa, v_unidad
          FROM core.pedidos p WHERE p.id = NEW.pedido_id;
        IF NEW.producto_id IS NOT NULL
           AND (SELECT empresa_id FROM core.productos WHERE id = NEW.producto_id) <> v_empresa THEN
            RAISE EXCEPTION 'Ese producto es de otra empresa.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF NEW.plato_dia_id IS NOT NULL
           AND (SELECT md.unidad_id FROM core.platos_dia pd JOIN core.menus_dia md ON md.id = pd.menu_dia_id
                 WHERE pd.id = NEW.plato_dia_id) <> v_unidad THEN
            RAISE EXCEPTION 'Ese plato del día es de otra unidad.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF NEW.menu_dia_id IS NOT NULL
           AND (SELECT unidad_id FROM core.menus_dia WHERE id = NEW.menu_dia_id) <> v_unidad THEN
            RAISE EXCEPTION 'Ese menú es de otra unidad.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'pedido_item_opciones' THEN
        SELECT i.menu_dia_id INTO v_otra FROM core.pedido_items i WHERE i.id = NEW.pedido_item_id;
        IF (SELECT mc.menu_dia_id FROM core.menu_opciones mo
              JOIN core.menu_categorias mc ON mc.id = mo.menu_categoria_id
             WHERE mo.id = NEW.menu_opcion_id) IS DISTINCT FROM v_otra THEN
            RAISE EXCEPTION 'Esa opción no es del menú de ese ítem.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'entradas_inventario' THEN
        SELECT iu.unidad_id INTO v_unidad FROM core.insumo_unidades iu WHERE iu.id = NEW.insumo_unidad_id;
        IF NEW.pedido_id IS NOT NULL
           AND (SELECT unidad_id FROM core.pedidos WHERE id = NEW.pedido_id) <> v_unidad THEN
            RAISE EXCEPTION 'Esa factura es de otra unidad.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        SELECT empresa_id INTO v_otra FROM core.usuarios WHERE id = NEW.usuario_id;
        IF v_otra IS NOT NULL AND v_otra <> core.fn_empresa_de_unidad(v_unidad) THEN
            RAISE EXCEPTION 'Ese usuario no es de la empresa de la unidad.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'cierre_detalles' THEN
        SELECT ci.unidad_id INTO v_unidad FROM core.cierres_inventario ci WHERE ci.id = NEW.cierre_id;
        IF (SELECT unidad_id FROM core.insumo_unidades WHERE id = NEW.insumo_unidad_id) <> v_unidad THEN
            RAISE EXCEPTION 'Ese producto no es de la unidad del cierre.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'bases_caja' THEN
        SELECT empresa_id INTO v_otra FROM core.usuarios WHERE id = NEW.usuario_id;
        IF v_otra IS NOT NULL AND v_otra <> core.fn_empresa_de_unidad(NEW.unidad_id) THEN
            RAISE EXCEPTION 'Ese usuario no es de la empresa de la unidad.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    ELSE
        RAISE EXCEPTION 'tg_relaciones_empresa no está preparado para %', TG_TABLE_NAME;
    END CASE;

    RETURN NEW;
END;
$$;

DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['pedidos', 'pedido_items', 'pedido_item_opciones',
                             'entradas_inventario', 'cierre_detalles', 'bases_caja']
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%1$s_relaciones ON core.%1$I', t);
        EXECUTE format(
            'CREATE TRIGGER trg_%1$s_relaciones BEFORE INSERT OR UPDATE ON core.%1$I
                 FOR EACH ROW EXECUTE FUNCTION core.tg_relaciones_empresa()', t);
    END LOOP;
END;
$$;

NOTIFY pgrst, 'reload schema';


/* ============================================================================
   20_MOTIVO_MARCA
   El motivo de marca de cada empresa
   ============================================================================ */

/* ============================================================================
   TASECA · 20 · MOTIVO DE MARCA DE CADA EMPRESA
   ----------------------------------------------------------------------------
   La banda decorativa que corta la portada bajo la primera pantalla —y las
   fichas que acompañan al logotipo— eran la bandera a cuadros de NASCAR,
   escrita a la fuerza en el CSS. Ahora son un dato más del tema de cada
   empresa: `core.empresas.patron`.

   Qué dibujo es cada motivo lo decide css/styles.css (`html[data-patron=…]`)
   y la lista de los que se pueden elegir está en js/data.js
   (NASCAR.PATRONES). La base sólo guarda CUÁL eligió la empresa: aquí no
   entra CSS de nadie, igual que con la tipografía.

   NADIE CAMBIA DE ASPECTO POR ESTE SCRIPT
     A todas las empresas que ya existen se les escribe 'cuadros', que es
     exactamente lo que se les ve hoy. Las empresas NUEVAS nacen con el
     motivo que traiga su plantilla, que nunca es el de carreras.

   No toca pedidos, ventas, pagos ni auditoría. Se puede ejecutar más de una
   vez sin efectos.
   Requiere: 00 … 15 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. MODELO
   ============================================================================ */

ALTER TABLE core.empresas ADD COLUMN IF NOT EXISTS patron VARCHAR(20);
COMMENT ON COLUMN core.empresas.patron IS
    'Id del motivo de marca, de la lista cerrada de la aplicación (NASCAR.PATRONES). NULL = el de siempre.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_empresas_patron') THEN
        ALTER TABLE core.empresas
            ADD CONSTRAINT ck_empresas_patron CHECK (patron IS NULL OR patron ~ '^[a-z0-9_-]{1,20}$');
    END IF;
END;
$$;

/* Lo que ya está publicado se queda como está. */
UPDATE core.empresas SET patron = 'cuadros' WHERE patron IS NULL;


/* ============================================================================
   2. VISTAS

   Columnas nuevas al final: CREATE OR REPLACE VIEW sólo deja añadir.
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_empresa_ficha AS
SELECT e.id AS empresa_id, e.codigo, e.nombre_comercial, e.razon_social, e.nit, e.eslogan, e.descripcion,
       e.estado, e.hora_corte_operativa, e.telefono, e.whatsapp, e.email, e.direccion, e.horario_general,
       e.instagram_url, e.facebook_url, e.tiempo_mesa, e.tiempo_domicilio,
       e.color_primario, e.color_secundario, e.color_acento, e.color_fondo,
       e.tipografia, e.logo_texto, e.logo_acento, e.iniciales, e.lema, e.plantilla, e.creado_en,
       core.fn_fecha_operativa(e.id, now()) AS jornada_actual,
       (SELECT i.actualizado_en FROM core.empresa_imagenes i WHERE i.empresa_id = e.id) AS imagenes_version,
       (SELECT jsonb_object_agg(m.modulo, m.activo) FROM api.v_empresa_modulos m WHERE m.empresa_id = e.id) AS modulos,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('codigo', mp.codigo, 'nombre', mp.nombre, 'grupo', mp.grupo_caja,
                                                     'descripcion', emp.descripcion, 'activo', emp.activo)
                                  ORDER BY emp.orden, mp.id)
                   FROM core.empresa_metodos_pago emp
                   JOIN core.metodos_pago mp ON mp.id = emp.metodo_pago_id
                  WHERE emp.empresa_id = e.id), '[]') AS metodos_pago,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('entidad', c.entidad, 'numero', c.numero, 'titular', c.titular)
                                  ORDER BY c.id)
                   FROM core.cuentas_recaudo c
                  WHERE c.empresa_id = e.id AND c.activa), '[]') AS cuentas,
       (SELECT count(*) FROM core.unidades u WHERE u.empresa_id = e.id) AS n_unidades,
       (SELECT count(*) FROM core.usuarios us WHERE us.empresa_id = e.id) AS n_usuarios,
       e.patron
  FROM core.empresas e;

CREATE OR REPLACE VIEW rest.empresas AS
SELECT v.empresa_id, v.codigo, v.nombre_comercial, v.eslogan, v.telefono, v.whatsapp, v.email, v.direccion,
       v.horario_general, v.tiempo_mesa, v.tiempo_domicilio, v.color_primario, v.color_secundario, v.color_acento,
       v.color_fondo, e.logo_url, v.hora_corte_operativa, v.jornada_actual,
       v.razon_social, v.nit, v.descripcion, v.instagram_url, v.facebook_url, v.tipografia, v.logo_texto,
       v.logo_acento, v.iniciales, v.lema, v.plantilla, v.estado, v.creado_en, v.imagenes_version,
       v.modulos, v.metodos_pago, v.cuentas, v.patron
  FROM api.v_empresa_ficha v
  JOIN core.empresas e ON e.id = v.empresa_id
 WHERE v.estado = 'activa';

/* `SELECT v.*` se guarda ya expandido, así que hay que volver a crearla
   para que vea la columna nueva. */
CREATE OR REPLACE VIEW rest.plataforma_empresas AS
SELECT v.*
  FROM api.v_empresa_ficha v
 WHERE api.fn_tiene_permiso(core.fn_jwt_usuario(), 'plataforma');


/* ============================================================================
   3. GUARDAR EL TEMA

   Misma puerta de siempre: sólo la plataforma. Una empresa no cambia su
   propio tema desde su panel, y mucho menos el de otra.
   ============================================================================ */

CREATE OR REPLACE PROCEDURE api.sp_guardar_tema_empresa(p_empresa_id INTEGER, p_usuario_id INTEGER, p_tema JSONB)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    c TEXT;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'plataforma');
    IF NOT EXISTS (SELECT 1 FROM core.empresas WHERE id = p_empresa_id) THEN
        RAISE EXCEPTION 'Esa empresa no existe.';
    END IF;
    FOREACH c IN ARRAY ARRAY['primary', 'secondary', 'accent', 'background'] LOOP
        IF NULLIF(p_tema ->> c, '') IS NOT NULL AND (p_tema ->> c) !~ '^#[0-9A-Fa-f]{6}$' THEN
            RAISE EXCEPTION 'Los colores deben tener el formato #RRGGBB.';
        END IF;
    END LOOP;
    IF NULLIF(p_tema ->> 'fontFamily', '') IS NOT NULL AND (p_tema ->> 'fontFamily') !~ '^[a-z0-9_-]{1,30}$' THEN
        RAISE EXCEPTION 'Tipografía no válida.';
    END IF;
    IF NULLIF(p_tema ->> 'patron', '') IS NOT NULL AND (p_tema ->> 'patron') !~ '^[a-z0-9_-]{1,20}$' THEN
        RAISE EXCEPTION 'Motivo de marca no válido.';
    END IF;

    UPDATE core.empresas
       SET color_primario   = COALESCE(NULLIF(p_tema ->> 'primary', ''), color_primario),
           color_secundario = COALESCE(NULLIF(p_tema ->> 'secondary', ''), color_secundario),
           color_acento     = COALESCE(NULLIF(p_tema ->> 'accent', ''), color_acento),
           color_fondo      = COALESCE(NULLIF(p_tema ->> 'background', ''), color_fondo),
           tipografia       = COALESCE(NULLIF(p_tema ->> 'fontFamily', ''), tipografia),
           patron           = COALESCE(NULLIF(p_tema ->> 'patron', ''), patron),
           logo_texto       = core.fn_texto(p_tema ->> 'logoTexto', 24),
           logo_acento      = core.fn_texto(p_tema ->> 'logoAcento', 24),
           iniciales        = upper(core.fn_texto(p_tema ->> 'iniciales', 3)),
           lema             = core.fn_texto(p_tema ->> 'lema', 80),
           actualizado_en   = now()
     WHERE id = p_empresa_id;

    -- Imágenes: sólo si vienen ("" = quitar)
    IF p_tema ? 'logo' OR p_tema ? 'favicon' THEN
        INSERT INTO core.empresa_imagenes (empresa_id) VALUES (p_empresa_id) ON CONFLICT (empresa_id) DO NOTHING;
        UPDATE core.empresa_imagenes
           SET logo    = CASE WHEN p_tema ? 'logo'    THEN NULLIF(p_tema ->> 'logo', '')    ELSE logo END,
               favicon = CASE WHEN p_tema ? 'favicon' THEN NULLIF(p_tema ->> 'favicon', '') ELSE favicon END,
               actualizado_en = now()
         WHERE empresa_id = p_empresa_id;
    END IF;
END;
$$;


/* ============================================================================
   4. REVISIÓN

   Todo lo que menciona la columna nueva va por SQL dinámico (EXECUTE). No es
   capricho: en el editor de Supabase, que habla con la base a través del
   pooler, un bloque PL/pgSQL puede compilarse contra el plan en caché de la
   tabla ANTERIOR al ALTER y quejarse de que «column patron does not exist»
   aunque la columna ya esté creada. Con EXECUTE la consulta se resuelve en el
   momento de ejecutarla y eso no puede pasar.
   ============================================================================ */

DO $$
DECLARE
    v_sin  INTEGER;
    v_col  BOOLEAN;
    v_tot  INTEGER;
BEGIN
    SELECT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'core.empresas'::regclass AND attname = 'patron' AND NOT attisdropped)
      INTO v_col;

    IF NOT v_col THEN
        RAISE EXCEPTION 'La columna core.empresas.patron no se creó: revisa el paso 1.';
    END IF;

    EXECUTE 'SELECT count(*) FROM core.empresas WHERE patron IS NULL' INTO v_sin;
    EXECUTE 'SELECT count(*) FROM core.empresas' INTO v_tot;

    RAISE NOTICE '--------------------------------------------------';
    RAISE NOTICE 'Columna core.empresas.patron ....... sí';
    RAISE NOTICE 'Empresas ........................... %', v_tot;
    RAISE NOTICE 'Empresas sin motivo definido ....... %', v_sin;
    RAISE NOTICE 'Vista rest.empresas publica patron . %',
        CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                           WHERE table_schema = 'rest' AND table_name = 'empresas' AND column_name = 'patron')
             THEN 'sí' ELSE 'NO' END;
    RAISE NOTICE '--------------------------------------------------';
END;
$$;

SELECT codigo, nombre_comercial, patron AS motivo_de_marca
  FROM core.empresas
 ORDER BY id;


/* ============================================================================
   19_RLS
   Seguridad a nivel de fila en todas las tablas
   ============================================================================ */

/* ============================================================================
   TASECA · 19 · SEGURIDAD A NIVEL DE FILA (RLS) EN TODAS LAS TABLAS
   ----------------------------------------------------------------------------
   Enciende RLS en todas las tablas de `core`, sin políticas. Efecto:

     · Nadie puede leer ni escribir una tabla DIRECTAMENTE, aunque algún día
       alguien le dé permisos por error o exponga el esquema en la API.
     · El DUEÑO de la tabla queda exento (así funciona PostgreSQL), y el dueño
       es quien ejecuta las vistas de `api` y los procedimientos
       SECURITY DEFINER. O sea: la aplicación sigue funcionando igual.

   Es el segundo candado. El primero ya estaba: `07_seguridad.sql` no le da a
   `taseca_app` ni a `taseca_anon` ningún permiso sobre las tablas de `core`,
   y a la API sólo se publica el esquema `rest`.

   En Supabase esto además calla el aviso "esta consulta crea tablas sin
   habilitar la seguridad a nivel de fila".

   Se puede ejecutar más de una vez. Para revisarlo:

       SELECT * FROM api.fn_estado_rls() WHERE NOT rls;
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. ENCENDER RLS
   ============================================================================ */

DO $$
DECLARE
    t         RECORD;
    v_nuevas  INTEGER := 0;
    v_ya      INTEGER := 0;
BEGIN
    FOR t IN
        SELECT c.relname, c.relrowsecurity
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'core' AND c.relkind = 'r'
         ORDER BY c.relname
    LOOP
        IF t.relrowsecurity THEN
            v_ya := v_ya + 1;
        ELSE
            EXECUTE format('ALTER TABLE core.%I ENABLE ROW LEVEL SECURITY', t.relname);
            v_nuevas := v_nuevas + 1;
        END IF;
    END LOOP;

    RAISE NOTICE 'RLS encendida en % tabla(s); ya lo estaba en %.', v_nuevas, v_ya;
END;
$$;


/* ============================================================================
   2. CÓMO REVISARLO DESPUÉS

   Devuelve una fila por tabla de `core` diciendo si tiene RLS y si alguien
   más que el dueño tiene permisos sobre ella. Lo segundo no debería pasar:
   si aparece un rol, algo le dio acceso directo a una tabla.
   ============================================================================ */

CREATE OR REPLACE FUNCTION api.fn_estado_rls()
RETURNS TABLE (tabla TEXT, rls BOOLEAN, politicas INTEGER, con_permisos TEXT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT c.relname::TEXT,
           c.relrowsecurity,
           (SELECT count(*)::INTEGER FROM pg_policy p WHERE p.polrelid = c.oid),
           COALESCE((SELECT string_agg(DISTINCT g.grantee, ', ')
                       FROM information_schema.role_table_grants g
                      WHERE g.table_schema = 'core'
                        AND g.table_name = c.relname
                        AND g.grantee NOT IN ('PUBLIC', c.relowner::REGROLE::TEXT)), '—')
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'core' AND c.relkind = 'r'
     ORDER BY c.relname;
$$;

COMMENT ON FUNCTION api.fn_estado_rls() IS
    'Una fila por tabla de core: si tiene RLS, cuántas políticas y qué roles (aparte del dueño) tienen permisos directos.';

REVOKE ALL ON FUNCTION api.fn_estado_rls() FROM PUBLIC;


/* ============================================================================
   3. REVISIÓN
   ============================================================================ */

DO $$
DECLARE
    v_sin_rls   INTEGER;
    v_con_perm  INTEGER;
BEGIN
    SELECT count(*) FILTER (WHERE NOT rls),
           count(*) FILTER (WHERE con_permisos <> '—')
      INTO v_sin_rls, v_con_perm
      FROM api.fn_estado_rls();

    IF v_sin_rls = 0 THEN
        RAISE NOTICE '✔ Todas las tablas de core tienen RLS';
    ELSE
        RAISE NOTICE '✗ Quedan % tabla(s) sin RLS', v_sin_rls;
    END IF;

    IF v_con_perm = 0 THEN
        RAISE NOTICE '✔ Ningún rol tiene permisos directos sobre las tablas de core';
    ELSE
        RAISE NOTICE '? % tabla(s) con permisos directos: SELECT * FROM api.fn_estado_rls() WHERE con_permisos <> ''—''', v_con_perm;
    END IF;
END;
$$;


/* ============================================================================
   ROLES DE SUPABASE
   authenticator y anon, y que quien instala pueda asumirlos
   ============================================================================ */

/* ============================================================================
   2. ROLES

   Supabase conecta con el rol `authenticator` y, según el token, cambia al
   rol que diga el campo `role`:

     · sin sesión (portal público) → anon        → tiene que poder lo de taseca_anon
     · con sesión (panel)          → taseca_app  → authenticator debe poder asumirlo

   Los roles taseca_app y taseca_anon los crean 07_seguridad.sql y
   09_postgrest.sql. Aquí sólo se conectan con los de Supabase.
   ============================================================================ */

DO $$
DECLARE
    v_rol TEXT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
        RAISE NOTICE 'No existe el rol authenticator: esto no parece un proyecto de Supabase. Se salta el paso 2.';
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'taseca_app') THEN
        RAISE NOTICE 'Todavía no existen los roles de Taseca (los crean 07 y 09).';
        RAISE NOTICE 'Sigue con los scripts 01 … 17 y vuelve a ejecutar este archivo al final.';
        RETURN;
    END IF;

    -- El panel entra como taseca_app
    EXECUTE 'GRANT taseca_app TO authenticator';

    -- El portal público entra como anon y necesita lo que puede taseca_anon
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        EXECUTE 'GRANT taseca_anon TO anon';
    END IF;

    -- Por si alguna herramienta entra directamente como taseca_anon
    EXECUTE 'GRANT taseca_anon TO authenticator';

    /* Quien instala (el editor SQL entra como `postgres`, que en Supabase NO
       es superusuario) también tiene que poder asumir los roles: es lo que
       hacen las pruebas con SET LOCAL ROLE, y hace falta para mantenimiento. */
    FOREACH v_rol IN ARRAY ARRAY['taseca_app', 'taseca_anon', 'taseca_lectura'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_rol) THEN
            EXECUTE format('GRANT %I TO %I', v_rol, current_user);
        END IF;
    END LOOP;

    RAISE NOTICE 'Roles conectados: authenticator puede asumir taseca_app y taseca_anon; anon hereda taseca_anon.';
    RAISE NOTICE 'El usuario % también puede asumirlos (lo necesitan las pruebas).', current_user;
END;
$$;




/* ============================================================================
   FIN · REVISIÓN
   ============================================================================ */

DO $final$
DECLARE
    v_tablas  INTEGER;
    v_vistas  INTEGER;
    v_rutinas INTEGER;
    v_sin_rls INTEGER;
BEGIN
    SELECT count(*) INTO v_tablas  FROM pg_tables  WHERE schemaname = 'core';
    SELECT count(*) INTO v_vistas  FROM pg_views   WHERE schemaname IN ('api', 'rest');
    SELECT count(*) INTO v_rutinas FROM information_schema.routines WHERE routine_schema IN ('api', 'rest');
    SELECT count(*) INTO v_sin_rls FROM api.fn_estado_rls() WHERE NOT rls;

    RAISE NOTICE '---------------------------------------------';
    RAISE NOTICE 'Taseca instalada';
    RAISE NOTICE '  tablas en core        : %', v_tablas;
    RAISE NOTICE '  vistas en api y rest  : %', v_vistas;
    RAISE NOTICE '  funciones y procs     : %', v_rutinas;
    RAISE NOTICE '  tablas sin RLS        : %', v_sin_rls;
    RAISE NOTICE '---------------------------------------------';
    RAISE NOTICE 'Siguiente paso: la contraseña del usuario de conexión';
    RAISE NOTICE '  ALTER ROLE taseca_rest LOGIN PASSWORD ''una-contraseña-larga'';';
    RAISE NOTICE 'Y, si usas el Data API de Supabase, el JWT secret (al final del archivo).';
END;
$final$;

/* Sólo si vas a usar el Data API de Supabase en vez de nuestro PostgREST:
   pega aquí el JWT secret del proyecto (Settings → API → JWT Settings) y
   ejecuta esta sentencia sola.

   UPDATE core.jwt_config
      SET secreto = 'PEGA-AQUI-EL-JWT-SECRET-DEL-PROYECTO'
    WHERE id = (SELECT max(id) FROM core.jwt_config);
*/
