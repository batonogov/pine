/* An intentionally local, deterministic design prototype; no agent/API calls. */
"use strict";

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const icon = (name) => `<svg aria-hidden="true"><use href="#i-${name}"/></svg>`;
const state = {
  task: "home",
  view: "result",
  revision: 2,
  home: "ready",
  saved: "question",
  search: "working",
  annotation: false,
  anchor: null,
  drafts: { home: "", saved: "", search: "", overview: "" },
  feedback: "",
  attachment: null,
  decision: "",
  customGoal: "",
  feedbackHistory: [],
};
let toastTimer;
let dialogReturnFocus;
let previewReturnFocus;
let attachmentURL;
let tourStep = 0;

function announce(message) {
  $("#announcer").textContent = message;
}

function toast(message) {
  clearTimeout(toastTimer);
  $("#toast").textContent = message;
  $("#toast").classList.add("visible");
  toastTimer = setTimeout(() => $("#toast").classList.remove("visible"), 4200);
}

function openDetail(eyebrow, content, onReady) {
  dialogReturnFocus = document.activeElement;
  $("#dialog-eyebrow").textContent = eyebrow;
  $("#dialog-content").innerHTML = content;
  if (!$("#detail-dialog").open) $("#detail-dialog").showModal();
  onReady?.();
}

function closeDetail() {
  $("#detail-dialog").close();
}

$("#close-dialog").addEventListener("click", closeDetail);
$("#detail-dialog").addEventListener("close", () => {
  if (dialogReturnFocus?.isConnected) dialogReturnFocus.focus({ preventScroll: true });
});
for (const dialog of $$("dialog")) {
  dialog.addEventListener("click", (event) => {
    if (event.target !== dialog) return;
    const rect = dialog.getBoundingClientRect();
    if (event.clientX < rect.left || event.clientX > rect.right ||
        event.clientY < rect.top || event.clientY > rect.bottom) dialog.close();
  });
}

function setAnnotation(enabled) {
  state.annotation = enabled;
  $("#artifact-stage").classList.toggle("annotating", enabled);
  $("#annotation-hint").hidden = !enabled;
  $("#annotate-button").setAttribute("aria-pressed", String(enabled));
  if (enabled) {
    showView("result");
    $("#annotation-anchor").focus({ preventScroll: true });
    announce("Выберите первый экран для замечания. Escape отменяет выбор.");
  }
}

function selectAnchor() {
  state.anchor = `Первый экран · версия ${String(state.revision).padStart(2, "0")}`;
  $("#feedback-context-text").textContent = state.anchor;
  $("#feedback-context").hidden = false;
  setAnnotation(false);
  $("#feedback-input").placeholder = "Что изменить в этом месте?";
  $("#feedback-input").focus();
  announce("Первый экран выбран. Напишите, что хотите изменить.");
}

$("#annotate-button").addEventListener("click", () => setAnnotation(!state.annotation));
$("#annotation-anchor").addEventListener("click", (event) => {
  event.stopPropagation();
  selectAnchor();
});
$(".travel-hero").addEventListener("click", () => {
  if (state.annotation) selectAnchor();
});
$("#remove-anchor").addEventListener("click", () => {
  state.anchor = null;
  $("#feedback-context").hidden = true;
  $("#feedback-input").placeholder = "Что хотите улучшить?";
  $("#feedback-input").focus();
});

function showView(view) {
  state.view = view;
  const changes = view === "changes";
  $("#artifact-stage").hidden = changes;
  $("#changes-panel").hidden = !changes;
  $("#result-tab").classList.toggle("active", !changes);
  $("#changes-tab").classList.toggle("active", changes);
  $("#result-tab").setAttribute("aria-pressed", String(!changes));
  $("#changes-tab").setAttribute("aria-pressed", String(changes));
  $("#annotate-button").hidden = changes;
  if (changes) {
    setAnnotation(false);
    $(".new-change").hidden = true;
  }
}

$("#result-tab").addEventListener("click", () => showView("result"));
$("#changes-tab").addEventListener("click", () => showView("changes"));

