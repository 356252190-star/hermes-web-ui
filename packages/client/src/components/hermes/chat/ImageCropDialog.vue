<script setup lang="ts">
import { ref, computed, watch, onMounted, onBeforeUnmount, nextTick } from 'vue'
import { useI18n } from 'vue-i18n'
import { NButton, NSlider } from 'naive-ui'

const props = defineProps<{
  visible: boolean
  imageSrc: string
  fileName: string
}>()

const emit = defineEmits<{
  (e: 'crop', blob: Blob): void
  (e: 'cancel'): void
}>()

const { t } = useI18n()

const canvasRef = ref<HTMLCanvasElement>()
const img = ref<HTMLImageElement | null>(null)

const scale = ref(1)
const offsetX = ref(0)
const offsetY = ref(0)
const isDragging = ref(false)
const dragStartX = ref(0)
const dragStartY = ref(0)
const dragStartOffsetX = ref(0)
const dragStartOffsetY = ref(0)

const CROP_SIZE = 256 // output size in px

// Load image
watch(() => props.visible, async (v) => {
  if (v && props.imageSrc) {
    scale.value = 1
    offsetX.value = 0
    offsetY.value = 0
    const image = new Image()
    image.crossOrigin = 'anonymous'
    image.onload = () => {
      img.value = image
      // Auto-fit: scale so the smaller dimension fills the crop area
      const minDim = Math.min(image.width, image.height)
      scale.value = CROP_SIZE / minDim
      // Center
      offsetX.value = (CROP_SIZE - image.width * scale.value) / 2
      offsetY.value = (CROP_SIZE - image.height * scale.value) / 2
      drawPreview()
    }
    image.src = props.imageSrc
  }
})

// Zoom slider range
const minScale = computed(() => {
  if (!img.value) return 0.1
  const minDim = Math.min(img.value.width, img.value.height)
  return CROP_SIZE / minDim * 0.5
})
const maxScale = computed(() => {
  if (!img.value) return 3
  const minDim = Math.min(img.value.width, img.value.height)
  return CROP_SIZE / minDim * 3
})

function drawPreview() {
  const canvas = canvasRef.value
  const image = img.value
  if (!canvas || !image) return
  const ctx = canvas.getContext('2d')
  if (!ctx) return

  canvas.width = CROP_SIZE
  canvas.height = CROP_SIZE

  // Clear with dark bg
  ctx.fillStyle = '#1a1a1a'
  ctx.fillRect(0, 0, CROP_SIZE, CROP_SIZE)

  // Draw image with current transform
  ctx.save()
  ctx.translate(offsetX.value, offsetY.value)
  ctx.scale(scale.value, scale.value)
  ctx.drawImage(image, 0, 0)
  ctx.restore()
}

// Watch for redraw on changes
watch([scale, offsetX, offsetY], () => {
  nextTick(drawPreview)
})

// Drag to pan
function onPointerDown(e: PointerEvent) {
  isDragging.value = true
  dragStartX.value = e.clientX
  dragStartY.value = e.clientY
  dragStartOffsetX.value = offsetX.value
  dragStartOffsetY.value = offsetY.value
  ;(e.target as HTMLElement).setPointerCapture(e.pointerId)
}

function onPointerMove(e: PointerEvent) {
  if (!isDragging.value) return
  const dx = e.clientX - dragStartX.value
  const dy = e.clientY - dragStartY.value
  offsetX.value = dragStartOffsetX.value + dx
  offsetY.value = dragStartOffsetY.value + dy
}

function onPointerUp() {
  isDragging.value = false
}

function onWheel(e: WheelEvent) {
  e.preventDefault()
  const delta = e.deltaY > 0 ? 0.9 : 1.1
  const newScale = Math.max(minScale.value, Math.min(maxScale.value, scale.value * delta))
  // Zoom toward center of crop area
  const centerX = CROP_SIZE / 2
  const centerY = CROP_SIZE / 2
  offsetX.value = centerX - (centerX - offsetX.value) * (newScale / scale.value)
  offsetY.value = centerY - (centerY - offsetY.value) * (newScale / scale.value)
  scale.value = newScale
}

