<script setup lang="ts">
import { ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { NInput, NButton, NSpace } from 'naive-ui'

const { t } = useI18n()
const emit = defineEmits<{ submit: [name: string, inviteCode: string]; cancel: [] }>()

const roomName = ref('')
const inviteCode = ref('')

function generateCode(): string {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    let code = ''
    for (let i = 0; i < 6; i++) {
        code += chars[Math.floor(Math.random() * chars.length)]
    }
    return code
}

function handleCreate() {
    const name = roomName.value.trim()
    const code = inviteCode.value.trim() || generateCode()
    if (!name) return
    emit('submit', name, code)
}
</script>

<template>
    <div class="create-form">
        <div class="form-group">
            <label class="form-label">{{ t('groupChat.roomName') }}</label>
            <NInput
                v-model:value="roomName"
                :placeholder="t('groupChat.roomNamePlaceholder')"
                @keyup.enter="handleCreate"
            />
        </div>
        <div class="form-group">
            <label class="form-label">{{ t('groupChat.inviteCode') }}</label>
            <div class="code-row">
                <NInput
                    v-model:value="inviteCode"
                    :placeholder="t('groupChat.autoGenerate')"
                />
                <NButton size="small" @click="inviteCode = generateCode()">
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
                        <polyline points="23 4 23 10 17 10" /><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10" />
                    </svg>
                </NButton>
            </div>
        </div>
        <div class="modal-actions">
            <NSpace justify="end">
                <NButton @click="emit('cancel')">{{ t('common.cancel') }}</NButton>
                <NButton type="primary" :disabled="!roomName.trim()" @click="handleCreate">{{ t('common.create') }}</NButton>
            </NSpace>
        </div>
    </div>
</template>

<style scoped lang="scss">
@use "@/styles/variables" as *;

.create-form {
    .form-group {
        margin-bottom: 16px;
    }
}

.form-label {
    display: block;
    font-size: 13px;
    font-weight: 500;
    color: $text-secondary;
    margin-bottom: 6px;
}

.code-row {
    display: flex;
    gap: 8px;
    align-items: center;
}
</style>
