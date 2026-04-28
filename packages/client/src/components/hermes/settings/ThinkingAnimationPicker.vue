<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { NButton, NUpload, useMessage } from 'naive-ui'
import type { UploadCustomRequestOptions } from 'naive-ui'
import { useI18n } from 'vue-i18n'
import SettingRow from './SettingRow.vue'

const { t } = useI18n()
const message = useMessage()

const hasCustom = ref(false)
const customUrl = ref('')
const customType = ref<'gif' | 'video'>('gif')
const uploading = ref(false)

async function checkStatus() {
  try {
    const res = await fetch('/api/thinking-animation/status')
    const data = await res.json()
    hasCustom.value = data.hasCustom
    if (data.hasCustom) {
      customUrl.value = data.url
      customType.value = data.type
    } else {
      customUrl.value = ''
    }
  } catch {
    hasCustom.value = false
    customUrl.value = ''
  }
}

async function handleUpload({ file }: UploadCustomRequestOptions) {
  if (!file.file) return
  const ext = file.name.split('.').pop()?.toLowerCase() || ''
  if (!['gif', 'mp4', 'webm', 'mov', 'avi', 'mkv'].includes(ext)) {
    message.error(t('settings.display.thinkingAnimationUnsupported'))
    return
  }
  if (file.file.size > 100 * 1024 * 1024) {
    message.error(t('settings.display.thinkingAnimationTooLarge'))
    return
  }
  uploading.value = true
  try {
    const formData = new FormData()
    formData.append('file', file.file, file.name)
    const token = localStorage.getItem('hermes_api_key') || ''
    const res = await fetch('/api/thinking-animation/upload', {
      method: 'POST',
      body: formData,
      headers: token ? { Authorization: `Bearer ${token}` } : {},
    })
    const data = await res.json()
    if (data.success) {
      hasCustom.value = true
      customUrl.value = data.url
      customType.value = data.type
      message.success(t('settings.display.thinkingAnimationUploaded'))
    } else {
      message.error(data.error || t('settings.display.thinkingAnimationFailed'))
    }
  } catch (err) {
    message.error(t('settings.display.thinkingAnimationFailed'))
  } finally {
    uploading.value = false
  }
}

async function handleReset() {
  try {
    const token = localStorage.getItem('hermes_api_key') || ''
    const res = await fetch('/api/thinking-animation', {
      method: 'DELETE',
      headers: token ? { Authorization: `Bearer ${token}` } : {},
    })
    const data = await res.json()
    if (data.success) {
      hasCustom.value = false
      customUrl.value = ''
      message.success(t('settings.display.thinkingAnimationReset'))
    }
  } catch {
    message.error(t('settings.display.thinkingAnimationFailed'))
  }
}

onMounted(checkStatus)
</script>

<template>
  <SettingRow
    :label="t('settings.display.thinkingAnimation')"
    :hint="t('settings.display.thinkingAnimationHint')"
  >
    <div class="thinking-animation-picker">
      <div v-if="hasCustom && customUrl" class="thinking-animation-preview">
        <img
          v-if="customType === 'gif'"
          :src="customUrl"
          class="thinking-animation-thumb"
          alt="Custom thinking animation"
        />
        <video
          v-else
          :src="customUrl"
          class="thinking-animation-thumb"
          autoplay
          loop
          muted
        />
        <NButton size="small" type="error" quaternary @click="handleReset">
          {{ t('settings.display.thinkingAnimationReset') }}
        </NButton>
      </div>
      <NUpload
        v-else
        :custom-request="handleUpload"
        accept=".gif,.mp4,.webm,.mov,.avi,.mkv"
        :max="1"
        :disabled="uploading"
        :show-file-list="false"
      >
        <NButton size="small" :loading="uploading" secondary>
          {{ uploading ? t('settings.display.thinkingAnimationUploading') : t('settings.display.thinkingAnimationUpload') }}
        </NButton>
      </NUpload>
    </div>
  </SettingRow>
</template>

<style scoped>
.thinking-animation-picker {
  display: flex;
  align-items: center;
  gap: 8px;
}
.thinking-animation-preview {
  display: flex;
  align-items: center;
  gap: 8px;
}
.thinking-animation-thumb {
  width: 48px;
  height: 48px;
  object-fit: contain;
  border-radius: 8px;
  border: 1px solid var(--border-color);
}
</style>
