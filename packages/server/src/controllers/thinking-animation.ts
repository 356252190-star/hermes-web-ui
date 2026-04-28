import { existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync } from 'fs'
import { resolve, join, basename } from 'path'
import { randomBytes } from 'crypto'
import { config } from '../config'

const DATA_DIR = join(config.dataDir, 'thinking-animation')
const ALLOWED_EXTS = ['.gif', '.mp4', '.webm', '.mov', '.avi', '.mkv']
const MAX_SIZE = 100 * 1024 * 1024 // 100MB

// Ensure data directory exists
if (!existsSync(DATA_DIR)) {
  mkdirSync(DATA_DIR, { recursive: true })
}

/** Safe path resolution to prevent traversal */
function safePath(filename: string): string | null {
  const cleaned = basename(filename)
  if (cleaned !== filename || cleaned === '.' || cleaned === '..') return null
  const ext = '.' + cleaned.split('.').pop()?.toLowerCase()
  if (!ALLOWED_EXTS.includes(ext)) return null
  return join(DATA_DIR, cleaned)
}

/** Split multipart body into parts */
function splitMultipart(raw: Buffer, boundary: Buffer): Buffer[] {
  const parts: Buffer[] = []
  let start = 0
  while (true) {
    const idx = raw.indexOf(boundary, start)
    if (idx === -1) break
    if (start > 0) {
      const end = idx - 2 // before \r\n
      if (end > start) parts.push(raw.subarray(start, end))
    }
    start = idx + boundary.length + 2 // skip \r\n after boundary
  }
  return parts
}

/** GET /api/thinking-animation/status — public */
export async function getStatus(ctx: any) {
  if (!existsSync(DATA_DIR)) {
    ctx.body = { hasCustom: false }; return
  }
  const { readdirSync } = await import('fs')
  const files = readdirSync(DATA_DIR).filter(f => {
    const ext = '.' + f.split('.').pop()?.toLowerCase()
    return ALLOWED_EXTS.includes(ext)
  })
  if (files.length === 0) {
    ctx.body = { hasCustom: false }; return
  }
  const file = files[0]
  const ext = '.' + file.split('.').pop()?.toLowerCase()
  ctx.body = {
    hasCustom: true,
    filename: file,
    type: ext === '.gif' ? 'gif' : 'video',
    url: `/api/thinking-animation/file/${encodeURIComponent(file)}`
  }
}

/** GET /api/thinking-animation/file/:filename — public */
export async function getFile(ctx: any) {
  const filename = ctx.params.filename
  const filePath = safePath(filename)
  if (!filePath || !existsSync(filePath)) {
    ctx.status = 404; ctx.body = { error: 'Not found' }; return
  }
  const ext = '.' + filename.split('.').pop()?.toLowerCase()
  const mimeMap: Record<string, string> = {
    '.gif': 'image/gif', '.mp4': 'video/mp4', '.webm': 'video/webm',
    '.mov': 'video/quicktime', '.avi': 'video/x-msvideo', '.mkv': 'video/x-matroska'
  }
  ctx.set('Content-Type', mimeMap[ext] || 'application/octet-stream')
  ctx.set('Cache-Control', 'public, max-age=86400')
  ctx.body = readFileSync(filePath)
}

/** POST /api/thinking-animation/upload — protected */
export async function upload(ctx: any) {
  const contentType = ctx.get('content-type') || ''
  if (!contentType.startsWith('multipart/form-data')) {
    ctx.status = 400; ctx.body = { error: 'Expected multipart/form-data' }; return
  }
  const boundary = '--' + contentType.split('boundary=')[1]
  if (!boundary) {
    ctx.status = 400; ctx.body = { error: 'Missing boundary' }; return
  }

  const chunks: Buffer[] = []
  let totalSize = 0
  for await (const chunk of ctx.req) {
    totalSize += chunk.length
    if (totalSize > MAX_SIZE) {
      ctx.status = 413; ctx.body = { error: `File too large (max ${MAX_SIZE / 1024 / 1024}MB)` }; return
    }
    chunks.push(chunk)
  }
  const raw = Buffer.concat(chunks)
  const boundaryBuf = Buffer.from(boundary)
  const parts = splitMultipart(raw, boundaryBuf)

  for (const part of parts) {
    const headerEnd = part.indexOf(Buffer.from('\r\n\r\n'))
    if (headerEnd === -1) continue
    const header = part.subarray(0, headerEnd).toString('utf-8')
    const data = part.subarray(headerEnd + 4, part.length - 2)

    let filename = ''
    const filenameStarMatch = header.match(/filename\*=UTF-8''(.+)/i)
    if (filenameStarMatch) {
      filename = decodeURIComponent(filenameStarMatch[1])
    } else {
      const filenameMatch = header.match(/filename="([^"]+)"/)
      if (!filenameMatch) continue
      filename = filenameMatch[1]
    }

    const ext = '.' + filename.split('.').pop()?.toLowerCase()
    if (!ALLOWED_EXTS.includes(ext)) {
      ctx.status = 400; ctx.body = { error: `Unsupported file type: ${ext}` }; return
    }

    // Delete old animation files
    const { readdirSync } = await import('fs')
    if (existsSync(DATA_DIR)) {
      for (const old of readdirSync(DATA_DIR)) {
        try { unlinkSync(join(DATA_DIR, old)) } catch {}
      }
    }

    // Save new file with random name
    const savedName = randomBytes(8).toString('hex') + ext
    writeFileSync(join(DATA_DIR, savedName), data)

    ctx.body = {
      success: true,
      filename: savedName,
      originalName: filename,
      size: data.length,
      type: ext === '.gif' ? 'gif' : 'video',
      url: `/api/thinking-animation/file/${encodeURIComponent(savedName)}`
    }
    return
  }

  ctx.status = 400; ctx.body = { error: 'No file found in upload' }
}

/** DELETE /api/thinking-animation — protected */
export async function resetAnimation(ctx: any) {
  if (!existsSync(DATA_DIR)) {
    ctx.body = { success: true }; return
  }
  const { readdirSync } = await import('fs')
  const files = readdirSync(DATA_DIR)
  for (const f of files) {
    try { unlinkSync(join(DATA_DIR, f)) } catch {}
  }
  ctx.body = { success: true }
}
