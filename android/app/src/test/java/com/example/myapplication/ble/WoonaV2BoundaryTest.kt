package com.example.myapplication.ble

// Synthetic C wire vectors, independently checked against firmware v2_protocol.c.
import com.example.myapplication.protocol.*
import org.junit.Assert.*
import org.junit.Test
private fun boundaryHex(value:String)=value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
class WoonaV2BoundaryTest {
 val streams=V2Streams(0,3,listOf(V2Stream(1,1,3,1000),V2Stream(2,1,3,1000)))
 @Test fun startAckAndDataCoalescedBeforeFinalWriteCallbackKeepFirstSamples() {
  val live=WoonaV2LiveSession(streams);val queue=WoonaV2GattWriteQueue()
  queue.begin(live.start(3).bytes,23)
  assertNotNull(queue.acknowledgeChunk()) // last chunk written; its callback has NOT arrived
  assertTrue(queue.isBusy)
  val decoder=WoonaV2StreamDecoder()
  val events=decoder.append(START_ACK+DATA).flatMap { live.receive(it) }
  assertEquals(2,events.size);assertTrue(events[0] is WoonaV2LiveSession.Event.Started)
  assertTrue(events[1] is WoonaV2LiveSession.Event.Samples)
  assertEquals(2,(events[1] as WoonaV2LiveSession.Event.Samples).block.count)
  assertTrue(queue.isBusy)
  assertNull(queue.acknowledgeChunk()) // final GATT callback releases only write queue
  assertEquals(WoonaV2LiveSession.Phase.RUNNING,live.phase)
 }
 @Test fun partialFirstDataSurvivesAcrossAckNotificationBoundary() {
  val live=WoonaV2LiveSession(streams);live.start(3);val decoder=WoonaV2StreamDecoder()
  val split=DATA.size/2
  val first=decoder.append(START_ACK+DATA.copyOfRange(0,split)).flatMap { live.receive(it) }
  assertEquals(1,first.size);assertTrue(first.single() is WoonaV2LiveSession.Event.Started)
  val second=decoder.append(DATA.copyOfRange(split,DATA.size)).flatMap { live.receive(it) }
  assertEquals(1,second.size);assertTrue(second.single() is WoonaV2LiveSession.Event.Samples)
 }
 @Test fun earlyHelloResponseQueuesNextCommandUntilFinalGattWriteCallback() {
  val discovery=WoonaV2Discovery();val queue=WoonaV2GattWriteQueue()
  queue.begin(discovery.begin().bytes,23);assertNotNull(queue.acknowledgeChunk())
  val next=discovery.receive(HELLO_ACK).single() as WoonaV2Discovery.Event.Transmit
  assertTrue(queue.isBusy)
  // The production startNextV2Frame busy guard leaves this pending, rather than beginning it now.
  val pending=java.util.ArrayDeque<ByteArray>();pending.add(next.bytes)
  assertEquals(WoonaV2Discovery.Phase.WAIT_STREAMS,discovery.phase)
  assertNull(queue.acknowledgeChunk());queue.begin(pending.removeFirst(),23)
  assertTrue(queue.isBusy);assertTrue(pending.isEmpty())
 }
 companion object {
  val START_ACK=boundaryHex("07574e413202840314180101026801010204010101020101024d0101020301010101010101010101010101010599aee3e400")
  val DATA=boundaryHex("07574e4132024003142401010269010101010101024d010102010201020203e8030101010201010101010220010480ffff01020104ff7f2a058593f7a800")
  val HELLO_ACK=boundaryHex("07574e41320281031410010102640101020101010302020103ff0701027f01010102080105c087de1500")
 }
}
