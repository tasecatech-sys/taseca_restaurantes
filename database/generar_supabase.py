# ============================================================================
#  Arma SUPABASE_INSTALAR.sql: toda la base en un solo archivo, en el orden
#  que necesita Supabase.
#
#  No duplica nada: pega los scripts de siempre tal como están, así que lo que
#  se corrija en ellos aparece aquí con sólo volver a ejecutar:
#
#      py database/generar_supabase.py
# ============================================================================

import io
import os

AQUI = os.path.dirname(os.path.abspath(__file__))

# El 00 no va: Supabase ya trae la base creada.
# El 18 se parte en dos: sus atajos de cifrado van al principio (sin ellos el
# 02 no se puede crear) y sus roles al final (sólo existen después del 09).
PARTES = [
    ('01_estructura.sql',                    'Esquemas, tablas, llaves e índices'),
    ('02_funciones.sql',                     'Funciones internas: jornada, consecutivos, permisos, PIN'),
    ('03_triggers.sql',                      'Reglas del negocio que la base hace cumplir sola'),
    ('04_procedimientos.sql',                'Todo lo que escribe pasa por aquí'),
    ('05_vistas.sql',                        'Lo que la aplicación lee'),
    ('06_datos_iniciales.sql',               'Catálogos y la estructura de ejemplo (NASCAR)'),
    ('07_seguridad.sql',                     'Roles taseca_app y taseca_lectura'),
    ('09_postgrest.sql',                     'Capa REST, roles de la API y tokens'),
    ('10_optimizacion.sql',                  'Auditoría liviana, índices y reportes'),
    ('11_fase2_carta_menu.sql',              'Fase 2 · carta y menú del día'),
    ('12_fase2_usuarios_unidades.sql',       'Fase 2 · usuarios y unidades'),
    ('13_fase2_inventario.sql',              'Fase 2 · stock, entradas y cierres'),
    ('14_fase2_caja_gastos.sql',             'Fase 2 · base de caja, gastos y cruce'),
    ('15_fase2_configuracion_plataforma.sql','Fase 2 · configuración, ajustes y plataforma'),
    ('16_pagos_en_caja.sql',                 'Todos los pagos se confirman en caja'),
    ('17_integridad_multiempresa.sql',       'Chequeo de relaciones y red de seguridad'),
    ('22_relaciones_empresa_completas.sql',  'Red de seguridad completa en el camino de un pedido'),

    # ---- OJO CON EL ORDEN DE LA 23 Y LA 25 -----------------------------
    # La 23 borra la firma de sp_crear_pedido de 14 argumentos -la del 04-
    # y crea la de 15, con p_clave. La 25 borra la de 15 y crea la suya,
    # que lleva p_clave Y la venta directa.
    #
    # Aqui la 23 estaba DESPUES de la 25, y eso rompia la instalacion:
    # la 25 no encontraba nada que borrar y quedaban dos versiones del
    # procedimiento. Su propio chequeo lo cazaba y paraba el instalador
    # («Quedaron 3 versiones de los procedimientos»). Y de no pararlo,
    # habria sido peor: la 23 habria corrido despues pisando la version
    # de la 25 y dejando la venta directa rota en silencio.
    ('23_pedidos_sin_duplicados.sql',        'Un envío, un pedido: candado contra facturas repetidas'),
    ('24_arranque_en_un_viaje.sql',          'Abrir el panel en una sola petición'),
    ('25_venta_directa.sql',                 'Venta directa en el mostrador'),
    ('26_anulacion_por_item.sql',            'Al anular, qué vuelve al stock y qué se da de baja'),
    ('20_motivo_marca.sql',                  'El motivo de marca de cada empresa'),

    # ---- Lo de después de la 20. Van AQUÍ, entre la 20 y la 19, y en este
    #      orden, porque se apoyan unas en otras:
    #        · la 31 reconstruye api.v_empresa_ficha incluyendo el `patron`
    #          de la 20 y el recargo de la 30, así que va detrás de las dos;
    #        · la 30 parchea los DOS rest.crear_pedido, y el segundo nace en
    #          la 23, que ya está más arriba;
    #        · la 32 busca una condición dentro de api.sp_crear_pedido, cuya
    #          última definición viene de la 23;
    #        · la 19 se queda la última, como estaba, porque enciende RLS
    #          sobre todas las tablas y estas tres añaden columnas.
    #
    #      NO están la 33, la 36 ni la 41: eran parches para bases YA
    #      instaladas. Sus fallos se corrigieron en origen -la 30, la 15, y
    #      la 41 en la 01 (columnas) y la 09 (rest.login con el freno)-, así
    #      que en una instalación nueva sobrarían. La 34 y la 35 sí están,
    #      porque arreglan funciones que nacen en los scripts base y no hay
    #      dónde corregirlas antes.
    ('27_fotos_en_storage.sql',              'Las fotos de la carta viven en Storage'),
    ('28_recetas_cantidad.sql',              'Cuánto gasta cada plato de cada insumo'),
    ('29_billeteras_separadas.sql',          'Nequi, Daviplata y Bre-B, cada una por su lado'),
    ('30_recargo_por_metodo.sql',            'El recargo que la empresa le cobra por método de pago'),
    ('31_modo_claro.sql',                    'Cada empresa elige si se ve clara u oscura'),
    ('32_recoger_en_sitio.sql',              'Recoger el pedido en el local'),
    ('34_reportar_pago_con_billeteras.sql',  'Reportar el pago desde Nequi, Daviplata y Bre-B'),
    ('35_avanzar_desde_donde_se_ve.sql',     'Avanzar un pedido solo desde donde se esta viendo'),
    # La 40 esta aqui, y no corregida en la 16, por lo mismo que la 34 y la
    # 35: arregla api.sp_actualizar_pago, que nace en la 16, pero necesita
    # core.fn_recargo_pago, que no existe hasta la 30. No hay donde
    # corregirla antes.
    ('40_el_recargo_sigue_al_metodo.sql',    'Si caja cambia el metodo de pago, el recargo lo sigue'),
    # La 37 (cobrar varios pedidos de una vez) ya corría en producción pero
    # faltaba aquí: una instalación nueva quedaba sin rest.confirmar_pagos.
    # Va después de la 40 porque llama a api.sp_actualizar_pago.
    ('37_cobrar_en_lote.sql',                'Cobrar varios pedidos de una vez'),

    # La 42 va despues de la 24 (rest.arranque) y de la ultima recreacion de la
    # vista rest.empresas (la 31), para quitarle a anon el SELECT directo y que
    # el arranque sin sesion no entregue razon social ni correo.
    ('42_el_escaparate_no_filtra.sql',       'El escaparate anonimo no filtra razon social, correo ni la vista entera'),

    ('19_rls.sql',                           'Seguridad a nivel de fila en todas las tablas'),

    # Al final del todo: cuando ya existen TODAS las funciones, se le fija el
    # search_path a las que les faltaba (los triggers y ayudantes de core, y
    # los atajos de pgcrypto en public). Defensa en profundidad + linter limpio.
    ('43_search_path_fijo.sql',              'Cada funcion con su search_path fijo (cierra el linter)'),

    # Corrige el alcance de la 42: devuelve a anon las 11 columnas de marca que
    # necesita el directorio publico, y le quita a taseca_app el SELECT directo
    # sobre rest.empresas (lo leia de otras empresas). Va despues de la 42.
    ('44_vitrina_publica_por_columnas.sql',  'anon ve solo la marca del directorio; app no lee la ficha de otras'),

    # El menú del chef puede pedir acompañamientos (opcional, por menú). Va al
    # final: redefine sp_crear_pedido y dos triggers ya existentes.
    ('45_chef_con_acompanamientos.sql',      'El menu del chef puede dejar que el cliente elija sopa y bebida'),

    # El panel guarda el interruptor de acompañamientos (rest.sincronizar_catalogo).
    ('46_sincronizar_guarda_acompanamientos.sql', 'El panel guarda el interruptor de acompañamientos del chef'),
    ('47_plato_chef_con_imagen.sql',          'El plato del chef puede tener foto'),

    # Productos «solo personal»: mesero y caja sí, el cliente no. Va al final:
    # redefine rest.carta (de la 25), el trigger de ítems (de la 03, con su
    # search_path de la 43) y rest.sincronizar_catalogo (de la 47).
    ('49_solo_personal.sql',                  'Productos solo para el personal: el mesero los vende, el cliente no los ve'),

    # Despieces: una entrada (Pollo entero) que llena varios insumos (presas).
    # Va al final: redefine rest.entradas y rest.inventario_marca (de la 13),
    # el trigger de entradas inmutables (de la 13, con su search_path de la 43)
    # y crea dos tablas con RLS encendida a mano (la 19 ya pasó).
    ('50_despiece_de_entradas.sql',           'Despieces: comprar un pollo entero y que se llenen las presas'),

    # Qué domiciliario llevó cada pedido, para cobrarle el efectivo. Va al
    # final: redefine core.fn_pedido_json (de la 09) y pone un trigger nuevo
    # en core.pedidos.
    ('51_domiciliario_del_pedido.sql',        'Qué domiciliario llevó cada pedido, para cobrarle el efectivo'),

    # Comanda impresa por sede (opcional). Va al final: redefine las dos
    # rest.crear_pedido (de la 30) y la vista rest.unidades.
    ('52_comanda_impresa.sql',                'Comanda impresa: la cocina no toca el sistema, caja marca «Listo»'),
]