function updateComposer() {
  const input = $("#feedback-input");
  input.style.height = "auto";
  input.style.height = `${Math.min(input.scrollHeight, 100)}px`;
  $("#send-button").disabled = !input.value.trim() && !(window.pineExamples?.active ? false : state.attachment);
  if (window.pineExamples?.active) window.pineExamples.recordDraft(input.value);
  else state.drafts[state.task] = input.value;
}
$("#feedback-input").addEventListener("input", updateComposer);
$("#feedback-input").addEventListener("keydown", (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
    event.preventDefault();
    $("#feedback-form").requestSubmit();
  }
});

function removeAttachment() {
  if (attachmentURL) URL.revokeObjectURL(attachmentURL);
  attachmentURL = undefined;
  state.attachment = null;
  $("#attachment-image").removeAttribute("src");
  $("#attachment-preview").hidden = true;
  $("#attachment-input").value = "";
  updateComposer();
}
$("#attach-button").addEventListener("click", () => $("#attachment-input").click());
$("#attachment-input").addEventListener("change", (event) => {
  const file = event.target.files[0];
  if (!file) return;
  if (!["image/jpeg", "image/png", "image/webp"].includes(file.type) || file.size > 10 * 1024 * 1024) {
    toast("Выберите PNG, JPEG или WebP размером до 10 МБ.");
    event.target.value = "";
    return;
  }
  removeAttachment();
  state.attachment = file;
  attachmentURL = URL.createObjectURL(file);
  $("#attachment-image").src = attachmentURL;
  $("#attachment-name").textContent = `${file.name} · только в этой вкладке`;
  $("#attachment-preview").hidden = false;
  updateComposer();
  toast("Изображение остаётся в браузере. Прототип ничего не отправляет.");
});
$("#remove-attachment").addEventListener("click", removeAttachment);
window.addEventListener("pagehide", () => {
  if (attachmentURL) URL.revokeObjectURL(attachmentURL);
});

function updateTaskList() {
  $("#home-state").textContent = state.home === "working" ? "Уточняем результат" : "Результат готов";
  $("#home-dot").className = `task-dot ${state.home === "working" ? "working" : "ready"}`;
  $("#home-label").textContent = state.customGoal ? "Новая идея" : "Первое впечатление";
  $("#saved-state").textContent = state.saved === "question" ? "Нужен ваш выбор" : state.saved === "working" ? "Учитываем ваш выбор" : "Результат готов";
  const savedDot = $('[data-task="saved"] .task-dot');
  savedDot.className = `task-dot ${state.saved === "question" ? "question" : state.saved === "ready" ? "ready" : "working"}`;
  $('[data-task="search"] small').textContent = state.search === "ready" ? "Результат готов" : "Проверяем изменения";
  $('[data-task="search"] .task-dot').className = `task-dot ${state.search === "ready" ? "ready" : "working"}`;
  $("#inbox-count").textContent = String(
    (state.home === "ready" ? 1 : 0) +
    (state.saved !== "working" ? 1 : 0) +
    (state.search === "ready" ? 1 : 0)
  );
  $$(".task").forEach((button) => {
    const selected = button.dataset.task === state.task;
    button.classList.toggle("selected", selected);
    if (selected) button.setAttribute("aria-current", "page");
    else button.removeAttribute("aria-current");
  });
}

function heading(eyebrow, title, description) {
  $("#eyebrow").textContent = eyebrow;
  $("#task-title").textContent = title;
  $("#task-description").textContent = description;
}

