/* Pine landing — i18n, workflow switcher, lightbox, scroll reveals */
(function () {
    "use strict";

    /* ---------- i18n ---------- */

    var LANGS = ["en", "de", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans"];
    var STORAGE_KEY = "pine-lang";
    var cache = {};

    // English strings live in the HTML itself; snapshot them so switching
    // back to English never requires a network request.
    function snapshotEnglish() {
        var dict = {};
        document.querySelectorAll("[data-i18n]").forEach(function (el) {
            dict[el.getAttribute("data-i18n")] = el.textContent;
        });
        document.querySelectorAll("[data-i18n-html]").forEach(function (el) {
            dict[el.getAttribute("data-i18n-html")] = el.innerHTML;
        });
        document.querySelectorAll("[data-i18n-alt]").forEach(function (el) {
            dict[el.getAttribute("data-i18n-alt")] = el.alt;
        });
        document.querySelectorAll("[data-i18n-aria-label]").forEach(function (el) {
            dict[el.getAttribute("data-i18n-aria-label")] = el.getAttribute("aria-label");
        });
        dict["meta.title"] = document.title;
        var metaSelectors = {
            "meta.description": 'meta[name="description"]',
            "meta.ogTitle": 'meta[property="og:title"]',
            "meta.ogDescription": 'meta[property="og:description"]',
            "meta.twitterTitle": 'meta[name="twitter:title"]',
            "meta.twitterDescription": 'meta[name="twitter:description"]'
        };
        Object.keys(metaSelectors).forEach(function (key) {
            var el = document.querySelector(metaSelectors[key]);
            if (el) dict[key] = el.content;
        });
        return dict;
    }

    function detectLang() {
        var stored = localStorage.getItem(STORAGE_KEY);
        if (stored && LANGS.indexOf(stored) !== -1) return stored;
        var nav = navigator.language || "";
        if (LANGS.indexOf(nav) !== -1) return nav;
        var short = nav.slice(0, 2);
        if (short === "zh") return "zh-Hans";
        if (short === "pt") return "pt-BR";
        return LANGS.indexOf(short) !== -1 ? short : "en";
    }

    function applyLang(lang) {
        var dict = cache[lang];
        if (!dict) return;

        document.documentElement.lang = lang;
        if (dict["meta.title"]) document.title = dict["meta.title"];
        var metaMap = {
            "meta.description": 'meta[name="description"]',
            "meta.ogTitle": 'meta[property="og:title"]',
            "meta.ogDescription": 'meta[property="og:description"]',
            "meta.twitterTitle": 'meta[name="twitter:title"]',
            "meta.twitterDescription": 'meta[name="twitter:description"]'
        };
        Object.keys(metaMap).forEach(function (key) {
            var el = document.querySelector(metaMap[key]);
            if (el && dict[key]) el.content = dict[key];
        });

        document.querySelectorAll("[data-i18n]").forEach(function (el) {
            var value = dict[el.getAttribute("data-i18n")];
            if (value) el.textContent = value;
        });
        document.querySelectorAll("[data-i18n-html]").forEach(function (el) {
            var value = dict[el.getAttribute("data-i18n-html")];
            if (value) el.innerHTML = value;
        });
        document.querySelectorAll("[data-i18n-alt]").forEach(function (el) {
            var value = dict[el.getAttribute("data-i18n-alt")];
            if (value) el.alt = value;
        });
        document.querySelectorAll("[data-i18n-aria-label]").forEach(function (el) {
            var value = dict[el.getAttribute("data-i18n-aria-label")];
            if (value) el.setAttribute("aria-label", value);
        });

        document.querySelectorAll(".screenshot-trigger").forEach(function (button) {
            var img = button.querySelector("img");
            if (img) button.setAttribute("aria-label", img.alt);
        });

        if (dict["install.copied"]) {
            document.querySelectorAll(".copy-btn").forEach(function (button) {
                button.setAttribute("data-copied-label", dict["install.copied"]);
            });
        }

        localStorage.setItem(STORAGE_KEY, lang);
    }

    function setLang(lang) {
        if (cache[lang]) {
            applyLang(lang);
            return;
        }
        fetch("i18n/" + encodeURIComponent(lang) + ".json")
            .then(function (res) {
                if (!res.ok) throw new Error("locale " + res.status);
                return res.json();
            })
            .then(function (dict) {
                cache[lang] = dict;
                applyLang(lang);
            })
            .catch(function () {
                // Offline / file:// preview: stay on the current language.
            });
    }

    cache.en = snapshotEnglish();
    var langSelect = document.getElementById("lang-toggle");
    var initialLang = detectLang();
    if (langSelect) {
        langSelect.value = initialLang;
        langSelect.addEventListener("change", function () {
            setLang(this.value);
        });
    }
    if (initialLang !== "en") setLang(initialLang);

    /* ---------- workflow step switcher ---------- */

    var steps = Array.from(document.querySelectorAll(".workflow-step"));
    var frames = Array.from(document.querySelectorAll(".workflow-frame"));
    var counterCurrent = document.getElementById("workflow-counter-current");

    function selectStep(index) {
        steps.forEach(function (step, i) {
            var current = i === index;
            step.classList.toggle("is-current", current);
            step.setAttribute("aria-selected", current ? "true" : "false");
        });
        frames.forEach(function (frame, i) {
            frame.classList.toggle("is-current", i === index);
        });
        if (counterCurrent) {
            counterCurrent.textContent = String(index + 1).padStart(2, "0");
        }
    }

    steps.forEach(function (step, i) {
        step.addEventListener("click", function () {
            selectStep(i);
        });
    });

    /* ---------- copy buttons ---------- */

    document.querySelectorAll(".copy-btn").forEach(function (button) {
        button.addEventListener("click", function () {
            var target = document.querySelector(button.getAttribute("data-copy-target"));
            if (!target) return;
            var text = target.textContent.trim();
            var done = function () {
                button.classList.add("is-copied");
                var label = button.textContent;
                button.textContent = button.getAttribute("data-copied-label") || label;
                setTimeout(function () {
                    button.classList.remove("is-copied");
                    button.textContent = label;
                }, 1600);
            };
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text).then(done, done);
            } else {
                var area = document.createElement("textarea");
                area.value = text;
                document.body.appendChild(area);
                area.select();
                try { document.execCommand("copy"); } catch (e) { /* noop */ }
                document.body.removeChild(area);
                done();
            }
        });
    });

    /* ---------- lightbox ---------- */

    var lightbox = document.getElementById("lightbox");
    var lightboxImg = document.getElementById("lightbox-img");
    var lightboxClose = document.getElementById("lightbox-close");

    if (lightbox && lightboxImg && lightboxClose) {
        document.querySelectorAll(".screenshot-trigger").forEach(function (button) {
            button.addEventListener("click", function () {
                var img = this.querySelector("img");
                if (!img) return;
                lightboxImg.src = img.src;
                lightboxImg.alt = img.alt;
                lightbox.showModal();
                lightboxClose.focus();
            });
        });

        lightbox.addEventListener("click", function (e) {
            if (e.target === lightbox) lightbox.close();
        });

        lightboxClose.addEventListener("click", function () {
            lightbox.close();
        });
    }

    /* ---------- scroll reveals + progress ---------- */

    var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
    if (reduceMotion.matches) return;

    document.documentElement.classList.add("scroll-motion");

    var progress = document.createElement("div");
    progress.className = "scroll-progress";
    progress.setAttribute("aria-hidden", "true");
    document.body.appendChild(progress);

    var revealSelectors = [
        ".section-head > *",
        ".mini-card",
        ".compare-card",
        ".feature-card",
        ".screenshot-gallery figure",
        ".manifesto-card > *",
        ".story-card > *",
        ".install-panel > *",
        ".workflow-grid > *"
    ];

    var revealTargets = [];
    revealSelectors.forEach(function (selector) {
        document.querySelectorAll(selector).forEach(function (el, index) {
            el.classList.add("scroll-reveal");
            el.style.setProperty("--reveal-delay", ((index % 4) * 80) + "ms");
            revealTargets.push(el);
        });
    });

    var observer = new IntersectionObserver(function (entries, obs) {
        entries.forEach(function (entry) {
            if (!entry.isIntersecting) return;
            entry.target.classList.add("is-visible");
            obs.unobserve(entry.target);
        });
    }, { threshold: 0.12, rootMargin: "0px 0px -6% 0px" });

    revealTargets.forEach(function (el) {
        if (el.getBoundingClientRect().top < window.innerHeight * 0.94) {
            el.classList.add("is-visible");
        } else {
            observer.observe(el);
        }
    });

    var framePending = false;
    function updateProgress() {
        var maxScroll = document.documentElement.scrollHeight - window.innerHeight;
        var ratio = maxScroll > 0 ? window.scrollY / maxScroll : 0;
        progress.style.transform = "scaleX(" + Math.min(1, Math.max(0, ratio)) + ")";
        framePending = false;
    }

    window.addEventListener("scroll", function () {
        if (framePending) return;
        framePending = true;
        window.requestAnimationFrame(updateProgress);
    }, { passive: true });
    updateProgress();
})();
