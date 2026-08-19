/**
 * Supervised probe for the sidecar tunnel-recovery question — run it YOURSELF,
 * WATCHING Conductor, never from automation:
 *
 *   node scripts/sidecar-probe.ts [--hold <seconds>] [--status <sessionId>]
 *
 * What this decides: Conductor's sidecar socket is single-client — every new
 * connection displaces the desktop app's own event tunnel, and when that
 * connection closes the slot is left empty rather than restored (re-derived from
 * conductor-runtime 0.81; see src/sidecar.ts). Session events then pile into a
 * persisted outbox until something reattaches. What nobody has measured is how
 * fast the app recovers: instantly (it reconnects on its next request), slowly
 * (next poll/health tick), or not until restart. That answer gates
 * SIDECAR_WHEN_LOCKED (src/server.ts) — behind-the-lock sidecar delivery is only
 * defensible if recovery is automatic.
 *
 * Protocol:
 *   1. Start an agent doing something long in Conductor so output is visibly
 *      streaming.
 *   2. Run this script. It connects to the sidecar socket, holds the connection
 *      (default 10s), and disconnects — twice, with a short connect in between.
 *   3. Watch the streaming transcript on the Mac the whole time. Note whether it
 *      stalls while this script is connected, and how long after each disconnect
 *      it takes to resume. Resumes within a few seconds unaided, both times →
 *      recovery is automatic and the locked-Mac experiment can proceed. Stalls
 *      until you click around or restart Conductor → do not enable
 *      SIDECAR_WHEN_LOCKED; the app holds one persistent connection and never
 *      re-registers.
 *
 * `--status <sessionId>` additionally sends one getSessionStatus RPC (a read;
 * no turn is triggered) while connected, to confirm the protocol still parses on
 * this Conductor build. Even without it, the bare connection IS the experiment —
 * connecting is the disruptive act, which is why the relay never probes this
 * socket on its own.
 */
import net from 'node:net'
import { sidecarSessionStatus, sidecarSocket } from '../src/sidecar.ts'

const sleep = (ms: number): Promise<void> => new Promise(resolve => setTimeout(resolve, ms))

function arg(name: string): string | undefined {
	const i = process.argv.indexOf(name)
	return i >= 0 ? process.argv[i + 1] : undefined
}

const holdSeconds = Number(arg('--hold') ?? 10)
const statusSessionId = arg('--status')

async function holdConnection(socketPath: string, seconds: number): Promise<void> {
	await new Promise<void>((resolve, reject) => {
		const sock = net.connect(socketPath)
		sock.on('connect', async () => {
			console.log(`  connected — the app's event tunnel now points at this script (${seconds}s hold)`)
			for (let remaining = seconds; remaining > 0; remaining--) {
				process.stdout.write(`\r  …${remaining}s — is the Mac's transcript still streaming?  `)
				await sleep(1000)
			}
			process.stdout.write('\n')
			sock.destroy()
			console.log('  disconnected — the tunnel slot is now empty until the app reattaches')
			resolve()
		})
		sock.on('error', reject)
	})
}

const socketPath = await sidecarSocket()
if (!socketPath) {
	console.error('No sidecar socket answered — is Conductor running?')
	process.exit(1)
}
console.log(`Sidecar socket: ${socketPath}`)
console.log('Watch a streaming agent in Conductor on the Mac for this whole run.\n')

console.log('Round 1 — long hold:')
await holdConnection(socketPath, holdSeconds)
console.log('  ➜ note how many seconds until the Mac transcript resumes on its own\n')
await sleep(8000)

if (statusSessionId) {
	console.log(`getSessionStatus(${statusSessionId}):`)
	try {
		console.log(' ', JSON.stringify(await sidecarSessionStatus(statusSessionId)))
	} catch (err) {
		console.log(`  RPC failed: ${err instanceof Error ? err.message : err}`)
	}
	console.log('  (that RPC was itself a connect/disconnect — watch for the same stall/recover)\n')
	await sleep(8000)
}

console.log('Round 2 — brief connect (the availability-probe shape):')
await holdConnection(socketPath, 2)
console.log('  ➜ same question: does streaming resume unaided, and how fast?\n')

console.log('Verdict is yours: both resumes automatic and quick → the locked-Mac sidecar')
console.log('experiment can proceed (SIDECAR_WHEN_LOCKED=1 on the relay). Any stall that')
console.log('needed your help → leave it off and rely on the parked queue as today.')
