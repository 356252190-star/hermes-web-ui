<script setup lang="ts">
import { ref, computed, onMounted, nextTick } from 'vue'
import { NTooltip, NDropdown, useMessage } from 'naive-ui'
import type { DropdownOption } from 'naive-ui'
import { useI18n } from 'vue-i18n'
import { useProfilesStore } from '@/stores/hermes/profiles'

const emit = defineEmits<{ (e: 'switch', name: string): void }>()

const { t } = useI18n()
const message = useMessage()
const profilesStore = useProfilesStore()

// Create profile
const showCreate = ref(false)
const createName = ref('')
const creating = ref(false)

// Rename profile
const showRename = ref(false)
const renameOld = ref('')
const renameNew = ref('')
const renaming = ref(false)

const activeName = computed(() => profilesStore.activeProfileName ?? '')

function contextOptions(): DropdownOption[] {
  return [
    { label: t('gatewayTabs.rename', 'Rename'), key: 'rename' },
    { label: t('gatewayTabs.export', 'Export'), key: 'export' },
    { type: 'divider', key: 'd1' },
    {
      label: t('gatewayTabs.delete', 'Delete'),
      key: 'delete',
      props: { style: { color: 'var(--error)' } },
    },
  ]
}

async function handleSwitch(name: string) {
  if (name === activeName.value || profilesStore.switching) return
  const ok = await profilesStore.switchProfile(name)
  if (ok) {
    message.success(t('profiles.switchSuccess', { name }))
    emit('switch', name)
  }
}

function handleCreate() {
  createName.value = ''
  showCreate.value = true
  nextTick(() => {
    const input = document.querySelector('.create-profile-input input') as HTMLInputElement
    input?.focus()
  })
}

async function doCreate() {
  const name = createName.value.trim()
  if (!name) {
    message.warning(t('gatewayTabs.nameRequired', 'Profile name is required'))
    return
  }
  creating.value = true
  try {
    const ok = await profilesStore.createProfile(name)
    if (ok) {
      message.success(t('gatewayTabs.created', { name }))
      showCreate.value = false
    } else {
      message.error(t('gatewayTabs.createFailed', 'Failed to create profile'))
    }
  } finally {
    creating.value = false
  }
}

function handleRename(name: string) {
  renameOld.value = name
  renameNew.value = name
  showRename.value = true
  nextTick(() => {
    const input = document.querySelector('.rename-profile-input input') as HTMLInputElement
    input?.focus()
    input?.select()
  })
}

async function doRename() {
  const newName = renameNew.value.trim()
  if (!newName) {
    message.warning(t('gatewayTabs.nameRequired', 'Profile name is required'))
    return
  }
  if (newName === renameOld.value) {
    showRename.value = false
    return
  }
  renaming.value = true
  try {
    const ok = await profilesStore.renameProfile(renameOld.value, newName)
    if (ok) {
      message.success(t('gatewayTabs.renamed', { from: renameOld.value, to: newName }))
      showRename.value = false
    } else {
      message.error(t('gatewayTabs.renameFailed', 'Failed to rename profile'))
    }
  } finally {
    renaming.value = false
  }
}

async function handleDelete(name: string) {
  if (name === activeName.value) {
    message.warning(t('gatewayTabs.cannotDeleteActive', 'Cannot delete the active profile'))
    return
  }
  const ok = await profilesStore.deleteProfile(name)
  if (ok) {
    message.success(t('gatewayTabs.deleted', { name }))
  } else {
    message.error(t('gatewayTabs.deleteFailed', 'Failed to delete profile'))
  }
}

async function handleExport(name: string) {
  try {
    const ok = await profilesStore.exportProfile(name)
    if (ok) {
      message.success(t('gatewayTabs.exported', { name }))
    } else {
      message.error(t('gatewayTabs.exportFailed', 'Failed to export profile'))
    }
  } catch {
    message.error(t('gatewayTabs.exportFailed', 'Failed to export profile'))
  }
}

function handleContextMenu(key: string, profileName: string) {
  if (key === 'rename') handleRename(profileName)
  else if (key === 'delete') handleDelete(profileName)
  else if (key === 'export') handleExport(profileName)
}

onMounted(() => {
  if (profilesStore.profiles.length === 0) {
    profilesStore.fetchProfiles()
  }
})
</script>

