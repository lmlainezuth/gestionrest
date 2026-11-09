/// Contraseña interna a partir del PIN. Debe coincidir con la Edge Function.
String claveDePin(String pin, String correo) => 'GRpin-$pin-${correo.split('@').first}';

bool esUsuarioPin(String? correo) => correo != null && correo.endsWith('@gestionrest.local');
