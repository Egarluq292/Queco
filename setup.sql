-- Preferencias · configuración de Supabase (versión 4)
-- Texto, fotos, audios, edición, borrado, mensajes temporales, avisos y sala cerrada.
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

-- ===== «Escribiendo…» (dura unos segundos; una fila por móvil) =====
create table if not exists public.presencia (
  sala  text not null,
  disp  text not null,
  hasta timestamptz not null,
  primary key (sala, disp)
);
alter table public.presencia add column if not exists activo timestamptz;
alter table public.presencia enable row level security;
revoke all on public.presencia from anon, authenticated;

-- ===== Sala cerrada: solo los móviles admitidos =====
-- Cada móvil tiene una «llave» propia (identificador + secreto aleatorio) que nunca sale de él;
-- aquí solo se guarda su huella SHA-256. Con la sala cerrada, sin llave admitida no se accede a nada.
create table if not exists public.salas_cerradas (
  sala       text primary key,
  cerrada_en timestamptz not null default now()
);
alter table public.salas_cerradas enable row level security;
revoke all on public.salas_cerradas from anon, authenticated;

create table if not exists public.dispositivos (
  sala   text not null,
  huella text not null,                -- sha256 de la llave del móvil
  disp   text not null,
  estado text not null default 'admitido',  -- 'admitido' | 'pendiente'
  info   text,                         -- nombre y tipo de móvil, cifrados con la clave de la sala
  creado timestamptz not null default now(),
  visto  timestamptz not null default now(),
  primary key (sala, huella)
);
alter table public.dispositivos enable row level security;
revoke all on public.dispositivos from anon, authenticated;

-- El servicio de avisos (Edge Function) usa el rol interno service_role
grant select, insert, update, delete on public.suscripciones to service_role;
grant select, insert, update, delete on public.configuracion to service_role;

-- ===== Funciones (se borran las versiones antiguas) =====
drop function if exists public.leer(text, bigint);
drop function if exists public.enviar(text, text);
drop function if exists public.enviar(text, text, integer);
drop function if exists public.subir(text, text);
drop function if exists public.subir(text, text, integer);
drop function if exists public.bajar(text, bigint);
drop function if exists public.editar(text, bigint, text);
drop function if exists public.borrar(text, bigint, bigint);
drop function if exists public.vaciar(text);
drop function if exists public.suscribir(text, text, text, text, text);
drop function if exists public.escribir(text, text, boolean);
drop function if exists public.escribiendo(text, text);
drop function if exists public.latido(text, text);
drop function if exists public.presencia_otro(text, text);

create or replace function public.huella(p_llave text) returns text
language sql immutable as $$ select encode(sha256(convert_to(coalesce(p_llave, ''), 'UTF8')), 'hex') $$;

-- Si la sala está cerrada, solo pasan los móviles admitidos
create or replace function public.comprobar_acceso(p_sala text, p_llave text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from salas_cerradas where sala = p_sala) then return; end if;
  if p_llave is null or not exists (
    select 1 from dispositivos d where d.sala = p_sala and d.estado = 'admitido' and d.huella = huella(p_llave)
  ) then
    raise exception 'sala cerrada';
  end if;
end $$;

-- Cambios desde una versión: mensajes nuevos, editados y borrados.
-- datos nulo = lo borró quien lo envió (el otro lo conserva en su móvil);
-- datos vacío = caducado o conversación vaciada (desaparece para los dos).
create or replace function public.leer(p_sala text, p_desde bigint, p_llave text default null)
returns table (id bigint, version bigint, datos text)
language plpgsql security definer set search_path = public as $$
begin
  perform comprobar_acceso(p_sala, p_llave);
  -- Mensajes temporales caducados: se borran de verdad
  update mensajes m set datos = '', caduca = null, cambiado = now(),
         version = nextval('mensajes_version')
   where m.sala = p_sala and m.caduca < now() and m.datos <> '';
  delete from adjuntos a where a.sala = p_sala and a.caduca < now();
  -- Marcas de borrado antiguas: ya no hacen falta
  delete from mensajes m where m.sala = p_sala and (m.datos is null or m.datos = '') and m.cambiado < now() - interval '30 days';

  return query
    select m.id, m.version, m.datos from mensajes m
     where m.sala = p_sala and m.version > p_desde
     order by m.version
     limit 200;
end $$;

