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
  busy: null,                  // { id, action, text } — подпись на карточке
  task: null,                  // { action, id, text, phase, phases } — блокирующий оверлей
  confirm: null,               // { token, action, text } — подтверждение в окне
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

// -- блокирующий оверлей задачи -----------------------------------------------------

let progressTimer = null

function stopProgressPolling() {
  if (progressTimer) {
    clearTimeout(progressTimer)
    progressTimer = null
  }
}

function clearTask() {
  state.task = null
  stopProgressPolling()
}

// Ruby ведёт оверлей: task-пуш при старте, фазы — ответами на get_progress
// (опрос 500 мс, Sketchup API только на главном потоке), снятие —
// action_result/error. Закрытие диалога не отменяет операцию: при новом
// pushState с busy_task оверлей восстанавливается.
function setTask(task) {
  if (!task || !task.action) return
  stopProgressPolling()
  state.task = { phase: null, phases: [], ...task }
  const poll = () => {
    progressTimer = setTimeout(() => {
      if (!state.task) return
      callRubyJson('get_progress', {})
      poll()
    }, 500)
  }
  poll()
}

function applyProgress(payload) {
  if (!state.task || !payload || !payload.action) return
  if (payload.action && state.task.action && payload.action !== state.task.action) return
  state.task.phase = payload.current || null
  state.task.phases = payload.phases || state.task.phases
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
    if (payload.busy_task && payload.busy_task.action) {
      if (!state.task || state.task.action !== payload.busy_task.action) setTask(payload.busy_task)
    }
    else if (state.task) clearTask()
    clearBusy(null)
  }
  window.pushResult = function (kind, payload) {
    emitResult(kind, payload || {})
  }
}

function emitResult(kind, payload) {
  if (kind === 'error') {
    clearBusy(null)
    clearTask()
    toast('err', payload.message || 'Ошибка Ruby', 8000)
    return
  }
  if (kind === 'action_result') {
    clearBusy(payload.id)
    clearTask()
    if (payload.ok) {
      toast('ok', payload.message || 'Операция успешно завершена!')
    } else {
      toast('err', payload.error || 'Произошла ошибка при выполнении операции.', 8000)
    }
    return
  }
  if (kind === 'task') {
    setTask(payload)
    return
  }
  if (kind === 'progress') {
    applyProgress(payload)
    return
  }
  if (kind === 'confirm') {
    state.confirm = payload
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

// Подтверждение внутри диалога: Ruby прислал 'confirm' с токеном, ответ —
// confirm_answer с тем же токеном (да/нет).
export function answerConfirm(token, yes) {
  state.confirm = null
  if (!token) return
  callRubyJson('confirm_answer', { token, yes: !!yes })
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

// Подтверждаемые операции (delete/uninstall/restore) оверлей не включают до
// самого подтверждения — Ruby ведёт его после confirm_answer.
export function deleteProfile(id, name) {
  if (isMock) {
    setBusy(id, 'delete', `Удаление «${name}»…`)
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
  if (isMock) {
    setBusy(extId, 'uninstall', `Удаление «${extId}»…`)
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
  if (isMock) {
    setBusy(id, 'restore', 'Восстановление из снимка…')
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

// Проверка обновления: сначала локальная папка разработки, потом GitHub.
export function checkUpdate() {
  if (isMock) {
    toast('ok', 'Проверка обновлений (mock): актуальная версия')
    return
  }
  callRuby('check_update')
}

export { state, isMock, toast, clearBusy, setBusy, clearTask }
