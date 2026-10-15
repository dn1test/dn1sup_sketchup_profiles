# =============================================================================
# su_profiles_helper.ps1 — внешний помощник менеджера профилей SketchUp (v2).
#
# Схема v2: реальный каталог Plugins НЕ является junction (SketchUp 2026 не
# регистрирует расширения через junction-пути). Вместо этого:
#   - *.rb-регистраторы в Plugins — реальные копии из хранилища профиля;
#   - папки расширений — NTFS-junction на profiles\<id>\Plugins\<ext>;
#   - SharedPreferences.json / PrivatePreferences.json (настройки интерфейса)
#     — реальные файлы, свапаются копированием при переключении.
#
# Запускается расширением dn1sup_sketchup_profiles СКРЫТО перед закрытием
# SketchUp. Все решения и пути — в job-файле (JSON):
#   kind=migrate: содержимое реального Plugins переносится в хранилище
#     «Основного» (.rb — копия обратно, папки — junction на месте), настройки
#     копируются в Prefs, создаются профили-клоны (robocopy с фильтром);
#   kind=switch: сохранение .rb+настроек уходящего профиля, очистка Plugins
#     (файлы удалить, junction-ы снять), наполнение из целевого, свап настроек.
#
# Прогресс — в pending_job.result.json (по фазам), журнал — в logs\.
# Совместим с Windows PowerShell 5.1. Файл обязан быть в UTF-8 с BOM.
#
# Ручной запуск (отладка): powershell -File su_profiles_helper.ps1 -JobPath <job.json>
# =============================================================================

param(
  [Parameter(Mandatory = $true)]
  [string]$JobPath
)

$ErrorActionPreference = 'Stop'

# ---- job / журналы -------------------------------------------------------------

if (-not (Test-Path -LiteralPath $JobPath -PathType Leaf)) {
  Write-Output "job-файл не найден: $JobPath"
  exit 1
}
$job = Get-Content -LiteralPath $JobPath -Raw -Encoding UTF8 | ConvertFrom-Json

