import Router from '@koa/router'
import { randomBytes } from 'crypto'
import { writeFile, readFile, unlink, mkdir } from 'fs/promises'
import { existsSync } from 'fs'
import { execFile } from 'child_process'
import { promisify } from 'util'
import path from 'path'
import { config } from '../../config'

const execFileAsync = promisify(execFile)

const thinkingPublicRoutes = new Router()
const thinkingProtectedRoutes = new Router()

const MAX_FILE_SIZE = 100 * 1024 * 1024 // 100MB
const ANIMATION_DIR = path.join(config.uploadDir, 'thinking-animations')

// Allowed output filenames — prevents path traversal
const ALLOWED_OUTPUT_NAMES = ['thinking-custom.mp4', 'thinking-custom.gif', 'thinking-custom.webm']

// Formats that browsers can play natively (no conversion needed)
const NATIVE_FORMATS = ['.mp4', '.gif', '.webm']
// Formats that need conversion to MP4 (requires ffmpeg)
const CONVERT_FORMATS = ['.mov', '.avi', '.mkv']

const EXT_TYPE_MAP: Record<string, string> = {
  '.mp4': 'mp4', '.gif': 'gif', '.webm': 'webm'
}

const MIME_MAP: Record<string, string> = {
  'mp4': 'video/mp4', 'gif': 'image/gif', 'webm': 'video/webm'
}

/** Check if ffmpeg is available on the system PATH (cached) */
let _ffmpegAvailable: boolean | null = null
async function isFfmpegAvailable(): Promise<boolean> {
  if (_ffmpegAvailable !== null) return _ffmpegAvailable
  try {
    await execFileAsync('ffmpeg', ['-version'], { timeout: 5000 })
    _ffmpegAvailable = true
  } catch {
    _ffmpegAvailable = false
  }
  return _ffmpegAvailable
}

async function ensureDir(dir: string) {
  if (!existsSync(dir)) {
    await mkdir(dir, { recursive: true })
  }
}

/** Validate that a resolved path stays within the allowed directory */
function safePath(dir: string, filename: string): string | null {
  const resolved = path.resolve(dir, filename)
  if (!resolved.startsWith(dir + path.sep) && resolved !== dir) return null
  return resolved
}

/** Parse multipart/form-data body without external dependencies. */
async function parseMultipartBody(
  req: NodeJS.ReadableStream,
  contentType: string
): Promise<{ fileData: Buffer; filename: string } | null> {
  const boundaryMatch = contentType.match(/boundary=(.+)/i)
  if (!boundaryMatch) return null
  const boundary = '--' + boundaryMatch[1].trim()

  const chunks: Buffer[] = []
  let totalSize = 0
  for await (const chunk of req) {
    totalSize += chunk.length
    if (totalSize > MAX_FILE_SIZE) return null
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))
  }

  const raw = Buffer.concat(chunks)
  const boundaryBuf = Buffer.from(boundary)

  const parts: Buffer[] = []
  let start = 0
  while (true) {
    const idx = raw.indexOf(boundaryBuf, start)
    if (idx === -1) break
    if (start > 0) {
      parts.push(raw.subarray(start + 2, idx))
    }
    start = idx + boundaryBuf.length
  }

  for (const part of parts) {
    const headerEnd = part.indexOf(Buffer.from('\r\n\r\n'))
    if (headerEnd === -1) continue
    const header = part.subarray(0, headerEnd).toString('utf-8')
    const data = part.subarray(headerEnd + 4, part.length - 2)

    const filenameStarMatch = header.match(/filename\*=UTF-8''(.+)/i)
    let filename = ''
    if (filenameStarMatch) {
      filename = decodeURIComponent(filenameStarMatch[1])
    } else {
      const filenameMatch = header.match(/filename="([^"]+)"/)
      if (filenameMatch) filename = filenameMatch[1]
    }
    if (!filename) continue

    return { fileData: data, filename }
  }
  return null
}

