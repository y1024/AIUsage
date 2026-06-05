import Foundation

// MARK: - JSON Web Editor Assets
// 内嵌 Web 代码编辑器（WKWebView）使用的静态 HTML/CSS/JS 资源。
// 从 JSONRawEditorView 抽离，避免单文件超长（>800 行必拆分）。
enum JSONWebEditorAssets {
    static let html = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <style>
        :root {
          color-scheme: light dark;
          --bg: color-mix(in srgb, Canvas 94%, CanvasText 6%);
          --panel: Canvas;
          --text: CanvasText;
          --muted: color-mix(in srgb, CanvasText 46%, transparent);
          --gutter: color-mix(in srgb, CanvasText 36%, transparent);
          --line: color-mix(in srgb, CanvasText 12%, transparent);
          --selection: color-mix(in srgb, Highlight 34%, transparent);
          --active-line: color-mix(in srgb, Highlight 10%, transparent);
          --find: rgba(255, 210, 84, .46);
          --find-active: rgba(255, 149, 0, .72);
          --source-common: color-mix(in srgb, #3b82f6 12%, transparent);
          --source-node: color-mix(in srgb, #10a37f 12%, transparent);
          --source-override: color-mix(in srgb, #f59e0b 16%, transparent);
          --key: #008c8c;
          --string: #138a36;
          --number: #c56a00;
          --constant: #8e44ad;
        }
        html, body {
          margin: 0;
          width: 100%;
          height: 100%;
          overflow: hidden;
          background: var(--bg);
          color: var(--text);
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
        }
        body {
          display: flex;
          flex-direction: column;
        }
        #findBar {
          display: none;
          align-items: center;
          gap: 6px;
          min-height: 34px;
          padding: 6px 8px;
          border-bottom: 1px solid var(--line);
          background: color-mix(in srgb, Canvas 92%, CanvasText 8%);
          box-sizing: border-box;
          font-size: 12px;
        }
        #findBar.visible { display: flex; }
        #findInput {
          flex: 1;
          min-width: 80px;
          height: 22px;
          border: 1px solid var(--line);
          border-radius: 6px;
          padding: 0 8px;
          background: Canvas;
          color: CanvasText;
          outline: none;
          font-size: 12px;
        }
        #findInput:focus {
          border-color: color-mix(in srgb, Highlight 70%, var(--line));
          box-shadow: 0 0 0 2px color-mix(in srgb, Highlight 18%, transparent);
        }
        .findButton {
          width: 24px;
          height: 22px;
          border: 1px solid var(--line);
          border-radius: 6px;
          background: Canvas;
          color: CanvasText;
          font-size: 12px;
          padding: 0;
        }
        #findCount {
          color: var(--muted);
          font-variant-numeric: tabular-nums;
          min-width: 48px;
          text-align: right;
        }
        #shell {
          position: relative;
          flex: 1;
          min-height: 0;
          display: grid;
          grid-template-columns: 48px 1fr;
          background: var(--panel);
        }
        #gutterClip {
          position: relative;
          overflow: hidden;
          border-right: 1px solid var(--line);
          background: color-mix(in srgb, Canvas 88%, CanvasText 12%);
        }
        #gutter {
          position: absolute;
          left: 0;
          right: 0;
          top: 0;
          padding: 12px 4px 12px 0;
          box-sizing: border-box;
          color: var(--gutter);
          font: 12px/20px ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
          user-select: none;
        }
        .gutterLine {
          height: 20px;
          display: grid;
          grid-template-columns: 14px 1fr;
          align-items: center;
          column-gap: 3px;
        }
        .source-common { background: var(--source-common); }
        .source-node { background: var(--source-node); }
        .source-override { background: var(--source-override); }
        .foldToggle {
          width: 14px;
          height: 18px;
          border: 0;
          padding: 0;
          background: transparent;
          color: var(--gutter);
          font: 10px/18px -apple-system, BlinkMacSystemFont, sans-serif;
          cursor: pointer;
          opacity: .75;
        }
        .foldToggle:hover {
          color: var(--text);
          opacity: 1;
        }
        .foldToggle.empty {
          cursor: default;
          opacity: 0;
        }
        .lineNumber {
          text-align: right;
          padding-right: 3px;
        }
        #codeArea {
          position: relative;
          overflow: hidden;
          background:
            linear-gradient(var(--active-line), var(--active-line)) 0 12px / 100% 20px no-repeat,
            Canvas;
        }
        #highlight, #input {
          position: absolute;
          inset: 0;
          box-sizing: border-box;
          margin: 0;
          border: 0;
          min-width: 100%;
          min-height: 100%;
          font: 12px/20px ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
          tab-size: 2;
          white-space: pre;
        }
        #lineBackgrounds {
          position: absolute;
          inset: 0;
          box-sizing: border-box;
          padding: 12px 0;
          overflow: visible;
          pointer-events: none;
        }
        .lineBackground {
          height: 20px;
          width: 100%;
        }
        #highlight {
          overflow: visible;
          color: var(--text);
          pointer-events: none;
          padding: 12px 0;
        }
        #input {
          overflow: auto;
          resize: none;
          outline: none;
          background: transparent;
          padding: 12px;
          color: transparent;
          caret-color: var(--text);
          -webkit-text-fill-color: transparent;
          selection-background-color: var(--selection);
        }
        #input::selection {
          background: var(--selection);
        }
        .readonly #input {
          display: none;
        }
        .readonly #highlight {
          overflow: auto;
          pointer-events: auto;
          user-select: text;
          white-space: pre;
        }
        .codeLine {
          display: block;
          min-width: 100%;
          width: max-content;
          min-height: 20px;
          padding: 0 12px;
          box-sizing: border-box;
        }
        .key { color: var(--key); }
        .string { color: var(--string); }
        .number { color: var(--number); }
        .constant { color: var(--constant); }
        .match {
          background: var(--find);
          border-radius: 2px;
        }
        .match.active {
          background: var(--find-active);
        }
        .foldPlaceholder {
          color: var(--muted);
          font-style: italic;
        }
      </style>
    </head>
    <body>
      <div id="findBar">
        <input id="findInput" placeholder="Find" autocomplete="off" spellcheck="false">
        <span id="findCount">0/0</span>
        <button class="findButton" id="prevButton" title="Previous">↑</button>
        <button class="findButton" id="nextButton" title="Next">↓</button>
        <button class="findButton" id="closeButton" title="Close">×</button>
      </div>
      <div id="shell">
        <div id="gutterClip"><div id="gutter">1</div></div>
        <div id="codeArea">
          <div id="lineBackgrounds"></div>
          <pre id="highlight"></pre>
          <textarea id="input" spellcheck="false" autocorrect="off" autocapitalize="off"></textarea>
        </div>
      </div>
      <script>
        const input = document.getElementById('input');
        const highlight = document.getElementById('highlight');
        const lineBackgrounds = document.getElementById('lineBackgrounds');
        const gutter = document.getElementById('gutter');
        const shell = document.getElementById('shell');
        const findBar = document.getElementById('findBar');
        const findInput = document.getElementById('findInput');
        const findCount = document.getElementById('findCount');
        const prevButton = document.getElementById('prevButton');
        const nextButton = document.getElementById('nextButton');
        const closeButton = document.getElementById('closeButton');
        let textValue = '';
        let editable = true;
        let query = '';
        let matches = [];
        let activeMatch = -1;
        let applying = false;
        let foldedRanges = new Map();
        let foldRanges = new Map();
        let lineMarkers = {};
        let lineHeight = 20;

        function escapeHTML(value) {
          return value
            .replaceAll('&', '&amp;')
            .replaceAll('<', '&lt;')
            .replaceAll('>', '&gt;')
            .replaceAll('"', '&quot;');
        }

        function tokenClass(source, value, end) {
          if (/^"(?:[^"\\\\]|\\\\.)*"$/.test(value)) {
            let idx = end;
            while (idx < source.length && /\\s/.test(source[idx])) idx++;
            return source[idx] === ':' ? 'key' : 'string';
          }
          if (/^-?\\d/.test(value)) return 'number';
          if (/^(true|false|null)$/.test(value)) return 'constant';
          return '';
        }

        function lineStarts(source) {
          const starts = [0];
          for (let i = 0; i < source.length; i++) {
            if (source[i] === '\\n') starts.push(i + 1);
          }
          return starts;
        }

        function lineForIndex(starts, index) {
          let lo = 0, hi = starts.length - 1;
          while (lo <= hi) {
            const mid = Math.floor((lo + hi) / 2);
            if (starts[mid] <= index) lo = mid + 1;
            else hi = mid - 1;
          }
          return Math.max(0, hi);
        }

        function rebuildFoldRanges() {
          foldRanges.clear();
          const starts = lineStarts(textValue);
          const stack = [];
          let inString = false;
          let escape = false;
          for (let i = 0; i < textValue.length; i++) {
            const ch = textValue[i];
            if (inString) {
              if (escape) {
                escape = false;
              } else if (ch === '\\\\') {
                escape = true;
              } else if (ch === '"') {
                inString = false;
              }
              continue;
            }
            if (ch === '"') {
              inString = true;
            } else if (ch === '{' || ch === '[') {
              stack.push({ ch, line: lineForIndex(starts, i) });
            } else if (ch === '}' || ch === ']') {
              const opener = ch === '}' ? '{' : '[';
              for (let j = stack.length - 1; j >= 0; j--) {
                if (stack[j].ch === opener) {
                  const startLine = stack[j].line;
                  const endLine = lineForIndex(starts, i);
                  stack.splice(j);
                  if (endLine > startLine) foldRanges.set(startLine, endLine);
                  break;
                }
              }
            }
          }
          for (const [start, end] of Array.from(foldedRanges.entries())) {
            if (foldRanges.get(start) !== end) foldedRanges.delete(start);
          }
        }

        function buildDisplay() {
          const lines = textValue.split('\\n');
          const output = [];
          const rows = [];
          for (let line = 0; line < lines.length; line++) {
            const foldedEnd = foldedRanges.get(line);
            const original = lines[line] ?? '';
            if (foldedEnd !== undefined) {
              const hiddenCount = Math.max(1, foldedEnd - line);
              const suffix = `  … ${hiddenCount} lines folded`;
              output.push(`${original}${suffix}`);
              rows.push({ line, foldable: true, folded: true, placeholderStart: original.length });
              line = foldedEnd;
            } else {
              output.push(original);
              rows.push({ line, foldable: foldRanges.has(line), folded: false });
            }
          }
          return { text: output.join('\\n'), rows };
        }

        function computeMatches() {
          matches = [];
          activeMatch = -1;
          if (!query) return;
          const haystack = buildDisplay().text.toLowerCase();
          const needle = query.toLowerCase();
          let idx = haystack.indexOf(needle);
          while (idx !== -1) {
            matches.push([idx, idx + needle.length]);
            idx = haystack.indexOf(needle, idx + Math.max(needle.length, 1));
          }
          if (matches.length > 0) activeMatch = 0;
        }

        function splitWithMatches(source, start, end, className) {
          let html = '';
          let cursor = start;
          for (let i = 0; i < matches.length; i++) {
            const [mStart, mEnd] = matches[i];
            if (mEnd <= start || mStart >= end) continue;
            const beforeEnd = Math.max(cursor, Math.min(mStart, end));
            if (beforeEnd > cursor) {
              html += span(source.slice(cursor, beforeEnd), className);
            }
            const hitStart = Math.max(cursor, mStart, start);
            const hitEnd = Math.min(mEnd, end);
            if (hitEnd > hitStart) {
              html += span(source.slice(hitStart, hitEnd), [className, 'match', i === activeMatch ? 'active' : ''].filter(Boolean).join(' '), i === activeMatch && hitStart === mStart ? 'activeMatch' : '');
              cursor = hitEnd;
            }
          }
          if (cursor < end) html += span(source.slice(cursor, end), className);
          return html;
        }

        function span(value, className, id) {
          const idAttr = id ? ` id="${id}"` : '';
          const classAttr = className ? ` class="${className}"` : '';
          return `<span${idAttr}${classAttr}>${escapeHTML(value)}</span>`;
        }

        function markerClass(marker) {
          if (marker === 'C') return 'source-common';
          if (marker === 'N') return 'source-node';
          if (marker === 'O') return 'source-override';
          return '';
        }

        function renderSourceSegment(source, start, end) {
          const regex = /"(?:[^"\\\\]|\\\\.)*"|-?\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?|\\b(?:true|false|null)\\b/g;
          regex.lastIndex = start;
          let html = '';
          let cursor = start;
          let match;
          while ((match = regex.exec(source)) !== null) {
            if (match.index >= end) break;
            if (match.index > cursor) {
              html += splitWithMatches(source, cursor, match.index, '');
            }
            const value = match[0];
            const tokenEnd = Math.min(match.index + value.length, end);
            html += splitWithMatches(source, match.index, tokenEnd, tokenClass(source, value, match.index + value.length));
            cursor = tokenEnd;
          }
          if (cursor < end) html += splitWithMatches(source, cursor, end, '');
          return html;
        }

        function renderHighlight() {
          const display = buildDisplay();
          const source = display.text;
          const starts = lineStarts(source);
          const lines = source.split('\\n');
          let html = display.rows.map((row, index) => {
            const start = starts[index] ?? 0;
            const end = start + (lines[index] ?? '').length;
            let lineHTML;
            if (row.folded && row.placeholderStart !== undefined) {
              const placeholderStart = Math.min(end, start + row.placeholderStart);
              lineHTML = renderSourceSegment(source, start, placeholderStart)
                + splitWithMatches(source, placeholderStart, end, 'foldPlaceholder');
            } else {
              lineHTML = renderSourceSegment(source, start, end);
            }
            if (lineHTML.length === 0) lineHTML = '&nbsp;';
            return `<span class="codeLine">${lineHTML}</span>`;
          }).join('');
          if (html.length === 0) html = '<span></span>';
          highlight.innerHTML = html;
          lineBackgrounds.innerHTML = display.rows.map((row) => {
            const marker = markerClass(lineMarkers[String(row.line + 1)] || '');
            return `<div class="lineBackground ${marker}"></div>`;
          }).join('');
          if (input.value !== source) input.value = source;
        }

        function renderGutter() {
          const display = buildDisplay();
          const count = Math.max(1, textValue.split('\\n').length);
          gutter.innerHTML = display.rows.map((row) => {
            const symbol = row.foldable ? (row.folded ? '▶' : '▾') : '•';
            const empty = row.foldable ? '' : ' empty';
            const marker = lineMarkers[String(row.line + 1)] || '';
            return `<div class="gutterLine ${markerClass(marker)}" data-line="${row.line}">
              <button class="foldToggle${empty}" data-line="${row.line}" ${row.foldable ? '' : 'disabled'}>${symbol}</button>
              <span class="lineNumber">${row.line + 1}</span>
            </div>`;
          }).join('');
          window.webkit.messageHandlers.editor.postMessage({ type: 'lineCount', lineCount: count });
        }

        function render() {
          rebuildFoldRanges();
          renderHighlight();
          renderGutter();
          updateFindCount();
          syncScroll();
        }

        function syncScroll() {
          const top = editable ? input.scrollTop : highlight.scrollTop;
          const left = editable ? input.scrollLeft : highlight.scrollLeft;
          if (editable) {
            highlight.style.transform = `translate(${-left}px, ${-top}px)`;
          } else {
            highlight.style.transform = 'none';
          }
          lineBackgrounds.style.transform = `translateY(${-top}px)`;
          gutter.style.transform = `translateY(${-top}px)`;
        }

        function notifyChange() {
          const lineCount = Math.max(1, textValue.split('\\n').length);
          window.webkit.messageHandlers.editor.postMessage({ type: 'textChanged', text: textValue, lineCount });
        }

        function updateFromInput() {
          if (applying) return;
          if (foldedRanges.size > 0) {
            foldedRanges.clear();
            input.value = textValue;
            render();
            return;
          }
          textValue = input.value;
          const previousQuery = query;
          computeMatches();
          if (previousQuery !== query) activeMatch = -1;
          render();
          notifyChange();
        }

        function setEditable(nextEditable) {
          editable = nextEditable;
          shell.classList.toggle('readonly', !editable);
          input.readOnly = !editable || foldedRanges.size > 0;
          if (editable) {
            input.style.display = 'block';
          }
        }

        window.setEditorState = function(nextText, nextEditable) {
          applying = true;
          textValue = nextText || '';
          foldedRanges.clear();
          input.value = textValue;
          setEditable(!!nextEditable);
          computeMatches();
          render();
          applying = false;
        };

        window.setLineMarkers = function(nextMarkers) {
          for (const key of Object.keys(lineMarkers)) delete lineMarkers[key];
          for (const [key, value] of Object.entries(nextMarkers || {})) lineMarkers[key] = value;
          render();
        };

        function openFind() {
          findBar.classList.add('visible');
          findInput.focus();
          findInput.select();
        }

        function closeFind() {
          findBar.classList.remove('visible');
          query = '';
          matches = [];
          activeMatch = -1;
          render();
          if (editable) input.focus();
        }

        function updateFindCount() {
          findCount.textContent = matches.length === 0 ? '0/0' : `${activeMatch + 1}/${matches.length}`;
        }

        function selectMatch(direction) {
          if (matches.length === 0) return;
          activeMatch = (activeMatch + direction + matches.length) % matches.length;
          render();
          setTimeout(() => {
            const el = document.getElementById('activeMatch');
            if (el) el.scrollIntoView({ block: 'center', inline: 'center' });
            syncScroll();
          }, 0);
        }

        function clearFoldsForEditing(event) {
          if (!editable || foldedRanges.size === 0) return false;
          if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'f') return false;
          foldedRanges.clear();
          input.readOnly = false;
          input.value = textValue;
          render();
          event.preventDefault();
          input.focus();
          return true;
        }

        gutter.addEventListener('click', (event) => {
          const button = event.target.closest('.foldToggle');
          if (!button || button.classList.contains('empty')) return;
          const line = Number(button.dataset.line);
          const end = foldRanges.get(line);
          if (end === undefined) return;
          if (foldedRanges.has(line)) foldedRanges.delete(line);
          else foldedRanges.set(line, end);
          computeMatches();
          render();
        });

        input.addEventListener('input', updateFromInput);
        input.addEventListener('scroll', syncScroll);
        highlight.addEventListener('scroll', syncScroll);
        input.addEventListener('keydown', (event) => {
          if (clearFoldsForEditing(event)) return;
          if (event.key === 'Tab') {
            event.preventDefault();
            const start = input.selectionStart;
            const end = input.selectionEnd;
            input.setRangeText('  ', start, end, 'end');
            updateFromInput();
          }
        });
        document.addEventListener('keydown', (event) => {
          if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'f') {
            event.preventDefault();
            openFind();
          } else if (event.key === 'Escape' && findBar.classList.contains('visible')) {
            event.preventDefault();
            closeFind();
          } else if (event.key === 'Enter' && findBar.classList.contains('visible') && document.activeElement === findInput) {
            event.preventDefault();
            selectMatch(event.shiftKey ? -1 : 1);
          }
        });
        findInput.addEventListener('input', () => {
          query = findInput.value;
          computeMatches();
          render();
          if (matches.length > 0) selectMatch(0);
        });
        prevButton.addEventListener('click', () => selectMatch(-1));
        nextButton.addEventListener('click', () => selectMatch(1));
        closeButton.addEventListener('click', closeFind);
      </script>
    </body>
    </html>
    """
}
