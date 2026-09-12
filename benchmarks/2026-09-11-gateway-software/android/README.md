# Android gateway software evidence

Scope: Android emulator components and JVM protocol/application tests. These are
not physical USB, Android Wi-Fi Aware, cross-platform radio, acoustic audio,
locked-phone, endurance, or group-capacity results.

The first native run is retained as a failure: 7/8 passed; the synchronous
`JmDNS.getServiceInfo` lookup returned null after 8 seconds. The isolation run
proves explicit-interface public `MulticastSocket` loopback on emulator eth0,
while retaining the same JmDNS lookup failure. Its diagnostic snapshot contains
the received PTR/SRV/TXT/A records and a resolved service in the listener cache.
The production adapter uses `ServiceListener.serviceResolved`, not the one-shot
getter. The final native run passed **9/9**, including that callback with the same
8-second deadline and exact service/address/port assertions. This does not claim
a JmDNS internal root cause for the one-shot getter's observed null result.

The current candidate includes the later guide-local Aware ownership fix.
`build-ownership-final.log`: `lintDebug`, all app JVM tests (**198/198**, 37 suites),
debug app/test APKs, and unsigned release APK passed. `native-ownership-final.log`:
**9/9**, 12.774 seconds, no skipped cases. `summary.json` records these artifact
hashes and commands. `jvm-tests-final/` contains the current sanitized JUnit XML.

Earlier `build-final.log`, `native-final.log` (9/9, 13.495 seconds), and
`jvm-tests/` (193 tests) belong to the pre-ownership-fix candidate and are retained
only as history. The ownership regression first reproduced two failures:
missing original-guide Aware activation and missing companion preference
restoration. `discovery-ownership-before.log` retains those failures; the final
suite also verifies retained preferences despite radio failure, original-guide
diagnostics, and a tour ending during native offer setup.

Dependencies: [JmDNS 3.6.3 release](https://github.com/jmdns/jmdns/releases/tag/v3.6.3),
[Maven POM](https://repo.maven.apache.org/maven2/org/jmdns/jmdns/3.6.3/jmdns-3.6.3.pom),
Apache-2.0, transitive `slf4j-api:2.0.7`. No logging provider was added. Production
uses JmDNS's public unrecoverable-I/O delegate plus explicit lifecycle errors;
Android logs record exception classes without raw endpoint/error details.

The native TLS address-recovery fixture changes an injected interface inventory
from loopback IPv4 to IPv6 on the same NIC after enrollment expiry, retaining
the actual AndroidKeyStore certificates and native TLS connections. It proves
the software lifecycle, not DHCP or physical cable recovery.