<template>
  <div class="gateway-tabs">
    <div class="tabs-header">
      <span class="tabs-label">{{ t('sidebar.profiles') }}</span>
      <button class="tabs-add" @click="handleCreate" :title="t('gatewayTabs.create', 'Create profile')">+</button>
    </div>
    <div class="tabs-scroll">
      <div class="tabs-list">
        <NDropdown
          v-for="p in profilesStore.profiles"
          :key="p.name"
          :options="contextOptions()"
          trigger="click"
          placement="bottom-start"
          @select="(key) => handleContextMenu(key as string, p.name)"
        >
          <NTooltip :delay="400" placement="top">
            <template #trigger>
              <button
                class="tab-btn"
                :class="{ active: p.name === activeName, switching: profilesStore.switching && p.name === activeName }"
                :disabled="profilesStore.switching"
                @click="handleSwitch(p.name)"
              >
                <span class="tab-dot" :class="p.active ? 'running' : 'unknown'" />
                <span class="tab-name" :title="p.alias || p.name">{{ p.alias || p.name }}</span>
              </button>
            </template>
            <div class="tab-tooltip">
              <div class="tooltip-name">{{ p.name }}</div>
              <div v-if="p.model" class="tooltip-detail">{{ p.model }}</div>
              <div v-if="p.gateway" class="tooltip-detail">{{ p.gateway }}</div>
            </div>
          </NTooltip>
        </NDropdown>

        <div v-if="profilesStore.profiles.length === 0 && !profilesStore.loading" class="tabs-empty">
          {{ t('common.noData') }}
        </div>
      </div>
    </div>

    <!-- Create profile inline -->
    <div v-if="showCreate" class="tabs-inline-form">
      <input
        v-model="createName"
        class="create-profile-input"
        :placeholder="t('gatewayTabs.namePlaceholder', 'Profile name')"
        @keydown.enter="doCreate"
        @keydown.escape="showCreate = false"
      />
      <button class="form-btn confirm" :disabled="creating" @click="doCreate">✓</button>
      <button class="form-btn cancel" @click="showCreate = false">✕</button>
    </div>

    <!-- Rename profile inline -->
    <div v-if="showRename" class="tabs-inline-form">
      <input
        v-model="renameNew"
        class="rename-profile-input"
        :placeholder="t('gatewayTabs.namePlaceholder', 'Profile name')"
        @keydown.enter="doRename"
        @keydown.escape="showRename = false"
      />
      <button class="form-btn confirm" :disabled="renaming" @click="doRename">✓</button>
      <button class="form-btn cancel" @click="showRename = false">✕</button>
    </div>
  </div>
</template>

<style scoped lang="scss">
@use '@/styles/variables' as *;

.gateway-tabs {
  padding: 0 12px;
  margin-bottom: 8px;
}

.tabs-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 6px;
}

.tabs-label {
  font-size: 11px;
  font-weight: 600;
  color: $text-muted;
  text-transform: uppercase;
  letter-spacing: 0.5px;
}

.tabs-add {
  width: 18px;
  height: 18px;
  border-radius: 4px;
  border: 1px solid $border-color;
  background: transparent;
  color: $text-muted;
  font-size: 14px;
  line-height: 1;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: background $transition-fast, color $transition-fast;

  &:hover {
    background: $bg-card-hover;
    color: $text-primary;
  }
}

.tabs-scroll {
  overflow-x: auto;
  scrollbar-width: none;
  &::-webkit-scrollbar { display: none; }
}

.tabs-list {
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
}

.tab-btn {
  flex: 0 0 calc(50% - 2px);
  min-width: 0;
  display: flex;
  align-items: center;
  gap: 5px;
  padding: 4px 8px;
  border: 1px solid transparent;
  border-radius: 6px;
  background: transparent;
  color: $text-secondary;
  font-size: 12px;
  cursor: pointer;
  transition: background $transition-fast, border-color $transition-fast;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;

  &:hover {
    background: $bg-card-hover;
    border-color: $border-color;
  }

  &.active {
    background: rgba(var(--accent-primary-rgb), 0.1);
    border-color: rgba(var(--accent-primary-rgb), 0.3);
    color: $text-primary;
    font-weight: 500;
  }

  &.switching {
    opacity: 0.6;
    pointer-events: none;
  }

  &:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
}

.tab-dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  flex-shrink: 0;

  &.running { background: #18a058; }
  &.unknown { background: $text-muted; }
}

.tab-name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  min-width: 0;
}

.tab-tooltip {
  font-size: 12px;
  line-height: 1.6;
}
.tooltip-name {
  font-weight: 600;
  color: $text-primary;
}
.tooltip-detail {
  color: $text-muted;
}
.tooltip-backend {
  color: $accent-primary;
  font-family: monospace;
  font-size: 11px;
}

.tabs-empty {
  font-size: 12px;
  color: $text-muted;
  padding: 4px 0;
}

.tabs-inline-form {
  display: flex;
  align-items: center;
  gap: 4px;
  margin-top: 6px;

  input {
    flex: 1;
    min-width: 0;
    padding: 3px 6px;
    border: 1px solid $border-color;
    border-radius: 4px;
    background: $bg-input;
    color: $text-primary;
    font-size: 12px;
    outline: none;

    &:focus {
      border-color: $accent-primary;
    }
  }
}

.form-btn {
  width: 22px;
  height: 22px;
  border: none;
  border-radius: 4px;
  font-size: 12px;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;

  &.confirm {
    background: rgba(var(--accent-primary-rgb), 0.15);
    color: $accent-primary;
    &:hover { background: rgba(var(--accent-primary-rgb), 0.25); }
  }
  &.cancel {
    background: transparent;
    color: $text-muted;
    &:hover { background: $bg-card-hover; }
  }
}
</style>
