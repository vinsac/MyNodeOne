#!/usr/bin/env node
//
// Renders the node list of the website pages from hostile cluster data, using the
// page's own functions, and checks that no markup from the data survives.
//
// Usage: node external-apps/tests/test-website-xss.js

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const websiteDir = path.join(__dirname, '..', '..', 'website');
const payload = '<img src=x onerror=alert(1)>';

// The source of a top-level function in a page, found by matching its braces.
function functionSource(html, name) {
    const match = html.match(new RegExp(`(async )?function ${name}\\(`));
    assert(match, `function ${name} not found`);
    let depth = 0;
    for (let i = html.indexOf('{', match.index); i < html.length; i++) {
        if (html[i] === '{') depth++;
        if (html[i] === '}' && --depth === 0) return html.slice(match.index, i + 1);
    }
    throw new Error(`unbalanced braces in ${name}`);
}

function loadPage(file, functions) {
    const html = fs.readFileSync(path.join(websiteDir, file), 'utf8');
    const elements = {};
    const context = {
        document: {
            getElementById: id => (elements[id] = elements[id] || { innerHTML: '' }),
        },
    };
    vm.createContext(context);
    vm.runInContext(functions.map(name => functionSource(html, name)).join('\n'), context);
    return { context, elements };
}

const hostileKubectlNode = {
    name: payload,
    status: 'True',
    roles: [payload],
    os: payload,
    kubernetes: payload,
    usage: { cpu: payload, memory: payload },
};
const hostileApiNode = {
    name: payload,
    status: payload,
    type: payload,
    ip: payload,
    last_heartbeat: 'never',
    config_version: payload,
};
const hostileCluster = {
    nodes: { ready: payload, total: 1 },
    pods: { running: payload },
    services: { running: payload },
    storage: { bound_pvc: payload },
};

let passed = 0;
function check(name, fn) {
    fn();
    passed++;
    console.log(`  ok   - ${name}`);
}

function assertEscaped(html, name) {
    assert(!html.includes('<img'), `${name}: raw markup reached the page`);
    assert(html.includes('&lt;img'), `${name}: the value should still be displayed, escaped`);
}

for (const file of ['dashboard.html', 'cluster-status.html']) {
    const functions = ['escapeHtml', 'updateClusterOverview', 'updateNodeStatus'];
    if (file === 'cluster-status.html') functions.push('formatLastSeen');
    const { context, elements } = loadPage(file, functions);

    check(`${file}: escapeHtml covers every special character`, () => {
        assert.strictEqual(context.escapeHtml(`<>&"'`), '&lt;&gt;&amp;&quot;&#39;');
    });
    check(`${file}: escapeHtml keeps zero and empties missing values`, () => {
        assert.strictEqual(context.escapeHtml(0), '0');
        assert.strictEqual(context.escapeHtml(null), '');
        assert.strictEqual(context.escapeHtml(undefined), '');
    });
    check(`${file}: node list from kubectl data`, () => {
        context.updateNodeStatus([hostileKubectlNode]);
        assertEscaped(elements['node-list'].innerHTML, file);
    });
    if (file === 'cluster-status.html') {
        check(`${file}: node list from Config API data`, () => {
            context.updateNodeStatus({ nodes: [hostileApiNode] });
            assertEscaped(elements['node-list'].innerHTML, file);
        });
    }
    check(`${file}: ordinary values render unchanged`, () => {
        context.updateNodeStatus([{
            name: 'node-1', status: 'True', roles: ['control-plane'], os: 'Ubuntu 24.04',
            kubernetes: 'v1.31.2', usage: { cpu: 42, memory: 80 },
        }]);
        const html = elements['node-list'].innerHTML;
        for (const expected of ['node-1', 'control-plane • Ubuntu 24.04', 'v1.31.2', '42%', '80%']) {
            assert(html.includes(expected), `missing: ${expected}`);
        }
    });

    const overviewId = file === 'dashboard.html' ? 'system-health-content' : 'cluster-overview-content';
    check(`${file}: cluster overview`, () => {
        context.updateClusterOverview(hostileCluster);
        assert(!elements[overviewId].innerHTML.includes('<img'), 'raw markup reached the page');
    });
}

// The rendering checks above only reach the branches they run, so also check that no
// cluster value is interpolated into either page without going through the helper.
for (const file of ['dashboard.html', 'cluster-status.html']) {
    check(`${file}: every cluster value goes through escapeHtml`, () => {
        const html = fs.readFileSync(path.join(websiteDir, file), 'utf8');
        const raw = html.match(/\$\{\s*(node\b|clusterData\b|roles\b|nodeType\b|cpuUsage\b|ramUsage\b)[^}]*\}/g);
        // A usage threshold picks one of three fixed colours, so its output is safe.
        const unsafe = (raw || []).filter(match => !/^\$\{(cpuUsage|ramUsage) > 70 \? '#/.test(match));
        assert.deepStrictEqual(unsafe, [], `not escaped: ${unsafe}`);
    });
}

console.log(`\n${passed} passed, 0 failed`);