function selectTask(task, focus = false) {
  if (window.pineExamples?.active) {
    window.pineExamples.selectTask(task, focus);
    return;
  }
  // Each draft remains associated with its task across navigation.
  state.drafts[state.task] = $("#feedback-input").value;
  state.task = task;
  setAnnotation(false);
  $("#app").classList.remove("mobile-sidebar");
  $("#sidebar-button").setAttribute("aria-expanded", String(window.innerWidth > 620 && !$("#app").classList.contains("sidebar-hidden")));
  updateTaskList();
  const isHomeReady = task === "home" && state.home === "ready";
  $("#result-body").hidden = !isHomeReady;
  $("#alternate-view").hidden = isHomeReady;
  $("#feedback-zone").hidden = !isHomeReady && !(task === "saved" && state.saved === "question") && task !== "overview";
  $("#preview-button").hidden = task !== "home" && task !== "overview";
  $("#feedback-context").hidden = !state.anchor || !isHomeReady;
  $("#attachment-preview").hidden = !state.attachment || !isHomeReady;
  $("#attach-button").hidden = !isHomeReady;
  $("#composer-footer-text").textContent = "Контекст, решения и предыдущий результат сохранятся.";
  $("#breadcrumb-task").textContent = { home: state.customGoal ? "Новая идея" : "Первое впечатление", saved: "Избранные места", search: "Поиск по маршрутам", overview: "Обзор проекта" }[task];
  $("#feedback-input").value = state.drafts[task];
  $("#feedback-input").placeholder = task === "overview" ? "Что хотите изменить в Atlas?" : task === "saved" ? "Или предложите свой вариант…" : "Что хотите улучшить?";
  $("#preview-button").innerHTML = icon("external") + (state.home === "working" && task === "home" ? "Предыдущий результат" : "Открыть превью");

  if (isHomeReady) {
    heading(state.revision > 2 ? "ВАША ИДЕЯ СТАНОВИТСЯ ТОЧНЕЕ" : "ВАША ИДЕЯ, ВОПЛОЩЁННАЯ",
      state.revision > 2 ? "Ещё немного воздуха." : "Меньше суеты. Больше открытий.",
      state.revision > 2 ? "Пример уточнения: меньше текста, свободнее композиция, яснее действие." : "Новый первый экран Atlas. Места и настроение — на первом плане.");
    if (state.customGoal) $("#task-description").textContent = `Демонстрация вашей задачи: ${state.customGoal}`;
    showView(state.view);
  } else if (task === "overview") {
    renderOverview();
  } else if (task === "saved" && state.saved === "question") {
    renderQuestion();
  } else if (state[task] === "working") {
    renderWorking();
  } else {
    renderNonvisualResult();
  }
  updateComposer();
  if (focus) {
    $("#task-title").tabIndex = -1;
    $("#task-title").focus({ preventScroll: true });
    $("#main").scrollTo({ top: 0 });
  }
}
$$("[data-task]").forEach((button) => button.addEventListener("click", () => selectTask(button.dataset.task, true)));

function renderOverview() {
  heading("МЕСТО ДЛЯ ВАШЕГО ЗАМЫСЛА", "Atlas. Путешествовать иначе.", "Последний результат, важные решения и следующая идея — всё здесь.");
  $("#alternate-view").innerHTML = `
    <div class="project-overview">
      <div class="project-hero"><span>ПОСЛЕДНИЙ РЕЗУЛЬТАТ · ВЕРСИЯ ${String(state.revision).padStart(2, "0")}</span><h2>Somewhere<br><em>slower.</em></h2><button id="overview-result">Вернуться к результату ${icon("arrow")}</button></div>
      <div class="overview-side">
        <button class="overview-card" id="overview-question"><span class="eyebrow">${state.saved === "question" ? "ОДНО РЕШЕНИЕ" : "ИЗБРАННЫЕ МЕСТА"}</span><h3>${state.saved === "question" ? "Сохранять места без регистрации?" : "Ваш выбор сохранён"}</h3><p>${state.saved === "question" ? "Можно начать локально. Аккаунт понадобится для синхронизации." : "Продолжайте задачу с тем же контекстом."}</p></button>
        <button class="overview-card" id="overview-search"><span class="eyebrow">${state.search === "ready" ? "РЕЗУЛЬТАТ ГОТОВ" : "В РАБОТЕ"}</span><h3>Поиск по маршрутам</h3><p>Названия, описания и опечатки.</p></button>
        <div class="overview-note"><strong>Что мы решили</strong><br>Спокойный тон. Одно главное действие.<br>Путешествие начинается с места.</div>
      </div>
    </div>`;
  $("#overview-result").addEventListener("click", () => selectTask("home", true));
  $("#overview-question").addEventListener("click", () => selectTask("saved", true));
  $("#overview-search").addEventListener("click", () => selectTask("search", true));
}
$("#project-button").addEventListener("click", () => selectTask("overview", true));
$("#breadcrumb-project").addEventListener("click", () => selectTask("overview", true));

