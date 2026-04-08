Изучил `codedash`. По сути это уже не “быстрый session picker”, а довольно широкий localhost‑продукт: браузерный дашборд + CLI, который агрегирует сессии нескольких агентов, даёт поиск, replay, live monitoring, cost analytics, convert/handoff, export/import и набор web/API действий. В README проект прямо позиционируется как “Dashboard + CLI for AI coding agent sessions”, а архитектура описывает один Node‑процесс с web UI на `localhost:3847`, API‑роутами и фронтендом на plain browser JS. ([GitHub][1])

Техническое ядро у идеи здравое: `codedash` агрегирует локальные источники Claude и Codex, читая для Claude `~/.claude/history.jsonl`, `~/.claude/projects/<PROJECT_KEY>/<SESSION_ID>.jsonl` и PID‑файлы из `~/.claude/sessions/`, а для Codex — `~/.codex/history.jsonl` и JSONL‑сессии под `~/.codex/sessions/...`. Но resume‑запуск у него жёстко собран в `openInTerminal(sessionId, tool, flags, projectDir, terminalId)`: либо `codex resume <id>`, либо `claude --resume <id>`, и единственный спецкейс по флагам — `skip-permissions`, который превращается в `--dangerously-skip-permissions` для Claude. Документированного профиля запуска с произвольными шаблонами команд там я не увидел; что явно есть — это browser‑state в `localStorage` для terminal preference, tags, theme, layout и т.п. ([GitHub][2])

При этом и сами агенты уже умеют resume нативно. У Claude Code есть `claude --continue` для последней беседы в текущей директории, `claude --resume` как picker или resume по имени/ID, preview внутри picker и фильтры вроде current directory / all projects / current branch. У Codex есть `codex resume` с picker, `codex resume --all`, `codex resume --last` и `codex resume <SESSION_ID>`; официальная документация отдельно пишет, что ID можно брать из picker, `/status` или файлов в `~/.codex/sessions/`. ([Claude API Docs][3])

Отсюда главный вывод: тебе не нужен “CodeDash, но в терминале”. Тебе нужен **terminal-native unified session switcher / launcher** для Claude Code и Codex. Не dashboard. Не analytics suite. Не session museum. А одна очень резкая штука: **найти нужную сессию за 1–3 действия и открыть её правильной командой с твоими профилями и флагами**.

---

# PRD — Unified TUI Session Switcher for Claude Code + Codex

## 1. Продуктовая формулировка

**Название:** sessy
**Репозиторий:** m0n0x41d/sessy
**Категория:** TUI session switcher / launcher.
**Основная задача:** быстро находить и возобновлять локальные сессии Claude Code и Codex из одного терминального интерфейса.

### Ключевая ценность

Пользователь не думает “в каком агенте у меня была та сессия” и не роется в двух разных picker’ах. Он открывает один TUI, видит merged‑список, ищет, смотрит session id, жмёт Enter — и получает resume через свой заранее настроенный launch profile.

---

## 2. Что продукт должен делать, а что не должен

### Должен

* Быть **нативным TUI/CLI**, без браузера и без локального web‑сервера.
* Показывать **единый список** сессий Claude Code и Codex.
* Делать акцент на **recent sessions + current repo first**.
* Делать **очень быстрый поиск** по metadata, а deep transcript search — только по запросу.
* Показывать **session id как first-class entity**: short ID в списке, full ID в preview/detail.
* Запускать resume через **конфигурируемые шаблоны команд** и профили.
* Поддерживать **FZF mode или эквивалентный backend**, но не зависеть от него жёстко.
* Быть **scriptable**: JSON/TSV/plain output для shell pipelines.

### Не должен

* Поднимать дашборд.
* Иметь heatmap, cost charts, replay timeline, “activity dashboard”, live polling как основу UX.
* Разрастаться до 5–6 агентов в v1.
* Хранить критичные настройки в browser state или случайном UI state.
* Делать “магический” launch без явного показа команды/профиля.

---

## 3. Продуктовая позиция

Это не “менеджер всех AI‑сессий”.
Это **session recall tool** для terminal power users.

Правильная ментальная модель:

* `fzf` для AI sessions
* `gh`-подобный CLI слой
* `tmux-sessionizer`, но для Claude/Codex
* минимальный, быстрый, scriptable launcher

---

## 4. Целевая аудитория

