/// Datos de conexión al proyecto Supabase de GestiónRest.
/// La clave publishable es pública por diseño (la seguridad la da RLS).
class Config {
  static const supabaseUrl = 'https://zouujjameuyyedqiotxt.supabase.co';

  /// Supabase → botón "Connect" → copia la "Publishable key" (sb_publishable_...)
  static const supabaseKey = 'sb_publishable_oF8647VghLNyzdG71lwJ0Q_vdkwZZ5a';

  /// Servicio puente TicketBAI en Netlify (Android, web y equipos sin certificado).
  /// Pon aquí la dirección de tu sitio de Netlify, por ejemplo:
  /// 'https://itsasoa-gestion.netlify.app/api/tbai'. Vacío = no se usa.
  static const puenteTbai = 'https://gestionrest.netlify.app/api/tbai';
}
