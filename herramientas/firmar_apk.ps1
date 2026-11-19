# Firma el APK de GestionRest con el certificado de firma de código de Certum (nube, SimplySign)
# y archiva una copia de cada versión distribuida (art. 9.3 y 9.4 de la OF 521/2020).
#
# Uso, desde la carpeta del proyecto y con SimplySign Desktop conectado:
#   powershell -ExecutionPolicy Bypass -File herramientas\firmar_apk.ps1 -Alias "<alias del certificado>"
# El alias se ve con:
#   keytool -list -keystore NONE -storetype PKCS11 -providerClass sun.security.pkcs11.SunPKCS11 -providerArg herramientas\simplysign.cfg
# Más detalles (primera vez, renovación del certificado): docs\firma-apk.md
param(
  [Parameter(Mandatory = $true)][string]$Alias,
  [string]$Cfg = "$PSScriptRoot\simplysign.cfg",
  [string]$Archivo = "$PSScriptRoot\..\versiones-apk",
  [switch]$SinCompilar
)
$ErrorActionPreference = 'Stop'
Set-Location "$PSScriptRoot\.."

# Versión: la misma que va en los ficheros TicketBAI (lib\core\software.dart)
$m = Select-String -Path 'lib\core\software.dart' -Pattern "static const version = '([^']+)'"
if (-not $m) { throw 'No encuentro la versión en lib\core\software.dart' }
$version = $m.Matches[0].Groups[1].Value
$destino = Join-Path $Archivo $version
$apkFinal = Join-Path $destino "GestionRest-$version.apk"
if (Test-Path $apkFinal) {
  throw "La versión $version ya está firmada y archivada. Si cambias el programa, sube la versión en lib\core\software.dart y comunícalo al Registro TicketBAI."
}
if (-not (Test-Path $Cfg)) { throw "Falta $Cfg (copia herramientas\simplysign.cfg.ejemplo)" }

# Herramientas del SDK de Android (la build-tools más reciente)
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "$env:LOCALAPPDATA\Android\Sdk" }
$bt = Get-ChildItem "$sdk\build-tools" -Directory |
  Sort-Object { [version]($_.Name -replace '[^0-9.].*$', '') } | Select-Object -Last 1
if (-not $bt) { throw "No encuentro build-tools en $sdk" }
$apksigner = Join-Path $bt.FullName 'apksigner.bat'
$zipalign = Join-Path $bt.FullName 'zipalign.exe'

if (-not $SinCompilar) {
  flutter build apk --release
  if ($LASTEXITCODE) { throw 'Falló flutter build apk' }
}
$apk = 'build\app\outputs\flutter-apk\app-release.apk'
New-Item -ItemType Directory -Force $destino | Out-Null
$alineado = Join-Path $env:TEMP "gestionrest-$version-alineado.apk"
& $zipalign -p -f 4 $apk $alineado
if ($LASTEXITCODE) { throw 'Falló zipalign' }

# Firma: apksigner pide el PIN de la tarjeta de SimplySign (si no tiene PIN, sirve cualquier valor)
& $apksigner sign --provider-class sun.security.pkcs11.SunPKCS11 --provider-arg $Cfg `
  --ks NONE --ks-type PKCS11 --ks-key-alias $Alias --out $apkFinal $alineado
if ($LASTEXITCODE) { Remove-Item -ErrorAction SilentlyContinue $apkFinal; throw 'Falló la firma' }
& $apksigner verify --verbose --print-certs $apkFinal
if ($LASTEXITCODE) { Remove-Item -ErrorAction SilentlyContinue $apkFinal; throw 'La firma no verifica' }

$hash = (Get-FileHash $apkFinal -Algorithm SHA256).Hash
"GestionRest $version`r`nFirmado: $(Get-Date -Format 'yyyy-MM-dd HH:mm')`r`nSHA-256 del APK: $hash" |
  Set-Content (Join-Path $destino 'LEEME.txt') -Encoding UTF8
Remove-Item $alineado
Write-Host "Listo: $apkFinal" -ForegroundColor Green
Write-Host 'Guarda también una copia de la carpeta versiones-apk fuera de este PC (por ejemplo en Drive).'
