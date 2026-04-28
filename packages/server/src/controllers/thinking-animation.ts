import { randomBytes } from 'crypto'
import { writeFile, readFile, unlink, mkdir, readdir, stat } from 'fs/promises'
import { resolve, join, extname, basename } from 'path'
import { execFile } from 'child_process'
import { promisify } from 'util'
import { config } from '../config'

const execFileAsync = promisify(execFile)

const MAX_UPLOAD_SIZE = 100 * 1024 * 1024 // 100MB
const ALLOWED_EXTENSIONS = new Set(['.gif', '.mp4', '.webm', '.mov', '.avi', '.mkv'])
const NATIVE_EXTENSIONS = new Set(['.gif', '.mp4', '.webm'])
const ANIM_DIR = resolve(config.dataDir, 'thinking-animations')

const MIME_TYPES: Record<string, string> = {
  '.gif': 'image/gif',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
  '.mov': 'video/mp4',   // converted to mp4
  '.avi': 'video/mp4',   // converted to mp4
  '.mkv': 'video/mp4',   // converted to mp4
}

function safePath(dir: string, file: string): string {
  const resolved = resolve(dir, file)
  if (!resolved.startsWith(dir)) throw new Error('Path traversal detected')
  return resolved
}

async function ensureAnimDir() {
  await mkdir(ANIM_DIR, { recursive: true })
}

async function cleanupOldFiles() {
  try {
    const files = await readdir(ANIM_DIR)
    for (const f of files) {
      if (f === '.gitkeep') continue
      const fp = join(ANIM_DIR, f)
      await unlink(fp).catch(() => {})
    }
  } catch {}
}

async function hasFfmpeg(): Promise<boolean> {
  try {
    await execFileAsync('ffmpeg', ['-version'], { timeout: 5000 })
    return true
  } catch {
    return false
  }
}

async function convertToMp4(inputPath: string): Promise<string> {
  const outputPath = inputPath.replace(/\.[^.]+$/, '.mp4')
  await execFileAsync('ffmpeg', [
    '-i', inputPath,
    '-c:v', 'libx264', '-preset', 'fast', '-crf', '23',
    '-an', // no audio
    '-movflags', '+faststart',
    '-y', outputPath
  ], { timeout: 120000 })
  await unlink(inputPath).catch(() => {})
  return outputPath
}

function splitMultipart(raw: Buffer, boundary: Buffer): Buffer[] {
  const parts: Buffer[] = []
  let start = 0
  while (true) {
    const idx = raw.indexOf(boundary, start)
    if (idx === -1) break
    if (start > 0) {
      parts.push(raw.subarray(start + 2, idx))
    }
    start = idx + boundary.length
  }
  return parts
}

// GET /api/thinking-animation/status
export async function getStatus(ctx: any) {
  await ensureAnimDir()
  try {
    const files = await readdir(ANIM_DIR)
    const animFiles = files.filter(f => f !== '.gitkeep')
    if (animFiles.length === 0) {
      ctx.body = { hasCustom: false, filename: null }
      return
    }
    const filePath = join(ANIM_DIR, animFiles[0])
    const s = await stat(filePath)
    const ext = extname(animFiles[0]).toLowerCase()
    ctx.body = {
      hasCustom: true,
      filename: animFiles[0],
      size: s.size,
      mimeType: MIME_TYPES[ext] || 'application/octet-stream',
      url: `/api/thinking-animation/file/${encodeURIComponent(animFiles[0])}`
    }
  } catch {
    ctx.body = { hasCustom: false, filename: null }
  }
}

// GET /api/thinking-animation/file/:filename
export async function getFile(ctx: any) {
  const filename = decodeURIComponent(ctx.params.filename)
  await ensureAnimDir()
  const filePath = safePath(ANIM_DIR, filename)
  try {
    const data = await readFile(filePath)
    const ext = extname(filename).toLowerCase()
    ctx.set('Content-Type', MIME_TYPES[ext] || 'application/octet-stream')
    ctx.set('Cache-Control', 'public, max-age=3600')
    ctx.body = data
  } catch {
    ctx.status = 404
    ctx.body = { error: 'Animation file not found' }
  }
}