function handleCrop() {
  const canvas = canvasRef.value
  if (!canvas) return
  canvas.toBlob((blob) => {
    if (blob) emit('crop', blob)
  }, 'image/png', 0.92)
}

function handleCancel() {
  emit('cancel')
}

// Keyboard
function onKeyDown(e: KeyboardEvent) {
  if (e.key === 'Escape') handleCancel()
  if (e.key === 'Enter') handleCrop()
}

onMounted(() => {
  document.addEventListener('keydown', onKeyDown)
})
onBeforeUnmount(() => {
  document.removeEventListener('keydown', onKeyDown)
})
</script>

<template>
  <Teleport to="body">
    <div v-if="visible" class="crop-overlay" @click.self="handleCancel">
      <div class="crop-dialog">
        <div class="crop-header">
          <span class="crop-title">{{ t('avatar.cropTitle') }}</span>
          <span class="crop-filename">{{ fileName }}</span>
        </div>
        <div
          class="crop-canvas-wrap"
          @pointerdown="onPointerDown"
          @pointermove="onPointerMove"
          @pointerup="onPointerUp"
          @wheel="onWheel"
        >
          <canvas ref="canvasRef" class="crop-canvas" />
          <div class="crop-grid">
            <div class="grid-line h1"></div>
            <div class="grid-line h2"></div>
            <div class="grid-line v1"></div>
            <div class="grid-line v2"></div>
          </div>
        </div>
        <div class="crop-controls">
          <span class="zoom-label">🔍</span>
          <NSlider
            v-model:value="scale"
            :min="minScale"
            :max="maxScale"
            :step="0.01"
            :tooltip="false"
            class="zoom-slider"
          />
          <span class="zoom-pct">{{ Math.round(scale / (img ? CROP_SIZE / Math.min(img.width, img.height) : 1) * 100) }}%</span>
        </div>
        <div class="crop-actions">
          <NButton size="small" @click="handleCancel">{{ t('common.cancel') }}</NButton>
          <NButton size="small" type="primary" @click="handleCrop">{{ t('avatar.cropConfirm') }}</NButton>
        </div>
      </div>
    </div>
  </Teleport>
</template>

<style scoped lang="scss">
@use '@/styles/variables' as *;

.crop-overlay {
  position: fixed;
  inset: 0;
  z-index: 9999;
  background: rgba(0, 0, 0, 0.65);
  display: flex;
  align-items: center;
  justify-content: center;
  backdrop-filter: blur(4px);
}

.crop-dialog {
  background: $bg-primary;
  border-radius: $radius-lg;
  padding: 20px;
  min-width: 320px;
  max-width: 400px;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
}

.crop-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 12px;
}

.crop-title {
  font-size: 15px;
  font-weight: 600;
  color: $text-primary;
}

.crop-filename {
  font-size: 12px;
  color: $text-muted;
  max-width: 160px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.crop-canvas-wrap {
  position: relative;
  width: 256px;
  height: 256px;
  margin: 0 auto 12px;
  border-radius: $radius-md;
  overflow: hidden;
  cursor: grab;
  border: 1px solid $border-color;
  touch-action: none;

  &:active {
    cursor: grabbing;
  }
}

.crop-canvas {
  display: block;
  width: 256px;
  height: 256px;
}

.crop-grid {
  position: absolute;
  inset: 0;
  pointer-events: none;

  .grid-line {
    position: absolute;
    background: rgba(255, 255, 255, 0.2);

    &.h1, &.h2 {
      left: 0; right: 0; height: 1px;
    }
    &.h1 { top: 33.33%; }
    &.h2 { top: 66.66%; }

    &.v1, &.v2 {
      top: 0; bottom: 0; width: 1px;
    }
    &.v1 { left: 33.33%; }
    &.v2 { left: 66.66%; }
  }
}

.crop-controls {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 16px;
  padding: 0 4px;
}

.zoom-label {
  font-size: 14px;
  flex-shrink: 0;
}

.zoom-slider {
  flex: 1;
}

.zoom-pct {
  font-size: 12px;
  color: $text-muted;
  min-width: 36px;
  text-align: right;
  flex-shrink: 0;
}

.crop-actions {
  display: flex;
  justify-content: flex-end;
  gap: 8px;
}
</style>
