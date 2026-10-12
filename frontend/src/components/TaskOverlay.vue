<script setup>
import { computed } from 'vue'
import { Loader2 } from 'lucide-vue-next'
import { state } from '../composables/useSketchupBridge'

// Блокирующий оверлей долгой операции: идёт от Ruby (task-пуш), снимается
// action_result/error. Никаких кнопок — операции необратимы и не отменяются.
const task = computed(() => state.task)

const PHASE_LABELS = {
  check: 'проверка',
  copy: 'копирование файлов',
  mirror: 'обновление Plugins',
  delete: 'удаление файлов',
  meta: 'сохранение данных профиля',
  prefs: 'копирование настроек интерфейса',
  self: 'установка менеджера профилей',
  extract: 'распаковка архива',
  replace: 'замена данных профиля',
  zip: 'архивирование'
}

const phaseText = computed(() => {
  const raw = task.value && task.value.phase
  if (!raw) return ''
  return PHASE_LABELS[raw] || raw
})
</script>

<template>
  <div v-if="task" class="absolute inset-0 z-[90] bg-black/60 backdrop-blur-[2px]
       flex flex-col items-center justify-center gap-4 text-white cursor-default">
    <Loader2 class="w-10 h-10 animate-spin text-brand-400" />
    <div class="font-semibold text-lg">{{ task.text || 'Работаю…' }}</div>
    <div v-if="task.id" class="text-xs font-mono text-slate-300">{{ task.id }}</div>
    <div class="text-sm text-slate-200 min-h-[20px]">
      {{ phaseText || 'подготовка…' }}
    </div>
    <div class="text-[12px] text-slate-400 max-w-sm text-center">
      Окно откликнется, когда операция завершится. SketchUp не закрывайте —
      операция работает с файлами профиля, модели ничего не грозит.
    </div>
  </div>
</template>
