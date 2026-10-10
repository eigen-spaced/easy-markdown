(function () {
  "use strict";

  const native = window.webkit.messageHandlers;
  const content = document.getElementById("content");

  function escapeHtml(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  // ---------------------------------------------------------------- themes

  // Code themes as light/dark stylesheet pairs (files in hljs-themes/).
  const CODE_THEMES = {
    "github": ["github", "github-dark"],
    "atom-one": ["atom-one-light", "atom-one-dark"],
    "tokyo-night": ["tokyo-night-light", "tokyo-night-dark"],
    "solarized": ["solarized-light", "solarized-dark"],
    "gruvbox": ["gruvbox-light-medium", "gruvbox-dark-medium"],
    "stackoverflow": ["stackoverflow-light", "stackoverflow-dark"],
    "nord": ["nord", "nord"],
    "monokai": ["monokai", "monokai"],
    "dracula": ["dracula", "dracula"],
  };

  // Code theme used when the code theme is "auto".
  const PREVIEW_CODE_THEME = {
    "github": "github",
    "paper": "atom-one",
    "nord": "nord",
    "solarized": "solarized",
    "gruvbox": "gruvbox",
    "tokyo-night": "tokyo-night",
  };

  const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");

  function setTheme(preview, code) {
    const root = document.documentElement;
    root.className = root.className.replace(/\btheme-\S+/g, "").trim();
    root.classList.add("theme-" + preview);

    const pair = CODE_THEMES[code === "auto" ? PREVIEW_CODE_THEME[preview] : code] || CODE_THEMES.github;
    document.getElementById("hl-light").href = "easymd:///__easymd__/hljs-themes/" + pair[0] + ".css";
    document.getElementById("hl-dark").href = "easymd:///__easymd__/hljs-themes/" + pair[1] + ".css";
    reportThemeColors();
    // Diagrams take their colours from the theme, so redraw them.
    if (lastSource !== null && document.querySelector(".mermaid-block")) window.easymd.render(lastSource);
  }

  // Tell the native editor which colours the preview theme uses so the two panes match.
  function reportThemeColors() {
    const css = getComputedStyle(document.documentElement);
    const v = (name) => css.getPropertyValue(name).trim();
    native.theme.postMessage({
      bg: v("--bg"), fg: v("--fg"), muted: v("--muted"), link: v("--link"),
      heading: v("--heading"), code: v("--code-fg"), accent: v("--accent"),
    });
  }

  darkQuery.addEventListener("change", () => {
    reportThemeColors();
    if (lastSource !== null) window.easymd.render(lastSource);
  });

  // ---------------------------------------------------------------- markdown

  const md = window.markdownit({ html: true, linkify: true, typographer: false })
    .use(window.markdownitTaskLists, { enabled: false, label: true })
    .use(window.texmath, { engine: window.katex, delimiters: ["dollars", "beg_end"], katexOptions: { throwOnError: false } });

  function highlight(code, lang) {
    if (lang && hljs.getLanguage(lang)) {
      try { return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value; } catch (_) {}
    }
    return escapeHtml(code);
  }

  function lineAttr(token, env) {
    return token.map ? ' data-line="' + (token.map[0] + env.lineOffset) + '"' : "";
  }

  md.renderer.rules.fence = function (tokens, idx, options, env) {
    const token = tokens[idx];
    const lang = token.info.trim().split(/\s+/)[0].toLowerCase();
    const line = lineAttr(token, env);

    if (lang === "mermaid") {
      return '<div class="mermaid-block"' + line + ' data-src="' + escapeHtml(token.content) + '"></div>';
    }
    if (lang === "math" || lang === "latex" || lang === "tex" || lang === "katex") {
      return '<div class="math-block"' + line + ">" +
        katex.renderToString(token.content, { displayMode: true, throwOnError: false }) + "</div>";
    }
    // The label sits inside <code> so it inherits the code theme's colour.
    const label = lang ? '<span class="code-lang" aria-hidden="true">' + escapeHtml(lang) + "</span>" : "";
    return "<pre" + line + '><code class="hljs">' + label + highlight(token.content, lang) + "</code></pre>";
  };

  // Source-line anchors for scroll sync. Opening tokens carry attrs directly; renderers
  // that ignore attrs (math, raw HTML, indented code) get the attribute spliced in.
  md.core.ruler.push("line_anchors", function (state) {
    const offset = state.env.lineOffset || 0;
    for (const token of state.tokens) {
      if (token.map && token.nesting === 1) token.attrSet("data-line", String(token.map[0] + offset));
    }
  });
  for (const name of ["math_block", "math_block_eqno", "html_block", "code_block"]) {
    const original = md.renderer.rules[name];
    if (!original) continue;
    md.renderer.rules[name] = function (tokens, idx, options, env, self) {
      const html = original(tokens, idx, options, env, self);
      return html.replace(/^\s*<([a-zA-Z][\w-]*)/, (m, tag) => "<" + tag + lineAttr(tokens[idx], env));
    };
  }

  // GitHub-style heading ids so [link](#some-heading) works.
  md.core.ruler.push("heading_ids", function (state) {
    const seen = Object.create(null);
    const tokens = state.tokens;
    for (let i = 0; i < tokens.length; i++) {
      if (tokens[i].type !== "heading_open") continue;
      const text = tokens[i + 1].children
        .filter((t) => t.type === "text" || t.type === "code_inline")
        .map((t) => t.content)
        .join("");
      let slug = text.trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, "").replace(/\s/g, "-");
      if (slug in seen) slug += "-" + ++seen[slug];
      else seen[slug] = 0;
      tokens[i].attrSet("id", slug);
    }
  });

  // Hide YAML front matter; report how many lines it occupied so line anchors stay correct.
  function splitFrontMatter(src) {
    const m = /^---\r?\n[\s\S]*?\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/.exec(src);
    if (!m) return { body: src, lineOffset: 0 };
    return { body: src.slice(m[0].length), lineOffset: m[0].split("\n").length - 1 };
  }

  // ---------------------------------------------------------------- mermaid

  const mermaidCache = new Map();
  let mermaidLoading = null;
  let mermaidTheme = null;
  let mermaidId = 0;

  function loadMermaid() {
    if (!mermaidLoading) {
      mermaidLoading = new Promise((resolve, reject) => {
        const script = document.createElement("script");
        script.src = "easymd:///__easymd__/mermaid/mermaid.min.js";
        script.onload = resolve;
        script.onerror = reject;
        document.head.appendChild(script);
      });
    }
    return mermaidLoading;
  }

  // Derive diagram colours from the active preview theme ("base" is Mermaid's customisable theme).
  function mermaidThemeVariables() {
    const css = getComputedStyle(document.documentElement);
    const v = (name) => css.getPropertyValue(name).trim();
    return {
      darkMode: darkQuery.matches,
      background: v("--subtle-bg"),
      primaryColor: v("--bg"),
      primaryTextColor: v("--fg"),
      primaryBorderColor: v("--link"),
      secondaryColor: v("--subtle-bg"),
      tertiaryColor: v("--subtle-bg"),
      lineColor: v("--muted"),
      edgeLabelBackground: v("--subtle-bg"),
      clusterBkg: v("--subtle-bg"),
      textColor: v("--fg"),
      noteBkgColor: v("--subtle-bg"),
      noteTextColor: v("--fg"),
      fontFamily: v("--font-body"),
      fontSize: "14px",
    };
  }

  async function renderMermaid(generation, previous) {
    const blocks = Array.from(content.querySelectorAll(".mermaid-block"));
    if (!blocks.length) return;

    const themeVariables = mermaidThemeVariables();
    const theme = JSON.stringify(themeVariables);
    const todo = [];
    blocks.forEach((block, i) => {
      const key = theme + "\n" + block.dataset.src;
      const cached = mermaidCache.get(key);
      if (cached) {
        block.innerHTML = cached;
      } else {
        // Keep the previous diagram on screen while the new one renders to avoid flicker.
        if (previous[i]) block.innerHTML = previous[i];
        todo.push({ block, key });
      }
    });
    if (!todo.length) return;

    await loadMermaid();
    if (mermaidTheme !== theme) {
      window.mermaid.initialize({ startOnLoad: false, theme: "base", themeVariables, securityLevel: "strict" });
      mermaidTheme = theme;
    }
    for (const { block, key } of todo) {
      const id = "easymd-mermaid-" + ++mermaidId;
      let html;
      try {
        html = (await window.mermaid.render(id, block.dataset.src)).svg;
      } catch (e) {
        html = '<pre class="mermaid-error">' + escapeHtml(String((e && e.message) || e)) + "</pre>";
        document.getElementById("d" + id)?.remove();
        document.getElementById(id)?.remove();
      }
      if (mermaidCache.size > 200) mermaidCache.delete(mermaidCache.keys().next().value);
      mermaidCache.set(key, html);
      if (generation !== renderGeneration) return;
      block.innerHTML = html;
    }
  }

  // ---------------------------------------------------------------- scroll sync

  let anchorCache = null;
  let ignoreScrollUntil = 0;

  function anchors() {
    if (anchorCache) return anchorCache;
    const list = [];
    let lastLine = -1;
    let lastTop = -Infinity;
    for (const el of content.querySelectorAll("[data-line]")) {
      const line = +el.dataset.line;
      const top = el.getBoundingClientRect().top + window.scrollY;
      // Keep the list monotonic in both line and position.
      if (line <= lastLine || top < lastTop) continue;
      list.push({ line, top });
      lastLine = line;
      lastTop = top;
    }
    anchorCache = list;
    return list;
  }

  function maxScroll() {
    return document.documentElement.scrollHeight - window.innerHeight;
  }

  let pendingScrollY = 0;
  let pendingScrollFrame = 0;

  // `line` is fractional (0-based); a negative value means "the end of the document".
  function scrollToLine(line) {
    let y;
    if (line < 0) {
      y = maxScroll();
    } else {
      const a = anchors();
      if (!a.length) return;
      let i = 0;
      while (i + 1 < a.length && a[i + 1].line <= line) i++;
      const cur = a[i];
      const next = a[i + 1] || { line: cur.line + 1, top: document.documentElement.scrollHeight };
      const t = Math.max(0, Math.min(1, (line - cur.line) / Math.max(1, next.line - cur.line)));
      y = line < a[0].line ? 0 : cur.top + t * (next.top - cur.top) - 16;
    }
    // Apply once per frame so the preview moves in even steps alongside the editor.
    pendingScrollY = Math.max(0, y);
    ignoreScrollUntil = performance.now() + 150;
    if (!pendingScrollFrame) {
      pendingScrollFrame = requestAnimationFrame(() => {
        pendingScrollFrame = 0;
        ignoreScrollUntil = performance.now() + 150;
        window.scrollTo(0, pendingScrollY);
      });
    }
  }

  function lineAtTop() {
    if (window.scrollY >= maxScroll() - 2 && window.scrollY > 0) return -1;
    const a = anchors();
    if (!a.length) return 0;
    const y = window.scrollY + 16;
    let i = 0;
    while (i + 1 < a.length && a[i + 1].top <= y) i++;
    const cur = a[i];
    if (y < cur.top) return 0;
    const next = a[i + 1] || { line: cur.line + 1, top: document.documentElement.scrollHeight };
    return cur.line + ((y - cur.top) / Math.max(1, next.top - cur.top)) * (next.line - cur.line);
  }

  let scrollFrame = 0;
  window.addEventListener("scroll", () => {
    if (performance.now() < ignoreScrollUntil || scrollFrame) return;
    scrollFrame = requestAnimationFrame(() => {
      scrollFrame = 0;
      native.scroll.postMessage(lineAtTop());
    });
  }, { passive: true });

  window.addEventListener("resize", () => { anchorCache = null; });

  // Clicking an image opens it in the native viewer; linked images still follow their link.
  content.addEventListener("click", (event) => {
    const img = event.target.closest("img");
    if (!img || img.closest("a") || !native.image) return;
    event.preventDefault();
    native.image.postMessage(img.currentSrc || img.src);
  });
  new ResizeObserver(() => { anchorCache = null; }).observe(content);

  // ---------------------------------------------------------------- render

  let renderGeneration = 0;
  let lastSource = null;

  function imagesSettled(timeoutMs) {
    const pending = Array.from(content.querySelectorAll("img"))
      .filter((img) => !img.complete)
      .map((img) => new Promise((resolve) => {
        img.addEventListener("load", resolve, { once: true });
        img.addEventListener("error", resolve, { once: true });
      }));
    const timeout = new Promise((resolve) => setTimeout(resolve, timeoutMs));
    return Promise.race([Promise.all(pending), timeout]);
  }

  window.easymd = {
    // Resolves once images and diagrams are ready so PDF export captures them.
    async render(src) {
      lastSource = src;
      const generation = ++renderGeneration;
      const previous = Array.from(content.querySelectorAll(".mermaid-block"), (b) => b.innerHTML);
      const { body, lineOffset } = splitFrontMatter(src);
      content.innerHTML = md.render(body, { lineOffset });
      anchorCache = null;
      await Promise.all([renderMermaid(generation, previous), imagesSettled(4000)]);
      anchorCache = null;
      return true;
    },
    setTheme,
    scrollToLine,
  };

  native.ready.postMessage(true);
})();
