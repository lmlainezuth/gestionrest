-- 0032 · Crear empresas (bares nuevos) es cosa del programador, no del dueño de un bar.
-- El administrador de un bar sigue mandando en su bar, pero ya no puede dar de alta otros.
-- Necesita la 0029 y la 0030. Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

create or replace function public.solo_programador_crea_empresa()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- auth.uid() es null en el SQL Editor y en las funciones del servidor: ahí sí se permite
  if auth.uid() is not null and not public.es_programador() then
    raise exception 'Solo el programador puede crear empresas';
  end if;
  return new;
end $$;

drop trigger if exists solo_programador_crea_empresa on public.empresa;
create trigger solo_programador_crea_empresa
before insert on public.empresa
for each row execute function public.solo_programador_crea_empresa();