// Upload custom thinking animation
thinkingProtectedRoutes.post('/api/hermes/thinking-animation', async (ctx: any) => {
  try {
    await ensureDir(ANIMATION_DIR)

    const contentType = ctx.get('content-type') || ''
    if (!contentType.startsWith('multipart/form-data')) {
      ctx.status = 400
      ctx.body = { error: 'Expected multipart/form-data' }
      return
    }

    const parsed = await parseMultipartBody(ctx.req, contentType)
    if (!parsed || !parsed.fileData || !parsed.filename) {
      ctx.status = 400
      ctx.body = { error: 'No file uploaded' }
      return
    }

    const { fileData, filename } = parsed
    const ext = path.extname(filename).toLowerCase()
    const isNative = NATIVE_FORMATS.includes(ext)
    const needsConversion = CONVERT_FORMATS.includes(ext)

    if (!isNative && !needsConversion) {
      ctx.status = 400
      ctx.body = { error: 'Unsupported format. Use GIF, MP4, WebM, MOV, AVI, or MKV.' }
      return
    }

    // Check ffmpeg availability upfront if conversion is needed
    if (needsConversion && !(await isFfmpegAvailable())) {
      ctx.status = 400
      ctx.body = {
        error: 'ffmpeg is not installed. Install ffmpeg to convert MOV/AVI/MKV files, or use a browser-native format (GIF, MP4, WebM).'
      }
      return
    }

    // Write to temp file first
    const tempId = randomBytes(8).toString('hex')
    const tempPath = safePath(ANIMATION_DIR, `temp_${tempId}${ext}`)
    if (!tempPath) {
      ctx.status = 400
      ctx.body = { error: 'Invalid temp path' }
      return
    }
    await writeFile(tempPath, fileData)

    try {
      if (isNative) {
        // Native format — save directly, no conversion needed
        const type = EXT_TYPE_MAP[ext] || 'mp4'
        const outputName = `thinking-custom.${type}`
        const outputPath = safePath(ANIMATION_DIR, outputName)
        if (!outputPath || !ALLOWED_OUTPUT_NAMES.includes(outputName)) {
          ctx.status = 400
          ctx.body = { error: 'Invalid output filename' }
          return
        }
        // Remove other format files so only one custom animation exists
        for (const name of ALLOWED_OUTPUT_NAMES) {
          if (name !== outputName) {
            const fp = safePath(ANIMATION_DIR, name)
            if (fp && existsSync(fp)) try { await unlink(fp) } catch {}
          }
        }
        await writeFile(outputPath, fileData)
        ctx.body = {
          success: true,
          type,
          path: '/api/hermes/thinking-animation/file',
          message: `${ext.toUpperCase()} uploaded successfully (no conversion needed)`
        }
      } else {
        // Convertible format — use ffmpeg to convert to MP4
        const outputPath = safePath(ANIMATION_DIR, 'thinking-custom.mp4')
        if (!outputPath) {
          ctx.status = 400
          ctx.body = { error: 'Invalid output path' }
          return
        }
        await execFileAsync('ffmpeg', [
          '-i', tempPath,
          '-c:v', 'libx264',
          '-pix_fmt', 'yuv420p',
          '-movflags', '+faststart',
          '-y', outputPath
        ], { timeout: 60000 })

        // Remove non-MP4 custom animations after successful conversion
        for (const name of ALLOWED_OUTPUT_NAMES) {
          if (name !== 'thinking-custom.mp4') {
            const fp = safePath(ANIMATION_DIR, name)
            if (fp && existsSync(fp)) try { await unlink(fp) } catch {}
          }
        }

        ctx.body = {
          success: true,
          type: 'mp4',
          path: '/api/hermes/thinking-animation/file',
          message: `${ext.toUpperCase()} converted to MP4 successfully`
        }
      }
    } catch (err: any) {
      ctx.status = 400
      ctx.body = { error: `Video conversion failed: ${err.message}` }
    } finally {
      try { await unlink(tempPath) } catch {}
    }
  } catch (error: any) {
    console.error('Thinking animation upload error:', error)
    ctx.status = 500
    ctx.body = { error: error.message }
  }
})

// Serve custom thinking animation file
thinkingPublicRoutes.get('/api/hermes/thinking-animation/file', async (ctx: any) => {
  try {
    await ensureDir(ANIMATION_DIR)

    // Check in priority order: mp4, gif, webm
    const checkOrder: Array<[string, string]> = [
      ['thinking-custom.mp4', 'mp4'],
      ['thinking-custom.gif', 'gif'],
      ['thinking-custom.webm', 'webm']
    ]

    for (const [filename, type] of checkOrder) {
      const fp = safePath(ANIMATION_DIR, filename)
      if (fp && existsSync(fp)) {
        const data = await readFile(fp)
        ctx.set('Content-Type', MIME_MAP[type] || 'application/octet-stream')
        ctx.set('Cache-Control', 'no-cache')
        ctx.body = data
        return
      }
    }

    ctx.status = 404
    ctx.body = { error: 'No custom animation found' }
  } catch (error: any) {
    ctx.status = 500
    ctx.body = { error: error.message }
  }
})

// Delete custom thinking animation (revert to default)
thinkingProtectedRoutes.delete('/api/hermes/thinking-animation', async (ctx: any) => {
  try {
    await ensureDir(ANIMATION_DIR)

    for (const filename of ALLOWED_OUTPUT_NAMES) {
      const fp = safePath(ANIMATION_DIR, filename)
      if (fp && existsSync(fp)) await unlink(fp)
    }

    ctx.body = { success: true, message: 'Custom animation removed, using default' }
  } catch (error: any) {
    ctx.status = 500
    ctx.body = { error: error.message }
  }
})

// Check if custom thinking animation exists
thinkingPublicRoutes.get('/api/hermes/thinking-animation/status', async (ctx: any) => {
  try {
    await ensureDir(ANIMATION_DIR)

    let hasCustom = false
    let type: string | null = null

    const checkOrder: Array<[string, string]> = [
      ['thinking-custom.mp4', 'mp4'],
      ['thinking-custom.gif', 'gif'],
      ['thinking-custom.webm', 'webm']
    ]

    for (const [filename, ext] of checkOrder) {
      const fp = safePath(ANIMATION_DIR, filename)
      if (fp && existsSync(fp)) {
        hasCustom = true
        type = ext
        break
      }
    }

    ctx.body = { hasCustom, type }
  } catch (error: any) {
    ctx.status = 500
    ctx.body = { error: error.message }
  }
})

export { thinkingPublicRoutes, thinkingProtectedRoutes }
