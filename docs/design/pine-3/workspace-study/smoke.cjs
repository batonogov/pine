// Interaction-contract checks for the local concept. No browser or providers run.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const { initialState, transition, currentTask, projects } = require("./study.js");
let checks = 0;
let failures = 0;
function check(name, run) {
  checks++;
  try { run(); console.log("PASS", name); }
  catch (error) { failures++; console.error("FAIL", name, "—", error.message); }
}

check("viewing a result changes unread only", () => {
  const before = initialState();
  const after = transition(before, "select", "task-2");
  assert.equal(currentTask(after).state, "ready");
  assert.equal(currentTask(after).unread, false);
  assert.equal(currentTask(after).accepted, false);
  assert.equal(before.tasks[1].unread, true);
});
check("answer belongs to a current actionable question and is one-shot", () => {
  let state = transition(initialState(), "select", "task-1");
  state = transition(state, "answer", "Keep structure");
  state = transition(state, "answer", "Overwrite answer");
  assert.equal(currentTask(state).answer, "Keep structure");
  assert.equal(currentTask(state).state, "working");
});
check("manual edit invalidates Ready and acceptance but preserves history", () => {
  let state = transition(initialState(), "select", "task-2");
  state = transition(state, "accept");
  state = transition(state, "edit", "unsaved draft");
  const task = currentTask(state);
  assert.equal(task.state, "stale");
  assert.equal(task.accepted, false);
  assert.equal(task.history[0].accepted, true);
  assert.equal(task.history[0].revision, 1);
  assert.equal(task.revision, 2);
});
check("repeated reviewed edit cycles receive distinct revision identities", () => {
  let state = transition(initialState(), "select", "task-2");
  state = transition(state, "edit", "draft A");
  state = transition(state, "edit", "draft A continued");
  assert.equal(currentTask(state).revision, 2, "one stale draft is one candidate");
  state = transition(state, "scenario", "ready");
  state = transition(state, "accept");
  assert.equal(currentTask(state).dirty, true, "a reviewed dirty tree may retain an unsaved draft");
  state = transition(state, "edit", "draft B");
  assert.equal(currentTask(state).revision, 3, "editing a reviewed dirty generation needs a new identity");
  assert.equal(currentTask(state).accepted, false);
  assert.deepEqual(currentTask(state).history, [
    { revision: 1, accepted: false },
    { revision: 2, accepted: true },
  ]);
  state = transition(state, "scenario", "ready");
  state = transition(state, "accept");
  state = transition(state, "edit", "draft C");
  assert.equal(currentTask(state).revision, 4);
  assert.equal(currentTask(state).history[2].revision, 3);
  assert.equal(currentTask(state).history[2].accepted, true);
});
check("composition and navigation preserve selected view and unsaved draft", () => {
  let state = transition(initialState(), "select", "task-2");
  state = transition(state, "tool", "files");
  state = transition(state, "edit", "draft stays");
  state = transition(state, "layout", "table");
  state = transition(state, "overview");
  state = transition(state, "project", "atlas");
  state = transition(state, "select", "task-2");
  assert.equal(currentTask(state).draft, "draft stays");
  assert.equal(currentTask(state).tool, "files");
  assert.equal(state.layout, "table");
  assert.equal(state.project, "canvas");
});
check("restoration preserves metadata and refuses stale question responses", () => {
  let state = transition(initialState(), "select", "task-1");
  state = transition(state, "scenario", "relaunch");
  const before = structuredClone(currentTask(state));
  state = transition(state, "answer", "Must not send");
  assert.deepEqual(currentTask(state), before);
  state = transition(state, "resume");
  assert.equal(currentTask(state).state, "working");
  assert.equal(currentTask(state).restored, false);
  assert.equal(currentTask(state).goal, before.goal);
});
check("app-wide relaunch invalidates every task without discarding metadata", () => {
  let state = transition(initialState(), "select", "task-2");
  state = transition(state, "accept");
  state = transition(state, "edit", "retained Canvas draft");
  state = transition(state, "scenario", "ready");
  state = transition(state, "feedback", "retained feedback reference");
  const before = structuredClone(state.tasks);
  state = transition(state, "scenario", "relaunch");
  for (const task of state.tasks) {
    const previous = before.find(item => item.id === task.id);
    assert.equal(task.restored, true, task.id);
    assert.equal(task.state, "stale", task.id);
    assert.equal(task.accepted, false, task.id);
    assert.equal(task.goal, previous.goal);
    assert.equal(task.draft, previous.draft);
    assert.equal(task.feedback, previous.feedback);
    assert.deepEqual(task.history, previous.history);
    state = transition(state, "select", task.id);
    state = transition(state, "answer", "must not answer old request");
    state = transition(state, "accept");
    assert.equal(currentTask(state).answer, previous.answer);
    assert.equal(currentTask(state).accepted, false);
  }
  state = transition(state, "select", "task-1");
  state = transition(state, "resume");
  assert.equal(currentTask(state).state, "working");
  assert.equal(state.tasks.find(task => task.id === "task-2").restored, true);
  state = transition(state, "overview");
  state = transition(state, "scenario", "relaunch");
  assert.ok(state.tasks.every(task => task.restored && task.state === "stale"));
});
check("new feedback invalidates evidence and retains earlier reviewed history", () => {
  let state = transition(initialState(), "select", "task-2");
  state = transition(state, "feedback", "Keep the toolbar smaller");
  assert.equal(currentTask(state).state, "working");
  assert.equal(currentTask(state).feedback, "Keep the toolbar smaller");
  assert.equal(currentTask(state).history[0].revision, 1);
  state = transition(state, "scenario", "ready");
  assert.deepEqual(currentTask(state).history.map(item => item.revision), [1, 2]);
});
check("all project types remain available without a universal run action", () => {
  assert.deepEqual(projects.map(project => project.type), ["web", "native", "cli", "document"]);
  for (const project of projects) {
    let state = transition(initialState(), "project", project.id);
    state = transition(state, "create", "A new outcome");
    assert.equal(currentTask(state).project, project.id);
    assert.equal(currentTask(state).state, "working");
  }
});
check("unavailable or unknown execution cannot accept or send feedback", () => {
  for (const status of ["unknown", "unavailable", "cancelled"]) {
    let state = transition(initialState(), "select", "task-2");
    state = transition(state, "scenario", status);
    state = transition(state, "accept");
    state = transition(state, "feedback", "Must not send");
    assert.equal(currentTask(state).accepted, false);
    assert.equal(currentTask(state).feedback, "");
    assert.equal(currentTask(state).state, status);
  }
});
check("rendering entered task text escapes markup", () => {
  const elements = new Map();
  const handlers = new Map();
  const document = {
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, { innerHTML: "", textContent: "", focus() {}, addEventListener() {} });
      return elements.get(id);
    },
    querySelectorAll() { return []; },
    addEventListener(type, handler) { handlers.set(type, handler); },
  };
  vm.runInNewContext(fs.readFileSync(__dirname + "/study.js", "utf8"), {
    document, structuredClone,
    FormData: class { get() { return '<img src=x onerror="bad()">'; } },
  });
  handlers.get("submit")({ target: { id: "new-task" }, preventDefault() {} });
  const markup = document.getElementById("app").innerHTML;
  assert.ok(markup.includes("&lt;img src=x onerror=&quot;bad()&quot;&gt;"));
  assert.ok(!markup.includes("<img"));
});
console.log(`${checks - failures}/${checks} interaction-contract checks passed.`);
if (failures) process.exitCode = 1;
