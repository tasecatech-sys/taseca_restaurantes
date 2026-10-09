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
    ('20_motivo_marca.sql',                  'El motivo de marca de cada empresa'),
    ('19_rls.sql',                           'Seguridad a nivel de fila en todas las tablas'),
]

CABECERA = '''/* ============================================================================
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
