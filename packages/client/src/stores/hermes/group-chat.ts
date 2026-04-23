import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import {
    connectGroupChat,
    disconnectGroupChat,
    getSocket,
    type RoomInfo,
    type RoomAgent,
    type ChatMessage,
    type MemberInfo,
    type JoinResult,
    createRoom,
    listRooms,
    getRoomDetail,
    joinRoomByCode,
    addAgent,
    listAgents,
    removeAgent,
} from '@/api/hermes/group-chat'

export const useGroupChatStore = defineStore('groupChat', () => {
    // ─── State ─────────────────────────────────────────────
    const connected = ref(false)
    const currentRoomId = ref<string | null>(null)
    const rooms = ref<RoomInfo[]>([])
    const messages = ref<ChatMessage[]>([])
    const members = ref<MemberInfo[]>([])
    const agents = ref<RoomAgent[]>([])
    const roomName = ref('')
    const isJoining = ref(false)
    const error = ref<string | null>(null)
    const typingUsers = ref<Map<string, { name: string; timer: ReturnType<typeof setTimeout> }>>(new Map())
    const contextStatus = ref<{ agentName: string; status: string } | null>(null)

    // ─── Computed ───────────────────────────────────────────
    const sortedMessages = computed(() => {
        return [...messages.value].sort((a, b) => a.timestamp - b.timestamp)
    })

    const memberNames = computed(() => {
        return members.value.map(m => m.name)
    })

    const typingNames = computed(() => {
        return Array.from(typingUsers.value.values()).map(u => u.name)
    })

    const typingText = computed(() => {
        const names = typingNames.value
        if (names.length === 0) return ''
        if (names.length === 1) return `${names[0]} is typing...`
        if (names.length === 2) return `${names[0]} and ${names[1]} are typing...`
        return `${names[0]} and ${names.length - 1} others are typing...`
    })

    // ─── Connection ────────────────────────────────────────
    function connect() {
        const socket = connectGroupChat()
        console.log('[GroupChat] connecting...')

        socket.on('connect', () => {
            console.log('[GroupChat] connected, socket id:', socket.id)
            connected.value = true
            error.value = null
        })

        socket.on('disconnect', (reason) => {
            console.log('[GroupChat] disconnected:', reason)
            connected.value = false
        })

        socket.on('connect_error', (err: Error) => {
            console.error('[GroupChat] connect_error:', err.message)
            error.value = err.message
            connected.value = false
        })

        socket.on('message', (msg: ChatMessage) => {
            if (msg.roomId === currentRoomId.value) {
                messages.value.push(msg)
            }
        })

        socket.on('member_joined', (data: { roomId: string; members: MemberInfo[] }) => {
            if (data.roomId === currentRoomId.value) {
                members.value = data.members
            }
        })

        socket.on('member_left', (data: { roomId: string; members: MemberInfo[] }) => {
            if (data.roomId === currentRoomId.value) {
                members.value = data.members
            }
        })

        socket.on('typing', (data: { roomId: string; userId: string; userName: string }) => {
            if (data.roomId === currentRoomId.value && !typingUsers.value.has(data.userId)) {
                const timer = setTimeout(() => typingUsers.value.delete(data.userId), 5000)
                typingUsers.value.set(data.userId, { name: data.userName, timer })
            }
        })

        socket.on('stop_typing', (data: { roomId: string; userId: string }) => {
            if (data.roomId === currentRoomId.value && typingUsers.value.has(data.userId)) {
                const entry = typingUsers.value.get(data.userId)!
                clearTimeout(entry.timer)
                typingUsers.value.delete(data.userId)
            }
        })

        socket.on('context_status', (data: { roomId: string; agentName: string; status: string }) => {
            if (data.roomId === currentRoomId.value) {
                if (data.status === 'ready') {
                    contextStatus.value = null
                } else {
                    contextStatus.value = { agentName: data.agentName, status: data.status }
                }
            }
        })
    }

    function disconnect() {
        disconnectGroupChat()
        connected.value = false
        currentRoomId.value = null
        messages.value = []
        members.value = []
        agents.value = []
        roomName.value = ''
        typingUsers.value.clear()
        contextStatus.value = null
    }

    // ─── Room Actions ──────────────────────────────────────
    async function joinRoom(roomId: string) {
        isJoining.value = true
        error.value = null

        try {
            const res = await getRoomDetail(roomId)
            currentRoomId.value = res.room.id
            roomName.value = res.room.name
            messages.value = res.messages
            agents.value = res.agents
        } catch (err: any) {
            error.value = err.message
            throw err
        } finally {
            isJoining.value = false
        }

        // Join via socket for real-time updates
        const socket = getSocket()
        if (socket) {
            await new Promise<void>((resolve) => {
                socket.emit('join', { roomId }, (res: any) => {
                    if (!res?.error) {
                        members.value = res.members || []
                    }
                    resolve()
                })
            })
        }
    }

    async function sendMessage(content: string) {
        const socket = getSocket()
        if (!socket || !currentRoomId.value) return
        emitStopTyping()

        return new Promise<void>((resolve, reject) => {
            socket!.emit('message', { roomId: currentRoomId.value, content }, (res: { id?: string; error?: string }) => {
                if (res.error) {
                    reject(new Error(res.error))
                    return
                }
                resolve()
            })
        })
    }

    async function loadRooms() {
        try {
            const res = await listRooms()
            rooms.value = res.rooms
        } catch (err: any) {
            error.value = err.message
        }
    }

    async function createNewRoom(name: string, inviteCode: string, agentList?: { profile: string; name?: string; description?: string; invited?: boolean }[]) {
        try {
            const res = await createRoom({ name, inviteCode, agents: agentList })
            rooms.value.push(res.room)
            return res
        } catch (err: any) {
            error.value = err.message
            throw err
        }
    }

    async function joinByCode(code: string) {
        try {
            const res = await joinRoomByCode(code)
            await joinRoom(res.room.id)
            return res.room
        } catch (err: any) {
            error.value = err.message
            throw err
        }
    }

    // ─── Agent Actions ─────────────────────────────────────
    async function loadAgents(roomId: string) {
        try {
            const res = await listAgents(roomId)
            agents.value = res.agents
        } catch { /* ignore */ }
    }

    async function addAgentToRoom(roomId: string, data: { profile: string; name?: string; description?: string; invited?: boolean }) {
        try {
            const res = await addAgent(roomId, data)
            agents.value.push(res.agent)
            return res.agent
        } catch (err: any) {
            error.value = err.message
            throw err
        }
    }

    async function removeAgentFromRoom(roomId: string, agentId: string) {
        try {
            await removeAgent(roomId, agentId)
            agents.value = agents.value.filter(a => a.id !== agentId)
        } catch (err: any) {
            error.value = err.message
            throw err
        }
    }

    // ─── Typing ────────────────────────────────────────────
    let _typingTimer: ReturnType<typeof setTimeout> | null = null

    function emitTyping() {
        const socket = getSocket()
        if (!socket || !currentRoomId.value) return
        socket.emit('typing', { roomId: currentRoomId.value })
        if (_typingTimer) clearTimeout(_typingTimer)
        _typingTimer = setTimeout(() => emitStopTyping(), 4000)
    }

    function emitStopTyping() {
        const socket = getSocket()
        if (!socket || !currentRoomId.value) return
        socket.emit('stop_typing', { roomId: currentRoomId.value })
        if (_typingTimer) { clearTimeout(_typingTimer); _typingTimer = null }
    }

    return {
        // State
        connected,
        currentRoomId,
        rooms,
        messages,
        members,
        agents,
        roomName,
        isJoining,
        error,
        contextStatus,
        // Computed
        sortedMessages,
        memberNames,
        typingNames,
        typingText,
        // Actions
        connect,
        disconnect,
        joinRoom,
        sendMessage,
        loadRooms,
        emitTyping,
        emitStopTyping,
        createNewRoom,
        joinByCode,
        loadAgents,
        addAgentToRoom,
        removeAgentFromRoom,
    }
})