1. **Power user Claude + Codex**
   Работает в двух агентах, часто переключается между репами и сессиями.

2. **Terminal-native разработчик**
   tmux/zellij/wezterm/kitty, не хочет вылезать в браузер ради поиска и resume.

3. **Многопроектный инженер / консультант**
   У него десятки репозиториев, и стандартные picker’ы внутри каждого инструмента дают слишком узкий взгляд.

4. **Пользователь с жёсткими launch preferences**
   Хочет всегда запускать Claude с дополнительными флагами, а Codex — с профилем или иными параметрами.

---

## 5. Product thesis

`codedash` пытается быть всем сразу: search UI, monitoring UI, analytics UI, replay UI, convert UI, handoff UI. Это делает продукт шире, чем нужно. Архитектура подтверждает это: browser frontend, API, polling, deep search, replay, tags, stars, cost views и т.д. ([GitHub][2])

Твой продукт должен быть **уже, быстрее и злее**:

* один job: **find + inspect + resume**
* одна основная сущность: **session**
* один основной action: **launch selected session with correct profile**

---

## 6. Основные сценарии пользователя

| Pri | User story                                                                                | Результат                             |
| --- | ----------------------------------------------------------------------------------------- | ------------------------------------- |
| P0  | Как пользователь, я открываю TUI и сразу вижу merged recent sessions Claude и Codex       | Не думаю, где именно была сессия      |
| P0  | Как пользователь в текущем repo, я вижу сначала sessions from current repo/worktree       | Минимум шума                          |
| P0  | Как пользователь, я ищу по session id, prompt snippet, project path, tool                 | Нахожу нужную сессию за пару символов |
| P0  | Как пользователь, я вижу short ID в строке и full ID в preview                            | Могу resume/copy без догадок          |
| P0  | Как пользователь, я жму Enter и resume идёт через мой профиль запуска                     | Не повторяю флаги руками              |
| P0  | Как пользователь, я могу иметь профиль `claude.unsafe` с `--dangerously-skip-permissions` | Персональный default workflow         |
| P0  | Как пользователь, я могу сначала сделать dry-run и увидеть точную команду                 | Контроль и предсказуемость            |
| P0  | Как пользователь, я могу скопировать session id / cwd / launch command                    | Быстрые shell сценарии                |
| P1  | Как пользователь, я могу переключиться в transcript search mode                           | Ищу не только по metadata             |
| P1  | Как пользователь, я могу использовать `--ui=fzf`                                          | Сохраняю muscle memory                |
| P1  | Как пользователь, я могу фильтровать repo/current dir/all/tool/date                       | Точный scope                          |
| P1  | Как пользователь, я вижу best-effort active/running marker                                | Понимаю, что сессия ещё жива          |
| P1  | Как пользователь tmux/zellij, я могу открыть resume в split pane/new pane/current tty     | UX под мою среду                      |
| P2  | Как пользователь, я могу экспортировать handoff/summary для другой системы                | Позже, не в ядре                      |
| P2  | Как пользователь, я могу подключить дополнительные adapters                               | После стабилизации Claude/Codex       |

---

## 7. Scope v1

### In

* Claude Code
* Codex
* merged metadata index
* native TUI picker
* optional `fzf` mode
* preview pane
* configurable launch templates
* profiles
* dry-run
* JSON/plain output
* doctor/reindex/config commands

### Out

* browser UI
* dashboards
* tags/stars
* cost analytics
* session replay
* cross-agent convert
* handoff generation
* Cursor/OpenCode/Kiro adapters

---

## 8. UX spec

## 8.1 Default entry

Команда без аргументов открывает picker:

```bash
sessy
```

## 8.2 Layout

**Header**

* query
* scope: `repo | cwd | all`
* tool filter: `all | claude | codex`
* mode: `meta | deep`
* profile: active launch profile

**List row**

* running marker
* tool
* title / first prompt / display text
* short session id
* relative project path
* updated ago

**Right preview pane**

* full session id
* tool
* cwd / project root
* model (если известно)
* permission mode (если известно)
* first message
* last message snippet
* exact launch command preview

**Footer**

* `Enter` resume
* `Tab` preview toggle
* `Ctrl-Y` copy ID
* `Ctrl-O` open cwd
* `Ctrl-S` scope
* `Ctrl-T` tool filter
* `Ctrl-F` deep search
* `Ctrl-R` reload
* `?` help
* `Esc` quit