function renderQuestion() {
  heading("ЗДЕСЬ ВАЖЕН ВАШ ВЫБОР", "Маленькое решение. Большая разница.", "Работа сохранена. Продолжим, когда определимся с поведением.");
  $("#alternate-view").innerHTML = `
    <div class="question-card">
      <span class="detail-tag">Избранные места · вопрос агента</span>
      <h2>Нужен ли аккаунт,<br>чтобы сохранить место?</h2>
      <p>Без регистрации человек сможет начать сразу. Сохранённое останется в этом браузере. Аккаунт позволит перенести его на другое устройство.</p>
      <div class="decision-options">
        <button data-decision="Начать без регистрации"><span>Начать без регистрации<small>Хранить локально. Синхронизацию добавить позже.</small></span><span class="recommendation">Рекомендуем</span></button>
        <button data-decision="Сохранять в аккаунте"><span>Сохранять в аккаунте<small>Сначала предложить войти или зарегистрироваться.</small></span>${icon("chevron")}</button>
      </div>
      <p class="question-footnote">Решение останется в контексте этой задачи. Его можно будет пересмотреть.</p>
    </div>`;
  $$("[data-decision]").forEach((button) => button.addEventListener("click", () => decide(button.dataset.decision)));
}

function decide(decision) {
  state.decision = decision;
  state.saved = "working";
  $("#feedback-input").value = "";
  selectTask("saved", true);
  announce("Выбор сохранён в демонстрационной задаче.");
}

function renderWorking() {
  const task = state.task;
  const home = task === "home";
  heading("МОЖНО ЗАНЯТЬСЯ СВОИМ", home ? "Придаём идее новую форму." : task === "search" ? "Хороший поиск замечает детали." : "От выбора — к результату.",
    home ? "Уточнение связано с предыдущей версией. История и решения на месте." : "Проверки и ревью остаются внутри задачи.");
  $("#alternate-view").innerHTML = `
    <div class="working-scene">
      <div class="working-sculpture" aria-hidden="true"><span></span></div>
      <h2>${home ? "Меньше лишнего. Ближе к замыслу." : task === "search" ? "Проверяем граничные случаи." : "Учитываем ваше решение."}</h2>
      <p id="working-context"></p>
      <div class="work-steps">
        <div class="work-step">${icon("check")}<span>Контекст и предыдущий результат сохранены</span></div>
        <div class="work-step current"><span class="step-circle"></span><span>${home ? "Вносим уточнение" : "Проверяем изменения"}</span></div>
        <div class="work-step"><span class="step-circle"></span><span>Независимое ревью этой версии</span></div>
      </div>
      <button class="secondary-button" id="finish-demo">Показать следующий шаг демо ${icon("arrow")}</button>
      <div class="work-caption">Это симуляция процесса. Реальные агенты и проверки не запускаются.</div>
    </div>`;
  $("#working-context").textContent = home ? state.feedback || state.customGoal || "Сохраняем настроение. Упрощаем первый экран." :
    task === "saved" ? `Ваш выбор: ${state.decision}` : "Пустой запрос, опечатки и маршруты без описания.";
  $("#finish-demo").style.display = "inline-flex";
  $("#finish-demo").style.alignItems = "center";
  $("#finish-demo").style.gap = "10px";
  $("#finish-demo svg").style.width = "14px";
  $("#finish-demo").addEventListener("click", finishDemo);
}

function finishDemo() {
  const task = state.task;
  state[task] = "ready";
  if (task === "home") {
    state.revision += 1;
    $("#travel-site").classList.add("revised");
    $("#revision-label").textContent = `Версия ${String(state.revision).padStart(2, "0")}`;
    $("#compare-version").textContent = `Версия ${String(state.revision).padStart(2, "0")}`;
    // The comparison is explicitly anchored to the previous actual demo version.
    $(".compare-label span:last-child").textContent = `Версия ${String(state.revision - 1).padStart(2, "0")}`;
    const before = $(".before-site");
    before.className = "mini-site before-site after-site";
    before.style.textAlign = "left";
    before.innerHTML = `<strong>atlas®</strong><h3>Somewhere<br><em>slower.</em></h3><span class="mini-cta">${state.revision === 3 ? "Места, где можно никуда не спешить." : "Найти своё место ↗"}</span>`;
    $("#changes-description").textContent = state.revision === 3 ? "Пример после уточнения: убрали поясняющий абзац и выделили единственное действие. Сравнение с версией 02." : "В этом концепте показан один вариант визуального уточнения. Следующая демонстрационная версия сохраняет тот же результат.";
    $("#change-third-title").textContent = "Меньше пояснений";
    $("#change-third-copy").textContent = "Фотография и заголовок передают настроение сами.";
    $(".new-change").hidden = false;
    state.anchor = null;
    state.drafts.home = "";
    state.view = "result";
  }
  selectTask(task, true);
  announce("Демонстрационный результат готов. Можно попробовать и сравнить.");
}

