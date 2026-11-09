-- Alérgenos de declaración obligatoria (Reglamento UE 1169/2011, anexo II)
alter table public.productos
  add column alergenos text[] not null default '{}'
  check (alergenos <@ array['gluten','crustaceos','huevo','pescado','cacahuete','soja',
                             'lacteos','frutos_cascara','apio','mostaza','sesamo',
                             'sulfitos','altramuces','moluscos']::text[]);
