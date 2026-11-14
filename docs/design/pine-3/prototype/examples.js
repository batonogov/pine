/* Three developer workflows. All commands and check records are simulated. */
"use strict";

(() => {
  const projects = {
    go: {
      name: "Harbor", kind: "Go · CLI", avatar: "go", avatarClass: "go-avatar",
      subtitle: "Инструменты для разработчика", task: "Фильтр больших файлов",
      title: "Нужные файлы. Без лишнего вывода.",
      description: "Добавлен --min-size и потоковый JSON. Результат можно проверить на фиксированном дереве файлов.",
      action: "Запустить пример", questionTask: "Символические ссылки", workingTask: "Отмена сканирования",
      question: "Переходить по символическим ссылкам?",
      questionText: "Ссылка может вести за пределы выбранной директории. От этого зависит, какие файлы попадут в результат.",
      options: ["Не переходить по ссылкам", "Добавить явный флаг --follow"],
      optionDetails: ["Предсказуемый результат в пределах выбранного дерева.", "Расширить поведение только для явно заданного флага."],
      workingTitle: "Останавливать обход по Ctrl+C.",
      workingDescription: "Проверяем, что отмена не оставляет обход и запись JSON в фоне.",
      secondaryResult: "Отмена прекращает обход.",
      secondaryDetail: "Контекст отмены передаётся в обход. При прерывании команда завершается с отдельным кодом, а поток вывода закрывается.",
      refinement: "Пример исправления: включить файлы размером ровно 10 MiB. Граничный тест теперь проходит.",
      placeholder: "Например: файл ровно 10 MiB тоже должен попадать в результат",
      command: "go run ./cmd/harbor scan ./testdata/tree --min-size 10MiB --json",
      checkSummary: "18 тестов · race detector · ревью",
      checks: [
        ["go test ./...", "18 тестов: фильтр, пустое дерево, JSON и ошибки чтения."],
        ["go test -race ./...", "Пример завершённого запуска без обнаруженных гонок."],
        ["go vet ./...", "Статический анализ изменённого пакета."],
        ["Независимое ревью", "Проверены граница размера, отмена и работа с путями."],
      ],
      files: ["cmd/harbor/scan.go", "internal/scan/filter.go", "internal/scan/filter_test.go"],
      code: `// internal/scan/filter.go — фрагмент реализации
func Accept(size, minSize int64) bool {
    return size > minSize
}

// cmd/harbor/scan.go — обработка потока
encoder := json.NewEncoder(out)
err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
    if err != nil {
        return err
    }
    if err := ctx.Err(); err != nil {
        return err
    }
    if entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
        return nil
    }
    info, err := entry.Info()
    if err != nil {
        return err
    }
    if !scan.Accept(info.Size(), minSize) {
        return nil
    }
    return encoder.Encode(Result{Path: path, Bytes: info.Size()})
})`,
      test: `// internal/scan/filter_test.go
func TestAcceptIncludesBoundary(t *testing.T) {
    const min = int64(10 * 1024 * 1024)
    tests := []struct {
        name string
        size int64
        want bool
    }{
        {"below", min - 1, false},
        {"equal", min, true},
        {"above", min + 1, true},
    }
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            if got := Accept(tt.size, min); got != tt.want {
                t.Fatalf("Accept(%d) = %v; want %v", tt.size, got, tt.want)
            }
        })
    }
}`,
      diff: `internal/scan/filter.go

− return size > minSize
+ return size >= minSize

internal/scan/filter_test.go

+ {"equal", min, true},

До исправления
FAIL TestAcceptIncludesBoundary/equal
  Accept(10485760) = false; want true

После исправления
PASS TestAcceptIncludesBoundary
ok   harbor/internal/scan`,
      beforeTitle: "Граница исключалась",
      beforeText: "Файл ровно 10 MiB не попадал в результат. Успешные старые тесты не покрывали этот случай.",
      afterTitle: "Граница включена",
      afterText: "Сравнение стало включающим. Отдельный regression test проверяет размер ниже, на границе и выше порога.",
      beforeCode: "Accept(10 * MiB, 10 * MiB)\n→ false",
      afterCode: "Accept(10 * MiB, 10 * MiB)\n→ true",
      limitation: "Проверки на фикстуре не доказывают производительность на многомиллионном дереве. Benchmark вне этого примера.",
    },
    python: {
      name: "Lumen", kind: "Python · Data", avatar: "L", avatarClass: "python-avatar",
      subtitle: "Данные, которым можно доверять", task: "Выручка без дублей",
      title: "Одна продажа. Один раз в отчёте.",
      description: "CSV → валидация → дедупликация → недельная выручка. Код, данные и проверка результата в одной задаче.",
      action: "Повторить на примере", questionTask: "Возвраты в отчёте", workingTask: "Проверка входной схемы",
      question: "Как учитывать возвраты?",
      questionText: "В исходном экспорте возвраты идут отдельными строками. Нужно выбрать смысл показателя перед изменением расчёта.",
      options: ["Вычитать из выручки", "Показывать отдельным показателем"],
      optionDetails: ["Отчёт показывает net revenue.", "Продажи и возвраты видны отдельно."],
      workingTitle: "Понятная ошибка вместо неверного отчёта.",
      workingDescription: "Проверяем отсутствующие столбцы, валюту и некорректные значения денежных сумм.",
      secondaryResult: "Неполные данные не дают готовый отчёт.",
      secondaryDetail: "Ошибка содержит имя столбца и номер строки. Проверки отсутствующих полей выполняются до агрегации.",
      refinement: "Пример исправления: считать суммы через Decimal, чтобы 0.10 + 0.20 давало ровно 0.30.",
      placeholder: "Например: проверь точность сумм 0.10 + 0.20",
      command: "python -m lumen.report fixtures/orders.csv --currency EUR --out /tmp/lumen-demo",
      checkSummary: "24 теста · схема данных · ревью",
      checks: [
        ["python -m pytest -q", "24 теста: дубли, суммы, даты, пустой ввод и пропущенные поля."],
        ["ruff check src tests", "Проверка Python-кода."],
        ["Проверка отчёта", "12 480 строк → 64 дубля исключены → 12 416 заказов."],
        ["Независимое ревью", "Согласованы ключ дедупликации, EUR и границы недель."],
      ],
      files: ["src/lumen/report.py", "tests/test_report.py", "fixtures/orders.csv"],
      code: `# src/lumen/report.py — фрагмент реализации
from decimal import Decimal
from collections import defaultdict

def weekly_revenue(rows):
    totals = defaultdict(lambda: Decimal("0.00"))
    seen = set()
    for row in rows:
        validate_row(row)  # id, amount, currency, paid_at
        if row["currency"] != "EUR":
            raise ValueError("Expected EUR; currency conversion is not configured")
        if row["order_id"] in seen:
            continue
        seen.add(row["order_id"])
        week = iso_week_in_utc(row["paid_at"])
        totals[week] += Decimal(row["amount"])
    return dict(totals)

# Вход: CSV со строковыми денежными значениями.
# Выход: weekly_revenue.csv и report.json.
# Порядок дублей в этом примере: первая валидная строка.`,
      test: `# tests/test_report.py
from decimal import Decimal

def test_money_is_exact():
    rows = [
        order("A", amount="0.10"),
        order("B", amount="0.20"),
    ]
    result = weekly_revenue(rows)
    assert result["2026-W40"] == Decimal("0.30")

def test_duplicate_order_is_counted_once():
    row = order("A", amount="24.90")
    result = weekly_revenue([row, row])
    assert result["2026-W40"] == Decimal("24.90")

def test_missing_amount_has_actionable_error():
    with pytest.raises(ValueError, match="amount"):
        weekly_revenue([{"order_id": "A"}])`,
      diff: `src/lumen/report.py

− totals[week] += float(row["amount"])
+ totals[week] += Decimal(row["amount"])

tests/test_report.py

+ assert result["2026-W40"] == Decimal("0.30")

До исправления
0.1 + 0.2 → 0.30000000000000004

После исправления
Decimal("0.10") + Decimal("0.20") → Decimal("0.30")`,
      beforeTitle: "Float для денежных сумм",
      beforeText: "Двоичная арифметика добавляла дробный хвост. Форматирование скрывало его, но не исправляло расчёт.",
      afterTitle: "Точная десятичная сумма",
      afterText: "Decimal создаётся из исходной строки. Regression test проверяет точное значение до форматирования.",
      beforeCode: "float('0.10') + float('0.20')\n→ 0.30000000000000004",
      afterCode: "Decimal('0.10') + Decimal('0.20')\n→ Decimal('0.30')",
      limitation: "В фикстуре одна валюта — EUR. Конвертация валют и правила возвратов требуют отдельного решения.",
    },
    devops: {
      name: "Northstar", kind: "DevOps · Terraform", avatar: "N", avatarClass: "devops-avatar",
      subtitle: "Предсказуемые изменения", task: "Масштабирование API",
      title: "План понятен до применения.",
      description: "Terraform + Kubernetes: запас реплик и обновление без недоступных pod. Окружение staging.",
      action: "Посмотреть план", questionTask: "Граница окружений", workingTask: "Readiness и rollout",
      question: "Что входит в это изменение?",
      questionText: "Текущий план подготовлен для staging. Production использует отдельные параметры и состояние.",
      options: ["Оставить только staging", "Подготовить отдельный production-план"],
      optionDetails: ["Проверить поведение в тестовом окружении.", "Создать ещё один план для рассмотрения, без применения."],
      workingTitle: "Готовность pod перед переключением.",
      workingDescription: "Проверяем readiness probe, rolling update и соответствие порта приложения.",
      secondaryResult: "Конфигурация rollout проверена.",
      secondaryDetail: "Статические проверки согласуют probe и targetPort. Реальный rollout и доступность кластера этим не подтверждены.",
      refinement: "Пример уточнения: оставить минимум 2 реплики. Обновлены конфигурация и демонстрационный план.",
      placeholder: "Например: оставь минимум 2 реплики, максимум 6",
      command: "terraform plan -var-file=staging.tfvars",
      checkSummary: "validate · policy checks · ревью",
      checks: [
        ["terraform fmt -check", "Формат конфигурации."],
        ["terraform validate", "Согласованность Terraform-конфигурации."],
        ["Policy checks", "maxUnavailable = 0, maxReplicas = 6, только staging."],
        ["Независимое ревью", "Просмотрены план и границы окружения. Apply не выполнялся."],
      ],
      files: ["infra/staging/api.tf", "infra/staging/staging.tfvars", "policy/rollout.rego"],
      code: `# infra/staging/api.tf — фрагмент конфигурации
resource "kubernetes_horizontal_pod_autoscaler_v2" "api" {
  metadata {
    name      = "api"
    namespace = "staging"
  }
  spec {
    min_replicas = 3
    max_replicas = 6
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = "api"
    }
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 60
        }
      }
    }
  }
}
# В Deployment: max_unavailable = "0", max_surge = "1".
# Количество реплик управляется HPA.`,
      test: `# policy/rollout.rego — фрагмент политики
package rollout
import rego.v1

deny contains "Unavailable pods are not allowed" if {
    input.environment == "staging"
    input.max_unavailable != 0
}

deny contains "Replica limit exceeds approved capacity" if {
    input.max_replicas > 6
}

# Примеры входов:
# staging / max_unavailable=1  → deny
# staging / max_unavailable=0  → allow
# staging / max_replicas=8     → deny`,
      diff: `infra/staging/api.tf

~ kubernetes_horizontal_pod_autoscaler_v2.api
− min_replicas = 3
+ min_replicas = 2
  max_replicas = 6
  average_utilization = 60

План после уточнения
  0 to add, 2 to change, 0 to destroy

Неизменённые границы
  namespace: staging
  max_unavailable: 0
  production: не входит в план
  apply: не выполнялся`,
      beforeTitle: "Минимум 3 реплики",
      beforeText: "Первый план увеличивал минимальную ёмкость staging с 2 до 3.",
      afterTitle: "Минимум 2, максимум 6",
      afterText: "Уточнение сохраняет исходный минимум. Порог CPU 60% и политика rollout остаются в плане.",
      beforeCode: "min_replicas = 3\nmax_replicas = 6\naverage_utilization = 60",
      afterCode: "min_replicas = 2\nmax_replicas = 6\naverage_utilization = 60",
      limitation: "Проверенный план не означает успешный rollout. Ничего не применено; доступность и реальная ёмкость кластера здесь не проверяются.",
    },
  };

  const sessions = Object.fromEntries(Object.keys(projects).map((key) => [key, {
    task: "home", view: "result", revision: 2,
    status: { home: "ready", saved: "question", search: "working" },
    drafts: { home: "", saved: "", search: "" },
    history: [], decision: "", feedback: { home: "", saved: "", search: "" }, ran: false, codeTab: "implementation",
  }]));
  let active = null;
  const project = () => projects[active];
  const session = () => sessions[active];
  const escapeHTML = (value) => String(value).replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
  const version = () => String(session().revision).padStart(2, "0");

  function chooseProject() {
    openDetail("ОДИН PINE. РАЗНЫЕ ВИДЫ РАБОТЫ.", `
      <h2>Что будем разрабатывать?</h2>
      <p>У каждого проекта свой результат: интерфейс, CLI, данные или инфраструктура.</p>
      <div class="project-picker">
        <button class="project-option" data-project="web" aria-pressed="${!active}"><span class="project-avatar">A</span><div><strong>Atlas</strong><small>Первый экран и визуальное уточнение</small></div><span class="project-kind">Web</span></button>
        ${Object.entries(projects).map(([key, item]) => `<button class="project-option" data-project="${key}" aria-pressed="${active === key}"><span class="project-avatar ${item.avatarClass}">${item.avatar}</span><div><strong>${item.name}</strong><small>${item.task}</small></div><span class="project-kind">${item.kind}</span></button>`).join("")}
      </div><p class="dialog-note">Все проекты — интерактивные сценарии с демонстрационными кодом, данными и проверками. Команды не исполняются.</p>
    `, () => {
      $$("[data-project]").forEach((button) => button.addEventListener("click", () => {
        closeDetail();
        switchProject(button.dataset.project);
      }));
    });
  }

  function switchProject(key) {
    if (active) session().drafts[session().task] = $("#feedback-input").value;
    else state.drafts[state.task] = $("#feedback-input").value;
    active = key === "web" ? null : key;
    $("#app").classList.toggle("developer-mode", Boolean(active));
    setAnnotation(false);
    if (!active) {
      $(".project-avatar").className = "project-avatar";
      $(".project-avatar").innerHTML = "A<span>↗</span>";
      $("#project-button strong").textContent = "Atlas";
      $("#project-button small").textContent = "Путешествовать иначе";
      $("#project-button").setAttribute("aria-label", "Обзор проекта Atlas");
      $(".task-list").setAttribute("aria-label", "Задачи Atlas");
      $("#breadcrumb-project").textContent = "Atlas";
      $('[data-task="saved"] strong').textContent = "Избранные места";
      $('[data-task="search"] strong').textContent = "Поиск по маршрутам";
      $(".composer-hint").textContent = "Продолжить эту идею";
      $("#feedback-input").value = state.drafts[state.task];
      selectTask(state.task, true);
    } else {
      const p = project();
      $(".project-avatar").className = `project-avatar ${p.avatarClass}`;
      $(".project-avatar").textContent = p.avatar;
      $("#project-button strong").textContent = p.name;
      $("#project-button small").textContent = p.subtitle;
      $("#project-button").setAttribute("aria-label", `Обзор проекта ${p.name}`);
      $(".task-list").setAttribute("aria-label", `Задачи ${p.name}`);
      $("#breadcrumb-project").textContent = p.name;
      $("#home-label").textContent = p.task;
      $('[data-task="saved"] strong').textContent = p.questionTask;
      $('[data-task="search"] strong').textContent = p.workingTask;
      selectExampleTask(session().task, true, false);
    }
    const next = new URL(location.href);
    next.searchParams.set("project", key);
    if (active) next.searchParams.set("view", session().view);
    else next.searchParams.delete("view");
    window.history.replaceState(null, "", next);
  }

  function selectExampleTask(task, focus = false, saveDraft = true) {
    const s = session();
    if (saveDraft) s.drafts[s.task] = $("#feedback-input").value;
    s.task = task === "overview" ? "home" : task;
    render(focus);
  }

  function render(focus = false) {
    const p = project(), s = session(), task = s.task;
    const status = s.status[task];
    $("#app").classList.remove("mobile-sidebar");
    $("#sidebar-button").setAttribute("aria-expanded", String(innerWidth > 620 && !$("#app").classList.contains("sidebar-hidden")));
    $$(".task").forEach((button) => {
      const selected = button.dataset.task === task;
      button.classList.toggle("selected", selected);
      if (selected) button.setAttribute("aria-current", "page");
      else button.removeAttribute("aria-current");
      $(".task-dot", button).className = `task-dot ${s.status[button.dataset.task]}`;
      $("small", button).textContent = { ready: "Результат готов", working: "Проверяем изменения", question: "Нужен ваш выбор" }[s.status[button.dataset.task]];
    });
    $("#inbox-count").textContent = String(Object.values(s.status).filter((value) => value !== "working").length);
    $("#breadcrumb-task").textContent = task === "home" ? p.task : task === "saved" ? p.questionTask : p.workingTask;
    $("#result-body").hidden = true;
    $("#alternate-view").hidden = false;
    $("#feedback-context").hidden = true;
    $("#attachment-preview").hidden = true;
    $("#attach-button").hidden = true;
    $("#feedback-zone").hidden = status === "working";
    $("#preview-button").hidden = task !== "home" || status !== "ready";
    $("#preview-button").innerHTML = icon(active === "devops" ? "paper" : "code") + p.action;
    $("#feedback-input").value = s.drafts[task] || "";
    $("#feedback-input").placeholder = status === "question" ? "Или опишите своё решение…" : p.placeholder;
    $(".composer-hint").textContent = "Уточнение к этой задаче · ⌘ Enter";
    $("#composer-footer-text").textContent = `${p.name} · версия ${version()} · контекст и решения сохранятся`;
    updateComposer();
    if (status === "question") renderQuestion();
    else if (status === "working") renderWorking();
    else if (task !== "home") renderSecondaryResult();
    else renderResult();
    if (focus) {
      $("#task-title").tabIndex = -1;
      $("#task-title").focus({ preventScroll: true });
      $("#alternate-view").scrollTop = 0;
    }
  }

  function renderResult() {
    const p = project(), s = session();
    heading(`${p.kind.toUpperCase()} · РЕЗУЛЬТАТ РАЗРАБОТКИ`, s.revision > 2 ? {
      go: "Граничный случай больше не теряется.",
      python: "Теперь суммы сходятся точно.",
      devops: "Тот же замысел. Меньше ёмкость.",
    }[active] : p.title, s.revision > 2 ? p.refinement : p.description);
    $("#alternate-view").innerHTML = `
      <div class="example-tabs"><div class="segmented" aria-label="Представление задачи">
        <button data-example-view="result" class="${s.view === "result" ? "active" : ""}" aria-pressed="${s.view === "result"}">Результат</button>
        <button data-example-view="changes" class="${s.view === "changes" ? "active" : ""}" aria-pressed="${s.view === "changes"}">Изменения</button>
        <button data-example-view="code" class="${s.view === "code" ? "active" : ""}" aria-pressed="${s.view === "code"}">Код и тесты</button>
      </div><span>Версия ${version()} · демо</span></div>
      <div id="example-artifact"></div>
      <div class="example-checks"><button id="example-evidence">${icon("check")} ${active === "devops" ? "План проверен" : "Проверено"} <span>· ${p.checkSummary}</span>${icon("chevron")}</button><span>Пример свидетельств</span></div>`;
    if (s.view === "changes") renderChanges();
    else if (s.view === "code") renderCode();
    else if (active === "go") renderGo();
    else if (active === "python") renderPython();
    else renderDevops();
    $$("[data-example-view]").forEach((button) => button.addEventListener("click", () => {
      s.view = button.dataset.exampleView;
      const url = new URL(location.href);
      url.searchParams.set("view", s.view);
      window.history.replaceState(null, "", url);
      renderResult();
      $(`[data-example-view="${s.view}"]`).focus({ preventScroll: true });
    }));
    $("#example-evidence").addEventListener("click", evidence);
  }

  function renderGo() {
    const s = session();
    $("#example-artifact").innerHTML = `
      <div class="artifact-sheet">
        <div class="artifact-caption"><span>${icon("code")}<strong>harbor scan</strong></span><span>CLI · Go 1.x · локальная фикстура</span></div>
        <div class="command-artifact"><div class="terminal-label">ВОСПРОИЗВОДИМЫЙ ПРИМЕР</div><div class="command-line"><span>$</span><code>${project().command}</code></div>
          <p class="terminal-hint">${s.ran ? "Пример сохранённого вывода для текущей демонстрационной версии." : "Нажмите «Запустить пример», чтобы посмотреть команду, результат и код завершения."}</p>
          <div class="terminal-output" ${s.ran ? "" : "hidden"}><pre id="go-output"></pre><div class="terminal-outcome">${icon("check")} Exit 0 · ${s.revision > 2 ? "3" : "2"} файла<small>Вывод симулирован · процесс не запускался</small></div></div>
        </div>
        <div class="artifact-description"><div><h2>Большие файлы — по одному.</h2><p>Обход не собирает всё дерево в памяти. Каждая подходящая запись сразу попадает в JSON Lines. Пути привязаны к окружению задачи.</p></div><span class="artifact-type">stdout → JSONL<br>stderr → ошибки</span></div>
        <div class="result-specs"><span>Потоковый вывод</span><span>Отмена через context</span><span>Порог в MiB</span><span>Тестируемая фикстура</span></div>
      </div>`;
    if (s.ran) $("#go-output").textContent = [
      '{"path":"testdata/tree/assets/video.mov","bytes":25165824}',
      ...(s.revision > 2 ? ['{"path":"testdata/tree/cache/exact.bin","bytes":10485760}'] : []),
      '{"path":"testdata/tree/export/data.csv","bytes":15728640}',
    ].join("\n");
  }

  function renderPython() {
    const s = session();
    const revenue = [18.4, 21.6, 19.8, 26.2, 24.7, 31.9];
    $("#example-artifact").innerHTML = `
      <div class="artifact-sheet">
        <div class="artifact-caption"><span>${icon("paper")}<strong>weekly_revenue.csv</strong></span><span>Фикстура · EUR · UTC</span></div>
        <div class="data-report">
          <div class="report-top"><div><span class="eyebrow">ПОСЛЕ ДЕДУПЛИКАЦИИ</span><h2>Шесть недель. Чистые данные.</h2></div><div class="report-total"><strong>€142 600</strong><small>Сумма по демонстрационному отчёту</small></div></div>
          <div class="revenue-chart" role="img" aria-label="Выручка за недели 40–45: 18,4; 21,6; 19,8; 26,2; 24,7; 31,9 тысячи евро">${revenue.map((value) => `<div class="chart-column"><span>€${value.toFixed(1)}k</span><div class="bar" style="--bar-height:${Math.round(value / 32 * 100)}px"></div></div>`).join("")}</div>
          <div class="chart-labels">${revenue.map((_, index) => `<span>W${40 + index}</span>`).join("")}</div>
          <div class="data-flow"><div><strong>12 480</strong><small>строк на входе</small></div>${icon("arrow")}<div><strong>64</strong><small>дубля исключены</small></div>${icon("arrow")}<div><strong>12 416</strong><small>уникальных заказов</small></div></div>
          <div class="report-footer"><span>Ключ: order_id · первая валидная запись</span><button id="report-table">Посмотреть CSV ${icon("arrow")}</button></div>
        </div>
        ${s.ran ? `<div class="report-run">Пример завершённого запуска: 12 416 заказов · report.json + weekly_revenue.csv<br>Exit 0 · Python в браузере не запускался.</div>` : ""}
      </div>`;
    $("#report-table").addEventListener("click", () => openDetail("АРТЕФАКТ ЗАДАЧИ", `<h2>Отчёт можно проверить.</h2><p>Те же данные, что на графике. Демонстрационный CSV.</p><pre>week,currency,revenue
2026-W40,EUR,18400.00
2026-W41,EUR,21600.00
2026-W42,EUR,19800.00
2026-W43,EUR,26200.00
2026-W44,EUR,24700.00
2026-W45,EUR,31900.00</pre><p class="dialog-note">Источник и результат — вымышленные данные примера. Личные файлы не читаются.</p>`));
  }

  function renderDevops() {
    const min = session().revision > 2 ? 2 : 3;
    $("#example-artifact").innerHTML = `
      <div class="artifact-sheet">
        <div class="artifact-caption"><span>${icon("paper")}<strong>staging.tfplan · пример</strong></span><span>НЕ ПРИМЕНЁН</span></div>
        <div class="infra-summary"><div><h2>Больше устойчивости.<br>Понятная граница изменений.</h2><p>Изменяются HPA и стратегия обновления API. Production не входит в план.</p></div><span class="environment-chip">staging</span></div>
        <div class="plan-totals"><span><strong>0</strong> создать</span><span class="plan-update"><strong>2</strong> изменить</span><span><strong>0</strong> удалить</span></div>
        <div class="resource-list">
          <div class="resource"><div class="resource-heading"><span>~</span><code>kubernetes_horizontal_pod_autoscaler_v2.api</code></div>
            <div class="resource-changes"><div><span>min_replicas</span>${min === 2 ? "<span>2 · без изменения</span>" : `<del>2</del>${icon("arrow")}<ins>3</ins>`}</div><div><span>target_cpu</span><del>70%</del>${icon("arrow")}<ins>60%</ins></div><div><span>max_replicas</span><span>6 · без изменения</span></div></div>
          </div>
          <div class="resource"><div class="resource-heading"><span>~</span><code>kubernetes_deployment_v1.api</code></div><div class="resource-changes"><div><span>max_unavailable</span><del>1</del>${icon("arrow")}<ins>0</ins></div><div><span>max_surge</span><span>1 · без изменения</span></div></div></div>
        </div>
        <div class="plan-footnote">${icon("clock")}<span>План подготовлен для рассмотрения. Применение и реальный rollout не выполнялись.</span></div>
      </div>`;
  }

  function renderChanges() {
    const p = project(), revised = session().revision > 2;
    $("#example-artifact").innerHTML = `
      <div class="scenario-compare"><article><span class="eyebrow">ДО УТОЧНЕНИЯ · ВЕРСИЯ 02</span><h2>${p.beforeTitle}</h2><p>${p.beforeText}</p><pre>${escapeHTML(p.beforeCode)}</pre></article><article><span class="eyebrow">${revised ? `ТЕКУЩАЯ ВЕРСИЯ ${version()}` : "ПРИМЕР СЛЕДУЮЩЕГО УТОЧНЕНИЯ"}</span><h2>${p.afterTitle}</h2><p>${p.afterText}</p><pre>${escapeHTML(p.afterCode)}</pre></article></div>
      <div class="scenario-comparison-note">${icon("code")}<span>${revised ? "Это заранее подготовленный пример исправления после обратной связи." : "Версия 02 ещё не включает это исправление. Отправьте уточнение, чтобы пройти сценарий тест → исправление → повторная проверка."} Точный diff и regression test доступны в «Код и тесты».</span></div>`;
  }

  function codeContent(tab) {
    const p = project(), revised = session().revision > 2;
    if (tab === "tests") {
      const comment = active === "go" ? "//" : "#";
      return (revised || active === "devops" ? "" :
        `${comment} Новый regression test для следующего уточнения.\n${comment} Не входит в показанный набор проверок версии 02.\n\n`) + p.test;
    }
    if (tab === "diff") return (revised ? "" : "ПЛАНИРУЕМЫЙ ПРИМЕР ИСПРАВЛЕНИЯ · ещё не применён\n\n") + p.diff;
    if (tab === "terminal") return `$ ${p.command}\n\n${active === "devops" ? "Plan: 0 to add, 2 to change, 0 to destroy.\nApply: NOT RUN." : active === "python" ? "rows=12480 duplicates=64 accepted=12416\nreport.json · weekly_revenue.csv" : `JSON Lines: ${revised ? "3" : "2"} matches\nExit: 0`}\n\nПример вывода. Процесс не запущен.`;
    if (active === "go" && revised) return p.code.replace("return size > minSize", "return size >= minSize");
    if (active === "python" && !revised) return p.code.replace('from decimal import Decimal\n', "").replace('defaultdict(lambda: Decimal("0.00"))', "defaultdict(float)").replace('Decimal(row["amount"])', 'float(row["amount"])');
    if (active === "devops" && revised) return p.code.replace("min_replicas = 3", "min_replicas = 2");
    return p.code;
  }

  function renderCode() {
    const s = session();
    $("#example-artifact").innerHTML = `
      <div class="artifact-sheet"><div class="artifact-caption"><span>${icon("code")}<strong>${project().files[0]}</strong></span><span>Фрагменты · не полный проект</span></div>
      <div class="example-code-content"><div class="code-tabs"><button data-code-tab="implementation">Код</button><button data-code-tab="tests">Тесты</button><button data-code-tab="diff">Diff</button><button data-code-tab="terminal">Терминал</button></div><pre id="example-code"></pre></div></div>`;
    const select = (tab) => {
      s.codeTab = tab;
      $("#example-code").textContent = codeContent(tab);
      $$("[data-code-tab]").forEach((button) => {
        button.classList.toggle("active", button.dataset.codeTab === tab);
        button.setAttribute("aria-pressed", String(button.dataset.codeTab === tab));
      });
    };
    $$("[data-code-tab]").forEach((button) => button.addEventListener("click", () => select(button.dataset.codeTab)));
    select(s.codeTab);
  }

  function run() {
    const p = project(), s = session();
    openDetail(active === "devops" ? "ПЛАН ИЗМЕНЕНИЙ" : "ЗАПУСК В ОКРУЖЕНИИ ЗАДАЧИ", `
      <h2>${active === "devops" ? "Сначала видно, что изменится." : "Результат можно воспроизвести."}</h2>
      <p>${active === "devops" ? "Пример сохранённого плана Terraform. Эта страница не подключена к кластеру." : "Команда и входные данные относятся к выбранной задаче."}</p>
      <pre>${escapeHTML(p.command)}</pre>
      <div class="detail-list"><div class="detail-line">${icon("paper")}<div><strong>${p.name} · версия ${version()}</strong><small>${active === "devops" ? "Окружение: staging · 0 создать / 2 изменить / 0 удалить" : active === "go" ? "Вход: testdata/tree · порог 10 MiB · выход JSON Lines" : "Вход: fixtures/orders.csv · EUR · выход CSV и JSON"}</small></div></div></div>
      <button class="primary-button" id="example-run-confirm">${active === "devops" ? "Открыть полный пример плана" : "Показать пример вывода"} ${icon("arrow")}</button>
      <p class="dialog-note">Выполнение симулировано. Никаких процессов, файловых изменений или обращений к инфраструктуре.</p>
    `, () => $("#example-run-confirm").addEventListener("click", () => {
      s.ran = true;
      closeDetail();
      if (active === "devops") {
        s.view = "code";
        s.codeTab = "terminal";
      } else s.view = "result";
      render(true);
      announce("Открыт демонстрационный результат команды.");
    }));
  }

  function evidence() {
    const p = project();
    openDetail("СВИДЕТЕЛЬСТВА ДЛЯ ЭТОЙ ВЕРСИИ", `
      <h2>${active === "devops" ? "Проверен план, а не rollout." : "Проверки можно разобрать."}</h2><p>${p.name} · версия ${version()} · отдельное окружение задачи</p>
      <div class="detail-list">${p.checks.map(([command, detail]) => `<div class="detail-line">${icon("check")}<div><strong>${command}</strong><small>${detail}</small></div></div>`).join("")}</div>
      <p><strong>Граница проверки:</strong> ${p.limitation}</p>
      <p class="dialog-note">Вымышленные записи проверок для визуализации интерфейса. Они не доказывают выполнение приведённых фрагментов кода.</p>`);
  }

  function renderQuestion() {
    const p = project();
    heading(`${p.kind.toUpperCase()} · НУЖНО РЕШЕНИЕ`, p.questionTask, "Это решение влияет на поведение. Сначала уточним смысл.");
    $("#alternate-view").innerHTML = `
      <div class="question-card"><span class="detail-tag">${p.name} · вопрос по реализации</span><h2>${p.question}</h2><p>${p.questionText}</p>
      <div class="decision-options">${p.options.map((option, index) => `<button data-example-decision="${index}"><span>${option}<small>${p.optionDetails[index]}</small></span>${index === 0 ? '<span class="recommendation">Рекомендуем</span>' : icon("chevron")}</button>`).join("")}</div><p class="question-footnote">Решение относится только к этой задаче. Свободный ответ доступен ниже.</p></div>`;
    $$("[data-example-decision]").forEach((button) => button.addEventListener("click", () => decide(p.options[Number(button.dataset.exampleDecision)])));
  }

  function decide(text) {
    const s = session();
    s.decision = text;
    s.history.push({ title: "Решение по задаче", text });
    s.status.saved = "working";
    s.drafts.saved = "";
    render(true);
  }

  function renderWorking() {
    const p = project(), s = session(), home = s.task === "home";
    heading(`${p.kind.toUpperCase()} · В РАБОТЕ`, home ? "Уточнение становится кодом." : s.task === "search" ? p.workingTitle : "Решение сохранено. Продолжаем.",
      home ? "Предыдущий результат остаётся в истории. Новое изменение ещё не проверено." : s.task === "search" ? p.workingDescription : "Пример продолжения задачи с учётом вашего выбора.");
    $("#alternate-view").innerHTML = `
      <div class="working-scene"><div class="working-sculpture" aria-hidden="true"><span></span></div><h2>${home ? "Воспроизвести. Исправить. Проверить." : "Проверяем поведение, а не только сборку."}</h2><p id="example-working-context"></p>
        <div class="work-steps"><div class="work-step">${icon("check")}<span>Предыдущая версия и контекст сохранены</span></div><div class="work-step current"><span class="step-circle"></span><span>${active === "devops" ? "Обновление конфигурации и плана" : "Regression test и исправление"}</span></div><div class="work-step"><span class="step-circle"></span><span>Повторные проверки и независимое ревью</span></div></div>
        <button class="secondary-button" id="example-finish">Показать проверенный пример ${icon("arrow")}</button><div class="work-caption">Демо одного подготовленного исправления. Агент не запускается.</div>
      </div>`;
    $("#example-working-context").textContent = s.feedback[s.task] ||
      (s.task === "saved" ? s.decision : p.workingDescription);
    $("#example-finish").addEventListener("click", () => {
      s.status[s.task] = "ready";
      if (home) {
        s.revision += 1;
        s.ran = false;
        s.view = "changes";
      }
      render(true);
      announce("Демонстрационное исправление проверено. Открыто сравнение.");
    });
  }

  function renderSecondaryResult() {
    const p = project(), s = session();
    heading(`${p.kind.toUpperCase()} · РЕЗУЛЬТАТ ГОТОВ`, s.task === "saved" ? "Решение стало частью задачи." : p.secondaryResult, "Пример результата без визуального превью.");
    $("#alternate-view").innerHTML = `<div class="question-card"><span class="detail-tag">${icon("check")} Проверено · демо</span><h2>${s.task === "saved" ? p.questionTask : p.workingTask}</h2><p id="example-secondary-copy"></p><p>${s.task === "saved" ? "Этот выбор сохранён отдельно от основной задачи и войдёт в контекст следующего уточнения." : p.secondaryDetail}</p><button class="secondary-button" id="example-back">Вернуться к основной задаче</button><p class="dialog-note">Демонстрация сохранения решения, а не выполнение инфраструктурной или программной операции.</p></div>`;
    $("#example-secondary-copy").textContent = [
      s.task === "saved" ? s.decision : p.workingDescription,
      s.feedback[s.task] ? `Сохранённое уточнение: ${s.feedback[s.task]}` : "",
    ].filter(Boolean).join("\n\n");
    $("#example-back").addEventListener("click", () => selectExampleTask("home", true));
  }

  function submit() {
    const text = $("#feedback-input").value.trim();
    if (!text) return;
    const s = session();
    if (s.status[s.task] === "question") {
      decide(text);
      return;
    }
    const title = s.task === "home" ? project().task : s.task === "saved" ? project().questionTask : project().workingTask;
    s.history.push({ title: `Уточнение · ${title} · v${version()}`, text });
    s.feedback[s.task] = text;
    s.drafts[s.task] = "";
    s.status[s.task] = "working";
    render(true);
  }

  function history() {
    const p = project(), s = session();
    openDetail("КОНТЕКСТ ПРОЕКТА", `<h2>${p.name} помнит решения.</h2><p>${p.description}</p><div class="detail-list" id="example-history"></div><p class="dialog-note">Записи существуют только в этой вкладке и отдельно от других проектов.</p>`, () => {
      const records = [{ title: "Исходная задача", text: p.task }, ...s.history];
      for (const record of records) {
        const row = document.createElement("div");
        row.className = "detail-line";
        row.innerHTML = `${icon("clock")}<div><strong></strong><small></small></div>`;
        $("strong", row).textContent = record.title;
        $("small", row).textContent = record.text;
        $("#example-history").append(row);
      }
    });
  }

  function inbox() {
    const p = project(), s = session();
    const entries = Object.entries(s.status).filter(([, value]) => value !== "working");
    openDetail("ВНИМАНИЕ В ТЕКУЩЕМ ПРОЕКТЕ", `<h2>${p.name}: результаты и решения.</h2><div class="example-detail-rows">${entries.map(([task, status]) => `<button data-example-inbox="${task}"><span>${task === "home" ? p.task : task === "saved" ? p.questionTask : p.workingTask}<small>${status === "question" ? "Нужен ваш выбор" : "Результат готов"}</small></span>${icon("chevron")}</button>`).join("") || "<p>Сейчас нет вопросов или новых результатов.</p>"}</div>`, () => {
      $$("[data-example-inbox]").forEach((button) => button.addEventListener("click", () => {
        closeDetail();
        selectExampleTask(button.dataset.exampleInbox, true);
      }));
    });
  }

  function tools() {
    const p = project();
    openDetail(`${p.kind.toUpperCase()} · ИНСТРУМЕНТЫ`, `<h2>Код рядом с результатом.</h2><p>${p.files.join(" · ")}</p><div class="code-tabs"><button data-example-tool="implementation">Код</button><button data-example-tool="tests">Тесты</button><button data-example-tool="diff">Diff</button><button data-example-tool="terminal">Терминал</button></div><pre id="example-tool-content"></pre><p class="dialog-note">Фрагменты реализации и демонстрационный вывод. Это не исполняемый редактор или shell.</p>`, () => {
      const select = (tab) => {
        $("#example-tool-content").textContent = codeContent(tab);
        $$("[data-example-tool]").forEach((button) => {
          button.classList.toggle("active", button.dataset.exampleTool === tab);
          button.setAttribute("aria-pressed", String(button.dataset.exampleTool === tab));
        });
      };
      $$("[data-example-tool]").forEach((button) => button.addEventListener("click", () => select(button.dataset.exampleTool)));
      select("implementation");
    });
  }

  function newTask(goal = "") {
    openDetail("ДЕМО СЛЕДУЮЩЕГО УТОЧНЕНИЯ", `<h2>Что изменить в ${project().name}?</h2><p>Этот прототип покажет подготовленное исправление в основной задаче, сохранив ваш текст.</p><form id="example-new-form"><label class="visually-hidden" for="example-new-input">Уточнение задачи</label><textarea class="dialog-input" id="example-new-input" required maxlength="2000"></textarea><button class="primary-button" type="submit">Продолжить демо ${icon("arrow")}</button></form>`, () => {
      $("#example-new-input").value = goal;
      $("#example-new-input").focus();
      $("#example-new-form").addEventListener("submit", (event) => {
        event.preventDefault();
        const text = $("#example-new-input").value.trim();
        if (!text) return;
        closeDetail();
        selectExampleTask("home");
        $("#feedback-input").value = text;
        submit();
      });
    });
  }

  function tour() {
    openDetail(`${project().kind.toUpperCase()} · СЦЕНАРИЙ РАЗРАБОТКИ`, `<h2>От кода до проверяемого результата.</h2><p>1. Откройте «Код и тесты»: реализация, regression test и diff.<br>2. ${project().action}: команда и демонстрационный вывод.<br>3. Отправьте уточнение — ${project().refinement.toLowerCase()}<br>4. Посмотрите исправленную версию и независимое ревью.<br>5. Откройте «${project().questionTask}», чтобы принять решение по реализации.</p><button class="primary-button" id="example-tour-start">Открыть код и тесты ${icon("arrow")}</button>`, () => $("#example-tour-start").addEventListener("click", () => {
      closeDetail();
      session().view = "code";
      selectExampleTask("home", true);
    }));
  }

  window.pineExamples = {
    get active() { return active; },
    selectTask: selectExampleTask,
    recordDraft(value) { session().drafts[session().task] = value; },
    submit, run, history, inbox, tools, newTask, tour,
  };
  $("#choose-project").addEventListener("click", chooseProject);
  $("#examples-button").addEventListener("click", chooseProject);
  const requested = new URLSearchParams(location.search).get("project");
  if (requested && Object.hasOwn(projects, requested)) {
    const view = new URLSearchParams(location.search).get("view");
    if (["result", "changes", "code"].includes(view)) sessions[requested].view = view;
    switchProject(requested);
  }
})();