function renderNonvisualResult() {
  const search = state.task === "search";
  heading("РЕЗУЛЬТАТ ГОТОВ", search ? "Находит даже с опечаткой." : "Сохранить — одним движением.",
    "Демонстрационный результат задачи. Подробности доступны без обязательного просмотра кода.");
  $("#alternate-view").innerHTML = `
    <div class="question-card">
      <span class="detail-tag">${icon("check")} Проверено · пример</span>
      <h2>${search ? "Нужное место.<br>Даже если забыли название." : "Место остаётся с вами."}</h2>
      <p id="nonvisual-description"></p>
      <div class="detail-list">
        <div class="detail-line">${icon("check")}<div><strong>${search ? "Поиск по названию и описанию" : "Выбор сохранён в задаче"}</strong><small>${search ? "Регистр и лишние пробелы не мешают результату." : "Следующее уточнение продолжит этот же контекст."}</small></div></div>
        <div class="detail-line">${icon("check")}<div><strong>Проверки и независимое ревью</strong><small>Пример того, как выглядят свидетельства для результата без визуального превью.</small></div></div>
      </div>
      <button class="secondary-button" id="nonvisual-code">Посмотреть пример изменений</button>
    </div>`;
  $("#nonvisual-description").textContent = search ? "Запрос «даломиты» находит «Доломитовые Альпы». Пустой запрос предлагает подборку мест." : `Реализованный в сценарии выбор: ${state.decision}.`;
  $("#nonvisual-code").addEventListener("click", showTools);
}

$("#feedback-form").addEventListener("submit", (event) => {
  event.preventDefault();
  if (window.pineExamples?.active) {
    window.pineExamples.submit();
    return;
  }
  const text = $("#feedback-input").value.trim();
  if (!text && !state.attachment) return;
  if (state.task === "saved") {
    decide(text);
    return;
  }
  if (state.task === "overview") {
    newTask(text);
    return;
  }
  if (state.task !== "home" || state.home !== "ready") return;
  state.feedback = text || "Уточнение с изображением";
  state.feedbackHistory.push({ text: state.feedback, revision: state.revision, anchor: state.anchor, attachment: state.attachment?.name || null });
  state.home = "working";
  state.drafts.home = "";
  $("#feedback-input").value = "";
  removeAttachment();
  selectTask("home", true);
  announce("Уточнение сохранено в демо. Переход к примеру работы над новой версией.");
});

function openPreview() {
  if (window.pineExamples?.active) {
    window.pineExamples.run();
    return;
  }
  previewReturnFocus = document.activeElement;
  const clone = $("#travel-site").cloneNode(true);
  $$("[id]", clone).forEach((node) => node.removeAttribute("id"));
  clone.removeAttribute("id");
  $(".annotation-anchor", clone).remove();
  $("#expanded-preview").replaceChildren(clone);
  $$(".travel-nav button, .travel-bottom button, .explore-button", clone).forEach((button) => {
    button.addEventListener("click", () => toast("Это демонстрационный сайт Atlas. В Pine здесь будет ваш работающий продукт."));
  });
  $("#preview-dialog").showModal();
}
$("#preview-button").addEventListener("click", openPreview);
$("#close-preview").addEventListener("click", () => $("#preview-dialog").close());
$("#preview-dialog").addEventListener("close", () => {
  if (previewReturnFocus?.isConnected) previewReturnFocus.focus({ preventScroll: true });
});
$$("[data-travel], #explore-button").forEach((button) => button.addEventListener("click", () => {
  if (!state.annotation) openPreview();
}));

