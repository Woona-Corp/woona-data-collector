# Legacy packet continuity and recovery

The counter and timer in the legacy header are **unsigned 32-bit little-endian**
values. A value of 65535 is not the rollover boundary. Source bytes, raw fragments
and their timestamps remain unchanged.

A structurally valid header can still be corrupt. The observed failure was a
normal `counter=644,timer=658674`, followed by a spurious
`counter=3222815366,timer=974731800`. Updating the trusted timer with that header
caused hundreds of subsequent ordinary packets to be rejected, and the loss
counter could report billions of packets.

Android and iOS now apply the same sequence guard **before** accepted-packet
persistence or clock/statistics changes:

- Normal forward counter/timer progression is accepted. Ordinary unsigned32
  rollover is handled modulo 2^32 and starts a separate chart segment.
- An unconfirmed counter advance of 100000 or more, a timer advance above one
  hour, a backward timer, or a duplicate/backward counter is quarantined. Its
  complete bytes remain in the raw capture; the reason, counter and timer are
  recorded, and it is counted as rejected rather than successful capture.
- An ordinary next header is compared against the last **trusted** packet,
  restoring reception immediately after a single corrupt header.
- Two coherent consecutive headers can establish a new discontinuous segment.
  This is evidence for resuming capture, not proof of a hardware reset or exact
  time alignment. A large confirmed forward gap is counted fully. A reset or
  ambiguous large backward/wrap transition is explicitly classified as unknown
  loss; it is never represented as a measured zero-loss interval.
- The advance limits are bounds on an **unconfirmed** transition, not limits on
  session length or permanently forbidden gap sizes. The first quarantined
  packet stays in raw and is not retroactively added to accepted packets.
- A new baseline is committed only after accepted packet and timeline writes
  succeed. Session reset clears trusted and pending headers.

No checksum is added to the legacy wire protocol and no source file is repaired
or filtered on the server. Two coherent headers cannot certify the authenticity
of a corrupt stream; real firmware/hardware tests and raw replay remain required.
Original anchors and packet timelines must be retained. Discontinuous clock
segments must not be presented as certified sensor/video alignment.

`shared/test-fixtures/packet-sequence.csv` is synthetic and is consumed by both
platforms' protocol tests. It covers the observed poison-header sequence,
legitimate gaps, large confirmed gaps, duplicate/backward counters, unsigned32
counter/timer rollover, timer regression, reset, and a bad first header.
Capture processor tests also assert that quarantined bytes remain in raw and
normal packets still reach the accepted-packet file.
