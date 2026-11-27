// GestiónRest · alta de usuarios con nombre + PIN, y cambio de PIN.
// Solo administradores. Corre en el servidor (usa la clave de servicio).
import { createClient } from "npm:@supabase/supabase-js@2.50.3";

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
  // Apunta un intento sospechoso en eventos_seguridad (panel Seguridad y aviso diario); si falla, sigue
  const apuntarEvento = async (empresa: string, tipo: string, usuario: string, detalle: string) => {
    try {
      await admin.from("eventos_seguridad").insert({ empresa_id: empresa, tipo, usuario_id: usuario, detalle });
    } catch (_) { /* no es crítico */ }
  };

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
  // Mínimo 4 cifras para todos: con menos, un PIN se adivina probando
  if (!/^\d{4,8}$/.test(pin)) return json({ error: "El PIN debe tener entre 4 y 8 cifras" }, 400);
  // Un administrador lo puede todo en su bar: su PIN no puede ser de los que se adivinan probando
  const PIN_ADMIN = 6;
  const pinCorto = (rol: string) => rol === "admin" && pin.length < PIN_ADMIN;
  const avisoPinCorto = `El PIN de un administrador debe tener al menos ${PIN_ADMIN} cifras`;

  // Cambiar el PIN de un usuario existente
  if (b.accion === "pin") {
    const { data: miembro } = await admin.from("empresa_usuarios").select("usuario_id, rol")
      .eq("empresa_id", empresa).eq("usuario_id", String(b.id)).maybeSingle();
    if (!miembro) {
      await apuntarEvento(String(empresa), "usuario_ajeno", user.id, "Intentó cambiar el PIN de un usuario de otro bar");
      return json({ error: "Ese usuario no es de tu empresa" }, 403);
    }
    const { data: p } = await admin.from("perfiles").select("correo").eq("id", String(b.id)).single();
    if (!p?.correo) return json({ error: "Usuario no encontrado" }, 404);
    // Solo cuentas de PIN: la contraseña de una cuenta con correo la cambia su dueño
    if (!p.correo.endsWith("@gestionrest.local")) {
      return json({ error: "Este usuario entra con correo y contraseña: su clave no se cambia desde aquí" }, 403);
    }
    // Quien también trabaja en otro bar no depende de este administrador (salvo que sea uno mismo)
    if (String(b.id) !== user.id) {
      const { data: otras, error: errOtras } = await admin.from("empresa_usuarios").select("empresa_id")
        .eq("usuario_id", String(b.id)).neq("empresa_id", empresa).limit(1);
      if (errOtras) return json({ error: errOtras.message }, 400);
      if (otras && otras.length > 0) {
        await apuntarEvento(String(empresa), "pin_otro_bar", user.id, "No pudo cambiar el PIN de un empleado que también está en otro bar");
        return json({ error: "Este usuario también está en otro bar: solo él puede cambiar su PIN" }, 403);
      }
    }
    if (pinCorto(miembro.rol)) return json({ error: avisoPinCorto }, 400);
    const { error } = await admin.auth.admin.updateUserById(String(b.id), {
      password: claveDePin(pin, p.correo),
    });
    if (error) return json({ error: error.message }, 400);
    // Para pasar a administrador hace falta un PIN largo (lo comprueba la base, migración 0041)
    await admin.from("perfiles").update({ pin_seguro: pin.length >= PIN_ADMIN }).eq("id", String(b.id));
    return json({ ok: true });
  }

  // Alta
  const nombre = String(b.nombre ?? "").trim();
  const rol = String(b.rol ?? "");
  if (!nombre) return json({ error: "Escribe el nombre" }, 400);
  if (!["admin", "camarero", "cocinero"].includes(rol)) return json({ error: "Rol no válido" }, 400);
  if (pinCorto(rol)) return json({ error: avisoPinCorto }, 400);

  const correo = `u${crypto.randomUUID().replaceAll("-", "").slice(0, 12)}@gestionrest.local`;
  const { data, error } = await admin.auth.admin.createUser({
    email: correo,
    password: claveDePin(pin, correo),
    email_confirm: true,
    user_metadata: { nombre },
  });
  if (error) return json({ error: error.message }, 400);

  // Si falla cualquier paso se borra el usuario: nunca queda uno a medias (sin empresa)
  const { error: e1 } = await admin.from("perfiles")
    .update({ nombre, empresa_actual: empresa, pin_seguro: pin.length >= PIN_ADMIN }).eq("id", data.user.id);
  const { error: e2 } = e1 ? { error: null } :
    await admin.from("empresa_usuarios").insert({ empresa_id: empresa, usuario_id: data.user.id, rol, activo: true });
  if (e1 || e2) {
    await admin.auth.admin.deleteUser(data.user.id);
    return json({ error: `No se pudo crear el usuario: ${(e1 ?? e2)!.message}` }, 400);
  }
  return json({ id: data.user.id });
});