## 8.3 FZF mode

Если установлен `fzf`, можно запустить:

```bash
sessy --ui=fzf
```

Логика:

* built-in tool генерирует candidate list
* `fzf` отвечает только за selection
* preview идёт через `sessy preview --id …`

Это лучше, чем делать `fzf` обязательным: ты получаешь и standalone TUI, и режим для power users.

---

## 9. Search model

### 9.1 Search tiers

**Tier 1 — metadata search (default)**

* session id
* title/display
* first prompt
* cwd/project path
* tool
* last activity

**Tier 2 — transcript search (opt-in)**

* full message content
* lazy / indexed separately
* включается явно через toggle или флаг

### 9.2 Ranking policy

По умолчанию сортировка должна быть не “просто fuzzy”, а:

1. exact current cwd match
2. same git repo/worktree
3. active/running session
4. exact session-id prefix match
5. exact substring in title/snippet/path
6. fuzzy match
7. recency decay

Это будет лучше, чем generic dashboard search, потому что пользователь обычно хочет **то, над чем работал недавно в этом repo**, а не абстрактный full-text across everything.

### 9.3 Important product decision

У `codedash` deep search строится в памяти, на первом `/api/search` читает все detail files и кэширует результат на 60 секунд; это нормально для браузерного дашборда, но плохой default для ultra-fast picker. ([GitHub][2])

Поэтому:

* **default = metadata-first**
* **deep = opt-in**
* если потом нужен transcript search, его лучше делать через persistent local index, а не через “сканировать всё при первом поиске”

---

## 10. Launch engine

Это самый важный кусок продукта.

## 10.1 Core principle

Не хардкодить `claude --resume {{id}}` и `codex resume {{id}}` в коде, как делает `codedash`; вынести launch в **declarative templates + profiles**. Сейчас у `codedash` resume-команда строится прямо в функции `openInTerminal`, и отдельным спецкейсом туда вшит только `--dangerously-skip-permissions`. ([GitHub][4])

## 10.2 Execution modes

* `spawn` — запустить child process в текущем tty после выхода из TUI
* `exec` — заменить текущий процесс
* `print` — только вывести команду
* `tmux-split` / `zellij-pane` / `wezterm-tab` — интеграции позже

## 10.3 Template placeholders

* `{{id}}`
* `{{tool}}`
* `{{cwd}}`
* `{{project}}`
* `{{title}}`
* `{{profile}}`

If a launch template references `{{profile}}`, sessy must either expand it from the selected profile or fail launch assembly explicitly. It must never pass the literal placeholder through to the spawned argv.

## 10.4 Config example

```toml
[ui]
mode = "tui"
scope = "repo"
preview = true
profile = "fast"

[sources.claude]
history = "~/.claude/history.jsonl"
projects = "~/.claude/projects"
sessions = "~/.claude/sessions"

[sources.codex]
history = "~/.codex/history.jsonl"
sessions = "~/.codex/sessions"

[launch.claude]
argv = ["claude", "--resume", "{{id}}"]
cwd_policy = "session"
exec_mode = "spawn"

[launch.codex]
argv = ["codex", "resume", "{{id}}"]
cwd_policy = "session"
exec_mode = "spawn"

[profiles.claude.unsafe]
extends = "claude"
argv_append = ["--dangerously-skip-permissions"]

[profiles.codex.fast]
extends = "codex"
argv_append = ["--profile", "fast"]
```

## 10.5 Product rule

Команда должна собираться как `argv`, а не как сырая shell string, чтобы не словить quoting/escaping-ад. Shell-template mode можно оставить, но только как advanced opt-in.

---

## 11. Native tool alignment

Важно не воевать с нативными возможностями самих агентов.

Claude уже поддерживает `--continue`, `--resume`, session names, preview/search в picker и permission settings через `defaultMode` / `--permission-mode`; Codex уже поддерживает `resume`, `resume --last`, `resume --all`, resume по `SESSION_ID`, user/project `config.toml` и profile-scoped overrides. Поэтому твой инструмент должен быть **launcher/switcher above native tools**, а не заменой их внутренней логики. ([Claude API Docs][3])

Практически это означает:

* использовать native fast path там, где он уже есть
* `last` для Claude можно мапить на `claude --continue`
* `last` для Codex — на `codex resume --last`
* profiles твоего инструмента должны быть additive, не ломать нативные конфиги

