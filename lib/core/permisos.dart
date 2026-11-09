import '../features/auth/perfil.dart';

/// Lo máximo que puede hacer cada rol (la base de datos manda por rol).
const permisosPermitidos = <Rol, List<String>>{
  Rol.admin: [
    'mesas', 'barra', 'carta', 'caja', 'facturas', 'informes', 'usuarios', 'cocina', 'ajustes', 'cobrar', 'anular',
    'caja_diaria', 'gastos', 'proveedores', 'resumen', 'stock', 'fichajes', 'cierres', 'panel', 'anulaciones',
  ],
  Rol.camarero: ['mesas', 'barra', 'cobrar', 'anular', 'caja', 'caja_diaria', 'gastos', 'proveedores', 'resumen', 'stock'],
  Rol.cocinero: ['cocina'],
};

/// Lo que tiene cada rol si no se le marcan permisos a mano.
const permisosPorDefecto = <Rol, List<String>>{
  Rol.admin: [
    'mesas', 'barra', 'carta', 'caja', 'facturas', 'informes', 'usuarios', 'cocina', 'ajustes', 'cobrar', 'anular',
    'caja_diaria', 'gastos', 'proveedores', 'resumen', 'stock', 'fichajes', 'cierres', 'panel', 'anulaciones',
  ],
  Rol.camarero: ['mesas', 'barra', 'cobrar', 'anular'],
  Rol.cocinero: ['cocina'],
};

/// Secciones de gestión (lo que antes hacía Yitso).
const permisosGestion = ['caja_diaria', 'gastos', 'proveedores', 'resumen', 'stock'];

const nombresPermiso = <String, String>{
  'mesas': 'Mesas y comandas',
  'barra': 'Venta en barra',
  'carta': 'Gestionar la carta',
  'caja': 'Turno de caja del TPV',
  'facturas': 'Ver facturas',
  'informes': 'Ver informes',
  'usuarios': 'Gestionar usuarios',
  'cocina': 'Pantalla de cocina',
  'ajustes': 'Ajustes',
  'cobrar': 'Cobrar',
  'anular': 'Anular productos enviados',
  'caja_diaria': 'Gestión · Caja diaria',
  'gastos': 'Gestión · Gastos',
  'proveedores': 'Gestión · Proveedores',
  'resumen': 'Gestión · Resumen del mes',
  'stock': 'Gestión · Stock e inventario',
  'fichajes': 'Fichajes del equipo (registro de jornada)',
  'cierres': 'Ver cierres y descuadres de caja',
  'panel': 'Panel del dueño (Hoy)',
  'anulaciones': 'Control de anulaciones',
};
