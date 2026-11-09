package com.levinlainez.gestionrest

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.cert.X509Certificate

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // En el TPV la pantalla no se apaga mientras la app está abierta
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    // Certificado ya abierto (abrir un .p12 cuesta tiempo): se reutiliza entre tickets
    private var huella: Int? = null
    private var clavePrivada: PrivateKey? = null
    private var certificado: X509Certificate? = null

    private fun abrir(p12: ByteArray, clave: String) {
        val h = p12.contentHashCode() * 31 + clave.hashCode()
        if (h == huella && clavePrivada != null) return
        val ks = KeyStore.getInstance("PKCS12")
        ks.load(ByteArrayInputStream(p12), clave.toCharArray())
        val alias = ks.aliases().toList().firstOrNull { ks.isKeyEntry(it) }
            ?: throw IllegalStateException("El certificado no contiene la clave privada")
        clavePrivada = ks.getKey(alias, clave.toCharArray()) as PrivateKey
        certificado = ks.getCertificate(alias) as X509Certificate
        huella = h
    }

    // Firma TicketBAI en el propio TPV (sin internet): RSA-SHA256 con el certificado del negocio
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gestionrest/firma").setMethodCallHandler { call, result ->
            try {
                val p12 = call.argument<ByteArray>("p12")!!
                val clave = call.argument<String>("clave") ?: ""
                abrir(p12, clave)
                when (call.method) {
                    "certificado" -> result.success(
                        mapOf(
                            "der" to certificado!!.encoded,
                            "titular" to certificado!!.subjectX500Principal.name,
                            "caduca" to certificado!!.notAfter.time,
                        )
                    )
                    "firmar" -> {
                        val s = Signature.getInstance("SHA256withRSA")
                        s.initSign(clavePrivada)
                        s.update(call.argument<ByteArray>("datos")!!)
                        result.success(s.sign())
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                huella = null
                result.error("FIRMA", e.message ?: e.toString(), null)
            }
        }
    }
}
