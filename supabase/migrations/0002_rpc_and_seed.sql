-- RPCs y datos semilla

-- =========================================================
-- Tipos de clase por defecto y plantillas de email base
-- =========================================================
insert into class_types (club_id, name, default_capacity, serio)
select id, v.name, v.cap, v.serio
from clubs, (values
  ('Multinivel', 4, false),
  ('Particular', 2, false),
  ('Curso nivel', 4, true),
  ('Competición', 4, true)
) as v(name, cap, serio)
where clubs.name = 'Bamvolea Sportcity Valencia';

insert into email_templates (key, name, subject, body) values
  ('alta_alumno', 'Alta de alumno', 'Bienvenido/a a {{club}}',
   'Hola {{nombre}},\n\nBienvenido/a a {{club}}. En breve nos pondremos en contacto para asignarte clase.\n\nUn saludo,\nEquipo {{club}}'),
  ('baja_alumno', 'Baja de alumno', 'Confirmación de baja - {{club}}',
   'Hola {{nombre}},\n\nConfirmamos tu baja en {{club}}. Esperamos verte de nuevo pronto.\n\nUn saludo,\nEquipo {{club}}'),
  ('lista_espera', 'Aviso lista de espera', 'Tenemos hueco para ti en {{club}}',
   'Hola {{nombre}},\n\nTenemos un hueco disponible que encaja con tu nivel y disponibilidad. Contesta a este correo para confirmarlo.\n\nUn saludo,\nEquipo {{club}}'),
  ('recordatorio_pago', 'Recordatorio de pago', 'Pago pendiente - {{club}}',
   'Hola {{nombre}},\n\nTe recordamos que tienes un pago pendiente en {{club}}. Por favor, regulariza tu situación cuando puedas.\n\nUn saludo,\nEquipo {{club}}'),
  ('aviso_evento', 'Aviso de evento', 'Detalles de tu evento en {{club}}',
   'Hola {{nombre}},\n\nTe confirmamos los detalles de tu evento el {{fecha}} en {{club}}.\n\nUn saludo,\nEquipo {{club}}')
on conflict (key) do nothing;

-- =========================================================
-- VISTA ENTRENADOR (acceso simbólico por PIN, sin login completo)
-- Cada RPC revalida el PIN contra trainers.pin porque no hay sesión real.
-- =========================================================
create or replace function rpc_trainer_login(p_pin text)
returns table (id uuid, name text, clubs uuid[], color text)
language sql security definer stable
as $$
  select t.id, t.name, t.clubs, t.color
  from trainers t
  where t.pin = p_pin and t.active;
$$;

create or replace function rpc_trainer_dashboard(p_trainer_id uuid, p_pin text)
returns jsonb
language plpgsql security definer stable
as $$
declare
  result jsonb;
begin
  if not exists (select 1 from trainers where id = p_trainer_id and pin = p_pin and active) then
    raise exception 'PIN inválido';
  end if;

  select jsonb_build_object(
    'classes', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'club_id', c.club_id, 'day', c.day, 'hour', c.hour,
        'type', c.type, 'court', c.court, 'capacity', c.capacity,
        'students', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'id', s.id, 'name', s.name, 'welcome_pack_received', s.welcome_pack_received,
            'morose', s.morose
          )), '[]'::jsonb)
          from class_students cs join students s on s.id = cs.student_id
          where cs.class_id = c.id
        )
      )), '[]'::jsonb)
      from classes c where c.trainer_id = p_trainer_id
    ),
    'planning', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'club_id', pw.club_id, 'session_number', pw.session_number,
        'title', pw.title, 'content', pw.content,
        'attachment_url', pw.attachment_url, 'attachment_name', pw.attachment_name
      ) order by pw.session_number desc), '[]'::jsonb)
      from planning_weeks pw
      where pw.club_id = any(select clubs from trainers where id = p_trainer_id)
    ),
    'monthly_stats', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'month_key', ms.month_key, 'total_classes', ms.total_classes,
        'breakdown', ms.breakdown, 'source', ms.source
      ) order by ms.month_key desc), '[]'::jsonb)
      from monthly_stats ms where ms.trainer_id = p_trainer_id
    )
  ) into result;

  return result;
end;
$$;

