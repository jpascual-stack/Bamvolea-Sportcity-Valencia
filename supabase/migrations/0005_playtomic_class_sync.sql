-- Permite que la Parrilla mezcle clases manuales (plantilla semanal
-- recurrente, sin fecha concreta) con clases sincronizadas desde Playtomic
-- (fecha concreta real, con sus participantes por nombre — sin crear ficha
-- de alumno, solo texto).

alter table classes add column if not exists date date; -- null = plantilla manual recurrente; con valor = instancia real sincronizada
alter table classes add column if not exists playtomic_booking_id text unique;
alter table classes add column if not exists source text not null default 'manual' check (source in ('manual', 'playtomic'));
alter table classes add column if not exists participant_names text[] not null default '{}';

-- La restricción original (club_id, day, hour, court) ya no vale tal cual:
-- una clase manual recurrente y sus futuras instancias sincronizadas
-- comparten day/hour/court pero en fechas distintas. La sustituimos por dos
-- índices parciales: uno para plantillas manuales (date is null) y otro
-- para instancias con fecha concreta.
alter table classes drop constraint if exists classes_club_id_day_hour_court_key;

create unique index if not exists classes_manual_slot_unique
  on classes (club_id, day, hour, court) where date is null;
create unique index if not exists classes_dated_slot_unique
  on classes (club_id, date, hour, court) where date is not null;
