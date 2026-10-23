(() => {
    "use strict";

    const element = "umarkdown-find-match";
    const className = "umarkdown-find-result";
    const activeClass = "umarkdown-find-current";
    const svgNamespace = "http://www.w3.org/2000/svg";
    const marker = new Mark(document.body);
    const svgBackgrounds = [];
    let matches = [];
    let current = -1;
    let lastQuery = "";
    let highlighted = false;
    let dirty = false;
    const combiningDiacritics = Array.from({ length: 0x70 }, (_, index) => String.fromCharCode(0x300 + index));
    const changes = new MutationObserver(records => {
        if (records.some(record => record.type !== "attributes" || !record.target.classList.contains(className))) {
            dirty = true;
        }
    });
    const watch = () => changes.observe(document.body, {
        subtree: true, childList: true, characterData: true,
        attributes: true, attributeFilter: ["style", "class", "hidden", "open"]
    });

    const style = document.createElement("style");
    style.textContent = `
        ${element}.${className} {
            color: rgb(0, 0, 0) !important;
            background: rgb(255, 255, 255) !important;
            border-radius: 3px;
            box-shadow: 0 0 0 1px rgba(0, 0, 0, .15);
            -webkit-box-decoration-break: clone;
            box-decoration-break: clone;
        }
        ${element}.${activeClass} {
            background: rgb(255, 255, 84) !important;
            box-shadow: 0 1px 4px rgba(0, 0, 0, .5);
        }
        tspan.${className} { fill: rgb(0, 0, 0) !important; }
        rect.${className} { fill: rgb(255, 255, 255) !important; }
        rect.${activeClass} { fill: rgb(255, 255, 84) !important; }
    `;
    document.head.append(style);

    // Cut holes in the dimmer instead of raising the matches' z-index. This
    // keeps results bright inside stacking contexts, including the sticky TOC.
    const dimmer = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    const mask = document.createElementNS("http://www.w3.org/2000/svg", "mask");
    const background = document.createElementNS("http://www.w3.org/2000/svg", "rect");
    const holes = document.createElementNS("http://www.w3.org/2000/svg", "path");
    const shade = document.createElementNS("http://www.w3.org/2000/svg", "path");
    dimmer.setAttribute("aria-hidden", "true");
    dimmer.style.cssText = "position:fixed;inset:0;width:100%;height:100%;pointer-events:none;z-index:2147483647;";
    mask.id = "umarkdown-find-viewport-mask";
    mask.setAttribute("maskUnits", "userSpaceOnUse");
    background.setAttribute("width", "100%");
    background.setAttribute("height", "100%");
    background.setAttribute("fill", "white");
    holes.setAttribute("fill", "black");
    mask.append(background, holes);
    shade.setAttribute("fill", "rgba(0,0,0,.2)");
    shade.setAttribute("mask", `url(#${mask.id})`);
    dimmer.append(mask, shade);
    const visibleMarks = new Set();
    let maskFrame = 0;
    function updateMask() {
        maskFrame = 0;
        shade.setAttribute("d", `M0 0H${innerWidth}V${innerHeight}H0Z`);
        let path = "";
        for (const node of visibleMarks) {
            for (const rect of node.getClientRects()) {
                const { left, top, right, bottom } = rect;
                const radius = Math.min(3, rect.width / 2, rect.height / 2);
                path += `M${left + radius} ${top}H${right - radius}Q${right} ${top} ${right} ${top + radius}`
                    + `V${bottom - radius}Q${right} ${bottom} ${right - radius} ${bottom}`
                    + `H${left + radius}Q${left} ${bottom} ${left} ${bottom - radius}`
                    + `V${top + radius}Q${left} ${top} ${left + radius} ${top}Z`;
            }
        }
        holes.setAttribute("d", path);
    }
    function queueMask() {
        if (highlighted && matches.length && !maskFrame) maskFrame = requestAnimationFrame(updateMask);
    }
    const intersections = new IntersectionObserver(entries => {
        for (const entry of entries) {
            if (entry.isIntersecting) visibleMarks.add(entry.target);
            else visibleMarks.delete(entry.target);
        }
        queueMask();
    });
    window.addEventListener("scroll", queueMask, true);
    window.addEventListener("resize", queueMask);

    function state() {
        return { current: matches.length ? current + 1 : 0, total: matches.length };
    }

    function select(index) {
        if (!matches.length) return;
        for (const node of matches[current] || []) node.classList.remove(activeClass);
        current = (index + matches.length) % matches.length;
        for (const node of matches[current]) node.classList.add(activeClass);
        // Use the scroll API supported by the oldest deployment target, while
        // bypassing the document theme's smooth scrolling for find navigation.
        const root = document.documentElement;
        const behavior = root.style.getPropertyValue("scroll-behavior");
        const priority = root.style.getPropertyPriority("scroll-behavior");
        root.style.setProperty("scroll-behavior", "auto", "important");
        matches[current][0].scrollIntoView({ block: "center", inline: "nearest", behavior: "auto" });
        if (behavior) root.style.setProperty("scroll-behavior", behavior, priority);
        else root.style.removeProperty("scroll-behavior");
        for (const node of matches[current]) visibleMarks.add(node);
        queueMask();
    }

    function unmark() {
        for (const rect of svgBackgrounds) rect.remove();
        svgBackgrounds.length = 0;
        return new Promise(resolve => marker.unmark({ element: "*", className, done: resolve }));
    }

    function addSVGBackgrounds() {
        for (const match of matches) {
            for (const node of match.slice()) {
                if (node.namespaceURI !== svgNamespace) continue;
                const text = node.closest("text");
                const parent = text && text.parentElement;
                const matrix = node.getCTM();
                const parentMatrix = parent && parent.getCTM();
                if (!matrix || !parentMatrix) continue;
                const bounds = node.getBBox();
                const relative = parentMatrix.inverse().multiply(matrix);
                const rect = document.createElementNS(svgNamespace, "rect");
                for (const key of ["x", "y", "width", "height"]) rect.setAttribute(key, bounds[key]);
                rect.setAttribute("rx", "3");
                rect.setAttribute("transform", `matrix(${relative.a} ${relative.b} ${relative.c} ${relative.d} ${relative.e} ${relative.f})`);
                rect.classList.add(className);
                parent.insertBefore(rect, text);
                svgBackgrounds.push(rect);
                match.push(rect);
            }
        }
    }

    async function search(query) {
        if (highlighted && !dirty && query === lastQuery) return state();
        const previous = query === lastQuery ? current : 0;
        changes.disconnect();
        intersections.disconnect();
        visibleMarks.clear();
        await unmark();
        dimmer.remove();
        matches = [];
        current = -1;
        lastQuery = query;
        highlighted = true;
        dirty = false;
        if (!query.length) {
            watch();
            return state();
        }

        // Exclude hidden subtrees before the library builds its text index.
        // Filtering only completed matches can accept part of a phrase that
        // crosses hidden text. Read visibility once per element, not per match.
        const hidden = [];
        const hiddenAttribute = "data-umarkdown-find-hidden";
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT, {
            acceptNode(node) {
                const css = getComputedStyle(node);
                if (css.display === "none" || css.visibility === "hidden" || css.visibility === "collapse") {
                    hidden.push(node);
                    node.setAttribute(hiddenAttribute, "");
                    return NodeFilter.FILTER_REJECT;
                }
                return NodeFilter.FILTER_ACCEPT;
            }
        });
        while (walker.nextNode()) { /* Visit rendered elements once. */ }

        try {
            await new Promise(resolve => marker.mark(query.normalize("NFC"), {
                element, className,
                separateWordSearch: false,
                acrossElements: true,
                blockElementsBoundary: true,
                caseSensitive: false,
                diacritics: true,
                ignorePunctuation: combiningDiacritics,
                wildcards: "disabled",
                exclude: ["script", "style", "noscript", "template", "textarea", "select",
                    `[${hiddenAttribute}]`, `[${hiddenAttribute}] *`,
                    "details:not([open]) > :not(summary)", "details:not([open]) > :not(summary) *"],
                // The library reports logical matches separately from fragments.
                // A phrase split by emphasis still counts and navigates as one.
                each: (node, info) => {
                    // Preserve SVG text rendering: HTML wrappers inside <text>
                    // suppress its glyphs. Move the same text nodes into a tspan.
                    if (node.parentElement.namespaceURI === svgNamespace) {
                        const span = document.createElementNS(svgNamespace, "tspan");
                        for (const attribute of node.attributes) span.setAttribute(attribute.name, attribute.value);
                        span.append(...node.childNodes);
                        node.replaceWith(span);
                        node = span;
                    }
                    if (info.matchStart) matches.push([]);
                    matches[matches.length - 1].push(node);
                },
                done: resolve
            }));
        } finally {
            for (const node of hidden) node.removeAttribute(hiddenAttribute);
        }

        if (matches.length) {
            addSVGBackgrounds();
            document.body.append(dimmer);
            select(Math.min(Math.max(previous, 0), matches.length - 1));
            for (const match of matches) for (const node of match) intersections.observe(node);
            for (const node of matches[current]) visibleMarks.add(node);
            updateMask();
        }
        watch();
        return state();
    }

    window.umarkdownFind = {
        search,
        async move(query, direction) {
            const hadMatches = query === lastQuery && current >= 0;
            await search(query);
            if (matches.length) select(hadMatches ? current + direction : direction < 0 ? matches.length - 1 : 0);
            return state();
        },
        async hide() {
            changes.disconnect();
            intersections.disconnect();
            visibleMarks.clear();
            if (maskFrame) cancelAnimationFrame(maskFrame);
            maskFrame = 0;
            dimmer.remove();
            await unmark();
            highlighted = false;
            matches = [];
            watch();
            return { current: 0, total: 0 };
        }
    };
})();
