import type {
    StoredMessage,
    CompressionConfig,
    CompressedContext,
    BuildContextInput,
    MessageFetcher,
    GatewayCaller,
} from './types'
import { DEFAULT_COMPRESSION_CONFIG } from './types'
import { SummaryCache } from './summary-cache'
import { GatewaySummarizer } from './gateway-client'
import { buildAgentInstructions, buildSummarizationSystemPrompt } from './prompt'

export class ContextEngine {
    private config: CompressionConfig
    private messageFetcher: MessageFetcher
    private gatewayCaller: GatewayCaller
    private cache: SummaryCache

    constructor(opts: {
        config?: Partial<CompressionConfig>
        messageFetcher: MessageFetcher
        gatewayCaller?: GatewayCaller
    }) {
        this.config = { ...DEFAULT_COMPRESSION_CONFIG, ...opts.config }
        this.messageFetcher = opts.messageFetcher
        this.gatewayCaller = opts.gatewayCaller || new GatewaySummarizer(this.config.summarizationTimeoutMs)
        this.cache = new SummaryCache(this.config.summaryTtlMs)
    }

    async buildContext(input: BuildContextInput): Promise<CompressedContext> {
        const allMessages = this.messageFetcher.getMessages(input.roomId)

        // Filter out messages newer than the current one
        const messages = allMessages.filter(m => m.timestamp <= input.currentMessage.timestamp)
        const total = messages.length
        const totalTokens = this.estimateTokensFromMessages(messages)

        const meta: CompressedContext['meta'] = {
            totalMessages: total,
            summarizedCount: 0,
            verbatimHeadCount: 0,
            verbatimTailCount: 0,
            summaryTokenEstimate: 0,
            cacheHit: false,
        }

        const instructions = buildAgentInstructions({
            agentName: input.agentName,
            roomName: input.roomName,
            agentDescription: input.agentDescription,
            memberNames: input.memberNames,
        })

        const { triggerTokens, headMessageCount, tailMessageCount } = this.config

        // Under token threshold — pass all messages verbatim
        if (totalTokens <= triggerTokens) {
            const history = messages.map(m => this.mapToHistory(m, input.agentSocketId))
            return { conversationHistory: history, instructions, meta }
        }

        // Over threshold — three-zone split
        const head = messages.slice(0, headMessageCount)
        const tail = messages.slice(-tailMessageCount)
        const middle = messages.slice(headMessageCount, -tailMessageCount)

        meta.verbatimHeadCount = head.length
        meta.verbatimTailCount = tail.length
        meta.summarizedCount = middle.length

        console.log(`[ContextEngine] ${input.agentName}: ${total} msgs, ~${totalTokens} tokens > ${triggerTokens}, compressing ${middle.length} middle msgs`)

        // Attempt summarization
        let summaryContent: string | null = null

        try {
            summaryContent = await this.summarizeMiddle(
                input.roomId,
                middle,
                input.upstream,
                input.apiKey,
            )
        } catch (err: any) {
            console.warn(`[ContextEngine] Summarization failed for ${input.agentName} in ${input.roomId}: ${err.message}`)
            // Degrade: skip middle, keep head + tail only
        }

        // Assemble history
        const history: Array<{ role: 'user' | 'assistant'; content: string }> = []

        if (summaryContent) {
            history.push(
                { role: 'user', content: '[Previous conversation summary for context]\n' + summaryContent },
                { role: 'assistant', content: 'I have reviewed the conversation history and understand the context.' },
            )
            meta.summaryTokenEstimate = Math.ceil(summaryContent.length / this.config.charsPerToken)
        }

        history.push(...head.map(m => this.mapToHistory(m, input.agentSocketId)))
        history.push(...tail.map(m => this.mapToHistory(m, input.agentSocketId)))

        // Token budget trimming
        this.trimToBudget(history, meta.summaryTokenEstimate)

        return { conversationHistory: history, instructions, meta }
    }

    invalidateRoom(roomId: string): void {
        this.cache.invalidate(roomId)
    }

    // ─── Private ─────────────────────────────────────────────

    private async summarizeMiddle(
        roomId: string,
        middle: StoredMessage[],
        upstream: string,
        apiKey: string | null,
    ): Promise<string | null> {
        const cached = this.cache.get(roomId)

        if (cached) {
            // Check if there are new messages since last summary
            const newMessages = middle.filter(m => m.timestamp > cached.lastSummarizedTimestamp)
            if (newMessages.length === 0) {
                // Cache hit, no new messages
                return cached.summaryContent
            }

            // Incremental update with new messages only
            const summary = await this.gatewayCaller.summarize(
                upstream,
                apiKey,
                buildSummarizationSystemPrompt(),
                newMessages,
                cached.summaryContent,
            )

            this.cache.set(roomId, {
                summaryContent: summary,
                lastSummarizedTimestamp: newMessages[newMessages.length - 1].timestamp,
                createdAt: Date.now(),
                messageCountAtCreation: middle.length,
            })

            return summary
        }

        // Cache miss — full summarization
        const summary = await this.gatewayCaller.summarize(
            upstream,
            apiKey,
            buildSummarizationSystemPrompt(),
            middle,
        )

        this.cache.set(roomId, {
            summaryContent: summary,
            lastSummarizedTimestamp: middle[middle.length - 1].timestamp,
            createdAt: Date.now(),
            messageCountAtCreation: middle.length,
        })

        return summary
    }

    private mapToHistory(
        msg: StoredMessage,
        agentSocketId: string,
    ): { role: 'user' | 'assistant'; content: string } {
        if (msg.senderId === agentSocketId) {
            return { role: 'assistant', content: msg.content }
        }
        return { role: 'user', content: `[${msg.senderName}]: ${msg.content}` }
    }

    private trimToBudget(
        history: Array<{ role: 'user' | 'assistant'; content: string }>,
        summaryTokens: number,
    ): void {
        let totalTokens = summaryTokens + this.estimateTokens(history)
        // Trim from the end (tail messages) while preserving head + summary
        while (totalTokens > this.config.maxHistoryTokens && history.length > 0) {
            history.pop()
            totalTokens = summaryTokens + this.estimateTokens(history)
        }
    }

    private estimateTokens(history: Array<{ role: string; content: string }>): number {
        const text = history.map(m => m.content).join('')
        return this.countTokens(text)
    }

    private estimateTokensFromMessages(messages: StoredMessage[]): number {
        const text = messages.map(m => m.content + m.senderName).join('')
        return this.countTokens(text)
    }

    /** Estimate tokens distinguishing CJK (~1.5 tok/char) from Latin (~0.25 tok/char) */
    private countTokens(text: string): number {
        const cjk = (text.match(/[\u2e80-\u9fff\uac00-\ud7af\u3000-\u303f\uff00-\uffef]/g) || []).length
        const other = text.length - cjk
        return Math.ceil(cjk * 1.5 + other / 4)
    }
}
