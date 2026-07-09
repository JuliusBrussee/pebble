# 05 — Network Protocol, TCP Transport, Discovery, and Social Connectivity

## Scope

Files: `Sources/PebbleCore/Net/NetProtocol.swift`, `NetSession.swift`, `NetTransport.swift`, `Social.swift`, `Sources/Pebble/LanScreens.swift`, `packaging/Info.plist`.

Goal: keep the wire protocol stable while replacing Apple-only transport/discovery with portable direct TCP and adapter-based discovery.

## Current blockers

- `NetTransport.swift` and `NetSession.swift` import Apple `Network`.
- UI stores `NWEndpoint`-style concrete endpoints.
- Network callbacks assume `DispatchQueue.main`.
- Social writes through singleton/default paths.
- Windows server E2E also needs server runtime and data-root modules.

## Target architecture

Split networking into:

1. **Protocol codec**: message IDs, fields, endian rules, exact decode.
2. **Chunk wire helpers**: VCK1 chunk payloads shared with persistence codec.
3. **Runtime interfaces**: `NetConnection`, `NetListener`, `NetBrowser`, `NetworkServices`, `NetScheduler`, `DiscoveredSession`.
4. **Adapters**: Apple Network.framework + Bonjour; portable direct TCP; optional mDNS; in-memory fake.
5. **UI/session composition**: no concrete OS endpoint types in gameplay/UI.

## Plan

1. Add characterization tests for all `NetMsg` round-trips and current frame behavior.
2. Define exact decode policy: reject trailing junk, unknown type, invalid UTF-8, underflow, oversize, and zero-length frames according to the written spec.
3. Introduce transport-neutral interfaces and scheduler semantics.
4. Refactor `NetSession.swift` off `Network.framework` types.
5. Refactor `GameCore` LAN/dedicated entry points to accept `NetworkServices`.
6. Move `NWConnection`/`NWListener`/`NWBrowser`/Bonjour into an Apple adapter.
7. Add portable direct TCP adapter, ideally through isolated C/C++ socket shim if Swift OS socket imports get broad.
8. Make direct host:port the required cross-platform path before auto-discovery.
9. Keep macOS Bonjour TXT metadata and Info.plist local-network keys.
10. For Windows discovery, either implement tested mDNS or expose a tested direct-IP fallback with discovery disabled.
11. Replace `LanScreens.swift` endpoint storage with opaque discovered sessions and clipboard/network services.
12. Update `SECURITY.md`/docs to reflect real network attack surface.

## Verification gates

- Protocol round-trip tests pass unchanged where schema is unchanged.
- Malformed/truncated/oversized/unknown frames behave exactly as the spec says.
- Version mismatch sends a reason and cleans up state.
- macOS Apple transport loopback host/guest passes.
- Windows portable TCP direct host/guest passes.
- Dedicated server direct-IP E2E passes after server runtime lands.
- Social/friends/recent players tests use injected temp roots.
- Windows LAN discovery is either automated and tested or explicitly unavailable with direct-IP fallback.

## Done criteria

Portable network/session code has no Apple framework imports; direct TCP works cross-platform; Bonjour remains macOS adapter-only; UI and social are platform-neutral.
