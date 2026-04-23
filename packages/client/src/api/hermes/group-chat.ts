import { io } from 'socket.io-client'
import { request, getApiKey } from '../client'

// ─── Types ──────────────────────────────────────────────────

export interface RoomInfo {
    id: string
    name: string
    inviteCode: string | null
}

export interface RoomAgent {
    id: string
    roomId: string
    agentId: string
    profile: string
    name: string
    description: string
    invited: number
}

export interface ChatMessage {
    id: string
    roomId: string
    senderId: string
    senderName: string
    content: string
    timestamp: number
}

export interface MemberInfo {
    id: string
    name: string
    joinedAt: number
}

export interface JoinResult {
    roomId: string
    roomName: string
    members: MemberInfo[]
    messages: ChatMessage[]
    rooms: string[]
}

// ─── Socket.IO Client ──────────────────────────────────────

let socket: ReturnType<typeof io> | null = null

export function connectGroupChat(): ReturnType<typeof io> {
    if (socket?.connected) return socket

    const token = getApiKey()

    socket = io('/group-chat', {
        auth: { token: token || undefined },
        transports: ['websocket'],
        reconnection: true,
        reconnectionAttempts: Infinity,
        reconnectionDelay: 1000,
        reconnectionDelayMax: 30000,
    })

    return socket
}

export function getSocket(): ReturnType<typeof io> | null {
    return socket?.connected ? socket : null
}

export function disconnectGroupChat(): void {
    if (socket) {
        socket.disconnect()
        socket = null
    }
}

// ─── REST API ───────────────────────────────────────────────

export async function createRoom(data: {
    name: string
    inviteCode: string
    agents?: { profile: string; name?: string; description?: string; invited?: boolean }[]
}): Promise<{ room: RoomInfo; agents: RoomAgent[] }> {
    return request('/api/hermes/group-chat/rooms', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data),
    })
}

export async function listRooms(): Promise<{ rooms: RoomInfo[] }> {
    return request('/api/hermes/group-chat/rooms')
}

export async function getRoomDetail(roomId: string): Promise<{ room: RoomInfo; messages: ChatMessage[]; agents: RoomAgent[] }> {
    return request(`/api/hermes/group-chat/rooms/${roomId}`)
}

export async function joinRoomByCode(code: string): Promise<{ room: RoomInfo }> {
    return request(`/api/hermes/group-chat/rooms/join/${code}`)
}

export async function updateInviteCode(roomId: string, inviteCode: string): Promise<void> {
    return request(`/api/hermes/group-chat/rooms/${roomId}/invite-code`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ inviteCode }),
    })
}

export async function addAgent(roomId: string, data: {
    profile: string
    name?: string
    description?: string
    invited?: boolean
}): Promise<{ agent: RoomAgent }> {
    return request(`/api/hermes/group-chat/rooms/${roomId}/agents`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data),
    })
}

export async function listAgents(roomId: string): Promise<{ agents: RoomAgent[] }> {
    return request(`/api/hermes/group-chat/rooms/${roomId}/agents`)
}

export async function removeAgent(roomId: string, agentId: string): Promise<void> {
    return request(`/api/hermes/group-chat/rooms/${roomId}/agents/${agentId}`, {
        method: 'DELETE',
    })
}

