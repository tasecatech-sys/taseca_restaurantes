/* ============================================================================
   ANDAMIO · lo que Supabase pone y un PostgreSQL pelado no
   ----------------------------------------------------------------------------
   ESTO NO ES PARTE DE TASECA. Es el mínimo para poder correr
   SUPABASE_INSTALAR.sql contra un contenedor limpio y ver si se instala
   de principio a fin.

   Lo que monta, y por qué:

     · pgcrypto        — lo usa core.* para los PIN.
     · el esquema storage, con buckets, objects y foldername(), que es lo
       único que toca la migración 27. Las columnas son las que esa
       migración usa; no pretende ser el storage real de Supabase.
     · los roles authenticator y anon. El propio instalador ya se salta
       ese tramo si no existen («esto no parece un proyecto de Supabase»),
       pero creándolos se prueba también ese tramo.

   Lo que el andamio NO prueba: que el storage DE VERDAD de Supabase se
   comporte igual. Eso sólo se ve en un proyecto Supabase.
   ============================================================================ */

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Supabase guarda pgcrypto en el esquema `extensions`; el instalador deja
-- atajos en public contando con eso. Aquí ya está en public, así que basta.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
        CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD 'andamio';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        CREATE ROLE anon NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        CREATE ROLE service_role NOLOGIN BYPASSRLS;
    END IF;
END;
$$;

CREATE SCHEMA IF NOT EXISTS storage;

CREATE TABLE IF NOT EXISTS storage.buckets (
    id                 TEXT PRIMARY KEY,
    name               TEXT NOT NULL,
    public             BOOLEAN DEFAULT FALSE,
    file_size_limit    BIGINT,
    allowed_mime_types TEXT[],
    created_at         TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS storage.objects (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bucket_id  TEXT REFERENCES storage.buckets(id),
    name       TEXT,
    owner      UUID,
    created_at TIMESTAMPTZ DEFAULT now(),
    metadata   JSONB
);

ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

/* Parte la ruta por '/': de 'empresa_nascar/00123.jpg' saca {empresa_nascar}.
   Misma forma que la de Supabase: devuelve el array SIN el nombre del
   archivo. */
CREATE OR REPLACE FUNCTION storage.foldername(name TEXT)
RETURNS TEXT[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    partes TEXT[];
BEGIN
    partes := string_to_array(name, '/');
    RETURN partes[1 : array_length(partes, 1) - 1];
END;
$$;

SELECT 'andamio listo' AS estado;
