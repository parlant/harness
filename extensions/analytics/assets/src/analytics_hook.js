const BLOCKED_ERROR = "External network/file loading disabled by H policy";

const blockedLoader = {
  load: () => Promise.reject(new Error(BLOCKED_ERROR)),
  sanitize: () => Promise.reject(new Error(BLOCKED_ERROR)),
  http: () => Promise.reject(new Error(BLOCKED_ERROR)),
  file: () => Promise.reject(new Error(BLOCKED_ERROR))
};

function readThemeVars() {
  const styles = getComputedStyle(document.documentElement);
  const pick = (name, fallback) => {
    const val = styles.getPropertyValue(name).trim();
    return val || fallback;
  };
  return {
    text: pick("--text", "#161b22"),
    muted: pick("--muted", "#59636e"),
    border: pick("--border", "#d9dfe7"),
    surface: pick("--surface", "#ffffff"),
    surface2: pick("--surface-2", "#f0f2f5"),
    accent: pick("--accent", "#0969da"),
    mono: pick("--mono", "ui-monospace, monospace"),
    sans: pick("--sans", "-apple-system, BlinkMacSystemFont, sans-serif")
  };
}

function buildThemeConfig(baseConfig = {}) {
  const t = readThemeVars();
  const theme = {
    background: "transparent",
    font: t.sans,
    axis: {
      domainColor: t.border,
      gridColor: t.border,
      gridOpacity: 0.55,
      tickColor: t.border,
      labelColor: t.muted,
      titleColor: t.text,
      labelFontSize: 11,
      titleFontSize: 11,
      titleFontWeight: 500
    },
    legend: {
      labelColor: t.text,
      titleColor: t.text,
      labelFontSize: 11,
      titleFontSize: 11
    },
    title: {
      color: t.text,
      subtitleColor: t.muted
    },
    view: {
      stroke: "transparent"
    },
    text: {
      color: t.text
    },
    range: {
      category: [t.accent, "#2da44e", "#bf8700", "#8250df", "#cf222e", "#0598bc", "#e16f24"]
    }
  };
  return {
    ...theme,
    ...baseConfig,
    axis: { ...theme.axis, ...(baseConfig.axis || {}) },
    legend: { ...theme.legend, ...(baseConfig.legend || {}) },
    title: { ...theme.title, ...(baseConfig.title || {}) },
    view: { ...theme.view, ...(baseConfig.view || {}) },
    text: { ...theme.text, ...(baseConfig.text || {}) },
    range: { ...theme.range, ...(baseConfig.range || {}) }
  };
}

import { compile } from "vega-lite";
import { parse, View } from "vega";
import { expressionInterpreter } from "vega-interpreter";

const AnalyticsVegaChart = {
  mounted() {
    this._view = null;
    this._resizeObserver = null;
    this._resizeTimer = null;
    this._lastSpec = null;
    this._canvas = null;
    this._renderChart();
    this._setupResizeObserver();
  },

  updated() {
    this._renderChart();
  },

  destroyed() {
    if (this._resizeTimer) {
      window.clearTimeout(this._resizeTimer);
      this._resizeTimer = null;
    }
    if (this._resizeObserver) {
      this._resizeObserver.disconnect();
      this._resizeObserver = null;
    }
    if (this._view) {
      this._view.finalize();
      this._view = null;
    }
    this._canvas = null;
  },

  _ensureCanvas() {
    if (!this._canvas || !this._canvas.isConnected) {
      this._canvas = document.createElement("div");
      this._canvas.className = "analytics-vega-canvas";
      this.el.replaceChildren(this._canvas);
    }
    return this._canvas;
  },

  _setupResizeObserver() {
    if (typeof ResizeObserver !== "function") return;
    this._resizeObserver = new ResizeObserver(() => {
      if (this._resizeTimer) window.clearTimeout(this._resizeTimer);
      this._resizeTimer = window.setTimeout(() => {
        this._resizeTimer = null;
        this._renderChart(true);
      }, 120);
    });
    this._resizeObserver.observe(this.el);
  },

  _renderChart(forceResize = false) {
    const raw = this.el.dataset.spec;
    if (!raw) return;
    if (!forceResize && raw === this._lastSpec && this._view) return;
    this._lastSpec = raw;

    let vlSpec;
    try {
      vlSpec = JSON.parse(raw);
    } catch (_err) {
      return;
    }

    const rect = this.el.getBoundingClientRect();
    const width = Math.max(Math.floor(rect.width) - 4, 220);

    const specWithTheme = {
      ...vlSpec,
      width: vlSpec.width === "container" || !vlSpec.width ? width : vlSpec.width,
      autosize: vlSpec.autosize || { type: "fit", contains: "padding" },
      config: buildThemeConfig(vlSpec.config || {})
    };

    try {
      const compiled = compile(specWithTheme);
      const runtime = parse(compiled.spec, undefined, { ast: true });

      if (this._view) {
        this._view.finalize();
        this._view = null;
      }

      const view = new View(runtime, {
        expr: expressionInterpreter,
        loader: blockedLoader,
        renderer: "svg",
        hover: true
      });

      const clickEvent = this.el.dataset.clickEvent;
      if (clickEvent) {
        view.addEventListener("click", (_event, item) => {
          if (item?.datum) {
            this.pushEvent(clickEvent, { datum: item.datum });
          }
        });
      }

      const target = this._ensureCanvas();
      view.initialize(target).runAsync().catch(() => {});
      this._view = view;
    } catch (_err) {
      // Keep page resilient on invalid specs
    }
  }
};

export const hooks = { AnalyticsVegaChart };

if (typeof window !== "undefined" && typeof window.registerHWebHooks === "function") {
  window.registerHWebHooks(hooks);
}
