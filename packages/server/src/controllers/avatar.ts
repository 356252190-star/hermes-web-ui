import { existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync, readdirSync } from 'fs'
import { resolve, join, basename, extname } from 'path'
import { randomBytes } from 'crypto'
import { config } from '../config'

const DATA_DIR = join(config.dataDir, 'avatars')
const ALLOWED_TYPES = ['user', 'assistant']
const ALLOWED_EXTS = ['.png', '.jpg', '.jpeg', '.gif', '.webp']
const ANIMATED_EXTS = ['.gif', '.apng']
const MAX_SIZE = 5 * 1024 * 1024 // 5MB

// MIME map
const MIME_MAP: Record<string, string> = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
}

// Ensure data directory exists
if (!existsSync(DATA_DIR)) {
  mkdirSync(DATA_DIR, { recursive: true })
}

/** Resolve the avatar directory for a given profile */
function avatarDir(profile: string): string {
  // Sanitize profile name to prevent path traversal
  const safe = basename(profile)
  if (safe !== profile || safe === '.' || safe === '..') {
    throw new Error('Invalid profile name')
  }
  return join(DATA_DIR, safe)
}

/** Resolve the avatar file path */
function avatarPath(profile: string, type: string): string | null {
  if (!ALLOWED_TYPES.includes(type)) return null
  const dir = avatarDir(profile)
  // Check for any allowed extension
  for (const ext of ALLOWED_EXTS) {
    const p = join(dir, `${type}${ext}`)
    if (existsSync(p)) return p
  }
  return null
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

/** GET /api/avatar/:profile/:type — public (serving avatar images) */
export async function getAvatar(ctx: any) {
  const { profile, type } = ctx.params
  if (!ALLOWED_TYPES.includes(type)) {
    ctx.status = 400; ctx.body = { error: 'Invalid type' }; return
  }
  try {
    const filePath = avatarPath(profile, type)
    if (!filePath) {
      ctx.status = 404; ctx.body = { error: 'Not found' }; return
    }
    const ext = extname(filePath).toLowerCase()
    ctx.set('Content-Type', MIME_MAP[ext] || 'application/octet-stream')
    ctx.set('Cache-Control', 'public, max-age=86400')
    ctx.body = readFileSync(filePath)
  } catch {
    ctx.status = 400; ctx.body = { error: 'Invalid profile' }
  }
}

/** GET /api/avatar/:profile/status — public (check avatar existence) */
export async function getStatus(ctx: any) {
  const { profile } = ctx.params
  try {
    const dir = avatarDir(profile)
    const result: Record<string, { exists: boolean; url?: string }> = {}
    for (const type of ALLOWED_TYPES) {
      const filePath = avatarPath(profile, type)
      if (filePath) {
        const ext = basename(filePath)
        result[type] = { exists: true, url: `/api/avatar/${encodeURIComponent(profile)}/${type}` }
      } else {
        result[type] = { exists: false }
      }
    }
    ctx.body = result
  } catch {
    ctx.status = 400; ctx.body = { error: 'Invalid profile' }
  }
}

/** POST /api/avatar/:profile/:type — protected (upload avatar) */
export async function uploadAvatar(ctx: any) {
  const { profile, type } = ctx.params
  if (!ALLOWED_TYPES.includes(type)) {
    ctx.status = 400; ctx.body = { error: 'Invalid type' }; return
  }

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

    const ext = extname(filename).toLowerCase()
    if (!ALLOWED_EXTS.includes(ext)) {
      ctx.status = 400; ctx.body = { error: `Unsupported file type: ${ext}. Allowed: ${ALLOWED_EXTS.join(', ')}` }; return
    }

    // Ensure profile directory exists
    let dir: string
    try {
      dir = avatarDir(profile)
    } catch {
      ctx.status = 400; ctx.body = { error: 'Invalid profile name' }; return
    }
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true })

    // Delete old avatar files for this type
    for (const oldExt of ALLOWED_EXTS) {
      const oldPath = join(dir, `${type}${oldExt}`)
      if (existsSync(oldPath)) {
        try { unlinkSync(oldPath) } catch {}
      }
    }

    // Save new file
    const savedName = `${type}${ext}`
    writeFileSync(join(dir, savedName), data)

    const url = `/api/avatar/${encodeURIComponent(profile)}/${type}`
    ctx.body = {
      success: true,
      type,
      profile,
      size: data.length,
      url,
    }
    return
  }

  ctx.status = 400; ctx.body = { error: 'No file found in upload' }
}

/** DELETE /api/avatar/:profile/:type — protected (delete avatar) */
export async function deleteAvatar(ctx: any) {
  const { profile, type } = ctx.params
  if (!ALLOWED_TYPES.includes(type)) {
    ctx.status = 400; ctx.body = { error: 'Invalid type' }; return
  }

  try {
    const filePath = avatarPath(profile, type)
    if (filePath) {
      unlinkSync(filePath)
    }
    ctx.body = { success: true, type, profile }
  } catch {
    ctx.status = 400; ctx.body = { error: 'Invalid profile' }
  }
}