create or replace function rpc_trainer_mark_attendance(
  p_trainer_id uuid, p_pin text, p_class_id uuid, p_student_id uuid, p_class_date date, p_present boolean
) returns void
language plpgsql security definer
as $$
begin
  if not exists (select 1 from trainers where id = p_trainer_id and pin = p_pin and active) then
    raise exception 'PIN inválido';
  end if;
  if not exists (select 1 from classes where id = p_class_id and trainer_id = p_trainer_id) then
    raise exception 'Esta clase no pertenece a este entrenador';
  end if;

  insert into attendance (class_id, student_id, class_date, present)
  values (p_class_id, p_student_id, p_class_date, p_present)
  on conflict (class_id, student_id, class_date)
  do update set present = excluded.present;
end;
$$;

create or replace function rpc_trainer_update_student_flag(
  p_trainer_id uuid, p_pin text, p_student_id uuid, p_field text, p_value boolean
) returns void
language plpgsql security definer
as $$
begin
  if not exists (select 1 from trainers where id = p_trainer_id and pin = p_pin and active) then
    raise exception 'PIN inválido';
  end if;
  if p_field not in ('welcome_pack_received', 'morose') then
    raise exception 'Campo no permitido';
  end if;
  if not exists (
    select 1 from class_students cs join classes c on c.id = cs.class_id
    where cs.student_id = p_student_id and c.trainer_id = p_trainer_id
  ) then
    raise exception 'Este alumno no pertenece a ninguna clase de este entrenador';
  end if;

  if p_field = 'welcome_pack_received' then
    update students set welcome_pack_received = p_value where id = p_student_id;
  else
    update students set morose = p_value where id = p_student_id;
  end if;
end;
$$;

create or replace function rpc_trainer_report_incident(
  p_trainer_id uuid, p_pin text, p_description text, p_target_section text, p_urgency text
) returns uuid
language plpgsql security definer
as $$
declare
  v_name text;
  v_task_id uuid;
begin
  select name into v_name from trainers where id = p_trainer_id and pin = p_pin and active;
  if v_name is null then
    raise exception 'PIN inválido';
  end if;

  insert into tasks (description, urgency, target_section, created_section, created_by_name)
  values (p_description, p_urgency, p_target_section, 'entrenador', v_name)
  returning id into v_task_id;

  return v_task_id;
end;
$$;

grant execute on function rpc_trainer_login to anon, authenticated;
grant execute on function rpc_trainer_dashboard to anon, authenticated;
grant execute on function rpc_trainer_mark_attendance to anon, authenticated;
grant execute on function rpc_trainer_update_student_flag to anon, authenticated;
grant execute on function rpc_trainer_report_incident to anon, authenticated;

-- =========================================================
-- "MI VISTA" para cuentas reales con role='entrenador' (profiles.trainer_id)
-- Mismo dashboard que la Vista entrenador por PIN, pero identificado por
-- auth.uid() en vez de PIN, para quien sí tiene cuenta de Auth completa.
-- =========================================================
create or replace function my_trainer_id()
returns uuid
language sql stable security definer
as $$
  select trainer_id from profiles where id = auth.uid() and role = 'entrenador';
$$;

create or replace function rpc_my_trainer_dashboard()
returns jsonb
language sql security definer stable
as $$
  select rpc_trainer_dashboard(my_trainer_id(), (select pin from trainers where id = my_trainer_id()));
$$;

create or replace function rpc_my_trainer_mark_attendance(
  p_class_id uuid, p_student_id uuid, p_class_date date, p_present boolean
) returns void
language sql security definer
as $$
  select rpc_trainer_mark_attendance(my_trainer_id(), (select pin from trainers where id = my_trainer_id()), p_class_id, p_student_id, p_class_date, p_present);
$$;

create or replace function rpc_my_trainer_update_student_flag(
  p_student_id uuid, p_field text, p_value boolean
) returns void
language sql security definer
as $$
  select rpc_trainer_update_student_flag(my_trainer_id(), (select pin from trainers where id = my_trainer_id()), p_student_id, p_field, p_value);
$$;

create or replace function rpc_my_trainer_report_incident(
  p_description text, p_target_section text, p_urgency text
) returns uuid
language sql security definer
as $$
  select rpc_trainer_report_incident(my_trainer_id(), (select pin from trainers where id = my_trainer_id()), p_description, p_target_section, p_urgency);
$$;

grant execute on function my_trainer_id to authenticated;
grant execute on function rpc_my_trainer_dashboard to authenticated;
grant execute on function rpc_my_trainer_mark_attendance to authenticated;
grant execute on function rpc_my_trainer_update_student_flag to authenticated;
grant execute on function rpc_my_trainer_report_incident to authenticated;