$("#evidence-button").addEventListener("click", () => openDetail("ПОЧЕМУ ЭТОТ РЕЗУЛЬТАТ ГОТОВ", `
  <h2>Уверенность в деталях.</h2>
  <p>Проверки относятся к версии ${String(state.revision).padStart(2, "0")}. Если код изменится, этот статус станет неактуальным.</p>
  <div class="detail-list">
    <div class="detail-line">${icon("check")}<div><strong>Сборка завершена</strong><small><code>npm run build</code> · окружение задачи Atlas</small></div><span class="line-meta">8 секунд</span></div>
    <div class="detail-line">${icon("check")}<div><strong>12 проверок пройдены</strong><small>Навигация, адаптивная сетка, доступность элементов.</small></div><span class="line-meta">12 / 12</span></div>
    <div class="detail-line">${icon("check")}<div><strong>Независимое ревью</strong><small>Отдельная сессия проверила ту же версию. Открытых замечаний нет.</small></div></div>
  </div>
  <p><strong>Ограничение:</strong> реальные бронирования и оплата не входят в эту задачу.</p>
  <p class="dialog-note">Все результаты проверок здесь — вымышленные данные интерфейса. Прототип не выполняет команды и не подключается к агентам.</p>
`));

$("#history-button").addEventListener("click", () => {
  if (window.pineExamples?.active) {
    window.pineExamples.history();
    return;
  }
  openDetail("КОНТЕКСТ ЭТОЙ ЗАДАЧИ", `
    <h2>Замысел не теряется.</h2>
    <p id="history-goal"></p>
    <div class="detail-list" id="history-list"></div>
    <p class="dialog-note">Это история действий в текущей вкладке. Прототип не сохраняет переписку и вложения после перезагрузки.</p>
  `, () => {
    const home = state.task === "home" || state.task === "overview";
    $("#history-goal").textContent = home ? state.customGoal || "Сделать первый экран спокойнее: место, настроение и одно понятное действие." : state.task === "saved" ? "Сохранять понравившиеся места, не прерывая путешествие." : "Находить маршруты по названию и описанию, в том числе с опечатками.";
    const items = home ? [
      { title: "Исходное решение", detail: "Спокойный тон. Без рекламных обещаний и перегруженной навигации." },
      { title: "Версия 01 → 02", detail: "Оставили одно главное действие. Дали фотографии больше пространства." },
      ...state.feedbackHistory.map((feedback) => ({
        title: `Ваше уточнение к версии ${String(feedback.revision).padStart(2, "0")}`,
        detail: feedback.text + (feedback.anchor ? ` · ${feedback.anchor}` : "") + (feedback.attachment ? ` · изображение: ${feedback.attachment} (не хранится)` : ""),
      })),
    ] : [{ title: state.task === "saved" ? "Ваше решение" : "Критерии результата", detail: state.task === "saved" ? state.decision || "Ещё не принято. Нужен ваш выбор." : "Обработать регистр, лишние пробелы, пустой запрос и опечатки." }];
    for (const item of items) {
      const row = document.createElement("div");
      row.className = "detail-line";
      row.innerHTML = `${icon("clock")}<div><strong></strong><small></small></div>`;
      $("strong", row).textContent = item.title;
      $("small", row).textContent = item.detail;
      $("#history-list").append(row);
    }
  });
});

$("#inbox-button").addEventListener("click", () => {
  if (window.pineExamples?.active) {
    window.pineExamples.inbox();
    return;
  }
  const entries = [
    ...(state.home === "ready" ? [{ task: "home", title: "Первое впечатление", text: `Результат готов · версия ${String(state.revision).padStart(2, "0")}` }] : []),
    ...(state.saved === "question" ? [{ task: "saved", title: "Избранные места", text: "Один вопрос: нужен ли аккаунт?" }] : state.saved === "ready" ? [{ task: "saved", title: "Избранные места", text: "Результат готов с учётом вашего выбора" }] : []),
    ...(state.search === "ready" ? [{ task: "search", title: "Поиск по маршрутам", text: "Результат готов" }] : []),
  ];
  openDetail("ТОЛЬКО ТО, ЧТО НУЖНО ВАМ", entries.length ? `
    <h2>Есть к чему вернуться.</h2><p>Результаты и решения. Промежуточная работа остаётся внутри задач.</p>
    <div class="decision-options">${entries.map((entry) => `<button data-inbox-task="${entry.task}"><span>${entry.title}<small>${entry.text}</small></span>${icon("chevron")}</button>`).join("")}</div>
  ` : `<h2>Сейчас ничего не нужно.</h2><p>Задачи продолжаются. Здесь появится результат или конкретный вопрос.</p>`, () => {
    $$("[data-inbox-task]").forEach((button) => button.addEventListener("click", () => {
      closeDetail();
      selectTask(button.dataset.inboxTask, true);
    }));
  });
});

