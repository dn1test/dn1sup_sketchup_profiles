# AGENTS.md — DN1Sup SketchUp Profiles

> **ОБЯЗАТЕЛЬНО ПРОЧИТАТЬ ПЕРЕД РАБОТОЙ — общие правила каналов dev / prod**
> (dev-вариант против релизов, dev-цикл, публикация): мастер
> `U:\dn1code\sketchup_ext\AGENTS.md` — единственная полная копия правил
> (публикация: `U:\dn1code\sketchup_ext\PUBLISHING.md`).

- Расширение: `dn1sup_sketchup_profiles` / dev-вариант: `dn1sup_sketchup_profiles_dev` / имя: «DN1Sup SketchUp Profiles».
- Критичное, пока мастер не прочитан: id с суффиксом `_dev` никогда не
  публикуются; версию поднимать сразу в четырёх местах (`ext.version`
  регистратора, `VERSION` в `dn1sup_sketchup_profiles/profile_core.rb`,
  `.sketchup_dev.json`, `registry.json` — pack проверяет расхождения); релиз —
  только при зелёных тестах.
  Локальный чек-лист публикации — в `PUBLISHING.md` этого репозитория.

## Локальные правила репозитория

- **Не расширение внутри SketchUp, а расширение + внешний хелпер**:
  `dn1sup_sketchup_profiles/helper/su_profiles_helper.ps1` — единственная
  часть, работающая вне SketchUp (после его закрытия). Хелпер тупой: все пути
  и решения — в job-файле, который пишет Ruby-ядро (`profile_core.rb`).
  Правки хелпера требуют проверки `ruby test/helper_sandbox_test.rb` (Windows).
- **Тесты:** `ruby test/smoke_test.rb` (песочница, без живого SketchUp);
  `ext_test id=dn1sup_sketchup_profiles_dev` — в живом SketchUp. Оба зелёные
  перед коммитом.
- **Живые данные пользователя** (`%LOCALAPPDATA%\dn1sup_sketchup_profiles`,
  junction на `%APPDATA%\SketchUp\SketchUp <год>`) — трогать только через ядро:
  удаление junction — только после проверки, что это junction и цель внутри
  хранилища. Прямые эксперименты с боевыми папками запрещены — только песочница
  тестов.
- Сборка GUI: `cd frontend && npm run build` (Vite single-file пишет в
  `dn1sup_sketchup_profiles/html/index.html`); собранный файл коммитится.
