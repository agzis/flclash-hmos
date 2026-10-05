# FlClash HarmonyOS

HarmonyOS-only ARM64 proxy client using Mihomo. This checkout is a developer source tree, not a production release. The app requires a HarmonyOS device with the VPN extension APIs (the integration target is Mate60 Pro / API 24), a valid Mihomo profile supplied by the user, and Developer Mode/USB debugging for HDC installation.

## Build on macOS with DevEco Studio

1. Install DevEco Studio and its HarmonyOS SDK (compile SDK 26, target API 24, minimum compatible API 22). For a fresh checkout, copy `harmony/build-profile.template.json5` to `harmony/build-profile.json5`; do not overwrite existing local signing configuration. Open `harmony/` in DevEco Studio, synchronize dependencies, and use **Automatically generate signing** for your own development certificate/profile. The generated configuration is ignored; never commit signing material. Development certificates/profiles expire and are not production distribution credentials.
2. From the repository root, build the Go core and then the signed development HAP:

   ```sh
   ./harmony/scripts/build-core.sh
   ./harmony/scripts/build-hap.sh
   ```

   The scripts default to `/Applications/DevEco-Studio.app/Contents`; set `DEVECO_HOME` for another installation. `build-hap.sh` sets `JAVA_HOME` to DevEco's bundled JBR (`Contents/jbr/Contents/Home`) unless explicitly overridden. The core build is `GOOS=openharmony GOARCH=arm64 CGO_ENABLED=1`, uses the bundled OpenHarmony Native SDK compiler/sysroot, and emits ignored `harmony/libs/arm64-v8a/libmihomo.so` with SONAME `libmihomo.so`. Setup verifies the source archive hash below, downloads/checksums the official Go 1.24.13 macOS bootstrap, and builds the OpenHarmony toolchain in the user's cache directory, not a temporary project path. First setup requires network access and a macOS x86-64 or arm64 host.
3. The signed output is `harmony/entry/build/default/outputs/default/entry-default-signed.hap`. It is a device-authorized developer package, not an app-store distribution package. Do not publish development keys.
4. Connect an authorized ARM64 HarmonyOS phone with USB debugging enabled. Install the resulting signed HAP:

   ```sh
   ./harmony/scripts/install-hap.sh
   ```

   If multiple HDC targets are present, set `HDC_TARGET` to the authorized phone's connect key. The installer checks HDC's actual success message because HDC can exit with status zero after a failed command. Installation works while the phone is locked, but launching the UI requires manual unlock in Developer Mode; do not disable debugging or share a screen-lock credential.

   The bundled HDC tool is used by default. The system will request VPN authorization at first start; review the permission and approve it to use the VPN. To stop proxying, use the app's Stop action; uninstalling the app is not a substitute for stopping a live VPN first.

Build artifacts, local toolchain caches, credentials and personal profile files are not release sources and must not be committed. This project does not include or prescribe any subscription URL or profile.

## Development and testing retrospective

See [开发与实机测试复盘](DEVELOPMENT_RETROSPECTIVE.md) for confirmed technical defects, costly diagnostic mistakes, evidence limits, implementation entry points, and a reusable device-acceptance checklist. In particular, the earlier controller-loss symptom has no established single root cause; the final successful network smoke must not be presented as proof of long-term stability.

## Daily operation

- Add a profile only from a URL you control or a file you select through the system document picker. Profile URLs and YAML contain credentials: treat both as secrets and do not paste them into issue reports, screenshots, logs, or source files.
- Select the desired profile, then use Connect/Start and approve the HarmonyOS VPN prompt. Use the app's Stop action to disconnect. Choose Rule, Global, or Direct mode as needed; mode affects the running core after a successful controller update.
- Profiles can be selected, updated, renamed, and deleted from the profile area. Proxy groups expose their configured members/current selection; select a node there. A delay is a real request to the configured test URL while the core is running, not a synthetic estimate.
- The dashboard, connections, and logs reflect core/controller state when connected. Close a connection from its details or close all from the connections view. Settings contain appearance and latency-test URL preferences. These controls require a valid imported profile and network access to its proxy endpoints.

The authenticated controller binds only `127.0.0.1:9097`. Its ArkTS client uses RemoteCommunicationKit RCP (PATCH supported since API 11), not NetworkKit's API-26-only PATCH enum, so mode changes do not require upgrading the API-24 target phone.

Subscription downloads send `User-Agent: Clash.Meta/v1.19.31`, matching the pinned core. Some providers negotiate configuration format through this header; a generic HTTP client may receive a non-YAML subscription instead. Download/HTTP failures and native configuration-validation failures are reported separately without exposing the URL.

URL profiles use **更新** to fetch their subscription. File profiles use **替换文件** to select a newly granted document URI, validate its YAML, and replace the existing profile atomically; the original name, profile identity, and rollback behavior are retained. Canceling the system picker does not report an update.

