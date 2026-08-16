import { type SpawnSyncReturns, spawn, spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createInterface } from 'node:readline/promises'

// Build, sign, and install the native iOS app (ios/) on a physical iPhone:
//   yarn ios:deploy [--device <name|udid>] [--team <ID>] [--release] [--no-launch] [--list-devices]
//
// Free-account signing expires every 7 days; the fix is rerunning this command,
// so every step here is idempotent. The team ID persists in the gitignored
// ios/Signing.local.xcconfig (wired via project.yml configFiles); first run
// resolves it from the keychain, Xcode's account cache, or a prompt.
// One-time phone setup (Apple ID in Xcode, Trust, Developer Mode) is in
// ios/README.md ▸ "Deploy to your phone".

const repoRoot = join(import.meta.dirname, '..')
const iosDir = join(repoRoot, 'ios')
const xcconfigPath = join(iosDir, 'Signing.local.xcconfig')
const projectPath = join(iosDir, 'ConductorRemote.xcodeproj')
const bundleId = 'com.biggart.ConductorRemote'
const TEAM_ID = /^[A-Z0-9]{10}$/

function fail(msg: string): never {
	console.error(`\nios-deploy: ${msg}`)
	process.exit(1)
}

function run(cmd: string, args: string[]): SpawnSyncReturns<string> {
	return spawnSync(cmd, args, { encoding: 'utf8' })
}

// ---- CLI ----

const argv = process.argv.slice(2)
function flagValue(name: string): string | undefined {
	const i = argv.indexOf(name)
	if (i < 0) return undefined
	const v = argv[i + 1]
	if (!v || v.startsWith('--')) fail(`${name} needs a value`)
	return v
}
const deviceArg = flagValue('--device')
const teamArg = flagValue('--team')
if (teamArg && !TEAM_ID.test(teamArg)) fail(`--team "${teamArg}" is not a 10-character Team ID (A–Z, 0–9)`)
const release = argv.includes('--release')
const noLaunch = argv.includes('--no-launch')
const listOnly = argv.includes('--list-devices')

// ---- Preflight ----

if (process.platform !== 'darwin') fail('device deploys need macOS with Xcode')

const devDir = run('xcode-select', ['-p']).stdout?.trim() ?? ''
if (!devDir.endsWith('.app/Contents/Developer'))
	fail(
		`xcode-select points at "${devDir}" — device builds need full Xcode:\n  sudo xcode-select -s /Applications/Xcode.app`
	)

if (run('xcodegen', ['--version']).error) fail('xcodegen not found — brew install xcodegen')
if (run('xcrun', ['devicectl', '--version']).status !== 0)
	fail('`xcrun devicectl` unavailable — this Xcode is too old for device installs (needs Xcode 15+)')

// ---- Resolve DEVELOPMENT_TEAM ----
// Order: flag → env → persisted xcconfig → keychain cert OU → Xcode account
// cache → prompt. First valid 10-char ID wins and is persisted, so after the
// first run only the xcconfig read happens.

function teamFromXcconfig(): string | undefined {
	if (!existsSync(xcconfigPath)) return undefined
	return readFileSync(xcconfigPath, 'utf8').match(/^\s*DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]{10})\s*$/m)?.[1]
}

function teamFromKeychain(): string | undefined {
	const ids = run('security', ['find-identity', '-v', '-p', 'codesigning']).stdout ?? ''
	if (!ids.includes('Apple Development')) return undefined
	const pem = run('security', ['find-certificate', '-c', 'Apple Development', '-p'])
	if (pem.status !== 0) return undefined
	const subject = spawnSync('openssl', ['x509', '-noout', '-subject'], { input: pem.stdout, encoding: 'utf8' })
	return subject.stdout?.match(/OU\s*=\s*([A-Z0-9]{10})/)?.[1]
}

