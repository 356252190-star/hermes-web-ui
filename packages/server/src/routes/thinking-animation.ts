import Router from '@koa/router'
import * as ctrl from '../controllers/thinking-animation'

export const thinkingAnimationPublicRoutes = new Router()
export const thinkingAnimationProtectedRoutes = new Router()

// Public routes (needed for <img>/<video> src)
thinkingAnimationPublicRoutes.get('/api/thinking-animation/status', ctrl.getStatus)
thinkingAnimationPublicRoutes.get('/api/thinking-animation/file/:filename', ctrl.getFile)

// Protected routes (require auth)
thinkingAnimationProtectedRoutes.post('/api/thinking-animation/upload', ctrl.upload)
thinkingAnimationProtectedRoutes.delete('/api/thinking-animation', ctrl.reset)