function showTools() {
  if (window.pineExamples?.active) {
    window.pineExamples.tools();
    return;
  }
  const task = state.task;
  openDetail("ИНСТРУМЕНТЫ В КОНТЕКСТЕ", `
    <h2>Можно зайти глубже.</h2>
    <p>Файлы, изменения и настоящий терминал остаются рядом с задачей. Ниже — иллюстрация их представления.</p>
    <div class="code-tabs" aria-label="Инструменты"><button class="active" data-tool="diff">Изменения</button><button data-tool="files">Файлы</button><button data-tool="terminal">Терминал</button></div>
    <pre id="tool-content"></pre>
    <p class="dialog-note">Пример данных. Команды здесь не исполняются; файлы вашего проекта не читаются.</p>
  `, () => {
    const contents = {
      diff: task === "search" ? `src/search.ts\n\n−  return places.filter(p => p.title === query)\n+  const normalized = normalize(query)\n+  return rankMatches(places, normalized)\n\n✓ Пустой запрос · регистр · опечатки` :
        task === "saved" ? `src/saved-places.ts\n\n+  export function savePlace(place) {\n+    return savedPlaces.add(place.id)\n+  }\n\nРешение: ${state.decision || "ожидает вашего выбора"}` :
        `src/components/Hero.tsx\n\n−  <h1>Откройте мир новых путешествий</h1>\n+  <h1>Somewhere <em>slower.</em></h1>\n\n−  <OffersGrid />\n−  <PromoBanner />\n+  <ExploreButton>Найти своё место</ExploreButton>`,
      files: `Atlas / окружение задачи\n\nsrc/\n  components/\n    Hero.tsx             изменён\n    Navigation.tsx       изменён\n  styles/\n    typography.css       изменён\n  search.ts\n  saved-places.ts\n\n12 проверок · отдельное ревью\nДемонстрационные данные`,
      terminal: `atlas / task-environment\n\n$ npm run build\n✓ build completed\n\n$ npm test\n✓ 12 passed\n\nЭто пример терминальной поверхности.\nВ этой странице shell не запущен.`,
    };
    const select = (tool) => {
      $("#tool-content").textContent = contents[tool];
      $$("[data-tool]").forEach((button) => {
        button.classList.toggle("active", button.dataset.tool === tool);
        button.setAttribute("aria-pressed", String(button.dataset.tool === tool));
      });
    };
    $$("[data-tool]").forEach((button) => button.addEventListener("click", () => select(button.dataset.tool)));
    select("diff");
  });
}
$("#tools-button").addEventListener("click", showTools);

function newTask(goal = "") {
  if (window.pineExamples?.active) {
    window.pineExamples.newTask(goal);
    return;
  }
  openDetail("НОВАЯ ИДЕЯ ДЛЯ ATLAS", `
    <h2>Что хочется изменить?</h2>
    <p>Начните с результата, который хотите получить. Проект и выбранный агент уже на месте.</p>
    <form id="new-task-form"><label class="visually-hidden" for="new-task-input">Желаемый результат</label><textarea id="new-task-input" class="dialog-input" placeholder="Например: сделать первый экран ещё спокойнее…" required maxlength="2000"></textarea><button class="primary-button dialog-action" type="submit">Начать демо ${icon("arrow")}</button></form>
    <p class="dialog-note">Текст останется в этой вкладке. Для любой задачи прототип показывает один заранее подготовленный сценарий Atlas, а не генерирует новый продукт.</p>
  `, () => {
    $("#new-task-input").value = goal;
    $("#new-task-input").focus();
    $("#new-task-form").addEventListener("submit", (event) => {
      event.preventDefault();
      const value = $("#new-task-input").value.trim();
      if (!value) return;
      state.customGoal = value;
      state.feedback = value;
      state.home = "working";
      state.drafts.home = "";
      $("#feedback-input").value = "";
      closeDetail();
      selectTask("home", true);
    });
  });
}
$("#new-task").addEventListener("click", () => newTask());