/** Teams of the Apple IDs added in Xcode ▸ Settings ▸ Accounts — works before any cert exists. */
function teamsFromXcodeDefaults(): string[] {
	// On some Xcode versions this key is archived data the regex can't see — any
	// miss just falls through to the prompt.
	const out = run('defaults', ['read', 'com.apple.dt.Xcode', 'IDEProvisioningTeams']).stdout ?? ''
	return [...new Set([...out.matchAll(/teamID\s*=\s*"?([A-Z0-9]{10})"?/g)].map(m => m[1]))]
}

async function promptForTeam(candidates: string[]): Promise<string> {
	const help =
		candidates.length > 1
			? `Xcode knows several teams: ${candidates.join(', ')}\nPaste the one to use`
			: 'No development team found on this Mac.\n' +
				'Either open Xcode → Settings → Accounts → "+" → sign in with your Apple ID\n' +
				'(a free account is fine) and rerun, or paste your 10-character Team ID\n' +
				'(developer.apple.com/account ▸ Membership details)'
	if (!process.stdin.isTTY) fail(`${help}\n(or pass --team <ID>)`)
	const rl = createInterface({ input: process.stdin, output: process.stdout })
	const answer = (await rl.question(`${help}: `)).trim()
	rl.close()
	if (!TEAM_ID.test(answer)) fail(`"${answer}" is not a 10-character Team ID`)
	return answer
}

async function resolveTeam(): Promise<string> {
	for (const [source, value] of [
		['--team', teamArg],
		['CONDUCTOR_DEV_TEAM', process.env.CONDUCTOR_DEV_TEAM],
		['ios/Signing.local.xcconfig', teamFromXcconfig()],
		['keychain certificate', teamFromKeychain()]
	] as const) {
		if (value === undefined) continue
		if (!TEAM_ID.test(value)) fail(`team from ${source} ("${value}") is not a 10-character Team ID`)
		return value
	}
	const cached = teamsFromXcodeDefaults()
	if (cached.length === 1) return cached[0]
	return promptForTeam(cached)
}

// ---- Device discovery ----

type Device = {
	name: string
	udid: string // hardware UDID — what xcodebuild destinations want
	identifier: string // CoreDevice UUID — what devicectl commands want
	os: string
	transport: string
	connected: boolean
	developerMode: string
}

/** The slice of devicectl's JSON we read (CoreDevice 506.x). */
type RawDevice = {
	identifier?: string
	hardwareProperties?: { udid?: string; platform?: string }
	connectionProperties?: { tunnelState?: string; transportType?: string }
	deviceProperties?: { name?: string; osVersionNumber?: string; developerModeStatus?: string }
}

/** devicectl only emits machine-readable output to a file, not stdout. */
function listDevices(): Device[] {
	const tmp = mkdtempSync(join(tmpdir(), 'ios-deploy-'))
	const jsonPath = join(tmp, 'devices.json')
	try {
		const res = run('xcrun', ['devicectl', 'list', 'devices', '--json-output', jsonPath])
		if (res.status !== 0) fail(`devicectl list devices failed:\n${res.stderr}`)
		const parsed = JSON.parse(readFileSync(jsonPath, 'utf8'))
		const raw: RawDevice[] = parsed?.result?.devices ?? []
		return raw
			.filter(d => (d?.hardwareProperties?.platform ?? 'iOS') === 'iOS')
			.map(d => ({
				name: d?.deviceProperties?.name ?? '(unnamed)',
				udid: d?.hardwareProperties?.udid ?? '',
				identifier: d?.identifier ?? '',
				os: d?.deviceProperties?.osVersionNumber ?? '?',
				transport: d?.connectionProperties?.transportType ?? '?',
				connected: d?.connectionProperties?.tunnelState === 'connected',
				developerMode: d?.deviceProperties?.developerModeStatus ?? 'unknown'
			}))
	} finally {
		rmSync(tmp, { recursive: true, force: true })
	}
}

function describe(d: Device): string {
	const link = d.connected ? (d.transport === 'wired' ? 'cable' : 'Wi-Fi') : 'not reachable'
	return `${d.name} — iOS ${d.os}, ${link} (udid ${d.udid || '?'})`
}

const devices = listDevices()

