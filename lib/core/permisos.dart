import '../features/auth/perfil.dart';

/// Lo máximo que puede hacer cada rol (la base de datos manda por rol).
const permisosPermitidos = <Rol, List<String>>{
  Rol.admin: [
    'mesas', 'barra', 'carta', 'caja', 'facturas', 'informes', 'usuarios', 'cocina', 'ajustes', 'cobrar', 'anular',
    'gastos', 'proveedores', 'resumen', 'stock', 'fichajes', 'cierres', 'panel', 'anulaciones',
    'total_dia',
  ],
  // facturas (solo ver), informes y cierres: para el perfil de Gestión (oficina / gestor)
  Rol.camarero: [
    'mesas', 'barra', 'cobrar', 'anular', 'caja', 'gastos', 'proveedores', 'resumen', 'stock',
    'total_dia', 'facturas', 'informes', 'cierres',
  ],
  Rol.cocinero: ['cocina'],
};

/// Lo que tiene cada rol si no se le marcan permisos a mano.
const permisosPorDefecto = <Rol, List<String>>{
  Rol.admin: [
    'mesas', 'barra', 'carta', 'caja', 'facturas', 'informes', 'usuarios', 'cocina', 'ajustes', 'cobrar', 'anular',
    'gastos', 'proveedores', 'resumen', 'stock', 'fichajes', 'cierres', 'panel', 'anulaciones',
    'total_dia',
  ],
  Rol.camarero: ['mesas', 'barra', 'cobrar', 'anular'],
  Rol.cocinero: ['cocina'],
};

/// Secciones de gestión (lo que antes hacía Yitso).
const permisosGestion = [
  'gastos', 'proveedores', 'resumen', 'stock', // compras
  'facturas', 'informes', 'cierres', // facturas emitidas (ver), ventas, márgenes, IVA trimestral, descuadres
];

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
  'gastos': 'Gestión · Gastos',
  'proveedores': 'Gestión · Proveedores',
  'resumen': 'Gestión · Resumen del mes',
  'stock': 'Gestión · Stock e inventario',
  'fichajes': 'Fichajes del equipo (registro de jornada)',
  'cierres': 'Ver cierres y descuadres de caja',
  'panel': 'Panel del dueño (Hoy)',
  'anulaciones': 'Control de anulaciones',
  'total_dia': 'Ver cuánto se lleva vendido hoy (Ventas de hoy)',
};
