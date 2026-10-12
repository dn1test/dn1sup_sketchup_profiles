<script setup>
import { computed } from 'vue'
import {
  PackagePlus, Trash2, RefreshCw, Puzzle, FlaskConical, Boxes, Sparkles, FileCode
} from 'lucide-vue-next'
import {
  state, installRbz, uninstallExtension, getExtensions
} from '../composables/useSketchupBridge'

const props = defineProps({
  profile: { type: Object, required: true }
})

const items = computed(() => state.extensions)

const busyNow = computed(() =>
  state.busy && (state.busy.id === props.profile.id || state.busy.action === 'uninstall' || state.busy.action === 'install')
    ? state.busy.text : '')

const kindMeta = {
  self:     { label: 'менеджер', cls: 'bg-brand-100 dark:bg-brand-900/50 text-brand-700 dark:text-brand-300', icon: Sparkles },
  dn1sup:   { label: 'dn1sup', cls: 'bg-indigo-100 dark:bg-indigo-900/50 text-indigo-700 dark:text-indigo-300', icon: Puzzle },
  dev:      { label: 'dev', cls: 'bg-amber-100 dark:bg-amber-900/50 text-amber-700 dark:text-amber-300', icon: FlaskConical },
  third_party: { label: 'стороннее', cls: 'bg-slate-100 dark:bg-slate-800 text-slate-600 dark:text-slate-400', icon: Boxes }
}

function meta(kind) {
  return kindMeta[kind] || kindMeta.third_party
}
</script>

<template>
  <div class="flex flex-col gap-3 min-h-0 flex-1">
    <div class="flex flex-wrap items-center gap-2">
      <button class="sp-btn-primary" @click="installRbz(profile.id, profile.name)">
        <PackagePlus class="w-4 h-4" /> Установить .rbz…
      </button>
      <button class="sp-btn-ghost" @click="getExtensions(profile.id)">
        <RefreshCw class="w-4 h-4" /> Обновить
      </button>
      <div class="flex-1"></div>
      <span v-if="profile.is_active" class="text-[12px] text-amber-600 dark:text-amber-400">
        Установленное в активный профиль загрузится после перезапуска SketchUp
      </span>
    </div>

    <div v-if="busyNow" class="text-[12px] text-brand-500 dark:text-brand-400">{{ busyNow }}</div>

    <div class="flex-1 min-h-0 overflow-y-auto rounded-xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900/60">
      <div v-if="state.extensionsLoading" class="p-6 text-center text-sm text-slate-400">Загрузка…</div>
      <div v-else-if="items.length === 0" class="p-6 text-center text-sm text-slate-400">
        В профиле нет расширений
      </div>
      <div v-else class="divide-y divide-slate-100 dark:divide-slate-800/70">
        <div v-for="ext in items" :key="ext.id" class="sp-row group">
          <component :is="meta(ext.kind).icon" class="w-4 h-4 shrink-0 text-slate-400" />
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2 flex-wrap">
              <span class="text-sm font-medium truncate">{{ ext.name }}</span>
              <span v-if="ext.version" class="text-[11px] font-mono text-slate-400">v{{ ext.version }}</span>
              <span class="px-1.5 py-0.5 rounded text-[10px] font-semibold" :class="meta(ext.kind).cls">
                {{ meta(ext.kind).label }}
              </span>
              <span v-if="!ext.has_rb" title="Только папка, без регистратора .rb" class="text-[10px] text-slate-400 inline-flex items-center gap-0.5">
                <FileCode class="w-3 h-3" /> без .rb
              </span>
            </div>
            <div class="text-[11px] font-mono text-slate-400 truncate">{{ ext.id }}</div>
          </div>
          <button v-if="ext.kind !== 'self'"
                  class="sp-btn-danger !px-2 opacity-0 group-hover:opacity-100 transition-opacity"
                  :title="`Удалить «${ext.id}» из профиля`"
                  @click="uninstallExtension(profile.id, ext.id)">
            <Trash2 class="w-4 h-4" />
          </button>
          <span v-else class="text-[10px] text-slate-400 pr-1">нужен для переключения</span>
        </div>
      </div>
    </div>
  </div>
</template>
