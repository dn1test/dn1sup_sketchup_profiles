import { reactive } from 'vue'
import { applyMockAction, mockPayload } from '../mocks'

/**
 * Мост Ruby ↔ JS (единый паттерн с dn1sup_ext_manager / dn1sup_save_settings):
 *  — JS → Ruby: sketchup.call_ruby(name, param) — один экшен-колбэк 'call_ruby';
 *  — Ruby → JS: window.pushState(state) и window.pushResult(kind, payload).
 *
 * Вне SketchUp (npm run dev в браузере) включается mock-режим.
 */

function getSketchup() {
  if (typeof sketchup !== 'undefined' && sketchup && typeof sketchup.call_ruby === 'function') {
    return sketchup
  }
  if (typeof window !== 'undefined' && window.sketchup && typeof window.sketchup.call_ruby === 'function') {
    return window.sketchup
  }
  return null
}

const isMock = !getSketchup()

// -- общее состояние UI ---------------------------------------------------------

const state = reactive({
  ready: false,
  view: 'profiles',            // 'profiles' | 'extensions' | 'backups'
  data: null,                  // pushState payload: profiles, active_profile, initialized…
  selectedProfile: null,       // id профиля на экране расширений
  extensions: [],
  extensionsLoading: false,
  backups: [],
  busy: null,                  // { id, action, text }
  toast: null,                 // { kind: 'ok'|'err'|'info', text }
  quitting: false
})

let toastTimer = null
function toast(kind, text, ms = 5000) {
  state.toast = { kind, text }
  if (toastTimer) clearTimeout(toastTimer)
  toastTimer = setTimeout(() => { state.toast = null }, ms)
}

function clearBusy(id) {
  if (state.busy && (!id || state.busy.id === id)) state.busy = null
}

function setBusy(id, action, text) {
  state.busy = { id, action, text }
}

// -- обработчики пушей Ruby (регистрируются до монтирования Vue) ------------------

if (typeof window !== 'undefined') {
  window.pushState = function (payload) {
    if (!payload) return
    state.ready = true
    state.data = payload
    if (payload.job_result) {
      const jr = payload.job_result
      if (jr.ok) toast('ok', `Хелпер завершил: ${(jr.phases || []).join(' → ') || 'готово'}`)
      else toast('err', `Хелпер прервался: ${jr.error || 'неизвестная ошибка'} (фазы: ${(jr.phases || []).join(' → ')})`, 9000)
    }
    clearBusy(null)
  }
  window.pushResult = function (kind, payload) {
    emitResult(kind, payload || {})
  }
}

function emitResult(kind, payload) {
  if (kind === 'error') {
    clearBusy(null)
    toast('err', payload.message || 'Ошибка Ruby', 8000)
    return
  }
  if (kind === 'action_result') {
    clearBusy(payload.id)
    if (payload.ok) {
      toast('ok', payload.message || 'Операция успешно завершена!')
    } else {
      toast('err', payload.error || 'Произошла ошибка при выполнении операции.', 8000)
    }
    return
  }
  if (kind === 'extensions') {
    state.selectedProfile = payload.profile
    state.extensions = payload.items || []
    state.extensionsLoading = false
    return
  }
  if (kind === 'backups') {
    state.backups = payload.items || []
    return
  }
  if (kind === 'quitting') {
    state.quitting = true
    if (payload.message) toast('info', payload.message, 30000)
  }
}

// -- вызовы Ruby --------------------------------------------------------------------

function callRuby(name, param) {
  const bridge = getSketchup()
  if (bridge) {
    try {
      bridge.call_ruby(name, param === undefined ? '' : String(param))
      return true
    } catch (e) {
      console.warn('callRuby error:', e)
    }
  }
  return false
}

function callRubyJson(name, obj) {
  return callRuby(name, JSON.stringify(obj || {}))
}

export function loadState() {
  if (isMock) {
    setTimeout(() => window.pushState(mockPayload()), 150)
    return
  }
  callRuby('ready')
  setTimeout(() => {
    if (!state.ready) callRuby('ready')
  }, 350)
}

export function getExtensions(profileId) {
  state.selectedProfile = profileId
  state.extensions = []
  state.extensionsLoading = true
  if (isMock) {
    applyMockAction('get_extensions', { profile: profileId })
    return
  }
  callRubyJson('get_extensions', { profile: profileId })
}

export function getBackups() {
  if (isMock) {
    applyMockAction('get_backups', {})
    return
  }
  callRuby('get_backups')
}

export function beginMigration(createIds) {
  if (isMock) {
    applyMockAction('begin_migration', { create: createIds })
    return
  }
  callRubyJson('begin_migration', { create: createIds })
}

export function switchProfile(id, name) {
  setBusy(id, 'switch', `Переключение на «${name}»…`)
  if (isMock) {
    applyMockAction('switch_profile', { id })
    return
  }
  callRubyJson('switch_profile', { id })
}

export function createProfile(payload) {
  setBusy(payload.id, 'create', 'Создание профиля (копирование)…')
  if (isMock) {
    applyMockAction('create_profile', payload)
    return
  }
  callRubyJson('create_profile', payload)
}

export function renameProfile(payload) {
  setBusy(payload.id, 'rename', 'Сохранение…')
  if (isMock) {
    applyMockAction('rename_profile', payload)
    return
  }
  callRubyJson('rename_profile', payload)
}

export function deleteProfile(id, name) {
  setBusy(id, 'delete', `Удаление «${name}»…`)
  if (isMock) {
    applyMockAction('delete_profile', { id })
    return
  }
  callRubyJson('delete_profile', { id })
}

export function installRbz(profileId, profileName) {
  setBusy(profileId, 'install', `Установка .rbz в «${profileName}»…`)
  if (isMock) {
    applyMockAction('install_rbz', { profile: profileId })
    return
  }
  callRubyJson('install_rbz', { profile: profileId })
}

export function uninstallExtension(profileId, extId) {
  setBusy(extId, 'uninstall', `Удаление «${extId}»…`)
  if (isMock) {
    applyMockAction('uninstall_extension', { profile: profileId, ext: extId })
    return
  }
  callRubyJson('uninstall_extension', { profile: profileId, ext: extId })
}

export function backupProfile(id) {
  setBusy(id, 'backup', 'Создание снимка…')
  if (isMock) {
    applyMockAction('backup_profile', { id })
    return
  }
  callRubyJson('backup_profile', { id })
}

export function restoreBackup(id, file) {
  setBusy(id, 'restore', 'Восстановление из снимка…')
  if (isMock) {
    applyMockAction('restore_backup', { id, file })
    return
  }
  callRubyJson('restore_backup', { id, file })
}

export function deleteBackup(file) {
  if (isMock) {
    applyMockAction('delete_backup', { file })
    return
  }
  callRubyJson('delete_backup', { file })
}

export function syncSelf() {
  setBusy('sync', 'sync', 'Синхронизация менеджера в профили…')
  if (isMock) {
    applyMockAction('sync_self', {})
    return
  }
  callRuby('sync_self')
}

export { state, isMock, toast, clearBusy, setBusy }
