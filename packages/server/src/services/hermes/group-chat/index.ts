import { Server, Socket, Namespace } from 'socket.io'
import type { Server as HttpServer } from 'http'
import { getToken } from '../../../services/auth'
import { getDb, ensureTable } from '../../../db'
import { AgentClients } from './agent-clients'
import { ContextEngine } from '../context-engine'

// ─── Types ────────────────────────────────────────────────────

interface ChatMessage {
    id: string
    roomId: string
    senderId: string
    senderName: string
    content: string
    timestamp: number
}

interface RoomAgent {
    id: string
    roomId: string
    agentId: string
    profile: string
    name: string
    description: string
    invited: number
}

interface Member {
    id: string
    name: string
    joinedAt: number
}

// ─── SQLite Storage (global DB) ──────────────────────────────

const GC_ROOMS_SCHEMA: Record<string, string> = {
    id: 'TEXT PRIMARY KEY',
    name: 'TEXT NOT NULL',
    inviteCode: 'TEXT UNIQUE',
}

const GC_MESSAGES_SCHEMA: Record<string, string> = {
    id: 'TEXT PRIMARY KEY',
    roomId: 'TEXT NOT NULL',
    senderId: 'TEXT NOT NULL',
    senderName: 'TEXT NOT NULL',
    content: 'TEXT NOT NULL',
    timestamp: 'INTEGER NOT NULL',
}

const GC_ROOM_AGENTS_SCHEMA: Record<string, string> = {
    id: 'TEXT PRIMARY KEY',
    roomId: 'TEXT NOT NULL',
    agentId: 'TEXT NOT NULL',
    profile: 'TEXT NOT NULL',
    name: 'TEXT NOT NULL',
    description: "TEXT NOT NULL DEFAULT ''",
    invited: 'INTEGER NOT NULL DEFAULT 0',
}

let _tablesEnsured = false

class ChatStorage {
    private db() { return getDb() }

    init(): void {
        if (_tablesEnsured) return
        const db = this.db()
        if (!db) return
        ensureTable('gc_rooms', GC_ROOMS_SCHEMA)
        ensureTable('gc_messages', GC_MESSAGES_SCHEMA)
        ensureTable('gc_room_agents', GC_ROOM_AGENTS_SCHEMA)
        // Indexes (safe to run multiple times — CREATE INDEX IF NOT EXISTS)
        try { db.exec('CREATE INDEX IF NOT EXISTS idx_gc_messages_room ON gc_messages(roomId, timestamp)') } catch { /* ignore */ }
        try { db.exec('CREATE INDEX IF NOT EXISTS idx_gc_room_agents_room ON gc_room_agents(roomId)') } catch { /* ignore */ }
        _tablesEnsured = true
    }

    // ─── Rooms ────────────────────────────────────────────────

    getRoom(roomId: string): { id: string; name: string; inviteCode: string | null } | undefined {
        return this.db()?.prepare('SELECT id, name, inviteCode FROM gc_rooms WHERE id = ?').get(roomId) as any
    }

    getRoomByInviteCode(code: string): { id: string; name: string; inviteCode: string | null } | undefined {
        return this.db()?.prepare('SELECT id, name, inviteCode FROM gc_rooms WHERE inviteCode = ?').get(code) as any
    }

    getAllRooms(): { id: string; name: string; inviteCode: string | null }[] {
        return (this.db()?.prepare('SELECT id, name, inviteCode FROM gc_rooms ORDER BY id').all() || []) as any[]
    }

    saveRoom(id: string, name: string, inviteCode?: string): void {
        this.db()?.prepare('INSERT OR IGNORE INTO gc_rooms (id, name, inviteCode) VALUES (?, ?, ?)').run(id, name, inviteCode || null)
    }

    updateRoomInviteCode(roomId: string, inviteCode: string): void {
        this.db()?.prepare('UPDATE gc_rooms SET inviteCode = ? WHERE id = ?').run(inviteCode, roomId)
    }

    // ─── Messages ─────────────────────────────────────────────

    getMessages(roomId: string, limit = 500): ChatMessage[] {
        const rows = (this.db()?.prepare(
            'SELECT id, roomId, senderId, senderName, content, timestamp FROM gc_messages WHERE roomId = ? ORDER BY timestamp DESC LIMIT ?'
        ).all(roomId, limit) || []) as any[]
        return rows.reverse()
    }

    addMessage(msg: ChatMessage): void {
        this.db()?.prepare(
            'INSERT INTO gc_messages (id, roomId, senderId, senderName, content, timestamp) VALUES (?, ?, ?, ?, ?, ?)'
        ).run(msg.id, msg.roomId, msg.senderId, msg.senderName, msg.content, msg.timestamp)
    }

