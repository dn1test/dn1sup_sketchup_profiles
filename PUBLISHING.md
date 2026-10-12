# Публикация расширения на GitHub

> Полная общая инструкция — мастер `U:\dn1code\sketchup_ext\PUBLISHING.md`
> (единственная полная копия: как Store ищет репозитории, обязательные
> требования, registry.json, версии и changelog, релизы). Ниже — локальный
> чек-лист этого репозитория.

## Чек-лист этого репозитория

| Требование | Статус |
|---|---|
| Имя `dn1sup_*` в аккаунте `dn1test` | ✅ `dn1test/dn1sup_sketchup_profiles` |
| Не archived | ✅ |
| `registry.json` в корне `main` | ✅ (id, name, repo, version) |
| Стабильные релизы с `<id>.rbz` | ✅ `dist/dn1sup_sketchup_profiles-<ver>.rbz` через CI |
| Теги `vMAJOR.MINOR.PATCH` | ✅ (workflow на `v*`) |
| Регистратор `<id>.rb` + `ext.id` | ✅ `dn1sup_sketchup_profiles.rb` в корне |
| Тело релиза из CHANGELOG.md | ✅ `tools/release_body.rb` + `body_path` |
