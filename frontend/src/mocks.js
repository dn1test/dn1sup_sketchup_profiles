/**
 * Mock-режим для разработки интерфейса в браузере (npm run dev).
 * Имитирует ответы Ruby: pushState / pushResult. Демо-данные нейтральные.
 */

let mockProfiles = [
  {
    id: 'main',
    name: 'Основной',
    description: 'Все расширения и настройки на момент разделения профилей',
    is_active: true,
    protected: true,
    extensions_count: 48,
    created_at: 1760000000,
    last_launch: 1760200000
  },
  {
    id: 'training',
    name: 'Обучение',
    description: 'Чистый профиль для обучения',
    is_active: false,
    protected: false,
    extensions_count: 2,
    created_at: 1760000000,
    last_launch: null
  }
]

const mockExtensions = [
  { id: 'dn1sup_sketchup_profiles', name: 'DN1Sup SketchUp Profiles', version: '0.1.0', kind: 'self', has_rb: true, has_dir: true },
  { id: 'dn1sup_ext_manager', name: 'DN1Sup Extension Store', version: '0.11.2', kind: 'dn1sup', has_rb: true, has_dir: true },
  { id: 'curic_deep_select', name: 'Curic Deep Select', version: '', kind: 'third_party', has_rb: true, has_dir: true },
  { id: 'ladb_opencutlist', name: 'OpenCutList', version: '', kind: 'third_party', has_rb: true, has_dir: true },
  { id: 'fillet', name: 'Fillet', version: '', kind: 'third_party', has_rb: true, has_dir: false }
]

let mockBackups = [
  { file: 'main-20261010-120000.zip', profile: 'main', size: 41234567, mtime: 1760100000 },
  { file: 'training-20261009-090000.zip', profile: 'training', size: 8123456, mtime: 1760010000 }
]

export function mockPayload() {
  return {
    version: '0.1.0-mock',
    store_version: 1,
    initialized: true,
    junction_roaming: true,
    junction_local: true,
    active_profile: 'main',
    year: '2026',
    store_root: 'C:\\Users\\demo\\AppData\\Local\\dn1sup_sketchup_profiles',
    su_exe_found: true,
    profiles: mockProfiles,
    job_result: null
  }
}

function delay(fn, ms = 500) {
  setTimeout(fn, ms)
}

/** Имитация действий Ruby: пушит результат и обновляет состояние. */
export function applyMockAction(name, params = {}) {
  const { id } = params
  const item = mockProfiles.find(p => p.id === id)

  if (name === 'get_extensions') {
    delay(() => window.pushResult('extensions', { profile: params.profile, items: mockExtensions }))
    return
  }
  if (name === 'get_backups') {
    delay(() => window.pushResult('backups', { items: mockBackups }), 100)
    return
  }
  if (name === 'begin_migration' || name === 'switch_profile') {
    delay(() => {
      window.pushResult('action_result', { id, action: name, ok: true, message: 'SketchUp закрывается… (mock)' })
      window.pushResult('quitting', { message: 'Переключение профиля — SketchUp перезапустится (mock).' })
    }, 600)
    return
  }
  if (name === 'create_profile') {
    delay(() => {
      const mode = params.mode || 'clone'
      const count = mode === 'clean' ? 1 : 48
      mockProfiles.push({
        id: params.id, name: params.name || params.id, description: params.description || '',
        is_active: false, protected: false, extensions_count: count,
        created_at: Math.floor(Date.now() / 1000), last_launch: null
      })
      window.pushResult('action_result', {
        id: params.id, action: name, ok: true,
        message: mode === 'clean'
          ? `Создан чистый профиль «${params.name}» (mock).`
          : `Профиль «${params.name}» создан на основе источника (mock).`
      })
      window.pushState(mockPayload())
    }, 900)
    return
  }
  if (name === 'rename_profile') {
    delay(() => {
      if (item) { item.name = params.name; item.description = params.description }
      window.pushResult('action_result', { id, action: name, ok: true, message: 'Описание профиля обновлено (mock).' })
      window.pushState(mockPayload())
    }, 300)
    return
  }
  if (name === 'delete_profile') {
    delay(() => {
      mockProfiles = mockProfiles.filter(p => p.id !== id)
      const known = new Set(mockProfiles.map(p => p.id))
      mockBackups = mockBackups.filter(b => known.has(b.profile))
      window.pushResult('action_result', { id, action: name, ok: true, message: `Профиль удалён вместе со снимками (mock).` })
      window.pushState(mockPayload())
      window.pushResult('backups', { items: mockBackups })
    }, 600)
    return
  }
  if (name === 'install_rbz') {
    delay(() => {
      window.pushResult('action_result', {
        id: params.profile, action: name, ok: true,
        message: 'Установлено в профиль (mock): demo.rb, demo/. Профиль сохранён.'
      })
    }, 800)
    return
  }
  if (name === 'uninstall_extension') {
    delay(() => {
      window.pushResult('action_result', { id: params.ext, action: name, ok: true, message: `Расширение «${params.ext}» удалено (mock).` })
    }, 500)
    return
  }
  if (name === 'backup_profile') {
    delay(() => {
      const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 15)
      mockBackups.unshift({ file: `${id}-${stamp}.zip`, profile: id, size: 12345678, mtime: Math.floor(Date.now() / 1000) })
      window.pushResult('action_result', { id, action: name, ok: true, message: `Снимок профиля «${id}» создан (mock).` })
    }, 900)
    return
  }
  if (name === 'restore_backup') {
    delay(() => {
      window.pushResult('action_result', { id, action: name, ok: true, message: `Профиль «${id}» восстановлен (mock).` })
    }, 900)
    return
  }
  if (name === 'delete_backup') {
    delay(() => {
      mockBackups = mockBackups.filter(b => b.file !== params.file)
      window.pushResult('action_result', { id: params.file, action: name, ok: true, message: 'Снимок удалён (mock).' })
      window.pushResult('backups', { items: mockBackups })
    }, 300)
    return
  }
  if (name === 'sync_self') {
    delay(() => {
      window.pushResult('action_result', { id: 'sync', action: name, ok: true, message: 'Менеджер синхронизирован во все профили (mock).' })
    }, 700)
  }
}