    pruneMessages(roomId: string, keep = 500): void {
        const db = this.db()
        if (!db) return
        const count = (db.prepare('SELECT COUNT(*) as c FROM gc_messages WHERE roomId = ?').get(roomId) as any)?.c
        if (count > keep) {
            const cutoff = db.prepare(
                'SELECT timestamp FROM gc_messages WHERE roomId = ? ORDER BY timestamp DESC LIMIT 1 OFFSET ?'
            ).get(roomId, keep - 1) as any
            if (cutoff) {
                db.prepare('DELETE FROM gc_messages WHERE roomId = ? AND timestamp < ?').run(roomId, cutoff.timestamp)
            }
        }
    }

    // ─── Room Agents ──────────────────────────────────────────

    getRoomAgents(roomId: string): RoomAgent[] {
        return (this.db()?.prepare(
            'SELECT id, roomId, agentId, profile, name, description, invited FROM gc_room_agents WHERE roomId = ?'
        ).all(roomId) || []) as unknown as RoomAgent[]
    }

    addRoomAgent(roomId: string, agentId: string, profile: string, name: string, description: string, invited: number): RoomAgent {
        const id = Date.now().toString(36) + Math.random().toString(36).slice(2, 8)
        this.db()?.prepare(
            'INSERT INTO gc_room_agents (id, roomId, agentId, profile, name, description, invited) VALUES (?, ?, ?, ?, ?, ?, ?)'
        ).run(id, roomId, agentId, profile, name, description, invited)
        return { id, roomId, agentId, profile, name, description, invited }
    }

    removeRoomAgent(agentId: string): void {
        this.db()?.prepare('DELETE FROM gc_room_agents WHERE id = ?').run(agentId)
    }
}

// ─── ChatRoom (in-memory, for online members) ─────────────────

class ChatRoom {
    readonly id: string
    name: string
    readonly members = new Map<string, Member>()

    constructor(id: string, name?: string) {
        this.id = id
        this.name = name || id
    }

    addMember(id: string, name: string): Member {
        const member: Member = { id, name, joinedAt: Date.now() }
        this.members.set(id, member)
        return member
    }

    removeMember(id: string): Member | undefined {
        const member = this.members.get(id)
        this.members.delete(id)
        return member
    }

    getMembersList(): Member[] {
        return Array.from(this.members.values())
    }

    hasMember(id: string): boolean {
        return this.members.has(id)
    }
}

// ─── GroupChat Server ────────────────────────────────────────

export class GroupChatServer {
    private io: Server
    private nsp: Namespace
    private storage: ChatStorage
    private rooms = new Map<string, ChatRoom>()
    private userNames = new Map<string, string>()
    readonly agentClients = new AgentClients()
    private gatewayManager: any = null
    private _restoreScheduled = false

    setGatewayManager(manager: any): void {
        this.gatewayManager = manager
        this.agentClients.setGatewayManager(manager)
    }

    constructor(httpServer: HttpServer) {
        this.storage = new ChatStorage()
        this.storage.init()

        this.io = new Server(httpServer, {
            cors: { origin: '*' },
            transports: ['websocket'],
        })
        this.nsp = this.io.of('/group-chat')
        this.nsp.use(this.authMiddleware.bind(this))
        this.nsp.on('connection', this.onConnection.bind(this))

        // Restore persisted rooms into memory
        this.storage.getAllRooms().forEach((row) => {
            this.rooms.set(row.id, new ChatRoom(row.id, row.name))
        })

        console.log('[GroupChat] Socket.IO ready at /group-chat')

        // Initialize context engine for group chat compression
        const contextEngine = new ContextEngine({ messageFetcher: this.storage })
        this.agentClients.setContextEngine(contextEngine)
        this.agentClients.setStorage(this.storage)

        // Restore agent connections — call restoreAgents() after server is listening
        this._restoreScheduled = false
    }

    getIO(): Server {
        return this.io
    }

    getStorage(): ChatStorage {
        return this.storage
    }

    getRoomIds(): string[] {
        return Array.from(this.rooms.keys())
    }

    // ─── Restore Agents ─────────────────────────────────────────

    /**
     * Restore persisted agent connections. Safe to call multiple times;
     * will only execute once.
     */
    async restoreWhenReady(): Promise<void> {
        if (this._restoreScheduled) return
        this._restoreScheduled = true
        await this.restoreAgents()
    }

    private async restoreAgents(): Promise<void> {
        const rooms = this.storage.getAllRooms()
        let total = 0

        for (const room of rooms) {
            const agents = this.storage.getRoomAgents(room.id)
            for (const agent of agents) {
                try {
                    const client = await this.agentClients.createAgent({
                        profile: agent.profile,
                        name: agent.name,
                        description: agent.description,
                        invited: agent.invited,
                    })
                    await this.agentClients.addAgentToRoom(room.id, client)
                    total++
                } catch (err: any) {
                    console.error(`[GroupChat] Failed to restore agent ${agent.name} in room ${room.id}: ${err.message}`)
                }
            }
        }

        if (total > 0) {
            console.log(`[GroupChat] Restored ${total} agent(s) across ${rooms.length} room(s)`)
        }
    }

