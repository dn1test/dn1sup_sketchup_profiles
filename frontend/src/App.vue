<script setup>
import { computed, onMounted, ref } from 'vue'
import {
  Layers, RefreshCw, DatabaseBackup, UserPlus, Share2, ArrowLeft, X,
  CheckCircle2, AlertTriangle, Info, HardDriveDownload, FolderOpen, Rocket, Loader2
} from 'lucide-vue-next'
import {
  state, loadState, beginMigration, getBackups, restoreBackup, deleteBackup,
  syncSelf, createProfile, renameProfile, isMock, toast
} from './composables/useSketchupBridge'
import { isValidId, slugify, uniqueId } from './id_slug'
import ProfileCard from './components/ProfileCard.vue'
import ExtensionsPanel from './components/ExtensionsPanel.vue'

onMounted(loadState)

const data = computed(() => state.data)
const profiles = computed(() => (data.value && data.value.profiles) || [])
const activeProfile = computed(() =>
  profiles.value.find(p => p.id === (data.value && data.value.active_profile)))
const selectedProfile = computed(() =>
  profiles.value.find(p => p.id === state.selectedProfile))

// -- экран инициализации ----------------------------------------------------------

const createDev = ref(true)
const createDrafting = ref(true)

function onBeginMigration() {
  const ids = []
  if (createDev.value) ids.push('dev')
  if (createDrafting.value) ids.push('drafting')
  beginMigration(ids)
}

// -- форма нового/редактируемого профиля --------------------------------------------

const showForm = ref(false)
const form = ref({ id: '', name: '', description: '', source: '', mode: 'empty', editing: null })
const idTouched = ref(false)
const idValidNow = () => isValidId(form.value.id.trim().toLowerCase())

function openCreateForm(cloneFrom = null) {
  form.value = {
    id: '',
    name: cloneFrom ? cloneFrom.name + ' (копия)' : '',
    description: cloneFrom ? cloneFrom.description : '',
    source: cloneFrom ? cloneFrom.id : (data.value.active_profile || 'main'),
    mode: cloneFrom ? 'clone' : 'empty',
    editing: null
  }
  idTouched.value = false
  showForm.value = true
}

function openEditForm(profile) {
  form.value = {
    id: profile.id, name: profile.name, description: profile.description,
    source: '', mode: 'clone', editing: profile.id
  }
  idTouched.value = true
  showForm.value = true
}

// id заполняется сам из названия, пока пользователь не начал править его руками
function onNameInput() {
  if (!idTouched.value) form.value.id = slugify(form.value.name)
}

function onManualId() {
  idTouched.value = form.value.id.trim().length > 0
}

const canSubmit = () => form.value.editing ||
  !!idValidNow() || !!slugify(form.value.id || form.value.name)

function submitForm() {
  if (form.value.editing) {
    renameProfile({ id: form.value.id, name: form.value.name, description: form.value.description })
    showForm.value = false
    return
  }
  // Ручной валидный id оставляем как есть (проверит ядро, «уже существует» —
  // понятно из тоста); кириллицу/мусор — транслитерацией из названия.
  const rawId = form.value.id.trim().toLowerCase()
  const manual = isValidId(rawId)
  let id = manual ? rawId : slugify(rawId || form.value.name)
  if (!id) {
    toast('err', 'Не удалось составить идентификатор. Нужны строчные латинские буквы, цифры и _ (до 32 символов), первый — буква. Например: training.', 9000)
    return
  }
  if (!manual) {
    // автосгенерированный не должен молча перезаписать существующий профиль
    id = uniqueId(id, profiles.value.map((p) => p.id))
  }
  const filters = form.value.mode === 'dn1sup'
    ? { include: ['dn1sup_*'], exclude: [] }
    : form.value.mode === 'no_dn1sup'
      ? { include: [], exclude: ['dn1sup_*', 'dn1c_*'] }
      : { include: [], exclude: [] }
  createProfile({
    id,
    name: form.value.name.trim() || id,
    description: form.value.description.trim(),
    source: form.value.source,
    ...filters
  })
  showForm.value = false
}