The native build enables `with_gvisor`; the VPN-owned descriptor requires that userspace TUN stack. An omitted build tag causes startup failure, not a usable VPN. Mode changes apply to new connections: an existing browser HTTP/2 connection can retain its previous route until closed.

## Verification status

- Native OpenHarmony ARM64 core and the complete ArkTS/native HAP build successfully from `harmony/`; the HAP is development-signed and installed on the owner's Mate60 Pro / API 24.
- The final native dashboard, profile form, and settings rendered on the phone. Light and dark themes were visually checked; dark appearance persisted across reinstall/relaunch, and the system-follow option was selected successfully. Device smoke checks also caught and fixed existing-directory initialization errors and unreadable dark-theme input/button text.
- The final app imported the authorized subscription and retained the active profile across replacement installation/relaunch. Host requests also verified content negotiation: a default client received non-YAML content, while the Mihomo User-Agent received a YAML profile. Automated text entry reordered URL punctuation through the phone input method, so the successful import used owner-pasted input.
- Device startup initially failed because the native build omitted `with_gvisor`. After correcting the tag, the final VPN ran and the system browser reached Cloudflare's HTTPS trace endpoint: rule/global mode reported Hong Kong egress; direct mode reported China after closing old connections and establishing a fresh browser connection. TLS 1.3 was reported. This also exercised VPN operation with the app UI in the background.
- The dashboard displayed actual cumulative traffic (3.8 MB down / 136.4 KB up at the observed point); the connections view showed 43 active TUN connections and a `GeoIP` / `DIRECT` detail. Single/all-close controls and live TCP/UDP logs were exercised. The stable-key list-row regression passed on the phone: selecting Hong Kong 2 immediately updated the group title and selected marker, a manual latency test completed at 316 ms, renaming immediately updated the profile list, and the imported-profile count displayed 1.
- Live subscription update and ordinary stop exposed a teardown acknowledgment defect. Credential-free temporary diagnostics proved native shutdown completed in 31 ms; acknowledgment was attempted from an asynchronous callback after `onDestroy` returned. The correction requests shutdown while the extension context is alive, awaits OS interface destruction, and correlates its persisted acknowledgment with a fresh request ID before terminating the extension. Temporary native diagnostics were removed. Device regression passed: start/normal stop was acknowledged without timeout; a subsequent live subscription update completed, restarted the VPN, advanced the displayed update time, and preserved Hong Kong 2 selection.
- Real document-picker import initially rejected a valid DIRECT-only YAML because native inspection/startup wrongly required proxy nodes or providers. Removing that requirement preserves Mihomo's valid direct-routing semantics. Device regression imported the downloaded 224-byte YAML through the system-granted URI, displayed two saved profiles, switched to the file profile, started its system VPN, and loaded Baidu over HTTPS.
- File replacement passed through the real system picker: valid replacement changed the running group from `FILE` to `FILE_NEXT`; malformed YAML left the old file, update timestamp, group and running VPN intact. An actual URL subscription returned HTTP 503 on update; its prior YAML and timestamp were retained. Both temporary profiles were subsequently deleted, the original subscription name restored, and the user's subscription remained active.
- Sustained external HTTPS download exercised live telemetry: the dashboard displayed 6.0 MB/s and 16.5 MB cumulative download at an observed point; the same active `speed.cloudflare.com` connection advanced from 22.9 MB to 42.1 MB. A separate LAN fixture download is not counted as proof of VPN traffic.
- Physical-network smoke confirmed Wi-Fi was actually disabled using the control-center radio icon, then restored to the original network. Fresh Cloudflare HTTPS traces reported Hong Kong on cellular and after Wi-Fi reconnection; the native dashboard stayed running and an independent TCP probe reached the authenticated controller (HTTP 401 without credentials). The first immediate Wi-Fi-return page was still in flight; a subsequent settled request completed. This is recovery proof, not a measured handoff-latency guarantee. Network callbacks use `Map.get` and refresh cached DNS transports when the physical network ID changes.
- The final diagnostic-free signed HAP was rebuilt and installed, then exercised again: confirmed cellular-only HTTPS reported Hong Kong and the UI remained running; the original Wi-Fi was restored and a fresh background HTTPS trace completed. After 175 seconds with the system browser foregrounded, the controller still answered and returning to the app showed running. Normal Stop reached stopped; force-stopping the already-disconnected app and cold-launching it retained the original profile name and no fixture profiles. The phone was left disconnected on its original Wi-Fi. Both local fixture servers and their two HDC forwarding tasks were removed; all five identified test downloads were deleted using the browser's delete-task-and-file action. Power-service diagnostics confirmed the screen-off timeout is 600000 ms, not the temporary one-hour override.
- Final privacy checks scanned all 16 signed-HAP members and 19 deliverable implementation/configuration/documentation files: no private subscription URL or imported proxy credential was found. Earlier broader source checks covered 27 files. The final HAP has no test subscription resource, fixture endpoint or temporary diagnostic tag. Private inputs, local signing configuration, generated binaries, and packages are ignored by source control.
- The installer was exercised against the authorized phone (success) and an unavailable target (rejected with exit status 1). It does not mistake HDC's zero-status failure output for a successful install.

