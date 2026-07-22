-- Bamvolea Sportcity Valencia - CRM
-- Esquema inicial: clubs, perfiles/roles, alumnos, entrenadores, parrilla,
-- grupos internos, planificación, tareas, eventos, plantillas de email y KPIs.

create extension if not exists pgcrypto;

-- =========================================================
-- CLUBS
-- =========================================================
create table clubs (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  num_courts int not null default 0,
  -- a partir de esta hora solo se admiten tipos de clase marcados como "serios"
  -- (class_types.serio = true); antes de esta hora se admite cualquier tipo.
  serious_cutoff_hour text not null default '17:00',
  created_at timestamptz not null default now()
);

insert into clubs (name, num_courts) values ('Bamvolea Sportcity Valencia', 30);

-- =========================================================
-- PERFILES / ROLES
-- Un perfil por usuario de auth.users. club_ids define a qué sedes tiene
-- acceso; casi todo el resto del sistema filtra por el club seleccionado
-- en el selector de la UI, salvo el calendario de Eventos que es global.
-- =========================================================
create type app_role as enum (
  'admin', 'front_desk', 'administracion', 'coordinacion', 'entrenador', 'direccion'
);

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  email text, -- email de contacto para avisos automáticos (tareas urgentes, etc.)
  role app_role not null,
  club_ids uuid[] not null default '{}',
  created_at timestamptz not null default now()
);

-- Funciones auxiliares para RLS. SECURITY DEFINER + estables para evitar
-- recursión al leer profiles dentro de sus propias políticas.
create or replace function current_role_name()
returns app_role
language sql stable security definer
as $$
  select role from profiles where id = auth.uid();
$$;

create or replace function current_club_ids()
returns uuid[]
language sql stable security definer
as $$
  select club_ids from profiles where id = auth.uid();
$$;

create or replace function is_admin()
returns boolean
language sql stable security definer
as $$
  select coalesce((select role = 'admin' from profiles where id = auth.uid()), false);
$$;

create or replace function has_club_access(target_club uuid)
returns boolean
language sql stable security definer
as $$
  select is_admin() or coalesce((select target_club = any(club_ids) from profiles where id = auth.uid()), false);
$$;

alter table profiles enable row level security;
-- Cualquier persona del equipo logueada puede ver nombre/rol/email del resto
-- (hace falta para poder avisar por email a "la sección X", por ejemplo).
create policy profiles_select on profiles for select using (auth.uid() is not null);
create policy profiles_update_self on profiles for update using (auth.uid() = id or is_admin());
create policy profiles_admin_insert on profiles for insert with check (is_admin());
create policy profiles_admin_delete on profiles for delete using (is_admin());

alter table clubs enable row level security;
create policy clubs_select on clubs for select using (auth.uid() is not null);
create policy clubs_admin_write on clubs for all using (is_admin()) with check (is_admin());

-- =========================================================
-- ENTRENADORES
-- =========================================================
create table trainers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text,
  phone text,
  pin text not null unique, -- acceso simbólico a "Vista entrenador", sin login completo
  clubs uuid[] not null default '{}',
  color text not null default '#2f6f4f',
  availability jsonb not null default '{}', -- {"lunes":[["16:00","21:00"]], ...}
  external_system_name text, -- para casar por nombre con Playtomic
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Solo relevante cuando profiles.role='entrenador': liga la cuenta con su
-- fila en `trainers` para que "Mi vista" (dentro del menú normal) sepa de
-- qué entrenador mostrar datos. La mayoría de entrenadores no necesita
-- esto: usan el PIN de Vista entrenador sin cuenta de Auth.
alter table profiles add column trainer_id uuid references trainers(id) on delete set null;

alter table trainers enable row level security;
create policy trainers_select on trainers for select using (auth.uid() is not null);
create policy trainers_write on trainers for all
  using (current_role_name() in ('admin','coordinacion'))
  with check (current_role_name() in ('admin','coordinacion'));

-- =========================================================
-- GRUPOS INTERNOS (Academia > Grupos)
-- Preparación de grupos de nivel/franja ANTES de que exista la clase real
-- en la Parrilla. Nunca escriben nada en `classes`.
-- =========================================================
create table academia_grupos (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references clubs(id) on delete cascade,
  dia text not null,
  franja text not null, -- ej. "17:00-18:00"
  nivel numeric,
  trainer_id uuid references trainers(id) on delete set null,
  capacidad int not null default 6,
  descripcion text,
  created_at timestamptz not null default now()
);

alter table academia_grupos enable row level security;
create policy academia_grupos_select on academia_grupos for select using (has_club_access(club_id));
create policy academia_grupos_write on academia_grupos for all
  using (has_club_access(club_id) and current_role_name() in ('admin','coordinacion','administracion'))
  with check (has_club_access(club_id) and current_role_name() in ('admin','coordinacion','administracion'));