$("#sidebar-button").addEventListener("click", () => {
  const mobile = window.innerWidth <= 620;
  $("#app").classList.toggle(mobile ? "mobile-sidebar" : "sidebar-hidden");
  const shown = mobile ? $("#app").classList.contains("mobile-sidebar") : !$("#app").classList.contains("sidebar-hidden");
  $("#sidebar-button").setAttribute("aria-expanded", String(shown));
  $("#sidebar-button").setAttribute("aria-label", shown ? "Скрыть боковую панель" : "Показать боковую панель");
});
document.addEventListener("pointerdown", (event) => {
  if (window.innerWidth <= 620 && $("#app").classList.contains("mobile-sidebar") &&
      !event.target.closest(".sidebar") && !event.target.closest("#sidebar-button")) {
    $("#app").classList.remove("mobile-sidebar");
    $("#sidebar-button").setAttribute("aria-expanded", "false");
  }
});
$("#theme-button").addEventListener("click", () => {
  const dark = document.body.classList.toggle("dark");
  $("#theme-button").innerHTML = icon(dark ? "sun" : "moon");
  $("#theme-button").setAttribute("aria-label", dark ? "Включить светлую тему" : "Включить тёмную тему");
});

const tour = [
  { title: "Начните с того, что получилось.", text: "В центре — ваш продукт. Попробуйте его, откройте проверки или сравните с предыдущей версией.", button: "Посмотреть результат", action: () => { selectTask("home", true); closeDetail(); openPreview(); } },
  { title: "Покажите, что хочется изменить.", text: "Прицельная кнопка справа над превью связывает замечание с конкретным местом и версией. Попробуйте: «Меньше текста, больше воздуха».", button: "Оставить уточнение", action: () => { selectTask("home", true); closeDetail(); selectAnchor(); $("#feedback-input").value = "Меньше текста, больше воздуха. Выдели главное действие."; updateComposer(); } },
  { title: "Сравните воплощения одной идеи.", text: "Отправьте уточнение и нажмите «Показать следующий шаг демо». Новая версия останется в той же задаче. Откройте «Что изменилось».", button: "Продолжить", action: closeDetail },
  { title: "Иногда нужен только ваш выбор.", text: "В задаче «Избранные места» есть конкретный вопрос. Выберите вариант и посмотрите, как решение становится частью контекста.", button: "Открыть вопрос", action: () => { closeDetail(); selectTask("saved", true); } },
  { title: "Проект помнит, где вы остановились.", text: "Обзор Atlas объединяет последний результат, важные решения и текущую работу. Это место, куда можно вернуться завтра.", button: "Открыть проект", action: () => { closeDetail(); selectTask("overview", true); } },
];
$("#tour-button").addEventListener("click", () => {
  if (window.pineExamples?.active) {
    window.pineExamples.tour();
    return;
  }
  const step = tour[tourStep % tour.length];
  openDetail(`ЗНАКОМСТВО С PINE · ${tourStep % tour.length + 1} / ${tour.length}`, `
    <h2>${step.title}</h2><p>${step.text}</p><button class="primary-button dialog-action" id="tour-next">${step.button} ${icon("arrow")}</button>
    <p class="dialog-note">Следующий пункт — по кнопке «Пройти сценарий» под окном. Можно свободно исследовать интерфейс в любом порядке.</p>
  `, () => $("#tour-next").addEventListener("click", () => { tourStep += 1; step.action(); }));
});
$("#reset-button").addEventListener("click", () => {
  openDetail("НАЧАТЬ СНАЧАЛА", `<h2>Вернуться к первой версии демо?</h2><p>Текст уточнений и выбранные изображения в этой вкладке будут сброшены.</p><button class="primary-button dialog-action" id="confirm-reset">Начать сначала</button>`,
    () => $("#confirm-reset").addEventListener("click", () => window.location.reload()));
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    if (state.annotation) {
      setAnnotation(false);
      $("#annotate-button").focus();
    }
    if ($("#app").classList.contains("mobile-sidebar")) {
      $("#app").classList.remove("mobile-sidebar");
      $("#sidebar-button").setAttribute("aria-expanded", "false");
      $("#sidebar-button").focus();
    }
  }
});

selectTask("home");