// POST /api/thinking-animation/upload
export async function upload(ctx: any) {
  const contentType = ctx.get('content-type') || ''
  if (!contentType.startsWith('multipart/form-data')) {
    ctx.status = 400; ctx.body = { error: 'Expected multipart/form-data' }; return
  }
  const boundary = '--' + contentType.split('boundary=')[1]
  if (!boundary || boundary === '--undefined') {
    ctx.status = 400; ctx.body = { error: 'Missing boundary' }; return
  }

  const chunks: Buffer[] = []
  let totalSize = 0
  for await (const chunk of ctx.req) {
    totalSize += chunk.length
    if (totalSize > MAX_UPLOAD_SIZE) {
      ctx.status = 413; ctx.body = { error: `File too large (max ${MAX_UPLOAD_SIZE / 1024 / 1024}MB)` }; return
    }
    chunks.push(chunk)
  }

  const raw = Buffer.concat(chunks)
  const boundaryBuf = Buffer.from(boundary)
  const parts = splitMultipart(raw, boundaryBuf)

  let filename = ''
  let fileData: Buffer | null = null

  for (const part of parts) {
    const headerEnd = part.indexOf(Buffer.from('\r\n\r\n'))
    if (headerEnd === -1) continue
    const headerBuf = part.subarray(0, headerEnd)
    const header = headerBuf.toString('utf-8')
    const data = part.subarray(headerEnd + 4, part.length - 2)

    const filenameStarMatch = header.match(/filename\*=UTF-8''(.+)/i)
    if (filenameStarMatch) {
      filename = decodeURIComponent(filenameStarMatch[1])
    } else {
      const filenameMatch = header.match(/filename="([^"]+)"/)
      if (!filenameMatch) continue
      filename = filenameMatch[1]
    }
    fileData = data
    break
  }

  if (!filename || !fileData) {
    ctx.status = 400; ctx.body = { error: 'No file provided' }; return
  }

  const ext = extname(filename).toLowerCase()
  if (!ALLOWED_EXTENSIONS.has(ext)) {
    ctx.status = 400
    ctx.body = { error: `Unsupported format. Allowed: ${[...ALLOWED_EXTENSIONS].join(', ')}` }
    return
  }

  await ensureAnimDir()
  await cleanupOldFiles()

  const savedName = randomBytes(8).toString('hex') + ext
  const savedPath = join(ANIM_DIR, savedName)
  await writeFile(savedPath, fileData)

  let finalPath = savedPath
  let finalExt = ext

  // Convert non-native formats to mp4
  if (!NATIVE_EXTENSIONS.has(ext)) {
    const ffmpegAvailable = await hasFfmpeg()
    if (!ffmpegAvailable) {
      await unlink(savedPath).catch(() => {})
      ctx.status = 400
      ctx.body = { error: `${ext} format requires ffmpeg. Install ffmpeg or use GIF/MP4/WebM.` }
      return
    }
    try {
      finalPath = await convertToMp4(savedPath)
      finalExt = '.mp4'
    } catch (err: any) {
      await unlink(savedPath).catch(() => {})
      ctx.status = 500
      ctx.body = { error: `Conversion failed: ${err.message}` }
      return
    }
  }

  const finalName = basename(finalPath)
  const s = await stat(finalPath)

  ctx.body = {
    success: true,
    filename: finalName,
    size: s.size,
    mimeType: MIME_TYPES[finalExt] || 'application/octet-stream',
    url: `/api/thinking-animation/file/${encodeURIComponent(finalName)}`
  }
}

// DELETE /api/thinking-animation
export async function reset(ctx: any) {
  await ensureAnimDir()
  try {
    const files = await readdir(ANIM_DIR)
    for (const f of files) {
      if (f === '.gitkeep') continue
      await unlink(join(ANIM_DIR, f)).catch(() => {})
    }
  } catch {}
  ctx.body = { success: true, hasCustom: false }
}