// -- снимки ---------------------------------------------------------------------------

function fmtSize(bytes) {
  if (bytes == null) return '—'
  if (bytes > 1024 * 1024) return (bytes / 1024 / 1024).toFixed(1) + ' МБ'
  if (bytes > 1024) return (bytes / 1024).toFixed(0) + ' КБ'
  return bytes + ' Б'
}

function fmtDate(ts) {
  if (!ts) return ''
  const d = new Date(ts * 1000)
  return d.toLocaleDateString('ru-RU') + ' ' + d.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' })
}

function openBackups() {
  state.view = 'backups'
  getBackups()
}

function backupProfileOf(file) {
  return profiles.value.find(p => p.id === file.profile)
}

function backToProfiles() {
  state.view = 'profiles'
  state.selectedProfile = null
  state.extensions = []
}
</script>

<template>
  <div class="h-full flex flex-col">
    <!-- Шапка -->
    <header class="flex items-center gap-3 px-4 py-3 border-b border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900/80">
      <div class="w-9 h-9 rounded-xl bg-brand-500 text-white flex items-center justify-center shrink-0">
        <Layers class="w-5 h-5" />
      </div>
      <div class="min-w-0">
        <div class="font-semibold leading-tight">Профили SketchUp</div>
        <div class="text-[11px] text-slate-400 leading-tight">
          DN1Sup · v{{ data?.version || '…' }}{{ isMock ? ' · mock' : '' }}
          <template v-if="data?.initialized">
            · SketchUp {{ data.year }} · активен: {{ activeProfile?.name || '—' }}
          </template>
        </div>
      </div>
      <div class="flex-1"></div>
      <button v-if="state.view !== 'profiles'" class="sp-btn-ghost" @click="backToProfiles">
        <ArrowLeft class="w-4 h-4" /> Профили
      </button>
      <template v-else-if="data?.initialized">
        <button class="sp-btn-ghost" title="Снимки-резервные копии профилей" @click="openBackups">
          <DatabaseBackup class="w-4 h-4" /> Снимки
        </button>
        <button class="sp-btn-ghost" title="Скопировать менеджер профилей во все профили"
                :disabled="state.busy?.action === 'sync'" @click="syncSelf">
          <Share2 class="w-4 h-4" /> Синхр. менеджера
        </button>
        <button class="sp-btn-primary" @click="openCreateForm()">
          <UserPlus class="w-4 h-4" /> Новый профиль
        </button>
      </template>
      <button class="sp-btn-ghost" title="Обновить" @click="loadState">
        <RefreshCw class="w-4 h-4" :class="{ 'animate-spin': !state.ready }" />
      </button>
    </header>

    <!-- Контент -->
    <main class="flex-1 min-h-0 overflow-y-auto p-4">
      <!-- Не инициализировано: мастер -->
      <div v-if="!data" class="h-full flex items-center justify-center text-slate-400">
        <Loader2 class="w-6 h-6 animate-spin" />
      </div>

      <div v-else-if="!data.initialized" class="max-w-2xl mx-auto pt-4">
        <div class="sp-card p-6 flex flex-col gap-4">
          <div class="flex items-center gap-3">
            <div class="w-10 h-10 rounded-xl bg-brand-100 dark:bg-brand-900/60 text-brand-600 dark:text-brand-300 flex items-center justify-center">
              <Rocket class="w-5 h-5" />
            </div>
            <div>
              <div class="font-semibold text-lg leading-tight">Инициализация профилей</div>
              <div class="text-[12px] text-slate-400">одноразовая настройка, данные не теряются</div>
            </div>
          </div>

          <p class="text-sm text-slate-600 dark:text-slate-300 leading-relaxed">
            Профиль — отдельный набор расширений и настроек интерфейса SketchUp.
            Текущие данные станут профилем <b>«Основной»</b>: они переедут в хранилище
            профилей, а SketchUp будет подключать их как раньше — для него ничего
            не изменится. Затем можно создавать другие профили и переключаться между
            ними (SketchUp перезапускается автоматически).
          </p>

          <div class="rounded-xl border border-slate-200 dark:border-slate-800 p-4 flex flex-col gap-2.5 text-sm">
            <label class="flex items-start gap-2.5 cursor-pointer">
              <input type="checkbox" v-model="createDev" class="mt-0.5 accent-brand-500" />
              <span>
                <b>Разработка</b> — сразу создать профиль с расширениями
                <span class="sp-id-badge">dn1sup_*</span> (прод + dev) и MCP-мостом
              </span>
            </label>
            <label class="flex items-start gap-2.5 cursor-pointer">
              <input type="checkbox" v-model="createDrafting" class="mt-0.5 accent-brand-500" />
              <span>
                <b>Черчение</b> — сразу создать профиль для проектной работы:
                рабочий набор сторонних расширений, без <span class="sp-id-badge">dn1sup_*</span> и dev-вариантов
              </span>
            </label>
            <p class="text-[12px] text-slate-400">
              Оба профиля наследуют настройки интерфейса «Основного»; создать их
              можно и позже кнопкой «Новый профиль».
            </p>
          </div>

          <div class="text-[12px] text-slate-400 flex items-start gap-1.5">
            <HardDriveDownload class="w-4 h-4 shrink-0 mt-px" />
            <span>Хранилище: <span class="font-mono">{{ data.store_root }}</span><br>
            SketchUp {{ data.year }} закроется и перезапустится автоматически.</span>
          </div>

          <div v-if="!data.su_exe_found" class="text-[12px] text-amber-600 dark:text-amber-400 flex items-center gap-1.5">
            <AlertTriangle class="w-4 h-4" /> Не найден SketchUp.exe — перезапуск придётся выполнить вручную.
          </div>

          <button class="sp-btn-primary self-start !px-4 !py-2" :disabled="state.quitting" @click="onBeginMigration">
            <Rocket class="w-4 h-4" /> Инициализировать профили
          </button>
        </div>
      </div>

      <!-- Профили -->
      <div v-else-if="state.view === 'profiles'" class="grid gap-3 [grid-template-columns:repeat(auto-fill,minmax(300px,1fr))]">
        <ProfileCard v-for="p in profiles" :key="p.id" :profile="p"
                     @clone="openCreateForm" @edit="openEditForm" />
        <button class="sp-card p-4 min-h-[150px] flex flex-col items-center justify-center gap-2
                       text-slate-400 hover:text-brand-500 hover:border-brand-300 dark:hover:border-brand-800
                       border-dashed !border-2 transition-colors"
                @click="openCreateForm()">
          <UserPlus class="w-6 h-6" />
          <span class="text-sm font-medium">Новый профиль</span>
          <span class="text-[11px]">с нуля, клон или с фильтром расширений</span>
        </button>
      </div>

      <!-- Расширения профиля -->
      <div v-else-if="state.view === 'extensions'" class="h-full flex flex-col min-h-0">
        <div class="flex items-center gap-2 pb-3 flex-wrap">
          <span class="text-[15px] font-semibold">Расширения</span>
          <span class="text-slate-400">·</span>
          <span class="text-[15px]">{{ selectedProfile?.name || state.selectedProfile }}</span>
          <span v-if="selectedProfile?.is_active" class="px-1.5 py-0.5 rounded text-[10px] font-semibold uppercase bg-brand-500 text-white">активен</span>
          <span class="sp-id-badge">{{ state.selectedProfile }}</span>
        </div>
        <ExtensionsPanel :profile="selectedProfile || { id: state.selectedProfile, name: state.selectedProfile, is_active: false }" />
      </div>

      <!-- Снимки -->
      <div v-else-if="state.view === 'backups'" class="max-w-3xl mx-auto flex flex-col gap-3">
        <div class="flex items-center gap-2">
          <span class="text-[15px] font-semibold">Снимки профилей</span>
          <span class="text-[12px] text-slate-400">(zip-копии Roaming + Local, хранятся 10 последних на профиль)</span>
        </div>
        <div class="sp-card divide-y divide-slate-100 dark:divide-slate-800/70">
          <div v-if="state.backups.length === 0" class="p-6 text-center text-sm text-slate-400">
            Снимков ещё нет — создайте их кнопкой «Снимок» на карточке профиля
          </div>
          <div v-for="b in state.backups" :key="b.file" class="sp-row">
            <DatabaseBackup class="w-4 h-4 text-slate-400 shrink-0" />
            <div class="flex-1 min-w-0">
              <div class="text-sm font-mono truncate">{{ b.file }}</div>
              <div class="text-[11px] text-slate-400">{{ fmtSize(b.size) }} · {{ fmtDate(b.mtime) }}</div>
            </div>
            <button class="sp-btn-ghost !px-2" title="Восстановить профиль из снимка"
                    :disabled="backupProfileOf(b)?.is_active"
                    @click="restoreBackup(b.profile, b.file)">
              <FolderOpen class="w-4 h-4" />
            </button>
            <button class="sp-btn-danger !px-2" title="Удалить снимок" @click="deleteBackup(b.file)">
              <X class="w-4 h-4" />
            </button>
          </div>
        </div>
        <p v-if="state.backups.some(b => backupProfileOf(b)?.is_active)" class="text-[12px] text-slate-400">
          Восстановление недоступно для снимков активного профиля: сначала переключитесь на другой профиль.
        </p>
      </div>
    </main>

    <!-- Статус-бар -->
    <footer v-if="data?.initialized" class="px-4 py-1.5 border-t border-slate-200 dark:border-slate-800
                 bg-white dark:bg-slate-900/80 text-[11px] text-slate-400 flex items-center gap-3">
      <span class="font-mono truncate" :title="data.store_root">{{ data.store_root }}</span>
      <span v-if="!data.junction_roaming || !data.junction_local" class="text-red-500 inline-flex items-center gap-1">
        <AlertTriangle class="w-3.5 h-3.5" />
        junction {{ !data.junction_roaming ? 'roaming ' : '' }}{{ !data.junction_local ? 'local' : '' }} не подключен
      </span>
      <span v-if="!data.su_exe_found" class="text-amber-500">SketchUp.exe не найден — автоперезапуск невозможен</span>
    </footer>

    <!-- Модальная форма профиля -->
    <div v-if="showForm" class="absolute inset-0 bg-black/40 backdrop-blur-[2px] flex items-center justify-center p-6 z-50" @click.self="showForm = false">
      <div class="sp-card w-full max-w-md p-5 flex flex-col gap-3 !bg-white dark:!bg-slate-900 shadow-2xl">
        <div class="font-semibold">{{ form.editing ? 'Профиль — описание' : 'Новый профиль' }}</div>

        <template v-if="!form.editing">
          <label class="flex flex-col gap-1">
            <span class="sp-label">идентификатор (латиница, цифры, _ — для папки)</span>
            <input v-model="form.id" class="sp-input font-mono" placeholder="обучение → obuchenie" spellcheck="false"
                   @input="onManualId" />
            <span class="text-[10px]" :class="idValidNow() ? 'text-green-600 dark:text-green-400' : 'text-slate-400'">
              {{ idValidNow()
                ? '✓ ' + form.id.trim().toLowerCase()
                : 'заполнится сам из названия; свой вариант — строчными латинскими, до 32 символов' }}
            </span>
          </label>
          <label class="flex flex-col gap-1">
            <span class="sp-label">название</span>
            <input v-model="form.name" class="sp-input" placeholder="Например: Обучение" @input="onNameInput" />
          </label>
          <label class="flex flex-col gap-1">
            <span class="sp-label">описание</span>
            <textarea v-model="form.description" rows="2" class="sp-input resize-none"></textarea>
          </label>
          <label class="flex flex-col gap-1">
            <span class="sp-label">источник (наследует настройки интерфейса)</span>
            <select v-model="form.source" class="sp-input">
              <option v-for="p in profiles" :key="p.id" :value="p.id">{{ p.name }} ({{ p.id }})</option>
            </select>
          </label>
          <div class="flex flex-col gap-1">
            <span class="sp-label">какие расширения копировать из источника</span>
            <label class="flex items-center gap-2 text-sm cursor-pointer">
              <input type="radio" value="clone" v-model="form.mode" class="accent-brand-500" /> все, как в источнике
            </label>
            <label class="flex items-center gap-2 text-sm cursor-pointer">
              <input type="radio" value="dn1sup" v-model="form.mode" class="accent-brand-500" /> только dn1sup_*
            </label>
            <label class="flex items-center gap-2 text-sm cursor-pointer">
              <input type="radio" value="no_dn1sup" v-model="form.mode" class="accent-brand-500" /> всё, кроме dn1sup_*/dn1c_*
            </label>
            <label class="flex items-center gap-2 text-sm cursor-pointer">
              <input type="radio" value="empty" v-model="form.mode" class="accent-brand-500" /> без расширений (пустой)
            </label>
          </div>
          <p class="text-[11px] text-slate-400">Менеджер профилей добавляется в профиль автоматически.</p>
        </template>
        <template v-else>
          <label class="flex flex-col gap-1">
            <span class="sp-label">название</span>
            <input v-model="form.name" class="sp-input" />
          </label>
          <label class="flex flex-col gap-1">
            <span class="sp-label">описание</span>
            <textarea v-model="form.description" rows="2" class="sp-input resize-none"></textarea>
          </label>
        </template>

        <div class="flex justify-end gap-2 pt-1">
          <button class="sp-btn-ghost" @click="showForm = false">Отмена</button>
          <button class="sp-btn-primary" :disabled="!canSubmit()" @click="submitForm">
            {{ form.editing ? 'Сохранить' : 'Создать (копирование)' }}
          </button>
        </div>
      </div>
    </div>

    <!-- Оверлей закрытия SketchUp -->
    <div v-if="state.quitting" class="absolute inset-0 bg-black/60 backdrop-blur-sm flex flex-col items-center justify-center gap-3 z-[60] text-white">
      <Loader2 class="w-8 h-8 animate-spin text-brand-400" />
      <div class="font-semibold">SketchUp закрывается…</div>
      <div class="text-sm text-slate-300 max-w-sm text-center">
        Хелпер переключит профиль и перезапустит SketchUp автоматически.
        Если окно SketchUp закрылось, а новое не открылось — смотрите лог в
        <span class="font-mono text-slate-200">…\dn1sup_sketchup_profiles\logs\</span>
      </div>
    </div>

    <!-- Тосты -->
    <div class="absolute bottom-8 right-4 z-[70] flex flex-col gap-2 max-w-[420px]">
      <div v-if="state.toast" class="flex items-start gap-2 px-3.5 py-2.5 rounded-xl shadow-lg text-sm
           border" :class="{
        'bg-green-50 dark:bg-green-950/70 border-green-200 dark:border-green-900 text-green-800 dark:text-green-200': state.toast.kind === 'ok',
        'bg-red-50 dark:bg-red-950/70 border-red-200 dark:border-red-900 text-red-800 dark:text-red-200': state.toast.kind === 'err',
        'bg-blue-50 dark:bg-blue-950/70 border-blue-200 dark:border-blue-900 text-blue-800 dark:text-blue-200': state.toast.kind === 'info'
      }">
        <CheckCircle2 v-if="state.toast.kind === 'ok'" class="w-4 h-4 mt-0.5 shrink-0" />
        <AlertTriangle v-else-if="state.toast.kind === 'err'" class="w-4 h-4 mt-0.5 shrink-0" />
        <Info v-else class="w-4 h-4 mt-0.5 shrink-0" />
        <span>{{ state.toast.text }}</span>
      </div>
    </div>
  </div>
</template>