-- =========================================================
-- ALUMNOS
-- El estado real (activo/espera/baja) NUNCA se guarda: se calcula en la
-- vista students_view a partir de `status` + si tiene alguna clase asignada.
-- =========================================================
create table students (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  club_id uuid not null references clubs(id) on delete cascade,
  level numeric, -- nivel interno del club
  level_playtomic numeric, -- nivel en el sistema externo, si aplica
  birthdate date,
  email text,
  phone text,
  status text not null default 'activo' check (status in ('activo','baja')),
  morose boolean not null default false,
  particular_mode boolean not null default false,
  bono_remaining int,
  availability jsonb not null default '{}',
  available_days text[] not null default '{}',
  interested_product text,
  academia_grupo_id uuid references academia_grupos(id) on delete set null,
  welcome_pack_received boolean not null default false,
  sexo text,
  created_at timestamptz not null default now()
);

create index students_club_idx on students(club_id);

alter table students enable row level security;
create policy students_select on students for select using (has_club_access(club_id));
create policy students_write on students for all
  using (has_club_access(club_id) and current_role_name() in ('admin','front_desk','administracion','coordinacion'))
  with check (has_club_access(club_id) and current_role_name() in ('admin','front_desk','administracion','coordinacion'));

-- =========================================================
-- PARRILLA (horario semanal real)
-- =========================================================
create table classes (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references clubs(id) on delete cascade,
  day text not null, -- lunes..domingo
  hour text not null, -- "17:00"
  type text not null, -- tipo de clase (ver class_types)
  capacity int not null default 4,
  court int,
  trainer_id uuid references trainers(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (club_id, day, hour, court)
);

create table class_students (
  class_id uuid not null references classes(id) on delete cascade,
  student_id uuid not null references students(id) on delete cascade,
  primary key (class_id, student_id)
);

-- Tipos de clase configurables. `serio` marca los tipos permitidos en la
-- franja tardía (a partir de clubs.serious_cutoff_hour); el resto solo se
-- puede programar antes de esa hora.
create table class_types (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references clubs(id) on delete cascade,
  name text not null,
  default_capacity int not null default 4,
  serio boolean not null default false,
  created_at timestamptz not null default now(),
  unique (club_id, name)
);

alter table classes enable row level security;
create policy classes_select on classes for select using (has_club_access(club_id));
create policy classes_write on classes for all
  using (has_club_access(club_id) and current_role_name() in ('admin','coordinacion','administracion'))
  with check (has_club_access(club_id) and current_role_name() in ('admin','coordinacion','administracion'));

alter table class_students enable row level security;
create policy class_students_select on class_students for select using (
  exists (select 1 from classes c where c.id = class_id and has_club_access(c.club_id))
);
create policy class_students_write on class_students for all using (
  exists (select 1 from classes c where c.id = class_id and has_club_access(c.club_id)
    and current_role_name() in ('admin','coordinacion','administracion'))
) with check (
  exists (select 1 from classes c where c.id = class_id and has_club_access(c.club_id)
    and current_role_name() in ('admin','coordinacion','administracion'))
);

alter table class_types enable row level security;
create policy class_types_select on class_types for select using (has_club_access(club_id));
create policy class_types_write on class_types for all
  using (has_club_access(club_id) and current_role_name() in ('admin','coordinacion'))
  with check (has_club_access(club_id) and current_role_name() in ('admin','coordinacion'));

-- =========================================================
-- ASISTENCIA
-- =========================================================
create table attendance (
  id uuid primary key default gen_random_uuid(),
  class_id uuid references classes(id) on delete cascade,
  student_id uuid not null references students(id) on delete cascade,
  present boolean not null default false,
  class_date date not null,
  created_at timestamptz not null default now(),
  unique (class_id, student_id, class_date)
);

alter table attendance enable row level security;
create policy attendance_select on attendance for select using (
  exists (select 1 from students s where s.id = student_id and has_club_access(s.club_id))
);
create policy attendance_write on attendance for all using (
  exists (select 1 from students s where s.id = student_id and has_club_access(s.club_id)
    and current_role_name() in ('admin','coordinacion','administracion','front_desk'))
) with check (
  exists (select 1 from students s where s.id = student_id and has_club_access(s.club_id)
    and current_role_name() in ('admin','coordinacion','administracion','front_desk'))
);

-- =========================================================
-- PLANIFICACIÓN (qué se trabaja cada semana, por club)
-- =========================================================
create table planning_weeks (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references clubs(id) on delete cascade,
  session_number int not null,
  title text,
  content text,
  attachment_url text,
  attachment_name text,
  created_at timestamptz not null default now(),
  unique (club_id, session_number)
);

alter table planning_weeks enable row level security;
create policy planning_select on planning_weeks for select using (has_club_access(club_id));
create policy planning_write on planning_weeks for all
  using (has_club_access(club_id) and current_role_name() in ('admin','coordinacion'))
  with check (has_club_access(club_id) and current_role_name() in ('admin','coordinacion'));

-- =========================================================
-- TAREAS (tablón interno)
-- =========================================================
create table tasks (
  id uuid primary key default gen_random_uuid(),
  description text not null,
  urgency text not null check (urgency in ('baja','media','urgente','muy_urgente')),
  target_section text not null,
  target_trainer_id uuid references trainers(id) on delete set null,
  created_section text not null,
  created_by_name text not null,
  created_by uuid references auth.users(id) on delete set null,
  due_date date,
  status text not null default 'pendiente' check (status in ('pendiente','hecho','cancelada')),
  club_id uuid references clubs(id) on delete set null,
  attachment_url text,
  notify_creator boolean not null default false,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

alter table tasks enable row level security;
create policy tasks_select on tasks for select using (auth.uid() is not null);
create policy tasks_write on tasks for all using (auth.uid() is not null) with check (auth.uid() is not null);

-- =========================================================
-- EVENTOS (calendario de alquileres/corporativo) - siempre global
-- =========================================================
create table events (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references clubs(id) on delete cascade,
  date date not null,
  end_date date,
  start_hour text not null,
  end_hour text not null,
  company text not null,
  contact_name text,
  contact_email text,
  contact_phone text,
  num_courts int not null default 1,
  category text not null,
  status text not null default 'confirmado' check (status in ('tentativo','confirmado','cancelado')),
  extras jsonb not null default '{}', -- ej: {"catering": true, "material_extra": false}
  created_at timestamptz not null default now()
);

alter table events enable row level security;
create policy events_select on events for select using (auth.uid() is not null);
create policy events_write on events for all
  using (current_role_name() in ('admin','coordinacion','direccion'))
  with check (current_role_name() in ('admin','coordinacion','direccion'));

-- =========================================================
-- PLANTILLAS DE EMAIL
-- =========================================================
create table email_templates (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  name text not null,
  subject text not null,
  body text not null, -- admite variables {{nombre}}, {{club}}, etc.
  attachment_url text,
  attachment_name text,
  created_at timestamptz not null default now()
);

alter table email_templates enable row level security;
create policy email_templates_select on email_templates for select using (auth.uid() is not null);
create policy email_templates_write on email_templates for all
  using (current_role_name() in ('admin','direccion','administracion'))
  with check (current_role_name() in ('admin','direccion','administracion'));

-- =========================================================
-- KPIs: snapshot congelado de estadísticas mensuales por entrenador
-- Mientras no exista snapshot para un mes, la UI estima a partir del
-- horario actual y lo marca explícitamente como "estimado".
-- =========================================================
create table monthly_stats (
  id uuid primary key default gen_random_uuid(),
  trainer_id uuid not null references trainers(id) on delete cascade,
  month_key text not null, -- "2026-07"
  breakdown jsonb not null default '{}', -- {"particular": 12, "grupo": 34, ...}
  total_classes int not null default 0,
  source text not null default 'real' check (source in ('real','estimado')),
  saved_at timestamptz not null default now(),
  unique (trainer_id, month_key)
);

alter table monthly_stats enable row level security;
create policy monthly_stats_select on monthly_stats for select using (auth.uid() is not null);
create policy monthly_stats_write on monthly_stats for all
  using (current_role_name() in ('admin','direccion','coordinacion'))
  with check (current_role_name() in ('admin','direccion','coordinacion'));

-- =========================================================
-- VISTA: alumnos con estado real calculado
-- =========================================================
create or replace view students_view as
select
  s.*,
  case
    when s.status = 'baja' then 'baja'
    when exists (select 1 from class_students cs where cs.student_id = s.id) then 'activo'
    else 'espera'
  end as computed_status,
  extract(day from now() - s.created_at)::int / 7 as weeks_waiting
from students s;

-- =========================================================
-- STORAGE
-- =========================================================
insert into storage.buckets (id, name, public)
values ('attachments', 'attachments', true)
on conflict (id) do nothing;

create policy attachments_read on storage.objects for select using (bucket_id = 'attachments');
create policy attachments_write on storage.objects for insert with check (bucket_id = 'attachments' and auth.uid() is not null);
create policy attachments_update on storage.objects for update using (bucket_id = 'attachments' and auth.uid() is not null);
create policy attachments_delete on storage.objects for delete using (bucket_id = 'attachments' and auth.uid() is not null);
