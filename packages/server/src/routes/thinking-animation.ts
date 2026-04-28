import Router from '@koa/router'
import * as ctrl from '../controllers/thinking-animation'

// Public routes (no auth required) — needed for <img>/<video> src
export const thinkingAnimationPublicRoutes = new Router()
thinkingAnimationPublicRoutes.get('/api/thinking-animation/status', ctrl.getStatus)
thinkingAnimationPublicRoutes.get('/api/thinking-animation/file/:filename', ctrl.getFile)

// Protected routes (auth required)
export const thinkingAnimationProtectedRoutes = new Router()
thinkingAnimationProtectedRoutes.post('/api/thinking-animation/upload', ctrl.upload)
thinkingAnimationProtectedRoutes.delete('/api/thinking-animation', ctrl.resetAnimation)
