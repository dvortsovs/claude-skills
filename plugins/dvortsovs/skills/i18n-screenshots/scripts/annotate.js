// Browser-side overlay. Injected by render.mjs; do not call directly.
//
// window.__annotate({title, items, scope}) draws, above the whole viewport (nothing is cropped or
// painted over):
//   - for every item, a label with item.label — red monospace text on a black plate, stacked at
//     the left or right edge of the viewport, as close to the item's height as the stack allows;
//   - a red arrow from the label to the item, the arrowhead at the item;
//   - `title` in a white caption box at the bottom left.
// items: [{id, label, text} | {id, label, attr, value} | {id, label, selector}], optional
// item.side ('left' | 'right'; by default the half of the viewport the item is in) and item.nth
// (which of several equal matches, 0-based, counted top to bottom).
// `scope` limits where items are searched (default: the whole page).
// Returns JSON {missing: [ids], offscreen: [ids], covered: [ids], found: n}:
//   missing   — not found on the page;
//   offscreen — found, but outside the viewport, so not in the screenshot;
//   covered   — a label sits on top of the item's text.
// The overlay element is #__ann; window.__annotateCleanup() removes it.
window.__annotateCleanup = () => {
    document.getElementById('__ann')?.remove();
    document.getElementById('__ann-style')?.remove();
};
window.__annotate = ({title, items, scope}) => {
    window.__annotateCleanup();
    const root = scope ? document.querySelector(scope) : document.body;
    if (!root) {
        return JSON.stringify({error: `scope not found: ${scope}`});
    }
    const style = document.createElement('style');
    style.id = '__ann-style';
    style.textContent = 'html, body, * { scrollbar-width: none !important; }';
    document.head.appendChild(style);

    const RED = '#ff2424';
    const EDGE = 12; // labels and caption keep this distance from the viewport edges
    const GAP = 8; // vertical gap between stacked labels
    const TIP = 6; // the arrowhead stops this far from the text
    const VW = window.innerWidth;
    const VH = window.innerHeight;
    const norm = (s) => (s || '').replace(/\s+/g, ' ').trim();

    const visible = (el) => {
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden';
    };
    // an element under a modal backdrop or another layer is a worse match than one on top
    const onTop = (el) => {
        const r = el.getBoundingClientRect();
        const x = Math.min(Math.max(r.left + r.width / 2, 0), VW - 1);
        const y = Math.min(Math.max(r.top + r.height / 2, 0), VH - 1);
        const hit = document.elementFromPoint(x, y);
        return Boolean(hit && (el === hit || el.contains(hit) || hit.contains(el)));
    };
    const pick = (candidates, nth) => {
        const sorted = candidates.sort(
            (a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top,
        );
        if (nth !== undefined) return sorted[nth];
        return sorted.find(onTop) || sorted[0];
    };
    const textRect = (el) => {
        const range = document.createRange();
        range.selectNodeContents(el);
        const r = range.getBoundingClientRect();
        return r.width && r.height ? r : el.getBoundingClientRect();
    };
    const rectOf = (item) => {
        if (item.selector) {
            const el = pick([...root.querySelectorAll(item.selector)].filter(visible), item.nth);
            return el && (item.attr ? el.getBoundingClientRect() : textRect(el));
        }
        if (item.attr) {
            const el = pick(
                [...root.querySelectorAll(`[${item.attr}]`)].filter(
                    (e) => norm(e.getAttribute(item.attr)) === norm(item.value),
                ),
                item.nth,
            );
            if (!el) return null;
            // an input's own box is narrower than the field the user sees
            const shown = el.closest('.g-text-input__content, .g-text-area__content') || el;
            return visible(shown) ? shown.getBoundingClientRect() : null;
        }
        const want = norm(item.text);
        const matches = [...root.querySelectorAll('*')].filter(
            (el) => visible(el) && norm(el.innerText) === want,
        );
        // the innermost element holding the whole text
        const innermost = matches.filter((el) => !matches.some((m) => m !== el && el.contains(m)));
        const el = pick(innermost, item.nth);
        if (el) return textRect(el);
        // a text node next to other elements ("Label <button>…</button>")
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        const nodes = [];
        for (let n = walker.nextNode(); n; n = walker.nextNode()) {
            if (norm(n.data) === want && n.parentElement && visible(n.parentElement)) nodes.push(n);
        }
        const rects = nodes
            .map((n) => {
                const range = document.createRange();
                range.selectNodeContents(n);
                return {r: range.getBoundingClientRect(), el: n.parentElement};
            })
            .filter(({r}) => r.width && r.height)
            .sort((a, b) => a.r.top - b.r.top);
        if (item.nth !== undefined) return rects[item.nth]?.r;
        return (rects.find(({el}) => onTop(el)) || rects[0])?.r;
    };

    const ov = document.createElement('div');
    ov.id = '__ann';
    Object.assign(ov.style, {
        position: 'fixed',
        left: 0,
        top: 0,
        width: VW + 'px',
        height: VH + 'px',
        zIndex: 2147483647,
        pointerEvents: 'none',
    });
    document.body.appendChild(ov);
    const add = (style, text) => {
        const el = document.createElement('div');
        Object.assign(el.style, {position: 'absolute', whiteSpace: 'nowrap', boxSizing: 'border-box', ...style});
        el.textContent = text;
        ov.appendChild(el);
        return el;
    };

    let bottomLimit = VH - EDGE;
    if (title) {
        const caption = add(
            {
                left: EDGE + 'px',
                bottom: EDGE + 'px',
                padding: '8px 12px',
                background: '#fff',
                border: '1px solid #c8c8c8',
                borderRadius: '2px',
                color: '#000',
                font: '15px/20px Arial, Helvetica, sans-serif',
                maxWidth: VW - 2 * EDGE + 'px',
                whiteSpace: 'normal',
            },
            title,
        );
        bottomLimit = caption.getBoundingClientRect().top - GAP;
    }

    const missing = [];
    const offscreen = [];
    const placed = [];
    const labelStyle = {
        padding: '0 8px',
        background: '#000',
        color: RED,
        font: '15px/30px Menlo, Consolas, "DejaVu Sans Mono", monospace',
        height: '30px',
    };
    items.forEach((item) => {
        const r = rectOf(item);
        if (!r) {
            missing.push(item.id || item.label);
            return;
        }
        if (r.bottom <= 0 || r.top >= VH || r.right <= 0 || r.left >= VW) {
            offscreen.push(item.id || item.label);
            return;
        }
        const label = add({...labelStyle, top: 0, left: 0}, item.label);
        const {width: w, height: h} = label.getBoundingClientRect();
        let side = item.side || (r.left + r.width / 2 < VW / 2 ? 'left' : 'right');
        // a label at the edge must not sit on its own item: take the other edge when it would
        const blocks = (s) => (s === 'left' ? r.left < EDGE + w + 2 * TIP : r.right > VW - EDGE - w - 2 * TIP);
        if (!item.side && blocks(side) && !blocks(side === 'left' ? 'right' : 'left')) {
            side = side === 'left' ? 'right' : 'left';
        }
        label.style.left = '';
        label.style[side] = EDGE + 'px';
        placed.push({item, side, r, label, h});
    });

    ['left', 'right'].forEach((side) => {
        const group = placed
            .filter((p) => p.side === side)
            .sort((a, b) => a.r.top + a.r.height / 2 - (b.r.top + b.r.height / 2));
        group.forEach((p) => {
            p.top = p.r.top + p.r.height / 2 - p.h / 2;
        });
        // push overlapping labels down, then pull the stack back above the caption
        let floor = EDGE;
        group.forEach((p) => {
            p.top = Math.max(p.top, floor);
            floor = p.top + p.h + GAP;
        });
        let ceiling = bottomLimit;
        [...group].reverse().forEach((p) => {
            p.top = Math.min(p.top, ceiling - p.h);
            ceiling = p.top - GAP;
        });
        group.forEach((p) => {
            p.label.style.top = p.top + 'px';
        });
    });

    const svgNS = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(svgNS, 'svg');
    svg.setAttribute('width', VW);
    svg.setAttribute('height', VH);
    Object.assign(svg.style, {position: 'absolute', left: 0, top: 0, overflow: 'visible'});
    svg.innerHTML = `<defs><marker id="__ah" markerWidth="12" markerHeight="12" refX="10" refY="6" orient="auto" markerUnits="userSpaceOnUse"><path d="M0,1 L11,6 L0,11 z" fill="${RED}"/></marker></defs>`;
    ov.appendChild(svg);

    const inside = (x, y, b, m = 2) => x > b.left - m && x < b.right + m && y > b.top - m && y < b.bottom + m;
    // does the segment pass through any other annotated item or any label?
    const crosses = (x1, y1, x2, y2, self) => {
        const boxes = placed.flatMap((p) => (p === self ? [] : [p.r, p.label.getBoundingClientRect()]));
        const STEPS = 80;
        for (let i = 1; i < STEPS; i++) {
            const x = x1 + ((x2 - x1) * i) / STEPS;
            const y = y1 + ((y2 - y1) * i) / STEPS;
            if (boxes.some((b) => inside(x, y, b))) return true;
        }
        return false;
    };
    const covered = [];
    const intersects = (a, b) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
    placed.forEach((p) => {
        const {item, side, r, label} = p;
        const lr = label.getBoundingClientRect();
        const x1 = side === 'left' ? lr.right : lr.left;
        const y1 = lr.top + lr.height / 2;
        // point at the item's near side; when that line runs through another item, come from
        // below or above instead
        const anchors = [
            [side === 'left' ? r.left - TIP : r.right + TIP, r.top + r.height / 2],
            [r.left + r.width / 2, r.bottom + TIP],
            [r.left + r.width / 2, r.top - TIP],
        ];
        const [x2, y2] = anchors.find(([x, y]) => !crosses(x1, y1, x, y, p)) || anchors[0];
        const line = document.createElementNS(svgNS, 'line');
        Object.entries({x1, y1, x2, y2, stroke: RED, 'stroke-width': 2, 'marker-end': 'url(#__ah)'}).forEach(
            ([k, v]) => line.setAttribute(k, v),
        );
        svg.appendChild(line);
        if (placed.some((q) => intersects(q.label.getBoundingClientRect(), r))) {
            covered.push(item.id || item.label);
        }
    });

    return JSON.stringify({missing, offscreen, covered, found: placed.length});
};
