package com.levinlainez.gestionrest

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Impresoras internas de los TPV Android (ESC/POS en crudo):
 *  - USB: impresora integrada que aparece como dispositivo USB (p. ej. PT80KM3, vid 1155)
 *  - Serie: puerto /dev/ttyS* de la placa
 */
class ImpresoraTpv(private val context: Context) {
    private val usb = context.getSystemService(Context.USB_SERVICE) as UsbManager

    /** Dispositivos USB conectados, para elegir en Ajustes. */
    fun listarUsb(): List<Map<String, Any>> = usb.deviceList.values.map {
        mapOf(
            "vid" to it.vendorId,
            "pid" to it.productId,
            "nombre" to (it.productName ?: it.deviceName),
            "impresora" to (salida(it) != null),
        )
    }

    /** Busca por vid/pid (0 = cualquiera); si no, la primera con clase impresora o con salida bulk. */
    private fun buscar(vid: Int, pid: Int): UsbDevice? {
        val todos = usb.deviceList.values
        if (vid != 0) {
            todos.firstOrNull { it.vendorId == vid && (pid == 0 || it.productId == pid) }?.let { return it }
        }
        return todos.firstOrNull { d -> (0 until d.interfaceCount).any { d.getInterface(it).interfaceClass == UsbConstants.USB_CLASS_PRINTER } }
            ?: todos.firstOrNull { salida(it) != null }
    }

    private fun salida(d: UsbDevice): Pair<UsbInterface, UsbEndpoint>? {
        for (i in 0 until d.interfaceCount) {
            val itf = d.getInterface(i)
            for (e in 0 until itf.endpointCount) {
                val ep = itf.getEndpoint(e)
                if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK && ep.direction == UsbConstants.USB_DIR_OUT) return itf to ep
            }
        }
        return null
    }

    /** Pide permiso (la primera vez Android muestra un aviso) y espera la respuesta. */
    private fun permiso(d: UsbDevice): Boolean {
        if (usb.hasPermission(d)) return true
        val accion = context.packageName + ".USB_PERMISO"
        val latch = CountDownLatch(1)
        var concedido = false
        val receptor = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                concedido = i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                latch.countDown()
            }
        }
        val filtro = IntentFilter(accion)
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receptor, filtro, Context.RECEIVER_NOT_EXPORTED)
        else context.registerReceiver(receptor, filtro)
        try {
            val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
            val pi = PendingIntent.getBroadcast(context, 0, Intent(accion).setPackage(context.packageName), flags)
            usb.requestPermission(d, pi)
            latch.await(60, TimeUnit.SECONDS)
        } finally {
            context.unregisterReceiver(receptor)
        }
        return concedido || usb.hasPermission(d)
    }

    fun enviarUsb(vid: Int, pid: Int, datos: ByteArray) {
        val d = buscar(vid, pid) ?: throw IllegalStateException("No se encuentra la impresora USB")
        if (!permiso(d)) throw IllegalStateException("Sin permiso para usar la impresora USB")
        val (itf, ep) = salida(d) ?: throw IllegalStateException("La impresora USB no tiene salida de datos")
        val con = usb.openDevice(d) ?: throw IllegalStateException("No se pudo abrir la impresora USB")
        try {
            if (!con.claimInterface(itf, true)) throw IllegalStateException("La impresora USB está ocupada por otra app")
            var i = 0
            while (i < datos.size) {
                val n = minOf(4096, datos.size - i)
                val r = con.bulkTransfer(ep, datos, i, n, 5000)
                if (r <= 0) throw IllegalStateException("La impresora USB no acepta datos")
                i += r
            }
            con.releaseInterface(itf)
        } finally {
            con.close()
        }
    }

    /** Puertos serie de la placa en los que la app puede escribir (ttyS*, ttyUSB*, ttyACM*). */
    fun listarSerie(): List<String> =
        (File("/dev").listFiles() ?: emptyArray())
            .filter { f -> listOf("ttyS", "ttyUSB", "ttyACM").any { f.name.startsWith(it) } && f.canWrite() }
            .map { it.absolutePath }
            .sorted()

    fun enviarSerie(puerto: String, baudios: Int, datos: ByteArray) {
        if (baudios > 0) {
            // Ajusta la velocidad si el sistema trae stty; si no, se queda la del puerto
            try {
                Runtime.getRuntime().exec(arrayOf("stty", "-F", puerto, baudios.toString(), "raw", "-echo")).waitFor()
            } catch (_: Exception) {}
        }
        val f = File(puerto)
        if (!f.canWrite()) throw IllegalStateException("No se puede escribir en $puerto")
        FileOutputStream(f).use { it.write(datos); it.flush() }
    }
}