create or replace function public.enviar(p_sala text, p_datos text, p_ttl integer default null, p_llave text default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare nuevo bigint;
begin
  perform comprobar_acceso(p_sala, p_llave);
  if length(p_sala) <> 64 or length(p_datos) > 24000 then
    raise exception 'petición no válida';
  end if;
  insert into mensajes (sala, datos, caduca)
  values (p_sala, p_datos, case when p_ttl > 0 then now() + make_interval(secs => p_ttl) end)
  returning id into nuevo;
  return nuevo;
end $$;

create or replace function public.subir(p_sala text, p_datos text, p_ttl integer default null, p_llave text default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare nuevo bigint;
begin
  perform comprobar_acceso(p_sala, p_llave);
  if length(p_sala) <> 64 or length(p_datos) > 2000000 then
    raise exception 'petición no válida';
  end if;
  insert into adjuntos (sala, datos, caduca)
  values (p_sala, decode(p_datos, 'base64'),
          case when p_ttl > 0 then now() + make_interval(secs => p_ttl) + interval '1 hour' end)
  returning id into nuevo;
  return nuevo;
end $$;

create or replace function public.bajar(p_sala text, p_id bigint, p_llave text default null)
returns text
language plpgsql security definer set search_path = public as $$
begin
  perform comprobar_acceso(p_sala, p_llave);
  return (select replace(encode(a.datos, 'base64'), E'\n', '') from adjuntos a where a.sala = p_sala and a.id = p_id);
end $$;

create or replace function public.editar(p_sala text, p_id bigint, p_datos text, p_llave text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform comprobar_acceso(p_sala, p_llave);
  if length(p_datos) > 24000 then raise exception 'petición no válida'; end if;
  update mensajes set datos = p_datos, cambiado = now(), version = nextval('mensajes_version')
   where sala = p_sala and id = p_id and datos <> '';
end $$;

create or replace function public.borrar(p_sala text, p_id bigint, p_adj bigint default null, p_llave text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform comprobar_acceso(p_sala, p_llave);
  update mensajes set datos = null, caduca = null, cambiado = now(), version = nextval('mensajes_version')
   where sala = p_sala and id = p_id and datos <> '';
  if p_adj is not null then
    delete from adjuntos where sala = p_sala and id = p_adj;
  end if;
end $$;

create or replace function public.vaciar(p_sala text, p_llave text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform comprobar_acceso(p_sala, p_llave);
  update mensajes set datos = '', caduca = null, cambiado = now(), version = nextval('mensajes_version')
   where sala = p_sala and (datos is null or datos <> '');
  delete from adjuntos where sala = p_sala;
end $$;

create or replace function public.suscribir(p_sala text, p_disp text, p_endpoint text, p_p256dh text, p_auth text, p_llave text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform comprobar_acceso(p_sala, p_llave);
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

-- Avisar de que se está escribiendo (p_activo = false: ha dejado de escribir)
create or replace function public.escribir(p_sala text, p_disp text, p_activo boolean default true, p_llave text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform comprobar_acceso(p_sala, p_llave);
  if length(p_sala) <> 64 or length(p_disp) > 64 then raise exception 'petición no válida'; end if;
  insert into presencia (sala, disp, hasta)
  values (p_sala, p_disp, case when p_activo then now() + interval '6 seconds' else now() end)
  on conflict (sala, disp) do update set hasta = excluded.hasta;
end $$;

-- ¿Está escribiendo alguien que no sea este móvil?
create or replace function public.escribiendo(p_sala text, p_disp text, p_llave text default null)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  perform comprobar_acceso(p_sala, p_llave);
  return exists (select 1 from presencia where sala = p_sala and disp <> p_disp and hasta > now());
end $$;

-- «En línea»: el móvil con la app abierta avisa cada pocos segundos
create or replace function public.latido(p_sala text, p_disp text, p_llave text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform comprobar_acceso(p_sala, p_llave);
  if length(p_sala) <> 64 or length(p_disp) > 64 then raise exception 'petición no válida'; end if;
  insert into presencia (sala, disp, hasta, activo) values (p_sala, p_disp, now(), now())
  on conflict (sala, disp) do update set activo = now();
end $$;

-- Estado del otro: si está escribiendo y cuándo tuvo la app abierta por última vez
create or replace function public.presencia_otro(p_sala text, p_disp text, p_llave text default null)
returns table (escribiendo boolean, ultima timestamptz, ahora timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  perform comprobar_acceso(p_sala, p_llave);
  return query select coalesce(bool_or(p.hasta > now()), false), max(p.activo), now()
    from presencia p where p.sala = p_sala and p.disp <> p_disp;
end $$;

-- ===== Sala cerrada: presentarse, ver móviles, cerrar/abrir, admitir/quitar =====
-- Cada móvil se presenta al entrar. Con la sala abierta queda admitido; cerrada, queda pendiente
-- hasta que un móvil admitido lo permita.
create or replace function public.presentarse(p_sala text, p_llave text, p_info text default null)
returns table (cerrada boolean, estado text)
language plpgsql security definer set search_path = public as $$
declare h text := huella(p_llave); d text := split_part(p_llave, '.', 1);
        esta_cerrada boolean := exists (select 1 from salas_cerradas where sala = p_sala); e text;
begin
  if length(p_sala) <> 64 or length(p_llave) not between 20 and 200 or length(coalesce(p_info, '')) > 2000 then
    raise exception 'petición no válida';
  end if;
  select x.estado into e from dispositivos x where x.sala = p_sala and x.huella = h;
  if e is null then
    if esta_cerrada then
      -- como mucho 5 solicitudes pendientes; se descartan las más antiguas
      delete from dispositivos x where x.sala = p_sala and x.estado = 'pendiente'
        and x.huella in (select y.huella from dispositivos y where y.sala = p_sala and y.estado = 'pendiente' order by y.creado desc offset 4);
      e := 'pendiente';
    else
      e := 'admitido';
    end if;
    insert into dispositivos (sala, huella, disp, estado, info) values (p_sala, h, d, e, p_info);
  else
    update dispositivos x set visto = now(), info = coalesce(p_info, x.info) where x.sala = p_sala and x.huella = h;
  end if;
  return query select esta_cerrada, e;
end $$;

-- Lista de móviles (solo para móviles con acceso)
create or replace function public.moviles(p_sala text, p_llave text)
returns table (id text, disp text, estado text, info text, creado timestamptz, visto timestamptz, yo boolean, cerrada boolean)
language plpgsql security definer set search_path = public as $$
declare h text := huella(p_llave);
begin
  perform comprobar_acceso(p_sala, p_llave);
  if not exists (select 1 from dispositivos x where x.sala = p_sala and x.huella = h and x.estado = 'admitido') then
    raise exception 'no admitido';
  end if;
  return query select left(x.huella, 16), x.disp, x.estado, x.info, x.creado, x.visto, x.huella = h,
                      exists (select 1 from salas_cerradas c where c.sala = p_sala)
    from dispositivos x where x.sala = p_sala order by x.estado, x.creado;
end $$;

-- Cerrar (true) o abrir (false) la sala
create or replace function public.cerrar_sala(p_sala text, p_llave text, p_cerrar boolean)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform comprobar_acceso(p_sala, p_llave);
  if not exists (select 1 from dispositivos x where x.sala = p_sala and x.huella = huella(p_llave) and x.estado = 'admitido') then
    raise exception 'no admitido';
  end if;
  if p_cerrar then
    insert into salas_cerradas (sala) values (p_sala) on conflict do nothing;
  else
    delete from salas_cerradas where sala = p_sala;
    delete from dispositivos where sala = p_sala and estado = 'pendiente';
  end if;
end $$;

-- Admitir (true) o quitar/rechazar (false) un móvil. Un móvil no puede quitarse a sí mismo.
create or replace function public.decidir_movil(p_sala text, p_llave text, p_id text, p_admitir boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare h text := huella(p_llave); quitado text;
begin
  perform comprobar_acceso(p_sala, p_llave);
  if not exists (select 1 from dispositivos x where x.sala = p_sala and x.huella = h and x.estado = 'admitido') then
    raise exception 'no admitido';
  end if;
  if length(p_id) <> 16 then raise exception 'petición no válida'; end if;
  if p_admitir then
    update dispositivos set estado = 'admitido', visto = now() where sala = p_sala and left(huella, 16) = p_id;
  else
    delete from dispositivos where sala = p_sala and left(huella, 16) = p_id and huella <> h returning disp into quitado;
    -- el móvil quitado deja de recibir avisos
    if quitado is not null and not exists (select 1 from dispositivos where sala = p_sala and disp = quitado) then
      delete from suscripciones where sala = p_sala and disp = quitado;
    end if;
  end if;
end $$;

-- ===== Permisos =====
revoke execute on function public.comprobar_acceso(text, text) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'leer(text, bigint, text)', 'enviar(text, text, integer, text)', 'subir(text, text, integer, text)',
    'bajar(text, bigint, text)', 'editar(text, bigint, text, text)', 'borrar(text, bigint, bigint, text)',
    'vaciar(text, text)', 'suscribir(text, text, text, text, text, text)', 'desuscribir(text)',
    'escribir(text, text, boolean, text)', 'escribiendo(text, text, text)',
    'latido(text, text, text)', 'presencia_otro(text, text, text)',
    'presentarse(text, text, text)', 'moviles(text, text)', 'cerrar_sala(text, text, boolean)',
    'decidir_movil(text, text, text, boolean)'
  ] loop
    execute format('revoke execute on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon', f);
  end loop;
end $$;

notify pgrst, 'reload schema';

-- ===== Si un día os quedáis los dos fuera (sala cerrada y ningún móvil con acceso) =====
-- Ejecuta solo esta línea en el SQL Editor y la sala vuelve a quedar abierta:
--   delete from public.salas_cerradas;
