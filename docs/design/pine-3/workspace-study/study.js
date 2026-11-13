/* Local interaction study only. No persistence, network, command, or provider APIs. */
(function () {
  "use strict";

  const projects = [
    { id: "atlas", name: "Atlas", type: "web", description: "A considered place to plan a weekend.", goal: "Give the homepage a quieter introduction" },
    { id: "canvas", name: "Canvas", type: "native", description: "A native sketching application.", goal: "Restore the selected document after relaunch" },
    { id: "trail", name: "Trail CLI", type: "cli", description: "A small command-line route planner.", goal: "Explain an invalid route without losing the input" },
    { id: "notes", name: "Field Notes", type: "document", description: "Documentation and internal logic.", goal: "Clarify the first-run setup guide" },
  ];
  const labels = { working: "Working", question: "Needs decision", ready: "Ready", stale: "Checks and review are stale", cancelled: "Cancelled", unknown: "Execution unknown", unverified: "Unverified result", failed: "Failed", unavailable: "Environment unavailable" };
  const actionLabels = { web: "Open preview", native: "Run application", cli: "Run example", document: "Open document" };
  const draft = "struct DocumentSelection {\n    var selectedDocument: String?\n}\n";
  const escape = value => String(value).replace(/[&<>"']/g, character => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[character]));

  function initialState() {
    return {
      layout: "focus", project: "atlas", selected: null, nextID: 5,
      tasks: projects.map((project, index) => ({ id: "task-" + (index + 1), project: project.id, goal: project.goal, state: index === 0 ? "question" : "ready", tool: "task", unread: true, accepted: false, revision: 1, history: index === 0 ? [] : [{ revision: 1, accepted: false }], draft, dirty: false, feedback: "", restored: false, answer: null })),
    };
  }

  function currentTask(state) { return state.tasks.find(task => task.id === state.selected); }
  function projectFor(state) { return projects.find(project => project.id === state.project); }

  // One shared interaction model lets composition changes preserve task context.
  function transition(state, action, value) {
    const next = structuredClone(state);
    let task = currentTask(next);
    switch (action) {
      case "layout": next.layout = value; break;
      case "project": next.project = value; next.selected = null; break;
      case "overview": next.selected = null; break;
      case "select":
        next.selected = value;
        task = currentTask(next);
        if (task) { next.project = task.project; task.unread = false; }
        break;
      case "create":
        if (!value.trim()) break;
        task = { id: "task-" + next.nextID++, project: next.project, goal: value.trim().slice(0, 180), state: "working", tool: "task", unread: false, accepted: false, revision: 1, history: [], draft, dirty: false, feedback: "", restored: false, answer: null };
        next.tasks.unshift(task); next.selected = task.id; break;
      case "tool": if (task) task.tool = value; break;
      case "answer":
        if (task && task.state === "question" && !task.restored) { task.answer = value; task.state = "working"; }
        break;
      case "accept":
        if (task && task.state === "ready") {
          task.accepted = true;
          const snapshot = task.history.find(item => item.revision === task.revision);
          if (snapshot) snapshot.accepted = true;
        }
        break;
      case "feedback":
        if (task && value.trim() && !["working", "cancelled", "unknown", "unavailable"].includes(task.state) && !task.restored) {
          task.feedback = value.trim().slice(0, 1000); task.state = "working"; task.accepted = false; task.revision++;
        }
        break;
      case "edit":
        if (task) {
          // Unsaved content can already have been reviewed. Only successive
          // edits within an unreviewed stale draft share a candidate identity.
          const continuingDraft = task.state === "stale" && task.dirty
            && !task.history.some(snapshot => snapshot.revision === task.revision);
          if (!continuingDraft) task.revision++;
          task.draft = value; task.dirty = true; task.state = "stale"; task.accepted = false;
        }
        break;
      case "resume":
        if (task && task.restored) { task.restored = false; task.state = "working"; task.revision++; }
        break;
      case "scenario":
        if (value === "relaunch") {
          // Relaunch is app-wide, including tasks outside the selected project.
          // Preserve metadata and history, but no live or positive evidence.
          for (const restoredTask of next.tasks) {
            restoredTask.restored = true;
            restoredTask.state = "stale";
            restoredTask.accepted = false;
            restoredTask.unread = false;
          }
          break;
        }
        if (!task) { task = next.tasks.find(candidate => candidate.project === next.project); next.selected = task?.id || null; }
        if (!task) break;
        task.accepted = false;
        task.tool = "task";
        if (value === "stale" && task.state === "ready") task.revision++;
        task.state = value; task.restored = false; task.unread = false;
        if (value === "ready" && !task.history.some(item => item.revision === task.revision)) task.history.push({ revision: task.revision, accepted: false });
        break;
    }
    return next;
  }

  if (typeof document === "undefined") {
    if (typeof module !== "undefined") module.exports = { initialState, transition, currentTask, projects };
    return;
  }

  let state = initialState();
  const app = document.getElementById("app");
  const announce = message => { document.getElementById("announcement").textContent = message; };
  const stateMarkup = task => `<span class="state ${task.state}" data-task-state>${labels[task.state]}${task.restored ? " · restored metadata" : ""}</span>`;
  const taskButton = task => `<button type="button" class="task-row" id="row-${task.id}" data-select="${task.id}"><span><span class="task-name">${escape(task.goal)}</span><small>${task.unread ? "Unviewed · " : ""}${task.accepted ? "Accepted revision · " : ""}Revision ${task.revision}</small></span><span>${stateMarkup(task)}</span><span class="chevron" aria-hidden="true">›</span></button>`;

  function navigation() {
    const attention = state.tasks.filter(task => task.state === "question" || (task.state === "ready" && task.unread)).length;
    if (state.layout === "table") {
      return `<nav class="project-rail" aria-label="Projects">${projects.map(project => `<button type="button" data-project="${project.id}" class="${state.project === project.id ? "selected" : ""}" aria-pressed="${state.project === project.id}">${project.name}</button>`).join("")}</nav>`;
    }
    return `<nav class="sidebar" aria-label="Projects and tasks"><button type="button" class="inbox-button" data-action="inbox">Inbox <small>${attention}</small></button><div class="nav-heading">Projects</div>${projects.map(project => `<button type="button" data-project="${project.id}" class="${state.project === project.id && !state.selected ? "selected" : ""}" aria-pressed="${state.project === project.id && !state.selected}"><span class="project-dot ${state.project === project.id ? "active" : ""}" aria-hidden="true"></span>${project.name}</button>${state.project === project.id ? state.tasks.filter(task => task.project === project.id).map(task => `<button type="button" class="task-link ${state.selected === task.id ? "selected" : ""}" data-select="${task.id}" aria-pressed="${state.selected === task.id}">${escape(task.goal)}</button>`).join("") : ""}`).join("")}</nav>`;
  }

  function composer() {
    return `<form class="composer" id="new-task"><label for="goal">What would you like to change?</label><textarea id="goal" name="goal" maxlength="180" placeholder="Describe the outcome…" required></textarea><div class="row"><small>Remembered agent: Codex · illustrative</small><button type="submit" class="primary">Start task</button></div></form>`;
  }

  function overview() {
    const project = projectFor(state);
    const tasks = state.tasks.filter(task => task.project === project.id);
    return `<div class="overview-intro"><div class="page-head"><div><p class="eyebrow">Project</p><h2 id="page-title" tabindex="-1">${project.name}</h2><p>${project.description}</p></div></div>${composer()}</div><div class="section-heading">Your work</div>${state.layout === "table" ? '<div class="table-labels"><span>Task / revision</span><span>Attention</span></div>' : ""}<div class="task-list">${tasks.map(taskButton).join("")}</div><p class="details">Files and a manual terminal remain available inside each task. No file tree or terminal is required to start.</p>`;
  }

  function artifact(task, project) {
    if (project.type === "web") return `<div class="result-artifact web"><div class="artifact-eyebrow">Illustrative artifact · Atlas</div><div class="artifact-title">Make room for a quieter weekend.</div><div class="artifact-line"></div><div class="artifact-line short"></div><p class="muted">Static design illustration; no running preview.</p></div>`;
    if (project.type === "native") return `<div class="result-artifact"><div class="artifact-eyebrow">Native application result</div><h3>Return to the document you left open.</h3><p>The selected-document identifier is restored. No application has been launched.</p><small>Illustrative built artifact: Canvas.app · task environment</small></div>`;
    if (project.type === "cli") return `<div class="result-artifact"><div class="artifact-eyebrow">CLI result</div><pre class="command">trail route --from Elm --to River\nRoute input is preserved when a destination is unavailable.</pre><small>Example shown for inspection; no command has run.</small></div>`;
    return `<div class="result-artifact"><div class="artifact-eyebrow">Document result</div><h3>First-run setup</h3><p>The guide distinguishes prerequisites from optional integrations and explains what to do when setup is incomplete.</p><small>A document and diff are useful results; execution is not required.</small><section id="document-content" hidden><h3>Prerequisites</h3><p>Install the supported toolchain before opening the sample project. Optional integrations can be configured later.</p><h3>When setup is incomplete</h3><p>Check the missing prerequisite and retry explicitly. Opening this guide never runs its examples.</p></section></div>`;
  }

  function evidence(task) {
    const current = task.state === "ready";
    return `<details class="evidence"><summary>${current ? "Checks passed · Independent review · Limitations" : "Checks and review must be repeated"}</summary><p><strong>Illustrative evidence, not actual verification.</strong></p><ul><li>Candidate: revision ${task.revision}; sample code-state A7. Pre/post identities ${current ? "match" : "are not current"}.</li><li>Environment: sample task environment; ${current ? "binding revalidated before Ready" : "binding must be revalidated"}.</li><li>Required checks: build and relevant tests; ${current ? "passing sample records" : "stale or missing"}.</li><li>Independent reviewer: separate sample session, read-only candidate, explicit task criteria; ${current ? "passing sample outcome" : "review is not current"}.</li><li>Limitations: no real agent, artifacts, commands, or accessibility validation are supplied by this study.</li></ul><p>Viewing, running, and accepting remain separate. Agent completion or process exit alone never establishes Ready.</p></details>`;
  }

  function result(task, project) {
    return `<div class="row wrap"><button type="button" class="primary" id="result-action" data-action="try">${actionLabels[project.type]}</button><span>${task.accepted ? '<span class="accepted">✓ This revision accepted</span>' : '<button type="button" class="subtle" data-action="accept">Accept this revision</button>'}</span></div>${artifact(task, project)}${evidence(task)}`;
  }

  function tools(task) {
    return `<div class="tools" role="group" aria-label="Task views">${[["task", "Task"], ["files", "Files"], ["diff", "Changes"], ["terminal", "Terminal"]].map(([value, label]) => `<button type="button" data-tool="${value}" aria-pressed="${task.tool === value}">${label}${value === "files" && task.dirty ? " · unsaved" : ""}</button>`).join("")}</div>`;
  }

  function toolContent(task) {
    if (task.tool === "files") return `<div class="tool-pane"><label for="source">Selection.swift — illustrative manual editing</label><textarea id="source" spellcheck="false">${escape(task.draft)}</textarea><p id="draft-status" class="${task.dirty ? "unsaved" : "muted"}">${task.dirty ? "Unsaved draft retained in this tab. Edit invalidates current checks and review." : "Edit this sample to invalidate the illustrated evidence."}</p><small>This prototype keeps drafts in memory; it never writes files.</small></div>`;
    if (task.tool === "diff") return `<div class="tool-pane"><h3>Changes in task context</h3><pre>+ Restore the previously selected document\n+ Keep the input when a destination is unavailable</pre><p class="muted">Illustrative diff. No repository was read.</p></div>`;
    return `<div class="tool-pane"><h3>Task terminal</h3><pre>Provider session details would appear here.\nNo terminal is connected in this prototype.</pre><p class="muted">In Pine, the real CLI remains available for inspection and intervention. Terminal text does not grant execution authority.</p></div>`;
  }

  function taskCanvas(task) {
    const project = projectFor(state);
    let content;
    if (task.tool !== "task") content = toolContent(task);
    else if (task.restored) content = `<div class="question-card"><h3>Your task is here. Live evidence is not.</h3><p>Goal, feedback reference, draft, and previous revision remain. No agent or correction loop restarted. Checks and independent review must be repeated in the revalidated environment.</p><button type="button" data-action="resume" class="primary">Resume explicitly</button></div>${evidence(task)}`;
    else if (task.state === "question") content = `<section class="question-card" aria-labelledby="question-title"><p class="eyebrow">One decision</p><h3 id="question-title">Keep the existing structure or simplify it?</h3><p>The selected agent asks which direction to implement. Your answer belongs to this task and this request.</p><div class="row"><button type="button" class="primary" data-answer="Simplify the structure">Simplify the structure</button><button type="button" data-answer="Keep the structure">Keep the structure</button></div></section><p class="muted">This is an illustrative question, not a real approval request.</p>`;
    else if (task.state === "ready") content = result(task, project);
    else if (task.state === "stale") content = `<div class="work-note"><strong>The candidate changed.</strong>Earlier checks and independent review no longer cover it. Previous reviewed and accepted history stays identifiable; this revision is not Ready.</div>${evidence(task)}`;
    else if (task.state === "cancelled") content = `<p class="cancelled-note">The illustrated attempt is cancelled. Late completion cannot produce Ready. Starting another attempt requires a separate user action.</p>`;
    else if (task.state === "unknown") content = `<div class="work-note"><strong>Current execution is not verifiable.</strong>The channel is unavailable. Previous activity does not prove idle or successful completion; historical requests cannot be answered until revalidated.</div>${evidence(task)}`;
    else if (task.state === "unverified") content = `<div class="work-note"><strong>The agent reported an outcome.</strong>Required Pine-observed checks and independent review are missing. The result is not Ready.</div>${evidence(task)}`;
    else if (task.state === "failed") content = `<div class="question-card"><h3>A required check failed.</h3><p>The candidate is not Ready. Inspect the failed-check evidence or give feedback; no automatic fourth correction is implied.</p></div>${evidence(task)}`;
    else if (task.state === "unavailable") content = `<div class="question-card"><h3>The task environment is unavailable.</h3><p>The saved binding no longer matches an available environment. Implementation, checks, review, and result execution remain blocked until it can be revalidated.</p></div>${evidence(task)}`;
    else content = `<div class="work-note"><strong>Work stays with this task.</strong>Illustrative active provider turn. Detailed activity and the CLI terminal are available without a universal plan, progress percentage, or fabricated live preview.</div>${task.answer ? `<p class="muted">Your answer: ${escape(task.answer)}</p>` : ""}<p class="muted">Use “Show checked result” in the prototype controls to inspect the result composition.</p>`;
    const feedbackEnabled = !["working", "cancelled", "unknown", "unavailable"].includes(task.state) && !task.restored;
    return `<div class="task-sheet"><div class="breadcrumb"><button type="button" data-action="overview">‹ ${project.name}</button><span>Task</span></div><div class="page-head"><div>${stateMarkup(task)}<h2 id="page-title" tabindex="-1">${escape(task.goal)}</h2><p id="revision-label">Revision ${task.revision}${task.dirty ? " · unsaved manual draft" : ""}${task.accepted ? " · accepted" : ""}</p></div></div>${tools(task)}${content}<form class="feedback" id="feedback"><label for="feedback-text">Continue with feedback</label><textarea id="feedback-text" name="feedback" maxlength="1000" required ${feedbackEnabled ? "" : "disabled"} placeholder="${task.state === "working" ? "This provider example does not accept input during an active turn." : "What should change next?"}"></textarea><div class="row"><small>Text only in this study. Attachments require explicit selection and provider support.</small><button type="submit" ${feedbackEnabled ? "" : "disabled"}>Send feedback</button></div>${task.feedback ? '<p class="muted">Previous feedback remains with the task in this in-memory example.</p>' : ""}</form><details class="details"><summary>Task details and continuity</summary><dl><dt>Project</dt><dd>${project.name}</dd><dt>Selected agent</dt><dd>Codex · remembered choice, illustrative</dd><dt>Environment</dt><dd>Task-owned routing; worktrees are not a security sandbox.</dd><dt>Restoration</dt><dd>Metadata only. A new provider process requires explicit action.</dd><dt>Acceptance</dt><dd>Applies only to the identified revision; later changes do not inherit it.</dd><dt>History</dt><dd>${task.history.length ? task.history.map(item => `Revision ${item.revision}: reviewed${item.accepted ? " and accepted" : ""}`).join("; ") : "No reviewed snapshot yet"} (illustrative)</dd></dl></details></div>`;
  }

  function render(focusID) {
    const task = currentTask(state);
    app.className = "window " + (state.layout === "table" ? "table-layout" : "focus-layout");
    app.innerHTML = `<div class="titlebar"><span class="traffic" aria-hidden="true"><i></i><i></i><i></i></span><span>Pine · ${projectFor(state).name}</span><span>Concept · no live processes</span></div>${state.layout === "table" ? navigation() : ""}<div class="body">${state.layout === "focus" ? navigation() : ""}<main id="workspace" tabindex="-1" aria-labelledby="page-title">${task ? taskCanvas(task) : overview()}</main></div><dialog aria-labelledby="action-title" aria-describedby="action-description"><h2 id="action-title">${task ? actionLabels[projectFor(state).type] : "Result action"}</h2><p id="action-description">In the implemented app, this action revalidates the task environment and current grant immediately before execution. Viewing a result does not authorize it.</p><p>${projectFor(state).type === "native" ? "Launching an application may change files or settings; build and install remain separate actions." : projectFor(state).type === "web" ? "Opening a preview may start a local server; it does not deploy or publish." : projectFor(state).type === "cli" ? "The exact command would be shown before running it in the task terminal." : "Opening a document displays content without executing embedded commands."}</p>${projectFor(state).type === "cli" ? '<pre class="command">trail route --from Elm --to River</pre>' : ""}<p><strong>This prototype executes nothing.</strong> Continue shows a simulated outcome only.</p><div class="row"><button type="button" data-action="dismiss">Cancel</button><button type="button" class="primary" data-action="confirm">Continue in prototype</button></div></dialog>`;
    document.querySelectorAll("[data-layout]").forEach(button => button.setAttribute("aria-pressed", String(button.dataset.layout === state.layout)));
    document.getElementById("composition-description").textContent = state.layout === "focus" ? "Projects and tasks stay in a compact sidebar. One selected task owns the canvas." : "Project work is a full-width table. A task opens as a focused sheet; project navigation moves above the canvas.";
    if (focusID) document.getElementById(focusID)?.focus();
  }

  function apply(action, value, message, focusID = "page-title") {
    state = transition(state, action, value);
    render(focusID);
    if (message) announce(message);
  }

  document.addEventListener("click", event => {
    const button = event.target.closest("button");
    if (!button || button.disabled) return;
    if (button.dataset.layout) { apply("layout", button.dataset.layout, "Composition changed. Selected task, view, and draft are preserved.", null); document.querySelector(`[data-layout="${state.layout}"]`).focus(); }
    else if (button.dataset.project) apply("project", button.dataset.project, "Project opened.", "page-title");
    else if (button.dataset.select) apply("select", button.dataset.select, "Task opened. Viewing does not accept or execute the result.");
    else if (button.dataset.tool) apply("tool", button.dataset.tool, "Task view changed.", button.dataset.tool === "files" ? "source" : "page-title");
    else if (button.dataset.answer) apply("answer", button.dataset.answer, "Illustrative answer sent once to this task request.");
    else if (button.dataset.scenario) apply("scenario", button.dataset.scenario, button.dataset.scenario === "relaunch" ? "Relaunch simulated. Metadata retained; live evidence is stale. No process started." : "Illustrative scenario selected.");
    else if (button.dataset.action === "overview") { const id = state.selected; apply("overview", null, "Returned to project. Task view and draft retained.", "row-" + id); }
    else if (button.dataset.action === "inbox") {
      const next = state.tasks.find(task => task.state === "question" || (task.state === "ready" && task.unread));
      if (next) apply("select", next.id, "Opened the next attention item. Intermediate activity stays inside its task.");
      else announce("No task needs attention in this example.");
    }
    else if (button.dataset.action === "accept") apply("accept", null, "Only this illustrated revision is accepted. Nothing ran.");
    else if (button.dataset.action === "resume") apply("resume", null, "Explicit resume simulated as a new attempt. No real agent started.");
    else if (button.dataset.action === "try" && currentTask(state)?.state === "ready") {
      if (projectFor(state).type === "document") {
        document.getElementById("document-content").hidden = false;
        announce("Document displayed in the prototype. Embedded examples are never executed; acceptance is unchanged.");
      } else app.querySelector("dialog").showModal();
    }
    else if (button.dataset.action === "dismiss") app.querySelector("dialog").close();
    else if (button.dataset.action === "confirm") { app.querySelector("dialog").close(); announce("Result action simulated. No process or network request started; acceptance is unchanged."); }
  });

  document.addEventListener("submit", event => {
    if (event.target.id === "new-task") { event.preventDefault(); apply("create", new FormData(event.target).get("goal") || "", "Task created in the selected project with the remembered agent. No actual process started."); }
    else if (event.target.id === "feedback") { event.preventDefault(); apply("feedback", new FormData(event.target).get("feedback") || "", "Feedback retained in this task; illustrated checks and review invalidated. No prompt sent."); }
  });

  document.addEventListener("input", event => {
    if (event.target.id === "source") {
      // Keep the textarea and selection intact while recording its draft.
      state = transition(state, "edit", event.target.value);
      const task = currentTask(state);
      app.querySelector("[data-task-state]").className = "state stale";
      app.querySelector("[data-task-state]").textContent = labels.stale;
      document.getElementById("revision-label").textContent = `Revision ${task.revision} · unsaved manual draft`;
      document.getElementById("draft-status").className = "unsaved";
      document.getElementById("draft-status").textContent = "Unsaved draft retained in this tab. Checks, review, and acceptance are no longer current.";
      announce("Unsaved draft retained. Checks, review, and acceptance are no longer current.");
    }
  });

  document.getElementById("other-state").addEventListener("change", event => {
    if (event.target.value) apply("scenario", event.target.value, "Illustrative recovery or failure state selected.");
    event.target.value = "";
  });

  render();
})();
