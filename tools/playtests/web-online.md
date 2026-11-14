# Web release online playtest

Build the matching backend first, then run from the project root:

```powershell
Push-Location server
npm.cmd run build
Pop-Location
node tools/playtests/web-online.mjs 'D:\Projects\ChatGPT\涅槃\outputs\commercial-preview\web' 'D:\Projects\ChatGPT\涅槃\outputs\commercial-preview\web-online' --ranked
```

The input directory must contain an actual Godot release export and `manifest.json` with matching SHA-256 hashes. Optional environment variables `PLAYWRIGHT_MODULE` and `BROWSER_EXECUTABLE` override the existing Playwright installation and browser executable. The default paths use the already installed Codex runtime and Edge; no packages are installed by this script.

The runner creates an independent in-memory server, random loopback port, two test accounts, two separate browser profiles, and temporary files under the project's `work/playtests/`. It never uses port 8080 or the player's database. No test balance, equipment, health baseline or result is inserted: both players earn their first currency and equipment by actually fighting the authoritative first boss.

Release Web templates disable `--script` and path overrides. To inspect and operate real Godot controls, this runner makes a temporary copy of the release HTML and preloads a test-only Node scene plus `override.cfg` into the browser's virtual filesystem through the official Engine API. That scene instantiates the unmodified production PCK's main scene. Its limited bridge reads state, edits form controls, sends mouse/input actions and confirms the UI dialog. It cannot write authoritative combat results or generate rewards. The release HTML and PCK remain unchanged, and the bridge is excluded from the export by the `tools/*` filter. A separate basic browser smoke test checks the delivered HTML without this bridge.

The online run covers actual WebSocket combat and real browser offline/reconnect, first-clear rewards, reward-funded wishing, wear/upgrade/unequip, sale and cross-account purchase retaining the same equipment ID/school/level, friend invitation/acceptance/private chat, friendly duel knockout/history, and (with `--ranked`) queue cancellation, requeue, automatic entry, authoritative victory, exact rating changes and the leaderboard. Network interruption combines browser offline mode with termination of only that fixture account's existing server WebSocket, since Chromium can retain an established socket in offline emulation. The runner verifies the authoritative `reconnecting` phase and unchanged health during the outage before restoring networking and checking return to the same fight.

The draw check fetches the first actual `growth.draw` response to ensure the server committed it, then deliberately aborts delivery. It verifies the WebSocket wallet update to 30, the retained original request key and the recoverable button despite funds below the draw cost. It refreshes the browser and logs in again, recovers the same request, and checks the original equipment instance plus exactly one -70 ledger debit. That one deliberate failed browser request is recorded as expected fault injection; other runtime/HTTP failures still fail the run. `--draw-recovery-only` runs just fresh-player PVE and this recovery path. `--draw-recovery-diagnostic` also records pre/post-presentation button states without treating a missing recovery caption as a product pass.

To check the delivered HTML without any bridge, run `node tools/playtests/web-basic.cjs --final`. The PCK resource audit is `web-pack-audit.gd` and is launched with a native Godot executable using `--main-pack <index.pck> --script <absolute audit path>`; set `XIUXIAN_PACK_AUDIT` to a D-drive JSON output and `XIUXIAN_PACK_PATH` to the same PCK's absolute path. `web-release-manifest.mjs --pending` identifies a fresh export before testing; its final mode requires the pack/basic/online results, matching PCK hashes and unchanged runtime sources before marking validation passed.

Screenshots and `web-online-report.json` are written to the selected output. The report identifies the tested PCK hash and includes final fixture-account snapshots, observed milestones, HTTP failures and runtime errors. A failed run writes its diagnostic state under that run's isolated work directory and exits nonzero. This check does not certify public deployment, mobile combat controls, weak-network performance or long-duration operation.