    // ─── Auth ───────────────────────────────────────────────────

    private async authMiddleware(socket: Socket, next: (err?: Error) => void): Promise<void> {
        const authToken = await getToken()
        if (authToken) {
            const token = socket.handshake.auth.token || socket.handshake.query.token || ''
            if (token !== authToken) {
                return next(new Error('Unauthorized'))
            }
        }
        next()
    }

    // ─── Connection ─────────────────────────────────────────────

    private onConnection(socket: Socket): void {
        const userId = socket.id
        const userName = (socket.handshake.auth.name as string) || `User-${userId.slice(0, 6)}`
        this.userNames.set(userId, userName)

        console.log(`[GroupChat] Connected: ${userName} (${userId})`)

        socket.on('join', (data: { roomId?: string; name?: string }, ack?: (response?: unknown) => void) => this.handleJoin(socket, data, ack))
        socket.on('message', (data: { roomId?: string; content: string }, ack?: (response?: unknown) => void) => this.handleMessage(socket, data, ack))
        socket.on('typing', (data: { roomId?: string }) => this.handleTyping(socket, data))
        socket.on('stop_typing', (data: { roomId?: string }) => this.handleStopTyping(socket, data))
        socket.on('disconnect', () => this.handleDisconnect(socket))
    }

    // ─── Handlers ───────────────────────────────────────────────

    private handleJoin(socket: Socket, data: { roomId?: string; name?: string }, ack?: (res: any) => void): void {
        const userId = socket.id
        if (data.name) this.userNames.set(userId, data.name)
        const userName = this.userNames.get(userId)!

        const roomId = data.roomId || 'general'
        let room = this.rooms.get(roomId)
        if (!room) {
            room = new ChatRoom(roomId)
            this.rooms.set(roomId, room)
            this.storage.saveRoom(roomId, roomId)
        }

        room.addMember(userId, userName)
        socket.join(roomId)

        socket.to(roomId).emit('member_joined', {
            roomId,
            memberId: userId,
            memberName: userName,
            members: room.getMembersList(),
        })

        // Load history from SQLite
        const messages = this.storage.getMessages(roomId)

        ack?.({
            roomId,
            roomName: room.name,
            members: room.getMembersList(),
            messages,
            rooms: this.getRoomIds(),
        })

        console.log(`[GroupChat] ${userName} joined room: ${roomId}`)
    }

    private handleMessage(socket: Socket, data: { roomId?: string; content: string }, ack?: (res: any) => void): void {
        const userId = socket.id
        const roomId = data.roomId || 'general'
        const room = this.rooms.get(roomId)

        if (!room || !room.hasMember(userId)) {
            ack?.({ error: 'Not in room' })
            return
        }

        const msg: ChatMessage = {
            id: this.generateId(),
            roomId,
            senderId: userId,
            senderName: this.userNames.get(userId)!,
            content: data.content,
            timestamp: Date.now(),
        }

        this.storage.addMessage(msg)
        this.storage.pruneMessages(roomId)
        this.nsp.to(roomId).emit('message', msg)
        ack?.({ id: msg.id })
    }

    private handleTyping(socket: Socket, data: { roomId?: string }): void {
        const roomId = data.roomId || 'general'
        socket.to(roomId).emit('typing', {
            roomId,
            userId: socket.id,
            userName: this.userNames.get(socket.id),
        })
    }

    private handleStopTyping(socket: Socket, data: { roomId?: string }): void {
        const roomId = data.roomId || 'general'
        socket.to(roomId).emit('stop_typing', {
            roomId,
            userId: socket.id,
            userName: this.userNames.get(socket.id),
        })
    }

    private handleDisconnect(socket: Socket): void {
        const userId = socket.id
        const userName = this.userNames.get(userId)

        console.log(`[GroupChat] Disconnected: ${userName} (${userId})`)

        this.leaveAllRooms(socket, userId, userName || userId)
        this.userNames.delete(userId)
    }

    // ─── Helpers ────────────────────────────────────────────────

    private leaveAllRooms(socket: Socket, userId: string, userName: string): void {
        this.rooms.forEach((room, rid) => {
            if (room.hasMember(userId)) {
                room.removeMember(userId)
                socket.leave(rid)
                this.nsp.to(rid).emit('member_left', {
                    roomId: rid,
                    memberId: userId,
                    memberName: userName,
                    members: room.getMembersList(),
                })
            }
        })
    }

    private generateId(): string {
        return Date.now().toString(36) + Math.random().toString(36).slice(2, 8)
    }
}
