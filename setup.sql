-- Preferencias · configuración de Supabase (versión 3)
-- Texto, fotos, audios, edición, borrado, mensajes temporales y avisos.
-- Pégalo entero en Supabase → SQL Editor → Run.
-- Se puede ejecutar varias veces sin perder mensajes.
--
-- Diseño: las tablas están cerradas al público. Solo se accede mediante
-- funciones que exigen conocer el identificador de sala (64 caracteres
-- derivados de vuestro código de acceso). El servidor solo guarda datos cifrados.

-- ===== Mensajes =====
create table if not exists public.mensajes (
  id    bigint generated always as identity primary key,
  sala  text   not null,
  datos text
);
create sequence if not exists public.mensajes_version;
alter table public.mensajes alter column datos drop not null;
alter table public.mensajes add column if not exists version  bigint;
alter table public.mensajes add column if not exists caduca   timestamptz;
alter table public.mensajes add column if not exists cambiado timestamptz default now();
update public.mensajes set version = nextval('public.mensajes_version') where version is null;
alter table public.mensajes alter column version set default nextval('public.mensajes_version');
alter table public.mensajes alter column version set not null;
create index if not exists mensajes_sala_id      on public.mensajes (sala, id);
create index if not exists mensajes_sala_version on public.mensajes (sala, version);
alter table public.mensajes enable row level security;
revoke all on public.mensajes from anon, authenticated;

-- ===== Adjuntos (fotos y audios, cifrados) =====
create table if not exists public.adjuntos (
  id    bigint generated always as identity primary key,
  sala  text   not null,
  datos bytea  not null
);
alter table public.adjuntos add column if not exists caduca timestamptz;
create index if not exists adjuntos_sala_id on public.adjuntos (sala, id);
alter table public.adjuntos enable row level security;
revoke all on public.adjuntos from anon, authenticated;

-- ===== Avisos (notificaciones) =====
create table if not exists public.suscripciones (
  endpoint text primary key,
  sala     text not null,
  disp     text not null,
  p256dh   text not null,
  auth     text not null
);
alter table public.suscripciones enable row level security;
revoke all on public.suscripciones from anon, authenticated;

create table if not exists public.configuracion (
  clave text primary key,
  valor text not null
);
alter table public.configuracion enable row level security;
revoke all on public.configuracion from anon, authenticated;

-- El servicio de avisos (Edge Function) usa el rol interno service_role
grant select, insert, update, delete on public.suscripciones to service_role;
grant select, insert, update, delete on public.configuracion to service_role;

-- ===== Funciones (se borran las versiones antiguas) =====
drop function if exists public.leer(text, bigint);
drop function if exists public.enviar(text, text);
drop function if exists public.enviar(text, text, integer);
drop function if exists public.subir(text, text);
drop function if exists public.subir(text, text, integer);

-- Cambios desde una versión: mensajes nuevos, editados y borrados (datos nulo)
create function public.leer(p_sala text, p_desde bigint)
returns table (id bigint, version bigint, datos text)
language plpgsql security definer set search_path = public as $$
begin
  -- Mensajes temporales caducados: se borran de verdad
  update mensajes m set datos = null, caduca = null, cambiado = now(),
         version = nextval('mensajes_version')
   where m.sala = p_sala and m.caduca < now() and m.datos is not null;
  delete from adjuntos a where a.sala = p_sala and a.caduca < now();
  -- Marcas de borrado antiguas: ya no hacen falta
  delete from mensajes m where m.sala = p_sala and m.datos is null and m.cambiado < now() - interval '30 days';

  return query
    select m.id, m.version, m.datos from mensajes m
     where m.sala = p_sala and m.version > p_desde
     order by m.version
     limit 200;
end $$;

create function public.enviar(p_sala text, p_datos text, p_ttl integer default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare nuevo bigint;
begin
  if length(p_sala) <> 64 or length(p_datos) > 24000 then
    raise exception 'petición no válida';
  end if;
  insert into mensajes (sala, datos, caduca)
  values (p_sala, p_datos, case when p_ttl > 0 then now() + make_interval(secs => p_ttl) end)
  returning id into nuevo;
  return nuevo;
end $$;

create function public.subir(p_sala text, p_datos text, p_ttl integer default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare nuevo bigint;
begin
  if length(p_sala) <> 64 or length(p_datos) > 2000000 then
    raise exception 'petición no válida';
  end if;
  insert into adjuntos (sala, datos, caduca)
  values (p_sala, decode(p_datos, 'base64'),
          case when p_ttl > 0 then now() + make_interval(secs => p_ttl) + interval '1 hour' end)
  returning id into nuevo;
  return nuevo;
end $$;

create or replace function public.bajar(p_sala text, p_id bigint)
returns text
language sql security definer set search_path = public as $$
  select replace(encode(a.datos, 'base64'), E'\n', '')
  from adjuntos a
  where a.sala = p_sala and a.id = p_id;
$$;

create or replace function public.editar(p_sala text, p_id bigint, p_datos text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if length(p_datos) > 24000 then raise exception 'petición no válida'; end if;
  update mensajes set datos = p_datos, cambiado = now(), version = nextval('mensajes_version')
   where sala = p_sala and id = p_id and datos is not null;
end $$;

create or replace function public.borrar(p_sala text, p_id bigint, p_adj bigint default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update mensajes set datos = null, caduca = null, cambiado = now(), version = nextval('mensajes_version')
   where sala = p_sala and id = p_id and datos is not null;
  if p_adj is not null then
    delete from adjuntos where sala = p_sala and id = p_adj;
  end if;
end $$;

create or replace function public.vaciar(p_sala text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update mensajes set datos = null, caduca = null, cambiado = now(), version = nextval('mensajes_version')
   where sala = p_sala and datos is not null;
  delete from adjuntos where sala = p_sala;
end $$;

create or replace function public.suscribir(p_sala text, p_disp text, p_endpoint text, p_p256dh text, p_auth text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if length(p_sala) <> 64 or length(p_disp) > 64 or length(p_endpoint) > 1000
     or p_endpoint not like 'https://%' or length(p_p256dh) > 200 or length(p_auth) > 100 then
    raise exception 'petición no válida';
  end if;
  insert into suscripciones (endpoint, sala, disp, p256dh, auth)
  values (p_endpoint, p_sala, p_disp, p_p256dh, p_auth)
  on conflict (endpoint) do update
    set sala = excluded.sala, disp = excluded.disp, p256dh = excluded.p256dh, auth = excluded.auth;
end $$;

create or replace function public.desuscribir(p_endpoint text)
returns void
language sql security definer set search_path = public as $$
  delete from suscripciones where endpoint = p_endpoint;
$$;

-- ===== Permisos =====
do $$
declare f text;
begin
  foreach f in array array[
    'leer(text, bigint)', 'enviar(text, text, integer)', 'subir(text, text, integer)',
    'bajar(text, bigint)', 'editar(text, bigint, text)', 'borrar(text, bigint, bigint)',
    'vaciar(text)', 'suscribir(text, text, text, text, text)', 'desuscribir(text)'
  ] loop
    execute format('revoke execute on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon', f);
  end loop;
end $$;
