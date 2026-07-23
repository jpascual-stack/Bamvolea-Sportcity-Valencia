-- Alta masiva de los 11 entrenadores del club (según el listado real de
-- Playtomic Manager > Academia > Entrenadores). Los PIN son provisionales
-- (1001-1011): cada entrenador/a debería cambiarlo por uno propio desde
-- Entrenador > Entrenadores en cuanto arranque. El ID de Playtomic solo se
-- conoce por ahora para 4 de ellos (deducido cruzando datos reales); el
-- resto se puede rellenar más adelante desde Gestión > Playtomic Manager.

insert into trainers (name, pin, clubs, color, playtomic_coach_id, external_system_name)
select
  v.name, v.pin, array(select id from clubs where name = 'Bamvolea Sportcity Valencia'),
  v.color, v.playtomic_coach_id, v.external_system_name
from (values
  ('Agus Sotos',            '1001', '#2f6f4f', null,        'Agus Sotos'),
  ('Jorge Chacón',          '1002', '#7a4fb5', null,        'Jorge Chacón'),
  ('Jose Ferrandis',        '1003', '#d98c3a', '15368909',  'Jose Ferrandis'),
  ('Pablo Tarazona',        '1004', '#2f6f9f', '11073137',  'Pablo Tarazona'),
  ('Jorge Mesado Albors',   '1005', '#a13f5c', null,        'Jorge Mesado Albors'),
  ('David Soriano',         '1006', '#3f9f8a', '15369213',  'DAVID SORIANO'),
  ('Rafa Peris',            '1007', '#8a6d3f', null,        'Rafa peris'),
  ('Jose Santodomingo Mora','1008', '#5c5c9f', null,        'Jose Santodomingo Mora'),
  ('Samuele Lo Cascio',     '1009', '#c9558f', '7885937',   'Samuele Lo Cascio'),
  ('Andres Sanchez',        '1010', '#4f8f3f', null,        'Andres Sanchez'),
  ('Jose Marín',            '1011', '#9f6f2f', null,        'Jose Marín')
) as v(name, pin, color, playtomic_coach_id, external_system_name)
where not exists (select 1 from trainers t where t.pin = v.pin);
