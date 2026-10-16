<script setup>
import { computed } from 'vue'
import {
  Play, Boxes, Camera, Copy, Pencil, Trash2, ShieldCheck, Lock, Zap
} from 'lucide-vue-next'
import { state, switchProfile, getExtensions, backupProfile, deleteProfile } from '../composables/useSketchupBridge'

const props = defineProps({
  profile: { type: Object, required: true }
})

defineEmits(['clone', 'edit'])

const busyNow = computed(() =>
  state.busy && state.busy.id === props.profile.id ? state.busy.text : '')

const kindHint = computed(() => {
  if (props.profile.id === 'main') return 'Основной профиль: текущие данные до разделения'
  if (props.profile.id === 'dev') return 'Профиль для разработки расширений dn1sup'
  if (props.profile.id === 'drafting') return 'Профиль для проектной работы'
  return ''
})

function fmtDate(ts) {
  if (!ts) return '—'
  const d = new Date(ts * 1000)
  return d.toLocaleDateString('ru-RU') + ' ' + d.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' })
}
</script>

<template>
  <div class="sp-card p-4 flex flex-col gap-3"
       :class="profile.is_active ? 'sp-card-active' : 'hover:border-brand-300 dark:hover:border-brand-800'">
    <div class="flex items-start gap-2">
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 flex-wrap">
          <span class="font-semibold text-[15px] truncate">{{ profile.name }}</span>
          <span class="sp-id-badge">{{ profile.id }}</span>
          <span v-if="profile.is_active"
                class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-semibold uppercase tracking-wide bg-brand-500 text-white">
            <Zap class="w-3 h-3" /> активен
          </span>
          <span v-if="profile.protected" :title="'Защищённый профиль — удаление запрещено'"
                class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium bg-slate-100 dark:bg-slate-800 text-slate-500 dark:text-slate-400 border border-slate-200 dark:border-slate-700">
            <Lock class="w-3 h-3" /> защищён
          </span>
        </div>
        <p class="mt-1 text-[13px] text-slate-500 dark:text-slate-400 leading-snug">
          {{ profile.description || kindHint }}
        </p>
      </div>
      <ShieldCheck v-if="profile.id === 'main'" class="w-5 h-5 text-brand-400 shrink-0" />
    </div>

    <div class="flex items-center gap-3 text-[12px] text-slate-500 dark:text-slate-400">
      <span class="inline-flex items-center gap-1"><Boxes class="w-3.5 h-3.5" />
        {{ profile.extensions_count == null ? '…' : profile.extensions_count + ' расширений' }}</span>
      <span>запуск: {{ fmtDate(profile.last_launch) }}</span>
    </div>

    <div v-if="busyNow" class="text-[12px] text-brand-500 dark:text-brand-400">{{ busyNow }}</div>

    <div class="flex flex-wrap gap-1.5 mt-auto pt-1">
      <button v-if="!profile.is_active" class="sp-btn-primary !px-2.5" @click="switchProfile(profile.id, profile.name)">
        <Play class="w-4 h-4" /> Запустить
      </button>
      <button class="sp-btn-ghost !px-2.5" @click="getExtensions(profile.id)">
        <Boxes class="w-4 h-4" /> Расширения
      </button>
      <button class="sp-btn-ghost !px-2.5" title="Снимок-резервная копия (zip)"
              @click="backupProfile(profile.id)">
        <Camera class="w-4 h-4" /> Снимок
      </button>
      <button class="sp-btn-ghost !px-2.5" title="Клонировать профиль" @click="$emit('clone', profile)">
        <Copy class="w-4 h-4" />
      </button>
      <button class="sp-btn-ghost !px-2.5" title="Переименовать / описание" @click="$emit('edit', profile)">
        <Pencil class="w-4 h-4" />
      </button>
      <button v-if="!profile.protected && !profile.is_active" class="sp-btn-danger !px-2.5" title="Удалить профиль"
              @click="deleteProfile(profile.id, profile.name)">
        <Trash2 class="w-4 h-4" />
      </button>
    </div>
  </div>
</template>
