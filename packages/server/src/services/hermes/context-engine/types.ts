// ─── Message Types ──────────────────────────────────────────

/** Raw message from SQLite messages table */
export interface StoredMessage {
    id: string
    roomId: string
    senderId: string
    senderName: string
    content: string
    timestamp: number
}

// ─── Compression Config ────────────────────────────────────

export interface CompressionConfig {
    /** Token threshold to trigger compression (estimate all messages) */
    triggerTokens: number
    /** Max tokens for the final compressed context sent to LLM */
    maxHistoryTokens: number
    /** Number of recent messages to keep verbatim (tail) */
    tailMessageCount: number
    /** Number of early messages to keep verbatim (head) */
    headMessageCount: number
    /** Characters per token for estimation */
    charsPerToken: number
    /** Cache TTL for summaries in ms */
    summaryTtlMs: number
    /** Timeout for summarization LLM call in ms */
    summarizationTimeoutMs: number
}

export const DEFAULT_COMPRESSION_CONFIG: CompressionConfig = {
    triggerTokens: 100_000,
    maxHistoryTokens: 32_000,
    tailMessageCount: 20,
    headMessageCount: 4,
    charsPerToken: 4,
    summaryTtlMs: 300_000,
    summarizationTimeoutMs: 30_000,
}

// ─── Compression Output ────────────────────────────────────

export interface CompressedContext {
    conversationHistory: Array<{ role: 'user' | 'assistant'; content: string }>
    instructions: string
    meta: {
        totalMessages: number
        summarizedCount: number
        verbatimHeadCount: number
        verbatimTailCount: number
        summaryTokenEstimate: number
        cacheHit: boolean
    }
}

// ─── Summary Cache ─────────────────────────────────────────

export interface SummaryCacheEntry {
    summaryContent: string
    lastSummarizedTimestamp: number
    createdAt: number
    messageCountAtCreation: number
}

// ─── Dependency Injection ──────────────────────────────────

export interface MessageFetcher {
    getMessages(roomId: string, limit?: number): StoredMessage[]
}

export interface GatewayCaller {
    summarize(
        upstream: string,
        apiKey: string | null,
        systemPrompt: string,
        messages: StoredMessage[],
        previousSummary?: string,
    ): Promise<string>
}

// ─── Build Context Input ───────────────────────────────────

export interface BuildContextInput {
    roomId: string
    agentId: string
    agentName: string
    agentDescription: string
    agentSocketId: string
    roomName: string
    memberNames: string[]
    upstream: string
    apiKey: string | null
    currentMessage: StoredMessage
}
