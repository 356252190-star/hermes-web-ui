<script setup lang="ts">
import { ref, computed, nextTick } from 'vue'
import { useI18n } from 'vue-i18n'
import { NButton } from 'naive-ui'

const { t } = useI18n()
const emit = defineEmits<{ send: [content: string] }>()

const inputText = ref('')
const textareaRef = ref<HTMLTextAreaElement>()
const isComposing = ref(false)

const canSend = computed(() => !!inputText.value.trim())

function handleKeydown(e: KeyboardEvent) {
    if (e.key !== 'Enter' || e.shiftKey) return
    if (isComposing.value || e.isComposing || e.keyCode === 229) return
    e.preventDefault()
    handleSend()
}

function handleSend() {
    const content = inputText.value.trim()
    if (!content) return

    emit('send', content)
    inputText.value = ''

    nextTick(() => {
        if (textareaRef.value) {
            textareaRef.value.style.height = 'auto'
        }
    })
}

function handleInput(e: Event) {
    const el = e.target as HTMLTextAreaElement
    el.style.height = 'auto'
    el.style.height = Math.min(el.scrollHeight, 100) + 'px'
}

function handleCompositionStart() {
    isComposing.value = true
}

function handleCompositionEnd() {
    requestAnimationFrame(() => {
        isComposing.value = false
    })
}
</script>

<template>
    <div class="chat-input-area">
        <div class="input-wrapper">
            <textarea
                ref="textareaRef"
                v-model="inputText"
                class="input-textarea"
                :placeholder="t('groupChat.inputPlaceholder')"
                rows="1"
                @keydown="handleKeydown"
                @compositionstart="handleCompositionStart"
                @compositionend="handleCompositionEnd"
                @input="handleInput"
            />
            <div class="input-actions">
                <NButton
                    size="small"
                    type="primary"
                    :disabled="!canSend"
                    @click="handleSend"
                >
                    <template #icon>
                        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="22" y1="2" x2="11" y2="13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/></svg>
                    </template>
                    {{ t('chat.send') }}
                </NButton>
            </div>
        </div>
    </div>
</template>

<style scoped lang="scss">
@use "@/styles/variables" as *;

.chat-input-area {
    padding: 12px 20px 16px;
    border-top: 1px solid $border-color;
    flex-shrink: 0;
}

.input-wrapper {
    display: flex;
    align-items: center;
    gap: 10px;
    background-color: $bg-input;
    border: 1px solid $border-color;
    border-radius: $radius-md;
    padding: 10px 12px;
    transition: border-color $transition-fast, background-color $transition-fast;

    &:focus-within {
        border-color: $accent-primary;
    }

    .dark & {
        background-color: #333333;
    }
}

.input-textarea {
    flex: 1;
    background: none;
    border: none;
    outline: none;
    color: $text-primary;
    font-family: $font-ui;
    font-size: 14px;
    line-height: 1.5;
    resize: none;
    max-height: 100px;
    min-height: 20px;
    overflow-y: auto;

    &::placeholder {
        color: $text-muted;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
    }
}

.input-actions {
    display: flex;
    gap: 6px;
    flex-shrink: 0;
    align-items: center;
}
</style>
