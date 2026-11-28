import { build } from "esbuild";
import { mkdir, readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const assetsDir = fileURLToPath(new URL(".", import.meta.url));
const outdir = fileURLToPath(new URL("../priv/static", import.meta.url));
const outfile = path.join(outdir, "analytics.js");

async function checkSupplyChain() {
  const lockPath = path.join(assetsDir, "package-lock.json");
  const lock = JSON.parse(await readFile(lockPath, "utf8"));
  const packages = lock.packages || {};

  // esbuild ships a benign platform-binary postinstall that we skipped via --ignore-scripts
  const allowedInstallScriptPackages = new Set(["node_modules/esbuild"]);

  for (const [pkgPath, meta] of Object.entries(packages)) {
    if (pkgPath === "") continue;

    if (!meta.resolved || !meta.resolved.startsWith("https://registry.npmjs.org/")) {
      throw new Error(`Supply-chain gate failed: ${pkgPath} has disallowed resolved URL: ${meta.resolved}`);
    }
    if (!meta.integrity || !meta.integrity.startsWith("sha512-")) {
      throw new Error(`Supply-chain gate failed: ${pkgPath} lacks sha512 integrity: ${meta.integrity}`);
    }
    if (meta.hasInstallScript === true && !allowedInstallScriptPackages.has(pkgPath)) {
      throw new Error(`Supply-chain gate failed: ${pkgPath} declares hasInstallScript === true`);
    }
  }

  const nodeModulesDir = path.join(assetsDir, "node_modules");
  await scanNodeModulesPackageJsons(nodeModulesDir, allowedInstallScriptPackages);
}

async function scanNodeModulesPackageJsons(nodeModulesDir, allowedInstallScriptPackages) {
  const entries = await readdir(nodeModulesDir, { withFileTypes: true });
  for (const entry of entries) {
    if (entry.name.startsWith(".")) continue;
    const fullPath = path.join(nodeModulesDir, entry.name);
    if (!entry.isDirectory()) continue;

    if (entry.name.startsWith("@")) {
      const subEntries = await readdir(fullPath, { withFileTypes: true });
      for (const sub of subEntries) {
        if (sub.isDirectory()) {
          await checkPackageJsonScripts(path.join(fullPath, sub.name), allowedInstallScriptPackages);
        }
      }
    } else {
      await checkPackageJsonScripts(fullPath, allowedInstallScriptPackages);
    }
  }
}

async function checkPackageJsonScripts(pkgDir, allowedInstallScriptPackages) {
  const relKey = path.relative(assetsDir, pkgDir).split(path.sep).join("/");
  const pjPath = path.join(pkgDir, "package.json");
  let pj;
  try {
    pj = JSON.parse(await readFile(pjPath, "utf8"));
  } catch (_err) {
    return;
  }

  const scripts = pj.scripts || {};
  for (const hook of ["preinstall", "install", "postinstall"]) {
    if (scripts[hook] && !allowedInstallScriptPackages.has(relKey)) {
      throw new Error(`Supply-chain gate failed: ${relKey}/package.json defines ${hook} script`);
    }
  }

  const nestedModules = path.join(pkgDir, "node_modules");
  try {
    await scanNodeModulesPackageJsons(nestedModules, allowedInstallScriptPackages);
  } catch (_err) {
    // No nested node_modules
  }
}

const cspSanitizePlugin = {
  name: "analytics-csp-sanitize",
  setup(builder) {
    builder.onLoad({ filter: /vega-loader[\\/]build[\\/]vega-loader\.browser\.js$/ }, async ({ path: filePath }) => {
      let contents = await readFile(filePath, "utf8");
      const httpLoaderPattern = /async function httpLoader\(url, options\) \{[\s\S]*?\n\}/;
      if (!httpLoaderPattern.test(contents)) {
        throw new Error(`Expected httpLoader function in ${filePath}`);
      }
      contents = contents.replace(
        httpLoaderPattern,
        `async function httpLoader() {\n  return Promise.reject(new Error("External network/file loading disabled by H policy"));\n}`
      );
      return { contents, loader: "js" };
    });

    builder.onLoad({ filter: /vega-runtime[\\/]build[\\/]vega-runtime\.js$/ }, async ({ path: filePath }) => {
      let contents = await readFile(filePath, "utf8");
      contents = contents
        .replace(
          "const fn = Function(...args.concat(code));",
          `const fn = () => { throw new Error("Codegen disabled under CSP; use vega-interpreter"); };`
        )
        .replace(
          "const get = Function('_', `return _${ref};`);",
          `const get = () => { throw new Error("Codegen disabled under CSP; use vega-interpreter"); };`
        )
        .replace(
          "const fn = Function('a', 'b', 'var u, v; return ' + fields.map(map).join('') + '0;');",
          `const fn = () => { throw new Error("Codegen disabled under CSP; use vega-interpreter"); };`
        );
      return { contents, loader: "js" };
    });

    builder.onLoad({ filter: /d3-dsv[\\/]src[\\/]dsv\.js$/ }, async ({ path: filePath }) => {
      let contents = await readFile(filePath, "utf8");
      const fnPattern = /function objectConverter\(columns\) \{[\s\S]*?\n\}/;
      if (!fnPattern.test(contents)) {
        throw new Error(`Expected objectConverter in ${filePath}`);
      }
      contents = contents.replace(
        fnPattern,
        `function objectConverter(columns) {\n  return function(d) {\n    const out = {};\n    for (let i = 0; i < columns.length; i++) out[columns[i]] = d[i] || "";\n    return out;\n  };\n}`
      );
      return { contents, loader: "js" };
    });
    builder.onLoad({ filter: /vega-crossfilter[\\/]build[\\/]vega-crossfilter\.js$/ }, async ({ path: filePath }) => {
      let contents = await readFile(filePath, "utf8");
      contents = contents
        .replaceAll("this.eval(", "this._eval(")
        .replaceAll("  eval(", "  _eval(");
      return { contents, loader: "js" };
    });
  }
};

async function checkPostBundleCsp(bundlePath) {
  const code = await readFile(bundlePath, "utf8");
  const forbidden = [
    { label: 'createElement("style")', re: /createElement\(["']style["']\)/g },
    { label: 'createElement("script")', re: /createElement\(["']script["']\)/g },
    { label: "new Function", re: /\bnew\s+Function\b/g },
    { label: "Function(", re: /\bFunction\s*\(/g },
    { label: "eval(", re: /\beval\s*\(/g },
    { label: "fetch(", re: /\bfetch\s*\(/g },
    { label: "XMLHttpRequest", re: /\bXMLHttpRequest\b/g },
    { label: "child_process", re: /\bchild_process\b/g }
  ];

  for (const { label, re } of forbidden) {
    const match = code.match(re);
    if (match) {
      throw new Error(`Post-bundle CSP gate failed: found ${match.length} match(es) for ${label} in ${bundlePath}`);
    }
  }
}

await checkSupplyChain();
await mkdir(outdir, { recursive: true });

await build({
  absWorkingDir: assetsDir,
  entryPoints: [path.join(assetsDir, "src/analytics_hook.js")],
  bundle: true,
  minify: true,
  format: "esm",
  target: ["es2022"],
  outfile,
  plugins: [cspSanitizePlugin]
});

await checkPostBundleCsp(outfile);
console.log(`Supply-chain + CSP gates passed. Built ${outfile}`);
