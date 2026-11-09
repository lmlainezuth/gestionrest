// GestiónRest · alta de usuarios con nombre + PIN, y cambio de PIN.
// Solo administradores. Corre en el servidor (usa la clave de servicio).
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (cuerpo: unknown, estado = 200) =>
  new Response(JSON.stringify(cuerpo), {
    status: estado,
    headers: { ...cors, "Content-Type": "application/json" },
  });

// Misma regla que la app (lib/features/auth/pin.dart)
const claveDePin = (pin: string, correo: string) => `GRpin-${pin}-${correo.split("@")[0]}`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user) return json({ error: "No has iniciado sesión" }, 401);
  // Debe ser administrador de su empresa actual
  const { data: perfil } = await admin.from("perfiles").select("empresa_actual").eq("id", user.id).single();
  const empresa = perfil?.empresa_actual;
  const { data: yo } = await admin.from("empresa_usuarios").select("rol, activo")
    .eq("empresa_id", empresa).eq("usuario_id", user.id).maybeSingle();
  if (!empresa || yo?.rol !== "admin" || !yo.activo) return json({ error: "Solo el administrador puede hacer esto" }, 403);

  const b = await req.json();
  const pin = String(b.pin ?? "");
  if (!/^\d{1,8}$/.test(pin)) return json({ error: "El PIN debe tener entre 1 y 8 cifras" }, 400);

  // Cambiar el PIN de un usuario existente
  if (b.accion === "pin") {
    const { data: miembro } = await admin.from("empresa_usuarios").select("usuario_id")
      .eq("empresa_id", empresa).eq("usuario_id", String(b.id)).maybeSingle();
    if (!miembro) return json({ error: "Ese usuario no es de tu empresa" }, 403);
    const { data: p } = await admin.from("perfiles").select("correo").eq("id", String(b.id)).single();
    if (!p?.correo) return json({ error: "Usuario no encontrado" }, 404);
    const { error } = await admin.auth.admin.updateUserById(String(b.id), {
      password: claveDePin(pin, p.correo),
    });
    return error ? json({ error: error.message }, 400) : json({ ok: true });
  }

  // Alta
  const nombre = String(b.nombre ?? "").trim();
  const rol = String(b.rol ?? "");
  if (!nombre) return json({ error: "Escribe el nombre" }, 400);
  if (!["admin", "camarero", "cocinero"].includes(rol)) return json({ error: "Rol no válido" }, 400);

  const correo = `u${crypto.randomUUID().replaceAll("-", "").slice(0, 12)}@gestionrest.local`;
  const { data, error } = await admin.auth.admin.createUser({
    email: correo,
    password: claveDePin(pin, correo),
    email_confirm: true,
    user_metadata: { nombre },
  });
  if (error) return json({ error: error.message }, 400);

  await admin.from("perfiles").update({ nombre, empresa_actual: empresa }).eq("id", data.user.id);
  await admin.from("empresa_usuarios").insert({ empresa_id: empresa, usuario_id: data.user.id, rol, activo: true });
  return json({ id: data.user.id });
});
