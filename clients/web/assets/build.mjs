import { build } from 'esbuild';
import { copyFile, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const outdir = fileURLToPath(new URL('../priv/static/monaco', import.meta.url));
const vs = fileURLToPath(new URL('./node_modules/monaco-editor/esm/vs/', import.meta.url));
await build({
  absWorkingDir: fileURLToPath(new URL('.', import.meta.url)),
  entryPoints: {
    editor: vs + 'editor/editor.main.js',
    'editor.worker': vs + 'editor/editor.worker.start.js',
    'css.worker': vs + 'languages/features/css/css.worker.js',
    'html.worker': vs + 'languages/features/html/html.worker.js',
    'json.worker': vs + 'languages/features/json/json.worker.js',
    'ts.worker': vs + 'languages/features/typescript/ts.worker.js',
  },
  bundle: true,
  splitting: true,
  format: 'esm',
  target: ['es2022'],
  minify: true,
  outdir,
  loader: {'.ttf': 'file', '.svg': 'file'},
  plugins: [{
    name: 'owner-csp',
    setup(builder) {
      builder.onLoad({filter: /[\\/](domStylesheets|contextview|editor\.main)\.js$/}, async ({path}) => {
        let contents = await readFile(path, 'utf8');
        if (path.endsWith('editor.main.js')) {
          // This browser does not run an LSP or connect to language servers.
          contents = contents.replace(/^import .*monaco-lsp-client.*\nexport \{ index as lsp \};\n/m, '');
        } else {
          const factory = "const style = document.createElement('style');";
          if (!contents.includes(factory)) throw new Error(`Monaco stylesheet factory changed: ${path}`);
          contents = contents.replaceAll(factory, `${factory}
            style.nonce = document.querySelector('meta[name="h-style-nonce"]')?.content || '';`);
        }
        return {contents, loader: 'js'};
      });
    }
  }]
});
await copyFile(new URL('./node_modules/monaco-editor/LICENSE', import.meta.url), `${outdir}/LICENSE`);
await copyFile(new URL('./node_modules/monaco-editor/ThirdPartyNotices.txt', import.meta.url), `${outdir}/ThirdPartyNotices.txt`);