if (listOnly) {
	if (!devices.length) console.log('No iPhones known to this Mac. Plug one in with a cable and tap Trust.')
	for (const d of devices) console.log(`  ${describe(d)}`)
	process.exit(devices.some(d => d.connected) ? 0 : 1)
}

function pickDevice(): Device {
	if (deviceArg) {
		const q = deviceArg.toLowerCase()
		const hits = devices.filter(
			d => d.udid.toLowerCase() === q || d.identifier.toLowerCase() === q || d.name.toLowerCase().includes(q)
		)
		if (hits.length !== 1)
			fail(
				`--device "${deviceArg}" matched ${hits.length} devices:\n${(hits.length ? hits : devices).map(d => `  ${describe(d)}`).join('\n')}`
			)
		if (!hits[0].connected) fail(`${describe(hits[0])} — plug in the cable and unlock it`)
		return hits[0]
	}
	const connected = devices.filter(d => d.connected)
	if (connected.length === 1) return connected[0]
	if (connected.length > 1) {
		const wired = connected.filter(d => d.transport === 'wired')
		if (wired.length === 1) return wired[0]
		fail(
			`several iPhones are connected — pick one with --device:\n${connected.map(d => `  ${describe(d)}`).join('\n')}`
		)
	}
	if (devices.length)
		fail(
			`iPhone is paired but not reachable — plug in the cable, unlock it, and if\n` +
				`using Wi-Fi make sure both are on the same network. Known devices:\n${devices.map(d => `  ${describe(d)}`).join('\n')}`
		)
	fail(
		'no iPhone found. First time: connect it with a cable, unlock it, and tap\n' +
			'"Trust This Computer" on the phone — then rerun. (`yarn ios:deploy --list-devices` to check.)'
	)
}

const device = pickDevice()
if (device.developerMode !== 'enabled' && device.developerMode !== 'unknown')
	fail(
		`${device.name}: Developer Mode is ${device.developerMode}. On the phone:\n` +
			'  Settings → Privacy & Security → Developer Mode → on (the phone reboots), then rerun.'
	)
if (device.transport !== 'wired') console.log('Note: Wi-Fi installs are slow and flaky — a cable is more reliable.')
console.log(`Deploying to ${describe(device)}`)

// ---- Resolve and persist the signing team ----

const team = await resolveTeam()
writeFileSync(
	xcconfigPath,
	'// Personal code-signing settings — gitignored, managed by `yarn ios:deploy`.\n' +
		`DEVELOPMENT_TEAM = ${team}\n` +
		'CODE_SIGN_STYLE = Automatic\n'
)
console.log(`Signing team ${team} (ios/Signing.local.xcconfig)`)

// ---- Generate the project (always — ~1s, kills stale-pbxproj bugs) ----

if (spawnSync('xcodegen', ['generate'], { cwd: iosDir, stdio: 'inherit' }).status !== 0)
	fail('xcodegen generate failed')

// ---- Error mapping (ordered; first match wins) ----

const errorMap: Array<[RegExp, string]> = [
	[
		/no account for team|add a new account/i,
		'Xcode → Settings → Accounts → "+" → sign in with your Apple ID, then rerun.'
	],
	[
		/no signing certificate|no valid.*identit/i,
		'Rerun — Xcode mints the certificate on the next build. If a macOS keychain\ndialog appears, enter your login password and click "Always Allow".'
	],
	[
		/errSecInternalComponent|user interaction is not allowed/i,
		'The keychain is locked or there is no GUI session (SSH?) — run from a local\nterminal, or `security unlock-keychain login.keychain-db`.'
	],
	[
		/failed to register bundle identifier|bundle identifier.*not available/i,
		'Free accounts get ~10 new app IDs per 7 days, and the ID may be taken —\nwait a few days, or change bundleIdPrefix in ios/project.yml.'
	],
	[
		/maximum number of registered devices/i,
		'Free-account device cap reached — remove a device at developer.apple.com\nor wait for the yearly reset.'
	],
	[/developer mode/i, 'Phone: Settings → Privacy & Security → Developer Mode → on (the phone\nreboots), then rerun.'],
	[/device is locked|passcode.*protected/i, 'Unlock the iPhone and keep it unlocked during the install, then rerun.'],
	[
		/ApplicationVerificationFailed|0xe8008015|no matching provisioning profile/i,
		'The provisioning profile is stale (free signing lasts 7 days) — rerun; if it\npersists, delete the app from the phone first.'
	],
	[
		/untrusted developer|invalid code signature|NotTrusted/i,
		'Phone: Settings → General → VPN & Device Management → your Apple ID →\nTrust, then launch the app by hand.'
	],
	[
		/tunnel.*unavailable|transport error|connection.*(interrupted|lost)/i,
		'The Wi-Fi connection dropped — plug in the cable and rerun.'
	]
]