$storeRoot = [string]$job.store_root
$logDir = Join-Path $storeRoot 'logs'
$resultPath = Join-Path $storeRoot 'pending_job.result.json'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir ("helper-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

$phases = New-Object System.Collections.ArrayList

function Write-Log([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  $line | Out-File -FilePath $log -Append -Encoding UTF8
}

# JSON на диск в UTF-8 БЕЗ BOM (Ruby JSON.parse не ест BOM).
function Write-JsonNoBom([string]$Path, $Object) {
  $json = $Object | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Save-Result([string]$Mode, [string]$ErrorText = '') {
  # $Mode: 'progress' | 'ok' | 'error'
  $res = [ordered]@{
    kind        = [string]$job.kind
    target      = [string]$job.target_profile
    phases      = @($phases)
    finished_at = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  }
  if ($Mode -eq 'ok') { $res.ok = $true }
  elseif ($Mode -eq 'error') { $res.ok = $false; $res.error = $ErrorText }
  else { $res.in_progress = $true }
  Write-JsonNoBom $resultPath $res
}

function Set-Prop($Object, [string]$Name, $Value) {
  if ($Object.PSObject.Properties[$Name]) {
    $Object.$Name = $Value
  } else {
    $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
  }
}

# ---- примитивы -------------------------------------------------------------------

function Test-Junction([string]$Path) {
  if (-not (Test-Reparse $Path)) { return $false }
  try { return ((Get-Item -LiteralPath $Path -Force).LinkType -eq 'Junction') } catch { return $false }
}

# Reparse-point детект, работает и для ВИСЯЧЕГО junction (Test-Path/Get-Item
# за отсутствующей целью дают $false): атрибут ReparsePoint читается по самой
# записи, цель не нужна.
function Test-Reparse([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  try {
    $attr = [System.IO.File]::GetAttributes($Path)
    return (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
  } catch { return $false }
}

function Remove-Junction([string]$Path) {
  [System.IO.Directory]::Delete($Path, $false)
}

function New-Junction([string]$Point, [string]$Target) {
  New-Item -ItemType Junction -Path $Point -Target $Target | Out-Null
}

function Copy-Tree([string]$Src, [string]$Dst, [string[]]$ExcludeNames = @()) {
  $Src = [string]$Src -replace '/', '\'
  $Dst = [string]$Dst -replace '/', '\'
  if (-not (Test-Path -LiteralPath $Src -PathType Container)) { return }
  New-Item -ItemType Directory -Force -Path $Dst | Out-Null
  $dirs = @(); $files = @()
  foreach ($n in $ExcludeNames) {
    if ([string]::IsNullOrWhiteSpace($n)) { continue }
    if (Test-Path -LiteralPath (Join-Path $Src $n) -PathType Leaf) { $files += $n } else { $dirs += $n }
  }
  $rcArgs = @($Src, $Dst, '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
  if ($dirs.Count -gt 0)  { $rcArgs += @('/XD'); $rcArgs += $dirs }
  if ($files.Count -gt 0) { $rcArgs += @('/XF'); $rcArgs += $files }
  Write-Log ("robocopy: {0} -> {1} | XD={2} XF={3}" -f $Src, $Dst, ($dirs -join ','), ($files -join ','))
  & robocopy.exe @rcArgs | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy $Src -> $Dst : код $LASTEXITCODE" }
}

# Удаляет элемент реального Plugins: junction снимается (оригинал живёт
# в хранилище), реальный файл/каталог удаляется насовсем. Висячий junction
# тоже снимается: Test-Reparse не ходит к цели.
function Remove-RealEntry([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  if (Test-Reparse $Path) {
    if (Test-Junction $Path) {
      Remove-Junction $Path
      return
    }
    # ReparsePoint другого типа (symlink) — снимаем тем же способом.
    [System.IO.Directory]::Delete($Path, $false)
    return
  }
  if (-not (Test-Path -LiteralPath $Path)) { return }
  if (Test-Path -LiteralPath $Path -PathType Container) {
    Remove-Item -LiteralPath $Path -Recurse -Force
  } else {
    Remove-Item -LiteralPath $Path -Force
  }
}

# Кладёт элемент хранилища профиля в реальный Plugins: .rb — копией,
# папку — junction-ом на хранилище.
function Mirror-Item([string]$StoreDir, [string]$Name) {
  $src = Join-Path $StoreDir $Name
  $dst = Join-Path ([string]$job.real_plugins) $Name
  if (Test-Path -LiteralPath $src -PathType Leaf) {
    Remove-RealEntry $dst
    Copy-Item -LiteralPath $src -Destination $dst -Force
  } elseif (Test-Path -LiteralPath $src -PathType Container) {
    Remove-RealEntry $dst
    New-Junction $dst $src
  }
}

# ---- исполнение -------------------------------------------------------------------

# Защита от параллельного запуска: два хелпера на одном job-файле ломают
# result.json и дублируют перенос. Второй экземпляр тихо выходит.
$helperMutex = New-Object System.Threading.Mutex($false, 'Global\dn1sup_sketchup_profiles_helper')
if (-not $helperMutex.WaitOne(0)) {
  Write-Output 'другой экземпляр хелпера уже работает — выходим'
  exit 0
}

try {
  Write-Log ("start kind={0} target={1}" -f $job.kind, $job.target_profile)

  # 1. Ждём выхода SketchUp (PID из job — это процесс, запустивший хелпер).
  $waitPid = [int]$job.wait_pid
  if ($waitPid -gt 0) {
    $timeout = [int]$job.wait_timeout_sec
    if ($timeout -le 0) { $timeout = 300 }
    $deadline = (Get-Date).AddSeconds($timeout)
    while (Get-Process -Id $waitPid -ErrorAction SilentlyContinue) {
      if ((Get-Date) -gt $deadline) { throw "таймаут ожидания выхода SketchUp (pid $waitPid, ${timeout}s)" }
      Start-Sleep -Milliseconds 500
    }
    Write-Log "sketchup pid $waitPid вышел"
    [void]$phases.Add('waited')
    Save-Result 'progress'
  }

  # 2. Другой запущенный экземпляр SketchUp делает переключение небезопасным
  #    (strict_solo отключают только песочные тесты хелпера).
  if ([bool]$job.strict_solo) {
    $others = @(Get-Process -Name SketchUp -ErrorAction SilentlyContinue)
    if ($others.Count -gt 0) {
      throw ("обнаружен другой запущенный SketchUp (pid {0}) — переключение отменено, закройте все экземпляры" -f $others[0].Id)
    }
  }

  $realPlugins = [string]$job.real_plugins
  if (-not (Test-Path -LiteralPath $realPlugins -PathType Container)) {
    throw "реальный каталог Plugins не найден: $realPlugins"
  }

  if ($job.kind -eq 'migrate') {
    # 3. Перенос содержимого Plugins в хранилище «Основного»:
    #    .rb → move + копия обратно; папка → move + junction на месте.
    $mainStore = [string]$job.store_main_plugins
    New-Item -ItemType Directory -Force -Path $mainStore | Out-Null
    $entries = @(Get-ChildItem -LiteralPath $realPlugins -Force | Where-Object { -not $_.Name.StartsWith('.') })
    $movedDirs = 0; $movedFiles = 0
    foreach ($e in $entries) {
      $target = Join-Path $mainStore $e.Name
      if (Test-Path -LiteralPath $target) {
        throw "в хранилище уже есть $($e.Name) — повторная инициализация прервана"
      }
      if ($e.PSIsContainer) {
        if (Test-Junction $e.FullName) {
          # уже junction (повторный запуск) — не трогаем
          continue
        }
        Move-Item -LiteralPath $e.FullName -Destination $target
        New-Junction $e.FullName $target
        $movedDirs++
      } else {
        Move-Item -LiteralPath $e.FullName -Destination $target
        Copy-Item -LiteralPath $target -Destination $e.FullName -Force
        $movedFiles++
      }
    }
    Write-Log ("migrate: папок перенесено {0}, .rb перенесено {1}" -f $movedDirs, $movedFiles)
    [void]$phases.Add('migrated')
    Save-Result 'progress'

    # 4. Настройки интерфейса → Prefs «Основного».
    $prefsDir = [string]$job.store_main_prefs
    New-Item -ItemType Directory -Force -Path $prefsDir | Out-Null
    if (Test-Path -LiteralPath ([string]$job.prefs_roaming) -PathType Leaf) {
      Copy-Item -LiteralPath ([string]$job.prefs_roaming) -Destination (Join-Path $prefsDir 'SharedPreferences.json') -Force
    }
    if (Test-Path -LiteralPath ([string]$job.prefs_local) -PathType Leaf) {
      Copy-Item -LiteralPath ([string]$job.prefs_local) -Destination (Join-Path $prefsDir 'PrivatePreferences.json') -Force
    }
    Write-Log 'migrate: настройки скопированы в Prefs'

    # 5. Дополнительные профили-клоны (если заданы в job.create_profiles;
    #    с версии 0.4.0 инициализация их не создаёт — массив пустой,
    #    ветка оставлена для совместимости со старыми job-файлами).
    foreach ($cp in @($job.create_profiles)) {
      Copy-Tree ([string]$cp.source) ([string]$cp.target) @($cp.exclude_names)
      # настройки наследуются
      $dstPrefs = Join-Path (Split-Path -Parent ([string]$cp.target)) 'Prefs'
      New-Item -ItemType Directory -Force -Path $dstPrefs | Out-Null
      Copy-Item (Join-Path $prefsDir '*') $dstPrefs -Force -ErrorAction SilentlyContinue
      # самоинъекция менеджера (фильтр мог его вырезать)
      $selfRb = Join-Path $cp.target ([string]$job.self.rb_name)
      $selfDir = Join-Path $cp.target ([string]$job.self.dir_name)
      if (-not (Test-Path -LiteralPath $selfRb)) {
        Copy-Item -LiteralPath ([string]$job.self.rb) -Destination $selfRb -Force
      }
      if (-not (Test-Path -LiteralPath $selfDir)) {
        Copy-Item -LiteralPath ([string]$job.self.dir) -Destination $selfDir -Recurse -Force
        Remove-Item -LiteralPath (Join-Path $selfDir 'test') -Recurse -Force -ErrorAction SilentlyContinue
      }
      Write-Log ("создан профиль {0}" -f $cp.id)
    }
    if (@($job.create_profiles).Count -gt 0) { [void]$phases.Add('created'); Save-Result 'progress' }
  }
  elseif ($job.kind -eq 'switch') {
    # 3. Сохранение уходящего профиля: свежие .rb и настройки.
    if ($job.store_from_plugins -and (Test-Path -LiteralPath ([string]$job.store_from_plugins) -PathType Container)) {
      $fromStore = [string]$job.store_from_plugins
      $rbFiles = @(Get-ChildItem -LiteralPath $realPlugins -Force -File | Where-Object { $_.Name -like '*.rb' })
      foreach ($f in $rbFiles) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $fromStore $f.Name) -Force
      }
      Write-Log ("switch: сохранено .rb уходящего профиля: {0}" -f $rbFiles.Count)
    }
    if ($job.store_from_prefs) {
      $fromPrefs = [string]$job.store_from_prefs
      New-Item -ItemType Directory -Force -Path $fromPrefs | Out-Null
      if (Test-Path -LiteralPath ([string]$job.prefs_roaming) -PathType Leaf) {
        Copy-Item -LiteralPath ([string]$job.prefs_roaming) -Destination (Join-Path $fromPrefs 'SharedPreferences.json') -Force
      }
      if (Test-Path -LiteralPath ([string]$job.prefs_local) -PathType Leaf) {
        Copy-Item -LiteralPath ([string]$job.prefs_local) -Destination (Join-Path $fromPrefs 'PrivatePreferences.json') -Force
      }
    }
    [void]$phases.Add('saved')
    Save-Result 'progress'

    # 4. Очистка реального Plugins (junction-ы снимаются, оригиналы в хранилище).
    $entries = @(Get-ChildItem -LiteralPath $realPlugins -Force | Where-Object { -not $_.Name.StartsWith('.') })
    foreach ($e in $entries) { Remove-RealEntry $e.FullName }
    Write-Log ("switch: реальный Plugins очищен ({0} эл.)" -f $entries.Count)

    # 5. Наполнение из хранилища целевого профиля.
    $toStore = [string]$job.store_to_plugins
    if (-not (Test-Path -LiteralPath $toStore -PathType Container)) {
      throw "хранилище целевого профиля не найдено: $toStore"
    }
    $items = @(Get-ChildItem -LiteralPath $toStore -Force | Where-Object { -not $_.Name.StartsWith('.') })
    foreach ($i in $items) { Mirror-Item $toStore $i.Name }
    Write-Log ("switch: подключено из {0}: {1} эл." -f $toStore, $items.Count)

    # Проверка сиротских лоадеров: .rb без папки упадёт с LoadError
    # (require version/main) при старте SketchUp — только лог, без прерывания.
    foreach ($rb in @(Get-ChildItem -LiteralPath $realPlugins -Force -File | Where-Object { $_.Name -like 'dn1sup_*.rb' })) {
      $base = [System.IO.Path]::GetFileNameWithoutExtension($rb.Name)
      $storeDir = Join-Path $toStore $base
      $realDir = Join-Path $realPlugins $base
      if ((Test-Path -LiteralPath $storeDir -PathType Container) -and (-not (Test-Path -LiteralPath $realDir))) {
        Write-Log ("switch: ВНИМАНИЕ: папка {0} есть в хранилище, но не подключилась в Plugins" -f $base)
      } elseif ((-not (Test-Path -LiteralPath $storeDir)) -and (-not (Test-Path -LiteralPath $realDir))) {
        Write-Log ("switch: ВНИМАНИЕ: {0} без папки (сиротский лоадер)" -f $rb.Name)
      }
    }

    # 6. Настройки интерфейса целевого профиля.
    $toPrefs = [string]$job.store_to_prefs
    if (Test-Path -LiteralPath $toPrefs -PathType Container) {
      $sr = Join-Path $toPrefs 'SharedPreferences.json'
      $sl = Join-Path $toPrefs 'PrivatePreferences.json'
      if (Test-Path -LiteralPath $sr -PathType Leaf) { Copy-Item -LiteralPath $sr -Destination ([string]$job.prefs_roaming) -Force }
      if (Test-Path -LiteralPath $sl -PathType Leaf) { Copy-Item -LiteralPath $sl -Destination ([string]$job.prefs_local) -Force }
    }
    [void]$phases.Add('switched')
    Save-Result 'progress'
  }
  else {
    throw "неизвестный тип job: $($job.kind)"
  }

  # 7. state.json: активный профиль.
  $now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $state = New-Object System.Management.Automation.PSObject
  if (Test-Path -LiteralPath ([string]$job.state_path)) {
    try { $state = Get-Content -LiteralPath ([string]$job.state_path) -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  }
  Set-Prop $state 'store_version' 2
  Set-Prop $state 'year' ([string]$job.year)
  Set-Prop $state 'su_exe' ([string]$job.su_exe)
  Set-Prop $state 'active_profile' ([string]$job.target_profile)
  Set-Prop $state 'initialized_at' $now
  Set-Prop $state 'updated_at' $now
  Write-JsonNoBom ([string]$job.state_path) $state
  [void]$phases.Add('state')

  # 8. profiles.json: отметка запуска целевого профиля.
  $profilesPath = [string]$job.profiles_path
  if (Test-Path -LiteralPath $profilesPath) {
    try {
      $pp = Get-Content -LiteralPath $profilesPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $targetEntry = @($pp.profiles) | Where-Object { $_.id -eq [string]$job.target_profile }
      if (@($targetEntry).Count -gt 0) {
        Set-Prop $targetEntry[0] 'last_launch' $now
        Write-JsonNoBom $profilesPath $pp
      }
    } catch {
      Write-Log "profiles.json не обновлён: $_"
    }
  }

  # 9. Перезапуск SketchUp.
  if ($job.relaunch -and $job.su_exe -and (Test-Path -LiteralPath ([string]$job.su_exe) -PathType Leaf)) {
    Start-Process -FilePath ([string]$job.su_exe)
    Write-Log 'sketchup запущен'
    [void]$phases.Add('relaunched')
  } else {
    Write-Log 'перезапуск не требуется/невозможен'
  }

  [void]$phases.Add('done')
  Save-Result 'ok'
  Remove-Item -LiteralPath $JobPath -Force -ErrorAction SilentlyContinue
  Write-Log 'done'
  $helperMutex.ReleaseMutex() | Out-Null
  exit 0
}
catch {
  $msg = $_.Exception.Message
  Write-Log "ERROR: $msg"
  Save-Result 'error' $msg
  $helperMutex.ReleaseMutex() | Out-Null
  exit 1
}
