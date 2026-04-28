import Router from '@koa/router'
import * as ctrl from '../controllers/avatar'

// Public routes (no auth required) — needed for <img src>
export const avatarPublicRoutes = new Router()
avatarPublicRoutes.get('/api/avatar/:profile/status', ctrl.getStatus)
avatarPublicRoutes.get('/api/avatar/:profile/:type', ctrl.getAvatar)

// Protected routes (auth required)
export const avatarProtectedRoutes = new Router()
avatarProtectedRoutes.post('/api/avatar/:profile/:type', ctrl.uploadAvatar)
avatarProtectedRoutes.delete('/api/avatar/:profile/:type', ctrl.deleteAvatar)
