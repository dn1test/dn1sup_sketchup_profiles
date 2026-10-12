/**
 * Идентификатор профиля: латиница строчная/цифры/_, первый символ — буква,
 * до 32 символов (правило PROFILE_ID_RE в profile_core.rb).
 *
 * slugify переводит произвольный текст (в т.ч. русский) в такой id:
 * кириллица — транслитом, пробелы/дефисы — в _, остальное выкидывается.
 * Возвращает '' если осмысленный id собрать не удалось.
 */

const MAP = {
  а: 'a', б: 'b', в: 'v', г: 'g', д: 'd', е: 'e', ё: 'e', ж: 'zh', з: 'z',
  и: 'i', й: 'y', к: 'k', л: 'l', м: 'm', н: 'n', о: 'o', п: 'p', р: 'r',
  с: 's', т: 't', у: 'u', ф: 'f', х: 'h', ц: 'c', ч: 'ch', ш: 'sh',
  щ: 'sch', ъ: '', ы: 'y', ь: '', э: 'e', ю: 'yu', я: 'ya',
  і: 'i', ї: 'yi', є: 'e', ґ: 'g'
}

export const ID_RE = /^[a-z][a-z0-9_]{0,31}$/

export function isValidId(id) {
  return ID_RE.test(String(id || ''))
}

export function slugify(text) {
  const mapped = String(text || '')
    .toLowerCase()
    .split('')
    .map((ch) => {
      if (Object.prototype.hasOwnProperty.call(MAP, ch)) return MAP[ch]
      if (ch >= 'a' && ch <= 'z') return ch
      if (ch >= '0' && ch <= '9') return ch
      if (ch === ' ' || ch === '-' || ch === '.') return '_'
      return ''
    })
    .join('')
  let id = mapped.replace(/_+/g, '_').replace(/^_+|_+$/g, '').slice(0, 32)
  if (id && !/^[a-z]/.test(id)) {
    id = 'p' + id.slice(id[0] === '_' ? 1 : 0, 31) // первый символ — буква
  }
  return ID_RE.test(id) ? id : ''
}

/** Если предложенный id занят — подбирает свободный суффиксом _2, _3, … */
export function uniqueId(id, takenIds) {
  const taken = new Set(takenIds)
  if (!taken.has(id)) return id
  for (let n = 2; n < 100; n++) {
    const candidate = `${id}_${n}`
    if (candidate.length <= 32 && !taken.has(candidate)) return candidate
  }
  return ''
}