CABECERA = '''/* ============================================================================
   TASECA · LA BASE COMPLETA, EN UN SOLO ARCHIVO (para Supabase)
   ----------------------------------------------------------------------------
   Crea todo: tablas, funciones, triggers, procedimientos, vistas, catálogos,
   la estructura de ejemplo de NASCAR, la capa REST, la fase 2 completa, el
   chequeo de integridad y la seguridad a nivel de fila.

   GENERADO, NO SE EDITA A MANO. Sale de pegar los scripts 01 … 32 con
   `py database/generar_supabase.py`. Si hay que corregir algo, se corrige en
   el script original y se vuelve a generar.

   CÓMO EJECUTARLO

     Opción A · editor SQL de Supabase
       Pega el contenido y dale a RUN. Tarda un par de minutos. Cuando
       pregunte por RLS, responde «Ejecuta y habilita RLS» (este archivo la
       enciende igual al final).

     Opción B · desde tu computador, más cómodo para un archivo grande
       psql "postgresql://postgres:TU-CONTRASEÑA@db.TU-PROYECTO.supabase.co:5432/postgres" \\
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

'''

CIERRE = '''

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
'''


def leer(nombre):
    return io.open(os.path.join(AQUI, nombre), encoding='utf-8').read()


def seccion(titulo, detalle=''):
    linea = '=' * 76
    return ('\n\n/* %s\n   %s\n   %s\n   %s */\n\n'
            % (linea, titulo.upper(), detalle, linea))