function explainFailure(step: string, output: string): never {
	for (const [re, fix] of errorMap) if (re.test(output)) fail(`${step} failed.\n${fix}`)
	fail(
		`${step} failed — full output above. If the cause isn't obvious, open\n` +
			'ios/ConductorRemote.xcodeproj in Xcode once: its Signing pane surfaces\naccount problems interactively.'
	)
}

/** Stream a command's output live while keeping a tail for the error mapper. */
function runStreaming(step: string, cmd: string, args: string[]): Promise<void> {
	return new Promise(resolve => {
		const child = spawn(cmd, args, { stdio: ['inherit', 'pipe', 'pipe'] })
		let tail = ''
		const pipe = (stream: NodeJS.ReadableStream, out: NodeJS.WriteStream) => {
			stream.on('data', (d: Buffer) => {
				out.write(d)
				tail = (tail + d.toString()).slice(-20000)
			})
		}
		pipe(child.stdout as NodeJS.ReadableStream, process.stdout)
		pipe(child.stderr as NodeJS.ReadableStream, process.stderr)
		child.on('exit', code => {
			if (code !== 0) explainFailure(step, tail)
			resolve()
		})
	})
}

// ---- Build ----

const config = release ? 'Release' : 'Debug'
const derivedData = join(iosDir, 'build', 'DerivedData')
console.log(`\nBuilding ${config}…`)
await runStreaming('Build', 'xcodebuild', [
	'-project',
	projectPath,
	'-scheme',
	'ConductorRemote',
	'-configuration',
	config,
	'-destination',
	// Concrete device, not generic/platform=iOS: -allowProvisioningDeviceRegistration
	// registers the destination device, which needs an id.
	`platform=iOS,id=${device.udid}`,
	'-derivedDataPath',
	derivedData,
	'-allowProvisioningUpdates',
	'-allowProvisioningDeviceRegistration',
	// Belt-and-braces on top of the xcconfig: a CLI override outranks any stale
	// pbxproj. (No CODE_SIGN_STYLE/identity overrides — those break SwiftPM
	// package signing.)
	`DEVELOPMENT_TEAM=${team}`,
	'build'
])

const appPath = join(derivedData, 'Build', 'Products', `${config}-iphoneos`, 'ConductorRemote.app')
if (!existsSync(appPath)) fail(`build reported success but ${appPath} does not exist`)

// ---- Install + launch ----

console.log(`\nInstalling on ${device.name}…`)
await runStreaming('Install', 'xcrun', [
	'devicectl',
	'device',
	'install',
	'app',
	'--device',
	device.identifier,
	appPath
])

if (!noLaunch) {
	console.log('\nLaunching…')
	await runStreaming('Launch', 'xcrun', [
		'devicectl',
		'device',
		'process',
		'launch',
		'--terminate-existing',
		'--device',
		device.identifier,
		bundleId
	])
}

console.log(
	`\nDone — Conductor is on ${device.name}.\n` +
		'First install? Two one-time steps on the phone:\n' +
		'  · Settings → General → VPN & Device Management → your Apple ID → Trust\n' +
		'  · Pair with the relay: `yarn service status` prints the URL — scan its QR\n' +
		'    in-app or paste the https://…#token=… link.\n' +
		'Free signing expires in 7 days; rerun `yarn ios:deploy` to refresh (pairing survives).'
)