Earlier narrow VPN/TUN phone experiments do not establish acceptance of this final UI/runtime. Only HarmonyOS ARM64 is targeted. Development signing may expire and must be regenerated by the local developer.

## Certificate trust

Native HTTPS latency tests and remote provider downloads use the bundled Mozilla CA store, not a verification bypass. `cacert.pem` is the unmodified [curl/Mozilla 2026-09-25 bundle](https://curl.se/ca/cacert-2026-09-25.pem), with 121 roots and SHA-256 `a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505`. [curl's CA extraction documentation](https://curl.se/docs/caextract.html) identifies the store license as MPL-2.0; its license text is retained in `LICENSES/MPL-2.0.txt`. The CA store is subject to the Mozilla Public License, v. 2.0, available at <https://mozilla.org/MPL/2.0/>. The original PEM is the supplied source form. Maintain this trust snapshot when rebuilding; it does not inherit Firefox's additional domain constraints.

An imported profile can independently request `skip-cert-verify`; that is a credential-interception risk, not a trusted application default. Prefer profiles whose proxy server certificates verify normally.

## Bundled geodata and attribution

The rawfile names are the case-sensitive filenames Mihomo/runtime expects: `GeoSite.dat`, `GeoIP.dat`, and `Country.mmdb`. They were fetched from MetaCubeX's own release links, as listed by its repository README:

- `GeoSite.dat`: <https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat> — SHA-256 `79e7a395c57da61aeb3f68db01121c1a0730ab2bd1c8bbe4c0c327786e225134`
- `GeoIP.dat`: <https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat> — SHA-256 `391b522361c52804e486a98b53d97f3d9c1d3e4e4217bb34954774a0b456b9fd`
- `Country.mmdb`: <https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb> — SHA-256 `b13f10cdb414b8db78a64c432d6cd511668415760ee0fb2d17ac9f42de5aba08`

This snapshot is pinned by the hashes above; the `latest` download links are mutable. MetaCubeX's README attributes `country.mmdb` and `geoip.dat` content to [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat), and lists upstream sources used in its geosite data (including V2Fly, Loyalsoldier and other rule projects). The [Loyalsoldier/geoip license and README](https://github.com/Loyalsoldier/geoip) declare CC-BY-SA-4.0 and GPL-3.0 and describe GeoLite2-derived products; its README specifically states the country/IP data is based on MaxMind GeoLite2 Country data. [MaxMind's current GeoLite EULA](https://www.maxmind.com/en/geolite/eula) requires attribution, links to CC-BY-SA-4.0, and defines additional use/disclosure and update/destruction conditions. Attribution: “This product includes GeoLite Data created by MaxMind, available from https://www.maxmind.com.” The database also contains community-modified/augmented IP data; see the linked sources for their terms. These files are included for this owner's private HarmonyOS phone build; this is not authorization to redistribute a HAP or geodata. Any sharing/distribution must preserve applicable CC-BY-SA/GPL and source attributions and comply with MaxMind EULA requirements, including its limits on disclosure.

Mihomo is upstream [MetaCubeX/Mihomo](https://github.com/MetaCubeX/mihomo) (vendored version v1.19.31); its source and dependencies retain their upstream notices/licenses. The complete portable Go source archive `harmony/third_party/ohos-go-1.24.13-src.tar.gz` is SHA-256 `bcad81e5016d7f61dbeef866f9919df677bedd2c1539626fefbd0eb03e885ddd`, including Go's `LICENSE`, `PATENTS`, and required `lib/time/zoneinfo.zip`, but excluding compiled host/target tools. The reference source's provenance records the [OpenHarmony-SIG release-branch.go1.24](https://gitcode.com/openharmony-sig/ohos_golang_go/tree/release-branch.go1.24) port commit `302a5306b6fad2f47196360b82561d1db1f954cf`, merged with upstream Go 1.24.13 commit `96e4e2b1616c3c59577d48abcf2823bf1fdcd2e2`, retaining upstream security fixes in merge conflicts. The archive checksum pins the included merged snapshot, not a byte-for-byte checkout of either upstream commit.

The vendored Mihomo core carries its upstream GPL-3.0 license (`harmony/core/vendor/github.com/metacubex/mihomo/LICENSE`). The application integrates with that core; a conveyed combined binary must meet all applicable GPL-3.0 source, notice, and licensing terms. Review dependency notices and the data terms before distributing anything. The interface is inspired by [FlClash](https://github.com/chen08209/FlClash), implemented independently in ArkTS/ArkUI, and is not an official FlClash release.
