package com.example.myapplication.storage

import com.sun.jdi.Bootstrap
import com.sun.jdi.VMDisconnectedException
import com.sun.jdi.event.BreakpointEvent
import com.sun.jdi.event.ClassPrepareEvent
import com.sun.jdi.event.VMDeathEvent
import com.sun.jdi.event.VMDisconnectEvent
import com.sun.jdi.request.EventRequest
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.nio.file.Files

class BleSessionCsvDiscoveryWorkTest {
    @Test(timeout = 60_000)
    fun discovery_doesNotBuildRowsOrSampleValueMaps() {
        val directory = Files.createTempDirectory("csv-discovery-work").toFile()
        val connector = Bootstrap.virtualMachineManager().defaultConnector()
        val arguments = connector.defaultArguments()
        val classpath = listOf(
            BleSessionCsvExporter::class.java,
            CsvDiscoveryWorkProbe::class.java,
            kotlin.Unit::class.java,
        ).map { File(requireNotNull(it.protectionDomain?.codeSource).location.toURI()).path }.distinct()
            .joinToString(File.pathSeparator)
        arguments.getValue("main").setValue("${CsvDiscoveryWorkProbe::class.java.name} \"${directory.path}\"")
        arguments.getValue("options").setValue("-cp \"$classpath\"")
        val vm = connector.launch(arguments)
        val builds = LongArray(2)
        val rows = LongArray(2)
        val maps = LongArray(2)
        var phase = 0
        try {
            for (filter in listOf(
                "com.example.myapplication.storage.BleSessionCsvExporter*",
                "kotlin.collections.MapsKt__MapsJVMKt",
            )) {
                vm.eventRequestManager().createClassPrepareRequest().apply {
                    addClassFilter(filter)
                    setSuspendPolicy(EventRequest.SUSPEND_ALL)
                    enable()
                }
            }
            vm.resume()
            var running = true
            while (running) {
                val events = try { vm.eventQueue().remove(30_000) } catch (_: VMDisconnectedException) { break }
                checkNotNull(events) { "CSV work probe timed out" }
                for (event in events) {
                    when (event) {
                        is ClassPrepareEvent -> for (method in event.referenceType().methods()) {
                            val type = event.referenceType().name()
                            val kind = when {
                                type.endsWith("\$CsvRow") && method.name() == "<init>" -> "row"
                                type == BleSessionCsvExporter::class.java.name && method.name() == "buildRows" -> "build"
                                type == BleSessionCsvExporter::class.java.name && method.name() == "writeHeader" -> "header"
                                type == "kotlin.collections.MapsKt__MapsJVMKt" &&
                                    method.name() == "createMapBuilder" && method.signature() == "()Ljava/util/Map;" -> "map"
                                else -> null
                            }
                            if (kind != null) vm.eventRequestManager().createBreakpointRequest(method.location()).apply {
                                putProperty("kind", kind)
                                enable()
                            }
                        }
                        is BreakpointEvent -> when (event.request().getProperty("kind")) {
                            "header" -> phase = 1
                            "build" -> builds[phase]++
                            "row" -> rows[phase]++
                            "map" -> maps[phase]++
                        }
                        is VMDeathEvent, is VMDisconnectEvent -> running = false
                    }
                }
                try { events.resume() } catch (_: VMDisconnectedException) { break }
            }
            assertEquals("Probe exit", 0, vm.process().waitFor())
            println("CSV work discovery/emission: builds=${builds.toList()}, rows=${rows.toList()}, maps=${maps.toList()}")
            assertEquals("Discovery buildRows calls", 0L, builds[0])
            assertEquals("Discovery CsvRow constructors", 0L, rows[0])
            assertEquals("Discovery sample value maps", 0L, maps[0])
            assertEquals("Emission buildRows calls", 20L, builds[1])
            assertEquals("Emission CsvRow constructors", 40L, rows[1])
            assertEquals("Emission sample value maps", 40L, maps[1])
        } finally {
            vm.process().destroyForcibly()
            directory.deleteRecursively()
        }
    }
}

/** Subprocess runs the real compiled exporter; no application counters or mocked parser. */
object CsvDiscoveryWorkProbe {
    @JvmStatic
    fun main(args: Array<String>) {
        val directory = File(args.single())
        val packet = byteArrayOf(
            0x33, 0x99.toByte(), 0xaa.toByte(), 0x55, 26, 0, 1,
            9, 0, 0, 0, 50, 0, 0, 0, 0,
            2, 1, 2, 0, 0, 0, 10, 0, 20, 0,
        )
        val packets = directory.resolve("packets.bin")
        packets.outputStream().use { output -> repeat(20) { output.write(packet) } }
        BleSessionCsvExporter().export(packets, 1000, directory.resolve("out.csv"))
    }
}