---

## 12. Data adapters

В v1 я бы зафиксировал такой подход:

### Claude adapter

* primary shortlist source: `~/.claude/history.jsonl`
* lazy hydrate: `~/.claude/projects/<PROJECT_KEY>/<SESSION_ID>.jsonl`
* optional active snapshot: `~/.claude/sessions/<SESSION_ID>.json`

### Codex adapter

* primary shortlist source: `~/.codex/history.jsonl`
* lazy hydrate: `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-...jsonl`

Именно так эти источники сейчас агрегирует `codedash`; у Codex официальная документация ещё и прямо указывает, что session ID можно брать из файлов под `~/.codex/sessions/`. ([GitHub][2])

Но в PRD надо записать важное ограничение:
**это adapter defaults, а не вечная истина**. Пути и форматы должны быть overrideable через config, потому что upstream storage format может меняться.

---

## 13. File-based config instead of browser state

В `codedash` documented persistent UI state живёт в `localStorage` браузера: terminal preference, tags, theme, layout и т.д. Для TUI это неверная модель; у тебя всё, что влияет на поведение запуска и поиска, должно жить в обычном конфиге пользователя и опционально в project override. ([GitHub][2])

### Конфиг-слои

1. built-in defaults
2. user config
3. project config
4. selected profile (`[ui].profile`)
5. CLI flags

---

## 14. CLI surface

Минимальный набор:

```bash
sessy                 # open TUI picker
sessy --ui=fzf        # fzf backend
sessy last            # fastest path to latest relevant session
sessy resume <id>     # direct resume by session id
sessy list            # list sessions
sessy list --json     # machine-readable output
sessy preview <id>    # preview detail
sessy doctor          # validate sources/config/adapters
sessy reindex         # rebuild cache/index
sessy config edit     # open config
```

---

## 15. Non-functional requirements

* cold start: very fast
* no browser
* no server
* no network
* read-only by default
* preview lazy-loaded
* metadata search instant
* stable on large session history
* cross-platform: macOS/Linux first, Windows later if needed
* one binary distribution

---

## 16. Release plan

| Phase    | What ships                                                                                                                                              |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P0 / MVP | Claude + Codex adapters, native TUI, repo-first ranking, full/short session IDs, preview pane, launch templates, profiles, dry-run, JSON output, doctor |
| P1       | `fzf` backend, deep transcript search, active markers, tmux/zellij integration, project overrides                                                       |
| P2       | handoff/export, optional conversion, plugin adapter API for more tools                                                                                  |
| P3       | only if core stays sharp: notes/bookmarks/history actions                                                                                               |

---

## 17. Why this will be better than CodeDash

Не потому, что “TUI вместо web”.
А потому, что продукт будет **уже и точнее**.

**CodeDash-путь:** session management как dashboard problem.
**Твой путь:** session recall как terminal workflow problem.

Из этого следуют правильные продуктовые решения:

* metadata-first instead of dashboard-first
* launch profiles instead of hardcoded commands
* config file instead of browser state
* repo-first ranking instead of generic all-sessions grid
* zero daemon/server instead of localhost app
* one dominant action (resume) instead of десяток вторичных поверхностей

Если делать именно так, получится не “ещё один просмотрщик сессий”, а реально полезный инструмент, который будет жить в ежедневном shell workflow.

---

## 18. Короткая жёсткая формулировка продукта

**Это должен быть не dashboard, а session switcher.**
**Не analytics, а recall + resume.**
**Не browser app, а native TUI with optional fzf backend.**
**Не hardcoded launcher, а profile-driven command engine.**

[1]: https://github.com/vakovalskii/codedash "GitHub - vakovalskii/codedash: Termius-style browser dashboard for Claude Code & Codex sessions. View, search, resume, tag, and manage all your AI coding sessions. · GitHub"
[2]: https://github.com/vakovalskii/codedash/blob/main/docs/ARCHITECTURE.md "codedash/docs/ARCHITECTURE.md at main · vakovalskii/codedash · GitHub"
[3]: https://docs.anthropic.com/en/docs/claude-code/tutorials "Common workflows - Claude Code Docs"
[4]: https://github.com/vakovalskii/codedash/blob/main/src/terminals.js "codedash/src/terminals.js at main · vakovalskii/codedash · GitHub"
