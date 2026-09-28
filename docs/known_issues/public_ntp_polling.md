# Public NTP polling and benchmark bursts

## Issue

Repeatedly querying public NTP servers at short intervals can trigger server-side rate limits or a Kiss-o'-Death (KoD) response. This can make a benchmark's results reflect the server's rate limiting, packet loss, or changed response behavior instead of ordinary network and clock performance.

Chrony's documentation says polling public Internet servers more often than once every 64 seconds should generally be avoided because it may be considered abuse. This is implementation guidance, not a universal NTP protocol minimum: Chrony supports shorter intervals for local networks, and actual policies vary by server operator. See the [Chrony server polling options](https://chrony-project.org/doc/4.8/chrony.conf.html#server).

## Benchmarking guidance

- Avoid sending 8–16 requests to a public server as a rapid burst. Space requests according to the server operator's policy; at 64 seconds between requests, 8–16 samples take roughly 8–16 minutes per server.
- For short-interval or high-volume experiments, use a server you operate or have permission to benchmark.
- Record every raw four-timestamp measurement and the response metadata. Keep rejected, timed-out, and KoD responses visible in the dataset rather than silently treating them as normal measurements.
- If a server returns KoD `RATE`, reduce the polling rate and continue reducing it if further `RATE` responses arrive. For `DENY` or `RSTR`, stop querying that server. These are the client actions specified by [RFC 5905 §7.4](https://www.rfc-editor.org/rfc/rfc5905.html#section-7.4).
- Do not use the receive and transmit timestamps in a KoD packet as a valid time measurement; RFC 5905 says they are undefined and must be discarded.

## Why this matters to Kronos

Kronos should treat KoD packets as control responses, not successful time samples. A benchmarking client built on the library should make request cadence configurable and preserve each raw response outcome so that rate limiting is distinguishable from ordinary measurement noise.
