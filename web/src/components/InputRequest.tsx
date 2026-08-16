import { AlertTriangle, CircleHelp, ClipboardCheck, Loader2 } from 'lucide-react'
import { useState } from 'react'
import { client } from '../lib/api.ts'
import { cn } from '../lib/cn.ts'
import type { PendingInput } from '../lib/types.ts'
import { Markdown } from './Markdown.tsx'

/**
 * The agent stopped and is waiting on the user: a question with options, or a
 * completed plan to approve. Rendered as a sibling of the entry list (never
 * inside the step-group fold) while `useTranscript`'s `pending` is non-null —
 * the card clears through that same poll once the answer lands, whether it was
 * given here or on the Mac.
 *
 * A tap POSTs and then *waits for the poll*: on ok (or `already`, the idempotent
 * retry answer) nothing changes locally, because the receipt row arriving in the
 * transcript is what removes the card. Errors show in words with the button
 * usable again — the relay validated before pressing, so a retry can't
 * double-answer.
 */
export function InputRequest({
	pending,
	sessionId,
	workspaceId
}: {
	pending: PendingInput
	sessionId: string
	workspaceId: string
}) {
	const [busy, setBusy] = useState(false)
	const [error, setError] = useState<string | null>(null)

	const submit = async (body: { options?: string[]; approve?: boolean }) => {
		setBusy(true)
		setError(null)
		try {
			await client.answer(sessionId, { workspaceId, toolUseId: pending.toolUseId, kind: pending.kind, ...body })
			// Stay busy: the 1s transcript poll clears the card when the receipt lands.
		} catch (err) {
			setBusy(false)
			setError(err instanceof Error ? err.message : String(err))
		}
	}

	return (
		<div className="fade-in overflow-hidden rounded-2xl border border-accent/40 bg-surface">
			{pending.kind === 'plan' ? (
				<PlanBody pending={pending} busy={busy} onApprove={() => submit({ approve: true })} />
			) : (
				<QuestionBody pending={pending} busy={busy} onPick={label => submit({ options: [label] })} />
			)}
			{error ? (
				<div className="flex items-center gap-2 border-t border-border-soft px-3.5 py-2 text-[11.5px] text-del">
					<AlertTriangle size={12} className="shrink-0" />
					<span className="min-w-0 flex-1">{error}</span>
				</div>
			) : null}
		</div>
	)
}

function Header({ icon, children }: { icon: React.ReactNode; children: string }) {
	return (
		<div className="flex items-center gap-1.5 px-3.5 pt-3 text-[11px] font-semibold uppercase tracking-wide text-accent">
			{icon}
			{children}
		</div>
	)
}

function QuestionBody({
	pending,
	busy,
	onPick
}: {
	pending: PendingInput
	busy: boolean
	onPick: (label: string) => void
}) {
	const questions = pending.questions ?? []
	// v1 answers single-choice, single-question cards only; anything richer is
	// shown read-only rather than half-answered (the relay refuses those too).
	const answerable = questions.length === 1 && !questions[0].multiSelect
	return (
		<div className="flex flex-col gap-2 pb-3">
			<Header icon={<CircleHelp size={12} />}>Waiting for your answer</Header>
			{questions.map(q => (
				<div key={q.question} className="flex flex-col gap-2 px-3.5">
					{q.header ? <div className="text-[11px] font-medium text-faint">{q.header}</div> : null}
					<div className="text-[14px] leading-relaxed">{q.question}</div>
					<div className="flex flex-col gap-1.5">
						{q.options.map(o => (
							<button
								key={o.label}
								type="button"
								disabled={busy || !answerable}
								onClick={() => onPick(o.label)}
								className={cn(
									'rounded-xl border border-border px-3 py-2 text-left text-[13.5px] transition',
									answerable && 'active:scale-[0.985] active:bg-surface-2',
									busy && 'opacity-50'
								)}
							>
								{o.label}
								{o.description ? <div className="mt-0.5 text-[12px] text-muted">{o.description}</div> : null}
							</button>
						))}
					</div>
				</div>
			))}
			<Footer busy={busy}>
				{answerable ? 'Or reply from the composer below.' : 'Answer this one in Conductor on your Mac.'}
			</Footer>
		</div>
	)
}

function PlanBody({ pending, busy, onApprove }: { pending: PendingInput; busy: boolean; onApprove: () => void }) {
	const [expanded, setExpanded] = useState(false)
	return (
		<div className="flex flex-col gap-2 pb-3">
			<Header icon={<ClipboardCheck size={12} />}>Plan ready for review</Header>
			<div
				className={cn('relative min-w-0 px-3.5 text-[13.5px] leading-relaxed', !expanded && 'max-h-64 overflow-hidden')}
			>
				<Markdown>{pending.plan ?? ''}</Markdown>
				{!expanded ? (
					<div className="absolute inset-x-0 bottom-0 h-14 bg-gradient-to-t from-surface to-transparent" />
				) : null}
			</div>
			<button
				type="button"
				onClick={() => setExpanded(e => !e)}
				className="self-start px-3.5 text-[12px] font-medium text-accent underline underline-offset-2"
			>
				{expanded ? 'Collapse' : 'Show all'}
			</button>
			<div className="px-3.5">
				<button
					type="button"
					disabled={busy}
					onClick={onApprove}
					className={cn(
						'w-full rounded-xl bg-accent px-3 py-2.5 text-center text-[14px] font-semibold text-bg transition active:scale-[0.985]',
						busy && 'opacity-50'
					)}
				>
					Approve plan
				</button>
			</div>
			<Footer busy={busy}>To keep planning, reply from the composer below.</Footer>
		</div>
	)
}

function Footer({ busy, children }: { busy: boolean; children: string }) {
	return busy ? (
		<span className="flex items-center gap-1.5 px-3.5 text-[11.5px] text-faint">
			<Loader2 size={11} className="animate-spin" />
			Answering…
		</span>
	) : (
		<span className="px-3.5 text-[11.5px] text-faint">{children}</span>
	)
}