def atajos_de_cifrado():
    """La parte 1 del 18: deja en public lo que Supabase guarda en extensions."""
    texto = leer('18_supabase.sql')
    ini = texto.index('/* ============================================================================\n   1. FUNCIONES DE CIFRADO')
    fin = texto.index('/* ============================================================================\n   2. ROLES')
    return texto[ini:fin]


def roles_de_supabase():
    """La parte 2 del 18: conectar nuestros roles con los de Supabase."""
    texto = leer('18_supabase.sql')
    ini = texto.index('/* ============================================================================\n   2. ROLES')
    fin = texto.index('/* ============================================================================\n   3. TOKENS')
    return texto[ini:fin]


def datos_marcados():
    """El 06 con los datos de ejemplo señalados, para poder quitarlos."""
    texto = leer('06_datos_iniciales.sql')
    marca = '/* ---------------------------------------------------------------- EMPRESA NASCAR */'
    aviso = ('\n/* ▼▼▼ DATOS DE EJEMPLO ▼▼▼  Desde aquí hasta el final de este bloque está\n'
             '   la estructura de NASCAR (empresa, locales, usuarios, carta, inventario y\n'
             '   menús). Para arrancar con la plataforma vacía, borra desde esta línea\n'
             '   hasta donde dice «FIN DE LOS DATOS DE EJEMPLO». Los catálogos de arriba\n'
             '   (estados, roles, permisos, métodos de pago…) SÍ hacen falta siempre. */\n\n')
    return texto.replace(marca, aviso + marca, 1) + \
        '\n/* ▲▲▲ FIN DE LOS DATOS DE EJEMPLO ▲▲▲ */\n'


def main():
    partes = [CABECERA]

    partes.append(seccion('0 · funciones de cifrado',
                          'pgcrypto vive en otro esquema en Supabase: se deja un atajo en public'))
    partes.append(atajos_de_cifrado())

    for archivo, detalle in PARTES:
        partes.append(seccion(archivo.replace('.sql', ''), detalle))
        partes.append(datos_marcados() if archivo == '06_datos_iniciales.sql' else leer(archivo))

    partes.append(seccion('roles de supabase',
                          'authenticator y anon, y que quien instala pueda asumirlos'))
    partes.append(roles_de_supabase())
    partes.append(CIERRE)

    salida = os.path.join(AQUI, 'SUPABASE_INSTALAR.sql')
    io.open(salida, 'w', encoding='utf-8', newline='\n').write(''.join(partes))

    kb = os.path.getsize(salida) / 1024
    print('OK  ->  database/SUPABASE_INSTALAR.sql  (%.0f KB, %d scripts)' % (kb, len(PARTES) + 1))


if __name__ == '__main__':
    main()
