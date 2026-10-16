<script setup>
import { Clock3, TriangleAlert } from 'lucide-vue-next'
import { state } from '../composables/useSketchupBridge'
import Modal from './Modal.vue'

defineProps({
  open: { type: Boolean, default: false }
})
defineEmits(['close'])
</script>

<template>
  <Modal
    :open="open"
    title="Как пользоваться профилями SketchUp"
    max-width="max-w-2xl"
    body-class="max-h-[72vh]"
    @close="$emit('close')"
  >
    <div class="space-y-4 text-xs leading-relaxed text-slate-600 dark:text-slate-300">
      <section class="space-y-1">
        <h4 class="text-xs font-semibold text-slate-800 dark:text-slate-100">Что такое профиль</h4>
        <p>
          Профиль — отдельный набор расширений и настроек интерфейса SketchUp.
          Переключение профилей меняет и то, и другое сразу: SketchUp закрывается
          и перезапускается уже с выбранным профилем.
        </p>
      </section>

      <section class="space-y-1">
        <h4 class="text-xs font-semibold text-slate-800 dark:text-slate-100">Инициализация</h4>
        <p>
          Одноразовая настройка при первом запуске: текущие данные SketchUp становятся
          профилем <span class="font-semibold">«Основной»</span> — ничего не теряется.
          SketchUp закроется и перезапустится автоматически.
        </p>
      </section>

      <section class="space-y-1">
        <h4 class="text-xs font-semibold text-slate-800 dark:text-slate-100">Новый профиль</h4>
        <p>
          Кнопка <span class="font-semibold">«Новый профиль»</span> внизу окна.
          Режимы: <span class="font-semibold">на основе источника</span> — всё как в выбранном
          профиле; <span class="font-semibold">чистый</span> — только менеджер профилей,
          интерфейс с нуля. Менеджер добавляется в профиль автоматически.
        </p>
      </section>

      <section class="space-y-1">
        <h4 class="text-xs font-semibold text-slate-800 dark:text-slate-100">Переключение</h4>
        <p>
          Кнопка переключения на карточке профиля. SketchUp предложит сохранить
          несохранённые модели, закроется и откроется снова с другим профилем.
        </p>
        <p>
          Если вы изменили состояние интерфейса SketchUp (панели, тулбары) и хотите
          его сохранить, нужно хотя бы один раз перезапустить SketchUp штатно
          до переключения — иначе переключитесь со старым интерфейсом.
        </p>
        <div class="flex items-start gap-2 p-2.5 rounded-lg bg-amber-50 dark:bg-amber-950/40 text-amber-800 dark:text-amber-200 text-[11px] leading-snug">
          <TriangleAlert :size="13" class="shrink-0 mt-0.5" />
          <span>Активный профиль защищён от удаления и восстановления из снимка: сначала переключитесь на другой.</span>
        </div>
      </section>

      <section class="space-y-1">
        <h4 class="text-xs font-semibold text-slate-800 dark:text-slate-100">Расширения профиля</h4>
        <p>
          Кнопка с числом расширений на карточке открывает список расширений профиля:
          установка <span class="font-mono">.rbz</span> в профиль и удаление расширений
          действуют только на этот профиль.
        </p>
      </section>

      <section class="space-y-1">
        <h4 class="text-xs font-semibold text-slate-800 dark:text-slate-100">Снимки</h4>
        <p>
          Кнопка <span class="font-semibold">«Снимки»</span> внизу окна — zip-копии данных
          профилей (хранятся 10 последних на профиль). Снимок создаётся кнопкой
          на карточке профиля, восстановление — из списка снимков.
        </p>
        <div class="flex items-start gap-2 p-2.5 rounded-lg bg-sky-50 dark:bg-sky-950/40 text-sky-800 dark:text-sky-200 text-[11px] leading-snug">
          <Clock3 :size="13" class="shrink-0 mt-0.5" />
          <span>Восстановление заменяет содержимое профиля и тоже перезапускает SketchUp.</span>
        </div>
      </section>

      <section class="space-y-1">
        <h4 class="text-xs font-semibold text-slate-800 dark:text-slate-100">Синхронизация менеджера</h4>
        <p>
          Кнопка <span class="font-semibold">«Синхр. менеджера»</span> внизу окна копирует
          сам менеджер профилей во все профили, чтобы окно профилей открывалось из любого профиля.
        </p>
      </section>

      <section class="space-y-1">
        <h4 class="text-xs font-semibold text-slate-800 dark:text-slate-100">Где хранятся данные</h4>
        <p>
          Хранилище профилей:
          <span class="font-mono break-all text-slate-600 dark:text-slate-300">{{ state.data?.store_root || '—' }}</span>.
        </p>
      </section>
    </div>
    <template #footer>
      <button class="sp-btn-primary" @click="$emit('close')">Понятно</button>
    </template>
  </Modal>
</template>
