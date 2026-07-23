-- Añade el ID real de Playtomic al entrenador, más fiable que casar por
-- nombre (coach_ids de /bookings son IDs, no nombres, y no hay endpoint
-- público para resolverlos a nombre).
alter table trainers add column if not exists playtomic_coach_id text;
