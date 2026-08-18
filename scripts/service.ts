/**
 * Deploy the relay as a macOS LaunchAgent — the only "deployment" this app has, since it must run
 * on the Mac that runs Conductor (local SQLite DB, git worktrees, and the sidecar unix socket all
 * live there). Installs a per-user agent that starts the relay on login and keeps it alive.
 *
 *   node scripts/service.ts <install|uninstall|status|restart>
 *   (or, once installed globally: `conductor-remote service <...>`)
 *
 * `yarn deploy` builds dist/ first, then runs `install`.
 */
import { execFileSync, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { packageRoot } from '../src/pkg-root.ts'
import type { ExposeMode } from '../src/tailscale.ts'
import {
	driftWarningLines,
	exposeStorePath,
	magicDnsName,
	normalizeExposeMode,
	relayPort,
	tailscaleBin,
	writeUrlHost
} from '../src/tailscale.ts'
import { qrLines } from './qr.ts'

const LABEL = 'no.adluna.conductor-remote'
const projectDir = packageRoot(import.meta.dirname)
const plistPath = path.join(os.homedir(), 'Library', 'LaunchAgents', `${LABEL}.plist`)
const logDir = path.join(os.homedir(), 'Library', 'Logs', 'conductor-remote')
const uid = process.getuid?.() ?? 0
const domain = `gui/${uid}`

/**
 * Install-time knobs are accepted as documented CLI flags OR the matching env var — a flag wins over the
 * ambient env. Parsed flags are folded back into process.env so everything downstream (and the plist we
 * bake) keeps reading a single source. Runs before any module-level env read below.
 */
const FLAG_ENV: Record<string, string> = {
	'--expose': 'EXPOSE',
	'--port': 'RELAY_PORT',
	'--host': 'RELAY_HOST',
	'--hostname': 'RELAY_HOSTNAME',
	'--token': 'RELAY_TOKEN',
	'--write-strategy': 'WRITE_STRATEGY',
	'--auto-update': 'AUTO_UPDATE',
	'--auto-update-interval': 'AUTO_UPDATE_INTERVAL_MINUTES',
	'--funnel-watchdog': 'FUNNEL_WATCHDOG',
	'--funnel-watchdog-interval': 'FUNNEL_WATCHDOG_INTERVAL_SECONDS',
	'--db': 'CONDUCTOR_DB',
	'--workspaces': 'CONDUCTOR_WORKSPACES'
}

function applyFlags(argv: string[]): void {
	for (let i = 0; i < argv.length; i++) {
		const arg = argv[i]
		if (!arg.startsWith('--')) continue
		const eq = arg.indexOf('=')
		const name = eq === -1 ? arg : arg.slice(0, eq)
		const envKey = FLAG_ENV[name]
		if (!envKey) {
			console.error(`unknown flag: ${name}\n  known: ${Object.keys(FLAG_ENV).join(', ')}`)
			process.exit(1)
		}
		const value = eq === -1 ? argv[++i] : arg.slice(eq + 1)
		if (value === undefined) {
			console.error(`flag ${name} needs a value (e.g. ${name} <value>)`)
			process.exit(1)
		}
		process.env[envKey] = value
	}
}

// argv[2] is the subcommand (see bottom); flags follow it. `logs` parses its own args (it takes -n /
// --no-follow, which applyFlags would reject as unknown flags), so skip the shared flag pass for it.
if ((process.argv[2] ?? 'status') !== 'logs') applyFlags(process.argv.slice(3))

function xml(s: string): string {
	return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

/** Run launchctl, swallowing the exit code so "already-loaded"/"not-loaded" states aren't fatal. */
function launchctl(...args: string[]): void {
	try {
		execFileSync('launchctl', args, { stdio: 'pipe' })
	} catch {
		// non-zero is expected for bootout-when-absent etc.; state is asserted by the caller's sequence
	}
}

/** Block the main thread briefly — used to let launchd settle between bootout and bootstrap. */
function sleepSync(ms: number): void {
	Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
}

/** Is the agent currently bootstrapped into the user domain? */
function serviceLoaded(): boolean {
	try {
		execFileSync('launchctl', ['print', `${domain}/${LABEL}`], { stdio: 'pipe' })
		return true
	} catch {
		return false
	}
}

/**
 * Reload the agent from the freshly written plist. `bootout` of a *running* instance is asynchronous,
 * so we wait for it to fully unload before `bootstrap` — otherwise bootstrap races the teardown and
 * fails silently, leaving the relay down after a re-deploy. Bootstrap is retried and its failure is fatal.
 */
function reloadAgent(): void {
	launchctl('bootout', `${domain}/${LABEL}`)
	for (let i = 0; i < 30 && serviceLoaded(); i++) sleepSync(100)
	let bootstrapped = false
	for (let i = 0; i < 10 && !bootstrapped; i++) {
		try {
			execFileSync('launchctl', ['bootstrap', domain, plistPath], { stdio: 'pipe' })
			bootstrapped = true
		} catch {
			sleepSync(150)
		}
	}
	if (!bootstrapped) {
		console.error(`✗ launchctl bootstrap failed for ${plistPath}`)
		console.error(`  Inspect with: launchctl print ${domain}/${LABEL}`)
		process.exit(1)
	}
	launchctl('enable', `${domain}/${LABEL}`)
	launchctl('kickstart', '-k', `${domain}/${LABEL}`)
}

/**
 * The relay's own private copy of node. macOS keys the Accessibility grant on
 * the exact binary, so pointing the LaunchAgent at nvm/Homebrew node means
 * every node upgrade (or a deploy run under a different version) silently
 * revokes the grant — measured live 2026-08-18: a redeploy left every AX write
 * refused. Copying node to a relay-owned path makes the grant survive both.
 * The copy is refreshed only when the *running* node is a different version
 * (`node --version` of the copy vs process.version), and a refresh is loudly
 * announced because it re-requires the one-time grant.
 */
function privateNode(): string {
	const binDir = path.join(os.homedir(), 'Library', 'Application Support', 'conductor-remote', 'bin')
	const target = path.join(binDir, 'node')
	let currentVersion: string | null = null
	try {
		currentVersion = execFileSync(target, ['--version'], { encoding: 'utf8' }).trim()
	} catch {
		currentVersion = null
	}
	if (currentVersion === process.version) return target
	fs.mkdirSync(binDir, { recursive: true })
	fs.copyFileSync(process.execPath, target)
	fs.chmodSync(target, 0o755)
	console.log(
		currentVersion
			? `  Refreshed the relay's private node (${currentVersion} → ${process.version}) — macOS will ask for the Accessibility grant again (System Settings ▸ Privacy & Security ▸ Accessibility ▸ ${target}).`
			: `  Installed the relay's private node at ${target} (${process.version}) — grant it Accessibility once and future deploys/node upgrades keep it.`
	)
	return target
}

/** Node runs the relay via the flag-free CLI shim; the private-copy path is baked at install time. */
function buildPlist(): string {
	const nodePath = privateNode()
	const node = xml(nodePath)
	const proj = xml(projectDir)
	const out = xml(path.join(logDir, 'relay.log'))
	const err = xml(path.join(logDir, 'relay.err.log'))
	// The *source* node's dir leads so the daemon can find `npm` (adjacent to
	// node, not copied) for self-update under launchd's bare PATH; Homebrew's
	// bin is appended for tailscale/node on Apple Silicon.
	const nodeDir = path.dirname(process.execPath)
	const daemonPath = `${nodeDir}:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin`
	// MANAGED marks this as the launchd-supervised instance: autoupdate.ts only self-restarts (exit →
	// KeepAlive respawn) when it sees this, so a dev `yarn start` or worktree run never auto-updates.
	const envEntries: Array<[string, string]> = [
		['PATH', daemonPath],
		['CONDUCTOR_REMOTE_MANAGED', '1']
	]
	if (process.env.WRITE_STRATEGY) envEntries.push(['WRITE_STRATEGY', process.env.WRITE_STRATEGY])
	if (process.env.RELAY_HOST) envEntries.push(['RELAY_HOST', process.env.RELAY_HOST])
	if (process.env.RELAY_PORT) envEntries.push(['RELAY_PORT', process.env.RELAY_PORT])
	if (process.env.AUTO_UPDATE) envEntries.push(['AUTO_UPDATE', process.env.AUTO_UPDATE])
	if (process.env.AUTO_UPDATE_INTERVAL_MINUTES)
		envEntries.push(['AUTO_UPDATE_INTERVAL_MINUTES', process.env.AUTO_UPDATE_INTERVAL_MINUTES])
	if (process.env.FUNNEL_WATCHDOG) envEntries.push(['FUNNEL_WATCHDOG', process.env.FUNNEL_WATCHDOG])
	if (process.env.FUNNEL_WATCHDOG_INTERVAL_SECONDS)
		envEntries.push(['FUNNEL_WATCHDOG_INTERVAL_SECONDS', process.env.FUNNEL_WATCHDOG_INTERVAL_SECONDS])
	if (process.env.CONDUCTOR_DB) envEntries.push(['CONDUCTOR_DB', process.env.CONDUCTOR_DB])
	if (process.env.CONDUCTOR_WORKSPACES) envEntries.push(['CONDUCTOR_WORKSPACES', process.env.CONDUCTOR_WORKSPACES])
	const envXml = envEntries.map(([k, v]) => `\t\t<key>${xml(k)}</key>\n\t\t<string>${xml(v)}</string>`).join('\n')
	return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${node}</string>
		<string>${proj}/bin/cli.js</string>
	</array>
	<key>WorkingDirectory</key>
	<string>${proj}</string>
	<key>EnvironmentVariables</key>
	<dict>
${envXml}
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>StandardOutPath</key>
	<string>${out}</string>
	<key>StandardErrorPath</key>
	<string>${err}</string>
</dict>
</plist>
`
}

function distBuilt(): boolean {
	return fs.existsSync(path.join(projectDir, 'dist', 'index.html'))
}

function tokenStorePath(): string {
	return path.join(os.homedir(), 'Library', 'Application Support', 'conductor-remote', 'token')
}

/** Read the persisted token (or env override) purely to print the phone URL — never mints one. */
function currentToken(): string | null {
	if (process.env.RELAY_TOKEN) return process.env.RELAY_TOKEN
	try {
		return fs.readFileSync(tokenStorePath(), 'utf8').trim() || null
	} catch {
		return null
	}
}

/**
 * A pinned token (`--token` / `RELAY_TOKEN`) is persisted to the token file, not baked into the plist —
 * the launchd daemon has no such env, so it resolves the secret from this file (config.ts ▸ resolveToken).
 * Writing it here keeps the daemon, the printed URL, and later `status` all in agreement.
 */
function persistPinnedToken(): void {
	const token = process.env.RELAY_TOKEN
	if (!token) return
	try {
		fs.mkdirSync(path.dirname(tokenStorePath()), { recursive: true })
		fs.writeFileSync(tokenStorePath(), token, { mode: 0o600 })
	} catch (err) {
		console.info(`  ⚠ could not persist --token (${err instanceof Error ? err.message : err})`)
	}
}

const RELAY_PORT = relayPort()

/**
 * Resolve the expose mode. Precedence: `EXPOSE` env (public|funnel / tailnet|serve|private) > persisted
 * choice > 'public' default. An explicit env value is persisted so re-deploys don't silently flip posture.
 * (The read-only counterpart used by the runtime watchdog is readExposeMode() in src/tailscale.ts.)
 */
function resolveExposeMode(): ExposeMode {
	const fromEnv = normalizeExposeMode(process.env.EXPOSE)
	if (fromEnv) {
		try {
			const file = exposeStorePath()
			fs.mkdirSync(path.dirname(file), { recursive: true })
			fs.writeFileSync(file, fromEnv)
		} catch {
			// persistence is a convenience; ignore failures
		}
		return fromEnv
	}
	if (process.env.EXPOSE) console.info(`  ⚠ unrecognized EXPOSE=${process.env.EXPOSE} — expected public|tailnet.`)
	try {
		const saved = normalizeExposeMode(fs.readFileSync(exposeStorePath(), 'utf8'))
		if (saved) return saved
	} catch {
		// no saved choice yet
	}
	return 'public'
}

/** Live serve/funnel state for this node: is the loopback proxy wired, and is Funnel (public) on? */
function tailscaleState(bin: string, dns: string | null): { proxyOk: boolean; funnelOn: boolean } {
	if (!dns) return { proxyOk: false, funnelOn: false }
	try {
		const out = execFileSync(bin, ['serve', 'status', '--json'], { encoding: 'utf8', stdio: 'pipe' })
		const cfg = JSON.parse(out)
		const key = `${dns}:443`
		const proxyOk = cfg?.Web?.[key]?.Handlers?.['/']?.Proxy === `http://127.0.0.1:${RELAY_PORT}`
		return { proxyOk, funnelOn: Boolean(cfg?.AllowFunnel?.[key]) }
	} catch {
		return { proxyOk: false, funnelOn: false }
	}
}

/** Assert the tailnet-only `serve` proxy — used for tailnet mode and as the Funnel fallback. */
function ensureServeOnly(bin: string, url: string, state: { proxyOk: boolean; funnelOn: boolean }): void {
	if (state.proxyOk && !state.funnelOn) {
		console.info(`✓ tailscale serve fronts ${url} → 127.0.0.1:${RELAY_PORT} (tailnet-only)`)
		return
	}
	try {
		execFileSync(bin, ['serve', '--bg', RELAY_PORT], { stdio: 'pipe' })
		console.info(`✓ tailscale serve → ${url} proxies 127.0.0.1:${RELAY_PORT} (tailnet-only)`)
	} catch (err) {
		console.info(
			`\n  ⚠ could not configure tailscale serve (${err instanceof Error ? err.message : err}). Run by hand:`
		)
		console.info(`      tailscale serve --bg ${RELAY_PORT}`)
	}
}

/**
 * Persist a stable Tailscale device name so this node's MagicDNS URL — the origin the installed PWA is
 * bolted to — can't drift out from under it. Tailscale otherwise *derives* the name from the Mac's
 * LocalHostName, which a macOS update or a network/settings reset can silently clear; the name then moves
 * (e.g. `mac` → `macbook-pro`), the URL changes, and every home-screen PWA pinned to the old origin dies
 * with an unexplained "failed to fetch". We pin `--hostname`/`RELAY_HOSTNAME` when given (also the way to
 * *rename* — `--hostname mac` restores a drifted node), else re-pin whatever name the node already has: a
 * no-op on today's URL, but it turns an auto-derived name into an explicit one Tailscale won't re-derive.
 * Best-effort — a failure just leaves the name auto-derived, exactly as before this ran.
 */
function pinHostname(bin: string): void {
	const label = (dns: string | null): string => (dns ?? '').split('.')[0]
	const current = label(magicDnsName(bin))
	const desired = (process.env.RELAY_HOSTNAME ?? '').trim() || current
	if (!desired) return // node name unknown and none requested — nothing to pin
	try {
		execFileSync(bin, ['set', `--hostname=${desired}`], { stdio: 'pipe' })
	} catch (err) {
		console.info(
			`  ⚠ could not pin tailscale hostname to "${desired}" (${err instanceof Error ? err.message.trim() : err}) — name stays auto-derived.`
		)
		return
	}
	if (desired === current) {
		console.info(`✓ tailscale device name pinned to "${desired}" (won't drift on an OS hostname change)`)
		return
	}
	// A rename: wait briefly for MagicDNS to reflect it, so the URL and Funnel cert below use the new name.
	for (let i = 0; i < 12 && label(magicDnsName(bin)) !== desired; i++) sleepSync(500)
	const actual = label(magicDnsName(bin))
	if (actual === desired)
		console.info(`✓ tailscale device renamed "${current || '<derived>'}" → "${desired}" and pinned`)
	else
		console.info(
			`  ⚠ requested hostname "${desired}" but the tailnet assigned "${actual}" (name likely already taken) — your URL is https://${actual}.…`
		)
}

/**
 * Front the loopback relay with a stable HTTPS URL, either publicly (`tailscale funnel`, the default) or
 * tailnet-only (`tailscale serve`), per resolveExposeMode(). Idempotent — flips Funnel off when switching
 * back to tailnet — and non-fatal: the relay binds loopback regardless, so a failure here just means the
 * phone URL isn't wired yet and we print how to do it by hand. Real TLS also satisfies the PWA's
 * secure-context requirement (a service worker won't register over plain http on a 100.x IP).
 *
 * PUBLIC IS INTERNET-FACING: the 128-bit token on every /api/* request is the only gate. Funnel must be
 * enabled for the tailnet (Admin console) or the funnel command fails — we then fall back to tailnet-only.
 */
function ensureTailscale(): void {
	const bin = tailscaleBin()
	if (!bin) {
		console.info('\n  ⚠ tailscale CLI not found — skipped URL setup. Once Tailscale is installed, run:')
		console.info(`      tailscale funnel --bg ${RELAY_PORT}   # public, or \`serve\` for tailnet-only`)
		return
	}
	pinHostname(bin)
	const dns = magicDnsName(bin)
	if (dns) writeUrlHost(dns) // baseline for drift detection (server startup + `service status` compare against this)
	const url = `https://${dns ?? '<node>'}/`
	const mode = resolveExposeMode()
	const state = tailscaleState(bin, dns)

	if (mode === 'tailnet') {
		if (state.funnelOn) {
			try {
				execFileSync(bin, ['funnel', 'reset'], { stdio: 'pipe' })
			} catch {
				// best-effort; ensureServeOnly re-asserts the proxy below
			}
			ensureServeOnly(bin, url, { proxyOk: false, funnelOn: false })
		} else {
			ensureServeOnly(bin, url, state)
		}
		return
	}

	// public (Funnel)
	if (state.proxyOk && state.funnelOn) {
		console.info(`✓ tailscale funnel already exposes ${url} → 127.0.0.1:${RELAY_PORT} (public, token-gated)`)
		return
	}
	try {
		execFileSync(bin, ['funnel', '--bg', '--yes', RELAY_PORT], { stdio: 'pipe' })
		console.info(`✓ tailscale funnel → ${url} now public over the internet (token-gated) → 127.0.0.1:${RELAY_PORT}`)
	} catch (err) {
		console.info(`\n  ⚠ could not enable Funnel (${err instanceof Error ? err.message.trim() : err}).`)
		console.info('    Funnel must be enabled for this tailnet: open the URL Tailscale printed above, or add the')
		console.info('    "funnel" nodeAttr in Admin console ▸ Access controls. Falling back to tailnet-only for now.')
		ensureServeOnly(bin, url, state)
	}
}

/** Print a scannable QR of `url` (theme-independent black-on-white). Never fatal — QR is a convenience. */
function printQr(url: string): void {
	try {
		console.info(`\n${qrLines(url).join('\n')}`)
	} catch (err) {
		console.info(`  (QR skipped: ${err instanceof Error ? err.message : err})`)
	}
}

function printUrl(): void {
	const token = currentToken()
	const frag = `#token=${token ?? '<starts on first run>'}`
	const bin = tailscaleBin()
	if (bin) {
		const drift = driftWarningLines(bin)
		if (drift.length) console.info(`\n${drift.join('\n')}`)
	}
	const dns = bin ? magicDnsName(bin) : null
	const state = bin ? tailscaleState(bin, dns) : { proxyOk: false, funnelOn: false }
	if (dns && state.proxyOk) {
		const scope = state.funnelOn ? 'public — any browser, token-gated' : 'same Tailnet only'
		const url = `https://${dns}/${frag}`
		console.info(`\n  Phone URL (HTTPS, ${scope}):\n    ${url}`)
		if (token) {
			console.info('\n  Scan to open on your phone:')
			printQr(url)
		}
		return
	}
	// Nothing fronting yet — the relay is only on loopback.
	console.info(`\n  Local URL:\n    http://127.0.0.1:${RELAY_PORT}/${frag}`)
	console.info(
		`\n  ⚠ Not reachable from your phone yet. Run \`tailscale funnel --bg ${RELAY_PORT}\` (public) or \`tailscale serve --bg ${RELAY_PORT}\` (tailnet)${dns ? ` → https://${dns}/` : ''}, then \`yarn service status\`.`
	)
}

/** npx unpacks into a throwaway cache that gets purged; a LaunchAgent baked against it would rot. */
function isEphemeralInstall(dir: string): boolean {
	return /[\\/]_npx[\\/]|[\\/]\.npm[\\/]_npx[\\/]/.test(dir)
}

function install(): void {
	if (isEphemeralInstall(projectDir)) {
		console.error(
			`✗ refusing to install from an npx cache path:\n    ${projectDir}\n` +
				'  That directory is temporary and gets purged, which would break the LaunchAgent.\n' +
				'  Install globally first: `npm i -g conductor-remote`, then `conductor-remote service install`.'
		)
		process.exit(1)
	}
	if (!distBuilt()) {
		console.error('✗ dist/ not built. Run `yarn build` first (or use `yarn deploy`, which builds).')
		process.exit(1)
	}
	persistPinnedToken()
	fs.mkdirSync(path.dirname(plistPath), { recursive: true })
	fs.mkdirSync(logDir, { recursive: true })
	fs.writeFileSync(plistPath, buildPlist())
	reloadAgent()
	console.info(`✓ installed LaunchAgent ${LABEL}`)
	console.info(`  plist: ${plistPath}`)
	console.info(`  logs:  ${logDir}/relay.log`)
	console.info(`  node:  ${process.execPath}`)
	ensureTailscale()
	printUrl()
	console.info(
		'\n  Note: a node version change (nvm) invalidates the baked path — re-run `yarn deploy` after upgrading node.'
	)
	console.info(
		'  Note: the AppleScript write path needs Accessibility permission granted to this node binary (System Settings ▸ Privacy).'
	)
}

function uninstall(): void {
	launchctl('bootout', `${domain}/${LABEL}`)
	try {
		fs.rmSync(plistPath)
	} catch {
		// already gone
	}
	console.info(`✓ removed LaunchAgent ${LABEL}`)
}

function restart(): void {
	launchctl('kickstart', '-k', `${domain}/${LABEL}`)
	console.info(`✓ restarted ${LABEL}`)
	printUrl()
}

function status(): void {
	const installed = fs.existsSync(plistPath)
	console.info(`plist:     ${installed ? plistPath : '(not installed)'}`)
	if (!installed) return
	try {
		const out = execFileSync('launchctl', ['print', `${domain}/${LABEL}`], { encoding: 'utf8', stdio: 'pipe' })
		const state = out.match(/state = (\S+)/)?.[1] ?? 'unknown'
		const pid = out.match(/pid = (\d+)/)?.[1] ?? '—'
		console.info(`state:     ${state}  (pid ${pid})`)
	} catch {
		console.info('state:     loaded but not running (check logs)')
	}
	printUrl()
}

/**
 * Stream the LaunchAgent's stdout+stderr logs (the same files the plist points at). Follows both by default
 * — `--no-follow` for a one-shot tail, `-n N` for depth. Pure `tail` passthrough so Ctrl-C just detaches.
 */
function logs(): void {
	const files = ['relay.log', 'relay.err.log'].map(f => path.join(logDir, f)).filter(f => fs.existsSync(f))
	if (files.length === 0) {
		console.info(
			`no logs yet in ${logDir}/ — the relay writes there once the LaunchAgent is running (\`conductor-remote service install\`).`
		)
		return
	}
	const argv = process.argv.slice(3)
	const follow = !argv.includes('--no-follow')
	const nAt = argv.indexOf('-n')
	const count = nAt !== -1 && argv[nAt + 1] ? argv[nAt + 1] : '200'
	const args = ['-n', count, ...(follow ? ['-F'] : []), ...files]
	const res = spawnSync('tail', args, { stdio: 'inherit' })
	// tail exits 0 normally; Ctrl-C kills it via SIGINT (null status). Only surface a genuine non-zero exit.
	if (typeof res.status === 'number' && res.status !== 0) process.exit(res.status)
}

const cmd = process.argv[2] ?? 'status'
switch (cmd) {
	case 'install':
		install()
		break
	case 'uninstall':
		uninstall()
		break
	case 'restart':
		restart()
		break
	case 'status':
		status()
		break
	case 'logs':
		logs()
		break
	default:
		console.error(
			`unknown command: ${cmd}\n` +
				'usage: service.ts <install|uninstall|restart|status|logs> [flags]\n' +
				`  flags (install): ${Object.keys(FLAG_ENV).join(', ')}`
		)
		process.exit(1)
}
