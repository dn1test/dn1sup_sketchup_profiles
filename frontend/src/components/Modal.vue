<script setup>
import { X } from 'lucide-vue-next'

defineProps({
  open: { type: Boolean, default: false },
  title: { type: String, default: '' },
  maxWidth: { type: String, default: 'max-w-md' },
  // Ограничение высоты содержимого; замена дефолта позволяет окну быть выше
  bodyClass: { type: String, default: 'max-h-[60vh]' }
})
defineEmits(['close'])
</script>

<template>
  <div v-if="open" class="fixed inset-0 z-50 flex items-center justify-center p-4">
    <div class="absolute inset-0 bg-slate-900/50 dark:bg-black/60" @click="$emit('close')"></div>
    <div
      class="relative w-full rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 shadow-2xl"
      :class="maxWidth"
    >
      <header class="flex items-center justify-between px-4 py-3 border-b border-slate-200 dark:border-slate-700">
        <h3 class="text-sm font-semibold">{{ title }}</h3>
        <button
          class="p-1 rounded-lg text-slate-400 hover:text-slate-600 dark:hover:text-slate-200 hover:bg-slate-100 dark:hover:bg-slate-800"
          @click="$emit('close')"
        >
          <X :size="16" />
        </button>
      </header>
      <div class="px-4 py-3 text-sm overflow-y-auto" :class="bodyClass">
        <slot />
      </div>
      <footer
        v-if="$slots.footer"
        class="flex items-center justify-end gap-2 px-4 py-3 border-t border-slate-200 dark:border-slate-700"
      >
        <slot name="footer" />
      </footer>
    </div>
  </div>
</template>
