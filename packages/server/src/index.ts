import Koa from 'koa'
import cors from '@koa/cors'
import bodyParser from '@koa/bodyparser'
import serve from 'koa-static'
import send from 'koa-send'
import { resolve } from 'path'
import { mkdir } from 'fs/promises'
import { config } from './config'
import { hermesRoutes, setupTerminalWebSocket, proxyMiddleware } from './routes/hermes'
import { uploadRoutes } from './routes/upload'
import { webhookRoutes } from './routes/webhook'
import * as hermesCli from './services/hermes-cli'
import { getToken, authMiddleware } from './services/auth'

const app = new Koa()
const { restartGateway, startGateway, startGatewayBackground, getVersion } = hermesCli

let server: any = null
let isShuttingDown = false

// 👉 如果你有子进程，一定要存
let gatewayPid: number | null = null

export async function bootstrap() {
  await mkdir(config.uploadDir, { recursive: true })
  await mkdir(config.dataDir, { recursive: true })

  // Auth (after mkdir so data dir exists)
  const authToken = await getToken()
  if (authToken) {
    app.use(await authMiddleware(authToken))
    console.log(`🔐 Auth enabled — token: ${authToken}`)
  }

  await ensureApiServerConfig()
  await ensureGatewayRunning()

  app.use(cors({ origin: config.corsOrigins }))
  app.use(bodyParser())

  app.use(webhookRoutes.routes())
  app.use(uploadRoutes.routes())
  app.use(hermesRoutes.routes())
  app.use(proxyMiddleware)

  // health
  app.use(async (ctx, next) => {
    if (ctx.path === '/health') {
      const raw = await getVersion()
      const version = raw.split('\n')[0].replace('Hermes Agent ', '') || ''

      let gatewayOk = false
      try {
        const res = await fetch(`${config.upstream.replace(/\/$/, '')}/health`, {
          signal: AbortSignal.timeout(5000),
        })
        gatewayOk = res.ok
      } catch { }

      ctx.body = {
        status: gatewayOk ? 'ok' : 'error',
        platform: 'hermes-agent',
        version,
        gateway: gatewayOk ? 'running' : 'stopped',
      }
      return
    }
    await next()
  })

  // SPA
  const distDir = resolve(__dirname, '..', 'client')
  app.use(serve(distDir))
  app.use(async (ctx) => {
    if (!ctx.path.startsWith('/api') &&
      ctx.path !== '/health' &&
      ctx.path !== '/upload' &&
      ctx.path !== '/webhook') {
      await send(ctx, 'index.html', { root: distDir })
    }
  })

  // 🚀 启动服务
  server = app.listen(config.port, '0.0.0.0')

  // Terminal WebSocket (must be after server is created)
  setupTerminalWebSocket(server)

  server.on('listening', () => {
    console.log(`➜ Server: http://localhost:${config.port}`)
    console.log(`➜ Upstream: ${config.upstream}`)
  })

  server.on('error', (err: any) => {
    console.error('Server error:', err.message)
  })

  // 👇 绑定退出信号
  bindShutdown()
}

// ============================
// ✅ 统一关闭逻辑（核心）
// ============================
function bindShutdown() {
  const shutdown = async (signal: string) => {
    if (isShuttingDown) return
    isShuttingDown = true

    console.log(`\n[${signal}] shutting down...`)

    try {
      // ✅ 1. 关闭 HTTP server
      if (server) {
        await new Promise<void>((resolve) => {
          server.close(() => {
            console.log('✓ http server closed')
            resolve()
          })
        })
      }

      // ✅ 2. 关闭子进程（如果有）
      if (gatewayPid) {
        try {
          process.kill(gatewayPid)
          console.log(`✓ gateway process killed: ${gatewayPid}`)
        } catch { }
      }

    } catch (err) {
      console.error('shutdown error:', err)
    }

    process.exit(0)
  }

  // 👉 nodemon 专用（必须 once）
  process.once('SIGUSR2', shutdown)

  // 👉 正常退出
  process.on('SIGINT', shutdown)
  process.on('SIGTERM', shutdown)

  // 👉 防止异常退出没处理
  process.on('uncaughtException', (err) => {
    console.error('uncaughtException:', err)
    shutdown('uncaughtException')
  })

  process.on('unhandledRejection', (err) => {
    console.error('unhandledRejection:', err)
    shutdown('unhandledRejection')
  })
}

// ============================
// 你的原逻辑（基本不动）
// ============================

async function ensureApiServerConfig() {
  const { homedir } = await import('os')
  const { readFileSync, writeFileSync, existsSync, copyFileSync } = await import('fs')
  const yaml = (await import('js-yaml')).default
  const configPath = resolve(homedir(), '.hermes/config.yaml')

  const defaults: Record<string, any> = {
    enabled: true,
    host: '127.0.0.1',
    port: 8642,
    key: '',
    cors_origins: '*',
  }

  try {
    if (!existsSync(configPath)) {
      console.log('✗ config.yaml not found')
      return
    }

    const content = readFileSync(configPath, 'utf-8')
    const cfg = yaml.load(content) as any || {}

    if (!cfg.platforms) cfg.platforms = {}
    if (!cfg.platforms.api_server) cfg.platforms.api_server = {}

    cfg.platforms.api_server = defaults

    copyFileSync(configPath, configPath + '.bak')
    writeFileSync(configPath, yaml.dump(cfg), 'utf-8')

    await restartGateway()
  } catch (err: any) {
    console.error('config error:', err.message)
  }
}

async function ensureGatewayRunning() {
  const upstream = config.upstream.replace(/\/$/, '')

  try {
    const res = await fetch(`${upstream}/health`, { signal: AbortSignal.timeout(5000) })
    if (res.ok) return
  } catch { }

  console.log('⚠ Gateway not running, starting...')

  try {
    // 👉 关键：保存 PID
    gatewayPid = await startGatewayBackground()

    await new Promise(r => setTimeout(r, 3000))

    const res = await fetch(`${upstream}/health`, { signal: AbortSignal.timeout(5000) })
    if (res.ok) {
      console.log(`✓ Gateway started (PID: ${gatewayPid})`)
    }
  } catch (err: any) {
    console.error('gateway start failed:', err.message)
  }
}

bootstrap()